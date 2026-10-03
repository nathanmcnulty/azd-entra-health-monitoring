#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$Location = '',
    [Parameter(Mandatory)][string]$EnvironmentName,
    [Parameter(Mandatory)][string]$LogicAppName,
    [string]$ExistingReference = '',
    [switch]$MigrationVerified,
    [switch]$Rotate,
    [switch]$VerifiedSubscriptionAbsent
)

$ErrorActionPreference = 'Stop'

function Invoke-QuietAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI could not verify or prepare the selected Key Vault scope. Use the normal cached or browser sign-in and check Azure permissions.' }
    return ($result | Out-String).Trim()
}

function Get-TokenClaims {
    param([Parameter(Mandatory)][string]$Token)
    try {
        $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    }
    catch { throw 'The selected Azure account did not provide usable identity claims.' }
}

function Get-StatusCode {
    param($ErrorRecord)
    if ($null -ne $ErrorRecord.Exception.StatusCode) { return [int]$ErrorRecord.Exception.StatusCode }
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response -and $null -ne $response.StatusCode) { return [int]$response.StatusCode }
    return 0
}

function Get-ManagedSecret {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token)
    try {
        return Invoke-RestMethod -Method GET -Uri $Uri -Headers @{ Authorization = "Bearer $Token" }
    }
    catch {
        if ((Get-StatusCode $_) -eq 404) { return $null }
        throw 'The selected account could not read the managed Key Vault secret.'
    }
}

if ($SubscriptionId -notmatch '^[0-9a-fA-F-]{36}$' -or $TenantId -notmatch '^[0-9a-fA-F-]{36}$' -or
    $ResourceGroupName -notmatch '^[A-Za-z0-9_.()\-]{1,90}$' -or
    $EnvironmentName -notmatch '^[A-Za-z0-9_.-]{1,64}$' -or
    $LogicAppName -notmatch '^[A-Za-z0-9_.()\-]{1,80}$' -or
    (-not [string]::IsNullOrWhiteSpace($Location) -and $Location -notmatch '^[a-zA-Z0-9-]{2,40}$')) {
    throw 'The selected subscription, tenant, resource group, location, environment, or Logic App name is invalid.'
}

$account = Invoke-QuietAz -Arguments @('account', 'show', '--subscription', $SubscriptionId, '--output', 'json') | ConvertFrom-Json
if ([string]$account.id -ne $SubscriptionId -or [string]$account.tenantId -ne $TenantId -or
    [string]$account.environmentName -ne 'AzureCloud') {
    throw 'The active Azure CLI account does not match the selected AzureCloud subscription and tenant.'
}

$armToken = Invoke-QuietAz -Arguments @('account', 'get-access-token', '--subscription', $SubscriptionId,
    '--resource', 'https://management.azure.com/', '--query', 'accessToken', '--output', 'tsv')
$claims = Get-TokenClaims -Token $armToken
if ([string]$claims.tid -ne $TenantId -or [string]$claims.oid -notmatch '^[0-9a-fA-F-]{36}$') {
    throw 'The Azure CLI token identity does not match the selected tenant or lacks an object ID.'
}

$hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$ResourceGroupName/$EnvironmentName".ToLowerInvariant()))
$vaultName = 'kvh' + ([Convert]::ToHexString($hashBytes).Substring(0, 20).ToLowerInvariant())
$secretName = 'graph-subscription-client-state'
$reference = "akvs://$SubscriptionId/$vaultName/$secretName"
if (-not [string]::IsNullOrWhiteSpace($ExistingReference) -and $ExistingReference -cne $reference) {
    throw 'GRAPH_SUBSCRIPTION_CLIENT_STATE must reference this environment-owned Key Vault secret.'
}
if ($Rotate -and ([string]::IsNullOrWhiteSpace($ExistingReference) -or -not $VerifiedSubscriptionAbsent)) {
    throw 'Rotation requires the existing Key Vault reference and explicit verification that the exact owned Graph subscription is absent.'
}

# An older deployment used a public deterministic state. Never silently change its
# receiver before an operator has reconciled the existing Graph subscription.
if ([string]::IsNullOrWhiteSpace($ExistingReference)) {
    $workflowUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName" + '?api-version=2019-05-01'
    try {
        Invoke-RestMethod -Method GET -Uri $workflowUri -Headers @{ Authorization = "Bearer $armToken" } | Out-Null
        if (-not $MigrationVerified -or -not $VerifiedSubscriptionAbsent) {
            throw 'An existing alert workflow needs explicit Graph subscription migration before a new clientState is installed.'
        }
    }
    catch {
        if ((Get-StatusCode $_) -ne 404) { throw }
    }
}

