#!/usr/local/bin/ruby
# frozen_string_literal: true

require 'fluent/plugin/output'

module Fluent::Plugin
  class OutputMDM < Output
    config_param :retry_mdm_post_wait_minutes, :integer
    Fluent::Plugin.register_output("mdm", self)

    def initialize
      super
      require "net/http"
      require "net/https"
      require "uri"
      require "yajl/json_gem"
      require_relative "KubernetesApiClient"
      require_relative "ApplicationInsightsUtility"
      require_relative "constants"
      require_relative "arc_k8s_cluster_identity"
      require_relative "proxy_utils"

      @@token_resource_url = "https://monitoring.azure.com/"
      # AAD auth supported only in public cloud and handle other clouds when enabled
      # this is unified new token audience for LA AAD MSI auth & metrics
      @@token_resource_audience = "https://monitor.azure.com/"
      @@grant_type = "client_credentials"
      @@azure_json_path = "/etc/kubernetes/host/azure.json"
      @@post_request_url_template = "https://%{aks_region}.monitoring.azure.com%{aks_resource_id}/metrics"
      @@aad_token_url_template = "https://login.microsoftonline.com/%{tenant_id}/oauth2/token"

      # msiEndpoint is the well known endpoint for getting MSI authentications tokens
      @@msi_endpoint_template = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&client_id=%{user_assigned_client_id}&resource=%{resource}"
      # IMDS msiEndpoint for AAD MSI Auth is the proxy endpoint whcih serves the MSI auth tokens with resource claim
      @@imds_msi_endpoint_template = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=%{resource}"
      @@user_assigned_client_id = ENV["USER_ASSIGNED_IDENTITY_CLIENT_ID"]

      @@plugin_name = "AKSCustomMetricsMDM"
      @@record_batch_size = 2000 #2600 at times exceeds 1MB, not safe

      @@token_refresh_back_off_interval = 30

      @data_hash = {}
      @parsed_token_uri = nil
      @http_client = nil
      @token_expiry_time = Time.now
      @cached_access_token = String.new
      @last_post_attempt_time = Time.now
      @first_post_attempt_made = false
      @can_send_data_to_mdm = true
      @last_telemetry_sent_time = nil
      # Setting useMsi to false by default
      @useMsi = false
      @isAADMSIAuth = false
      @metrics_flushed_count = 0

      @cluster_identity = nil
      @isArcK8sCluster = false
      @get_access_token_backoff_expiry = Time.now

      @mdm_exceptions_hash = {}
      @mdm_exceptions_count = 0
      @mdm_exception_telemetry_time_tracker = DateTime.now.to_time.to_i
    end

    def configure(conf)
      super
    end

    def start
      super
      begin
        aks_resource_id = ENV["AKS_RESOURCE_ID"]
        aks_region = ENV["AKS_REGION"]

        if aks_resource_id.to_s.empty?
          @log.info "Environment Variable AKS_RESOURCE_ID is not set.. "
          @can_send_data_to_mdm = false
        elsif !aks_resource_id.downcase.include?("/microsoft.containerservice/managedclusters/") && !aks_resource_id.downcase.include?("/microsoft.kubernetes/connectedclusters/")
          @log.info "MDM Metris not supported for this cluster type resource: #{aks_resource_id}"
          @can_send_data_to_mdm = false
        end

        if aks_region.to_s.empty?
          @log.info "Environment Variable AKS_REGION is not set.. "
          @can_send_data_to_mdm = false
        else
          aks_region = aks_region.gsub(" ", "")
        end

        if @can_send_data_to_mdm
          @log.info "MDM Metrics supported in #{aks_region} region"

          if aks_resource_id.downcase.include?("microsoft.kubernetes/connectedclusters")
            @isArcK8sCluster = true
          end
          @@post_request_url = @@post_request_url_template % { aks_region: aks_region, aks_resource_id: aks_resource_id }
          @post_request_uri = URI.parse(@@post_request_url)
          if (!!@isArcK8sCluster)
            proxy = (ProxyUtils.getProxyConfiguration)
            if proxy.nil? || proxy.empty?
              @http_client = Net::HTTP.new(@post_request_uri.host, @post_request_uri.port)
            else
              @log.info "Proxy configured on this cluster: #{aks_resource_id}"
              @http_client = Net::HTTP.new(@post_request_uri.host, @post_request_uri.port, proxy[:addr], proxy[:port], proxy[:user], proxy[:pass])
            end
          else
            @http_client = Net::HTTP.new(@post_request_uri.host, @post_request_uri.port)
          end
          @http_client.use_ssl = true
          @log.info "POST Request url: #{@@post_request_url}"
          ApplicationInsightsUtility.sendCustomEvent("AKSCustomMetricsMDMPluginStart", {})

          # arc k8s cluster uses cluster identity
          if (!!@isArcK8sCluster)
            @log.info "using cluster identity token since cluster is azure arc k8s cluster"
            @cluster_identity = ArcK8sClusterIdentity.new
            @cached_access_token = @cluster_identity.get_cluster_identity_token
          else
            # azure json file only used for aks and doesnt exist in non-azure envs
            file = File.read(@@azure_json_path)
            @data_hash = JSON.parse(file)
            # Check to see if SP exists, if it does use SP. Else, use msi
            sp_client_id = @data_hash["aadClientId"]
            sp_client_secret = @data_hash["aadClientSecret"]

            if (!sp_client_id.nil? && !sp_client_id.empty? && sp_client_id.downcase != "msi")
              @useMsi = false
              aad_token_url = @@aad_token_url_template % { tenant_id: @data_hash["tenantId"] }
              @parsed_token_uri = URI.parse(aad_token_url)
            else
              @useMsi = true
              if !@@user_assigned_client_id.nil? && !@@user_assigned_client_id.empty?
                msi_endpoint = @@msi_endpoint_template % { user_assigned_client_id: @@user_assigned_client_id, resource: @@token_resource_url }
              else
                # in case of aad msi auth user_assigned_client_id will be empty
                @log.info "using aad msi auth"
                @isAADMSIAuth = true
                msi_endpoint = @@imds_msi_endpoint_template % { resource: @@token_resource_audience }
              end
              @parsed_token_uri = URI.parse(msi_endpoint)
            end

            @cached_access_token = get_access_token
          end
        end
      rescue => e
        @log.info "exception when initializing out_mdm #{e}"
        ApplicationInsightsUtility.sendExceptionTelemetry(e, { "FeatureArea" => "MDM" })
        return
      end
    end

    # get the access token only if the time to expiry is less than 5 minutes and get_access_token_backoff has expired
    def get_access_token
      if (Time.now > @get_access_token_backoff_expiry)
        http_access_token = nil
        retries = 0
        begin
          if @cached_access_token.to_s.empty? || (Time.now + 5 * 60 > @token_expiry_time) # Refresh token 5 minutes from expiration
            @log.info "Refreshing access token for out_mdm plugin.."

            if (!!@useMsi)
              properties = {}
              if (!!@isAADMSIAuth)
                @log.info "Using aad msi auth to get the token to post MDM data"
                properties["aadAuthMSIMode"] = "true"
              else
                @log.info "Using msi to get the token to post MDM data"
              end
              ApplicationInsightsUtility.sendCustomEvent("AKSCustomMetricsMDMToken-MSI", properties)
              @log.info "Opening TCP connection"
              http_access_token = Net::HTTP.start(@parsed_token_uri.host, @parsed_token_uri.port, :use_ssl => false)
              # http_access_token.use_ssl = false
              token_request = Net::HTTP::Get.new(@parsed_token_uri.request_uri)
              token_request["Metadata"] = true
            else
              @log.info "Using SP to get the token to post MDM data"
              ApplicationInsightsUtility.sendCustomEvent("AKSCustomMetricsMDMToken-SP", {})
              @log.info "Opening TCP connection"
              http_access_token = Net::HTTP.start(@parsed_token_uri.host, @parsed_token_uri.port, :use_ssl => true)
              # http_access_token.use_ssl = true
              token_request = Net::HTTP::Post.new(@parsed_token_uri.request_uri)
              token_request.set_form_data(
                {
                  "grant_type" => @@grant_type,
                  "client_id" => @data_hash["aadClientId"],
                  "client_secret" => @data_hash["aadClientSecret"],
                  "resource" => @@token_resource_url,
                }
              )
            end

            @log.info "making request to get token.."
            token_response = http_access_token.request(token_request)
            # Handle the case where the response is not 200
            parsed_json = JSON.parse(token_response.body)
            @token_expiry_time = Time.now + @@token_refresh_back_off_interval * 60 # set the expiry time to be ~ thirty minutes from current time
            @cached_access_token = parsed_json["access_token"]
            @log.info "Successfully got access token"
          end
        rescue => err
          @log.info "Exception in get_access_token: #{err}"
          if (retries < 2)
            retries += 1
            @log.info "Retrying request to get token - retry number: #{retries}"
            sleep(retries)
            retry
          else
            @get_access_token_backoff_expiry = Time.now + @@token_refresh_back_off_interval * 60
            @log.info "@get_access_token_backoff_expiry set to #{@get_access_token_backoff_expiry}"
            ApplicationInsightsUtility.sendExceptionTelemetry(err, { "FeatureArea" => "MDM" })
          end
        ensure
          if http_access_token
            @log.info "Closing http connection"
            http_access_token.finish
          end
        end
      end
      @cached_access_token
    end

    def write_status_file(success, message)
      fn = "/var/opt/microsoft/docker-cimprov/log/MDMIngestion.status"
      status = '{ "operation": "MDMIngestion", "success": "%s", "message": "%s" }' % [success, message]
      begin
        File.open(fn, "w") { |file| file.write(status) }
      rescue => e
        @log.debug "Error:'#{e}'"
        ApplicationInsightsUtility.sendExceptionTelemetry(e)
      end
    end

    # This method is called when an event reaches to Fluentd.
    # Convert the event to a raw string.
    def format(tag, time, record)
      if record != {}
        @log.trace "Buffering #{tag}"
        return [tag, record].to_msgpack
      else
        return ""
      end
    end

    def exception_aggregator(error)
      begin
        errorStr = error.to_s
        if (@mdm_exceptions_hash[errorStr].nil?)
          @mdm_exceptions_hash[errorStr] = 1
        else
          @mdm_exceptions_hash[errorStr] += 1
        end
        #Keeping track of all exceptions to send the total in the last flush interval as a metric
        @mdm_exceptions_count += 1
      rescue => error
        @log.info "Error in MDM exception_aggregator method: #{error}"
        ApplicationInsightsUtility.sendExceptionTelemetry(error)
      end
    end

    def flush_mdm_exception_telemetry
      begin
        #Flush out exception telemetry as a metric for the last 30 minutes
        timeDifference = (DateTime.now.to_time.to_i - @mdm_exception_telemetry_time_tracker).abs
        timeDifferenceInMinutes = timeDifference / 60
        if (timeDifferenceInMinutes >= Constants::MDM_EXCEPTIONS_METRIC_FLUSH_INTERVAL)
          telemetryProperties = {}
          telemetryProperties["ExceptionsHashForFlushInterval"] = @mdm_exceptions_hash.to_json
          telemetryProperties["FlushInterval"] = Constants::MDM_EXCEPTIONS_METRIC_FLUSH_INTERVAL
          ApplicationInsightsUtility.sendMetricTelemetry(Constants::MDM_EXCEPTION_TELEMETRY_METRIC, @mdm_exceptions_count, telemetryProperties)
          # Resetting values after flushing
          @mdm_exceptions_count = 0
          @mdm_exceptions_hash = {}
          @mdm_exception_telemetry_time_tracker = DateTime.now.to_time.to_i
        end
      rescue => error
        @log.info "Error in flush_mdm_exception_telemetry method: #{error}"
        ApplicationInsightsUtility.sendExceptionTelemetry(error)
      end
    end

    # This method is called every flush interval. Send the buffer chunk to MDM.
    # 'chunk' is a buffer chunk that includes multiple formatted records
    def write(chunk)
      begin
        # Adding this before trying to flush out metrics, since adding after can lead to metrics never being sent
        flush_mdm_exception_telemetry
        if (!@first_post_attempt_made || (Time.now > @last_post_attempt_time + retry_mdm_post_wait_minutes * 60)) && @can_send_data_to_mdm
          post_body = []
          chunk.extend Fluent::ChunkMessagePackEventStreamer
          chunk.msgpack_each { |(tag, record)|
            post_body.push(record.to_json)
          }
          # the limit of the payload is 1MB. Each record is ~300 bytes. using a batch size of 2600, so that
          # the pay load size becomes approximately 800 Kb.
          count = post_body.size
          while count > 0
            current_batch = post_body.first(@@record_batch_size)
            post_body = post_body.drop(current_batch.size)
            count -= current_batch.size
            send_to_mdm current_batch
          end
        else
          if !@can_send_data_to_mdm
            @log.info "Cannot send data to MDM since all required conditions were not met"
          else
            @log.info "Last Failed POST attempt to MDM was made #{((Time.now - @last_post_attempt_time) / 60).round(1)} min ago. This is less than the current retry threshold of #{@retry_mdm_post_wait_minutes} min. NO-OP"
          end
        end
      rescue Exception => e
        # Adding exceptions to hash to aggregate and send telemetry for all write errors
        exception_aggregator(e)
        @log.info "Exception when writing to MDM: #{e}"
        raise e
      end
    end

    def send_to_mdm(post_body)
      begin
        if (!!@isArcK8sCluster)
          if @cluster_identity.nil?
            @cluster_identity = ArcK8sClusterIdentity.new
          end
          access_token = @cluster_identity.get_cluster_identity_token
        else
          access_token = get_access_token
        end
        request = Net::HTTP::Post.new(@post_request_uri.request_uri)
        request["Content-Type"] = "application/x-ndjson"
        request["Authorization"] = "Bearer #{access_token}"

        request.body = post_body.join("\n")
        @log.info "REQUEST BODY SIZE #{request.body.bytesize / 1024}"
        response = @http_client.request(request)
        response.value # this throws for non 200 HTTP response code
        @log.info "HTTP Post Response Code : #{response.code}"
        if @last_telemetry_sent_time.nil? || @last_telemetry_sent_time + 60 * 60 < Time.now
          ApplicationInsightsUtility.sendCustomEvent("AKSCustomMetricsMDMSendSuccessful", {})
          @last_telemetry_sent_time = Time.now
        end
      rescue Net::HTTPClientException  => e # see https://docs.ruby-lang.org/en/2.6.0/NEWS.html about deprecating HTTPServerException and adding HTTPClientException
        if !response.nil? && !response.body.nil? #body will have actual error
          @log.info "Failed to Post Metrics to MDM : #{e} Response.body: #{response.body}"
        else
          @log.info "Failed to Post Metrics to MDM : #{e} Response: #{response}"
        end
        @log.debug_backtrace(e.backtrace)
        if !response.code.empty? && response.code == 403.to_s
          @log.info "Response Code #{response.code} Updating @last_post_attempt_time"
          @last_post_attempt_time = Time.now
          @first_post_attempt_made = true
          # Not raising exception, as that will cause retries to happen
        elsif !response.code.empty? && response.code.start_with?("4")
          # Log 400 errors and continue
          @log.info "Non-retryable HTTPClientException when POSTing Metrics to MDM #{e} Response: #{response}"
        else
          # raise if the response code is non-400
          @log.info "HTTPServerException when POSTing Metrics to MDM #{e} Response: #{response}"
          raise e
        end
        # Adding exceptions to hash to aggregate and send telemetry for all 400 error codes
        exception_aggregator(e)
      rescue Errno::ETIMEDOUT => e
        @log.info "Timed out when POSTing Metrics to MDM : #{e} Response: #{response}"
        @log.debug_backtrace(e.backtrace)
        raise e
      rescue Exception => e
        @log.info "Exception POSTing Metrics to MDM : #{e} Response: #{response}"
        @log.debug_backtrace(e.backtrace)
        raise e
      end
    end
  end # class OutputMDM
end # module Fluent
