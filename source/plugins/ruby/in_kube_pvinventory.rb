#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  class Kube_PVInventory_Input < Input
    Fluent::Plugin.register_input("kube_pvinventory", self)

    @@hostName = (OMS::Common.get_hostname)

    def initialize
      super
      require "yaml"
      require "yajl/json_gem"
      require "yajl"
      require "time"
      require_relative "KubernetesApiClient"
      require_relative "ApplicationInsightsUtility"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "constants"
      require_relative "extension_utils"

      # Response size is around 1500 bytes per PV
      @PV_CHUNK_SIZE = "5000"
      @pvTypeToCountHash = {}
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.KUBE_PV_INVENTORY_BLOB"

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
        @@pvTelemetryTimeTracker = DateTime.now.to_time.to_i
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
        super
      end
    end

    def enumerate
      begin
        pvInventory = nil
        telemetryFlush = false
        @pvTypeToCountHash = {}
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601
        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_kube_pvinventory::enumerate: AAD AUTH MSI MODE")
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::KUBE_PV_INVENTORY_DATA_TYPE)
          end
        end

        continuationToken = nil
        $log.info("in_kube_pvinventory::enumerate : Getting PVs from Kube API @ #{Time.now.utc.iso8601}")
        continuationToken, pvInventory = KubernetesApiClient.getResourcesAndContinuationToken("persistentvolumes?limit=#{@PV_CHUNK_SIZE}")
        $log.info("in_kube_pvinventory::enumerate : Done getting PVs from Kube API @ #{Time.now.utc.iso8601}")

        if (!pvInventory.nil? && !pvInventory.empty? && pvInventory.key?("items") && !pvInventory["items"].nil? && !pvInventory["items"].empty?)
          parse_and_emit_records(pvInventory, batchTime)
        else
          $log.warn "in_kube_pvinventory::enumerate:Received empty pvInventory"
        end

        # If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          continuationToken, pvInventory = KubernetesApiClient.getResourcesAndContinuationToken("persistentvolumes?limit=#{@PV_CHUNK_SIZE}&continue=#{continuationToken}")
          if (!pvInventory.nil? && !pvInventory.empty? && pvInventory.key?("items") && !pvInventory["items"].nil? && !pvInventory["items"].empty?)
            parse_and_emit_records(pvInventory, batchTime)
          else
            $log.warn "in_kube_pvinventory::enumerate:Received empty pvInventory"
          end
        end

        # Setting this to nil so that we dont hold memory until GC kicks in
        pvInventory = nil

        # Adding telemetry to send pod telemetry every 10 minutes
        timeDifference = (DateTime.now.to_time.to_i - @@pvTelemetryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
          telemetryFlush = true
        end

        # Flush AppInsights telemetry once all the processing is done
        if telemetryFlush == true
          telemetryProperties = {}
          telemetryProperties["CountsOfPVTypes"] = @pvTypeToCountHash.to_json
          ApplicationInsightsUtility.sendCustomEvent(Constants::PV_INVENTORY_HEART_BEAT_EVENT, telemetryProperties)
          @@pvTelemetryTimeTracker = DateTime.now.to_time.to_i
        end

      rescue => errorStr
        $log.warn "in_kube_pvinventory::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end # end enumerate

    def parse_and_emit_records(pvInventory, batchTime = Time.utc.iso8601)
      currentTime = Time.now
      emitTime = Fluent::Engine.now
      eventStream = Fluent::MultiEventStream.new
      @@istestvar = ENV["ISTEST"]
      begin
        records = []
        pvInventory["items"].each do |item|

          # Node, pod, & usage info can be found by joining with pvUsedBytes metric using PVCNamespace/PVCName
          record = {}
          record["CollectionTime"] = batchTime
          record["ClusterId"] = KubernetesApiClient.getClusterId
          record["ClusterName"] = KubernetesApiClient.getClusterName
          record["PVName"] = item["metadata"]["name"]
          record["PVStatus"] = item["status"]["phase"]
          record["PVAccessModes"] = item["spec"]["accessModes"].join(', ')
          record["PVStorageClassName"] = item["spec"]["storageClassName"]
          record["PVCapacityBytes"] = KubernetesApiClient.getMetricNumericValue("memory", item["spec"]["capacity"]["storage"])
          record["PVCreationTimeStamp"] = item["metadata"]["creationTimestamp"]

          # Optional values
          pvcNamespace, pvcName = getPVCInfo(item)
          type, typeInfo = getTypeInfo(item)
          record["PVCNamespace"] = pvcNamespace
          record["PVCName"] = pvcName
          record["PVType"] = type
          record["PVTypeInfo"] = typeInfo

          records.push(record)

          # Record telemetry
          if type == nil
            type = "empty"
          end
          if (@pvTypeToCountHash.has_key? type)
            @pvTypeToCountHash[type] += 1
          else
            @pvTypeToCountHash[type] = 1
          end
        end

        records.each do |record|
          if !record.nil?
            eventStream.add(emitTime, record)
          end
        end

        router.emit_stream(@tag, eventStream) if eventStream
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
          $log.info("kubePVInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end

      rescue => errorStr
        $log.warn "Failed in parse_and_emit_record for in_kube_pvinventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end

    def getPVCInfo(item)
      begin
        if !item["spec"].nil? && !item["spec"]["claimRef"].nil?
          claimRef = item["spec"]["claimRef"]
          pvcNamespace = claimRef["namespace"]
          pvcName = claimRef["name"]
          return pvcNamespace, pvcName
        end
      rescue => errorStr
        $log.warn "Failed in getPVCInfo for in_kube_pvinventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end

      # No PVC or an error
      return nil, nil
    end

    def getTypeInfo(item)
      begin
        if !item["spec"].nil?
          (Constants::PV_TYPES).each do |pvType|

            # PV is this type
            if !item["spec"][pvType].nil?

              # Get additional info if azure disk/file
              typeInfo = {}
              if pvType == "azureDisk"
                azureDisk = item["spec"]["azureDisk"]
                typeInfo["DiskName"] = azureDisk["diskName"]
                typeInfo["DiskUri"] = azureDisk["diskURI"]
              elsif pvType == "azureFile"
                typeInfo["FileShareName"] = item["spec"]["azureFile"]["shareName"]
              end

              # Can only have one type: return right away when found
              return pvType, typeInfo

            end
          end
        end
      rescue => errorStr
        $log.warn "Failed in getTypeInfo for in_kube_pvinventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end

      # No matches from list of types or an error
      return nil, {}
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
            $log.info("in_kube_pvinventory::run_periodic.enumerate.start #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_pvinventory::run_periodic.enumerate.end #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_pvinventory::run_periodic: enumerate Failed to retrieve pod inventory: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # Kube_PVInventory_Input
end # module
