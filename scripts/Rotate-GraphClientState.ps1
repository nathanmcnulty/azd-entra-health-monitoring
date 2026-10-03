#Requires -Version 7.0

[CmdletBinding()]
param([switch]$VerifiedSubscriptionAbsent)

$ErrorActionPreference = 'Stop'
if (-not $VerifiedSubscriptionAbsent) {
    throw 'Rotation requires verification that the exact callback-bound Graph subscription is absent.'
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$lines = & azd env get-values --cwd $projectRoot 2>$null
if ($LASTEXITCODE -ne 0) { throw 'The current azd environment could not be read.' }
$values = @{}
foreach ($line in $lines) {
    if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
        $values[$Matches[1]] = $Matches[2].Trim('"')
    }
}
foreach ($name in @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_RESOURCE_GROUP',
    'AZURE_ENV_NAME', 'LOGIC_APP_NAME', 'GRAPH_SUBSCRIPTION_CLIENT_STATE')) {
    if ([string]::IsNullOrWhiteSpace([string]$values[$name])) { throw "$name is required for rotation." }
}

& (Join-Path $PSScriptRoot 'Initialize-GraphClientState.ps1') `
    -SubscriptionId $values.AZURE_SUBSCRIPTION_ID `
    -TenantId $values.AZURE_TENANT_ID `
    -ResourceGroupName $values.AZURE_RESOURCE_GROUP `
    -Location ([string]$values.AZURE_LOCATION) `
    -EnvironmentName $values.AZURE_ENV_NAME `
    -LogicAppName $values.LOGIC_APP_NAME `
    -ExistingReference $values.GRAPH_SUBSCRIPTION_CLIENT_STATE `
    -Rotate -VerifiedSubscriptionAbsent

Write-Host 'A new clientState secret version is ready. Run azd provision, then verify the new lifecycle subscription.'
