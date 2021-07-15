#!/bin/bash

waitforlisteneronTCPport() {
      local sleepdurationsecs=1
      local totalsleptsecs=0
      local port=$1
      local waittimesecs=$2
      local numeric='^[0-9]+$'
      local varlistener=""

      if [ -z "$1" ] || [ -z "$2" ]; then
            echo "${FUNCNAME[0]} called with incorrect arguments<$1 , $2>. Required arguments <#port, #wait-time-in-seconds>"
            return -1
      else

            if [[ $port =~ $numeric ]] && [[ $waittimesecs =~ $numeric ]]; then
                  #local varlistener=$(netstat -lnt | awk '$6 == "LISTEN" && $4 ~ ":25228$"')
                  while true
                  do
                        if [ $totalsleptsecs -gt $waittimesecs ]; then
                              echo "${FUNCNAME[0]} giving up waiting for listener on port:$port after $totalsleptsecs secs"
                              return 1
                        fi
                        varlistener=$(netstat -lnt | awk '$6 == "LISTEN" && $4 ~ ":'"$port"'$"')
                        if [ -z "$varlistener" ]; then
                              #echo "${FUNCNAME[0]} waiting for $sleepdurationsecs more sec for listener on port:$port ..."
                              sleep $sleepdurationsecs
                              totalsleptsecs=$(($totalsleptsecs+1))
                        else
                              echo "${FUNCNAME[0]} found listener on port:$port in $totalsleptsecs secs"
                              return 0
                        fi
                  done
            else
                  echo "${FUNCNAME[0]} called with non-numeric arguments<$1 , $2>. Required arguments <#port, #wait-time-in-seconds>"
                  return -1
            fi
      fi
}

#using /var/opt/microsoft/docker-cimprov/state instead of /var/opt/microsoft/omsagent/state since the latter gets deleted during onboarding
mkdir -p /var/opt/microsoft/docker-cimprov/state

#Run inotify as a daemon to track changes to the mounted configmap.
inotifywait /etc/config/settings --daemon --recursive --outfile "/opt/inotifyoutput.txt" --event create,delete --format '%e : %T' --timefmt '+%s'

#Run inotify as a daemon to track changes to the mounted configmap for OSM settings.
if [[ ( ( ! -e "/etc/config/kube.conf" ) && ( "${CONTAINER_TYPE}" == "PrometheusSidecar" ) ) ||
      ( ( -e "/etc/config/kube.conf" ) && ( "${SIDECAR_SCRAPING_ENABLED}" == "false" ) ) ]]; then
      inotifywait /etc/config/osm-settings --daemon --recursive --outfile "/opt/inotifyoutput-osm.txt" --event create,delete --format '%e : %T' --timefmt '+%s'
fi

#resourceid override for loganalytics data.
if [ -z $AKS_RESOURCE_ID ]; then
      echo "not setting customResourceId"
else
      export customResourceId=$AKS_RESOURCE_ID
      echo "export customResourceId=$AKS_RESOURCE_ID" >> ~/.bashrc
      source ~/.bashrc
      echo "customResourceId:$customResourceId"
      export customRegion=$AKS_REGION
      echo "export customRegion=$AKS_REGION" >> ~/.bashrc
      source ~/.bashrc
      echo "customRegion:$customRegion"
fi

#set agent config schema version
if [  -e "/etc/config/settings/schema-version" ] && [  -s "/etc/config/settings/schema-version" ]; then
      #trim
      config_schema_version="$(cat /etc/config/settings/schema-version | xargs)"
      #remove all spaces
      config_schema_version="${config_schema_version//[[:space:]]/}"
      #take first 10 characters
      config_schema_version="$(echo $config_schema_version| cut -c1-10)"

      export AZMON_AGENT_CFG_SCHEMA_VERSION=$config_schema_version
      echo "export AZMON_AGENT_CFG_SCHEMA_VERSION=$config_schema_version" >> ~/.bashrc
      source ~/.bashrc
      echo "AZMON_AGENT_CFG_SCHEMA_VERSION:$AZMON_AGENT_CFG_SCHEMA_VERSION"
fi

#set agent config file version
if [  -e "/etc/config/settings/config-version" ] && [  -s "/etc/config/settings/config-version" ]; then
      #trim
      config_file_version="$(cat /etc/config/settings/config-version | xargs)"
      #remove all spaces
      config_file_version="${config_file_version//[[:space:]]/}"
      #take first 10 characters
      config_file_version="$(echo $config_file_version| cut -c1-10)"

      export AZMON_AGENT_CFG_FILE_VERSION=$config_file_version
      echo "export AZMON_AGENT_CFG_FILE_VERSION=$config_file_version" >> ~/.bashrc
      source ~/.bashrc
      echo "AZMON_AGENT_CFG_FILE_VERSION:$AZMON_AGENT_CFG_FILE_VERSION"
