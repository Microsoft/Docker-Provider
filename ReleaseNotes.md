# Azure Monitor for Containers

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).  For more
information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact
[opencode@microsoft.com](mailto:opencode@microsoft.com) with any
additional questions or comments.

## Release History

Note : The agent version(s) below has dates (ciprod<mmddyyyy>), which indicate the agent build dates (not release dates)

### 07/13/2021 -
##### Version microsoft/oms:win-ciprod06112021-2 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod06112021-2 (windows)
##### Code change log
- Hotfix for fixing NODE_IP environment variable not set issue for non sidecar mode

### 06/11/2021 -
##### Version microsoft/oms:ciprod06112021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod06112021 (linux)
##### Version microsoft/oms:win-ciprod06112021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod06112021 (windows)
 - Linux Agent
   - Removal of base omsagent dependency
   - Using MDSD version 1.10.1  as base agent for all the supported LA data types
   - Ruby version upgrade to 2.6 i.e. same version as windows agent
   - Upgrade FluentD gem version to 1.12.2
   - All the Ruby Fluentd Plugins upgraded to v1 as per Fluentd guidance
   - Fluent-bit tail plugin Mem_Buf_limit is configurable via ConfigMap
 - Windows Agent
   - CA cert changes for airgapped clouds
   - Send perf metrics to MDM from windows daemonset
   - FluentD gem version upgrade from 1.10.2 to 1.12.2 to make same version as Linux Agent
  - Doc updates
   - README updates related to OSM preview release for Arc K8s
   - README updates related to recommended alerts

### 05/20/2021 -
##### Version microsoft/oms:ciprod05202021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod05202021 (linux)
##### No Windows changes with this release, win-ciprod04222021 still current.
##### Code change log
- Telegraf now waits 30 seconds on startup for network connections to complete (Linux only)
- Change adding telegraf to the liveness probe reverted (Linux only)

### 05/12/2021 -
##### Version microsoft/oms:ciprod05122021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod05122021 (linux)
##### No Windows changes with this release, win-ciprod04222021 still current.
##### Code change log
- Upgrading oneagent to version 1.8 (only for Linux)
- Enabling oneagent for container logs for East US 2

### 04/22/2021 -
##### Version microsoft/oms:ciprod04222021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod04222021 (linux)
##### Version microsoft/oms:win-ciprod04222021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod04222021 (windows)
##### Code change log
- Bug fixes for metrics cpuUsagePercentage and memoryWorkingSetPercentage for windows nodes
- Added metrics for threshold violation
- Made Job completion metric configurable
- Udated default buffer sizes in fluent-bit
- Updated recommended alerts
- Fixed bug where logs written before agent starts up were not collected
- Fixed bug which kept agent logs from being rotated
- Bug fix for Windows Containerd container log collection
- Bug fixes
- Doc updates
- Minor telemetry changes

### 03/26/2021 -
##### Version microsoft/oms:ciprod03262021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod03262021 (linux)
##### Version microsoft/oms:win-ciprod03262021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod03262021 (windows)
##### Code change log
- Started collecting new metric - kubelet running pods count
- Onboarding script fixes to add explicit json output
- Proxy and token updates for ARC
- Doc updates for Microsoft charts repo release
- Bug fixes for trailing whitespaces in enable-monitoring.sh script
- Support for higher volume of prometheus metrics by scraping metrics from sidecar
- Update to get new version of telegraf - 1.18
- Add label and field selectors for prometheus scraping using annotations
- Support for OSM integration
- Removed wireserver calls to get CA certs since access is removed
- Added liveness timeout for exec for linux containers

### 02/23/2021 -
##### Version microsoft/oms:ciprod02232021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod02232021 (linux)
##### Version microsoft/oms:win-ciprod02232021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod02232021 (windows)
##### Code change log
- ContainerLogV2 schema support for LogAnalytics & ADX (not usable externally yet)
- Fix nodemetrics (cpuusageprecentage & memoryusagepercentage) metrics not flowing. This is fixed upstream for k8s versions >= 1.19.7 and >=1.20.2.
- Fix cpu & memory usage exceeded threshold container metrics not flowing when requests and/or limits were not set
- Mute some unused exceptions from going to telemetry
- Collect containerimage (repository, image & imagetag) from spec (instead of runtime)
- Add support for extension MSI for k8s arc
- Use cloud specific instrumentation keys for telemetry
- Picked up newer version for apt
- Add priority class to daemonset (in our chart only)

