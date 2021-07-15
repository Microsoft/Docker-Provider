#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  require_relative "podinventory_to_mdm"

  class Kube_PodInventory_Input < Input
    Fluent::Plugin.register_input("kube_podinventory", self)

    @@MDMKubePodInventoryTag = "mdm.kubepodinventory"
    @@hostName = (OMS::Common.get_hostname)


    def initialize
      super
      require "yaml"
      require "yajl/json_gem"
      require "yajl"
      require "set"
      require "time"

      require_relative "kubernetes_container_inventory"
      require_relative "KubernetesApiClient"
      require_relative "ApplicationInsightsUtility"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "constants"
      require_relative "extension_utils"

      # refer tomlparser-agent-config for updating defaults
      # this configurable via configmap
      @PODS_CHUNK_SIZE = 0
      @PODS_EMIT_STREAM_BATCH_SIZE = 0

      @podCount = 0
      @serviceCount = 0
      @controllerSet = Set.new []
      @winContainerCount = 0
      @controllerData = {}
      @podInventoryE2EProcessingLatencyMs = 0
      @podsAPIE2ELatencyMs = 0

      @kubeperfTag = "oneagent.containerInsights.LINUX_PERF_BLOB"
      @kubeservicesTag = "oneagent.containerInsights.KUBE_SERVICES_BLOB"
      @containerInventoryTag = "oneagent.containerInsights.CONTAINER_INVENTORY_BLOB"
      @insightsMetricsTag = "oneagent.containerInsights.INSIGHTS_METRICS_BLOB"
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.KUBE_POD_INVENTORY_BLOB"

    def configure(conf)
      super
      @inventoryToMdmConvertor = Inventory2MdmConvertor.new()
    end

    def start
      if @run_interval
        super
        if !ENV["PODS_CHUNK_SIZE"].nil? && !ENV["PODS_CHUNK_SIZE"].empty? && ENV["PODS_CHUNK_SIZE"].to_i > 0
          @PODS_CHUNK_SIZE = ENV["PODS_CHUNK_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kube_podinventory::start: setting to default value since got PODS_CHUNK_SIZE nil or empty")
          @PODS_CHUNK_SIZE = 1000
        end
        $log.info("in_kube_podinventory::start: PODS_CHUNK_SIZE  @ #{@PODS_CHUNK_SIZE}")

        if !ENV["PODS_EMIT_STREAM_BATCH_SIZE"].nil? && !ENV["PODS_EMIT_STREAM_BATCH_SIZE"].empty? && ENV["PODS_EMIT_STREAM_BATCH_SIZE"].to_i > 0
          @PODS_EMIT_STREAM_BATCH_SIZE = ENV["PODS_EMIT_STREAM_BATCH_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kube_podinventory::start: setting to default value since got PODS_EMIT_STREAM_BATCH_SIZE nil or empty")
          @PODS_EMIT_STREAM_BATCH_SIZE = 200
        end
        $log.info("in_kube_podinventory::start: PODS_EMIT_STREAM_BATCH_SIZE  @ #{@PODS_EMIT_STREAM_BATCH_SIZE}")
        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@podTelemetryTimeTracker = DateTime.now.to_time.to_i
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

    def enumerate(podList = nil)
      begin
        podInventory = podList
        telemetryFlush = false
        @podCount = 0
        @serviceCount = 0
        @controllerSet = Set.new []
        @winContainerCount = 0
        @controllerData = {}
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601
        serviceRecords = []
        @podInventoryE2EProcessingLatencyMs = 0
        podInventoryStartTime = (Time.now.to_f * 1000).to_i
        if ExtensionUtils.isAADMSIAuthMode()
           $log.info("in_kube_podinventory::enumerate: AAD AUTH MSI MODE")
           if @kubeperfTag.nil? || !@kubeperfTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
             @kubeperfTag = ExtensionUtils.getOutputStreamId(Constants::PERF_DATA_TYPE)
           end
           if @kubeservicesTag.nil? || !@kubeservicesTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
             @kubeservicesTag = ExtensionUtils.getOutputStreamId(Constants::KUBE_SERVICES_DATA_TYPE)
           end
           if @containerInventoryTag.nil? || !@containerInventoryTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
             @containerInventoryTag = ExtensionUtils.getOutputStreamId(Constants::CONTAINER_INVENTORY_DATA_TYPE)
           end
           if @insightsMetricsTag.nil? || !@insightsMetricsTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
             @insightsMetricsTag = ExtensionUtils.getOutputStreamId(Constants::INSIGHTS_METRICS_DATA_TYPE)
           end
           if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
             @tag = ExtensionUtils.getOutputStreamId(Constants::KUBE_POD_INVENTORY_DATA_TYPE)
           end
	         $log.info("in_kube_podinventory::enumerate: using perf tag -#{@kubeperfTag} @ #{Time.now.utc.iso8601}")
           $log.info("in_kube_podinventory::enumerate: using kubeservices tag -#{@kubeservicesTag} @ #{Time.now.utc.iso8601}")
           $log.info("in_kube_podinventory::enumerate: using containerinventory tag -#{@containerInventoryTag} @ #{Time.now.utc.iso8601}")
           $log.info("in_kube_podinventory::enumerate: using insightsmetrics tag -#{@insightsMetricsTag} @ #{Time.now.utc.iso8601}")
           $log.info("in_kube_podinventory::enumerate: using kubepodinventory tag -#{@tag} @ #{Time.now.utc.iso8601}")
        end

        # Get services first so that we dont need to make a call for very chunk
        $log.info("in_kube_podinventory::enumerate : Getting services from Kube API @ #{Time.now.utc.iso8601}")
        serviceInfo = KubernetesApiClient.getKubeResourceInfo("services")
        # serviceList = JSON.parse(KubernetesApiClient.getKubeResourceInfo("services").body)
        $log.info("in_kube_podinventory::enumerate : Done getting services from Kube API @ #{Time.now.utc.iso8601}")

        if !serviceInfo.nil?
          $log.info("in_kube_podinventory::enumerate:Start:Parsing services data using yajl @ #{Time.now.utc.iso8601}")
          serviceList = Yajl::Parser.parse(StringIO.new(serviceInfo.body))
          $log.info("in_kube_podinventory::enumerate:End:Parsing services data using yajl @ #{Time.now.utc.iso8601}")
          serviceInfo = nil
          # service inventory records much smaller and fixed size compared to serviceList
          serviceRecords = KubernetesApiClient.getKubeServicesInventoryRecords(serviceList, batchTime)
          # updating for telemetry
          @serviceCount += serviceRecords.length
          serviceList = nil
        end

        # to track e2e processing latency
        @podsAPIE2ELatencyMs = 0
        podsAPIChunkStartTime = (Time.now.to_f * 1000).to_i
        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kube_podinventory::enumerate : Getting pods from Kube API @ #{Time.now.utc.iso8601}")
        continuationToken, podInventory = KubernetesApiClient.getResourcesAndContinuationToken("pods?limit=#{@PODS_CHUNK_SIZE}")
        $log.info("in_kube_podinventory::enumerate : Done getting pods from Kube API @ #{Time.now.utc.iso8601}")
        podsAPIChunkEndTime = (Time.now.to_f * 1000).to_i
        @podsAPIE2ELatencyMs = (podsAPIChunkEndTime - podsAPIChunkStartTime)
        if (!podInventory.nil? && !podInventory.empty? && podInventory.key?("items") && !podInventory["items"].nil? && !podInventory["items"].empty?)
          $log.info("in_kube_podinventory::enumerate : number of pod items :#{podInventory["items"].length}  from Kube API @ #{Time.now.utc.iso8601}")
          parse_and_emit_records(podInventory, serviceRecords, continuationToken, batchTime)
        else
          $log.warn "in_kube_podinventory::enumerate:Received empty podInventory"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          podsAPIChunkStartTime = (Time.now.to_f * 1000).to_i
          continuationToken, podInventory = KubernetesApiClient.getResourcesAndContinuationToken("pods?limit=#{@PODS_CHUNK_SIZE}&continue=#{continuationToken}")
          podsAPIChunkEndTime = (Time.now.to_f * 1000).to_i
          @podsAPIE2ELatencyMs = @podsAPIE2ELatencyMs + (podsAPIChunkEndTime - podsAPIChunkStartTime)
          if (!podInventory.nil? && !podInventory.empty? && podInventory.key?("items") && !podInventory["items"].nil? && !podInventory["items"].empty?)
            $log.info("in_kube_podinventory::enumerate : number of pod items :#{podInventory["items"].length} from Kube API @ #{Time.now.utc.iso8601}")
            parse_and_emit_records(podInventory, serviceRecords, continuationToken, batchTime)
          else
            $log.warn "in_kube_podinventory::enumerate:Received empty podInventory"
          end
        end

        @podInventoryE2EProcessingLatencyMs = ((Time.now.to_f * 1000).to_i - podInventoryStartTime)
        # Setting these to nil so that we dont hold memory until GC kicks in
        podInventory = nil
        serviceRecords = nil

        # Adding telemetry to send pod telemetry every 5 minutes
        timeDifference = (DateTime.now.to_time.to_i - @@podTelemetryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= 5)
          telemetryFlush = true
        end

        # Flush AppInsights telemetry once all the processing is done
        if telemetryFlush == true
          telemetryProperties = {}
          telemetryProperties["Computer"] = @@hostName
          telemetryProperties["PODS_CHUNK_SIZE"] = @PODS_CHUNK_SIZE
          telemetryProperties["PODS_EMIT_STREAM_BATCH_SIZE"] = @PODS_EMIT_STREAM_BATCH_SIZE
          ApplicationInsightsUtility.sendCustomEvent("KubePodInventoryHeartBeatEvent", telemetryProperties)
          ApplicationInsightsUtility.sendMetricTelemetry("PodCount", @podCount, {})
          ApplicationInsightsUtility.sendMetricTelemetry("ServiceCount", @serviceCount, {})
          telemetryProperties["ControllerData"] = @controllerData.to_json
          ApplicationInsightsUtility.sendMetricTelemetry("ControllerCount", @controllerSet.length, telemetryProperties)
          if @winContainerCount > 0
            telemetryProperties["ClusterWideWindowsContainersCount"] = @winContainerCount
            ApplicationInsightsUtility.sendCustomEvent("WindowsContainerInventoryEvent", telemetryProperties)
          end
          ApplicationInsightsUtility.sendMetricTelemetry("PodInventoryE2EProcessingLatencyMs", @podInventoryE2EProcessingLatencyMs, telemetryProperties)
          ApplicationInsightsUtility.sendMetricTelemetry("PodsAPIE2ELatencyMs", @podsAPIE2ELatencyMs, telemetryProperties)
          @@podTelemetryTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => errorStr
        $log.warn "in_kube_podinventory::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end

    def parse_and_emit_records(podInventory, serviceRecords, continuationToken, batchTime = Time.utc.iso8601)
      currentTime = Time.now
      emitTime = Fluent::Engine.now
      #batchTime = currentTime.utc.iso8601
      eventStream = Fluent::MultiEventStream.new
      containerInventoryStream = Fluent::MultiEventStream.new
      kubePerfEventStream = Fluent::MultiEventStream.new
      insightsMetricsEventStream = Fluent::MultiEventStream.new
      @@istestvar = ENV["ISTEST"]

      begin #begin block start
        # Getting windows nodes from kubeapi
        winNodes = KubernetesApiClient.getWindowsNodesArray
        podInventory["items"].each do |item| #podInventory block start
          # pod inventory records
          podInventoryRecords = getPodInventoryRecords(item, serviceRecords, batchTime)
          podInventoryRecords.each do |record|
            if !record.nil?
              eventStream.add(emitTime, record) if record
              @inventoryToMdmConvertor.process_pod_inventory_record(record)
            end
          end
          # Setting this flag to true so that we can send ContainerInventory records for containers
          # on windows nodes and parse environment variables for these containers
          if winNodes.length > 0
            nodeName = ""
            if !item["spec"]["nodeName"].nil?
              nodeName = item["spec"]["nodeName"]
            end
            if (!nodeName.empty? && (winNodes.include? nodeName))
              clusterCollectEnvironmentVar = ENV["AZMON_CLUSTER_COLLECT_ENV_VAR"]
              #Generate ContainerInventory records for windows nodes so that we can get image and image tag in property panel
              containerInventoryRecords = KubernetesContainerInventory.getContainerInventoryRecords(item, batchTime, clusterCollectEnvironmentVar, true)
              # Send container inventory records for containers on windows nodes
              @winContainerCount += containerInventoryRecords.length
              containerInventoryRecords.each do |cirecord|
                if !cirecord.nil?
                  containerInventoryStream.add(emitTime, cirecord) if cirecord
                end
              end
            end
          end

          if @PODS_EMIT_STREAM_BATCH_SIZE > 0 && eventStream.count >= @PODS_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_podinventory::parse_and_emit_records: number of pod inventory records emitted #{@PODS_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubePodInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
            router.emit_stream(@tag, eventStream) if eventStream
            eventStream = Fluent::MultiEventStream.new
          end

          #container perf records
          containerMetricDataItems = []
          containerMetricDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimits(item, "requests", "cpu", "cpuRequestNanoCores", batchTime))
          containerMetricDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimits(item, "requests", "memory", "memoryRequestBytes", batchTime))
          containerMetricDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimits(item, "limits", "cpu", "cpuLimitNanoCores", batchTime))
          containerMetricDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimits(item, "limits", "memory", "memoryLimitBytes", batchTime))

          containerMetricDataItems.each do |record|
            kubePerfEventStream.add(emitTime, record) if record
          end

          if @PODS_EMIT_STREAM_BATCH_SIZE > 0 && kubePerfEventStream.count >= @PODS_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_podinventory::parse_and_emit_records: number of container perf records emitted #{@PODS_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@kubeperfTag, kubePerfEventStream) if kubePerfEventStream
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubeContainerPerfEventEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
            kubePerfEventStream = Fluent::MultiEventStream.new
          end

          # container GPU records
          containerGPUInsightsMetricsDataItems = []
          containerGPUInsightsMetricsDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimitsAsInsightsMetrics(item, "requests", "nvidia.com/gpu", "containerGpuRequests", batchTime))
          containerGPUInsightsMetricsDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimitsAsInsightsMetrics(item, "limits", "nvidia.com/gpu", "containerGpuLimits", batchTime))
          containerGPUInsightsMetricsDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimitsAsInsightsMetrics(item, "requests", "amd.com/gpu", "containerGpuRequests", batchTime))
          containerGPUInsightsMetricsDataItems.concat(KubernetesApiClient.getContainerResourceRequestsAndLimitsAsInsightsMetrics(item, "limits", "amd.com/gpu", "containerGpuLimits", batchTime))
          containerGPUInsightsMetricsDataItems.each do |insightsMetricsRecord|
            insightsMetricsEventStream.add(emitTime, insightsMetricsRecord) if insightsMetricsRecord
          end

          if @PODS_EMIT_STREAM_BATCH_SIZE > 0 && insightsMetricsEventStream.count >= @PODS_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_podinventory::parse_and_emit_records: number of GPU insights metrics records emitted #{@PODS_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubePodInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
            router.emit_stream(@insightsMetricsTag, insightsMetricsEventStream) if insightsMetricsEventStream
            insightsMetricsEventStream = Fluent::MultiEventStream.new
          end
        end  #podInventory block end

        if eventStream.count > 0
          $log.info("in_kube_podinventory::parse_and_emit_records: number of pod inventory records emitted #{eventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@tag, eventStream) if eventStream
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubePodInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
          eventStream = nil
        end

        if containerInventoryStream.count > 0
          $log.info("in_kube_podinventory::parse_and_emit_records: number of windows container inventory records emitted #{containerInventoryStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@containerInventoryTag, containerInventoryStream) if containerInventoryStream
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubeWindowsContainerInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
          containerInventoryStream = nil
        end

        if kubePerfEventStream.count > 0
          $log.info("in_kube_podinventory::parse_and_emit_records: number of perf records emitted #{kubePerfEventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@kubeperfTag, kubePerfEventStream) if kubePerfEventStream
          kubePerfEventStream = nil
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubeContainerPerfEventEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
        end

        if insightsMetricsEventStream.count > 0
          $log.info("in_kube_podinventory::parse_and_emit_records: number of insights metrics records emitted #{insightsMetricsEventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@insightsMetricsTag, insightsMetricsEventStream) if insightsMetricsEventStream
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubePodInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
          insightsMetricsEventStream = nil
        end

        if continuationToken.nil? #no more chunks in this batch to be sent, get all mdm pod inventory records to send
          @log.info "Sending pod inventory mdm records to out_mdm"
          pod_inventory_mdm_records = @inventoryToMdmConvertor.get_pod_inventory_mdm_records(batchTime)
          @log.info "pod_inventory_mdm_records.size #{pod_inventory_mdm_records.size}"
          mdm_pod_inventory_es = Fluent::MultiEventStream.new
          pod_inventory_mdm_records.each { |pod_inventory_mdm_record|
            mdm_pod_inventory_es.add(batchTime, pod_inventory_mdm_record) if pod_inventory_mdm_record
          } if pod_inventory_mdm_records
          router.emit_stream(@@MDMKubePodInventoryTag, mdm_pod_inventory_es) if mdm_pod_inventory_es
        end

        if continuationToken.nil? # sending kube services inventory records
          kubeServicesEventStream = Fluent::MultiEventStream.new
          serviceRecords.each do |kubeServiceRecord|
            if !kubeServiceRecord.nil?
              # adding before emit to reduce memory foot print
              kubeServiceRecord["ClusterId"] = KubernetesApiClient.getClusterId
              kubeServiceRecord["ClusterName"] = KubernetesApiClient.getClusterName
              kubeServicesEventStream.add(emitTime, kubeServiceRecord) if kubeServiceRecord
              if @PODS_EMIT_STREAM_BATCH_SIZE > 0 && kubeServicesEventStream.count >= @PODS_EMIT_STREAM_BATCH_SIZE
                $log.info("in_kube_podinventory::parse_and_emit_records: number of service records emitted #{@PODS_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
                router.emit_stream(@kubeservicesTag, kubeServicesEventStream) if kubeServicesEventStream
                kubeServicesEventStream = Fluent::MultiEventStream.new
                if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
                  $log.info("kubeServicesEventEmitStreamSuccess @ #{Time.now.utc.iso8601}")
                end
              end
            end
          end

          if kubeServicesEventStream.count > 0
            $log.info("in_kube_podinventory::parse_and_emit_records : number of service records emitted #{kubeServicesEventStream.count} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@kubeservicesTag, kubeServicesEventStream) if kubeServicesEventStream
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubeServicesEventEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          end
          kubeServicesEventStream = nil
        end

        #Updating value for AppInsights telemetry
        @podCount += podInventory["items"].length
      rescue => errorStr
        $log.warn "Failed in parse_and_emit_record pod inventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end #begin block end
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
            $log.info("in_kube_podinventory::run_periodic.enumerate.start #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_podinventory::run_periodic.enumerate.end #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_podinventory::run_periodic: enumerate Failed to retrieve pod inventory: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    # TODO - move this method to KubernetesClient or helper class
    def getPodInventoryRecords(item, serviceRecords, batchTime = Time.utc.iso8601)
      records = []
      record = {}

      begin
        record["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
        record["Name"] = item["metadata"]["name"]
        podNameSpace = item["metadata"]["namespace"]
        podUid = KubernetesApiClient.getPodUid(podNameSpace, item["metadata"])
        if podUid.nil?
          return records
        end

        nodeName = ""
        #for unscheduled (non-started) pods nodeName does NOT exist
        if !item["spec"]["nodeName"].nil?
          nodeName = item["spec"]["nodeName"]
        end
        # For ARO v3 cluster, skip the pods scheduled on to master or infra nodes
        if KubernetesApiClient.isAROv3MasterOrInfraPod(nodeName)
          return records
        end

        record["PodUid"] = podUid
        record["PodLabel"] = [item["metadata"]["labels"]]
        record["Namespace"] = podNameSpace
        record["PodCreationTimeStamp"] = item["metadata"]["creationTimestamp"]
        #for unscheduled (non-started) pods startTime does NOT exist
        if !item["status"]["startTime"].nil?
          record["PodStartTime"] = item["status"]["startTime"]
        else
          record["PodStartTime"] = ""
        end
        #podStatus
        # the below is for accounting 'NodeLost' scenario, where-in the pod(s) in the lost node is still being reported as running
        podReadyCondition = true
        if !item["status"]["reason"].nil? && item["status"]["reason"] == "NodeLost" && !item["status"]["conditions"].nil?
          item["status"]["conditions"].each do |condition|
            if condition["type"] == "Ready" && condition["status"] == "False"
              podReadyCondition = false
              break
            end
          end
        end
        if podReadyCondition == false
          record["PodStatus"] = "Unknown"
          # ICM - https://portal.microsofticm.com/imp/v3/incidents/details/187091803/home
        elsif !item["metadata"]["deletionTimestamp"].nil? && !item["metadata"]["deletionTimestamp"].empty?
          record["PodStatus"] = Constants::POD_STATUS_TERMINATING
        else
          record["PodStatus"] = item["status"]["phase"]
        end
        #for unscheduled (non-started) pods podIP does NOT exist
        if !item["status"]["podIP"].nil?
          record["PodIp"] = item["status"]["podIP"]
        else
          record["PodIp"] = ""
        end

        record["Computer"] = nodeName
        record["ClusterId"] = KubernetesApiClient.getClusterId
        record["ClusterName"] = KubernetesApiClient.getClusterName
        record["ServiceName"] = getServiceNameFromLabels(item["metadata"]["namespace"], item["metadata"]["labels"], serviceRecords)

        if !item["metadata"]["ownerReferences"].nil?
          record["ControllerKind"] = item["metadata"]["ownerReferences"][0]["kind"]
          record["ControllerName"] = item["metadata"]["ownerReferences"][0]["name"]
          @controllerSet.add(record["ControllerKind"] + record["ControllerName"])
          #Adding controller kind to telemetry ro information about customer workload
          if (@controllerData[record["ControllerKind"]].nil?)
            @controllerData[record["ControllerKind"]] = 1
          else
            controllerValue = @controllerData[record["ControllerKind"]]
            @controllerData[record["ControllerKind"]] += 1
          end
        end
        podRestartCount = 0
        record["PodRestartCount"] = 0

        #Invoke the helper method to compute ready/not ready mdm metric
        @inventoryToMdmConvertor.process_record_for_pods_ready_metric(record["ControllerName"], record["Namespace"], item["status"]["conditions"])

        podContainers = []
        if item["status"].key?("containerStatuses") && !item["status"]["containerStatuses"].empty?
          podContainers = podContainers + item["status"]["containerStatuses"]
        end
        # Adding init containers to the record list as well.
        if item["status"].key?("initContainerStatuses") && !item["status"]["initContainerStatuses"].empty?
          podContainers = podContainers + item["status"]["initContainerStatuses"]
        end
        # if items["status"].key?("containerStatuses") && !items["status"]["containerStatuses"].empty? #container status block start
        if !podContainers.empty? #container status block start
          podContainers.each do |container|
            containerRestartCount = 0
            lastFinishedTime = nil
            # Need this flag to determine if we need to process container data for mdm metrics like oomkilled and container restart
            #container Id is of the form
            #docker://dfd9da983f1fd27432fb2c1fe3049c0a1d25b1c697b2dc1a530c986e58b16527
            if !container["containerID"].nil?
              record["ContainerID"] = container["containerID"].split("//")[1]
            else
              # for containers that have image issues (like invalid image/tag etc..) this will be empty. do not make it all 0
              record["ContainerID"] = ""
            end
            #keeping this as <PodUid/container_name> which is same as InstanceName in perf table
            if podUid.nil? || container["name"].nil?
              next
            else
              record["ContainerName"] = podUid + "/" + container["name"]
            end
            #Pod restart count is a sumtotal of restart counts of individual containers
            #within the pod. The restart count of a container is maintained by kubernetes
            #itself in the form of a container label.
            containerRestartCount = container["restartCount"]
            record["ContainerRestartCount"] = containerRestartCount

            containerStatus = container["state"]
            record["ContainerStatusReason"] = ""
            # state is of the following form , so just picking up the first key name
            # "state": {
            #   "waiting": {
            #     "reason": "CrashLoopBackOff",
            #      "message": "Back-off 5m0s restarting failed container=metrics-server pod=metrics-server-2011498749-3g453_kube-system(5953be5f-fcae-11e7-a356-000d3ae0e432)"
            #   }
            # },
            # the below is for accounting 'NodeLost' scenario, where-in the containers in the lost node/pod(s) is still being reported as running
            if podReadyCondition == false
              record["ContainerStatus"] = "Unknown"
            else
              record["ContainerStatus"] = containerStatus.keys[0]
            end
            #TODO : Remove ContainerCreationTimeStamp from here since we are sending it as a metric
            #Picking up both container and node start time from cAdvisor to be consistent
            if containerStatus.keys[0] == "running"
              record["ContainerCreationTimeStamp"] = container["state"]["running"]["startedAt"]
            else
              if !containerStatus[containerStatus.keys[0]]["reason"].nil? && !containerStatus[containerStatus.keys[0]]["reason"].empty?
                record["ContainerStatusReason"] = containerStatus[containerStatus.keys[0]]["reason"]
              end
              # Process the record to see if job was completed 6 hours ago. If so, send metric to mdm
              if !record["ControllerKind"].nil? && record["ControllerKind"].downcase == Constants::CONTROLLER_KIND_JOB
                @inventoryToMdmConvertor.process_record_for_terminated_job_metric(record["ControllerName"], record["Namespace"], containerStatus)
              end
            end

            # Record the last state of the container. This may have information on why a container was killed.
            begin
              if !container["lastState"].nil? && container["lastState"].keys.length == 1
                lastStateName = container["lastState"].keys[0]
                lastStateObject = container["lastState"][lastStateName]
                if !lastStateObject.is_a?(Hash)
                  raise "expected a hash object. This could signify a bug or a kubernetes API change"
                end

                if lastStateObject.key?("reason") && lastStateObject.key?("startedAt") && lastStateObject.key?("finishedAt")
                  newRecord = Hash.new
                  newRecord["lastState"] = lastStateName  # get the name of the last state (ex: terminated)
                  lastStateReason = lastStateObject["reason"]
                  # newRecord["reason"] = lastStateObject["reason"]  # (ex: OOMKilled)
                  newRecord["reason"] = lastStateReason  # (ex: OOMKilled)
                  newRecord["startedAt"] = lastStateObject["startedAt"]  # (ex: 2019-07-02T14:58:51Z)
                  lastFinishedTime = lastStateObject["finishedAt"]
                  newRecord["finishedAt"] = lastFinishedTime  # (ex: 2019-07-02T14:58:52Z)

                  # only write to the output field if everything previously ran without error
                  record["ContainerLastStatus"] = newRecord

                  #Populate mdm metric for OOMKilled container count if lastStateReason is OOMKilled
                  if lastStateReason.downcase == Constants::REASON_OOM_KILLED
                    @inventoryToMdmConvertor.process_record_for_oom_killed_metric(record["ControllerName"], record["Namespace"], lastFinishedTime)
                  end
                  lastStateReason = nil
                else
                  record["ContainerLastStatus"] = Hash.new
                end
              else
                record["ContainerLastStatus"] = Hash.new
              end

              #Populate mdm metric for container restart count if greater than 0
              if (!containerRestartCount.nil? && (containerRestartCount.is_a? Integer) && containerRestartCount > 0)
                @inventoryToMdmConvertor.process_record_for_container_restarts_metric(record["ControllerName"], record["Namespace"], lastFinishedTime)
              end
            rescue => errorStr
              $log.warn "Failed in parse_and_emit_record pod inventory while processing ContainerLastStatus: #{errorStr}"
              $log.debug_backtrace(errorStr.backtrace)
              ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
              record["ContainerLastStatus"] = Hash.new
            end

            podRestartCount += containerRestartCount
            records.push(record.dup)
          end
        else # for unscheduled pods there are no status.containerStatuses, in this case we still want the pod
          records.push(record)
        end  #container status block end

        records.each do |record|
          if !record.nil?
            record["PodRestartCount"] = podRestartCount
          end
        end
      rescue => error
        $log.warn("getPodInventoryRecords failed: #{error}")
      end
      return records
    end

    # TODO - move this method to KubernetesClient or helper class
    def getServiceNameFromLabels(namespace, labels, serviceRecords)
      serviceName = ""
      begin
        if !labels.nil? && !labels.empty?
          serviceRecords.each do |kubeServiceRecord|
            found = 0
            if kubeServiceRecord["Namespace"] == namespace
              selectorLabels = {}
              # selector labels wrapped in array in kube service records so unwrapping here
              if !kubeServiceRecord["SelectorLabels"].nil? && kubeServiceRecord["SelectorLabels"].length > 0
                selectorLabels = kubeServiceRecord["SelectorLabels"][0]
              end
              if !selectorLabels.nil? && !selectorLabels.empty?
                selectorLabels.each do |key, value|
                  if !(labels.select { |k, v| k == key && v == value }.length > 0)
                    break
                  end
                  found = found + 1
                end
                # service can have no selectors
                if found == selectorLabels.length
                  return kubeServiceRecord["ServiceName"]
                end
              end
            end
          end
        end
      rescue => errorStr
        $log.warn "Failed to retrieve service name from labels: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      return serviceName
    end
  end # Kube_Pod_Input
end # module
