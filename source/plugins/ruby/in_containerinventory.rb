#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  class Container_Inventory_Input < Input
    Fluent::Plugin.register_input("containerinventory", self)

    @@PluginName = "ContainerInventory"

    def initialize
      super
      require "yajl/json_gem"
      require "time"
      require_relative "ContainerInventoryState"
      require_relative "ApplicationInsightsUtility"
      require_relative "omslog"
      require_relative "CAdvisorMetricsAPIClient"
      require_relative "kubernetes_container_inventory"
      require_relative "extension_utils"
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.CONTAINER_INVENTORY_BLOB"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        super
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@telemetryTimeTracker = DateTime.now.to_time.to_i
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
        super # This super must be at the end of shutdown method
      end
    end

    def enumerate
      currentTime = Time.now
      batchTime = currentTime.utc.iso8601
      emitTime = Fluent::Engine.now
      containerInventory = Array.new
      eventStream = Fluent::MultiEventStream.new
      hostName = ""
      $log.info("in_container_inventory::enumerate : Begin processing @ #{Time.now.utc.iso8601}")
      if ExtensionUtils.isAADMSIAuthMode()
        $log.info("in_container_inventory::enumerate: AAD AUTH MSI MODE")
        if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
          @tag = ExtensionUtils.getOutputStreamId(Constants::CONTAINER_INVENTORY_DATA_TYPE)
        end
        $log.info("in_container_inventory::enumerate: using tag -#{@tag} @ #{Time.now.utc.iso8601}")
      end
      begin
        containerRuntimeEnv = ENV["CONTAINER_RUNTIME"]
        $log.info("in_container_inventory::enumerate : container runtime : #{containerRuntimeEnv}")
        clusterCollectEnvironmentVar = ENV["AZMON_CLUSTER_COLLECT_ENV_VAR"]
        $log.info("in_container_inventory::enumerate : using cadvisor apis")
        containerIds = Array.new
        response = CAdvisorMetricsAPIClient.getPodsFromCAdvisor(winNode: nil)
        if !response.nil? && !response.body.nil?
            podList = JSON.parse(response.body)
            if !podList.nil? && !podList.empty? && podList.key?("items") && !podList["items"].nil? && !podList["items"].empty?
              podList["items"].each do |item|
                containerInventoryRecords = KubernetesContainerInventory.getContainerInventoryRecords(item, batchTime, clusterCollectEnvironmentVar)
                containerInventoryRecords.each do |containerRecord|
                  ContainerInventoryState.writeContainerState(containerRecord)
                  if hostName.empty? && !containerRecord["Computer"].empty?
                    hostName = containerRecord["Computer"]
                  end
                  containerIds.push containerRecord["InstanceID"]
                  containerInventory.push containerRecord
                end
              end
            end
        end
        # Update the state for deleted containers
        deletedContainers = ContainerInventoryState.getDeletedContainers(containerIds)
        if !deletedContainers.nil? && !deletedContainers.empty?
          deletedContainers.each do |deletedContainer|
            container = ContainerInventoryState.readContainerState(deletedContainer)
            if !container.nil?
              container.each { |k, v| container[k] = v }
              container["State"] = "Deleted"
              KubernetesContainerInventory.deleteCGroupCacheEntryForDeletedContainer(container["InstanceID"])
              containerInventory.push container
             end
           end
        end
        containerInventory.each do |record|
          eventStream.add(emitTime, record) if record
        end
        router.emit_stream(@tag, eventStream) if eventStream
        @@istestvar = ENV["ISTEST"]
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && eventStream.count > 0)
          $log.info("containerInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
        $log.info("in_container_inventory::enumerate : Processing complete - emitted stream @ #{Time.now.utc.iso8601}")
        timeDifference = (DateTime.now.to_time.to_i - @@telemetryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= 5)
          @@telemetryTimeTracker = DateTime.now.to_time.to_i
          telemetryProperties = {}
          telemetryProperties["Computer"] = hostName
          telemetryProperties["ContainerCount"] = containerInventory.length
          ApplicationInsightsUtility.sendTelemetry(@@PluginName, telemetryProperties)
        end
      rescue => errorStr
        $log.warn("Exception in enumerate container inventory: #{errorStr}")
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end

    def run_periodic
      @mutex.lock
      done = @finished
      @nextTimeToRun = Time.now
      @waitTimeout = @run_interval
      until done
        @nextTimeToRun = @nextTimeToRun + @run_interval
        @now = Time.now
        if @nextTimeToRun <= @now
          @waitTimeout = 1
          @nextTimeToRun = @now
        else
          @waitTimeout = @nextTimeToRun - @now
        end
        @condition.wait(@mutex, @waitTimeout)
        done = @finished
        @mutex.unlock
        if !done
          begin
            $log.info("in_container_inventory::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_container_inventory::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_container_inventory::run_periodic: Failed in enumerate container inventory: #{errorStr}"
            $log.debug_backtrace(errorStr.backtrace)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # Container_Inventory_Input
end # module
