#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/input'

module Fluent::Plugin
  class Kube_Event_Input < Input
    Fluent::Plugin.register_input("kube_events", self)
    @@KubeEventsStateFile = "/var/opt/microsoft/docker-cimprov/state/KubeEventQueryState.yaml"

    def initialize
      super
      require "yajl/json_gem"
      require "yajl"
      require "time"

      require_relative "KubernetesApiClient"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "ApplicationInsightsUtility"
      require_relative "extension_utils"

      # refer tomlparser-agent-config for defaults
      # this configurable via configmap
      @EVENTS_CHUNK_SIZE = 0

      # Initializing events count for telemetry
      @eventsCount = 0

      # Initilize enable/disable normal event collection
      @collectAllKubeEvents = false
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oneagent.containerInsights.KUBE_EVENTS_BLOB"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        super
        if !ENV["EVENTS_CHUNK_SIZE"].nil? && !ENV["EVENTS_CHUNK_SIZE"].empty? && ENV["EVENTS_CHUNK_SIZE"].to_i > 0
          @EVENTS_CHUNK_SIZE = ENV["EVENTS_CHUNK_SIZE"].to_i
        else
          # this shouldnt happen just setting default here as safe guard
          $log.warn("in_kube_events::start: setting to default value since got EVENTS_CHUNK_SIZE nil or empty")
          @EVENTS_CHUNK_SIZE = 4000
        end
        $log.info("in_kube_events::start : EVENTS_CHUNK_SIZE  @ #{@EVENTS_CHUNK_SIZE}")

        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        collectAllKubeEventsSetting = ENV["AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS"]
        if !collectAllKubeEventsSetting.nil? && !collectAllKubeEventsSetting.empty?
          if collectAllKubeEventsSetting.casecmp("false") == 0
            @collectAllKubeEvents = false
            $log.warn("Normal kube events collection disabled for cluster")
          else
            @collectAllKubeEvents = true
            $log.warn("Normal kube events collection enabled for cluster")
          end
        end
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
        eventList = nil
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601
        eventQueryState = getEventQueryState
        newEventQueryState = []
        @eventsCount = 0

        if ExtensionUtils.isAADMSIAuthMode()
          $log.info("in_kube_events::enumerate: AAD AUTH MSI MODE")
          if @tag.nil? || !@tag.start_with?(Constants::EXTENSION_OUTPUT_STREAM_ID_TAG_PREFIX)
            @tag = ExtensionUtils.getOutputStreamId(Constants::KUBE_EVENTS_DATA_TYPE)
          end
          $log.info("in_kube_events::enumerate: using kubeevents tag -#{@tag} @ #{Time.now.utc.iso8601}")
        end
        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kube_events::enumerate : Getting events from Kube API @ #{Time.now.utc.iso8601}")
        if @collectAllKubeEvents
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?limit=#{@EVENTS_CHUNK_SIZE}")
        else
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?fieldSelector=type!=Normal&limit=#{@EVENTS_CHUNK_SIZE}")
        end
        $log.info("in_kube_events::enumerate : Done getting events from Kube API @ #{Time.now.utc.iso8601}")
        if (!eventList.nil? && !eventList.empty? && eventList.key?("items") && !eventList["items"].nil? && !eventList["items"].empty?)
          eventsCount = eventList["items"].length
          $log.info "in_kube_events::enumerate:Received number of events in eventList is #{eventsCount} @ #{Time.now.utc.iso8601}"
          newEventQueryState = parse_and_emit_records(eventList, eventQueryState, newEventQueryState, batchTime)
        else
          $log.warn "in_kube_events::enumerate:Received empty eventList"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?fieldSelector=type!=Normal&limit=#{@EVENTS_CHUNK_SIZE}&continue=#{continuationToken}")
          if (!eventList.nil? && !eventList.empty? && eventList.key?("items") && !eventList["items"].nil? && !eventList["items"].empty?)
            eventsCount = eventList["items"].length
            $log.info "in_kube_events::enumerate:Received number of events in eventList is #{eventsCount} @ #{Time.now.utc.iso8601}"
            newEventQueryState = parse_and_emit_records(eventList, eventQueryState, newEventQueryState, batchTime)
          else
            $log.warn "in_kube_events::enumerate:Received empty eventList"
          end
        end

        # Setting this to nil so that we dont hold memory until GC kicks in
        eventList = nil
        writeEventQueryState(newEventQueryState)

        # Flush AppInsights telemetry once all the processing is done, only if the number of events flushed is greater than 0
        if (@eventsCount > 0)
          ApplicationInsightsUtility.sendMetricTelemetry("EventCount", @eventsCount, {})
        end
      rescue => errorStr
        $log.warn "in_kube_events::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end # end enumerate

    def parse_and_emit_records(events, eventQueryState, newEventQueryState, batchTime = Time.utc.iso8601)
      currentTime = Time.now
      emitTime = Fluent::Engine.now
      @@istestvar = ENV["ISTEST"]
      begin
        eventStream = Fluent::MultiEventStream.new
        events["items"].each do |items|
          record = {}
          #<BUGBUG> - Not sure if ingestion has the below mapping for this custom type. Fix it as part of fixed type conversion
          record["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
          eventId = items["metadata"]["uid"] + "/" + items["count"].to_s
          newEventQueryState.push(eventId)
          if !eventQueryState.empty? && eventQueryState.include?(eventId)
            next
          end

          nodeName = items["source"].key?("host") ? items["source"]["host"] : (OMS::Common.get_hostname)
          # For ARO v3 cluster, drop the master and infra node sourced events to ingest
          if KubernetesApiClient.isAROV3Cluster && !nodeName.nil? && !nodeName.empty? &&
             (nodeName.downcase.start_with?("infra-") || nodeName.downcase.start_with?("master-"))
            next
          end

          record["ObjectKind"] = items["involvedObject"]["kind"]
          record["Namespace"] = items["involvedObject"]["namespace"]
          record["Name"] = items["involvedObject"]["name"]
          record["Reason"] = items["reason"]
          record["Message"] = items["message"]
          record["KubeEventType"] = items["type"]
          record["TimeGenerated"] = items["metadata"]["creationTimestamp"]
          record["SourceComponent"] = items["source"]["component"]
          record["FirstSeen"] = items["firstTimestamp"]
          record["LastSeen"] = items["lastTimestamp"]
          record["Count"] = items["count"]
          record["Computer"] = nodeName
          record["ClusterName"] = KubernetesApiClient.getClusterName
          record["ClusterId"] = KubernetesApiClient.getClusterId
          eventStream.add(emitTime, record) if record
          @eventsCount += 1
        end
        router.emit_stream(@tag, eventStream) if eventStream
        if (!@@istestvar.nil? && !@@istestvar.empty? && @@istestvar.casecmp("true") == 0)
          $log.info("kubeEventsInventoryEmitStreamSuccess @ #{Time.now.utc.iso8601}")
        end
      rescue => errorStr
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      return newEventQueryState
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
            $log.info("in_kube_events::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_events::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_events::run_periodic: enumerate Failed to retrieve kube events: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    def getEventQueryState
      eventQueryState = []
      begin
        if File.file?(@@KubeEventsStateFile)
          # Do not read the entire file in one shot as it spikes memory (50+MB) for ~5k events
          File.foreach(@@KubeEventsStateFile) do |line|
            eventQueryState.push(line.chomp) #puts will append newline which needs to be removed
          end
        end
      rescue => errorStr
        $log.warn $log.warn line.dump, error: errorStr.to_s
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      return eventQueryState
    end

    def writeEventQueryState(eventQueryState)
      begin
        if (!eventQueryState.nil? && !eventQueryState.empty?)
          # No need to close file handle (f) due to block scope
          File.open(@@KubeEventsStateFile, "w") do |f|
            f.puts(eventQueryState)
          end
        end
      rescue => errorStr
        $log.warn $log.warn line.dump, error: errorStr.to_s
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end
  end # Kube_Event_Input
end # module
