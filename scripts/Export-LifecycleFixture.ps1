# Exports deterministic synthetic workflow definitions to local disk only.
# This script never invokes az, Graph, Teams, Logic Apps, or a workflow runtime.
#Requires -Version 7.6
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$ProfilePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'validation/profiles/health-logic-fixture.v1.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Health.LifecycleFixture.psm1') -Force
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $temp = if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $OutputDirectory = Join-Path $temp ("health-logic-fixture-" + [guid]::NewGuid().ToString('N'))
}
$plan=Get-HealthFixturePlan -RepositoryRoot $RepositoryRoot -ProfilePath $ProfilePath
$result=Export-HealthLogicFixture -Plan $plan -OutputDirectory $OutputDirectory
$result | ConvertTo-Json -Depth 8
