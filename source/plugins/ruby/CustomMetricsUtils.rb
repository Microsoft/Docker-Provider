#!/usr/local/bin/ruby
# frozen_string_literal: true

class CustomMetricsUtils
    def initialize
    end

    class << self
        def check_custom_metrics_availability
            aks_region = ENV['AKS_REGION']
            aks_resource_id = ENV['AKS_RESOURCE_ID']
            aks_cloud_environment = ENV['CLOUD_ENVIRONMENT']
            if aks_region.to_s.empty? || aks_resource_id.to_s.empty?
                return false # This will also take care of AKS-Engine Scenario. AKS_REGION/AKS_RESOURCE_ID is not set for AKS-Engine. Only ACS_RESOURCE_NAME is set
            end

            return aks_cloud_environment.to_s.downcase == 'azurepubliccloud'
        end
    end
end