fi

#set OSM config schema version
if [[ ( ( ! -e "/etc/config/kube.conf" ) && ( "${CONTAINER_TYPE}" == "PrometheusSidecar" ) ) ||
      ( ( -e "/etc/config/kube.conf" ) && ( "${SIDECAR_SCRAPING_ENABLED}" == "false" ) ) ]]; then
      if [  -e "/etc/config/osm-settings/schema-version" ] && [  -s "/etc/config/osm-settings/schema-version" ]; then
            #trim
            osm_config_schema_version="$(cat /etc/config/osm-settings/schema-version | xargs)"
            #remove all spaces
            osm_config_schema_version="${osm_config_schema_version//[[:space:]]/}"
            #take first 10 characters
            osm_config_schema_version="$(echo $osm_config_schema_version| cut -c1-10)"

            export AZMON_OSM_CFG_SCHEMA_VERSION=$osm_config_schema_version
            echo "export AZMON_OSM_CFG_SCHEMA_VERSION=$osm_config_schema_version" >> ~/.bashrc
            source ~/.bashrc
            echo "AZMON_OSM_CFG_SCHEMA_VERSION:$AZMON_OSM_CFG_SCHEMA_VERSION"
      fi
fi

export PROXY_ENDPOINT=""
# Check for internet connectivity or workspace deletion
if [ -e "/etc/omsagent-secret/WSID" ]; then
      workspaceId=$(cat /etc/omsagent-secret/WSID)
      if [ -e "/etc/omsagent-secret/DOMAIN" ]; then
            domain=$(cat /etc/omsagent-secret/DOMAIN)
      else
            domain="opinsights.azure.com"
      fi

      if [ -e "/etc/omsagent-secret/PROXY" ]; then
            export PROXY_ENDPOINT=$(cat /etc/omsagent-secret/PROXY)
            # Validate Proxy Endpoint URL
            # extract the protocol://
            proto="$(echo $PROXY_ENDPOINT | grep :// | sed -e's,^\(.*://\).*,\1,g')"
            # convert the protocol prefix in lowercase for validation
            proxyprotocol=$(echo $proto | tr "[:upper:]" "[:lower:]")
            if [ "$proxyprotocol" != "http://" -a "$proxyprotocol" != "https://" ]; then
               echo "-e error proxy endpoint should be in this format http(s)://<user>:<pwd>@<hostOrIP>:<port>"
            fi
            # remove the protocol
            url="$(echo ${PROXY_ENDPOINT/$proto/})"
            # extract the creds
            creds="$(echo $url | grep @ | cut -d@ -f1)"
            user="$(echo $creds | cut -d':' -f1)"
            pwd="$(echo $creds | cut -d':' -f2)"
            # extract the host and port
            hostport="$(echo ${url/$creds@/} | cut -d/ -f1)"
            # extract host without port
            host="$(echo $hostport | sed -e 's,:.*,,g')"
            # extract the port
            port="$(echo $hostport | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"

            if [ -z "$user" -o -z "$pwd" -o -z "$host" -o -z "$port" ]; then
               echo "-e error proxy endpoint should be in this format http(s)://<user>:<pwd>@<hostOrIP>:<port>"
            else
               echo "successfully validated provided proxy endpoint is valid and expected format"
            fi
      fi

      if [ ! -z "$PROXY_ENDPOINT" ]; then
         echo "Making curl request to oms endpint with domain: $domain and proxy: $PROXY_ENDPOINT"
         curl --max-time 10 https://$workspaceId.oms.$domain/AgentService.svc/LinuxAgentTopologyRequest --proxy $PROXY_ENDPOINT
      else
         echo "Making curl request to oms endpint with domain: $domain"
         curl --max-time 10 https://$workspaceId.oms.$domain/AgentService.svc/LinuxAgentTopologyRequest
      fi

      if [ $? -ne 0 ]; then
            if [ ! -z "$PROXY_ENDPOINT" ]; then
               echo "Making curl request to ifconfig.co with proxy: $PROXY_ENDPOINT"
               RET=`curl --max-time 10 -s -o /dev/null -w "%{http_code}" ifconfig.co --proxy $PROXY_ENDPOINT`
            else
               echo "Making curl request to ifconfig.co"
               RET=`curl --max-time 10 -s -o /dev/null -w "%{http_code}" ifconfig.co`
            fi
            if [ $RET -eq 000 ]; then
                  echo "-e error    Error resolving host during the onboarding request. Check the internet connectivity and/or network policy on the cluster"
            else
                  # Retrying here to work around network timing issue
                  if [ ! -z "$PROXY_ENDPOINT" ]; then
                    echo "ifconfig check succeeded, retrying oms endpoint with proxy..."
                    curl --max-time 10 https://$workspaceId.oms.$domain/AgentService.svc/LinuxAgentTopologyRequest --proxy $PROXY_ENDPOINT
                  else
                    echo "ifconfig check succeeded, retrying oms endpoint..."
                    curl --max-time 10 https://$workspaceId.oms.$domain/AgentService.svc/LinuxAgentTopologyRequest
                  fi

                  if [ $? -ne 0 ]; then
                        echo "-e error    Error resolving host during the onboarding request. Workspace might be deleted."
                  else
                        echo "curl request to oms endpoint succeeded with retry."
                  fi
            fi
      else
            echo "curl request to oms endpoint succeeded."
      fi
