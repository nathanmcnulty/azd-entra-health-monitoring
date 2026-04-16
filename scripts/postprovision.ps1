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

function Set-AzdValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    azd env set $Name $Value | Out-Null
    Set-Item -Path "env:$Name" -Value $Value
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
        [string]$Uri,
        [Parameter(Mandatory = $false)]
        [object]$Body
    )

    $headers = @{ Authorization = "Bearer $(Get-ManagementToken)" }
    $debugRequests = $env:AZD_POSTPROVISION_DEBUG -eq '1'
    if ($PSBoundParameters.ContainsKey('Body')) {
        $jsonBody = $Body | ConvertTo-Json -Depth 20
        if ($debugRequests) {
            Write-Host "ARM $Method $Uri"
            Write-Host $jsonBody
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $jsonBody -ContentType 'application/json'
    }

    if ($debugRequests) {
        Write-Host "ARM $Method $Uri"
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Get-LogicAppTriggerCallbackUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkflowName,
        [Parameter(Mandatory = $true)]
        [string]$TriggerName
    )

    $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    $resourceGroupName = $env:AZURE_RESOURCE_GROUP
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Logic/workflows/$WorkflowName/triggers/$TriggerName/listCallbackUrl?api-version=2016-06-01"
    $response = Invoke-AzureManagementJson -Method Post -Uri $uri
    return $response.value
}

function Get-DeploymentLocation {
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_LOCATION)) {
        return $env:AZURE_LOCATION
    }

    $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    $resourceGroupName = $env:AZURE_RESOURCE_GROUP
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/${resourceGroupName}?api-version=2021-04-01"
    $resourceGroup = Invoke-AzureManagementJson -Method Get -Uri $uri
    if ([string]::IsNullOrWhiteSpace($resourceGroup.location)) {
        throw 'Unable to resolve the Azure location for the current resource group.'
    }

    return $resourceGroup.location
}

function Get-TeamsConnectionStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    $resourceGroupName = $env:AZURE_RESOURCE_GROUP
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connections/${ConnectionName}?api-version=2016-06-01"
    $connection = Invoke-AzureManagementJson -Method Get -Uri $uri
    return ($connection.properties.statuses | Select-Object -First 1).status
}

function Test-TeamsConnectionReady {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConnectionName,
        [Parameter(Mandatory = $false)]
        [string]$Status
    )

    $readyStatuses = @('Authenticated', 'Connected', 'Ready')
    if (-not $PSBoundParameters.ContainsKey('Status')) {
        $status = Get-TeamsConnectionStatus -ConnectionName $ConnectionName
    }

    return $status -in $readyStatuses
}

function Wait-ForTeamsConnectionAuthorization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName,
        [Parameter(Mandatory = $true)]
        [string]$ConsentUrl
    )

    Write-Warning 'Follow this link to complete the Teams connection setup for the Logic App.'
    Write-Warning 'Use the account that should appear as the sender for messages posted to the Teams channel.'
    Write-Host ''
    Write-Host $ConsentUrl
    Write-Host ''

    while ($true) {
        $response = Read-Host 'Press Enter after completing the browser consent flow, or type skip to exit'
        if ($response.Trim().ToLowerInvariant() -eq 'skip') {
            return $false
        }

        $status = Get-TeamsConnectionStatus -ConnectionName $ConnectionName
        if (Test-TeamsConnectionReady -Status $status) {
            return $true
        }

        $displayStatus = if ([string]::IsNullOrWhiteSpace($status)) { '<unknown>' } else { $status }
        Write-Warning "Teams connection status is '$displayStatus'. Finish the browser consent flow from the link above, then press Enter to check again."
    }
}

function Write-DeploymentSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NotificationUrl,
        [Parameter(Mandatory = $true)]
        [string]$ConnectionStatus
    )

    Write-Host 'Deployment summary:'
    Write-Host "  Alert Logic App: $($env:LOGIC_APP_NAME)"
    Write-Host "  Lifecycle Logic App: $($env:LIFECYCLE_LOGIC_APP_NAME)"
    Write-Host "  Resource Group: $($env:AZURE_RESOURCE_GROUP)"
    Write-Host "  Webhook URL: $NotificationUrl"
    Write-Host "  Teams Connection: $($env:TEAMS_CONNECTION_NAME)"
    Write-Host "  Teams Connection Status: $ConnectionStatus"
}

function Ensure-TeamsConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    $resourceGroupName = $env:AZURE_RESOURCE_GROUP
    $location = Get-DeploymentLocation
    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connections/${ConnectionName}?api-version=2016-06-01"
    $body = @{
        location   = $location
        kind       = 'V1'
        properties = @{
            displayName           = 'Microsoft Teams'
            customParameterValues = @{}
            api                   = @{
                id = "/subscriptions/$subscriptionId/providers/Microsoft.Web/locations/$location/managedApis/teams"
            }
        }
    }

    Invoke-AzureManagementJson -Method Put -Uri $uri -Body $body | Out-Null
}