### 01/11/2021 -
##### Version microsoft/oms:ciprod01112021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod01112021 (linux)
##### Version microsoft/oms:win-ciprod01112021 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod01112021 (windows)
##### Code change log
- Fixes for Linux Agent Replicaset Pod OOMing issue
- Update fluentbit (1.14.2 to 1.6.8) for the Linux Daemonset
- Make Fluentbit settings: log_flush_interval_secs, tail_buf_chunksize_megabytes and tail_buf_maxsize_megabytes configurable via configmap
- Support for PV inventory collection
- Removal of Custom metric region check for Public cloud regions and update to use cloud environment variable to determine the custom metric support
- For daemonset pods, add the dnsconfig to use ndots: 3 from ndots:5 to optimize the number of DNS API calls made
- Fix for inconsistency in the collection container environment variables for the pods which has high number of containers
- Fix for disabling of std{out;err} log_collection_settings via configmap issue in windows daemonset
- Update to use workspace key from mount file rather than environment variable for windows daemonset agent
- Remove per container info logs in the container inventory
- Enable ADX route for windows container logs
- Remove logging to termination log in windows agent liveness probe

### 11/09/2020 -
##### Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod11092020 (linux)
##### Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod11092020 (windows)
##### Code change log
- Fix for duplicate windows metrics

### 10/27/2020 -
##### Version microsoft/oms:ciprod10272020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod10272020 (linux)
##### Version microsoft/oms:win-ciprod10272020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod10272020 (windows)
##### Code change log
- Activate oneagent in few AKS regions (koreacentral,norwayeast)
- Disable syslog
- Fix timeout for Windows daemonset liveness probe
- Make request == limit for Windows daemonset resources (cpu & memory)
- Schema v2 for container log (ADX only - applicable only for select customers for piloting)

