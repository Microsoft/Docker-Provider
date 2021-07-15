Add-Type @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            ServicePointManager.ServerCertificateValidationCallback +=
                delegate
                (
                    Object obj,
                    X509Certificate certificate,
                    X509Chain chain,
                    SslPolicyErrors errors
                )
                {
                    return true;
                };
        }
    }
"@
function Confirm-WindowsServiceExists($name) {
    if (Get-Service $name -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}

function Remove-WindowsServiceIfItExists($name) {
    $exists = Confirm-WindowsServiceExists $name
    if ($exists) {
        sc.exe \\server delete $name
    }
}

function Start-FileSystemWatcher {
    Start-Process powershell -NoNewWindow .\filesystemwatcher.ps1
}

#register fluentd as a windows service

function Set-EnvironmentVariables {
    $domain = "opinsights.azure.com"
    $mcs_endpoint = "monitor.azure.com"
    $cloud_environment = "azurepubliccloud"
    if (Test-Path /etc/omsagent-secret/DOMAIN) {
        # TODO: Change to omsagent-secret before merging
        $domain = Get-Content /etc/omsagent-secret/DOMAIN
        if (![string]::IsNullOrEmpty($domain)) {
            if ($domain -eq "opinsights.azure.com") {
                $cloud_environment = "azurepubliccloud"
                $mcs_endpoint = "monitor.azure.com"
            } elseif ($domain -eq "opinsights.azure.cn") {
                $cloud_environment = "azurechinacloud"
                $mcs_endpoint = "monitor.azure.cn"
            } elseif ($domain -eq "opinsights.azure.us") {
                $cloud_environment = "azureusgovernmentcloud"
                $mcs_endpoint = "monitor.azure.us"
            } elseif ($domain -eq "opinsights.azure.eaglex.ic.gov") {
                $cloud_environment = "usnat"
                $mcs_endpoint = "monitor.azure.eaglex.ic.gov"
            } elseif ($domain -eq "opinsights.azure.microsoft.scloud") {
                $cloud_environment = "ussec"
                $mcs_endpoint = "monitor.azure.microsoft.scloud"
            } else {
                Write-Host "Invalid or Unsupported domain name $($domain). EXITING....."
                exit 1
            }
        } else {
            Write-Host "Domain name either null or empty. EXITING....."
            exit 1
        }
    }

    Write-Host "Log analytics domain: $($domain)"
    Write-Host "MCS endpoint: $($mcs_endpoint)"
    Write-Host "Cloud Environment: $($cloud_environment)"

    # Set DOMAIN
    [System.Environment]::SetEnvironmentVariable("DOMAIN", $domain, "Process")
    [System.Environment]::SetEnvironmentVariable("DOMAIN", $domain, "Machine")

    # Set MCS Endpoint
    [System.Environment]::SetEnvironmentVariable("MCS_ENDPOINT", $mcs_endpoint, "Process")
    [System.Environment]::SetEnvironmentVariable("MCS_ENDPOINT", $mcs_endpoint, "Machine")

    # Set CLOUD_ENVIRONMENT
    [System.Environment]::SetEnvironmentVariable("CLOUD_ENVIRONMENT", $cloud_environment, "Process")
    [System.Environment]::SetEnvironmentVariable("CLOUD_ENVIRONMENT", $cloud_environment, "Machine")

    $wsID = ""
    if (Test-Path /etc/omsagent-secret/WSID) {
        # TODO: Change to omsagent-secret before merging
        $wsID = Get-Content /etc/omsagent-secret/WSID
    }

    # Set WSID
    [System.Environment]::SetEnvironmentVariable("WSID", $wsID, "Process")
    [System.Environment]::SetEnvironmentVariable("WSID", $wsID, "Machine")

    # Don't store WSKEY as environment variable

    $proxy = ""
    if (Test-Path /etc/omsagent-secret/PROXY) {
        # TODO: Change to omsagent-secret before merging
        $proxy = Get-Content /etc/omsagent-secret/PROXY
        Write-Host "Validating the proxy configuration since proxy configuration provided"
        # valide the proxy endpoint configuration
        if (![string]::IsNullOrEmpty($proxy)) {
            $proxy = [string]$proxy.Trim();
            if (![string]::IsNullOrEmpty($proxy)) {
                $proxy = [string]$proxy.Trim();
                $parts = $proxy -split "@"
                if ($parts.Length -ne 2) {
                    Write-Host "Invalid ProxyConfiguration $($proxy). EXITING....."
                    exit 1
                }
                $subparts1 = $parts[0] -split "//"
                if ($subparts1.Length -ne 2) {
                    Write-Host "Invalid ProxyConfiguration $($proxy). EXITING....."
                    exit 1
                }
                $protocol = $subparts1[0].ToLower().TrimEnd(":")
                if (!($protocol -eq "http") -and !($protocol -eq "https")) {
                    Write-Host "Unsupported protocol in ProxyConfiguration $($proxy). EXITING....."
                    exit 1
                }
                $subparts2 = $parts[1] -split ":"
                if ($subparts2.Length -ne 2) {
                    Write-Host "Invalid ProxyConfiguration $($proxy). EXITING....."
                    exit 1
                }
            }
        }
        Write-Host "Provided Proxy configuration is valid"
    }

    # Set PROXY
    [System.Environment]::SetEnvironmentVariable("PROXY", $proxy, "Process")
    [System.Environment]::SetEnvironmentVariable("PROXY", $proxy, "Machine")
    #set agent config schema version
    $schemaVersionFile = '/etc/config/settings/schema-version'
    if (Test-Path $schemaVersionFile) {
        $schemaVersion = Get-Content $schemaVersionFile | ForEach-Object { $_.TrimEnd() }
        if ($schemaVersion.GetType().Name -eq 'String') {
            [System.Environment]::SetEnvironmentVariable("AZMON_AGENT_CFG_SCHEMA_VERSION", $schemaVersion, "Process")
            [System.Environment]::SetEnvironmentVariable("AZMON_AGENT_CFG_SCHEMA_VERSION", $schemaVersion, "Machine")
        }
        $env:AZMON_AGENT_CFG_SCHEMA_VERSION
    }

    # Need to do this before the SA fetch for AI key for airgapped clouds so that it is not overwritten with defaults.
    $appInsightsAuth = [System.Environment]::GetEnvironmentVariable("APPLICATIONINSIGHTS_AUTH", "process")
    if (![string]::IsNullOrEmpty($appInsightsAuth)) {
        [System.Environment]::SetEnvironmentVariable("APPLICATIONINSIGHTS_AUTH", $appInsightsAuth, "machine")
        Write-Host "Successfully set environment variable APPLICATIONINSIGHTS_AUTH - $($appInsightsAuth) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable APPLICATIONINSIGHTS_AUTH for target 'machine' since it is either null or empty"
    }

    $appInsightsEndpoint = [System.Environment]::GetEnvironmentVariable("APPLICATIONINSIGHTS_ENDPOINT", "process")
    if (![string]::IsNullOrEmpty($appInsightsEndpoint)) {
        [System.Environment]::SetEnvironmentVariable("APPLICATIONINSIGHTS_ENDPOINT", $appInsightsEndpoint, "machine")
        Write-Host "Successfully set environment variable APPLICATIONINSIGHTS_ENDPOINT - $($appInsightsEndpoint) for target 'machine'..."
    }

    # Check if the instrumentation key needs to be fetched from a storage account (as in airgapped clouds)
    $aiKeyURl = [System.Environment]::GetEnvironmentVariable('APPLICATIONINSIGHTS_AUTH_URL')
    if ($aiKeyURl) {
        $aiKeyFetched = ""
        # retry up to 5 times
        for ( $i = 1; $i -le 4; $i++) {
            try {
                $response = Invoke-WebRequest -uri $aiKeyURl -UseBasicParsing -TimeoutSec 5 -ErrorAction:Stop

                if ($response.StatusCode -ne 200) {
                    Write-Host "Expecting reponse code 200, was: $($response.StatusCode), retrying"
                    Start-Sleep -Seconds ([MATH]::Pow(2, $i) / 4)
                }
                else {
                    $aiKeyFetched = $response.Content
                    break
                }
            }
            catch {
                Write-Host "Exception encountered fetching instrumentation key:"
                Write-Host $_.Exception
            }
        }

        # Check if the fetched IKey was properly encoded. if not then turn off telemetry
        if ($aiKeyFetched -match '^[A-Za-z0-9=]+$') {
            Write-Host "Using cloud-specific instrumentation key"
            [System.Environment]::SetEnvironmentVariable("APPLICATIONINSIGHTS_AUTH", $aiKeyFetched, "Process")
            [System.Environment]::SetEnvironmentVariable("APPLICATIONINSIGHTS_AUTH", $aiKeyFetched, "Machine")
        }
        else {
            # Couldn't fetch the Ikey, turn telemetry off
            Write-Host "Could not get cloud-specific instrumentation key (network error?). Disabling telemetry"
            [System.Environment]::SetEnvironmentVariable("DISABLE_TELEMETRY", "True", "Process")
            [System.Environment]::SetEnvironmentVariable("DISABLE_TELEMETRY", "True", "Machine")
        }
    }

    $aiKeyDecoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($env:APPLICATIONINSIGHTS_AUTH))
    [System.Environment]::SetEnvironmentVariable("TELEMETRY_APPLICATIONINSIGHTS_KEY", $aiKeyDecoded, "Process")
    [System.Environment]::SetEnvironmentVariable("TELEMETRY_APPLICATIONINSIGHTS_KEY", $aiKeyDecoded, "Machine")

    # Setting environment variables required by the fluentd plugins
    $aksResourceId = [System.Environment]::GetEnvironmentVariable("AKS_RESOURCE_ID", "process")
    if (![string]::IsNullOrEmpty($aksResourceId)) {
        [System.Environment]::SetEnvironmentVariable("AKS_RESOURCE_ID", $aksResourceId, "machine")
        Write-Host "Successfully set environment variable AKS_RESOURCE_ID - $($aksResourceId) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable AKS_RESOURCE_ID for target 'machine' since it is either null or empty"
    }

    $aksRegion = [System.Environment]::GetEnvironmentVariable("AKS_REGION", "process")
    if (![string]::IsNullOrEmpty($aksRegion)) {
        [System.Environment]::SetEnvironmentVariable("AKS_REGION", $aksRegion, "machine")
        Write-Host "Successfully set environment variable AKS_REGION - $($aksRegion) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable AKS_REGION for target 'machine' since it is either null or empty"
    }

    $controllerType = [System.Environment]::GetEnvironmentVariable("CONTROLLER_TYPE", "process")
    if (![string]::IsNullOrEmpty($controllerType)) {
        [System.Environment]::SetEnvironmentVariable("CONTROLLER_TYPE", $controllerType, "machine")
        Write-Host "Successfully set environment variable CONTROLLER_TYPE - $($controllerType) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable CONTROLLER_TYPE for target 'machine' since it is either null or empty"
    }

    $osType = [System.Environment]::GetEnvironmentVariable("OS_TYPE", "process")
    if (![string]::IsNullOrEmpty($osType)) {
        [System.Environment]::SetEnvironmentVariable("OS_TYPE", $osType, "machine")
        Write-Host "Successfully set environment variable OS_TYPE - $($osType) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable OS_TYPE for target 'machine' since it is either null or empty"
    }

    $userMsi = [System.Environment]::GetEnvironmentVariable("USER_ASSIGNED_IDENTITY_CLIENT_ID", "process")
    if (![string]::IsNullOrEmpty($userMsi)) {
        [System.Environment]::SetEnvironmentVariable("USER_ASSIGNED_IDENTITY_CLIENT_ID", $userMsi, "machine")
        Write-Host "Successfully set environment variable USER_ASSIGNED_IDENTITY_CLIENT_ID - $($userMsi) for target 'machine'..."
    }

    $hostName = [System.Environment]::GetEnvironmentVariable("HOSTNAME", "process")
    if (![string]::IsNullOrEmpty($hostName)) {
        [System.Environment]::SetEnvironmentVariable("HOSTNAME", $hostName, "machine")
        Write-Host "Successfully set environment variable HOSTNAME - $($hostName) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable HOSTNAME for target 'machine' since it is either null or empty"
    }

    # check if its AAD Auth MSI mode via USING_AAD_MSI_AUTH environment variable
    $isAADMSIAuth = [System.Environment]::GetEnvironmentVariable("USING_AAD_MSI_AUTH", "process")
    if (![string]::IsNullOrEmpty($isAADMSIAuth)) {
        [System.Environment]::SetEnvironmentVariable("AAD_MSI_AUTH_MODE", $isAADMSIAuth, "Process")
        [System.Environment]::SetEnvironmentVariable("AAD_MSI_AUTH_MODE", $isAADMSIAuth, "Machine")
        Write-Host "Successfully set environment variable AAD_MSI_AUTH_MODE - $($isAADMSIAuth) for target 'machine'..."
    }

    # check if use token proxy endpoint set via USE_IMDS_TOKEN_PROXY_END_POINT environment variable
    $useIMDSTokenProxyEndpoint = [System.Environment]::GetEnvironmentVariable("USE_IMDS_TOKEN_PROXY_END_POINT", "process")
    if (![string]::IsNullOrEmpty($useIMDSTokenProxyEndpoint)) {
        [System.Environment]::SetEnvironmentVariable("USE_IMDS_TOKEN_PROXY_END_POINT", $useIMDSTokenProxyEndpoint, "Process")
        [System.Environment]::SetEnvironmentVariable("USE_IMDS_TOKEN_PROXY_END_POINT", $useIMDSTokenProxyEndpoint, "Machine")
        Write-Host "Successfully set environment variable USE_IMDS_TOKEN_PROXY_END_POINT - $($useIMDSTokenProxyEndpoint) for target 'machine'..."
    }
    $nodeIp = [System.Environment]::GetEnvironmentVariable("NODE_IP", "process")
    if (![string]::IsNullOrEmpty($nodeIp)) {
        [System.Environment]::SetEnvironmentVariable("NODE_IP", $nodeIp, "machine")
        Write-Host "Successfully set environment variable NODE_IP - $($nodeIp) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable NODE_IP for target 'machine' since it is either null or empty"
    }

    $agentVersion = [System.Environment]::GetEnvironmentVariable("AGENT_VERSION", "process")
    if (![string]::IsNullOrEmpty($agentVersion)) {
        [System.Environment]::SetEnvironmentVariable("AGENT_VERSION", $agentVersion, "machine")
        Write-Host "Successfully set environment variable AGENT_VERSION - $($agentVersion) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable AGENT_VERSION for target 'machine' since it is either null or empty"
    }

    # run config parser
    ruby /opt/omsagentwindows/scripts/ruby/tomlparser.rb
    .\setenv.ps1

    # run mdm config parser
    ruby /opt/omsagentwindows/scripts/ruby/tomlparser-mdm-metrics-config.rb
    .\setmdmenv.ps1
}

