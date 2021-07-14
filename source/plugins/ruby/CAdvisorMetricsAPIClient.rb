#!/usr/local/bin/ruby
# frozen_string_literal: true

class CAdvisorMetricsAPIClient
  require "yajl/json_gem"
  require "logger"
  require "net/http"
  require "net/https"
  require "uri"
  require "date"
  require "time"

  require_relative "oms_common"
  require_relative "KubernetesApiClient"
  require_relative "ApplicationInsightsUtility"
  require_relative "constants"

  @configMapMountPath = "/etc/config/settings/log-data-collection-settings"
  @promConfigMountPath = "/etc/config/settings/prometheus-data-collection-settings"
  @clusterEnvVarCollectionEnabled = ENV["AZMON_CLUSTER_COLLECT_ENV_VAR"]
  @clusterStdErrLogCollectionEnabled = ENV["AZMON_COLLECT_STDERR_LOGS"]
  @clusterStdOutLogCollectionEnabled = ENV["AZMON_COLLECT_STDOUT_LOGS"]
  @pvKubeSystemCollectionMetricsEnabled = ENV["AZMON_PV_COLLECT_KUBE_SYSTEM_METRICS"]
  @clusterLogTailExcludPath = ENV["AZMON_CLUSTER_LOG_TAIL_EXCLUDE_PATH"]
  @clusterLogTailPath = ENV["AZMON_LOG_TAIL_PATH"]
  @clusterAgentSchemaVersion = ENV["AZMON_AGENT_CFG_SCHEMA_VERSION"]
  @clusterContainerLogEnrich = ENV["AZMON_CLUSTER_CONTAINER_LOG_ENRICH"]
  @clusterContainerLogSchemaVersion = ENV["AZMON_CONTAINER_LOG_SCHEMA_VERSION"]
  @clusterMultilineEnabled = ENV["AZMON_LOG_STITCH_MULTILINE"]

  @dsPromInterval = ENV["TELEMETRY_DS_PROM_INTERVAL"]
  @dsPromFieldPassCount = ENV["TELEMETRY_DS_PROM_FIELDPASS_LENGTH"]
  @dsPromFieldDropCount = ENV["TELEMETRY_DS_PROM_FIELDDROP_LENGTH"]
  @dsPromUrlCount = ENV["TELEMETRY_DS_PROM_URLS_LENGTH"]

  @cAdvisorMetricsSecurePort = ENV["IS_SECURE_CADVISOR_PORT"]
  @containerLogsRoute = ENV["AZMON_CONTAINER_LOGS_ROUTE"]
  @hmEnabled = ENV["AZMON_CLUSTER_ENABLE_HEALTH_MODEL"]
  @npmIntegrationBasic = ENV["TELEMETRY_NPM_INTEGRATION_METRICS_BASIC"]
  @npmIntegrationAdvanced = ENV["TELEMETRY_NPM_INTEGRATION_METRICS_ADVANCED"]

  @os_type = ENV["OS_TYPE"]
  if !@os_type.nil? && !@os_type.empty? && @os_type.strip.casecmp("windows") == 0
    @LogPath = "/etc/omsagentwindows/kubernetes_perf_log.txt"
  else
    @LogPath = "/var/opt/microsoft/docker-cimprov/log/kubernetes_perf_log.txt"
  end
  @Log = Logger.new(@LogPath, 2, 10 * 1048576) #keep last 2 files, max log file size = 10M
  #   @@rxBytesLast = nil
  #   @@rxBytesTimeLast = nil
  #   @@txBytesLast = nil
  #   @@txBytesTimeLast = nil
  @@nodeCpuUsageNanoSecondsLast = nil
  @@nodeCpuUsageNanoSecondsTimeLast = nil
  @@winNodeCpuUsageNanoSecondsLast = {}
  @@winNodeCpuUsageNanoSecondsTimeLast = {}
  @@winContainerCpuUsageNanoSecondsLast = {}
  @@winContainerCpuUsageNanoSecondsTimeLast = {}
  @@winContainerPrevMetricRate = {}
  @@linuxNodePrevMetricRate = nil
  @@winNodePrevMetricRate = {}
  @@telemetryCpuMetricTimeTracker = DateTime.now.to_time.to_i
  @@telemetryMemoryMetricTimeTracker = DateTime.now.to_time.to_i
  @@telemetryPVKubeSystemMetricsTimeTracker = DateTime.now.to_time.to_i

  #Containers a hash of node name and the last time telemetry was sent for this node
  @@nodeTelemetryTimeTracker = {}

  # Keeping track of containers so that can delete the container from the container cpu cache when the container is deleted
  # as a part of the cleanup routine
  @@winContainerIdCache = []
  #cadvisor ports
  @@CADVISOR_SECURE_PORT = "10250"
  @@CADVISOR_NON_SECURE_PORT = "10255"

  def initialize
  end

  class << self
    def getSummaryStatsFromCAdvisor(winNode)
      relativeUri = "/stats/summary"
      return getResponse(winNode, relativeUri)
    end

    def getCongifzCAdvisor(winNode: nil)
      relativeUri = "/configz"
      return getResponse(winNode, relativeUri)
    end

    def getAllMetricsCAdvisor(winNode: nil)
      relativeUri = "/metrics/cadvisor"
      return getResponse(winNode, relativeUri)
    end

    def getPodsFromCAdvisor(winNode: nil)
      relativeUri = "/pods"
      return getResponse(winNode, relativeUri)
    end

    def getBaseCAdvisorUri(winNode)
      cAdvisorSecurePort = isCAdvisorOnSecurePort()

      if !!cAdvisorSecurePort == true
        defaultHost = "https://localhost:#{@@CADVISOR_SECURE_PORT}"
      else
        defaultHost = "http://localhost:#{@@CADVISOR_NON_SECURE_PORT}"
      end

      if !winNode.nil?
        nodeIP = winNode["InternalIP"]
      else
        nodeIP = ENV["NODE_IP"]
      end

      if !nodeIP.nil?
        @Log.info("Using #{nodeIP} for CAdvisor Host")
        if !!cAdvisorSecurePort == true
          return "https://#{nodeIP}:#{@@CADVISOR_SECURE_PORT}"
        else
          return "http://#{nodeIP}:#{@@CADVISOR_NON_SECURE_PORT}"
        end
      else
        @Log.warn ("NODE_IP environment variable not set. Using default as : #{defaultHost}")
        if !winNode.nil?
          return nil
        else
          return defaultHost
        end
      end
    end

    def getCAdvisorUri(winNode, relativeUri)
      baseUri = getBaseCAdvisorUri(winNode)
      return baseUri + relativeUri
    end

    def getMetrics(winNode: nil, metricTime: Time.now.utc.iso8601)
      metricDataItems = []
      begin
        cAdvisorStats = getSummaryStatsFromCAdvisor(winNode)
        if !cAdvisorStats.nil?
          metricInfo = JSON.parse(cAdvisorStats.body)
        end
        if !winNode.nil?
          hostName = winNode["Hostname"]
          operatingSystem = "Windows"
        else
          if !metricInfo.nil? && !metricInfo["node"].nil? && !metricInfo["node"]["nodeName"].nil?
            hostName = metricInfo["node"]["nodeName"]
          else
            hostName = (OMS::Common.get_hostname)
          end
          operatingSystem = "Linux"
        end
        if !metricInfo.nil?
          # Checking if we are in windows daemonset and sending only few metrics that are needed for MDM
          if !@os_type.nil? && !@os_type.empty? && @os_type.strip.casecmp("windows") == 0
            # Container metrics
            metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "workingSetBytes", Constants::MEMORY_WORKING_SET_BYTES, metricTime, operatingSystem))
            containerCpuUsageNanoSecondsRate = getContainerCpuMetricItemRate(metricInfo, hostName, "usageCoreNanoSeconds", Constants::CPU_USAGE_NANO_CORES, metricTime)
            if containerCpuUsageNanoSecondsRate && !containerCpuUsageNanoSecondsRate.empty? && !containerCpuUsageNanoSecondsRate.nil?
              metricDataItems.concat(containerCpuUsageNanoSecondsRate)
            end
            # Node metrics
            cpuUsageNanoSecondsRate = getNodeMetricItemRate(metricInfo, hostName, "cpu", "usageCoreNanoSeconds", Constants::CPU_USAGE_NANO_CORES, operatingSystem, metricTime)
            if cpuUsageNanoSecondsRate && !cpuUsageNanoSecondsRate.empty? && !cpuUsageNanoSecondsRate.nil?
              metricDataItems.push(cpuUsageNanoSecondsRate)
            end
            metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "workingSetBytes", Constants::MEMORY_WORKING_SET_BYTES, metricTime))
          else
            metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "workingSetBytes", Constants::MEMORY_WORKING_SET_BYTES, metricTime, operatingSystem))
            metricDataItems.concat(getContainerStartTimeMetricItems(metricInfo, hostName, "restartTimeEpoch", metricTime))

            if operatingSystem == "Linux"
              metricDataItems.concat(getContainerCpuMetricItems(metricInfo, hostName, "usageNanoCores", Constants::CPU_USAGE_NANO_CORES, metricTime))
              metricDataItems.concat(getContainerMemoryMetricItems(metricInfo, hostName, "rssBytes", Constants::MEMORY_RSS_BYTES, metricTime, operatingSystem))
              metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "rssBytes", Constants::MEMORY_RSS_BYTES, metricTime))
            elsif operatingSystem == "Windows"
              containerCpuUsageNanoSecondsRate = getContainerCpuMetricItemRate(metricInfo, hostName, "usageCoreNanoSeconds", Constants::CPU_USAGE_NANO_CORES, metricTime)
              if containerCpuUsageNanoSecondsRate && !containerCpuUsageNanoSecondsRate.empty? && !containerCpuUsageNanoSecondsRate.nil?
                metricDataItems.concat(containerCpuUsageNanoSecondsRate)
              end
            end

            cpuUsageNanoSecondsRate = getNodeMetricItemRate(metricInfo, hostName, "cpu", "usageCoreNanoSeconds", Constants::CPU_USAGE_NANO_CORES, operatingSystem, metricTime)
            if cpuUsageNanoSecondsRate && !cpuUsageNanoSecondsRate.empty? && !cpuUsageNanoSecondsRate.nil?
              metricDataItems.push(cpuUsageNanoSecondsRate)
            end
            metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "memory", "workingSetBytes", Constants::MEMORY_WORKING_SET_BYTES, metricTime))

            metricDataItems.push(getNodeLastRebootTimeMetric(metricInfo, hostName, "restartTimeEpoch", metricTime))
            # Disabling networkRxRate and networkTxRate since we dont use it as of now.
            #metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "network", "rxBytes", "networkRxBytes"))
            #metricDataItems.push(getNodeMetricItem(metricInfo, hostName, "network", "txBytes", "networkTxBytes"))
            #   networkRxRate = getNodeMetricItemRate(metricInfo, hostName, "network", "rxBytes", "networkRxBytesPerSec")
            #   if networkRxRate && !networkRxRate.empty? && !networkRxRate.nil?
            #     metricDataItems.push(networkRxRate)
            #   end
            #   networkTxRate = getNodeMetricItemRate(metricInfo, hostName, "network", "txBytes", "networkTxBytesPerSec")
            #   if networkTxRate && !networkTxRate.empty? && !networkTxRate.nil?
            #     metricDataItems.push(networkTxRate)
            #   end
          end
        else
          @Log.warn("Couldn't get metric information for host: #{hostName}")
        end
      rescue => error
        @Log.warn("getContainerMetrics failed: #{error}")
        return metricDataItems
      end
      return metricDataItems
    end

    def getContainerCpuMetricItems(metricJSON, hostName, cpuMetricNameToCollect, metricNametoReturn, metricPollTime)
      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      timeDifference = (DateTime.now.to_time.to_i - @@telemetryCpuMetricTimeTracker).abs
      timeDifferenceInMinutes = timeDifference / 60
      begin
        metricInfo = metricJSON
        metricInfo["pods"].each do |pod|
          podUid = pod["podRef"]["uid"]
          podName = pod["podRef"]["name"]
          podNamespace = pod["podRef"]["namespace"]

          if (!pod["containers"].nil?)
            pod["containers"].each do |container|
              #cpu metric
              containerName = container["name"]
              metricValue = container["cpu"][cpuMetricNameToCollect]
              metricTime = metricPollTime #container["cpu"]["time"]

              metricItem = {}
              metricItem["Timestamp"] = metricTime
              metricItem["Host"] = hostName
              metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_CONTAINER
              metricItem["InstanceName"] = clusterId + "/" + podUid + "/" + containerName

              
              metricCollection = {}
              metricCollection["CounterName"] = metricNametoReturn
              metricCollection["Value"] = metricValue

              metricItem["json_Collections"] = []
              metricCollections = []               
              metricCollections.push(metricCollection)        
              metricItem["json_Collections"] = metricCollections.to_json
              metricItems.push(metricItem)      
              
              #Telemetry about agent performance
              begin
                # we can only do this much now. Ideally would like to use the docker image repository to find our pods/containers
                # cadvisor does not have pod/container metadata. so would need more work to cache as pv & use
                if (podName.downcase.start_with?("omsagent-") && podNamespace.eql?("kube-system") && containerName.downcase.start_with?("omsagent") && metricNametoReturn.eql?(Constants::CPU_USAGE_NANO_CORES))
                  if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
                    telemetryProps = {}
                    telemetryProps["PodName"] = podName
                    telemetryProps["ContainerName"] = containerName
                    telemetryProps["Computer"] = hostName
                    telemetryProps["CAdvisorIsSecure"] = @cAdvisorMetricsSecurePort
                    #telemetry about log collections settings
                    if (File.file?(@configMapMountPath))
                      telemetryProps["clustercustomsettings"] = true
                      telemetryProps["clusterenvvars"] = @clusterEnvVarCollectionEnabled
                      telemetryProps["clusterstderrlogs"] = @clusterStdErrLogCollectionEnabled
                      telemetryProps["clusterstdoutlogs"] = @clusterStdOutLogCollectionEnabled
                      telemetryProps["clusterlogtailexcludepath"] = @clusterLogTailExcludPath
                      telemetryProps["clusterLogTailPath"] = @clusterLogTailPath
                      telemetryProps["clusterAgentSchemaVersion"] = @clusterAgentSchemaVersion
                      telemetryProps["clusterCLEnrich"] = @clusterContainerLogEnrich
                    end
                    #telemetry about prometheus metric collections settings for daemonset
                    if (File.file?(@promConfigMountPath))
                      telemetryProps["dsPromInt"] = @dsPromInterval
                      telemetryProps["dsPromFPC"] = @dsPromFieldPassCount
                      telemetryProps["dsPromFDC"] = @dsPromFieldDropCount
                      telemetryProps["dsPromUrl"] = @dsPromUrlCount
                    end
                    #telemetry about containerlog Routing for daemonset
                    telemetryProps["containerLogsRoute"] = @containerLogsRoute
                   
                    #telemetry about health model
                    if (!@hmEnabled.nil? && !@hmEnabled.empty?)
                      telemetryProps["hmEnabled"] = @hmEnabled
                    end
                    #telemetry for npm integration
                    if (!@npmIntegrationAdvanced.nil? && !@npmIntegrationAdvanced.empty?)
                      telemetryProps["int-npm-a"] = "1"
                    elsif (!@npmIntegrationBasic.nil? && !@npmIntegrationBasic.empty?)
                      telemetryProps["int-npm-b"] = "1"
                    end
                    #telemetry for Container log schema version clusterContainerLogSchemaVersion
                    if (!@clusterContainerLogSchemaVersion.nil? && !@clusterContainerLogSchemaVersion.empty?)
                      telemetryProps["containerLogVer"] = @clusterContainerLogSchemaVersion
                    end
                    if (!@clusterMultilineEnabled.nil? && !@clusterMultilineEnabled.empty?)
                      telemetryProps["multilineEnabled"] = @clusterMultilineEnabled
                    end
                    ApplicationInsightsUtility.sendMetricTelemetry(metricNametoReturn, metricValue, telemetryProps)
                  end
                end
              rescue => errorStr
                $log.warn("Exception while generating Telemetry from getcontainerCpuMetricItems failed: #{errorStr} for metric #{cpuMetricNameToCollect}")
              end
            end
          end
        end
        # reset time outside pod iterator as we use one timer per metric for 2 pods (ds & rs)
        if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES && metricNametoReturn.eql?("cpuUsageNanoCores"))
          @@telemetryCpuMetricTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => error
        @Log.warn("getcontainerCpuMetricItems failed: #{error} for metric #{cpuMetricNameToCollect}")
        return metricItems
      end
      return metricItems
    end

    def getInsightsMetrics(winNode: nil, metricTime: Time.now.utc.iso8601)
      metricDataItems = []
      begin
        cAdvisorStats = getSummaryStatsFromCAdvisor(winNode)
        if !cAdvisorStats.nil?
          metricInfo = JSON.parse(cAdvisorStats.body)
        end
        if !winNode.nil?
          hostName = winNode["Hostname"]
          operatingSystem = "Windows"
        else
          if !metricInfo.nil? && !metricInfo["node"].nil? && !metricInfo["node"]["nodeName"].nil?
            hostName = metricInfo["node"]["nodeName"]
          else
            hostName = (OMS::Common.get_hostname)
          end
          operatingSystem = "Linux"
        end
        if !metricInfo.nil?
          metricDataItems.concat(getContainerGpuMetricsAsInsightsMetrics(metricInfo, hostName, "memoryTotal", "containerGpumemoryTotalBytes", metricTime))
          metricDataItems.concat(getContainerGpuMetricsAsInsightsMetrics(metricInfo, hostName, "memoryUsed", "containerGpumemoryUsedBytes", metricTime))
          metricDataItems.concat(getContainerGpuMetricsAsInsightsMetrics(metricInfo, hostName, "dutyCycle", "containerGpuDutyCycle", metricTime))

          metricDataItems.concat(getPersistentVolumeMetrics(metricInfo, hostName, "usedBytes", Constants::PV_USED_BYTES, metricTime))
        else
          @Log.warn("Couldn't get Insights metrics information for host: #{hostName} os:#{operatingSystem}")
        end
      rescue => error
        @Log.warn("CAdvisorMetricsAPIClient::getInsightsMetrics failed: #{error}")
        return metricDataItems
      end
      return metricDataItems
    end

    def getPersistentVolumeMetrics(metricJSON, hostName, metricNameToCollect, metricNameToReturn, metricPollTime)
      telemetryTimeDifference = (DateTime.now.to_time.to_i - @@telemetryPVKubeSystemMetricsTimeTracker).abs
      telemetryTimeDifferenceInMinutes = telemetryTimeDifference / 60

      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      clusterName = KubernetesApiClient.getClusterName
      begin
        metricInfo = metricJSON
        metricInfo["pods"].each do |pod|
          podNamespace = pod["podRef"]["namespace"]
          excludeNamespace = false
          if (podNamespace.downcase == "kube-system") && @pvKubeSystemCollectionMetricsEnabled == "false"
            excludeNamespace = true
          end

          if (!excludeNamespace && !pod["volume"].nil?)
            pod["volume"].each do |volume|
              if (!volume["pvcRef"].nil?)
                pvcRef = volume["pvcRef"]
                if (!pvcRef["name"].nil?)

                  # A PVC exists on this volume
                  podUid = pod["podRef"]["uid"]
                  podName = pod["podRef"]["name"]
                  pvcName = pvcRef["name"]
                  pvcNamespace = pvcRef["namespace"]

                  metricItem = {}
                  metricItem["CollectionTime"] = metricPollTime
                  metricItem["Computer"] = hostName
                  metricItem["Name"] = metricNameToReturn
                  metricItem["Value"] = volume[metricNameToCollect]
                  metricItem["Origin"] = Constants::INSIGHTSMETRICS_TAGS_ORIGIN
                  metricItem["Namespace"] = Constants::INSIGTHTSMETRICS_TAGS_PV_NAMESPACE

                  metricTags = {}
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERID] = clusterId
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERNAME] = clusterName
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_POD_UID] = podUid
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_POD_NAME] = podName
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_PVC_NAME] = pvcName
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_PVC_NAMESPACE] = pvcNamespace
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_VOLUME_NAME] = volume["name"]
                  metricTags[Constants::INSIGHTSMETRICS_TAGS_PV_CAPACITY_BYTES] = volume["capacityBytes"]

                  metricItem["Tags"] = metricTags

                  metricItems.push(metricItem)
                end
              end
            end
          end
        end
      rescue => errorStr
        @Log.warn("getPersistentVolumeMetrics failed: #{errorStr} for metric #{metricNameToCollect}")
        return metricItems
      end

      # If kube-system metrics collection enabled, send telemetry
      begin
        if telemetryTimeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES && @pvKubeSystemCollectionMetricsEnabled == "true"
          ApplicationInsightsUtility.sendCustomEvent(Constants::PV_KUBE_SYSTEM_METRICS_ENABLED_EVENT, {})
          @@telemetryPVKubeSystemMetricsTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => errorStr
        @Log.warn("getPersistentVolumeMetrics kube-system metrics enabled telemetry failed: #{errorStr}")
      end

      return metricItems
    end

    def getContainerGpuMetricsAsInsightsMetrics(metricJSON, hostName, metricNameToCollect, metricNametoReturn, metricPollTime)
      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      clusterName = KubernetesApiClient.getClusterName
      begin
        metricInfo = metricJSON
        metricInfo["pods"].each do |pod|
          podUid = pod["podRef"]["uid"]
          podName = pod["podRef"]["name"]
          podNamespace = pod["podRef"]["namespace"]

          if (!pod["containers"].nil?)
            pod["containers"].each do |container|
              #gpu metrics
              if (!container["accelerators"].nil?)
                container["accelerators"].each do |accelerator|
                  if (!accelerator[metricNameToCollect].nil?) #empty check is invalid for non-strings
                    containerName = container["name"]
                    metricValue = accelerator[metricNameToCollect]

                    metricItem = {}
                    metricItem["CollectionTime"] = metricPollTime
                    metricItem["Computer"] = hostName
                    metricItem["Name"] = metricNametoReturn
                    metricItem["Value"] = metricValue
                    metricItem["Origin"] = Constants::INSIGHTSMETRICS_TAGS_ORIGIN
                    metricItem["Namespace"] = Constants::INSIGHTSMETRICS_TAGS_GPU_NAMESPACE

                    metricTags = {}
                    metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERID] = clusterId
                    metricTags[Constants::INSIGHTSMETRICS_TAGS_CLUSTERNAME] = clusterName
                    metricTags[Constants::INSIGHTSMETRICS_TAGS_CONTAINER_NAME] = podUid + "/" + containerName
                    #metricTags[Constants::INSIGHTSMETRICS_TAGS_K8SNAMESPACE] = podNameSpace

                    if (!accelerator["make"].nil? && !accelerator["make"].empty?)
                      metricTags[Constants::INSIGHTSMETRICS_TAGS_GPU_VENDOR] = accelerator["make"]
                    end

                    if (!accelerator["model"].nil? && !accelerator["model"].empty?)
                      metricTags[Constants::INSIGHTSMETRICS_TAGS_GPU_MODEL] = accelerator["model"]
                    end

                    if (!accelerator["id"].nil? && !accelerator["id"].empty?)
                      metricTags[Constants::INSIGHTSMETRICS_TAGS_GPU_ID] = accelerator["id"]
                    end

                    metricItem["Tags"] = metricTags

                    metricItems.push(metricItem)
                  end
                end
              end
            end
          end
        end
      rescue => errorStr
        @Log.warn("getContainerGpuMetricsAsInsightsMetrics failed: #{errorStr} for metric #{metricNameToCollect}")
        return metricItems
      end
      return metricItems
    end

    def clearDeletedWinContainersFromCache()
      begin
        winCpuUsageNanoSecondsKeys = @@winContainerCpuUsageNanoSecondsLast.keys
        winCpuUsageNanoSecondsTimeKeys = @@winContainerCpuUsageNanoSecondsTimeLast.keys

        # Find the container ids to be deleted from cache
        winContainersToBeCleared = winCpuUsageNanoSecondsKeys - @@winContainerIdCache
        if winContainersToBeCleared.length > 0
          @Log.warn "Stale containers found in cache, clearing...: #{winContainersToBeCleared}"
        end
        winContainersToBeCleared.each do |containerId|
          @@winContainerCpuUsageNanoSecondsLast.delete(containerId)
          @@winContainerCpuUsageNanoSecondsTimeLast.delete(containerId)
        end
      rescue => errorStr
        @Log.warn("clearDeletedWinContainersFromCache failed: #{errorStr}")
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end

    def resetWinContainerIdCache
      @@winContainerIdCache = []
    end

    # usageNanoCores doesnt exist for windows nodes. Hence need to compute this from usageCoreNanoSeconds
    def getContainerCpuMetricItemRate(metricJSON, hostName, cpuMetricNameToCollect, metricNametoReturn, metricPollTime)
      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      timeDifference = (DateTime.now.to_time.to_i - @@telemetryCpuMetricTimeTracker).abs
      timeDifferenceInMinutes = timeDifference / 60
      @Log.warn "in host: #{hostName}"
      begin
        metricInfo = metricJSON
        containerCount = 0
        metricInfo["pods"].each do |pod|
          podUid = pod["podRef"]["uid"]
          podName = pod["podRef"]["name"]
          podNamespace = pod["podRef"]["namespace"]

          if (!pod["containers"].nil?)
            pod["containers"].each do |container|
              #cpu metric
              containerCount += 1
              containerName = container["name"]
              metricValue = container["cpu"][cpuMetricNameToCollect]
              metricTime = metricPollTime #container["cpu"]["time"]
            
              metricItem = {}
              metricItem["Timestamp"] = metricTime
              metricItem["Host"] = hostName
              metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_CONTAINER
              metricItem["InstanceName"] = clusterId + "/" + podUid + "/" + containerName
              
              metricItem["json_Collections"] = []
              metricCollection = {}
              metricCollection["CounterName"] = metricNametoReturn

              containerId = podUid + "/" + containerName
              # Adding the containers to the winContainerIdCache so that it can be used by the cleanup routine
              # to clear the delted containers every 5 minutes
              @@winContainerIdCache.push(containerId)
              if @@winContainerCpuUsageNanoSecondsLast[containerId].nil? || @@winContainerCpuUsageNanoSecondsTimeLast[containerId].nil? || @@winContainerCpuUsageNanoSecondsLast[containerId] > metricValue #when kubelet is restarted the last condition will be true
                @@winContainerCpuUsageNanoSecondsLast[containerId] = metricValue
                @@winContainerCpuUsageNanoSecondsTimeLast[containerId] = metricTime
                next
              else
                timeDifference = DateTime.parse(metricTime).to_time - DateTime.parse(@@winContainerCpuUsageNanoSecondsTimeLast[containerId]).to_time
                containerCpuUsageDifference = metricValue - @@winContainerCpuUsageNanoSecondsLast[containerId]
                # containerCpuUsageDifference check is added to make sure we report non zero values when cadvisor returns same values for subsequent calls
                if timeDifference != 0 && containerCpuUsageDifference != 0
                  metricRateValue = (containerCpuUsageDifference * 1.0) / timeDifference
                else
                  @Log.info "container - cpu usage difference / time difference is 0, hence using previous cached value"
                  if !@@winContainerPrevMetricRate[containerId].nil?
                    metricRateValue = @@winContainerPrevMetricRate[containerId]
                  else
                    # This can happen when the metric value returns same values for subsequent calls when the plugin first starts
                    metricRateValue = 0
                  end
                end
                @@winContainerCpuUsageNanoSecondsLast[containerId] = metricValue
                @@winContainerCpuUsageNanoSecondsTimeLast[containerId] = metricTime
                metricValue = metricRateValue
                @@winContainerPrevMetricRate[containerId] = metricRateValue
              end

              metricCollection["Value"] = metricValue
              
              metricCollections = []               
              metricCollections.push(metricCollection)        
              metricItem["json_Collections"] = metricCollections.to_json
              metricItems.push(metricItem)
              #Telemetry about agent performance
              begin
                # we can only do this much now. Ideally would like to use the docker image repository to find our pods/containers
                # cadvisor does not have pod/container metadata. so would need more work to cache as pv & use
                if (podName.downcase.start_with?("omsagent-") && podNamespace.eql?("kube-system") && containerName.downcase.start_with?("omsagent"))
                  if (timeDifferenceInMinutes >= 10)
                    telemetryProps = {}
                    telemetryProps["PodName"] = podName
                    telemetryProps["ContainerName"] = containerName
                    telemetryProps["Computer"] = hostName
                    telemetryProps["CAdvisorIsSecure"] = @cAdvisorMetricsSecurePort
                    #telemetry about log collections settings
                    if (File.file?(@configMapMountPath))
                      telemetryProps["clustercustomsettings"] = true
                      telemetryProps["clusterenvvars"] = @clusterEnvVarCollectionEnabled
                      telemetryProps["clusterstderrlogs"] = @clusterStdErrLogCollectionEnabled
                      telemetryProps["clusterstdoutlogs"] = @clusterStdOutLogCollectionEnabled
                      telemetryProps["clusterlogtailexcludepath"] = @clusterLogTailExcludPath
                      telemetryProps["clusterLogTailPath"] = @clusterLogTailPath
                      telemetryProps["clusterAgentSchemaVersion"] = @clusterAgentSchemaVersion
                      telemetryProps["clusterCLEnrich"] = @clusterContainerLogEnrich
                    end
                    #telemetry about prometheus metric collections settings for daemonset
                    if (File.file?(@promConfigMountPath))
                      telemetryProps["dsPromInt"] = @dsPromInterval
                      telemetryProps["dsPromFPC"] = @dsPromFieldPassCount
                      telemetryProps["dsPromFDC"] = @dsPromFieldDropCount
                      telemetryProps["dsPromUrl"] = @dsPromUrlCount
                    end
                    ApplicationInsightsUtility.sendMetricTelemetry(metricNametoReturn, metricValue, telemetryProps)
                  end
                end
              rescue => errorStr
                $log.warn("Exception while generating Telemetry from getcontainerCpuMetricItems failed: #{errorStr} for metric #{cpuMetricNameToCollect}")
              end
            end
          end
        end
        #Sending ContainerInventoryTelemetry from replicaset for telemetry purposes
        if @@nodeTelemetryTimeTracker[hostName].nil?
          @@nodeTelemetryTimeTracker[hostName] = DateTime.now.to_time.to_i
        else
          timeDifference = (DateTime.now.to_time.to_i - @@nodeTelemetryTimeTracker[hostName]).abs
          timeDifferenceInMinutes = timeDifference / 60
          if (timeDifferenceInMinutes >= 5)
            @@nodeTelemetryTimeTracker[hostName] = DateTime.now.to_time.to_i
            telemetryProperties = {}
            telemetryProperties["Computer"] = hostName
            telemetryProperties["ContainerCount"] = containerCount
            telemetryProperties["OS"] = "Windows"
            # Hardcoding the event to ContainerInventory hearbeat event since the telemetry is pivoted off of this event.
            @Log.info "sending container inventory heartbeat telemetry"
            ApplicationInsightsUtility.sendCustomEvent("ContainerInventoryHeartBeatEvent", telemetryProperties)
          end
        end
      rescue => error
        @Log.warn("getcontainerCpuMetricItemRate failed: #{error} for metric #{cpuMetricNameToCollect}")
        return metricItems
      end
      return metricItems
    end

    def getContainerMemoryMetricItems(metricJSON, hostName, memoryMetricNameToCollect, metricNametoReturn, metricPollTime, operatingSystem)
      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      timeDifference = (DateTime.now.to_time.to_i - @@telemetryMemoryMetricTimeTracker).abs
      timeDifferenceInMinutes = timeDifference / 60
      begin
        metricInfo = metricJSON
        metricInfo["pods"].each do |pod|
          podUid = pod["podRef"]["uid"]
          podName = pod["podRef"]["name"]
          podNamespace = pod["podRef"]["namespace"]
          if (!pod["containers"].nil?)
            pod["containers"].each do |container|
              containerName = container["name"]
              metricValue = container["memory"][memoryMetricNameToCollect]
              metricTime = metricPollTime #container["memory"]["time"]

              metricItem = {}
              metricItem["Timestamp"] = metricTime
              metricItem["Host"] = hostName
              metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_CONTAINER
              metricItem["InstanceName"] = clusterId + "/" + podUid + "/" + containerName
           
              metricCollection = {}
              metricCollection["CounterName"] = metricNametoReturn
              metricCollection["Value"] = metricValue

              metricItem["json_Collections"] = []
              metricCollections = []  
              metricCollections.push(metricCollection)        
              metricItem["json_Collections"] = metricCollections.to_json
              metricItems.push(metricItem) 

              #Telemetry about agent performance
              begin
                # we can only do this much now. Ideally would like to use the docker image repository to find our pods/containers
                # cadvisor does not have pod/container metadata. so would need more work to cache as pv & use
                if (podName.downcase.start_with?("omsagent-") && podNamespace.eql?("kube-system") && containerName.downcase.start_with?("omsagent") && ((metricNametoReturn.eql?(Constants::MEMORY_RSS_BYTES) && operatingSystem == "Linux") || (metricNametoReturn.eql?(Constants::MEMORY_WORKING_SET_BYTES) && operatingSystem == "Windows")))
                  if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES)
                    telemetryProps = {}
                    telemetryProps["PodName"] = podName
                    telemetryProps["ContainerName"] = containerName
                    telemetryProps["Computer"] = hostName
                    ApplicationInsightsUtility.sendMetricTelemetry(metricNametoReturn, metricValue, telemetryProps)
                  end
                end
              rescue => errorStr
                $log.warn("Exception while generating Telemetry from getcontainerMemoryMetricItems failed: #{errorStr} for metric #{memoryMetricNameToCollect}")
              end
            end
          end
        end
        # reset time outside pod iterator as we use one timer per metric for 2 pods (ds & rs)
        if (timeDifferenceInMinutes >= Constants::TELEMETRY_FLUSH_INTERVAL_IN_MINUTES && metricNametoReturn.eql?(Constants::MEMORY_RSS_BYTES))
          @@telemetryMemoryMetricTimeTracker = DateTime.now.to_time.to_i
        end
      rescue => error
        @Log.warn("getcontainerMemoryMetricItems failed: #{error} for metric #{memoryMetricNameToCollect}")
        @Log.warn metricJSON
        return metricItems
      end
      return metricItems
    end

    def getNodeMetricItem(metricJSON, hostName, metricCategory, metricNameToCollect, metricNametoReturn, metricPollTime)
      metricItem = {}
      clusterId = KubernetesApiClient.getClusterId
      begin
        metricInfo = metricJSON
        node = metricInfo["node"]
        nodeName = node["nodeName"]

        if !node[metricCategory].nil?
          metricValue = node[metricCategory][metricNameToCollect]
          metricTime = metricPollTime #node[metricCategory]["time"]
                 
          metricItem["Timestamp"] = metricTime
          metricItem["Host"] = hostName
          metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_NODE
          metricItem["InstanceName"] = clusterId + "/" + nodeName

         
          metricCollection = {}
          metricCollection["CounterName"] = metricNametoReturn
          metricCollection["Value"] = metricValue

          metricItem["json_Collections"] = []
          metricCollections = []               
          metricCollections.push(metricCollection)   
          metricItem["json_Collections"] = metricCollections.to_json               
        end
      rescue => error
        @Log.warn("getNodeMetricItem failed: #{error} for metric #{metricNameToCollect}")
        @Log.warn metricJSON
        return metricItem
      end
      return metricItem
    end

    def getNodeMetricItemRate(metricJSON, hostName, metricCategory, metricNameToCollect, metricNametoReturn, operatingSystem, metricPollTime)
      metricItem = {}
      clusterId = KubernetesApiClient.getClusterId
      begin
        metricInfo = metricJSON
        node = metricInfo["node"]
        nodeName = node["nodeName"]

        if !node[metricCategory].nil?
          metricValue = node[metricCategory][metricNameToCollect]
          metricTime = metricPollTime #node[metricCategory]["time"]

          #   if !(metricNameToCollect == "rxBytes" || metricNameToCollect == "txBytes" || metricNameToCollect == "usageCoreNanoSeconds")
          #     @Log.warn("getNodeMetricItemRate : rateMetric is supported only for rxBytes, txBytes & usageCoreNanoSeconds and not for #{metricNameToCollect}")
          if !(metricNameToCollect == "usageCoreNanoSeconds")
            @Log.warn("getNodeMetricItemRate : rateMetric is supported only for usageCoreNanoSeconds and not for #{metricNameToCollect}")
            return nil
            #   elsif metricNameToCollect == "rxBytes"
            #     if @@rxBytesLast.nil? || @@rxBytesTimeLast.nil? || @@rxBytesLast > metricValue #when kubelet is restarted the last condition will be true
            #       @@rxBytesLast = metricValue
            #       @@rxBytesTimeLast = metricTime
            #       return nil
            #     else
            #       metricRateValue = ((metricValue - @@rxBytesLast) * 1.0) / (DateTime.parse(metricTime).to_time - DateTime.parse(@@rxBytesTimeLast).to_time)
            #       @@rxBytesLast = metricValue
            #       @@rxBytesTimeLast = metricTime
            #       metricValue = metricRateValue
            #     end
            #   elsif metricNameToCollect == "txBytes"
            #     if @@txBytesLast.nil? || @@txBytesTimeLast.nil? || @@txBytesLast > metricValue #when kubelet is restarted the last condition will be true
            #       @@txBytesLast = metricValue
            #       @@txBytesTimeLast = metricTime
            #       return nil
            #     else
            #       metricRateValue = ((metricValue - @@txBytesLast) * 1.0) / (DateTime.parse(metricTime).to_time - DateTime.parse(@@txBytesTimeLast).to_time)
            #       @@txBytesLast = metricValue
            #       @@txBytesTimeLast = metricTime
            #       metricValue = metricRateValue
            #     end
          else
            if operatingSystem == "Linux"
              if @@nodeCpuUsageNanoSecondsLast.nil? || @@nodeCpuUsageNanoSecondsTimeLast.nil? || @@nodeCpuUsageNanoSecondsLast > metricValue #when kubelet is restarted the last condition will be true
                @@nodeCpuUsageNanoSecondsLast = metricValue
                @@nodeCpuUsageNanoSecondsTimeLast = metricTime
                return nil
              else
                timeDifference = DateTime.parse(metricTime).to_time - DateTime.parse(@@nodeCpuUsageNanoSecondsTimeLast).to_time
                nodeCpuUsageDifference = metricValue - @@nodeCpuUsageNanoSecondsLast
                # nodeCpuUsageDifference check is added to make sure we report non zero values when cadvisor returns same values for subsequent calls
                if timeDifference != 0 && nodeCpuUsageDifference != 0
                  metricRateValue = (nodeCpuUsageDifference * 1.0) / timeDifference
                else
                  @Log.info "linux node - cpu usage difference / time difference is 0, hence using previous cached value"
                  if !@@linuxNodePrevMetricRate.nil?
                    metricRateValue = @@linuxNodePrevMetricRate
                  else
                    # This can happen when the metric value returns same values for subsequent calls when the plugin first starts
                    metricRateValue = 0
                  end
                end
                @@nodeCpuUsageNanoSecondsLast = metricValue
                @@nodeCpuUsageNanoSecondsTimeLast = metricTime
                @@linuxNodePrevMetricRate = metricRateValue
                metricValue = metricRateValue
              end
            elsif operatingSystem == "Windows"
              # Using the hash for windows nodes since this is running in replica set and there can be multiple nodes
              if @@winNodeCpuUsageNanoSecondsLast[hostName].nil? || @@winNodeCpuUsageNanoSecondsTimeLast[hostName].nil? || @@winNodeCpuUsageNanoSecondsLast[hostName] > metricValue #when kubelet is restarted the last condition will be true
                @@winNodeCpuUsageNanoSecondsLast[hostName] = metricValue
                @@winNodeCpuUsageNanoSecondsTimeLast[hostName] = metricTime
                return nil
              else
                timeDifference = DateTime.parse(metricTime).to_time - DateTime.parse(@@winNodeCpuUsageNanoSecondsTimeLast[hostName]).to_time
                nodeCpuUsageDifference = metricValue - @@winNodeCpuUsageNanoSecondsLast[hostName]
                # nodeCpuUsageDifference check is added to make sure we report non zero values when cadvisor returns same values for subsequent calls
                if timeDifference != 0 && nodeCpuUsageDifference != 0
                  metricRateValue = (nodeCpuUsageDifference * 1.0) / timeDifference
                else
                  @Log.info "windows node - cpu usage difference / time difference is 0, hence using previous cached value"
                  if !@@winNodePrevMetricRate[hostName].nil?
                    metricRateValue = @@winNodePrevMetricRate[hostName]
                  else
                    # This can happen when the metric value returns same values for subsequent calls when the plugin first starts
                    metricRateValue = 0
                  end
                end
                @@winNodeCpuUsageNanoSecondsLast[hostName] = metricValue
                @@winNodeCpuUsageNanoSecondsTimeLast[hostName] = metricTime
                @@winNodePrevMetricRate[hostName] = metricRateValue
                metricValue = metricRateValue
              end
            end
          end
                  
          metricItem["Timestamp"] = metricTime
          metricItem["Host"] = hostName
          metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_NODE
          metricItem["InstanceName"] = clusterId + "/" + nodeName
     
          metricCollection = {}
          metricCollection["CounterName"] = metricNametoReturn
          metricCollection["Value"] = metricValue

          metricItem["json_Collections"] = []
          metricCollections = []               
          metricCollections.push(metricCollection)        
          metricItem["json_Collections"] = metricCollections.to_json
        end
      rescue => error
        @Log.warn("getNodeMetricItemRate failed: #{error} for metric #{metricNameToCollect}")
        @Log.warn metricJSON
        return nil
      end
      return metricItem
    end

    def getNodeLastRebootTimeMetric(metricJSON, hostName, metricNametoReturn, metricPollTime)
      metricItem = {}
      clusterId = KubernetesApiClient.getClusterId

      begin
        metricInfo = metricJSON
        node = metricInfo["node"]
        nodeName = node["nodeName"]

        metricValue = node["startTime"]
        metricTime = metricPollTime #Time.now.utc.iso8601 #2018-01-30T19:36:14Z

       
        metricItem["Timestamp"] = metricTime
        metricItem["Host"] = hostName
        metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_NODE
        metricItem["InstanceName"] = clusterId + "/" + nodeName

       
        metricCollection = {}
        metricCollection["CounterName"] = metricNametoReturn
        #Read it from /proc/uptime
        metricCollection["Value"] = DateTime.parse(metricTime).to_time.to_i - IO.read("/proc/uptime").split[0].to_f

        metricItem["json_Collections"] = []
        metricCollections = []               
        metricCollections.push(metricCollection)        
        metricItem["json_Collections"] = metricCollections.to_json
      rescue => error
        @Log.warn("getNodeLastRebootTimeMetric failed: #{error} ")
        @Log.warn metricJSON
        return metricItem
      end
      return metricItem
    end

    def getContainerStartTimeMetricItems(metricJSON, hostName, metricNametoReturn, metricPollTime)
      metricItems = []
      clusterId = KubernetesApiClient.getClusterId
      #currentTime = Time.now.utc.iso8601 #2018-01-30T19:36:14Z
      begin
        metricInfo = metricJSON
        metricInfo["pods"].each do |pod|
          podUid = pod["podRef"]["uid"]
          if (!pod["containers"].nil?)
            pod["containers"].each do |container|
              containerName = container["name"]
              metricValue = container["startTime"]
              metricTime = metricPollTime #currentTime

              metricItem = {}
              metricItem["Timestamp"] = metricTime
              metricItem["Host"] = hostName
              metricItem["ObjectName"] = Constants::OBJECT_NAME_K8S_CONTAINER
              metricItem["InstanceName"] = clusterId + "/" + podUid + "/" + containerName
            
              metricCollection = {}
              metricCollection["CounterName"] = metricNametoReturn
              metricCollection["Value"] = DateTime.parse(metricValue).to_time.to_i

              metricItem["json_Collections"] = []
              metricCollections = []               
              metricCollections.push(metricCollection)        
              metricItem["json_Collections"] = metricCollections.to_json
              metricItems.push(metricItem)
            end
          end
        end
      rescue => error
        @Log.warn("getContainerStartTimeMetric failed: #{error} for metric #{metricNametoReturn}")
        @Log.warn metricJSON
        return metricItems
      end
      return metricItems
    end

    def getResponse(winNode, relativeUri)
      response = nil
      @Log.info "Getting CAdvisor Uri Response"
      bearerToken = File.read("/var/run/secrets/kubernetes.io/serviceaccount/token")
      begin
        cAdvisorUri = getCAdvisorUri(winNode, relativeUri)
        @Log.info "cAdvisorUri: #{cAdvisorUri}"

        if !cAdvisorUri.nil?
          uri = URI.parse(cAdvisorUri)
          if isCAdvisorOnSecurePort()
            Net::HTTP.start(uri.host, uri.port,
                            :use_ssl => true, :open_timeout => 20, :read_timeout => 40,
                            :ca_file => "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
                            :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|
              cAdvisorApiRequest = Net::HTTP::Get.new(uri.request_uri)
              cAdvisorApiRequest["Authorization"] = "Bearer #{bearerToken}"
              response = http.request(cAdvisorApiRequest)
              @Log.info "Got response code #{response.code} from #{uri.request_uri}"
            end
          else
            Net::HTTP.start(uri.host, uri.port, :use_ssl => false, :open_timeout => 20, :read_timeout => 40) do |http|
              cAdvisorApiRequest = Net::HTTP::Get.new(uri.request_uri)
              response = http.request(cAdvisorApiRequest)
              @Log.info "Got response code #{response.code} from #{uri.request_uri}"
            end
          end
        end
      rescue => error
        @Log.warn("CAdvisor api request for #{cAdvisorUri} failed: #{error}")
        telemetryProps = {}
        if !winNode.nil?
          hostName = winNode["Hostname"]
        else
          hostName = (OMS::Common.get_hostname)
        end
        telemetryProps["Computer"] = hostName
        ApplicationInsightsUtility.sendExceptionTelemetry(error, telemetryProps)
      end
      return response
    end

    def isCAdvisorOnSecurePort
      cAdvisorSecurePort = false
      # Check to see whether omsagent needs to use 10255(insecure) port or 10250(secure) port
      if !@cAdvisorMetricsSecurePort.nil? && @cAdvisorMetricsSecurePort == "true"
        cAdvisorSecurePort = true
      end
      return cAdvisorSecurePort
    end
  end
end