### 10/05/2020 -
##### Version microsoft/oms:ciprod10052020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod10052020 (linux)
##### Version microsoft/oms:win-ciprod10052020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod10052020 (windows)
##### Code change log
- Health CRD to version v1 (from v1beta1) for k8s versions >= 1.19.0
- Collection of PV usage metrics for PVs mounted by pods (kube-system pods excluded by default)(doc-link-needed)
- Zero fill few custom metrics under a timer, also add zero filling for new PV usage metrics
- Collection of additional Kubelet metrics ('kubelet_running_pod_count','volume_manager_total_volumes','kubelet_node_config_error','process_resident_memory_bytes','process_cpu_seconds_total','kubelet_runtime_operations_total','kubelet_runtime_operations_errors_total'). This also includes updates to 'kubelet' workbook to include these new metrics
- Collection of Azure NPM (Network Policy Manager) metrics (basic & advanced. By default, NPM metrics collection is turned OFF)(doc-link-needed)
- Support log collection when docker root is changed with knode. Tracked by [this](https://github.com/Azure/AKS/issues/1373) issue
- Support for Pods in 'Terminating' state for nodelost scenarios
- Fix for reduction in telemetry for custom metrics ingestion failures
- Fix CPU capacity/limits metrics being 0 for Virtual nodes (VK)
- Add new custom metric regions (eastus2,westus,australiasoutheast,brazilsouth,germanywestcentral,northcentralus,switzerlandnorth)
- Enable strict SSL validation for AppInsights Ruby SDK
- Turn off custom metrics upload for unsupported cluster types
- Install CA certs from wire server for windows (in certain clouds)

### 09/16/2020 -
> Note: This agent release targetted ONLY for non-AKS clusters via Azure Monitor for containers HELM chart update
##### Version microsoft/oms:ciprod09162020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod09162020 (linux)
##### Version microsoft/oms:win-ciprod09162020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod09162020 (windows)
##### Code change log
- Collection of Azure Network Policy Manager Basic and Advanced metrics
- Add support in Windows Agent for Container log collection of CRI runtimes such as ContainerD
- Alertable metrics support Arc K8s cluster to parity with AKS
- Support for multiple container log mount paths when docker is updated through knode
- Bug fix related to MDM telemetry

### 08/07/2020 -
##### Version microsoft/oms:ciprod08072020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod08072020 (linux)
##### Version microsoft/oms:win-ciprod08072020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod08072020 (windows)
##### Code change log
- Collection of KubeState metrics for deployments and HPA
- Add the Proxy support for Windows agent
- Fix for ContainerState in ContainerInventory to handle Failed state and collection of environment variables for terminated and failed containers
- Change /spec to /metrics/cadvisor endpoint to collect node capacity metrics
- Disable Health Plugin by default and can enabled via configmap
- Pin version of jq to 1.5+dfsg-2
- Bug fix for showing node as 'not ready' when there is disk pressure
- oneagent integration (disabled by default)
- Add region check before sending alertable metrics to MDM
- Telemetry fix for agent telemetry for sov. clouds


### 07/15/2020 -
##### Version microsoft/oms:ciprod07152020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod07152020 (linux)
##### Version microsoft/oms:win-ciprod05262020-2 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod05262020-2 (windows)
##### Code change log
- Following hotfixes which are applicable only for Linux agent
  - Fix the issue related to collection of multi-containers in pod for the ContainerInventory table
  - Fix the containerhostname field value to have podname rather than nodename in ContainerInventory table
  - Fix OOM issue during container startup if there are high number of pods or containers on the node
  - Fix the ContainerName field value same as before in ContainerInventory table
- We didn't rebuild windows container, so the image version for windows container stays the same as last release (ciprod:win-ciprod05262020-2) before this hotfix

### 06/30/2020 -
##### Version microsoft/oms:ciprod06302020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod06302020 (linux)
##### Version microsoft/oms:win-ciprod05262020-2 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod05262020-2 (windows)
##### Code change log
- Hotfix for nested JSON log parsing bug (applicable only to Linux Daemonset)
- We didn't rebuild windows container, so the image version for windows container stays the same as last release (ciprod:win-ciprod05262020-2) before this hotfix

### 05/27/2020 -
##### Version microsoft/oms:win-ciprod05262020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod05262020-2 (windows)
##### Code change log
- Update [application insights instrumentation key](https://github.com/microsoft/OMS-docker/pull/410) for windows image to point to the production instance

### 05/22/2020 -
##### Version microsoft/oms:ciprod05222020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod05222020 (linux)
##### Version microsoft/oms:win-ciprod05222020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:win-ciprod05222020 (windows)
##### Code change log
- Windows Daemonset - Collection of Windows std/stderr logs
- More Alerable Metrics (going to Metrics Store/custom metrics - see Customer Impact section below for metrics list)
- Fix OOM-ing at high prometheus scrape volume
- Update fluentbit (0.14.4 to 1.4.2)
- Drop non-numeric metrics thru Telegraf
- Reduce Health exception (when API server response is nil)
- Add 'Computer' dimension to all telemetry (internal use)
- Support for specifiying HTTP & HTTPS Proxy for outbound/egress (applicable only for non-AKS clusters)
- Move to rbac.authorization.k8s.io/v1 for ClusterRole & ClusterRoleBinding
- Move to apiextensions.k8s.io/v1 for Health CRD

##### Customer Impact
- Windows Logs - Customers will see agent automatically start collecting windows container STDOUT/STDERR logs sending them to same loganaytics workspace (containerlogs table)
- Alertable metrics - Customers will see the below metrics & namespaces in 'Metrics' TOC for AKS clusters
     - Metrics
         - diskUsagePercentage
         - completedJobsCount
         - oomKilledContainerCount
         - podReadyPercentage
         - restartingContainerCount
         - cpuExceededPercentage
         - memoryRssExceededPercentage
         - memoryWorkingSetExceededPercentage
     - Metric Namespaces
         - insights.container/containers
- HTTP/S Proxy support - For non-AKS clusters, proxy can be configured when installing thru HELM. Please see documentation for more details


### 04/16/2020 -
> Note: This agent release targetted ONLY for non-AKS clusters via Azure Monitor for containers HELM chart update
##### Version microsoft/oms:ciprod04162020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod04162020
##### Code change log
- Add support for rate limiting
- Add support for Container Runtime Interface compatible container runtime(s) like CRI-O and ContainerD
     - cAdvisor APIs are used to collect the container inventory for Docker/Moby and CRI runtime K8s environments
     - Based on the container runtime, corresponding container log FluentBit parser(docker/cri) selected

##### Customer Impact
- Ingestion will throttle the workspaces if the agent on the cluster sending the beyond Log Analytics Workspace throttling  limits i.e. 500 MB/s
- On Docker runtime environments, Inventory of the containers obtained  earlier via Docker REST API.
  Agent now uses the cAdvisor APIs to get the inventory of the containers for Docker and non-Docker container runtime environments.

### 03/02/2020 -
##### Version microsoft/oms:ciprod03022020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod03022020
##### Code change log
- Collection of GPU metrics as InsightsMetrics
- Enable config map settings to enable collection of 'Normal' kube events
- Fix kubehealth exceptions to handle empty/nil kube api responses
- Get resource limits for health and MDM from kubelet instead of kube api
- Bug fix for windows node image collection where image name contains multiple slashes
- Exclude ARO master node for data collection
- Telemetry for kube events flushed
- Changes to support msi for mdm if service principal doesnt exist
- Changes for AKS telemetry to ping ods endpoint first and then network check
- KubeEvents bug fix for KubeEvent type

##### Customer Impact
- Providing capability for customers to collect 'Normal' kube events using config map
- Metrics for GPU are collected and ingested to customers workspace if they have GPU enabled nodes
- Bug fix for windows container image collection allows customers to get the right data in the ContainerInventory table for windows       containers.

### 01/07/2020 -
##### Version microsoft/oms:ciprod01072020 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod01072020
##### Code change log
- Switch between 10255(old) and 10250(new) ports for cadvisor for older and newer versions of kubernetes

##### Customer Impact
- Node cpu, node memory, container cpu and container memory metrics were obtained earlier by querying kubelet readonly port(http://$NODE_IP:10255). Agent now supports getting these metrics from kubelet port(https://$NODE_IP:10250) as well. During the agent startup, it checks for connectivity to kubelet port(https://$NODE_IP:10250), and if it fails the metrics source is defaulted to readonly port(http://$NODE_IP:10255).

### 12/04/2019 -
##### Version microsoft/oms:ciprod12042019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod12042019
- Fix scheduler for all input plugins
- Fix liveness probe
- Reduce chunk sizes for all fluentD buffers to support larger clusters (nodes & pods)
- Chunk Kubernetes API calls (pods,nodes,events)
- Use HTTP.start instead of HTTP.new
- Merge KubePerf into KubePods & KubeNodes
- Merge KubeServices into KubePod
- Use stream based yajl for JSON parsing
- Health - Query only kube-system pods
- Health - Use keep_if instead of select
- Container log enrichment (turned OFF by default for ContainerName & ContainerImage)
- Application Insights Telemetry - Async
- Fix metricTime to be batch time for all metric input plugins
- Close socket connections properly for DockerAPIClient
- Fix top un handled exceptions in Kubernetes API Client and pod inventory
- Fix retries, wait between retries, chunk size, thread counts to be consistent for all FluentD workflows
- Back-off for containerlog enrichment K8S API calls
- Add new regions (3) for Azure Monitor Custom metrics
- Increase the cpu(1 core) & memory(750Mi) limits for replica-set to support larger clusters (nodes & pods)
- Move to Ubuntu 18.04 LTS
- Support for Kubernetes 1.16
- Use ifconfig for detecting network connectivity issues
- Collect eventType != Normal

### 10/11/2019 -
##### Version microsoft/oms:ciprod10112019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod10112019
- Update prometheus config scraping capability to restrict collecting metrics from pods in specific namespaces.
- Feature to send custom configuration/prometheus scrape errors to KubeMonAgentEvents table in customer's workspace.
- Bug fix to collect data for init containers for Container Logs, KubePodInventory and Perf.
- Bug fix for empty array being a valid setting in custom config in configmap.
- Restrict kubelet_docker_operations and kubelet_docker_operations_errors to create_containers, remove_containers and pull_image operations.
- Fix top exceptions in telemetry

### 08/22/2019 -
##### Version microsoft/oms:ciprod08222019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod08222019
- Cluster Health Private Preview based on config map setting
- Update resource requests for replicaset to 110m and 250Mi
- Update custom metrics supported regions
- Fix for promethus config map telemetry
- Telemetry for controller kind
- Update url to use one of the whitelisted urls for cp monitor telemetry
- Configmap with clusterid for AKS to be used by Application Insights

### 07/09/2019 -
##### Version microsoft/oms:ciprod07092019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod07092019
- Prometheus custom metric collection using config map allowing omsagent to
  * Scrape metrics from user defined urls
  * Scrape kubernetes pods with prometheus annotations
  * Scrape metrics from kubernetes services
- Exception fixes in daemonset and replicaset
- Container Inventory plugin changes to get image id from the repo digest and populate repository for image with
only image digest
- Remove telegraf errors from being sent to ApplicationInsights and instead log it to stderr to provide visibility for
customers
- Bug fixes for region names with spaces being processed incorrectly while sending mdm metrics
- Add log size in telemetry
- Remove buffer chunk size and buffer max size from fluentbit configuration
### 06/14/2019 -
##### Version microsoft/oms:ciprod06142019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod06142019
- MDM pod metrics bug fixes - MDM rejecting pod metrics due to nodename or controllername dimensions being empty
- Prometheus metrics collection by default in every node for kubelet docker operations and kubelet docker operation errors
- Telegraf metric collection for diskio and networkio metrics
- Agent Configuration/ Settings for data collection
  * Cluster level log collection enable/disable option
  * Ability to enable/disable stdout and/or stderr logs collection per namespace
  * Cluster level environment variable collection enable/disable option
  * Config file version & config schema version
  * Pod annotation for supported config schema version(s)
- Log collection optimization/tuning for better performance
  * Derive k8s namespaces from log file name (instead of making call to k8s api service)
  * Do not tail log files for containers in the excluded namespace list (if excluded both in stdout & stderr)
  * Limit buffer size to 1M and flush logs more frequently [every 10 secs (instead of 30 secs)]
  * Tuning of several other fluent bit settings
-	Increase requests
  * Replica set memory request by 75M (100M to 175M)
  * Daemonset CPU request by 25m (50m to 75m)
- Will be pushing image only to MCR ( no more Docker) starting this release. AKS-engine will also start to pull our agent image from MCR

### 04/23/2019 -
##### Version microsoft/oms:ciprod043232019 Version mcr.microsoft.com/azuremonitor/containerinsights/ciprod:ciprod04232019
- Windows node monitoring (metrics & inventory)
- Telegraf integration (Telegraf metrics to LogAnalytics)
- Node Disk usage metrics (used, free, used%) as InsightsMetrics
- Resource stamping for all types (inventory, metrics (perf), metrics (InsightsMetrics), logs) [Applicable only for AKS clusters]
- Upped daemonset memory request (not limit) from 150Mi to 225 Mi
- Added liveness probe for fluentbit
- Fix for MDM filter plugin when kubeapi returns non-200 response

### 03/12/2019 - Version microsoft/oms:ciprod03122019
- Fix for closing response.Body in outoms
- Update Mem_Buf_Limit to 5m for fluentbit
- Tail only files that were modified since 5 minutes
- Remove some unwanted logs that are chatty in outoms
- Fix for MDM disablement for AKS-Engine
- Fix for Pod count metric (same as container count) in MDM

### 02/21/2019 - Version microsoft/oms:ciprod02212019
- Container logs enrichment optimization
  * Get container meta data only for containers in current node (vs cluster before)
- Update fluent bit 0.13.7 => 0.14.4
  * This fixes the escaping issue in the container logs
- Mooncake cloud support for agent (AKS only)
  * Ability to disable agent telemetry
  * Ability to onboard and ingest to mooncake cloud
- Add & populate 'ContainerStatusReason'  column to KubePodInventory
- Alertable (custom) metrics (to AzureMonitor - only for AKS clusters)
  * Cpuusagenanocores & % metric
  * MemoryWorkingsetBytes & % metric
  * MemoryRssBytes & % metric
  * Podcount by node, phase & namespace metric
  * Nodecount metric
- ContainerNodeInventory_CL to fixed type

### 01/09/2018 - Version microsoft/oms:ciprod01092019
- Omsagent - 1.8.1.256 (nov 2018 release)
- Persist fluentbit state between container restarts
- Populate 'TimeOfCommand' for agent ingest time for container logs
- Get node cpu usage from cpuusagenanoseconds (and convert to cpuusgaenanocores)
- Container Node Inventory - move to fluentD from OMI
- Mount docker.sock (Daemon set) as /var/run/host
- Add omsagent user to docker group
- Move to fixed type for kubeevents & kubeservices
- Disable collecting ENV for our oms agent container (daemonset & replicaset)
- Disable container inventory collection for 'sandbox' containers & non kubernetes managed containers
- Agent telemetry - ContainerLogsAgentSideLatencyMs
- Agent telemetry - PodCount
- Agent telemetry - ControllerCount
- Agent telemetry - K8S Version
- Agent telemetry - NodeCoreCapacity
- Agent telemetry - NodeMemoryCapacity
- Agent telemetry - KubeEvents (exceptions)
- Agent telemetry - Kubenodes (exceptions)
- Agent telemetry - kubepods (exceptions)
- Agent telemetry - kubeservices (exceptions)
- Agent telemetry - Daemonset , Replicaset as dimensions (bug fix)

### 11/29/2018 - Version microsoft/oms:ciprod11292018
- Disable Container Image inventory workflow
- Kube_Events memory leak fix for replica-set
- Timeout (30 secs) for outOMS
- Reduce critical lock duration for quicker log processing (for log enrichment)
- Disable OMI based Container Inventory workflow to fluentD based Container Inventory
- Moby support for the new Container Inventory workflow
- Ability to disable environment variables collection by individual container
- Bugfix - No inventory data due to container status(es) not available
- Agent telemetry cpu usage & memory usage (for DaemonSet and ReplicaSet)
- Agent telemetry - log generation rate
- Agent telemetry - container count per node
- Agent telemetry - collect container logs from agent (DaemonSet and ReplicaSet) as AI trace
- Agent telemetry - errors/exceptions for Container Inventory workflow
- Agent telemetry - Container Inventory Heartbeat

### 10/16/2018 - Version microsoft/oms:ciprod10162018-2
- Fix for containerID being 00000-00000-00000
- Move from fluentD to fluentbit for container log collection
- Seg fault fixes in json parsing for container inventory & container image inventory
- Telemetry enablement
- Remove ContainerPerf, ContainerServiceLog, ContainerProcess fluentd-->OMI workflows
- Update log level for all fluentD based workflows

### 7/31/2018 - Version microsoft/oms:ciprod07312018
- Changes for node lost scenario (roll-up pod & container statuses as Unknown)
- Discover unscheduled pods
- KubeNodeInventory - delimit multiple true node conditions for node status
- UTF Encoding support for container logs
- Container environment variable truncated to 200K
- Handle json parsing errors for OMI provider for docker
- Test mode enablement for ACS-engine testing
- Latest OMS agent (1.6.0-163)
- Latest OMI (1.4.2.5)


### 6/7/2018 - Version microsoft/oms:ciprod06072018
- Remove node-0 dependency
- Remove passing WSID & Key as environment variables and pass them as kubernetes secret (for non-AKS; we already pass them as secret for AKS)
- Please note that if you are manually deploying thru yaml you need to -
- Provide workspaceid & key as base64 encoded strings with in double quotes (.yaml has comments to do so as well)
- Provide cluster name twice (for each container – daemonset & replicaset)

### 5/8/2018 - Version microsoft/oms:ciprod05082018
- Kubernetes RBAC enablement
- Latest released omsagent (1.6.0-42)
- Bug fix so that we do not collect kube-system namespace container logs when kube api calls fail occasionally (Bug #215107)
- .yaml changes (for RBAC)
