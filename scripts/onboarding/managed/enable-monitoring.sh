#!/bin/bash
#
# Execute this directly in Azure Cloud Shell (https://shell.azure.com) by pasting (SHIFT+INS on Windows, CTRL+V on Mac or Linux)
# the following line (beginning with curl...) at the command prompt and then replacing the args:
#  This scripts Onboards Azure Monitor for containers to Kubernetes cluster hosted outside and connected to Azure via Azure Arc cluster
#
#      1. Creates the Default Azure log analytics workspace if doesn't exist one in specified subscription
#      2. Adds the ContainerInsights solution to the Azure log analytics workspace
#      3. Adds the workspaceResourceId tag or enable addon (if the cluster is AKS) on the provided Managed cluster resource id
#      4. Installs Azure Monitor for containers HELM chart to the K8s cluster in provided via --kube-context
# Prerequisites :
#     Azure CLI:  https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest
#     Helm3 : https://helm.sh/docs/intro/install/
#     OC: https://docs.microsoft.com/en-us/azure/openshift/tutorial-connect-cluster#install-the-openshift-cli # Applicable for only ARO v4
# Note > 1. Format of the proxy endpoint should be http(s)://<user>:<pwd>@proxyhost:proxyport
#        2. cluster and workspace resource should be in valid azure resoure id format

# download script
# curl -o enable-monitoring.sh -L https://aka.ms/enable-monitoring-bash-script
# 1. Using Default Azure Log Analytics and no-proxy with current kube config context
# bash enable-monitoring.sh --resource-id <clusterResourceId>

# 2. Using Default Azure Log Analytics and no-proxy with current kube config context, and using service principal creds for the azure login
# bash enable-monitoring.sh --resource-id <clusterResourceId> --client-id <sp client id> --client-secret <sp client secret> --tenant-id <tenant id of the service principal>

# 3. Using Default Azure Log Analytics and no-proxy
# bash enable-monitoring.sh  --resource-id <clusterResourceId> --kube-context <kube-context>

# 4. Using Default Azure Log Analytics and with proxy endpoint configuration
# bash enable-monitoring.sh  --resource-id <clusterResourceId> --kube-context <kube-context> --proxy <proxy-endpoint>

# 5. Using Existing Azure Log Analytics and no-proxy
# bash enable-monitoring.sh  --resource-id <clusterResourceId> --kube-context <kube-context> --workspace-id <workspace-resource-id>

# 6. Using Existing Azure Log Analytics and proxy
# bash enable-monitoring.sh  --resource-id <clusterResourceId> --kube-context <kube-context> --workspace-id <workspace-resource-id> --proxy <proxy-endpoint>

set -e
set -o pipefail

# default to public cloud since only supported cloud is azure public cloud
defaultAzureCloud="AzureCloud"
# default domain will be for public cloud
omsAgentDomainName="opinsights.azure.com"

# released chart version in mcr
mcrChartVersion="2.8.2"
mcr="mcr.microsoft.com"
mcrChartRepoPath="azuremonitor/containerinsights/preview/azuremonitor-containers"
helmLocalRepoName="."
helmChartName="azuremonitor-containers"

# default release name used during onboarding
releaseName="azmon-containers-release-1"

# resource provider for azure arc connected cluster
arcK8sResourceProvider="Microsoft.Kubernetes/connectedClusters"

# resource provider for azure redhat openshift v4 cluster
aroV4ResourceProvider="Microsoft.RedHatOpenShift/OpenShiftClusters"

# resource provider for aks cluster
aksResourceProvider="Microsoft.ContainerService/managedClusters"

# default of resourceProvider is Azure Arc enabled Kubernetes and this will get updated based on the provider cluster resource
resourceProvider="Microsoft.Kubernetes/connectedClusters"

# resource type for azure log analytics workspace
workspaceResourceProvider="Microsoft.OperationalInsights/workspaces"

# openshift project name for aro v4 cluster
openshiftProjectName="azure-monitor-for-containers"
# AROv4 cluster resource
isAroV4Cluster=false

# Azure Arc enabled Kubernetes cluster resource
isArcK8sCluster=false

