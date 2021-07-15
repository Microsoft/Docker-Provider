#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  class Kube_Kubestate_HPA_Input < Input
    Fluent::Plugin.register_input("kubestate_hpa", self)
    @@istestvar = ENV["ISTEST"]

    def initialize
      super
      require "yajl/json_gem"
      require "yajl"
      require "time"

      require_relative "KubernetesApiClient"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "ApplicationInsightsUtility"
      require_relative "constants"
      require_relative "extension_utils"

      # refer tomlparser-agent-config for defaults
      # this configurable via configmap
      @HPA_CHUNK_SIZE = 0

      @HPA_API_GROUP = "autoscaling"

      # telemetry
      @hpaCount = 0

      @NodeName = OMS::Common.get_hostname
      @ClusterId = KubernetesApiClient.getClusterId
      @ClusterName = KubernetesApiClient.getClusterName
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.INSIGHTS_METRICS_BLOB"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        super
        if !ENV["HPA_CHUNK_SIZE"].nil? && !ENV["HPA_CHUNK_SIZE"].empty? && ENV["HPA_CHUNK_SIZE"].to_i > 0
          @HPA_CHUNK_SIZE = ENV["HPA_CHUNK_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kubestate_hpa::start: setting to default value since got HPA_CHUNK_SIZE nil or empty")
          @HPA_CHUNK_SIZE = 2000
        end
        $log.info("in_kubestate_hpa::start : HPA_CHUNK_SIZE  @ #{@HPA_CHUNK_SIZE}")

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
        super
      end
    end

    def enumerate
      begin
        hpaList = nil
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601

        @hpaCount = 0

        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_kubestate_hpa::enumerate: AAD AUTH MSI MODE")
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::INSIGHTS_METRICS_DATA_TYPE)
          end
	        $log.info("in_kubestate_hpa::enumerate: using tag -#{@tag} @ #{Time.now.utc.iso8601}")
        end
        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kubestate_hpa::enumerate : Getting HPAs from Kube API @ #{Time.now.utc.iso8601}")
        continuationToken, hpaList = KubernetesApiClient.getResourcesAndContinuationToken("horizontalpodautoscalers?limit=#{@HPA_CHUNK_SIZE}", api_group: @HPA_API_GROUP)
        $log.info("in_kubestate_hpa::enumerate : Done getting HPAs from Kube API @ #{Time.now.utc.iso8601}")
        if (!hpaList.nil? && !hpaList.empty? && hpaList.key?("items") && !hpaList["items"].nil? && !hpaList["items"].empty?)
          parse_and_emit_records(hpaList, batchTime)
        else
          $log.warn "in_kubestate_hpa::enumerate:Received empty hpaList"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          continuationToken, hpaList = KubernetesApiClient.getResourcesAndContinuationToken("horizontalpodautoscalers?limit=#{@HPA_CHUNK_SIZE}&continue=#{continuationToken}", api_group: @HPA_API_GROUP)
          if (!hpaList.nil? && !hpaList.empty? && hpaList.key?("items") && !hpaList["items"].nil? && !hpaList["items"].empty?)
            parse_and_emit_records(hpaList, batchTime)
          else
            $log.warn "in_kubestate_hpa::enumerate:Received empty hpaList"
          end
        end

        # Setting this to nil so that we dont hold memory until GC kicks in
        hpaList = nil

        # Flush AppInsights telemetry once all the processing is done, only if the number of events flushed is greater than 0
        if (@hpaCount > 0)
          # this will not be a useful telemetry, as hpa counts will not be huge, just log for now
          $log.info("in_kubestate_hpa::hpaCount= #{hpaCount}")
          #ApplicationInsightsUtility.sendMetricTelemetry("HPACount", @hpaCount, {})
        end
      rescue => errorStr
        $log.warn "in_kubestate_hpa::enumerate:Failed in enumerate: #{errorStr}"
        ApplicationInsightsUtility.sendExceptionTelemetry("in_kubestate_hpa::enumerate:Failed in enumerate: #{errorStr}")
      end
    end # end enumerate

    def parse_and_emit_records(hpas, batchTime = Time.utc.iso8601)
      metricItems = []
      insightsMetricsEventStream = Fluent::MultiEventStream.new
      begin
        metricInfo = hpas
        metricInfo["items"].each do |hpa|
          hpaName = hpa["metadata"]["name"]
          hpaNameSpace = hpa["metadata"]["namespace"]
          hpaCreatedTime = ""
          if !hpa["metadata"]["creationTimestamp"].nil?
            hpaCreatedTime = hpa["metadata"]["creationTimestamp"]
          end
          hpaSpecMinReplicas = 1 #default is 1 as per k8s spec
          if !hpa["spec"]["minReplicas"].nil?
            hpaSpecMinReplicas = hpa["spec"]["minReplicas"]
          end
          hpaSpecMaxReplicas = 0
          if !hpa["spec"]["maxReplicas"].nil?
            hpaSpecMaxReplicas = hpa["spec"]["maxReplicas"]
          end
          hpaSpecScaleTargetKind = ""
          hpaSpecScaleTargetName = ""
          if !hpa["spec"]["scaleTargetRef"].nil?
            if !hpa["spec"]["scaleTargetRef"]["kind"].nil?
              hpaSpecScaleTargetKind = hpa["spec"]["scaleTargetRef"]["kind"]
            end
            if !hpa["spec"]["scaleTargetRef"]["name"].nil?
              hpaSpecScaleTargetName = hpa["spec"]["scaleTargetRef"]["name"]
            end
          end
          hpaStatusCurrentReplicas = 0
          if !hpa["status"]["currentReplicas"].nil?
            hpaStatusCurrentReplicas = hpa["status"]["currentReplicas"]
          end
          hpaStatusDesiredReplicas = 0
          if !hpa["status"]["desiredReplicas"].nil?
            hpaStatusDesiredReplicas = hpa["status"]["desiredReplicas"]
          end

          hpaStatuslastScaleTime = ""
          if !hpa["status"]["lastScaleTime"].nil?
            hpaStatuslastScaleTime = hpa["status"]["lastScaleTime"]
          end

          metricItem = {}
          metricItem["CollectionTime"] = batchTime
          metricItem["Computer"] = @NodeName
          metricItem["Name"] = Constants::INSIGHTSMETRICS_METRIC_NAME_KUBE_STATE_HPA_STATE
          metricItem["Value"] = hpaStatusCurrentReplicas
          metricItem["Origin"] = Constants::INSIGHTSMETRICS_TAGS_ORIGIN
          metricItem["Namespace"] = Constants::INSIGHTSMETRICS_TAGS_KUBESTATE_NAMESPACE

          metricTags = {}
          metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERID] = @ClusterId
          metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERNAME] = @ClusterName
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_NAME] = hpaName
          metricTags[Constants::INSIGHTSMETRICS_TAGS_K8SNAMESPACE] = hpaNameSpace
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_CREATIONTIME] = hpaCreatedTime
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_SPEC_MIN_REPLICAS] = hpaSpecMinReplicas
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_SPEC_MAX_REPLICAS] = hpaSpecMaxReplicas
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_SPEC_SCALE_TARGET_KIND] = hpaSpecScaleTargetKind
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_SPEC_SCALE_TARGET_NAME] = hpaSpecScaleTargetName
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_STATUS_DESIRED_REPLICAS] = hpaStatusDesiredReplicas
          metricTags[Constants::INSIGHTSMETRICS_TAGS_KUBE_STATE_HPA_STATUS_LAST_SCALE_TIME] = hpaStatuslastScaleTime

          metricItem["Tags"] = metricTags

          metricItems.push(metricItem)
        end

        time = Fluent::Engine.now
        metricItems.each do |insightsMetricsRecord|
          insightsMetricsEventStream.add(time, insightsMetricsRecord) if insightsMetricsRecord
        end

        router.emit_stream(@tag, insightsMetricsEventStream) if insightsMetricsEventStream
        $log.info("successfully emitted #{metricItems.length()} kube_state_hpa metrics")
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0 && insightsMetricsEventStream.count > 0)
          $log.info("kubestatehpaInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
      rescue => error
        $log.warn("in_kubestate_hpa::parse_and_emit_records failed: #{error} ")
        ApplicationInsightsUtility.sendExceptionTelemetry("in_kubestate_hpa::parse_and_emit_records failed: #{error}")
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
            $log.info("in_kubestate_hpa::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kubestate_hpa::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kubestate_hpa::run_periodic: enumerate Failed to retrieve kube hpas: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry("in_kubestate_hpa::run_periodic: enumerate Failed to retrieve kube hpas: #{errorStr}")
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end
  end
end
