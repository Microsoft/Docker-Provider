require "socket"
require "msgpack"
require "securerandom"
require "singleton"
require_relative "omslog"
require_relative "constants"
require_relative "ApplicationInsightsUtility"


class Extension
  include Singleton

  def initialize
    @cache = {}
    @cache_lock = Mutex.new
    $log.info("Extension::initialize complete")
  end

  def get_output_stream_id(datatypeId)
    @cache_lock.synchronize {
      if @cache.has_key?(datatypeId)
        return @cache[datatypeId]
      else
        @cache = get_config()
        return @cache[datatypeId]
      end
    }
  end

  private
  def get_config()
    extConfig = Hash.new
    $log.info("Extension::get_config start ...")
    begin
      clientSocket = UNIXSocket.open(Constants::ONEAGENT_FLUENT_SOCKET_NAME)
      requestId = SecureRandom.uuid.to_s
      requestBodyJSON = { "Request" => "AgentTaggedData", "RequestId" => requestId, "Tag" => Constants::CI_EXTENSION_NAME, "Version" => Constants::CI_EXTENSION_VERSION }.to_json
      $log.info("Extension::get_config::sending request with request body: #{requestBodyJSON}")
      requestBodyMsgPack = requestBodyJSON.to_msgpack
      clientSocket.write(requestBodyMsgPack)
      clientSocket.flush
      $log.info("reading the response from fluent socket: #{Constants::ONEAGENT_FLUENT_SOCKET_NAME}")
      resp = clientSocket.recv(Constants::CI_EXTENSION_CONFIG_MAX_BYTES)
      if !resp.nil? && !resp.empty?
        $log.info("Extension::get_config::successfully read the extension config from fluentsocket and number of bytes read is #{resp.length}")
        respJSON = JSON.parse(resp)
        taggedData = respJSON["TaggedData"]
        if !taggedData.nil? && !taggedData.empty?
          taggedAgentData = JSON.parse(taggedData)
          extensionConfigurations = taggedAgentData["extensionConfigurations"]
          if !extensionConfigurations.nil? && !extensionConfigurations.empty?
            extensionConfigurations.each do |extensionConfig|
              outputStreams = extensionConfig["outputStreams"]
              if !outputStreams.nil? && !outputStreams.empty?
                outputStreams.each do |datatypeId, streamId|
                  $log.info("Extension::get_config datatypeId:#{datatypeId}, streamId: #{streamId}")
                  extConfig[datatypeId] = streamId
                end
              else
                $log.warn("Extension::get_config::received outputStreams is either nil or empty")
              end
            end
          else
            $log.warn("Extension::get_config::received extensionConfigurations from fluentsocket is either nil or empty")
          end
        end
      end
    rescue => errorStr
      $log.warn("Extension::get_config failed: #{errorStr}")
      ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
    ensure
      clientSocket.close unless clientSocket.nil?
    end
    $log.info("Extension::get_config complete ...")
    return extConfig
  end
end
