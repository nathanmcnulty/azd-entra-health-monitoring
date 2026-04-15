$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Web.HttpUtility

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
        [string]$Value
    )

    azd env set $Name $Value | Out-Null
    Set-Item -Path "env:$Name" -Value $Value
}

function Read-ValueWithDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = ''
    )

    $displayPrompt = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        $Prompt
    } else {
        "$Prompt [$DefaultValue]"
    }

    $value = Read-Host $displayPrompt
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

Import-AzdEnvironment

$envName = if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) { 'dev' } else { $env:AZURE_ENV_NAME }

if ([string]::IsNullOrWhiteSpace($env:AZURE_RESOURCE_GROUP)) {
    $resourceGroupName = Read-ValueWithDefault -Prompt 'Azure resource group name' -DefaultValue "rg-$envName"
    if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
        throw 'An Azure resource group name is required.'
    }

    Set-AzdValue -Name 'AZURE_RESOURCE_GROUP' -Value $resourceGroupName
}

if ([string]::IsNullOrWhiteSpace($env:LOGIC_APP_NAME)) {
    $logicAppName = Read-ValueWithDefault -Prompt 'Logic App name' -DefaultValue 'la-entra-health-alerts'
    if ([string]::IsNullOrWhiteSpace($logicAppName)) {
        throw 'A Logic App name is required.'
    }

    Set-AzdValue -Name 'LOGIC_APP_NAME' -Value $logicAppName
}

if ([string]::IsNullOrWhiteSpace($env:TEAMS_CHANNEL_LINK)) {
    $teamsChannelLink = Read-ValueWithDefault -Prompt 'Paste the Teams channel link'
    if ([string]::IsNullOrWhiteSpace($teamsChannelLink)) {
        throw 'TEAMS_CHANNEL_LINK must be provided before running azd provision.'
    }

    Set-AzdValue -Name 'TEAMS_CHANNEL_LINK' -Value $teamsChannelLink
}

$env:TEAMS_CHANNEL_LINK = (azd env get-value TEAMS_CHANNEL_LINK)

if ([string]::IsNullOrWhiteSpace($env:TEAMS_CHANNEL_LINK)) {
    throw 'TEAMS_CHANNEL_LINK must be provided before running azd provision.'
}

$channelUri = [System.Uri]$env:TEAMS_CHANNEL_LINK
$decodedSegments = $channelUri.AbsolutePath.Trim('/').Split('/') | ForEach-Object { [System.Uri]::UnescapeDataString($_) }

if ($decodedSegments.Length -lt 4 -or $decodedSegments[0] -ne 'l' -or $decodedSegments[1] -ne 'channel') {
    throw 'TEAMS_CHANNEL_LINK is not a supported Teams channel link.'
}

$query = [System.Web.HttpUtility]::ParseQueryString($channelUri.Query)
$targetChannelId = $decodedSegments[2]
$targetChannelDisplayName = $decodedSegments[3]
$targetTeamId = $query['groupId']
$targetTenantId = $query['tenantId']

if ([string]::IsNullOrWhiteSpace($targetTeamId) -or [string]::IsNullOrWhiteSpace($targetTenantId)) {
    throw 'Unable to derive groupId or tenantId from TEAMS_CHANNEL_LINK.'
}

Set-AzdValue -Name 'TARGET_CHANNEL_ID' -Value $targetChannelId
Set-AzdValue -Name 'TARGET_CHANNEL_DISPLAY_NAME' -Value $targetChannelDisplayName
Set-AzdValue -Name 'TARGET_TEAM_ID' -Value $targetTeamId
Set-AzdValue -Name 'TARGET_TENANT_ID' -Value $targetTenantId

if ([string]::IsNullOrWhiteSpace($env:GRAPH_SUBSCRIPTION_CLIENT_STATE)) {
    Set-AzdValue -Name 'GRAPH_SUBSCRIPTION_CLIENT_STATE' -Value ([guid]::NewGuid().Guid)
}

Write-Host "Prepared Logic App deployment values for Teams channel '$targetChannelDisplayName'."