# aks cluster resource
isAksCluster=false

# workspace and cluster is same azure subscription
isClusterAndWorkspaceInSameSubscription=true

solutionTemplateUri="https://raw.githubusercontent.com/microsoft/Docker-Provider/ci_dev/scripts/onboarding/templates/azuremonitor-containerSolution.json"

# default global params
clusterResourceId=""
kubeconfigContext=""
workspaceResourceId=""
proxyEndpoint=""
containerLogVolume=""

# default workspace region and code
workspaceRegion="eastus"
workspaceRegionCode="EUS"
workspaceResourceGroup="DefaultResourceGroup-"$workspaceRegionCode

# default workspace guid and key
workspaceGuid=""
workspaceKey=""

# sp details for the login if provided
servicePrincipalClientId=""
servicePrincipalClientSecret=""
servicePrincipalTenantId=""
isUsingServicePrincipal=false

usage() {
  local basename=$(basename $0)
  echo
  echo "Enable Azure Monitor for containers:"
  echo "$basename --resource-id <cluster resource id> [--client-id <clientId of service principal>] [--client-secret <client secret of service principal>] [--tenant-id <tenant id of the service principal>] [--kube-context <name of the kube context >] [--workspace-id <resource id of existing workspace>] [--proxy <proxy endpoint>]"
}

