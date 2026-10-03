$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'prepare-inputs.ps1')

foreach ($required in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_ENV_NAME')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($required, 'Process'))) {
        throw "$required must be selected by azd before preparing the Graph notification secret."
    }
}

$migrationVerified = $env:GRAPH_SUBSCRIPTION_MIGRATION_READY -eq 'true' -and
    [string]::IsNullOrWhiteSpace($env:GRAPH_SUBSCRIPTION_CLIENT_STATE)
& (Join-Path $PSScriptRoot 'Initialize-GraphClientState.ps1') `
    -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
    -TenantId $env:AZURE_TENANT_ID `
    -ResourceGroupName $env:AZURE_RESOURCE_GROUP `
    -Location $env:AZURE_LOCATION `
    -EnvironmentName $env:AZURE_ENV_NAME `
    -LogicAppName $env:LOGIC_APP_NAME `
    -ExistingReference $env:GRAPH_SUBSCRIPTION_CLIENT_STATE `
    -MigrationVerified:$migrationVerified `
    -VerifiedSubscriptionAbsent:$migrationVerified

Write-Host "Prepared Logic App deployment values for Teams channel '$($env:TARGET_CHANNEL_DISPLAY_NAME)'."