function Get-ContainerRuntime {
    # default container runtime and make default as containerd when containerd becomes default in AKS
    $containerRuntime = "docker"
    $cAdvisorIsSecure = "false"
    $response = ""
    $NODE_IP = ""
    try {
        if (![string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable("NODE_IP", "PROCESS"))) {
            $NODE_IP = [System.Environment]::GetEnvironmentVariable("NODE_IP", "PROCESS")
        }
        elseif (![string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable("NODE_IP", "USER"))) {
            $NODE_IP = [System.Environment]::GetEnvironmentVariable("NODE_IP", "USER")
        }
        elseif (![string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable("NODE_IP", "MACHINE"))) {
            $NODE_IP = [System.Environment]::GetEnvironmentVariable("NODE_IP", "MACHINE")
        }

        if (![string]::IsNullOrEmpty($NODE_IP)) {
            $isPodsAPISuccess = $false
            Write-Host "Value of NODE_IP environment variable : $($NODE_IP)"
            try {
                Write-Host "Making API call to http://$($NODE_IP):10255/pods"
                $response = Invoke-WebRequest -uri http://$($NODE_IP):10255/pods  -UseBasicParsing
                Write-Host "Response status code of API call to http://$($NODE_IP):10255/pods : $($response.StatusCode)"
            }
            catch {
                Write-Host "API call to http://$($NODE_IP):10255/pods failed"
            }

            if (![string]::IsNullOrEmpty($response) -and $response.StatusCode -eq 200) {
                Write-Host "API call to http://$($NODE_IP):10255/pods succeeded"
                $isPodsAPISuccess = $true
            }
            else {
                try {
                    Write-Host "Making API call to https://$($NODE_IP):10250/pods"
                    # ignore certificate validation since kubelet uses self-signed cert
                    [ServerCertificateValidationCallback]::Ignore()
                    $response = Invoke-WebRequest -Uri https://$($NODE_IP):10250/pods  -Headers @{'Authorization' = "Bearer $(Get-Content /var/run/secrets/kubernetes.io/serviceaccount/token)" } -UseBasicParsing
                    Write-Host "Response status code of API call to https://$($NODE_IP):10250/pods : $($response.StatusCode)"
                    if (![string]::IsNullOrEmpty($response) -and $response.StatusCode -eq 200) {
                        Write-Host "API call to https://$($NODE_IP):10250/pods succeeded"
                        $isPodsAPISuccess = $true
                        $cAdvisorIsSecure = "true"
                    }
                }
                catch {
                    Write-Host "API call to https://$($NODE_IP):10250/pods failed"
                }
            }

            # set IS_SECURE_CADVISOR_PORT env for debug and telemetry purpose
            Write-Host "Setting IS_SECURE_CADVISOR_PORT environment variable as $($cAdvisorIsSecure)"
            [System.Environment]::SetEnvironmentVariable("IS_SECURE_CADVISOR_PORT", $cAdvisorIsSecure, "Process")
            [System.Environment]::SetEnvironmentVariable("IS_SECURE_CADVISOR_PORT", $cAdvisorIsSecure, "Machine")

            if ($isPodsAPISuccess) {
                if (![string]::IsNullOrEmpty($response.Content)) {
                    $podList = $response.Content | ConvertFrom-Json
                    if (![string]::IsNullOrEmpty($podList)) {
                        $podItems = $podList.Items
                        if ($podItems.Length -gt 0) {
                            Write-Host "found pod items: $($podItems.Length)"
                            for ($index = 0; $index -le $podItems.Length ; $index++) {
                                Write-Host "current podItem index : $($index)"
                                $pod = $podItems[$index]
                                if (![string]::IsNullOrEmpty($pod) -and
                                    ![string]::IsNullOrEmpty($pod.status) -and
                                    ![string]::IsNullOrEmpty($pod.status.phase) -and
                                    $pod.status.phase -eq "Running" -and
                                    $pod.status.ContainerStatuses.Length -gt 0) {
                                    $containerID = $pod.status.ContainerStatuses[0].containerID
                                    $detectedContainerRuntime = $containerID.split(":")[0].trim()
                                    Write-Host "detected containerRuntime as : $($detectedContainerRuntime)"
                                    if (![string]::IsNullOrEmpty($detectedContainerRuntime) -and [string]$detectedContainerRuntime.StartsWith('docker') -eq $false) {
                                        $containerRuntime = $detectedContainerRuntime
                                    }
                                    Write-Host "using containerRuntime as : $($containerRuntime)"
                                    break
                                }
                            }
                        }
                        else {
                            Write-Host "got podItems count is 0 hence using default container runtime:  $($containerRuntime)"
                        }


                    }
                    else {
                        Write-Host "got podList null or empty hence using default container runtime:  $($containerRuntime)"
                    }
                }
                else {
                    Write-Host "got empty response content for /Pods API call hence using default container runtime:  $($containerRuntime)"
                }
            }
        }
        else {
            Write-Host "got empty NODE_IP environment variable"
        }
        # set CONTAINER_RUNTIME env for debug and telemetry purpose
        [System.Environment]::SetEnvironmentVariable("CONTAINER_RUNTIME", $containerRuntime, "Process")
        [System.Environment]::SetEnvironmentVariable("CONTAINER_RUNTIME", $containerRuntime, "Machine")
    }
    catch {
        $e = $_.Exception
        Write-Host $e
        Write-Host "exception occured on getting container runtime hence using default container runtime: $($containerRuntime)"
    }

    return $containerRuntime
}

