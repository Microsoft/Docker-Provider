#!/bin/bash
#
# Execute this directly in Azure Cloud Shell (https://shell.azure.com) by pasting (SHIFT+INS on Windows, CTRL+V on Mac or Linux)
# the following line (beginning with curl...) at the command prompt and then replacing the args:
#  This scripts upgrades the existing Azure Monitor for containers release on Azure Arc enabled Kubernetes cluster
#
#  1. Upgrades existing Azure Monitor for containers release to the K8s cluster in provided via --kube-context
# Prerequisites :
#     Azure CLI:  https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest
#     Helm3 : https://helm.sh/docs/intro/install/

# download script
# curl -o enable-monitoring.sh -L https://aka.ms/upgrade-monitoring-bash-script
# 1. Using Service Principal for Azure Login
## bash upgrade-monitoring.sh --client-id <sp client id> --client-secret <sp client secret> --tenant-id <tenant id of the service principal>
# 2. Using Interactive device login
# bash upgrade-monitoring.sh --resource-id <clusterResourceId>

set -e
set -o pipefail

# released chart version for Azure Arc enabled Kubernetes public preview
mcrChartVersion="2.7.6"
mcr="mcr.microsoft.com"
mcrChartRepoPath="azuremonitor/containerinsights/preview/azuremonitor-containers"

# default to public cloud since only supported cloud is azure public clod
defaultAzureCloud="AzureCloud"
helmLocalRepoName="."
helmChartName="azuremonitor-containers"

# default release name used during onboarding
releaseName="azmon-containers-release-1"

# resource provider for azure arc connected cluster
arcK8sResourceProvider="Microsoft.Kubernetes/connectedClusters"

# default of resourceProvider is Azure Arc enabled Kubernetes and this will get updated based on the provider cluster resource
resourceProvider="Microsoft.Kubernetes/connectedClusters"

# Azure Arc enabled Kubernetes cluster resource
isArcK8sCluster=false

# openshift project name for aro v4 cluster
openshiftProjectName="azure-monitor-for-containers"

# Azure Arc enabled Kubernetes cluster resource
isAroV4Cluster=false

# default global params
clusterResourceId=""
kubeconfigContext=""

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
  echo "Upgrade Azure Monitor for containers:"
  echo "$basename --resource-id <cluster resource id> [--client-id <clientId of service principal>] [--client-secret <client secret of service principal>] [--tenant-id <tenant id of the service principal>] [--kube-context <name of the kube context >]"
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
     "--client-id") set -- "$@" "-c" ;;
    "--client-secret") set -- "$@" "-s" ;;
    "--tenant-id") set -- "$@" "-t" ;;
    "--"*) usage ;;
    *) set -- "$@" "$arg" ;;
    esac
  done

  local OPTIND opt

  while getopts 'hk:r:c:s:t:' opt; do
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

  if [ ! -z "$servicePrincipalClientId" -a ! -z "$servicePrincipalClientSecret" -a ! -z "$servicePrincipalTenantId" ]; then
    echo "using service principal creds (clientId, secret and tenantId) for azure login since provided"
    isUsingServicePrincipal=true
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

  local identitytype=$(az resource show -g ${rgName} -n ${clusterName} --resource-type $resourceProvider --query identity.type)
  identitytype=$(echo $identitytype | tr "[:upper:]" "[:lower:]" | tr -d '"')
  echo "cluster identity type:" $identitytype

  if [[ "$identitytype" != "systemassigned" ]]; then
    echo "-e only supported cluster identity is systemassigned for Azure Arc enabled Kubernetes cluster type"
    exit 1
  fi

  echo "successfully validated the identity of the cluster"
}

validate_monitoring_tags() {
  echo "get loganalyticsworkspaceResourceId tag on to cluster resource"
  logAnalyticsWorkspaceResourceIdTag=$(az resource show --query tags.logAnalyticsWorkspaceResourceId -g $clusterResourceGroup -n $clusterName --resource-type $resourceProvider)
  echo "configured log analytics workspace: ${logAnalyticsWorkspaceResourceIdTag}"
  echo "successfully got logAnalyticsWorkspaceResourceId tag on the cluster resource"
  if [ -z "$logAnalyticsWorkspaceResourceIdTag" ]; then
    echo "-e logAnalyticsWorkspaceResourceId doesnt exist on this cluster which indicates cluster not enabled for monitoring"
    exit 1
  fi
}


upgrade_helm_chart_release() {

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

  export HELM_EXPERIMENTAL_OCI=1

  echo "pull the chart from ${mcr}/${mcrChartRepoPath}:${mcrChartVersion}"
  helm chart pull ${mcr}/${mcrChartRepoPath}:${mcrChartVersion}

  echo "export the chart from local cache to current directory"
  helm chart export ${mcr}/${mcrChartRepoPath}:${mcrChartVersion} --destination .

  helmChartRepoPath=$helmLocalRepoName/$helmChartName

  echo "upgrading the release: $releaseName to chart version : ${mcrChartVersion}"
  helm get values $releaseName -o yaml | helm upgrade --install $releaseName $helmChartRepoPath -f -
  echo "$releaseName got upgraded successfully."
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

# parse and validate args
parse_args $@

# configure azure cli for public cloud
configure_to_public_cloud

# parse cluster resource id
clusterSubscriptionId="$(echo $clusterResourceId | cut -d'/' -f3 | tr "[:upper:]" "[:lower:]")"
clusterResourceGroup="$(echo $clusterResourceId | cut -d'/' -f5)"
providerName="$(echo $clusterResourceId | cut -d'/' -f7)"
clusterName="$(echo $clusterResourceId | cut -d'/' -f9)"

# login to azure
login_to_azure

# set the cluster subscription id as active sub for azure cli
set_azure_subscription $clusterSubscriptionId

# validate cluster identity if its Azure Arc enabled Kubernetes cluster
if [ "$isArcK8sCluster" = true ]; then
  validate_cluster_identity $clusterResourceGroup $clusterName
fi

# validate the cluster has monitoring tags
validate_monitoring_tags

# upgrade helm chart release
upgrade_helm_chart_release

# portal link
echo "Proceed to https://aka.ms/azmon-containers to view health of your newly onboarded cluster"