parse_args() {

  if [ $# -le 1 ]; then
    usage
    exit 1
  fi

  # Transform long options to short ones
  for arg in "$@"; do
    shift
    case "$arg" in
    "--resource-id") set -- "$@" "-r" ;;
    "--kube-context") set -- "$@" "-k" ;;
    "--workspace-id") set -- "$@" "-w" ;;
    "--proxy") set -- "$@" "-p" ;;
    "--client-id") set -- "$@" "-c" ;;
    "--client-secret") set -- "$@" "-s" ;;
    "--tenant-id") set -- "$@" "-t" ;;
    "--helm-repo-name") set -- "$@" "-n" ;;
    "--helm-repo-url") set -- "$@" "-u" ;;
    "--container-log-volume") set -- "$@" "-v" ;;
    "--"*) usage ;;
    *) set -- "$@" "$arg" ;;
    esac
  done

  local OPTIND opt

  while getopts 'hk:r:w:p:c:s:t:n:u:v:' opt; do
    case "$opt" in
    h)
      usage
      ;;

    k)
      kubeconfigContext="$OPTARG"
      echo "name of kube-context is $OPTARG"
      ;;

    r)
      clusterResourceId="$OPTARG"
      echo "clusterResourceId is $OPTARG"
      ;;

    w)
      workspaceResourceId="$OPTARG"
      echo "workspaceResourceId is $OPTARG"
      ;;

    p)
      proxyEndpoint="$OPTARG"
      echo "proxyEndpoint is $OPTARG"
      ;;

    c)
      servicePrincipalClientId="$OPTARG"
      echo "servicePrincipalClientId is $OPTARG"
      ;;

    s)
      servicePrincipalClientSecret="$OPTARG"
      echo "clientSecret is *****"
      ;;

    t)
      servicePrincipalTenantId="$OPTARG"
      echo "service principal tenantId is $OPTARG"
      ;;

    n)
      helmRepoName="$OPTARG"
      echo "helm repo name is $OPTARG"
      ;;

    u)
      helmRepoUrl="$OPTARG"
      echo "helm repo url is $OPTARG"
      ;;

    v)
      containerLogVolume="$OPTARG"
      echo "container log volume is $OPTARG"
      ;;

    ?)
      usage
      exit 1
      ;;
    esac
  done
  shift "$(($OPTIND - 1))"

  local subscriptionId="$(echo ${clusterResourceId} | cut -d'/' -f3)"
  local resourceGroup="$(echo ${clusterResourceId} | cut -d'/' -f5)"

  # get resource parts and join back to get the provider name
  local providerNameResourcePart1="$(echo ${clusterResourceId} | cut -d'/' -f7)"
  local providerNameResourcePart2="$(echo ${clusterResourceId} | cut -d'/' -f8)"
  local providerName="$(echo ${providerNameResourcePart1}/${providerNameResourcePart2})"

  local clusterName="$(echo ${clusterResourceId} | cut -d'/' -f9)"

  # convert to lowercase for validation
  providerName=$(echo $providerName | tr "[:upper:]" "[:lower:]")

  echo "cluster SubscriptionId:" $subscriptionId
  echo "cluster ResourceGroup:" $resourceGroup
  echo "cluster ProviderName:" $providerName
  echo "cluster Name:" $clusterName

  if [ -z "$subscriptionId" -o -z "$resourceGroup" -o -z "$providerName" -o -z "$clusterName" ]; then
    echo "-e invalid cluster resource id. Please try with valid fully qualified resource id of the cluster"
    exit 1
  fi

  if [[ $providerName != microsoft.* ]]; then
    echo "-e invalid azure cluster resource id format."
    exit 1
  fi

  # detect the resource provider from the provider name in the cluster resource id
  if [ $providerName = "microsoft.kubernetes/connectedclusters" ]; then
    echo "provider cluster resource is of Azure Arc enabled Kubernetes cluster type"
    isArcK8sCluster=true
    resourceProvider=$arcK8sResourceProvider
  elif [ $providerName = "microsoft.redhatopenshift/openshiftclusters" ]; then
    echo "provider cluster resource is of AROv4 cluster type"
    resourceProvider=$aroV4ResourceProvider
    isAroV4Cluster=true
  elif [ $providerName = "microsoft.containerservice/managedclusters" ]; then
    echo "provider cluster resource is of AKS cluster type"
    isAksCluster=true
    resourceProvider=$aksResourceProvider
  else
    echo "-e unsupported azure managed cluster type"
    exit 1
  fi

  if [ -z "$kubeconfigContext" ]; then
    echo "using or getting current kube config context since --kube-context parameter not set "
  fi

  if [ ! -z "$workspaceResourceId" ]; then
    local workspaceSubscriptionId="$(echo $workspaceResourceId | cut -d'/' -f3)"
    local workspaceResourceGroup="$(echo $workspaceResourceId | cut -d'/' -f5)"
    local workspaceProviderName="$(echo $workspaceResourceId | cut -d'/' -f7)"
    local workspaceName="$(echo $workspaceResourceId | cut -d'/' -f9)"
    # convert to lowercase for validation
    workspaceProviderName=$(echo $workspaceProviderName | tr "[:upper:]" "[:lower:]")
    echo "workspace SubscriptionId:" $workspaceSubscriptionId
    echo "workspace ResourceGroup:" $workspaceResourceGroup
    echo "workspace ProviderName:" $workspaceName
    echo "workspace Name:" $workspaceName

    if [[ $workspaceProviderName != microsoft.operationalinsights* ]]; then
      echo "-e invalid azure log analytics resource id format."
      exit 1
    fi
  fi

  if [ ! -z "$proxyEndpoint" ]; then
    # Validate Proxy Endpoint URL
    # extract the protocol://
    proto="$(echo $proxyEndpoint | grep :// | sed -e's,^\(.*://\).*,\1,g')"
    # convert the protocol prefix in lowercase for validation
    proxyprotocol=$(echo $proto | tr "[:upper:]" "[:lower:]")
    if [ "$proxyprotocol" != "http://" -a "$proxyprotocol" != "https://" ]; then
      echo "-e error proxy endpoint should be in this format http(s)://<user>:<pwd>@<hostOrIP>:<port>"
    fi
    # remove the protocol
    url="$(echo ${proxyEndpoint/$proto/})"
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
      echo "successfully validated provided proxy endpoint is valid and in expected format"
    fi
  fi

  if [ ! -z "$servicePrincipalClientId" -a ! -z "$servicePrincipalClientSecret" -a ! -z "$servicePrincipalTenantId" ]; then
    echo "using service principal creds (clientId, secret and tenantId) for azure login since provided"
    isUsingServicePrincipal=true
  fi

}

