<#
    .DESCRIPTION

     Onboards Azure Monitor for containers to Azure Managed Kuberenetes such as Azure Arc enabled Kubernetes, ARO v4 and AKS etc.
       1. Creates the Default Azure log analytics workspace if doesn't exist one in specified subscription
       2. Adds the ContainerInsights solution to the Azure log analytics workspace
       3. Adds the workspaceResourceId tag or enable addon (if the cluster is AKS) on the provided Managed cluster resource id
       4. Installs Azure Monitor for containers HELM chart to the K8s cluster in provided via --kube-context

    .PARAMETER clusterResourceId
        Id of the Azure Managed Cluster such as Azure Arc enabled Kubernetes, ARO v4 etc.
    .PARAMETER servicePrincipalClientId
        Client Id of the service principal which will be used for the azure login
    .PARAMETER servicePrincipalClientSecret
        Client secret of the service principal which will be used for the azure login
    .PARAMETER tenantId
        Azure TenantId of the service principal which will be used for the azure login
    .PARAMETER kubeContext (optional)
        kube-context of the k8 cluster to install Azure Monitor for containers HELM chart
    .PARAMETER workspaceResourceId (optional)
        Provide the azure resource id of the existing  Azure Log Analytics Workspace if you want to use existing one
    .PARAMETER proxyEndpoint (optional)
        Provide Proxy endpoint if you have K8s cluster behind the proxy and would like to route Azure Monitor for containers outbound traffic via proxy.
        Format of the proxy endpoint should be http(s://<user>:<password>@<proxyhost>:<port>
    .PARAMETER azureCloudName (optional)
       Name of the Azure cloud name. Supported Azure cloud Name is AzureCloud or AzureUSGovernment

     Pre-requisites:
      -  Azure Managed cluster Resource Id
      -  Contributor role permission on the Subscription of the Azure Arc Cluster
      -  Helm v3.0.0 or higher  https://github.com/helm/helm/releases
      -  kube-context of the K8s cluster
 Note: 1. Please make sure you have all the pre-requisistes before running this script.
# download script
# curl -o enable-monitoring.ps1 -L https://aka.ms/enable-monitoring-powershell-script
#>
param(
    [Parameter(mandatory = $true)]
    [string]$clusterResourceId,
    [Parameter(mandatory = $false)]
    [string]$servicePrincipalClientId,
    [Parameter(mandatory = $false)]
    [string]$servicePrincipalClientSecret,
    [Parameter(mandatory = $false)]
    [string]$tenantId,
    [Parameter(mandatory = $false)]
    [string]$kubeContext,
    [Parameter(mandatory = $false)]
    [string]$workspaceResourceId,
    [Parameter(mandatory = $false)]
    [string]$proxyEndpoint,
    [Parameter(mandatory = $false)]
    [string]$azureCloudName
)

$solutionTemplateUri = "https://raw.githubusercontent.com/microsoft/Docker-Provider/ci_dev/scripts/onboarding/templates/azuremonitor-containerSolution.json"
$helmChartReleaseName = "azmon-containers-release-1"
$helmChartName = "azuremonitor-containers"

# flags to indicate the cluster types
$isArcK8sCluster = $false
$isAksCluster = $false
$isUsingServicePrincipal = $false

# microsoft helm chart repo
$microsoftHelmRepo="https://microsoft.github.io/charts/repo"
$microsoftHelmRepoName="microsoft"

$omsAgentDomainName="opinsights.azure.com"

if ([string]::IsNullOrEmpty($azureCloudName) -eq $true) {
    Write-Host("Azure cloud name parameter not passed in so using default cloud as AzureCloud")
    $azureCloudName = "AzureCloud"
} else {
    if(($azureCloudName.ToLower() -eq "azurecloud" ) -eq $true) {
        Write-Host("Specified Azure Cloud name is : $azureCloudName")
        $omsAgentDomainName="opinsights.azure.com"
    } elseif (($azureCloudName.ToLower() -eq "azureusgovernment" ) -eq $true) {
        Write-Host("Specified Azure Cloud name is : $azureCloudName")
        $omsAgentDomainName="opinsights.azure.us"
    } else {
        Write-Host("Specified Azure Cloud name is : $azureCloudName")
        Write-Host("Only supported azure clouds are : AzureCloud and AzureUSGovernment")
        exit
    }
}

# checks the required Powershell modules exist and if not exists, request the user permission to install
$azAccountModule = Get-Module -ListAvailable -Name Az.Accounts
$azResourcesModule = Get-Module -ListAvailable -Name Az.Resources
$azOperationalInsights = Get-Module -ListAvailable -Name Az.OperationalInsights

if (($null -eq $azAccountModule) -or ($null -eq $azResourcesModule) -or ($null -eq $azOperationalInsights)) {

    $isWindowsMachine = $true
    if ($PSVersionTable -and $PSVersionTable.PSEdition -contains "core") {
        if ($PSVersionTable.Platform -notcontains "win") {
            $isWindowsMachine = $false
        }
    }

    if ($isWindowsMachine) {
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

        if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Host("Running script as an admin...")
            Write-Host("")
        }
        else {
            Write-Host("Please re-launch the script with elevated administrator") -ForegroundColor Red
            Stop-Transcript
            exit
        }
    }

    $message = "This script will try to install the latest versions of the following Modules : `
			    Az.Resources, Az.Accounts  and Az.OperationalInsights using the command`
			    `'Install-Module {Insert Module Name} -Repository PSGallery -Force -AllowClobber -ErrorAction Stop -WarningAction Stop'
			    `If you do not have the latest version of these Modules, this troubleshooting script may not run."
    $question = "Do you want to Install the modules and run the script or just run the script?"

    $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
    $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes, Install and run'))
    $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Continue without installing the Module'))
    $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Quit'))

    $decision = $Host.UI.PromptForChoice($message, $question, $choices, 0)

    switch ($decision) {
        0 {

            if ($null -eq $azResourcesModule) {
                try {
                    Write-Host("Installing Az.Resources...")
                    Install-Module Az.Resources -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
                }
                catch {
                    Write-Host("Close other powershell logins and try installing the latest modules forAz.Accounts in a new powershell window: eg. 'Install-Module Az.Accounts -Repository PSGallery -Force'") -ForegroundColor Red
                    exit
                }
            }

            if ($null -eq $azAccountModule) {
                try {
                    Write-Host("Installing Az.Accounts...")
                    Install-Module Az.Accounts -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
                }
                catch {
                    Write-Host("Close other powershell logins and try installing the latest modules forAz.Accounts in a new powershell window: eg. 'Install-Module Az.Accounts -Repository PSGallery -Force'") -ForegroundColor Red
                    exit
                }
            }

            if ($null -eq $azOperationalInsights) {
                try {

                    Write-Host("Installing Az.OperationalInsights...")
                    Install-Module Az.OperationalInsights -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
                }
                catch {
                    Write-Host("Close other powershell logins and try installing the latest modules for Az.OperationalInsights in a new powershell window: eg. 'Install-Module Az.OperationalInsights -Repository PSGallery -Force'") -ForegroundColor Red
                    exit
                }
            }

        }
        1 {

            if ($null -eq $azResourcesModule) {
                try {
                    Import-Module Az.Resources -ErrorAction Stop
                }
                catch {
                    Write-Host("Could not import Az.Resources...") -ForegroundColor Red
                    Write-Host("Close other powershell logins and try installing the latest modules for Az.Resources in a new powershell window: eg. 'Install-Module Az.Resources -Repository PSGallery -Force'") -ForegroundColor Red
                    Stop-Transcript
                    exit
                }
            }
            if ($null -eq $azAccountModule) {
                try {
                    Import-Module Az.Accounts -ErrorAction Stop
                }
                catch {
                    Write-Host("Could not import Az.Accounts...") -ForegroundColor Red
                    Write-Host("Close other powershell logins and try installing the latest modules for Az.Accounts in a new powershell window: eg. 'Install-Module Az.Accounts -Repository PSGallery -Force'") -ForegroundColor Red
                    Stop-Transcript
                    exit
                }
            }

            if ($null -eq $azOperationalInsights) {
                try {
                    Import-Module Az.OperationalInsights -ErrorAction Stop
                }
                catch {
                    Write-Host("Could not import Az.OperationalInsights... Please reinstall this Module") -ForegroundColor Red
                    Stop-Transcript
                    exit
                }
            }

        }
        2 {
            Write-Host("")
            Stop-Transcript
            exit
        }
    }
}

if ([string]::IsNullOrEmpty($clusterResourceId)) {
    Write-Host("Specified Azure Arc enabled Kubernetes ClusterResourceId should not be NULL or empty") -ForegroundColor Red
    exit
}

if ([string]::IsNullOrEmpty($kubeContext)) {
    Write-Host("Since kubeContext parameter not passed in so using current kube config context") -ForegroundColor Yellow
}


$clusterResourceId = $clusterResourceId.Trim()
if ($clusterResourceId.EndsWith("/")) {
    Write-Host("Trimming redundant / in tail end of cluster resource id")
    $clusterResourceId = $clusterResourceId.TrimEnd("/")
}

if ($clusterResourceId.StartsWith("/") -eq $false) {
    Write-Host("Prepending / to cluster resource id since this doesnt exist")
    $clusterResourceId = "/" + $clusterResourceId
}

if ($clusterResourceId.Split("/").Length -ne 9) {
    Write-Host("Provided Cluster Resource Id is not in expected format") -ForegroundColor Red
    exit
}

if (($clusterResourceId.ToLower().Contains("microsoft.kubernetes/connectedclusters") -ne $true) -and
    ($clusterResourceId.ToLower().Contains("microsoft.redhatopenshift/openshiftclusters") -ne $true) -and
    ($clusterResourceId.ToLower().Contains("microsoft.containerservice/managedclusters") -ne $true)
) {
    Write-Host("Provided cluster ResourceId is not supported cluster type: $clusterResourceId") -ForegroundColor Red
    exit
}

if (([string]::IsNullOrEmpty($servicePrincipalClientId) -eq $false) -and
    ([string]::IsNullOrEmpty($servicePrincipalClientSecret) -eq $false) -and
    ([string]::IsNullOrEmpty($tenantId) -eq $false)) {
    Write-Host("Using service principal creds for the azure login since these provided.")
    $isUsingServicePrincipal = $true
}

if ($clusterResourceId.ToLower().Contains("microsoft.kubernetes/connectedclusters") -eq $true) {
    $isArcK8sCluster = $true
}
elseif ($clusterResourceId.ToLower().Contains("microsoft.containerservice/managedclusters") -eq $true) {
    $isAksCluster = $true
}

$resourceParts = $clusterResourceId.Split("/")
$clusterSubscriptionId = $resourceParts[2]

Write-Host("Cluster SubscriptionId : '" + $clusterSubscriptionId + "' ") -ForegroundColor Green

if ($isUsingServicePrincipal) {
    $spSecret = ConvertTo-SecureString -String $servicePrincipalClientSecret -AsPlainText -Force
    $spCreds = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $servicePrincipalClientId, $spSecret
    Connect-AzAccount -ServicePrincipal -Credential $spCreds -Tenant $tenantId -Subscription $clusterSubscriptionId -Environment $azureCloudName
}

try {
    Write-Host("")
    Write-Host("Trying to get the current Az login context...")
    $account = Get-AzContext -ErrorAction Stop
    $ctxCloud = $account.Environment.Name
    if(($azureCloudName.ToLower() -eq $ctxCloud.ToLower() ) -eq $false) {
        Write-Host("Specified azure cloud name is not same as current context cloud hence setting account to null to retrigger the login" ) -ForegroundColor Green
        $account = $null
    }
    Write-Host("Successfully fetched current AzContext context and azure cloud name: $azureCloudName" ) -ForegroundColor Green
    Write-Host("")
}
catch {
    Write-Host("")
    Write-Host("Could not fetch AzContext..." ) -ForegroundColor Red
    Write-Host("")
}


if ($null -eq $account.Account) {
    try {
        if ($isUsingServicePrincipal) {
            $spSecret = ConvertTo-SecureString -String $servicePrincipalClientSecret -AsPlainText -Force
            $spCreds = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $servicePrincipalClientId, $spSecret

            Connect-AzAccount -ServicePrincipal -Credential $spCreds -Tenant $tenantId -Subscription $clusterSubscriptionId -Environment $azureCloudName
        }
        else {
            Write-Host("Please login...")
            Connect-AzAccount -subscriptionid $clusterSubscriptionId -Environment $azureCloudName
        }
    }
    catch {
        Write-Host("")
        Write-Host("Could not select subscription with ID : " + $clusterSubscriptionId + ". Please make sure the ID you entered is correct and you have access to the cluster" ) -ForegroundColor Red
        Write-Host("")
        Stop-Transcript
        exit
    }
}
else {
    if ($account.Subscription.Id -eq $clusterSubscriptionId) {
        Write-Host("Subscription: $SubscriptionId is already selected. Account details: ")
        $account
    }
    else {
        try {
            Write-Host("Current Subscription:")
            $account
            Write-Host("Changing to subscription: $clusterSubscriptionId")
            Set-AzContext -SubscriptionId $clusterSubscriptionId
        }
        catch {
            Write-Host("")
            Write-Host("Could not select subscription with ID : " + $clusterSubscriptionId + ". Please make sure the ID you entered is correct and you have access to the cluster" ) -ForegroundColor Red
            Write-Host("")
            Stop-Transcript
            exit
        }
    }
}

# validate specified Azure Managed cluster exists and got access permissions
Write-Host("Checking specified Azure Managed cluster resource exists and got access...")
$clusterResource = Get-AzResource -ResourceId $clusterResourceId
if ($null -eq $clusterResource) {
    Write-Host("specified Azure Managed cluster resource id either you dont have access or doesnt exist") -ForegroundColor Red
    exit
}
$clusterRegion = $clusterResource.Location.ToLower()

if ($isArcK8sCluster -eq $true) {
    # validate identity
    $clusterIdentity = $clusterResource.identity.type.ToString().ToLower()
    if ($clusterIdentity.contains("systemassigned") -eq $false) {
        Write-Host("Identity of Azure Arc enabled Kubernetes cluster should be systemassigned but it has identity: $clusterIdentity") -ForegroundColor Red
        exit
    }
}

if ([string]::IsNullOrEmpty($workspaceResourceId)) {
    Write-Host("Using or creating default Log Analytics Workspace since workspaceResourceId parameter not set...")
    # mapping fors for default Azure Log Analytics workspace
    $AzureCloudLocationToOmsRegionCodeMap = @{
        "australiasoutheast" = "ASE" ;
        "australiaeast"      = "EAU" ;
        "australiacentral"   = "CAU" ;
        "canadacentral"      = "CCA" ;
        "centralindia"       = "CIN" ;
        "centralus"          = "CUS" ;
        "eastasia"           = "EA" ;
        "eastus"             = "EUS" ;
        "eastus2"            = "EUS2" ;
        "eastus2euap"        = "EAP" ;
        "francecentral"      = "PAR" ;
        "japaneast"          = "EJP" ;
        "koreacentral"       = "SE" ;
        "northeurope"        = "NEU" ;
        "southcentralus"     = "SCUS" ;
        "southeastasia"      = "SEA" ;
        "uksouth"            = "SUK" ;
        "usgovvirginia"      = "USGV" ;
        "westcentralus"      = "EUS" ;
        "westeurope"         = "WEU" ;
        "westus"             = "WUS" ;
        "westus2"            = "WUS2"
    }
    $AzureCloudRegionToOmsRegionMap = @{
        "australiacentral"   = "australiacentral" ;
        "australiacentral2"  = "australiacentral" ;
        "australiaeast"      = "australiaeast" ;
        "australiasoutheast" = "australiasoutheast" ;
        "brazilsouth"        = "southcentralus" ;
        "canadacentral"      = "canadacentral" ;
        "canadaeast"         = "canadacentral" ;
        "centralus"          = "centralus" ;
        "centralindia"       = "centralindia" ;
        "eastasia"           = "eastasia" ;
        "eastus"             = "eastus" ;
        "eastus2"            = "eastus2" ;
        "francecentral"      = "francecentral" ;
        "francesouth"        = "francecentral" ;
        "japaneast"          = "japaneast" ;
        "japanwest"          = "japaneast" ;
        "koreacentral"       = "koreacentral" ;
        "koreasouth"         = "koreacentral" ;
        "northcentralus"     = "eastus" ;
        "northeurope"        = "northeurope" ;
        "southafricanorth"   = "westeurope" ;
        "southafricawest"    = "westeurope" ;
        "southcentralus"     = "southcentralus" ;
        "southeastasia"      = "southeastasia" ;
        "southindia"         = "centralindia" ;
        "uksouth"            = "uksouth" ;
        "ukwest"             = "uksouth" ;
        "westcentralus"      = "eastus" ;
        "westeurope"         = "westeurope" ;
        "westindia"          = "centralindia" ;
        "westus"             = "westus" ;
        "westus2"            = "westus2";
        "usgovvirginia"      = "usgovvirginia"
    }

    $workspaceRegionCode = "EUS"
    $workspaceRegion = "eastus"
    if ($AzureCloudRegionToOmsRegionMap.Contains($clusterRegion)) {
        $workspaceRegion = $AzureCloudRegionToOmsRegionMap[$clusterRegion]

        if ($AzureCloudLocationToOmsRegionCodeMap.Contains($workspaceRegion)) {
            $workspaceRegionCode = $AzureCloudLocationToOmsRegionCodeMap[$workspaceRegion]
        }
    }

    $workspaceResourceGroup = "DefaultResourceGroup-" + $workspaceRegionCode
    $workspaceName = "DefaultWorkspace-" + $clusterSubscriptionId + "-" + $workspaceRegionCode

    # validate specified logAnalytics workspace exists and got access permissions
    Write-Host("Checking default Log Analytics Workspace Resource Group exists and got access...")
    $rg = Get-AzResourceGroup -ResourceGroupName $workspaceResourceGroup -ErrorAction SilentlyContinue
    if ($null -eq $rg) {
        Write-Host("Creating Default Workspace Resource Group: '" + $workspaceResourceGroup + "' since this does not exist")
        New-AzResourceGroup -Name $workspaceResourceGroup -Location $workspaceRegion -ErrorAction Stop
    }
    else {
        Write-Host("Resource Group : '" + $workspaceResourceGroup + "' exists")
    }

    Write-Host("Checking default Log Analytics Workspace exists and got access...")
    $WorkspaceInformation = Get-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -ErrorAction SilentlyContinue
    if ($null -eq $WorkspaceInformation) {
        Write-Host("Creating Log Analytics Workspace: '" + $workspaceName + "'  in Resource Group: '" + $workspaceResourceGroup + "' since this workspace does not exist")
        $WorkspaceInformation = New-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -Location $workspaceRegion -ErrorAction Stop
    }
    else {
        Write-Host("Azure Log Workspace: '" + $workspaceName + "' exists in WorkspaceResourceGroup : '" + $workspaceResourceGroup + "'  ")
    }
}
else {

    Write-Host("using specified Log Analytics Workspace ResourceId: '" + $workspaceResourceId + "' ")
    if ([string]::IsNullOrEmpty($workspaceResourceId)) {
        Write-Host("Specified workspaceResourceId should not be NULL or empty") -ForegroundColor Red
        exit
    }
    $workspaceResourceId = $workspaceResourceId.Trim()
    if ($workspaceResourceId.EndsWith("/")) {
        Write-Host("Trimming redundant / in tail end of the log analytics workspace resource id")
        $workspaceResourceId = $workspaceResourceId.TrimEnd("/")
    }

    if ($workspaceResourceId.StartsWith("/") -eq $false) {
        Write-Host("Prepending / to log analytics resource id since this doesnt exist")
        $workspaceResourceId = "/" + $workspaceResourceId
    }

    if (($workspaceResourceId.ToLower().Contains("microsoft.operationalinsights/workspaces") -ne $true) -or ($workspaceResourceId.Split("/").Length -ne 9)) {
        Write-Host("Provided workspace resource id should be in this format /subscriptions/<subId>/resourceGroups/<rgName>/providers/Microsoft.OperationalInsights/workspaces/<workspaceName>") -ForegroundColor Red
        exit
    }

    $workspaceResourceParts = $workspaceResourceId.Split("/")
    $workspaceSubscriptionId = $workspaceResourceParts[2]
    $workspaceResourceGroup = $workspaceResourceParts[4]
    $workspaceName = $workspaceResourceParts[8]

    if (($workspaceSubscriptionId.ToLower() -eq $clusterSubscriptionId.ToLower()) -eq $false) {
        Write-Host("Changing context to workspace subscription: $workspaceSubscriptionId since workspace and cluster in different subscription")
        Set-AzContext -SubscriptionId $workspaceSubscriptionId
    }

    Write-Host("Checking specified Log Analytics Workspace exists and got access...")
    $WorkspaceInformation = Get-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -ErrorAction SilentlyContinue
    if ($null -eq $WorkspaceInformation) {
        Write-Host("Specified Log Analytics Workspace: '" + $workspaceName + "'  in Resource Group: '" + $workspaceResourceGroup + "' in Subscription: '" + $workspaceSubscriptionId + "' does not exist") -ForegroundColor Red
        exit
    }
}

Write-Host("Deploying template to onboard Container Insights solution : Please wait...")

$DeploymentName = "ContainerInsightsSolutionOnboarding-" + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')
$Parameters = @{ }
$Parameters.Add("workspaceResourceId", $WorkspaceInformation.ResourceId)
$Parameters.Add("workspaceRegion", $WorkspaceInformation.Location)
$Parameters
try {
    New-AzResourceGroupDeployment -Name $DeploymentName `
        -ResourceGroupName $workspaceResourceGroup `
        -TemplateUri  $solutionTemplateUri `
        -TemplateParameterObject $Parameters -ErrorAction Stop`

    Write-Host("")
    Write-Host("Successfully added Container Insights Solution") -ForegroundColor Green

    Write-Host("")
}
catch {
    Write-Host ("Template deployment failed with an error: '" + $Error[0] + "' ") -ForegroundColor Red
    Write-Host("Please contact us by emailing askcoin@microsoft.com for help") -ForegroundColor Red
}

$workspaceGUID = "";
$workspacePrimarySharedKey = "";
Write-Host("Retrieving WorkspaceGUID and WorkspacePrimaryKey of the workspace : " + $WorkspaceInformation.Name)
try {

    $WorkspaceSharedKeys = Get-AzOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $WorkspaceInformation.ResourceGroupName -Name $WorkspaceInformation.Name -ErrorAction Stop -WarningAction SilentlyContinue
    $workspaceGUID = $WorkspaceInformation.CustomerId
    $workspacePrimarySharedKey = $WorkspaceSharedKeys.PrimarySharedKey
}
catch {
    Write-Host ("Failed to workspace details. Please validate whether you have Log Analytics Contributor role on the workspace error: '" + $Error[0] + "' ") -ForegroundColor Red
    exit
}


$account = Get-AzContext -ErrorAction Stop
if ($account.Subscription.Id -eq $clusterSubscriptionId) {
    Write-Host("Changing back context to cluster subscription: $clusterSubscriptionId")
    Set-AzContext -SubscriptionId $clusterSubscriptionId
}

if ($isAksCluster -eq $true) {
    Write-Host ("Enabling AKS Monitoring Addon ..")
    # TBD
}
else {
    Write-Host("Attaching workspaceResourceId tag on the cluster ResourceId")
    $clusterResource.Tags["logAnalyticsWorkspaceResourceId"] = $WorkspaceInformation.ResourceId
    Set-AzResource -Tag $clusterResource.Tags -ResourceId $clusterResource.ResourceId -Force
}

$helmVersion = helm version
Write-Host "Helm version" : $helmVersion

Write-Host("Installing or upgrading if exists, Azure Monitor for containers HELM chart ...")
try {

    Write-Host("Add helm chart repo- ${microsoftHelmRepoName} with repo path: ${microsoftHelmRepo}")
    helm repo add ${microsoftHelmRepoName} ${microsoftHelmRepo}
    Write-Host("Updating the helm chart repo- ${microsoftHelmRepoName} to get latest chart versions")
    helm repo update ${microsoftHelmRepoName}

    $helmChartRepoPath = "${microsoftHelmRepoName}" + "/" + "${helmChartName}"

    Write-Host("helmChartRepoPath is : ${helmChartRepoPath}")

    $helmParameters = "omsagent.domain=$omsAgentDomainName,omsagent.secret.wsid=$workspaceGUID,omsagent.secret.key=$workspacePrimarySharedKey,omsagent.env.clusterId=$clusterResourceId,omsagent.env.clusterRegion=$clusterRegion"
    if ([string]::IsNullOrEmpty($proxyEndpoint) -eq $false) {
        Write-Host("using proxy endpoint since its provided")
        $helmParameters = $helmParameters + ",omsagent.proxy=$proxyEndpoint"
    }
    if ([string]::IsNullOrEmpty($kubeContext)) {
        helm upgrade --install $helmChartReleaseName --set $helmParameters $helmChartRepoPath
    }
    else {
        Write-Host("using provided kube-context: $kubeContext")
        helm upgrade --install $helmChartReleaseName --set $helmParameters $helmChartRepoPath --kube-context $kubeContext
    }
}
catch {
    Write-Host ("Failed to Install Azure Monitor for containers HELM chart : '" + $Error[0] + "' ") -ForegroundColor Red
}

Write-Host("Successfully enabled Azure Monitor for containers for cluster: $clusterResourceId") -ForegroundColor Green
Write-Host("Proceed to https://aka.ms/azmon-containers to view your newly onboarded Azure Managed cluster") -ForegroundColor Green