function Start-Fluent-Telegraf {

    # Run fluent-bit service first so that we do not miss any logs being forwarded by the fluentd service and telegraf service.
    # Run fluent-bit as a background job. Switch this to a windows service once fluent-bit supports natively running as a windows service
    Start-Job -ScriptBlock { Start-Process -NoNewWindow -FilePath "C:\opt\fluent-bit\bin\fluent-bit.exe" -ArgumentList @("-c", "C:\etc\fluent-bit\fluent-bit.conf", "-e", "C:\opt\omsagentwindows\out_oms.so") }

    $containerRuntime = Get-ContainerRuntime

    #register fluentd as a service and start
    # there is a known issues with win32-service https://github.com/chef/win32-service/issues/70
    if (![string]::IsNullOrEmpty($containerRuntime) -and [string]$containerRuntime.StartsWith('docker') -eq $false) {
        # change parser from docker to cri if the container runtime is not docker
        Write-Host "changing parser from Docker to CRI since container runtime : $($containerRuntime) and which is non-docker"
        (Get-Content -Path C:/etc/fluent/fluent.conf -Raw) -replace 'fluent-docker-parser.conf', 'fluent-cri-parser.conf' | Set-Content C:/etc/fluent/fluent.conf
    }

    # Start telegraf only in sidecar scraping mode
    $sidecarScrapingEnabled = [System.Environment]::GetEnvironmentVariable('SIDECAR_SCRAPING_ENABLED')
    if (![string]::IsNullOrEmpty($sidecarScrapingEnabled) -and $sidecarScrapingEnabled.ToLower() -eq 'true') {
        Write-Host "Starting telegraf..."
        Start-Telegraf
    }

    fluentd --reg-winsvc i --reg-winsvc-auto-start --winsvc-name fluentdwinaks --reg-winsvc-fluentdopt '-c C:/etc/fluent/fluent.conf -o C:/etc/fluent/fluent.log'

    Notepad.exe | Out-Null
}

