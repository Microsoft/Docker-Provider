#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  class Kube_nodeInventory_Input < Input
    Fluent::Plugin.register_input("kube_nodes", self)

    @@configMapMountPath = "/etc/config/settings/log-data-collection-settings"
    @@promConfigMountPath = "/etc/config/settings/prometheus-data-collection-settings"
    @@osmConfigMountPath = "/etc/config/osm-settings/osm-metric-collection-configuration"
    @@AzStackCloudFileName = "/etc/kubernetes/host/azurestackcloud.json"


    @@rsPromInterval = ENV["TELEMETRY_RS_PROM_INTERVAL"]
    @@rsPromFieldPassCount = ENV["TELEMETRY_RS_PROM_FIELDPASS_LENGTH"]
    @@rsPromFieldDropCount = ENV["TELEMETRY_RS_PROM_FIELDDROP_LENGTH"]
    @@rsPromK8sServiceCount = ENV["TELEMETRY_RS_PROM_K8S_SERVICES_LENGTH"]
    @@rsPromUrlCount = ENV["TELEMETRY_RS_PROM_URLS_LENGTH"]
    @@rsPromMonitorPods = ENV["TELEMETRY_RS_PROM_MONITOR_PODS"]
    @@rsPromMonitorPodsNamespaceLength = ENV["TELEMETRY_RS_PROM_MONITOR_PODS_NS_LENGTH"]
    @@rsPromMonitorPodsLabelSelectorLength = ENV["TELEMETRY_RS_PROM_LABEL_SELECTOR_LENGTH"]
    @@rsPromMonitorPodsFieldSelectorLength = ENV["TELEMETRY_RS_PROM_FIELD_SELECTOR_LENGTH"]
    @@collectAllKubeEvents = ENV["AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS"]
    @@osmNamespaceCount = ENV["TELEMETRY_OSM_CONFIGURATION_NAMESPACES_COUNT"]

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
      require_relative "extension_utils"

      @ContainerNodeInventoryTag = "oneagent.containerInsights.CONTAINER_NODE_INVENTORY_BLOB"
      @insightsMetricsTag = "oneagent.containerInsights.INSIGHTS_METRICS_BLOB"
      @MDMKubeNodeInventoryTag = "mdm.kubenodeinventory"
      @kubeperfTag = "oneagent.containerInsights.LINUX_PERF_BLOB"

      # refer tomlparser-agent-config for the defaults
      @NODES_CHUNK_SIZE = 0
      @NODES_EMIT_STREAM_BATCH_SIZE = 0

      @nodeInventoryE2EProcessingLatencyMs = 0
      @nodesAPIE2ELatencyMs = 0
      require_relative "constants"

      @NodeCache = NodeStatsCache.new()
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.KUBE_NODE_INVENTORY_BLOB"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        super
        if !ENV["NODES_CHUNK_SIZE"].nil? && !ENV["NODES_CHUNK_SIZE"].empty? && ENV["NODES_CHUNK_SIZE"].to_i > 0
          @NODES_CHUNK_SIZE = ENV["NODES_CHUNK_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kube_nodes::start: setting to default value since got NODES_CHUNK_SIZE nil or empty")
          @NODES_CHUNK_SIZE = 250
        end
        $log.info("in_kube_nodes::start : NODES_CHUNK_SIZE  @ #{@NODES_CHUNK_SIZE}")

        if !ENV["NODES_EMIT_STREAM_BATCH_SIZE"].nil? && !ENV["NODES_EMIT_STREAM_BATCH_SIZE"].empty? && ENV["NODES_EMIT_STREAM_BATCH_SIZE"].to_i > 0
          @NODES_EMIT_STREAM_BATCH_SIZE = ENV["NODES_EMIT_STREAM_BATCH_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kube_nodes::start: setting to default value since got NODES_EMIT_STREAM_BATCH_SIZE nil or empty")
          @NODES_EMIT_STREAM_BATCH_SIZE = 100
        end
        $log.info("in_kube_nodes::start : NODES_EMIT_STREAM_BATCH_SIZE  @ #{@NODES_EMIT_STREAM_BATCH_SIZE}")

        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
        @@nodeInventoryLatencyTelemetryTimeTracker = DateTime.now.to_time.to_i
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
      begin
        nodeInventory = nil
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601

        @nodesAPIE2ELatencyMs = 0
        @nodeInventoryE2EProcessingLatencyMs = 0
        nodeInventoryStartTime = (Time.now.to_f * 1000).to_i

        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_kube_nodes::enumerate: AAD AUTH MSI MODE")
          if @kubeperfTag.nil? || !@kubeperfTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @kubeperfTag = ExtensionUtils.getOutputStreamId(Constants::PERF_DATA_TYPE)
          end
          if @insightsMetricsTag.nil? || !@insightsMetricsTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @insightsMetricsTag = ExtensionUtils.getOutputStreamId(Constants::INSIGHTS_METRICS_DATA_TYPE)
          end
          if @ContainerNodeInventoryTag.nil? || !@ContainerNodeInventoryTag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @ContainerNodeInventoryTag = ExtensionUtils.getOutputStreamId(Constants::CONTAINER_NODE_INVENTORY_DATA_TYPE)
          end
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::KUBE_NODE_INVENTORY_DATA_TYPE)
          end
	        $log.info("in_kube_nodes::enumerate: using perf tag -#{@kubeperfTag} @ #{Time.now.utc.iso8601}")
          $log.info("in_kube_nodes::enumerate: using insightsmetrics tag -#{@insightsMetricsTag} @ #{Time.now.utc.iso8601}")
          $log.info("in_kube_nodes::enumerate: using containernodeinventory tag -#{@ContainerNodeInventoryTag} @ #{Time.now.utc.iso8601}")
          $log.info("in_kube_nodes::enumerate: using kubenodeinventory tag -#{@tag} @ #{Time.now.utc.iso8601}")
        end
        nodesAPIChunkStartTime = (Time.now.to_f * 1000).to_i

        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kube_nodes::enumerate : Getting nodes from Kube API @ #{Time.now.utc.iso8601}")
        resourceUri = KubernetesApiClient.getNodesResourceUri("nodes?limit=#{@NODES_CHUNK_SIZE}")
        continuationToken, nodeInventory = KubernetesApiClient.getResourcesAndContinuationToken(resourceUri)
        $log.info("in_kube_nodes::enumerate : Done getting nodes from Kube API @ #{Time.now.utc.iso8601}")
        nodesAPIChunkEndTime = (Time.now.to_f * 1000).to_i
        @nodesAPIE2ELatencyMs = (nodesAPIChunkEndTime - nodesAPIChunkStartTime)
        if (!nodeInventory.nil? && !nodeInventory.empty? && nodeInventory.key?("items") && !nodeInventory["items"].nil? && !nodeInventory["items"].empty?)
          $log.info("in_kube_nodes::enumerate : number of node items :#{nodeInventory["items"].length} from Kube API @ #{Time.now.utc.iso8601}")
          parse_and_emit_records(nodeInventory, batchTime)
        else
          $log.warn "in_kube_nodes::enumerate:Received empty nodeInventory"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          nodesAPIChunkStartTime = (Time.now.to_f * 1000).to_i
          continuationToken, nodeInventory = KubernetesApiClient.getResourcesAndContinuationToken(resourceUri + "&continue=#{continuationToken}")
          nodesAPIChunkEndTime = (Time.now.to_f * 1000).to_i
          @nodesAPIE2ELatencyMs = @nodesAPIE2ELatencyMs + (nodesAPIChunkEndTime - nodesAPIChunkStartTime)
          if (!nodeInventory.nil? && !nodeInventory.empty? && nodeInventory.key?("items") && !nodeInventory["items"].nil? && !nodeInventory["items"].empty?)
            $log.info("in_kube_nodes::enumerate : number of node items :#{nodeInventory["items"].length} from Kube API @ #{Time.now.utc.iso8601}")
            parse_and_emit_records(nodeInventory, batchTime)
          else
            $log.warn "in_kube_nodes::enumerate:Received empty nodeInventory"
          end
        end

        @nodeInventoryE2EProcessingLatencyMs = ((Time.now.to_f * 1000).to_i - nodeInventoryStartTime)
        timeDifference = (DateTime.now.to_time.to_i - @@nodeInventoryLatencyTelemetryTimeTracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
          ApplicationInsightsUtility.sendMetricTelemetry("NodeInventoryE2EProcessingLatencyMs", @nodeInventoryE2EProcessingLatencyMs, {})
          ApplicationInsightsUtility.sendMetricTelemetry("NodesAPIE2ELatencyMs", @nodesAPIE2ELatencyMs, {})
          @@nodeInventoryLatencyTelemetryTimeTracker = DateTime.now.to_time.to_i
        end
        # Setting this to nil so that we dont hold memory until GC kicks in
        nodeInventory = nil
      rescue => errorStr
        $log.warn "in_kube_nodes::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end # end enumerate

    def parse_and_emit_records(nodeInventory, batchTime = Time.utc.iso8601)
      begin
        currentTime = Time.now
        emitTime = Fluent::Engine.now
        telemetrySent = false
        eventStream = Fluent::MultiEventStream.new
        containerNodeInventoryEventStream = Fluent::MultiEventStream.new
        insightsMetricsEventStream = Fluent::MultiEventStream.new
        kubePerfEventStream = Fluent::MultiEventStream.new
        @@istestvar = ENV["ISTEST"]
        #get node inventory
        nodeInventory["items"].each do |item|
          # node inventory
          nodeInventoryRecord = getNodeInventoryRecord(item, batchTime)
          eventStream.add(emitTime, nodeInventoryRecord) if nodeInventoryRecord
          if @NODES_EMIT_STREAM_BATCH_SIZE > 0 && eventStream.count >= @NODES_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_node::parse_and_emit_records: number of node inventory records emitted #{@NODES_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@tag, eventStream) if eventStream
            $log.info("in_kube_node::parse_and_emit_records: number of mdm node inventory records emitted #{@NODES_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@MDMKubeNodeInventoryTag, eventStream) if eventStream
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubeNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
            eventStream = Fluent::MultiEventStream.new
          end

          # container node inventory
          containerNodeInventoryRecord = getContainerNodeInventoryRecord(item, batchTime)
          containerNodeInventoryEventStream.add(emitTime, containerNodeInventoryRecord) if containerNodeInventoryRecord

          if @NODES_EMIT_STREAM_BATCH_SIZE > 0 && containerNodeInventoryEventStream.count >= @NODES_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_node::parse_and_emit_records: number of container node inventory records emitted #{@NODES_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@ContainerNodeInventoryTag, containerNodeInventoryEventStream) if containerNodeInventoryEventStream
            containerNodeInventoryEventStream = Fluent::MultiEventStream.new
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("containerNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          end

          # Only CPU and Memory capacity for windows nodes get added to the cache (at end of file)
          is_windows_node = false
          if !item["status"].nil? && !item["status"]["nodeInfo"].nil? && !item["status"]["nodeInfo"]["operatingSystem"].nil?
            operatingSystem = item["status"]["nodeInfo"]["operatingSystem"]
            if (operatingSystem.is_a?(String) && operatingSystem.casecmp("windows") == 0)
              is_windows_node = true
            end
          end

          # node metrics records
          nodeMetricRecords = []
          nodeMetricRecord = KubernetesApiClient.parseNodeLimitsFromNodeItem(item, "allocatable", "cpu", "cpuAllocatableNanoCores", batchTime)
          if !nodeMetricRecord.nil? && !nodeMetricRecord.empty?
            nodeMetricRecords.push(nodeMetricRecord)
          end
          nodeMetricRecord = KubernetesApiClient.parseNodeLimitsFromNodeItem(item, "allocatable", "memory", "memoryAllocatableBytes", batchTime)
          if !nodeMetricRecord.nil? && !nodeMetricRecord.empty?
            nodeMetricRecords.push(nodeMetricRecord)
          end
          nodeMetricRecord = KubernetesApiClient.parseNodeLimitsFromNodeItem(item, "capacity", "cpu", "cpuCapacityNanoCores", batchTime)
          if !nodeMetricRecord.nil? && !nodeMetricRecord.empty?
            nodeMetricRecords.push(nodeMetricRecord)
            # add data to the cache so filter_cadvisor2mdm.rb can use it
            if is_windows_node
              metricVal = JSON.parse(nodeMetricRecord["json_Collections"])[0]["Value"]
              @NodeCache.cpu.set_capacity(nodeMetricRecord["Host"], metricVal)
            end
          end
          nodeMetricRecord = KubernetesApiClient.parseNodeLimitsFromNodeItem(item, "capacity", "memory", "memoryCapacityBytes", batchTime)
          if !nodeMetricRecord.nil? && !nodeMetricRecord.empty?
            nodeMetricRecords.push(nodeMetricRecord)
            # add data to the cache so filter_cadvisor2mdm.rb can use it
            if is_windows_node
              metricVal = JSON.parse(nodeMetricRecord["json_Collections"])[0]["Value"]
              @NodeCache.mem.set_capacity(nodeMetricRecord["Host"], metricVal)
            end
          end
          nodeMetricRecords.each do |metricRecord|
            kubePerfEventStream.add(emitTime, metricRecord) if metricRecord
          end
          if @NODES_EMIT_STREAM_BATCH_SIZE > 0 && kubePerfEventStream.count >= @NODES_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_nodes::parse_and_emit_records: number of node perf metric records emitted #{@NODES_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@kubeperfTag, kubePerfEventStream) if kubePerfEventStream
            kubePerfEventStream = Fluent::MultiEventStream.new
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubeNodePerfEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          end

          # node GPU metrics record
          nodeGPUInsightsMetricsRecords = []
          insightsMetricsRecord = KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(item, "allocatable", "nvidia.com/gpu", "nodeGpuAllocatable", batchTime)
          if !insightsMetricsRecord.nil? && !insightsMetricsRecord.empty?
            nodeGPUInsightsMetricsRecords.push(insightsMetricsRecord)
          end
          insightsMetricsRecord = KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(item, "capacity", "nvidia.com/gpu", "nodeGpuCapacity", batchTime)
          if !insightsMetricsRecord.nil? && !insightsMetricsRecord.empty?
            nodeGPUInsightsMetricsRecords.push(insightsMetricsRecord)
          end
          insightsMetricsRecord = KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(item, "allocatable", "amd.com/gpu", "nodeGpuAllocatable", batchTime)
          if !insightsMetricsRecord.nil? && !insightsMetricsRecord.empty?
            nodeGPUInsightsMetricsRecords.push(insightsMetricsRecord)
          end
          insightsMetricsRecord = KubernetesApiClient.parseNodeLimitsAsInsightsMetrics(item, "capacity", "amd.com/gpu", "nodeGpuCapacity", batchTime)
          if !insightsMetricsRecord.nil? && !insightsMetricsRecord.empty?
            nodeGPUInsightsMetricsRecords.push(insightsMetricsRecord)
          end
          nodeGPUInsightsMetricsRecords.each do |insightsMetricsRecord|
            insightsMetricsEventStream.add(emitTime, insightsMetricsRecord) if insightsMetricsRecord
          end
          if @NODES_EMIT_STREAM_BATCH_SIZE > 0 && insightsMetricsEventStream.count >= @NODES_EMIT_STREAM_BATCH_SIZE
            $log.info("in_kube_nodes::parse_and_emit_records: number of GPU node perf metric records emitted #{@NODES_EMIT_STREAM_BATCH_SIZE} @ #{Time.now.utc.iso8601}")
            router.emit_stream(@insightsMetricsTag, insightsMetricsEventStream) if insightsMetricsEventStream
            insightsMetricsEventStream = Fluent::MultiEventStream.new
            if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
              $log.info("kubeNodeInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
            end
          end
          # Adding telemetry to send node telemetry every 10 minutes
          timeDifference = (DateTime.now.to_time.to_i - @@nodeTelemetryTimeTracker).abs
          timeDifferenceInMinutes = timeDifference / 60
          if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
            properties = getNodeTelemetryProps(item)
            properties["KubernetesProviderID"] = nodeInventoryRecord["KubernetesProviderID"]
            capacityInfo = item["status"]["capacity"]

            ApplicationInsightsUtility.sendMetricTelemetry("NodeMemory", capacityInfo["memory"], properties)
            begin
              if (!capacityInfo["nvidia.com/gpu"].nil?) && (!capacityInfo["nvidia.com/gpu"].empty?)
                properties["nvigpus"] = capacityInfo["nvidia.com/gpu"]
              end

              if (!capacityInfo["amd.com/gpu"].nil?) && (!capacityInfo["amd.com/gpu"].empty?)
                properties["amdgpus"] = capacityInfo["amd.com/gpu"]
              end
            rescue => errorStr
              $log.warn "Failed in getting GPU telemetry in_kube_nodes : #{errorStr}"
              $log.debug_backtrace(errorStr.backtrace)
              ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
            end

            # Telemetry for data collection config for replicaset
            if (File.file?(@@configMapMountPath))
              properties["collectAllKubeEvents"] = @@collectAllKubeEvents
            end

            #telemetry about prometheus metric collections settings for replicaset
            if (File.file?(@@promConfigMountPath))
              properties["rsPromInt"] = @@rsPromInterval
              properties["rsPromFPC"] = @@rsPromFieldPassCount
              properties["rsPromFDC"] = @@rsPromFieldDropCount
              properties["rsPromServ"] = @@rsPromK8sServiceCount
              properties["rsPromUrl"] = @@rsPromUrlCount
              properties["rsPromMonPods"] = @@rsPromMonitorPods
              properties["rsPromMonPodsNs"] = @@rsPromMonitorPodsNamespaceLength
              properties["rsPromMonPodsLabelSelectorLength"] = @@rsPromMonitorPodsLabelSelectorLength
              properties["rsPromMonPodsFieldSelectorLength"] = @@rsPromMonitorPodsFieldSelectorLength
            end
            # telemetry about osm metric settings for replicaset
            if (File.file?(@@osmConfigMountPath))
              properties["osmNamespaceCount"] = @@osmNamespaceCount
            end
            ApplicationInsightsUtility.sendMetricTelemetry("NodeCoreCapacity", capacityInfo["cpu"], properties)
            telemetrySent = true
          end
        end
        if telemetrySent == true
          @@nodeTelemetryTimeTracker = DateTime.now.to_time.to_i
        end
        if eventStream.count > 0
          $log.info("in_kube_node::parse_and_emit_records: number of node inventory records emitted #{eventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@tag, eventStream) if eventStream
          $log.info("in_kube_node::parse_and_emit_records: number of mdm node inventory records emitted #{eventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@MDMKubeNodeInventoryTag, eventStream) if eventStream
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubeNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
          eventStream = nil
        end
        if containerNodeInventoryEventStream.count > 0
          $log.info("in_kube_node::parse_and_emit_records: number of container node inventory records emitted #{containerNodeInventoryEventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@ContainerNodeInventoryTag, containerNodeInventoryEventStream) if containerNodeInventoryEventStream
          containerNodeInventoryEventStream = nil
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("containerNodeInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
        end

        if kubePerfEventStream.count > 0
          $log.info("in_kube_nodes::parse_and_emit_records: number of node perf metric records emitted #{kubePerfEventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@kubeperfTag, kubePerfEventStream) if kubePerfEventStream
          kubePerfEventStream = nil
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubeNodePerfInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
        end
        if insightsMetricsEventStream.count > 0
          $log.info("in_kube_nodes::parse_and_emit_records: number of GPU node perf metric records emitted #{insightsMetricsEventStream.count} @ #{Time.now.utc.iso8601}")
          router.emit_stream(@insightsMetricsTag, insightsMetricsEventStream) if insightsMetricsEventStream
          insightsMetricsEventStream = nil
          if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
            $log.info("kubeNodeInsightsMetricsEmitStreamSuccess @ #{Time.now.utc.iso8601}")
          end
        end
      rescue => errorStr
        $log.warn "Failed to retrieve node inventory: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      $log.info "in_kube_nodes::parse_and_emit_records:End #{Time.now.utc.iso8601}"
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
            $log.info("in_kube_nodes::run_periodic.enumerate.start #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_nodes::run_periodic.enumerate.end #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_nodes::run_periodic: enumerate Failed to retrieve node inventory: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    # TODO - move this method to KubernetesClient or helper class
    def getNodeInventoryRecord(item, batchTime = Time.utc.iso8601)
      record = {}
      begin
        record["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
        record["Computer"] = item["metadata"]["name"]
        record["ClusterName"] = KubernetesApiClient.getClusterName
        record["ClusterId"] = KubernetesApiClient.getClusterId
        record["CreationTimeStamp"] = item["metadata"]["creationTimestamp"]
        record["Labels"] = [item["metadata"]["labels"]]
        record["Status"] = ""

        if !item["spec"]["providerID"].nil? && !item["spec"]["providerID"].empty?
          if File.file?(@@AzStackCloudFileName) # existence of this file indicates agent running on azstack
            record["KubernetesProviderID"] = "azurestack"
          else
            #Multicluster kusto query is filtering after splitting by ":" to the left, so do the same here
            #https://msazure.visualstudio.com/One/_git/AzureUX-Monitoring?path=%2Fsrc%2FMonitoringExtension%2FClient%2FInfraInsights%2FData%2FQueryTemplates%2FMultiClusterKustoQueryTemplate.ts&_a=contents&version=GBdev
            provider = item["spec"]["providerID"].split(":")[0]
            if !provider.nil? && !provider.empty?
              record["KubernetesProviderID"] = provider
            else
              record["KubernetesProviderID"] = item["spec"]["providerID"]
            end
          end
        else
          record["KubernetesProviderID"] = "onprem"
        end

        # Refer to https://kubernetes.io/docs/concepts/architecture/nodes/#condition for possible node conditions.
        # We check the status of each condition e.g. {"type": "OutOfDisk","status": "False"} . Based on this we
        # populate the KubeNodeInventory Status field. A possible value for this field could be "Ready OutofDisk"
        # implying that the node is ready for hosting pods, however its out of disk.
        if item["status"].key?("conditions") && !item["status"]["conditions"].empty?
          allNodeConditions = ""
          item["status"]["conditions"].each do |condition|
            if condition["status"] == "True"
              if !allNodeConditions.empty?
                allNodeConditions = allNodeConditions + "," + condition["type"]
              else
                allNodeConditions = condition["type"]
              end
            end
            #collect last transition to/from ready (no matter ready is true/false)
            if condition["type"] == "Ready" && !condition["lastTransitionTime"].nil?
              record["LastTransitionTimeReady"] = condition["lastTransitionTime"]
            end
          end
          if !allNodeConditions.empty?
            record["Status"] = allNodeConditions
          end
        end
        nodeInfo = item["status"]["nodeInfo"]
        record["KubeletVersion"] = nodeInfo["kubeletVersion"]
        record["KubeProxyVersion"] = nodeInfo["kubeProxyVersion"]
      rescue => errorStr
        $log.warn "in_kube_nodes::getNodeInventoryRecord:Failed: #{errorStr}"
      end
      return record
    end

    # TODO - move this method to KubernetesClient or helper class
    def getContainerNodeInventoryRecord(item, batchTime = Time.utc.iso8601)
      containerNodeInventoryRecord = {}
      begin
        containerNodeInventoryRecord["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
        containerNodeInventoryRecord["Computer"] = item["metadata"]["name"]
        nodeInfo = item["status"]["nodeInfo"]
        containerNodeInventoryRecord["OperatingSystem"] = nodeInfo["osImage"]
        containerRuntimeVersion = nodeInfo["containerRuntimeVersion"]
        if containerRuntimeVersion.downcase.start_with?("docker://")
          containerNodeInventoryRecord["DockerVersion"] = containerRuntimeVersion.split("//")[1]
        else
          # using containerRuntimeVersion as DockerVersion as is for non docker runtimes
          containerNodeInventoryRecord["DockerVersion"] = containerRuntimeVersion
        end
      rescue => errorStr
        $log.warn "in_kube_nodes::getContainerNodeInventoryRecord:Failed: #{errorStr}"
      end
      return containerNodeInventoryRecord
    end

    # TODO - move this method to KubernetesClient or helper class
    def getNodeTelemetryProps(item)
      properties = {}
      begin
        properties["Computer"] = item["metadata"]["name"]
        nodeInfo = item["status"]["nodeInfo"]
        properties["KubeletVersion"] = nodeInfo["kubeletVersion"]
        properties["OperatingSystem"] = nodeInfo["operatingSystem"]
        properties["KernelVersion"] = nodeInfo["kernelVersion"]
        properties["OSImage"] = nodeInfo["osImage"]
        containerRuntimeVersion = nodeInfo["containerRuntimeVersion"]
        if containerRuntimeVersion.downcase.start_with?("docker://")
          properties["DockerVersion"] = containerRuntimeVersion.split("//")[1]
        else
          # using containerRuntimeVersion as DockerVersion as is for non docker runtimes
          properties["DockerVersion"] = containerRuntimeVersion
        end
        properties["NODES_CHUNK_SIZE"] = @NODES_CHUNK_SIZE
        properties["NODES_EMIT_STREAM_BATCH_SIZE"] = @NODES_EMIT_STREAM_BATCH_SIZE
      rescue => errorStr
        $log.warn "in_kube_nodes::getContainerNodeIngetNodeTelemetryPropsventoryRecord:Failed: #{errorStr}"
      end
      return properties
    end
  end # Kube_Node_Input
  class NodeStatsCache
    # inner class for caching implementation (CPU and memory caching is handled the exact same way, so logic to do so is moved to a private inner class)
    # (to reduce code duplication)
    class NodeCache

      @@RECORD_TIME_TO_LIVE = 60*20  # units are seconds, so clear the cache every 20 minutes.

      def initialize
        @cacheHash = {}
        @timeAdded = {}  # records when an entry was last added
        @lock = Mutex.new
        @lastCacheClearTime = 0

        @cacheHash.default = 0.0
        @lastCacheClearTime = DateTime.now.to_time.to_i
      end

      def get_capacity(node_name)
        @lock.synchronize do
          retval = @cacheHash[node_name]
          return retval
        end
      end

      def set_capacity(host, val)
        # check here if the cache has not been cleaned in a while. This way calling code doesn't have to remember to clean the cache
        current_time = DateTime.now.to_time.to_i
        if current_time - @lastCacheClearTime > @@RECORD_TIME_TO_LIVE
          clean_cache
          @lastCacheClearTime = current_time
        end

        @lock.synchronize do
          @cacheHash[host] = val
          @timeAdded[host] = current_time
        end
      end

      def clean_cache()
        $log.info "in_kube_nodes::clean_cache: cleaning node cpu/mem cache"
        cacheClearTime = DateTime.now.to_time.to_i
        @lock.synchronize do
          nodes_to_remove = []  # first make a list of nodes to remove, then remove them. This intermediate
          # list is used so that we aren't modifying a hash while iterating through it.
          @cacheHash.each do |key, val|
            if cacheClearTime - @timeAdded[key] > @@RECORD_TIME_TO_LIVE
              nodes_to_remove.append(key)
            end
          end

          nodes_to_remove.each {|node_name|
            @cacheHash.delete(node_name)
            @timeAdded.delete(node_name)
          }
        end
      end
    end  # NodeCache


    @@cpuCache = NodeCache.new
    @@memCache = NodeCache.new

    def cpu()
      return @@cpuCache
    end

    def mem()
      return @@memCache
    end
  end
end # module