validate_and_configure_supported_cloud() {
  echo "get active azure cloud name configured to azure cli"
  azureCloudName=$(az cloud show --query name -o tsv | tr "[:upper:]" "[:lower:]" | tr -d "[:space:]")
  echo "active azure cloud name configured to azure cli: ${azureCloudName}"
  if [ "$isArcK8sCluster" = true ]; then
    if [ "$azureCloudName" != "azurecloud" -a  "$azureCloudName" != "azureusgovernment" ]; then
      echo "-e only supported clouds are AzureCloud and AzureUSGovernment for Azure Arc enabled Kubernetes cluster type"
      exit 1
    fi
    if [ "$azureCloudName" = "azureusgovernment" ]; then
      echo "setting omsagent domain as opinsights.azure.us since the azure cloud is azureusgovernment "
      omsAgentDomainName="opinsights.azure.us"
    fi
  else
    # For ARO v4, only supported cloud is public so just configure to public to keep the existing behavior
    configure_to_public_cloud
  fi
}

configure_to_public_cloud() {
  echo "Set AzureCloud as active cloud for az cli"
  az cloud set -n $defaultAzureCloud
}

validate_cluster_identity() {
  echo "validating cluster identity"

  local rgName="$(echo ${1})"
  local clusterName="$(echo ${2})"

  local identitytype=$(az resource show -g ${rgName} -n ${clusterName} --resource-type $resourceProvider --query identity.type -o json)
  identitytype=$(echo $identitytype | tr "[:upper:]" "[:lower:]" | tr -d '"' | tr -d "[:space:]")
  echo "cluster identity type:" $identitytype

  if [[ "$identitytype" != "systemassigned" ]]; then
    echo "-e only supported cluster identity is systemassigned for Azure Arc enabled Kubernetes cluster type"
    exit 1
  fi

  echo "successfully validated the identity of the cluster"
}

create_default_log_analytics_workspace() {

  # extract subscription from cluster resource id
  local subscriptionId="$(echo $clusterResourceId | cut -d'/' -f3)"
  local clusterRegion=$(az resource show --ids ${clusterResourceId} --query location -o tsv)
  # convert cluster region to lower case
  clusterRegion=$(echo $clusterRegion | tr "[:upper:]" "[:lower:]")
  echo "cluster region:" $clusterRegion

  # mapping fors for default Azure Log Analytics workspace
  declare -A AzureCloudLocationToOmsRegionCodeMap=(
    [australiasoutheast]=ASE
    [australiaeast]=EAU
    [australiacentral]=CAU
    [canadacentral]=CCA
    [centralindia]=CIN
    [centralus]=CUS
    [eastasia]=EA
    [eastus]=EUS
    [eastus2]=EUS2
    [eastus2euap]=EAP
    [francecentral]=PAR
    [japaneast]=EJP
    [koreacentral]=SE
    [northeurope]=NEU
    [southcentralus]=SCUS
    [southeastasia]=SEA
    [uksouth]=SUK
    [usgovvirginia]=USGV
    [westcentralus]=EUS
    [westeurope]=WEU
    [westus]=WUS
    [westus2]=WUS2
  )

  declare -A AzureCloudRegionToOmsRegionMap=(
    [australiacentral]=australiacentral
    [australiacentral2]=australiacentral
    [australiaeast]=australiaeast
    [australiasoutheast]=australiasoutheast
    [brazilsouth]=southcentralus
    [canadacentral]=canadacentral
    [canadaeast]=canadacentral
    [centralus]=centralus
    [centralindia]=centralindia
    [eastasia]=eastasia
    [eastus]=eastus
    [eastus2]=eastus2
    [francecentral]=francecentral
    [francesouth]=francecentral
    [japaneast]=japaneast
    [japanwest]=japaneast
    [koreacentral]=koreacentral
    [koreasouth]=koreacentral
    [northcentralus]=eastus
    [northeurope]=northeurope
    [southafricanorth]=westeurope
    [southafricawest]=westeurope
    [southcentralus]=southcentralus
    [southeastasia]=southeastasia
    [southindia]=centralindia
    [uksouth]=uksouth
    [ukwest]=uksouth
    [westcentralus]=eastus
    [westeurope]=westeurope
    [westindia]=centralindia
    [westus]=westus
    [westus2]=westus2
    [usgovvirginia]=usgovvirginia
  )

  echo "cluster Region:"$clusterRegion
  if [ -n "${AzureCloudRegionToOmsRegionMap[$clusterRegion]}" ]; then
    workspaceRegion=${AzureCloudRegionToOmsRegionMap[$clusterRegion]}
  fi
  echo "Workspace Region:"$workspaceRegion

  if [ -n "${AzureCloudLocationToOmsRegionCodeMap[$workspaceRegion]}" ]; then
    workspaceRegionCode=${AzureCloudLocationToOmsRegionCodeMap[$workspaceRegion]}
  fi
  echo "Workspace Region Code:"$workspaceRegionCode

  workspaceResourceGroup="DefaultResourceGroup-"$workspaceRegionCode
  isRGExists=$(az group exists -g $workspaceResourceGroup)
  workspaceName="DefaultWorkspace-"$subscriptionId"-"$workspaceRegionCode

  if $isRGExists; then
    echo "using existing default resource group:"$workspaceResourceGroup
  else
    echo "creating resource group: $workspaceResourceGroup in region: $workspaceRegion"
    az group create -g $workspaceResourceGroup -l $workspaceRegion
  fi

  workspaceList=$(az resource list -g $workspaceResourceGroup -n $workspaceName --resource-type $workspaceResourceProvider)
  if [ "$workspaceList" = "[]" ]; then
    # create new default workspace since no mapped existing default workspace
    echo '{"location":"'"$workspaceRegion"'", "properties":{"sku":{"name": "standalone"}}}' >WorkspaceProps.json
    cat WorkspaceProps.json
    workspace=$(az resource create -g $workspaceResourceGroup -n $workspaceName --resource-type $workspaceResourceProvider --is-full-object -p @WorkspaceProps.json)
  else
    echo "using existing default workspace:"$workspaceName
  fi

  workspaceResourceId=$(az resource show -g $workspaceResourceGroup -n $workspaceName --resource-type $workspaceResourceProvider --query id -o json)
  workspaceResourceId=$(echo $workspaceResourceId | tr -d '"')
  echo "workspace resource Id: ${workspaceResourceId}"
}