else
      echo "LA Onboarding:Workspace Id not mounted, skipping the telemetry check"
fi


# Set environment variable for if public cloud by checking the workspace domain.
if [ -z $domain ]; then
  ClOUD_ENVIRONMENT="unknown"
elif [ $domain == "opinsights.azure.com" ]; then
  CLOUD_ENVIRONMENT="azurepubliccloud"
elif [ $domain == "opinsights.azure.cn" ]; then
  CLOUD_ENVIRONMENT="azurechinacloud"
elif [ $domain == "opinsights.azure.us" ]; then
  CLOUD_ENVIRONMENT="azureusgovernmentcloud"
elif [ $domain == "opinsights.azure.eaglex.ic.gov" ]; then
  CLOUD_ENVIRONMENT="usnat"
elif [ $domain == "opinsights.azure.microsoft.scloud" ]; then
  CLOUD_ENVIRONMENT="ussec"
fi
export CLOUD_ENVIRONMENT=$CLOUD_ENVIRONMENT
echo "export CLOUD_ENVIRONMENT=$CLOUD_ENVIRONMENT" >> ~/.bashrc

#consisten naming conventions with the windows
export DOMAIN=$domain
echo "export DOMAIN=$DOMAIN" >> ~/.bashrc
export WSID=$workspaceId
echo "export WSID=$WSID" >> ~/.bashrc

# Check if the instrumentation key needs to be fetched from a storage account (as in airgapped clouds)
if [ ${#APPLICATIONINSIGHTS_AUTH_URL} -ge 1 ]; then  # (check if APPLICATIONINSIGHTS_AUTH_URL has length >=1)
      for BACKOFF in {1..4}; do
            KEY=$(curl -sS $APPLICATIONINSIGHTS_AUTH_URL )
            # there's no easy way to get the HTTP status code from curl, so just check if the result is well formatted
            if [[ $KEY =~ ^[A-Za-z0-9=]+$ ]]; then
                  break
            else
                  sleep $((2**$BACKOFF / 4))  # (exponential backoff)
            fi
      done

      # validate that the retrieved data is an instrumentation key
      if [[ $KEY =~ ^[A-Za-z0-9=]+$ ]]; then
            export APPLICATIONINSIGHTS_AUTH=$(echo $KEY)
            echo "export APPLICATIONINSIGHTS_AUTH=$APPLICATIONINSIGHTS_AUTH" >> ~/.bashrc
            echo "Using cloud-specific instrumentation key"
      else
            # no ikey can be retrieved. Disable telemetry and continue
            export DISABLE_TELEMETRY=true
            echo "export DISABLE_TELEMETRY=true" >> ~/.bashrc
            echo "Could not get cloud-specific instrumentation key (network error?). Disabling telemetry"
      fi
fi


aikey=$(echo $APPLICATIONINSIGHTS_AUTH | base64 --decode)
export TELEMETRY_APPLICATIONINSIGHTS_KEY=$aikey
echo "export TELEMETRY_APPLICATIONINSIGHTS_KEY=$aikey" >> ~/.bashrc

source ~/.bashrc

if [ "${CONTAINER_TYPE}" != "PrometheusSidecar" ]; then
      #Parse the configmap to set the right environment variables.
      /usr/bin/ruby2.6 tomlparser.rb

      cat config_env_var | while read line; do
            echo $line >> ~/.bashrc
      done
      source config_env_var
fi

#Parse the configmap to set the right environment variables for agent config.
#Note > tomlparser-agent-config.rb has to be parsed first before td-agent-bit-conf-customizer.rb for fbit agent settings
if [ "${CONTAINER_TYPE}" != "PrometheusSidecar" ]; then
      /usr/bin/ruby2.6 tomlparser-agent-config.rb

      cat agent_config_env_var | while read line; do
            #echo $line
            echo $line >> ~/.bashrc
      done
      source agent_config_env_var

      #Parse the configmap to set the right environment variables for network policy manager (npm) integration.
      /usr/bin/ruby2.6 tomlparser-npm-config.rb

      cat integration_npm_config_env_var | while read line; do
            #echo $line
            echo $line >> ~/.bashrc
      done
      source integration_npm_config_env_var
fi

#Replace the placeholders in td-agent-bit.conf file for fluentbit with custom/default values in daemonset
if [ ! -e "/etc/config/kube.conf" ] && [ "${CONTAINER_TYPE}" != "PrometheusSidecar" ]; then
      /usr/bin/ruby2.6 td-agent-bit-conf-customizer.rb
fi

#Parse the prometheus configmap to create a file with new custom settings.
/usr/bin/ruby2.6 tomlparser-prom-customconfig.rb

#Setting default environment variables to be used in any case of failure in the above steps
if [ ! -e "/etc/config/kube.conf" ]; then
      if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ]; then
            cat defaultpromenvvariables-sidecar | while read line; do
                  echo $line >> ~/.bashrc
            done
            source defaultpromenvvariables-sidecar
      else
            cat defaultpromenvvariables | while read line; do
                  echo $line >> ~/.bashrc
            done
            source defaultpromenvvariables
      fi
else
      cat defaultpromenvvariables-rs | while read line; do
            echo $line >> ~/.bashrc
      done
      source defaultpromenvvariables-rs
fi

#Sourcing telemetry environment variable file if it exists
if [ -e "telemetry_prom_config_env_var" ]; then
      cat telemetry_prom_config_env_var | while read line; do
            echo $line >> ~/.bashrc
      done
      source telemetry_prom_config_env_var
fi

#Parse sidecar agent settings for custom configuration
if [ ! -e "/etc/config/kube.conf" ]; then
      if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ]; then
            #Parse the agent configmap to create a file with new custom settings.
            /usr/bin/ruby2.6 tomlparser-prom-agent-config.rb
            #Sourcing config environment variable file if it exists
            if [ -e "side_car_fbit_config_env_var" ]; then
                  cat side_car_fbit_config_env_var | while read line; do
                        echo $line >> ~/.bashrc
                  done
                  source side_car_fbit_config_env_var
            fi
      fi
