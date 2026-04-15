$ErrorActionPreference = 'Stop'

function Import-AzdEnvironment {
    $values = azd env get-values
    foreach ($line in $values) {
        if ([string]::IsNullOrWhiteSpace($line) -or -not $line.Contains('=')) {
            continue
        }

        $parts = $line.Split('=', 2)
        $name = $parts[0]
        $value = $parts[1].Trim('"')
        Set-Item -Path "env:$name" -Value $value
    }
}

function Get-ManagementToken {
    $token = az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire an Azure Resource Manager token from Azure CLI.'
    }

    return $token
}

function Invoke-AzureManagementJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $headers = @{ Authorization = "Bearer $(Get-ManagementToken)" }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

Import-AzdEnvironment

Write-Host "Alert Logic App: $($env:LOGIC_APP_NAME)"
Write-Host "Lifecycle Logic App: $($env:LIFECYCLE_LOGIC_APP_NAME)"
Write-Host "Resource Group: $($env:AZURE_RESOURCE_GROUP)"
Write-Host "Webhook URL: $($env:GRAPH_NOTIFICATION_URL)"
Write-Host "Teams Connection: $($env:TEAMS_CONNECTION_NAME)"

$connectionUri = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.Web/connections/$($env:TEAMS_CONNECTION_NAME)?api-version=2016-06-01"
$connection = Invoke-AzureManagementJson -Method Get -Uri $connectionUri
$connectionStatus = ($connection.properties.statuses | Select-Object -First 1).status
Write-Host "Teams Connection Status: $connectionStatus"

$workflowRunsUri = "https://management.azure.com/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.Logic/workflows/$($env:LIFECYCLE_LOGIC_APP_NAME)/runs?api-version=2019-05-01&`$top=1"
$latestRun = (Invoke-AzureManagementJson -Method Get -Uri $workflowRunsUri).value | Select-Object -First 1
if ($latestRun) {
    Write-Host "Latest Lifecycle Run Status: $($latestRun.properties.status)"
    Write-Host "Latest Lifecycle Run Start: $($latestRun.properties.startTime)"
}
