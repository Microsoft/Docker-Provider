#!/usr/local/bin/ruby
# frozen_string_literal: true

require "fluent/plugin/input"

module Fluent::Plugin
  class Win_CAdvisor_Perf_Input < Input
    Fluent::Plugin.register_input("win_cadvisor_perf", self)

    @@winNodes = []

    def initialize
      super
      require "yaml"
      require "yajl/json_gem"
      require "time"

      require_relative "CAdvisorMetricsAPIClient"
      require_relative "KubernetesApiClient"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "constants"
      require_relative "extension_utils"
      @insightsMetricsTag = "oneagent.containerInsights.INSIGHTS_METRICS_BLOB"
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.LINUX_PERF_BLOB"
    config_param :mdmtag, :string, :default => "mdm.cadvisorperf"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@winNodeQueryTimeTracker = DateTime.now.to_time.to_i
        @@cleanupRoutineTimeTracker = DateTime.now.to_time.to_i
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
      end
    end

    def enumerate()
      time = Fluent::Engine.now
      begin
        timeDifference = (DateTime.now.to_time.to_i - @@winNodeQueryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        @@istestvar = ENV["ISTEST"]
        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_win_cadvisor_perf::enumerate: AAD AUTH MSI MODE")
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::PERF_DATA_TYPE)
          end
          if @insightsMetricsTag.nil? || !@insightsMetricsTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @insightsMetricsTag = ExtensionUtils.getOutputStreamId(Constants::INSIGHTS_METRICS_DATA_TYPE)
          end
	        $log.info("in_win_cadvisor_perf::enumerate: using perf tag -#{@kubeperfTag} @ #{Time.now.utc.iso8601}")
          $log.info("in_win_cadvisor_perf::enumerate: using insightsmetrics tag -#{@insightsMetricsTag} @ #{Time.now.utc.iso8601}")
        end

        #Resetting this cache so that it is populated with the current set of containers with every call
        CAdvisorMetricsAPIClient.resetWinContainerIdCache()
        if (timeDifferenceInMinutes >= 5)
          $log.info "in_win_cadvisor_perf: Getting windows nodes"
          nodes = KubernetesApiClient.getWindowsNodes()
          if !nodes.nil?
            @@winNodes = nodes
          end
          $log.info "in_win_cadvisor_perf : Successuly got windows nodes after 5 minute interval"
          @@winNodeQueryTimeTracker = DateTime.now.to_time.to_i
        end
        @@winNodes.each do |winNode|
          eventStream = Fluent::MultiEventStream.new
          metricData = CAdvisorMetricsAPIClient.getMetrics(winNode: winNode, metricTime: Time.now.utc.iso8601)
          metricData.each do |record|
            if !record.empty?
              eventStream.add(time, record) if record
            end
          end
          router.emit_stream(@tag, eventStream) if eventStream

          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && eventStream.count > 0)
            $log.info("winCAdvisorPerfEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end

          #start GPU InsightsMetrics items
          begin
            containerGPUusageInsightsMetricsDataItems = []
            containerGPUusageInsightsMetricsDataItems.concat(CAdvisorMetricsAPIClient.getInsightsMetrics(winNode: winNode, metricTime: Time.now.utc.iso8601))
            insightsMetricsEventStream = Fluent::MultiEventStream.new

            containerGPUusageInsightsMetricsDataItems.each do |insightsMetricsRecord|
              insightsMetricsEventStream.add(time, insightsMetricsRecord) if insightsMetricsRecord
            end

            router.emit_stream(@insightsMetricsTag, insightsMetricsEventStream) if insightsMetricsEventStream
            router.emit_stream(@mdmtag, insightsMetricsEventStream) if insightsMetricsEventStream
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && insightsMetricsEventStream.count > 0)
              $log.info("winCAdvisorInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          rescue => errorStr
            $log.warn "Failed when processing GPU Usage metrics in_win_cadvisor_perf : #{errorStr}"
            $log.debug_backtrace(errorStr.backtrace)
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
          #end GPU InsightsMetrics items

        end

        # Cleanup routine to clear deleted containers from cache
        cleanupTimeDifference = (DateTime.now.to_time.to_i - @@cleanupRoutineTimeTracker).abs
        cleanupTimeDifferenceInMinutes = cleanupTimeDifference / 60
        if (cleanupTimeDifferenceInMinutes >= 5)
          $log.info "in_win_cadvisor_perf : Cleanup routine kicking in to clear deleted containers from cache"
          CAdvisorMetricsAPIClient.clearDeletedWinContainersFromCache()
          @@cleanupRoutineTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => errorStr
        $log.warn "Failed to retrieve cadvisor metric data for windows nodes: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
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
            $log.info("in_win_cadvisor_perf::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_win_cadvisor_perf::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_win_cadvisor_perf::run_periodic: enumerate Failed to retrieve cadvisor perf metrics for windows nodes: #{errorStr}"
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # Win_CAdvisor_Perf_Input
end # module