fi


#Parse the configmap to set the right environment variables for MDM metrics configuration for Alerting.
if [ "${CONTAINER_TYPE}" != "PrometheusSidecar" ]; then
      /usr/bin/ruby2.6 tomlparser-mdm-metrics-config.rb

      cat config_mdm_metrics_env_var | while read line; do
            echo $line >> ~/.bashrc
      done
      source config_mdm_metrics_env_var

      #Parse the configmap to set the right environment variables for metric collection settings
      /usr/bin/ruby2.6 tomlparser-metric-collection-config.rb

      cat config_metric_collection_env_var | while read line; do
            echo $line >> ~/.bashrc
      done
      source config_metric_collection_env_var
fi

# OSM scraping to be done in replicaset if sidecar car scraping is disabled and always do the scraping from the sidecar (It will always be either one of the two)
if [[ ( ( ! -e "/etc/config/kube.conf" ) && ( "${CONTAINER_TYPE}" == "PrometheusSidecar" ) ) ||
      ( ( -e "/etc/config/kube.conf" ) && ( "${SIDECAR_SCRAPING_ENABLED}" == "false" ) ) ]]; then
      /usr/bin/ruby2.6 tomlparser-osm-config.rb

      if [ -e "integration_osm_config_env_var" ]; then
            cat integration_osm_config_env_var | while read line; do
                  echo $line >> ~/.bashrc
            done
            source integration_osm_config_env_var
      fi
fi

#Setting environment variable for CAdvisor metrics to use port 10255/10250 based on curl request
echo "Making wget request to cadvisor endpoint with port 10250"
#Defaults to use port 10255
cAdvisorIsSecure=false
RET_CODE=`wget --server-response https://$NODE_IP:10250/stats/summary --no-check-certificate --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" 2>&1 | awk '/^  HTTP/{print $2}'`
if [ $RET_CODE -eq 200 ]; then
      cAdvisorIsSecure=true
fi

# default to docker since this is default in AKS as of now and change to containerd once this becomes default in AKS
export CONTAINER_RUNTIME="docker"
export NODE_NAME=""

