#!/usr/local/bin/ruby
# frozen_string_literal: true

class ApplicationInsightsUtility
  require_relative "lib/application_insights"
  require_relative "omslog"
  require_relative "DockerApiClient"
  require_relative "oms_common"
  require_relative "proxy_utils"
  require "yajl/json_gem"
  require "base64"

  @@HeartBeat = "HeartBeatEvent"
  @@Exception = "ExceptionEvent"
  @@AcsClusterType = "ACS"
  @@AksClusterType = "AKS"
  @@EnvAcsResourceName = "ACS_RESOURCE_NAME"
  @@EnvAksRegion = "AKS_REGION"
  @@EnvAgentVersion = "AGENT_VERSION"
  @@EnvApplicationInsightsKey = "APPLICATIONINSIGHTS_AUTH"
  @@EnvApplicationInsightsEndpoint = "APPLICATIONINSIGHTS_ENDPOINT"
  @@EnvControllerType = "CONTROLLER_TYPE"
  @@EnvContainerRuntime = "CONTAINER_RUNTIME"
  @@EnvAADMSIAuthMode = "AAD_MSI_AUTH_MODE"

  @@isWindows = false
  @@hostName = (OMS::Common.get_hostname)
  @@os_type = ENV["OS_TYPE"]
  if !@@os_type.nil? && !@@os_type.empty? && @@os_type.strip.casecmp("windows") == 0
    @@isWindows = true
    @@hostName = ENV["HOSTNAME"]
  end
  @@CustomProperties = {}
  @@Tc = nil
  @@proxy = (ProxyUtils.getProxyConfiguration)

  def initialize
  end

  class << self
    #Set default properties for telemetry event
    def initializeUtility()
      begin
        resourceInfo = ENV["AKS_RESOURCE_ID"]
        if resourceInfo.nil? || resourceInfo.empty?
          @@CustomProperties["ACSResourceName"] = ENV[@@EnvAcsResourceName]
          @@CustomProperties["ClusterType"] = @@AcsClusterType
          @@CustomProperties["SubscriptionID"] = ""
          @@CustomProperties["ResourceGroupName"] = ""
          @@CustomProperties["ClusterName"] = ""
          @@CustomProperties["Region"] = ""
        else
          @@CustomProperties["AKS_RESOURCE_ID"] = resourceInfo
          begin
            splitStrings = resourceInfo.split("/")
            subscriptionId = splitStrings[2]
            resourceGroupName = splitStrings[4]
            clusterName = splitStrings[8]
          rescue => errorStr
            $log.warn("Exception in AppInsightsUtility: parsing AKS resourceId: #{resourceInfo}, error: #{errorStr}")
          end
          @@CustomProperties["ClusterType"] = @@AksClusterType
          @@CustomProperties["SubscriptionID"] = subscriptionId
          @@CustomProperties["ResourceGroupName"] = resourceGroupName
          @@CustomProperties["ClusterName"] = clusterName
          @@CustomProperties["Region"] = ENV[@@EnvAksRegion]
        end

        #Commenting it for now from initilize method, we need to pivot all telemetry off of kubenode docker version
        #getDockerInfo()
        @@CustomProperties["WorkspaceID"] = getWorkspaceId
        @@CustomProperties["AgentVersion"] = ENV[@@EnvAgentVersion]
        @@CustomProperties["ControllerType"] = ENV[@@EnvControllerType]
        @@CustomProperties["Computer"] = @@hostName
        encodedAppInsightsKey = ENV[@@EnvApplicationInsightsKey]
        appInsightsEndpoint = ENV[@@EnvApplicationInsightsEndpoint]
        @@CustomProperties["WorkspaceCloud"] = getWorkspaceCloud
        if !@@proxy.nil? && !@@proxy.empty?
          $log.info("proxy configured")
          @@CustomProperties["IsProxyConfigured"] = "true"
          isProxyConfigured = true
        else
          @@CustomProperties["IsProxyConfigured"] = "false"
          isProxyConfigured = false
          $log.info("proxy is not configured")
        end
        aadAuthMSIMode = ENV[@@EnvAADMSIAuthMode]
        if !aadAuthMSIMode.nil? && !aadAuthMSIMode.empty? && aadAuthMSIMode.downcase == "true".downcase
          @@CustomProperties["aadAuthMSIMode"] = "true"
        else
          @@CustomProperties["aadAuthMSIMode"] = "false"
        end
        #Check if telemetry is turned off
        telemetryOffSwitch = ENV["DISABLE_TELEMETRY"]
        if telemetryOffSwitch && !telemetryOffSwitch.nil? && !telemetryOffSwitch.empty? && telemetryOffSwitch.downcase == "true".downcase
          $log.warn("AppInsightsUtility: Telemetry is disabled")
          @@Tc = ApplicationInsights::TelemetryClient.new
        elsif !encodedAppInsightsKey.nil?
          decodedAppInsightsKey = Base64.decode64(encodedAppInsightsKey)

          #override ai endpoint if its available otherwise use default.
          if appInsightsEndpoint && !appInsightsEndpoint.nil? && !appInsightsEndpoint.empty?
            $log.info("AppInsightsUtility: Telemetry client uses overrided endpoint url : #{appInsightsEndpoint}")
            #telemetrySynchronousSender = ApplicationInsights::Channel::SynchronousSender.new appInsightsEndpoint
            #telemetrySynchronousQueue = ApplicationInsights::Channel::SynchronousQueue.new(telemetrySynchronousSender)
            #telemetryChannel = ApplicationInsights::Channel::TelemetryChannel.new nil, telemetrySynchronousQueue
            if !isProxyConfigured
              sender = ApplicationInsights::Channel::AsynchronousSender.new appInsightsEndpoint
            else
              $log.info("AppInsightsUtility: Telemetry client uses provided proxy configuration since proxy configured")
              sender = ApplicationInsights::Channel::AsynchronousSender.new appInsightsEndpoint, @@proxy
            end
            queue = ApplicationInsights::Channel::AsynchronousQueue.new sender
            channel = ApplicationInsights::Channel::TelemetryChannel.new nil, queue
            @@Tc = ApplicationInsights::TelemetryClient.new decodedAppInsightsKey, channel
          else
            if !isProxyConfigured
              sender = ApplicationInsights::Channel::AsynchronousSender.new
            else
              $log.info("AppInsightsUtility: Telemetry client uses provided proxy configuration since proxy configured")
              sender = ApplicationInsights::Channel::AsynchronousSender.new nil, @@proxy
            end
            queue = ApplicationInsights::Channel::AsynchronousQueue.new sender
            channel = ApplicationInsights::Channel::TelemetryChannel.new nil, queue
            @@Tc = ApplicationInsights::TelemetryClient.new decodedAppInsightsKey, channel
          end
          # The below are default recommended values. If you change these, ensure you test telemetry flow fully

          # flush telemetry if we have 10 or more telemetry items in our queue
          #@@Tc.channel.queue.max_queue_length = 10

          # send telemetry to the service in batches of 5
          #@@Tc.channel.sender.send_buffer_size = 5

          # the background worker thread will be active for 5 seconds before it shuts down. if
          # during this time items are picked up from the queue, the timer is reset.
          #@@Tc.channel.sender.send_time = 5

          # the background worker thread will poll the queue every 0.5 seconds for new items
          #@@Tc.channel.sender.send_interval = 0.5
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: initilizeUtility - error: #{errorStr}")
      end
    end

    def getContainerRuntimeInfo()
      begin
        containerRuntime = ENV[@@EnvContainerRuntime]
        if !containerRuntime.nil? && !containerRuntime.empty?
          # DockerVersion field holds either containerRuntime for non-docker or Dockerversion if its docker
          @@CustomProperties["DockerVersion"] = containerRuntime
          # Not doing this for windows since docker is being deprecated soon and we dont want to bring in the socket dependency.
          if !@@isWindows.nil? && @@isWindows == false
            if containerRuntime.casecmp("docker") == 0
              dockerInfo = DockerApiClient.dockerInfo
              if (!dockerInfo.nil? && !dockerInfo.empty?)
                @@CustomProperties["DockerVersion"] = dockerInfo["Version"]
              end
            end
          end
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: getContainerRuntimeInfo - error: #{errorStr}")
      end
    end

    def sendHeartBeatEvent(pluginName)
      begin
        eventName = pluginName + @@HeartBeat
        if !(@@Tc.nil?)
          @@Tc.track_event eventName, :properties => @@CustomProperties
          $log.info("AppInsights Heartbeat Telemetry put successfully into the queue")
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendHeartBeatEvent - error: #{errorStr}")
      end
    end

    def sendLastProcessedContainerInventoryCountMetric(pluginName, properties)
      begin
        if !(@@Tc.nil?)
          @@Tc.track_metric "LastProcessedContainerInventoryCount", properties["ContainerCount"],
                            :kind => ApplicationInsights::Channel::Contracts::DataPointType::MEASUREMENT,
                            :properties => @@CustomProperties
          $log.info("AppInsights Container Count Telemetry sput successfully into the queue")
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendCustomMetric - error: #{errorStr}")
      end
    end

    def sendCustomEvent(eventName, properties)
      begin
        if @@CustomProperties.empty? || @@CustomProperties.nil?
          initializeUtility()
        end
        telemetryProps = {}
        # add common dimensions
        @@CustomProperties.each { |k, v| telemetryProps[k] = v }
        # add passed-in dimensions if any
        if (!properties.nil? && !properties.empty?)
          properties.each { |k, v| telemetryProps[k] = v }
        end
        if !(@@Tc.nil?)
          @@Tc.track_event eventName, :properties => telemetryProps
          $log.info("AppInsights Custom Event #{eventName} sent successfully")
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendCustomEvent - error: #{errorStr}")
      end
    end

    def sendExceptionTelemetry(errorStr, properties = nil)
      begin
        if @@CustomProperties.empty? || @@CustomProperties.nil?
          initializeUtility()
        elsif @@CustomProperties["DockerVersion"].nil?
          getContainerRuntimeInfo()
        end
        telemetryProps = {}
        # add common dimensions
        @@CustomProperties.each { |k, v| telemetryProps[k] = v }
        # add passed-in dimensions if any
        if (!properties.nil? && !properties.empty?)
          properties.each { |k, v| telemetryProps[k] = v }
        end
        if !(@@Tc.nil?)
          @@Tc.track_exception errorStr, :properties => telemetryProps
          $log.info("AppInsights Exception Telemetry put successfully into the queue")
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendExceptionTelemetry - error: #{errorStr}")
      end
    end

    #Method to send heartbeat and container inventory count
    def sendTelemetry(pluginName, properties)
      begin
        if @@CustomProperties.empty? || @@CustomProperties.nil?
          initializeUtility()
        elsif @@CustomProperties["DockerVersion"].nil?
          getContainerRuntimeInfo()
        end
        @@CustomProperties["Computer"] = properties["Computer"]
        sendHeartBeatEvent(pluginName)
        sendLastProcessedContainerInventoryCountMetric(pluginName, properties)
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendTelemetry - error: #{errorStr}")
      end
    end

    #Method to send metric. It will merge passed-in properties with common custom properties
    def sendMetricTelemetry(metricName, metricValue, properties)
      begin
        if (metricName.empty? || metricName.nil?)
          $log.warn("SendMetricTelemetry: metricName is missing")
          return
        end
        if @@CustomProperties.empty? || @@CustomProperties.nil?
          initializeUtility()
        elsif @@CustomProperties["DockerVersion"].nil?
          getContainerRuntimeInfo()
        end
        telemetryProps = {}
        # add common dimensions
        @@CustomProperties.each { |k, v| telemetryProps[k] = v }
        # add passed-in dimensions if any
        if (!properties.nil? && !properties.empty?)
          properties.each { |k, v| telemetryProps[k] = v }
        end
        if !(@@Tc.nil?)
          @@Tc.track_metric metricName, metricValue,
                            :kind => ApplicationInsights::Channel::Contracts::DataPointType::MEASUREMENT,
                            :properties => telemetryProps
          $log.info("AppInsights metric Telemetry #{metricName} put successfully into the queue")
        end
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: sendMetricTelemetry - error: #{errorStr}")
      end
    end

    def getWorkspaceId()
      begin
        workspaceId = ENV["WSID"]
        if workspaceId.nil? || workspaceId.empty?
          $log.warn("Exception in AppInsightsUtility: getWorkspaceId - WorkspaceID either nil or empty")
        end
        return workspaceId
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: getWorkspaceId - error: #{errorStr}")
      end
    end

    def getWorkspaceCloud()
      begin
        workspaceDomain = ENV["DOMAIN"]
        workspaceCloud = "AzureCloud"
        if workspaceDomain.casecmp("opinsights.azure.com") == 0
          workspaceCloud = "AzureCloud"
        elsif workspaceDomain.casecmp("opinsights.azure.cn") == 0
          workspaceCloud = "AzureChinaCloud"
        elsif workspaceDomain.casecmp("opinsights.azure.us") == 0
          workspaceCloud = "AzureUSGovernment"
        elsif workspaceDomain.casecmp("opinsights.azure.de") == 0
          workspaceCloud = "AzureGermanCloud"
        else
          workspaceCloud = "Unknown"
        end
        return workspaceCloud
      rescue => errorStr
        $log.warn("Exception in AppInsightsUtility: getWorkspaceCloud - error: #{errorStr}")
      end
    end
  end
end