function Start-Telegraf {
    # Set default telegraf environment variables for prometheus scraping
    Write-Host "**********Setting default environment variables for telegraf prometheus plugin..."
    .\setdefaulttelegrafenvvariables.ps1

    # run prometheus custom config parser
    Write-Host "**********Running config parser for custom prometheus scraping**********"
    ruby /opt/omsagentwindows/scripts/ruby/tomlparser-prom-customconfig.rb
    Write-Host "**********End running config parser for custom prometheus scraping**********"


    # Set required environment variable for telegraf prometheus plugin to run properly
    Write-Host "Setting required environment variables for telegraf prometheus input plugin to run properly..."
    $kubernetesServiceHost = [System.Environment]::GetEnvironmentVariable("KUBERNETES_SERVICE_HOST", "process")
    if (![string]::IsNullOrEmpty($kubernetesServiceHost)) {
        [System.Environment]::SetEnvironmentVariable("KUBERNETES_SERVICE_HOST", $kubernetesServiceHost, "machine")
        Write-Host "Successfully set environment variable KUBERNETES_SERVICE_HOST - $($kubernetesServiceHost) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable KUBERNETES_SERVICE_HOST for target 'machine' since it is either null or empty"
    }

    $kubernetesServicePort = [System.Environment]::GetEnvironmentVariable("KUBERNETES_SERVICE_PORT", "process")
    if (![string]::IsNullOrEmpty($kubernetesServicePort)) {
        [System.Environment]::SetEnvironmentVariable("KUBERNETES_SERVICE_PORT", $kubernetesServicePort, "machine")
        Write-Host "Successfully set environment variable KUBERNETES_SERVICE_PORT - $($kubernetesServicePort) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable KUBERNETES_SERVICE_PORT for target 'machine' since it is either null or empty"
    }
<<<<<<< HEAD
<<<<<<< HEAD

    $nodeIp = [System.Environment]::GetEnvironmentVariable("NODE_IP", "process")
    if (![string]::IsNullOrEmpty($nodeIp)) {
        [System.Environment]::SetEnvironmentVariable("NODE_IP", $nodeIp, "machine")
        Write-Host "Successfully set environment variable NODE_IP - $($nodeIp) for target 'machine'..."
    }
    else {
        Write-Host "Failed to set environment variable NODE_IP for target 'machine' since it is either null or empty"
    }

=======

>>>>>>> 6df299f9... Cherry picking hotfix changes to ci_dev (#605)
=======

>>>>>>> ci_dev
    Write-Host "Installing telegraf service"
    C:\opt\telegraf\telegraf.exe --service install --config "C:\etc\telegraf\telegraf.conf"

    # Setting delay auto start for telegraf since there have been known issues with windows server and telegraf -
    # https://github.com/influxdata/telegraf/issues/4081
    # https://github.com/influxdata/telegraf/issues/3601
    try {
        $serverName = [System.Environment]::GetEnvironmentVariable("PODNAME", "process")
        if (![string]::IsNullOrEmpty($serverName)) {
            sc.exe \\$serverName config telegraf start= delayed-auto
            Write-Host "Successfully set delayed start for telegraf"

        }
        else {
            Write-Host "Failed to get environment variable PODNAME to set delayed telegraf start"
        }
    }
    catch {
        $e = $_.Exception
        Write-Host $e
        Write-Host "exception occured in delayed telegraf start.. continuing without exiting"
    }
    Write-Host "Running telegraf service in test mode"
    C:\opt\telegraf\telegraf.exe --config "C:\etc\telegraf\telegraf.conf" --test
    Write-Host "Starting telegraf service"
    C:\opt\telegraf\telegraf.exe --service start

    # Trying to start telegraf again if it did not start due to fluent bit not being ready at startup
    Get-Service telegraf | findstr Running
    if ($? -eq $false) {
        Write-Host "trying to start telegraf in again in 30 seconds, since fluentbit might not have been ready..."
        Start-Sleep -s 30
        C:\opt\telegraf\telegraf.exe --service start
        Get-Service telegraf
    }
}

function Generate-Certificates {
    Write-Host "Generating Certificates"
    C:\\opt\\omsagentwindows\\certgenerator\\certificategenerator.exe
}

function Test-CertificatePath {
    $certLocation = $env:CI_CERT_LOCATION
    $keyLocation = $env:CI_KEY_LOCATION
    if (!(Test-Path $certLocation)) {
        Write-Host "Certificate file not found at $($certLocation). EXITING....."
        exit 1
    }
    else {
        Write-Host "Certificate file found at $($certLocation)"
    }

    if (! (Test-Path $keyLocation)) {
        Write-Host "Key file not found at $($keyLocation). EXITING...."
        exit 1
    }
    else {
        Write-Host "Key file found at $($keyLocation)"
    }
}

function Bootstrap-CACertificates {
    try {
        # This is required when the root CA certs are different for some clouds.
        $certMountPath = "C:\ca"
        Get-ChildItem $certMountPath |
        Foreach-Object {
            $absolutePath = $_.FullName
            Write-Host "cert path: $($absolutePath)"
            Import-Certificate -FilePath $absolutePath -CertStoreLocation 'Cert:\LocalMachine\Root' -Verbose
        }
    }
    catch {
        $e = $_.Exception
        Write-Host $e
        Write-Host "exception occured in Bootstrap-CACertificates..."
    }
}

Start-Transcript -Path main.txt

Remove-WindowsServiceIfItExists "fluentdwinaks"
Set-EnvironmentVariables
Start-FileSystemWatcher

#Bootstrapping CA certs for non public clouds and AKS clusters
$aksResourceId = [System.Environment]::GetEnvironmentVariable("AKS_RESOURCE_ID")
$requiresCertBootstrap = [System.Environment]::GetEnvironmentVariable("REQUIRES_CERT_BOOTSTRAP")
if (![string]::IsNullOrEmpty($requiresCertBootstrap) -and `
        $requiresCertBootstrap.ToLower() -eq 'true' -and `
        ![string]::IsNullOrEmpty($aksResourceId) -and `
        $aksResourceId.ToLower().Contains("/microsoft.containerservice/managedclusters/")) {
    Bootstrap-CACertificates
}

$isAADMSIAuth = [System.Environment]::GetEnvironmentVariable("USING_AAD_MSI_AUTH")
if (![string]::IsNullOrEmpty($isAADMSIAuth) -and $isAADMSIAuth.ToLower() -eq 'true') {
    Write-Host "skipping agent onboarding via cert since AAD MSI Auth configured"
} else {
    Generate-Certificates
    Test-CertificatePath
}
Start-Fluent-Telegraf

# List all powershell processes running. This should have main.ps1 and filesystemwatcher.ps1
Get-WmiObject Win32_process | Where-Object { $_.Name -match 'powershell' } | Format-Table -Property Name, CommandLine, ProcessId

#check if fluentd service is running
Get-Service fluentdwinaks