if [ "$cAdvisorIsSecure" = true ]; then
      echo "Wget request using port 10250 succeeded. Using 10250"
      export IS_SECURE_CADVISOR_PORT=true
      echo "export IS_SECURE_CADVISOR_PORT=true" >> ~/.bashrc
      export CADVISOR_METRICS_URL="https://$NODE_IP:10250/metrics"
      echo "export CADVISOR_METRICS_URL=https://$NODE_IP:10250/metrics" >> ~/.bashrc
      echo "Making curl request to cadvisor endpoint /pods with port 10250 to get the configured container runtime on kubelet"
      podWithValidContainerId=$(curl -s -k -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" https://$NODE_IP:10250/pods | jq -R 'fromjson? | [ .items[] | select( any(.status.phase; contains("Running")) ) ] | .[0]')
else
      echo "Wget request using port 10250 failed. Using port 10255"
      export IS_SECURE_CADVISOR_PORT=false
      echo "export IS_SECURE_CADVISOR_PORT=false" >> ~/.bashrc
      export CADVISOR_METRICS_URL="http://$NODE_IP:10255/metrics"
      echo "export CADVISOR_METRICS_URL=http://$NODE_IP:10255/metrics" >> ~/.bashrc
      echo "Making curl request to cadvisor endpoint with port 10255 to get the configured container runtime on kubelet"
      podWithValidContainerId=$(curl -s http://$NODE_IP:10255/pods | jq -R 'fromjson? | [ .items[] | select( any(.status.phase; contains("Running")) ) ] | .[0]')
fi

if [ ! -z "$podWithValidContainerId" ]; then
      containerRuntime=$(echo $podWithValidContainerId | jq -r '.status.containerStatuses[0].containerID' | cut -d ':' -f 1)
      nodeName=$(echo $podWithValidContainerId | jq -r '.spec.nodeName')
      # convert to lower case so that everywhere else can be used in lowercase
      containerRuntime=$(echo $containerRuntime | tr "[:upper:]" "[:lower:]")
      nodeName=$(echo $nodeName | tr "[:upper:]" "[:lower:]")
      # update runtime only if its not empty, not null and not startswith docker
      if [ -z "$containerRuntime" -o "$containerRuntime" == null  ]; then
            echo "using default container runtime as $CONTAINER_RUNTIME since got containeRuntime as empty or null"
      elif [[ $containerRuntime != docker* ]]; then
            export CONTAINER_RUNTIME=$containerRuntime
      fi

      if [ -z "$nodeName" -o "$nodeName" == null  ]; then
            echo "-e error nodeName in /pods API response is empty"
      else
            export NODE_NAME=$nodeName
      fi
else
      echo "-e error either /pods API request failed or no running pods"
fi

echo "configured container runtime on kubelet is : "$CONTAINER_RUNTIME
echo "export CONTAINER_RUNTIME="$CONTAINER_RUNTIME >> ~/.bashrc

export KUBELET_RUNTIME_OPERATIONS_TOTAL_METRIC="kubelet_runtime_operations_total"
echo "export KUBELET_RUNTIME_OPERATIONS_TOTAL_METRIC="$KUBELET_RUNTIME_OPERATIONS_TOTAL_METRIC >> ~/.bashrc
export KUBELET_RUNTIME_OPERATIONS_ERRORS_TOTAL_METRIC="kubelet_runtime_operations_errors_total"
echo "export KUBELET_RUNTIME_OPERATIONS_ERRORS_TOTAL_METRIC="$KUBELET_RUNTIME_OPERATIONS_ERRORS_TOTAL_METRIC >> ~/.bashrc

# default to docker metrics
export KUBELET_RUNTIME_OPERATIONS_METRIC="kubelet_docker_operations"
export KUBELET_RUNTIME_OPERATIONS_ERRORS_METRIC="kubelet_docker_operations_errors"

if [ "$CONTAINER_RUNTIME" != "docker" ]; then
   # these metrics are avialble only on k8s versions <1.18 and will get deprecated from 1.18
   export KUBELET_RUNTIME_OPERATIONS_METRIC="kubelet_runtime_operations"
   export KUBELET_RUNTIME_OPERATIONS_ERRORS_METRIC="kubelet_runtime_operations_errors"
fi

echo "set caps for ruby process to read container env from proc"
sudo setcap cap_sys_ptrace,cap_dac_read_search+ep /usr/bin/ruby2.6
echo "export KUBELET_RUNTIME_OPERATIONS_METRIC="$KUBELET_RUNTIME_OPERATIONS_METRIC >> ~/.bashrc
echo "export KUBELET_RUNTIME_OPERATIONS_ERRORS_METRIC="$KUBELET_RUNTIME_OPERATIONS_ERRORS_METRIC >> ~/.bashrc

source ~/.bashrc

echo $NODE_NAME > /var/opt/microsoft/docker-cimprov/state/containerhostname
#check if file was written successfully.
cat /var/opt/microsoft/docker-cimprov/state/containerhostname

#start cron daemon for logrotate
service cron start
#get  docker-provider versions

dpkg -l | grep docker-cimprov | awk '{print $2 " " $3}'

DOCKER_CIMPROV_VERSION=$(dpkg -l | grep docker-cimprov | awk '{print $3}')
echo "DOCKER_CIMPROV_VERSION=$DOCKER_CIMPROV_VERSION"
export DOCKER_CIMPROV_VERSION=$DOCKER_CIMPROV_VERSION
echo "export DOCKER_CIMPROV_VERSION=$DOCKER_CIMPROV_VERSION" >> ~/.bashrc

#skip imds lookup since not used either legacy or aad msi auth path
export SKIP_IMDS_LOOKUP_FOR_LEGACY_AUTH="true"
echo "export SKIP_IMDS_LOOKUP_FOR_LEGACY_AUTH=$SKIP_IMDS_LOOKUP_FOR_LEGACY_AUTH" >> ~/.bashrc
# this used by mdsd to determine cloud specific LA endpoints
export OMS_TLD=$domain
echo "export OMS_TLD=$OMS_TLD" >> ~/.bashrc
cat /etc/mdsd.d/envmdsd | while read line; do
   echo $line >> ~/.bashrc
done
source /etc/mdsd.d/envmdsd
MDSD_AAD_MSI_AUTH_ARGS=""
# check if its AAD Auth MSI mode via USING_AAD_MSI_AUTH
export AAD_MSI_AUTH_MODE=false
if [ "${USING_AAD_MSI_AUTH}" == "true" ]; then
   echo "*** activating oneagent in aad auth msi mode ***"
   # msi auth specific args
   MDSD_AAD_MSI_AUTH_ARGS="-a -A"
   export AAD_MSI_AUTH_MODE=true
   echo "export AAD_MSI_AUTH_MODE=true" >> ~/.bashrc
   # this used by mdsd to determine the cloud specific AMCS endpoints
   export customEnvironment=$CLOUD_ENVIRONMENT
   echo "export customEnvironment=$customEnvironment" >> ~/.bashrc
   export MDSD_FLUENT_SOCKET_PORT="28230"
   echo "export MDSD_FLUENT_SOCKET_PORT=$MDSD_FLUENT_SOCKET_PORT" >> ~/.bashrc
   export ENABLE_MCS="true"
   echo "export ENABLE_MCS=$ENABLE_MCS" >> ~/.bashrc
   export MONITORING_USE_GENEVA_CONFIG_SERVICE="false"
   echo "export MONITORING_USE_GENEVA_CONFIG_SERVICE=$MONITORING_USE_GENEVA_CONFIG_SERVICE" >> ~/.bashrc
   export MDSD_USE_LOCAL_PERSISTENCY="false"
   echo "export MDSD_USE_LOCAL_PERSISTENCY=$MDSD_USE_LOCAL_PERSISTENCY" >> ~/.bashrc
else
  echo "*** activating oneagent in legacy auth mode ***"
  CIWORKSPACE_id="$(cat /etc/omsagent-secret/WSID)"
  #use the file path as its secure than env
  CIWORKSPACE_keyFile="/etc/omsagent-secret/KEY"
  echo "setting mdsd workspaceid & key for workspace:$CIWORKSPACE_id"
  export CIWORKSPACE_id=$CIWORKSPACE_id
  echo "export CIWORKSPACE_id=$CIWORKSPACE_id" >> ~/.bashrc
  export CIWORKSPACE_keyFile=$CIWORKSPACE_keyFile
  echo "export CIWORKSPACE_keyFile=$CIWORKSPACE_keyFile" >> ~/.bashrc
  export MDSD_FLUENT_SOCKET_PORT="29230"
  echo "export MDSD_FLUENT_SOCKET_PORT=$MDSD_FLUENT_SOCKET_PORT" >> ~/.bashrc
fi
source ~/.bashrc

dpkg -l | grep mdsd | awk '{print $2 " " $3}'

if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ]; then
    echo "starting mdsd with mdsd-port=26130, fluentport=26230 and influxport=26330 in sidecar container..."
    #use tenant name to avoid unix socket conflict and different ports for port conflict
    #roleprefix to use container specific mdsd socket
    export TENANT_NAME="${CONTAINER_TYPE}"
    echo "export TENANT_NAME=$TENANT_NAME" >> ~/.bashrc
    export MDSD_ROLE_PREFIX=/var/run/mdsd-${CONTAINER_TYPE}/default
    echo "export MDSD_ROLE_PREFIX=$MDSD_ROLE_PREFIX" >> ~/.bashrc
    source ~/.bashrc
    mkdir /var/run/mdsd-${CONTAINER_TYPE}
    # add -T 0xFFFF for full traces
    mdsd ${MDSD_AAD_MSI_AUTH_ARGS} -r ${MDSD_ROLE_PREFIX} -p 26130 -f 26230 -i 26330 -e ${MDSD_LOG}/mdsd.err -w ${MDSD_LOG}/mdsd.warn -o ${MDSD_LOG}/mdsd.info -q ${MDSD_LOG}/mdsd.qos &
else
    echo "starting mdsd mode in main container..."
    # add -T 0xFFFF for full traces
    mdsd ${MDSD_AAD_MSI_AUTH_ARGS} -e ${MDSD_LOG}/mdsd.err -w ${MDSD_LOG}/mdsd.warn -o ${MDSD_LOG}/mdsd.info -q ${MDSD_LOG}/mdsd.qos &
fi

# no dependency on fluentd for prometheus side car container
if [ "${CONTAINER_TYPE}" != "PrometheusSidecar" ]; then
      if [ ! -e "/etc/config/kube.conf" ]; then
         echo "*** starting fluentd v1 in daemonset"
         fluentd -c /etc/fluent/container.conf -o /var/opt/microsoft/docker-cimprov/log/fluentd.log --log-rotate-age 5 --log-rotate-size 20971520 &
      else
        echo "*** starting fluentd v1 in replicaset"
        fluentd -c /etc/fluent/kube.conf -o /var/opt/microsoft/docker-cimprov/log/fluentd.log --log-rotate-age 5 --log-rotate-size 20971520 &
      fi
fi

#If config parsing was successful, a copy of the conf file with replaced custom settings file is created
if [ ! -e "/etc/config/kube.conf" ]; then
      if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ] && [ -e "/opt/telegraf-test-prom-side-car.conf" ]; then
            echo "****************Start Telegraf in Test Mode**************************"
            /opt/telegraf --config /opt/telegraf-test-prom-side-car.conf --input-filter file -test
            if [ $? -eq 0 ]; then
                  mv "/opt/telegraf-test-prom-side-car.conf" "/etc/opt/microsoft/docker-cimprov/telegraf-prom-side-car.conf"
                  echo "Moving test conf file to telegraf side-car conf since test run succeeded"
            fi
            echo "****************End Telegraf Run in Test Mode**************************"
      else
            if [ -e "/opt/telegraf-test.conf" ]; then
                  echo "****************Start Telegraf in Test Mode**************************"
                  /opt/telegraf --config /opt/telegraf-test.conf --input-filter file -test
                  if [ $? -eq 0 ]; then
                        mv "/opt/telegraf-test.conf" "/etc/opt/microsoft/docker-cimprov/telegraf.conf"
                        echo "Moving test conf file to telegraf daemonset conf since test run succeeded"
                  fi
                  echo "****************End Telegraf Run in Test Mode**************************"
            fi
      fi