add_container_insights_solution() {
  local resourceId="$(echo ${1})"

  # extract resource group from workspace resource id
  local resourceGroup="$(echo ${resourceId} | cut -d'/' -f5)"

  echo "adding containerinsights solution to workspace"
  solution=$(az deployment group create -g $resourceGroup --template-uri $solutionTemplateUri --parameters workspaceResourceId=$resourceId --parameters workspaceRegion=$workspaceRegion)
}

get_workspace_guid_and_key() {
  # extract resource parts from workspace resource id
  local resourceId="$(echo ${1} | tr -d '"')"
  local subId="$(echo ${resourceId} | cut -d'/' -f3)"
  local rgName="$(echo ${resourceId} | cut -d'/' -f5)"
  local wsName="$(echo ${resourceId} | cut -d'/' -f9)"

  # get the workspace guid
  workspaceGuid=$(az resource show -g $rgName -n $wsName --resource-type $workspaceResourceProvider --query properties.customerId -o json)
  workspaceGuid=$(echo $workspaceGuid | tr -d '"')
  echo "workspaceGuid:"$workspaceGuid

  echo "getting workspace primaryshared key"
  workspaceKey=$(az rest --method post --uri $workspaceResourceId/sharedKeys?api-version=2015-11-01-preview --query primarySharedKey -o json)
  workspaceKey=$(echo $workspaceKey | tr -d '"')
}