function Get-TeamsConsentLink {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionName
    )

    $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    $resourceGroupName = $env:AZURE_RESOURCE_GROUP
    $location = Get-DeploymentLocation
    $tenantId = $env:TARGET_TENANT_ID
    $objectId = az ad signed-in-user show --query id -o tsv
    if ([string]::IsNullOrWhiteSpace($objectId)) {
        throw 'Unable to resolve the signed-in Azure CLI user object ID.'
    }

    $uri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connections/${ConnectionName}/listConsentLinks?api-version=2016-06-01"
    $body = @{
        parameters = @(
            @{
                parameterName = 'token'
                redirectUrl   = 'https://portal.azure.com'
                objectId      = $objectId
                tenantId      = $tenantId
            }
        )
    }

    $response = Invoke-AzureManagementJson -Method Post -Uri $uri -Body $body
    return $response.value | Select-Object -First 1
}

function Ensure-ManagedIdentityGraphRoles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,
        [Parameter(Mandatory = $true)]
        [string[]]$RoleValues
    )

    $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Unable to acquire a Microsoft Graph delegated token from Azure CLI.'
    }

    $headers = @{ Authorization = "Bearer $token" }

    $graphServicePrincipal = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'" -Headers $headers
    $graphSp = $graphServicePrincipal.value | Select-Object -First 1
    if (-not $graphSp) {
        throw 'Microsoft Graph service principal was not found in this tenant.'
    }

    $principalSp = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=id eq '$PrincipalId'" -Headers $headers
    $principal = $principalSp.value | Select-Object -First 1
    if (-not $principal) {
        throw "Service principal '$PrincipalId' was not found."
    }

    $existingAssignments = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignments?`$top=999" -Headers $headers

    foreach ($roleValue in $RoleValues) {
        $role = @($graphSp.appRoles | Where-Object { $_.value -eq $roleValue -and $_.allowedMemberTypes -contains 'Application' }) | Select-Object -First 1
        if (-not $role) {
            throw "Application role '$roleValue' was not found on Microsoft Graph."
        }

        $assignment = @($existingAssignments.value | Where-Object { $_.resourceId -eq $graphSp.id -and $_.appRoleId -eq $role.id }) | Select-Object -First 1
        if ($assignment) {
            Write-Host "Managed identity $PrincipalId already has $roleValue."
            continue
        }

        $jsonBody = @{
            principalId = $principal.id
            resourceId  = $graphSp.id
            appRoleId   = $role.id
        } | ConvertTo-Json -Depth 20

        Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($principal.id)/appRoleAssignments" -Headers $headers -Body $jsonBody -ContentType 'application/json' | Out-Null

        Write-Host "Assigned $roleValue to managed identity $PrincipalId."
    }
}

Import-AzdEnvironment

if ([string]::IsNullOrWhiteSpace($env:LOGIC_APP_NAME)) {
    throw 'LOGIC_APP_NAME was not found in the azd environment. Run azd provision first.'
}

$notificationUrl = Get-LogicAppTriggerCallbackUrl -WorkflowName $env:LOGIC_APP_NAME -TriggerName 'When_a_HTTP_request_is_received'
Set-AzdValue -Name 'GRAPH_NOTIFICATION_URL' -Value $notificationUrl

Ensure-TeamsConnection -ConnectionName $env:TEAMS_CONNECTION_NAME
$consentLink = Get-TeamsConsentLink -ConnectionName $env:TEAMS_CONNECTION_NAME

if ($null -ne $consentLink -and $consentLink.status -ne 'Authenticated' -and -not [string]::IsNullOrWhiteSpace($consentLink.link)) {
    if (-not (Wait-ForTeamsConnectionAuthorization -ConnectionName $env:TEAMS_CONNECTION_NAME -ConsentUrl $consentLink.link)) {
        Write-Warning 'Teams connection authorization was skipped. Rerun: azd hooks run postprovision'
        return
    }
}

Ensure-ManagedIdentityGraphRoles -PrincipalId $env:LOGIC_APP_PRINCIPAL_ID -RoleValues @('HealthMonitoringAlert.Read.All')
Ensure-ManagedIdentityGraphRoles -PrincipalId $env:LIFECYCLE_LOGIC_APP_PRINCIPAL_ID -RoleValues @('HealthMonitoringAlertConfig.ReadWrite.All')

$connectionStatus = Get-TeamsConnectionStatus -ConnectionName $env:TEAMS_CONNECTION_NAME
Write-DeploymentSummary -NotificationUrl $notificationUrl -ConnectionStatus $connectionStatus

Write-Host 'Logic App bootstrap is complete. Graph subscription lifecycle is handled by the lifecycle workflow managed identity.'