else
      if [ -e "/opt/telegraf-test-rs.conf" ]; then
                  echo "****************Start Telegraf in Test Mode**************************"
                  /opt/telegraf --config /opt/telegraf-test-rs.conf --input-filter file -test
                  if [ $? -eq 0 ]; then
                        mv "/opt/telegraf-test-rs.conf" "/etc/opt/microsoft/docker-cimprov/telegraf-rs.conf"
                        echo "Moving test conf file to telegraf replicaset conf since test run succeeded"
                  fi
                  echo "****************End Telegraf Run in Test Mode**************************"
      fi
fi

#telegraf & fluentbit requirements
if [ ! -e "/etc/config/kube.conf" ]; then
      if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ]; then
            echo "starting fluent-bit and setting telegraf conf file for prometheus sidecar"
            /opt/td-agent-bit/bin/td-agent-bit -c /etc/opt/microsoft/docker-cimprov/td-agent-bit-prom-side-car.conf -e /opt/td-agent-bit/bin/out_oms.so &
            telegrafConfFile="/etc/opt/microsoft/docker-cimprov/telegraf-prom-side-car.conf"
      else
            echo "starting fluent-bit and setting telegraf conf file for daemonset"
            if [ "$CONTAINER_RUNTIME" == "docker" ]; then
                  /opt/td-agent-bit/bin/td-agent-bit -c /etc/opt/microsoft/docker-cimprov/td-agent-bit.conf -e /opt/td-agent-bit/bin/out_oms.so &
                  telegrafConfFile="/etc/opt/microsoft/docker-cimprov/telegraf.conf"
            else
                  echo "since container run time is $CONTAINER_RUNTIME update the container log fluentbit Parser to cri from docker"
                  sed -i 's/Parser.docker*/Parser cri/' /etc/opt/microsoft/docker-cimprov/td-agent-bit.conf
                  /opt/td-agent-bit/bin/td-agent-bit -c /etc/opt/microsoft/docker-cimprov/td-agent-bit.conf -e /opt/td-agent-bit/bin/out_oms.so &
                  telegrafConfFile="/etc/opt/microsoft/docker-cimprov/telegraf.conf"
            fi
      fi