install_helm_chart() {

  # get the config-context for ARO v4 cluster
  if [ "$isAroV4Cluster" = true ]; then
    echo "getting config-context of ARO v4 cluster "
    echo "getting admin user creds for aro v4 cluster"
    adminUserName=$(az aro list-credentials -g $clusterResourceGroup -n $clusterName --query 'kubeadminUsername' -o tsv)
    adminPassword=$(az aro list-credentials -g $clusterResourceGroup -n $clusterName --query 'kubeadminPassword' -o tsv)
    apiServer=$(az aro show -g $clusterResourceGroup -n $clusterName --query apiserverProfile.url -o tsv)
    echo "login to the cluster via oc login"
    oc login $apiServer -u $adminUserName -p $adminPassword
    echo "creating project azure-monitor-for-containers"
    oc new-project $openshiftProjectName
    echo "getting config-context of aro v4 cluster"
    kubeconfigContext=$(oc config current-context)
  fi

  if [ -z "$kubeconfigContext" ]; then
    echo "installing Azure Monitor for containers HELM chart on to the cluster and using current kube context ..."
  else
    echo "installing Azure Monitor for containers HELM chart on to the cluster with kubecontext:${kubeconfigContext} ..."
  fi

  echo "getting the region of the cluster"
  clusterRegion=$(az resource show --ids ${clusterResourceId} --query location -o tsv)
  echo "cluster region is : ${clusterRegion}"

  echo "pull the chart version ${mcrChartVersion} from ${mcr}/${mcrChartRepoPath}"
  export HELM_EXPERIMENTAL_OCI=1
  helm chart pull $mcr/$mcrChartRepoPath:$mcrChartVersion

  echo "export the chart from local cache to current directory"
  helm chart export $mcr/$mcrChartRepoPath:$mcrChartVersion --destination .

  helmChartRepoPath=$helmLocalRepoName/$helmChartName

  echo "helm chart repo path: ${helmChartRepoPath}"

  if [ ! -z "$proxyEndpoint" ]; then
    echo "using proxy endpoint since proxy configuration passed in"
    if [ -z "$kubeconfigContext" ]; then
      echo "using current kube-context since --kube-context/-k parameter not passed in"
      helm upgrade --install $releaseName --set omsagent.domain=$omsAgentDomainName,omsagent.proxy=$proxyEndpoint,omsagent.secret.wsid=$workspaceGuid,omsagent.secret.key=$workspaceKey,omsagent.env.clusterId=$clusterResourceId,omsagent.env.clusterRegion=$clusterRegion $helmChartRepoPath
    else
      echo "using --kube-context:${kubeconfigContext} since passed in"
      helm upgrade --install $releaseName --set omsagent.domain=$omsAgentDomainName,omsagent.proxy=$proxyEndpoint,omsagent.secret.wsid=$workspaceGuid,omsagent.secret.key=$workspaceKey,omsagent.env.clusterId=$clusterResourceId,omsagent.env.clusterRegion=$clusterRegion $helmChartRepoPath --kube-context ${kubeconfigContext}
    fi
  else
    if [ -z "$kubeconfigContext" ]; then
      echo "using current kube-context since --kube-context/-k parameter not passed in"
      helm upgrade --install $releaseName --set omsagent.domain=$omsAgentDomainName,omsagent.secret.wsid=$workspaceGuid,omsagent.secret.key=$workspaceKey,omsagent.env.clusterId=$clusterResourceId,omsagent.env.clusterRegion=$clusterRegion $helmChartRepoPath
    else
      echo "using --kube-context:${kubeconfigContext} since passed in"
      helm upgrade --install $releaseName --set omsagent.domain=$omsAgentDomainName,omsagent.secret.wsid=$workspaceGuid,omsagent.secret.key=$workspaceKey,omsagent.env.clusterId=$clusterResourceId,omsagent.env.clusterRegion=$clusterRegion $helmChartRepoPath --kube-context ${kubeconfigContext}
    fi
  fi

  echo "chart installation completed."

}

login_to_azure() {
  if [ "$isUsingServicePrincipal" = true ]; then
    echo "login to the azure using provided service principal creds"
    az login --service-principal --username $servicePrincipalClientId --password $servicePrincipalClientSecret --tenant $servicePrincipalTenantId
  else
    echo "login to the azure interactively"
    az login --use-device-code
  fi
}

