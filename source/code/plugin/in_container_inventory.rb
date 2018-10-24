#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent

  class Container_Inventory_Input < Input
    Plugin.register_input('containerinventory', self)

    def initialize
      super
      require 'json'
      require_relative 'DockerApiClient'
      require_relative 'omslog'
    end

    config_param :run_interval, :time, :default => '1m'
    config_param :tag, :string, :default => "oms.containerinsights.ContainerInventory"
  
    def configure (conf)
      super
    end

    def start
      if @run_interval
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
      end
    end

    def obtainContainerConfig(instance, container)
      begin
      configValue = container['Config']
      if !configValue.nil?
        instance['ContainerHostname'] = configValue['Hostname']

        envValue = configValue['Env']
        envValueString = (envValue.nil?) ? "" : envValue.to_s
        instance['EnvironmentVar'] = envValueString

        cmdValue = configValue['Cmd']
        cmdValueString = (cmdValue.nil?) ? "" : cmdValue.to_s
        instance['Command'] = cmdValueString

        instance['ComposeGroup'] = ""
        labelsValue = configValue['Labels']
        if !labelsValue.nil? && !labelsValue.empty?
          instance['ComposeGroup'] = labelsValue['com.docker.compose.project']
        end
      else
        $log.warn("Attempt in ObtainContainerConfig to get container #{container['Id']} config information returned null")
      end
      rescue => errorStr
        $log.warn("Exception in obtainContainerConfig: #{errorStr}")
      end
    end

    def obtainContainerState(instance, container)
      begin
      stateValue = container['State']
      if !stateValue.nil?
        exitCodeValue  = stateValue['ExitCode']
        # Exit codes less than 0 are not supported by the engine
        if exitCodeValue < 0
          exitCodeValue =  128
          $log.info("obtainContainerState::Container #{container['Id']} returned negative exit code")
        end
        instance['ExitCode'] = exitCodeValue
        if exitCodeValue > 0
          instance['State'] = "Failed"
        else
          # Set the Container status : Running/Paused/Stopped
          runningValue = stateValue['Running']
          if runningValue
            pausedValue = stateValue['Paused']
            # Checking for paused within running is true state because docker returns true for both Running and Paused fields when the container is paused
            if pausedValue
              instance['State'] = "Paused"
            else
              instance['State'] = "Running"
            end
          else
            instance['State'] = "Stopped"
          end
        end
      else
        $log.info("Attempt in ObtainContainerState to get container: #{container['Id']} state information returned null")
      end
      rescue => errorStr
        $log.warn("Exception in obtainContainerState: #{errorStr}")
      end
    end

    def obtainContainerHostConfig(instance, container)
      hostConfig = container['HostConfig']
      if !hostConfig.nil?
        links = hostConfig['Links']
        if !links.nil?
          linksString = links.to_s
          instance['Links'] = (linksString == "null")? "" : links
        end
        portBindings = hostConfig['PortBindings']
        if !portBindings.nil?
          portBindings.to_s
          instance['Ports'] = (portBindings == "null")? "" : portBindings
        end
      end
    end

    def inspectContainer(id, nameMap)
      containerInstance = {}
      request = DockerApiRestHelper.restDockerInspect(id)
      container = getResponse(request, false)
      if !container.nil? && !container.empty?
        containerInstance['InstanceID'] = container['Id']
        containerInstance['CreatedTime'] = container['Created']
        containerName = container['Name']
        if !containerName.nil? && !containerName.empty?
          # Remove the leading / from the name if it exists (this is an API issue)
          containerInstance['ElementName'] = (containerName[0] == '/') ? containerName[1..-1] : containerName
        end
        imageValue = container['Image']
        if !imageValue.nil? && !imageValue.empty?
          containerInstance['ImageId'] = imageValue
          repoImageTagArray = nameMap['imageValue']
          if nameMap.has_key? imageValue
            containerInstance['Repository'] = repoImageTagArray[0]
            containerInstance['Image'] = repoImageTagArray[1]
            containerInstance['ImageTag'] = repoImageTagArray[2]
          end
        end
        obtainContainerConfig(containerInstance, container);
        obtainContainerState(containerInstance, container);
        obtainContainerHostConfig(containerInstance, container);
      end


    end


    def enumerate
      currentTime = Time.now
      emitTime = currentTime.to_f
      batchTime = currentTime.utc.iso8601
      $log.info("in_container_inventory::enumerate : Begin processing @ #{Time.now.utc.iso8601}")
      hostname = DockerApiClient.getDockerHostName
      begin
        containerIds = DockerApiClient.listContainers
        nameMap = DockerApiClient.getImageIdMap
        containerIds.each do |containerId|
          inspectedContainer = {}
          inspectedContainer = inspectContainer(containerId, nameMap)
          inspectedContainer['Computer'] = hostname
        end




        eventStream = MultiEventStream.new
        record = {}
        record['myhost'] = myhost
        eventStream.add(emitTime, record) if record
        router.emit_stream(@tag, eventStream) if eventStream
      rescue => errorStr

      end
    end

    def run_periodic
      @mutex.lock
      done = @finished
      until done
        @condition.wait(@mutex, @run_interval)
        done = @finished
        @mutex.unlock
        if !done
          begin
            $log.info("in_container_inventory::run_periodic @ #{Time.now.utc.iso8601}")
            enumerate
          rescue => errorStr
            $log.warn "in_container_inventory::run_periodic: enumerate Failed to retrieve docker container inventory: #{errorStr}"
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

  end # Container_Inventory_Input

end # module