else
      echo "starting fluent-bit and setting telegraf conf file for replicaset"
      /opt/td-agent-bit/bin/td-agent-bit -c /etc/opt/microsoft/docker-cimprov/td-agent-bit-rs.conf -e /opt/td-agent-bit/bin/out_oms.so &
      telegrafConfFile="/etc/opt/microsoft/docker-cimprov/telegraf-rs.conf"
fi

#set env vars used by telegraf
if [ -z $AKS_RESOURCE_ID ]; then
      telemetry_aks_resource_id=""
      telemetry_aks_region=""
      telemetry_cluster_name=""
      telemetry_acs_resource_name=$ACS_RESOURCE_NAME
      telemetry_cluster_type="ACS"
else
      telemetry_aks_resource_id=$AKS_RESOURCE_ID
      telemetry_aks_region=$AKS_REGION
      telemetry_cluster_name=$AKS_RESOURCE_ID
      telemetry_acs_resource_name=""
      telemetry_cluster_type="AKS"
fi

export TELEMETRY_AKS_RESOURCE_ID=$telemetry_aks_resource_id
echo "export TELEMETRY_AKS_RESOURCE_ID=$telemetry_aks_resource_id" >> ~/.bashrc
export TELEMETRY_AKS_REGION=$telemetry_aks_region
echo "export TELEMETRY_AKS_REGION=$telemetry_aks_region" >> ~/.bashrc
export TELEMETRY_CLUSTER_NAME=$telemetry_cluster_name
echo "export TELEMETRY_CLUSTER_NAME=$telemetry_cluster_name" >> ~/.bashrc
export TELEMETRY_ACS_RESOURCE_NAME=$telemetry_acs_resource_name
echo "export TELEMETRY_ACS_RESOURCE_NAME=$telemetry_acs_resource_name" >> ~/.bashrc
export TELEMETRY_CLUSTER_TYPE=$telemetry_cluster_type
echo "export TELEMETRY_CLUSTER_TYPE=$telemetry_cluster_type" >> ~/.bashrc

