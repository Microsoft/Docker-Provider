#!/usr/local/bin/ruby
# frozen_string_literal: true
require "fluent/plugin/input"

module Fluent::Plugin
  class CAdvisor_Perf_Input < Input
    Fluent::Plugin.register_input("cadvisor_perf", self)
    @@isWindows = false
    @@os_type = ENV["OS_TYPE"]
    if !@@os_type.nil? && !@@os_type.empty? && @@os_type.strip.casecmp("windows") == 0
      @@isWindows = true
    end

    def initialize
      super
      require "yaml"
      require "yajl/json_gem"
      require "time"

      require_relative "CAdvisorMetricsAPIClient"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "constants"
      require_relative "extension_utils"
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.LINUX_PERF_BLOB"
    config_param :mdmtag, :string, :default => "mdm.cadvisorperf"
    config_param :nodehealthtag, :string, :default => "kubehealth.DaemonSet.Node"
    config_param :containerhealthtag, :string, :default => "kubehealth.DaemonSet.Container"
    config_param :insightsmetricstag, :string, :default => "oneagent.containerInsights.INSIGHTS_METRICS_BLOB"

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

    def enumerate()
      currentTime = Time.now
      time = Fluent::Engine.now
      batchTime = currentTime.utc.iso8601
      @@istestvar = ENV["ISTEST"]
      begin
        eventStream = Fluent::MultiEventStream.new
        insightsMetricsEventStream = Fluent::MultiEventStream.new
        metricData = CAdvisorMetricsAPIClient.getMetrics(winNode: nil, metricTime: batchTime )
        metricData.each do |record|
          eventStream.add(time, record) if record
        end

        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_cadvisor_perf::enumerate: AAD AUTH MSI MODE")
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::PERF_DATA_TYPE)
          end
          if @insightsmetricstag.nil? || !@insightsmetricstag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @insightsmetricstag = ExtensionUtils.getOutputStreamId(Constants::INSIGHTS_METRICS_DATA_TYPE)
          end
	        $log.info("in_cadvisor_perf::enumerate: using perf tag -#{@tag} @ #{Time.now.utc.iso8601}")
          $log.info("in_cadvisor_perf::enumerate: using insightsmetrics tag -#{@insightsmetricstag} @ #{Time.now.utc.iso8601}")
        end
        router.emit_stream(@tag, eventStream) if eventStream
        router.emit_stream(@mdmtag, eventStream) if eventStream
        router.emit_stream(@containerhealthtag, eventStream) if eventStream
        router.emit_stream(@nodehealthtag, eventStream) if eventStream

        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && eventStream.count > 0)
          $log.info("cAdvisorPerfEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end

        #start GPU InsightsMetrics items
        begin
          if !@@isWindows.nil? && @@isWindows == false
            containerGPUusageInsightsMetricsDataItems = []
            containerGPUusageInsightsMetricsDataItems.concat(CAdvisorMetricsAPIClient.getInsightsMetrics(winNode: nil, metricTime: batchTime))

          containerGPUusageInsightsMetricsDataItems.each do |insightsMetricsRecord|
            insightsMetricsEventStream.add(time, insightsMetricsRecord) if insightsMetricsRecord
          end

            router.emit_stream(@insightsmetricstag, insightsMetricsEventStream) if insightsMetricsEventStream
            router.emit_stream(@mdmtag, insightsMetricsEventStream) if insightsMetricsEventStream

            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && insightsMetricsEventStream.count > 0)
              $log.info("cAdvisorInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          end
        rescue => errorStr
          $log.warn "Failed when processing GPU Usage metrics in_cadvisor_perf : #{errorStr}"
          $log.debug_backtrace(errorStr.backtrace)
          ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
        end
        #end GPU InsightsMetrics items

      rescue => errorStr
        $log.warn "Failed to retrieve cadvisor metric data: #{errorStr}"
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
            $log.info("in_cadvisor_perf::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_cadvisor_perf::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_cadvisor_perf::run_periodic: enumerate Failed to retrieve cadvisor perf metrics: #{errorStr}"
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end # CAdvisor_Perf_Input
end # module