if ($Rotate -or $MigrationVerified) {
    $lifecycleUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/la-graph-subscription-management" + '?api-version=2019-05-01'
    try {
        $lifecycle = Invoke-RestMethod -Method GET -Uri $lifecycleUri -Headers @{ Authorization = "Bearer $armToken" }
    }
    catch { throw 'The lifecycle workflow state could not be verified for clientState migration or rotation.' }
    if ([string]$lifecycle.properties.state -ne 'Disabled') {
        throw 'Disable the lifecycle workflow before clientState migration or rotation.'
    }
}

$vaultId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$vaultName"
$vaultUri = "https://management.azure.com$vaultId" + '?api-version=2023-07-01'
try {
    $vault = Invoke-RestMethod -Method GET -Uri $vaultUri -Headers @{ Authorization = "Bearer $armToken" }
}
catch {
    if ((Get-StatusCode $_) -ne 404) { throw 'The environment-bound Key Vault could not be inspected.' }
    $vault = $null
}
if ($null -ne $vault) {
    if ([string]$vault.id -ine $vaultId -or [string]$vault.properties.tenantId -ne $TenantId -or
        [string]$vault.tags.'entra-health-env' -cne $EnvironmentName -or
        [bool]$vault.properties.enableRbacAuthorization) {
        throw 'The deterministic Key Vault name belongs to a different scope or access model.'
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($ExistingReference)) {
    throw 'The Key Vault for the existing clientState reference is unavailable; no replacement secret was generated.'
}
else {
    $groupExists = Invoke-QuietAz -Arguments @('group', 'exists', '--name', $ResourceGroupName, '--subscription', $SubscriptionId)
    if ($groupExists -notin @('true', 'false')) { throw 'Azure CLI returned an invalid resource group existence result.' }
    if ([string]::IsNullOrWhiteSpace($Location)) {
        if ($groupExists -eq 'false') { throw 'AZURE_LOCATION is required before creating a new resource group and Key Vault.' }
        $Location = Invoke-QuietAz -Arguments @('group', 'show', '--name', $ResourceGroupName,
            '--subscription', $SubscriptionId, '--query', 'location', '--output', 'tsv')
    }
    if ($groupExists -eq 'false') {
        Invoke-QuietAz -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location,
            '--subscription', $SubscriptionId, '--output', 'none') | Out-Null
    }
    Invoke-QuietAz -Arguments @('keyvault', 'create', '--name', $vaultName, '--resource-group', $ResourceGroupName,
        '--location', $Location, '--subscription', $SubscriptionId, '--enable-rbac-authorization', 'false',
        '--retention-days', '7', '--tags', "entra-health-env=$EnvironmentName", '--output', 'none') | Out-Null
}

if ([string]::IsNullOrWhiteSpace($ExistingReference)) {
    Invoke-QuietAz -Arguments @('keyvault', 'set-policy', '--name', $vaultName, '--subscription', $SubscriptionId,
        '--object-id', [string]$claims.oid, '--secret-permissions', 'get', 'set', '--output', 'none') | Out-Null
}

$vaultToken = Invoke-QuietAz -Arguments @('account', 'get-access-token', '--subscription', $SubscriptionId,
    '--resource', 'https://vault.azure.net', '--query', 'accessToken', '--output', 'tsv')
$secretUri = "https://$vaultName.vault.azure.net/secrets/$secretName" + '?api-version=7.4'
$stored = $null
for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
        $stored = Get-ManagedSecret -Uri $secretUri -Token $vaultToken
        break
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($ExistingReference) -or $attempt -eq 6) { throw }
        Start-Sleep -Seconds 5
    }
}
if ($null -eq $stored -or $Rotate) {
    if ($null -eq $stored -and -not [string]::IsNullOrWhiteSpace($ExistingReference)) {
        throw 'The referenced clientState secret is missing; no replacement was generated.'
    }
    $bytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    try {
        $clientState = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $body = @{ value = $clientState; contentType = 'Entra health Graph notification clientState' } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Method PUT -Uri $secretUri -Headers @{ Authorization = "Bearer $vaultToken" } -Body $body -ContentType 'application/json' | Out-Null
        }
        catch { throw 'The selected account could not create the managed Key Vault secret.' }
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $clientState = $null
        $body = $null
    }
}
elseif ([string]$stored.value -cnotmatch '^[A-Za-z0-9_-]{43}$') {
    throw 'The managed clientState secret is not a supported 256-bit value; no deployment value was changed.'
}

if ([string]::IsNullOrWhiteSpace($ExistingReference)) {
    $projectRoot = Split-Path $PSScriptRoot -Parent
    & azd env set GRAPH_SUBSCRIPTION_CLIENT_STATE $reference --cwd $projectRoot 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'The Key Vault secret exists, but azd could not save its reference. Rerun the preprovision hook.' }
}

Write-Host 'Verified the environment-bound Key Vault clientState reference.'