#if [ ! -e "/etc/config/kube.conf" ]; then
#   nodename=$(cat /hostfs/etc/hostname)
#else
nodename=$(cat /var/opt/microsoft/docker-cimprov/state/containerhostname)
#fi
echo "nodename: $nodename"
echo "replacing nodename in telegraf config"
sed -i -e "s/placeholder_hostname/$nodename/g" $telegrafConfFile

export HOST_MOUNT_PREFIX=/hostfs
echo "export HOST_MOUNT_PREFIX=/hostfs" >> ~/.bashrc
export HOST_PROC=/hostfs/proc
echo "export HOST_PROC=/hostfs/proc" >> ~/.bashrc
export HOST_SYS=/hostfs/sys
echo "export HOST_SYS=/hostfs/sys" >> ~/.bashrc
export HOST_ETC=/hostfs/etc
echo "export HOST_ETC=/hostfs/etc" >> ~/.bashrc
export HOST_VAR=/hostfs/var
echo "export HOST_VAR=/hostfs/var" >> ~/.bashrc

if [ ! -e "/etc/config/kube.conf" ]; then
      if [ "${CONTAINER_TYPE}" == "PrometheusSidecar" ]; then
            echo "checking for listener on tcp #25229 and waiting for 30 secs if not.."
            waitforlisteneronTCPport 25229 30
      else
            echo "checking for listener on tcp #25226 and waiting for 30 secs if not.."
            waitforlisteneronTCPport 25226 30
            echo "checking for listener on tcp #25228 and waiting for 30 secs if not.."
            waitforlisteneronTCPport 25228 30
      fi
else
      echo "checking for listener on tcp #25226 and waiting for 30 secs if not.."
      waitforlisteneronTCPport 25226 30
fi

#start telegraf
/opt/telegraf --config $telegrafConfFile &
/opt/telegraf --version
dpkg -l | grep td-agent-bit | awk '{print $2 " " $3}'

#dpkg -l | grep telegraf | awk '{print $2 " " $3}'

# Write messages from the liveness probe to stdout (so telemetry picks it up)
touch /dev/write-to-traces

echo "stopping rsyslog..."
service rsyslog stop

echo "getting rsyslog status..."
service rsyslog status

shutdown() {
	 pkill -f mdsd
	}

trap "shutdown" SIGTERM

sleep inf & wait