set_azure_subscription() {
  local subscriptionId="$(echo ${1})"
  echo "setting the subscription id: ${subscriptionId} as current subscription for the azure cli"
  az account set -s ${subscriptionId}
  echo "successfully configured subscription id: ${subscriptionId} as current subscription for the azure cli"
}

attach_monitoring_tags() {
  echo "attach loganalyticsworkspaceResourceId tag on to cluster resource"
  status=$(az resource update --set tags.logAnalyticsWorkspaceResourceId=$workspaceResourceId -g $clusterResourceGroup -n $clusterName --resource-type $resourceProvider)
  echo "$status"
  echo "successfully attached logAnalyticsWorkspaceResourceId tag on the cluster resource"
}

# enables aks monitoring addon for private preview and dont use this for aks prod
enable_aks_monitoring_addon() {
  echo "getting cluster object"
  clusterGetResponse=$(az rest --method get --uri $clusterResourceId?api-version=2020-03-01)
  export jqquery=".properties.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID=\"$workspaceResourceId\""
  echo $clusterGetResponse | jq $jqquery >putrequestbody.json
  status=$(az rest --method put --uri $clusterResourceId?api-version=2020-03-01 --body @putrequestbody.json --headers Content-Type=application/json)
  echo "status after enabling of aks monitoringa addon:$status"
}

# parse and validate args
parse_args $@

# validate and configure azure cli for cloud
validate_and_configure_supported_cloud

# parse cluster resource id
clusterSubscriptionId="$(echo $clusterResourceId | cut -d'/' -f3 | tr "[:upper:]" "[:lower:]")"
clusterResourceGroup="$(echo $clusterResourceId | cut -d'/' -f5)"
providerName="$(echo $clusterResourceId | cut -d'/' -f7)"
clusterName="$(echo $clusterResourceId | cut -d'/' -f9)"

# login to azure interactively
login_to_azure

# set the cluster subscription id as active sub for azure cli
set_azure_subscription $clusterSubscriptionId

# validate cluster identity if its Azure Arc enabled Kubernetes cluster
if [ "$isArcK8sCluster" = true ]; then
  validate_cluster_identity $clusterResourceGroup $clusterName
fi

if [ -z $workspaceResourceId ]; then
  echo "Using or creating default Log Analytics Workspace since workspaceResourceId parameter not set..."
  create_default_log_analytics_workspace
else
  echo "using provided azure log analytics workspace:${workspaceResourceId}"
  workspaceResourceId=$(echo $workspaceResourceId | tr -d '"')
  workspaceSubscriptionId="$(echo ${workspaceResourceId} | cut -d'/' -f3 | tr "[:upper:]" "[:lower:]")"
  workspaceResourceGroup="$(echo ${workspaceResourceId} | cut -d'/' -f5)"
  workspaceName="$(echo ${workspaceResourceId} | cut -d'/' -f9)"

  # set the azure subscription to azure cli if the workspace in different sub than cluster
  if [[ "$clusterSubscriptionId" != "$workspaceSubscriptionId" ]]; then
    echo "switch subscription id of workspace as active subscription for azure cli since workspace in different subscription than cluster: ${workspaceSubscriptionId}"
    isClusterAndWorkspaceInSameSubscription=false
    set_azure_subscription $workspaceSubscriptionId
  fi

  workspaceRegion=$(az resource show --ids ${workspaceResourceId} --query location -o json)
  workspaceRegion=$(echo $workspaceRegion | tr -d '"')
  echo "Workspace Region:"$workspaceRegion
fi

# add container insights solution
add_container_insights_solution $workspaceResourceId

# get workspace guid and key
get_workspace_guid_and_key $workspaceResourceId

if [ "$isClusterAndWorkspaceInSameSubscription" = false ]; then
  echo "switch to cluster subscription id as active subscription for cli: ${clusterSubscriptionId}"
  set_azure_subscription $clusterSubscriptionId
fi

# attach monitoring tags on to cluster resource
if [ "$isAksCluster" = true ]; then
  enable_aks_monitoring_addon
else
  attach_monitoring_tags
fi

# install helm chart
install_helm_chart

# portal link
echo "Proceed to https://aka.ms/azmon-containers to view health of your newly onboarded cluster"
