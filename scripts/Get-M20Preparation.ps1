#Requires -Version 7.6
[CmdletBinding()]
param(
    [ValidateSet('Plan','Simulate', IgnoreCase=$false)][string]$Mode='Plan',
    [ValidateSet('normal','create-race','create-response-lost','ledger-lost','recreated','wrong-stub','swapped-run','missing-correlation','redacted-oracle','billing-unavailable','admission-exhausted','recovery-exhausted','before-disable','before-cancel','before-delete','before-absence','unknown-delete','unknown-invoke', IgnoreCase=$false)][string]$Scenario='normal'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Health.M20Preparation.psm1') -Force
if($Mode -eq 'Plan'){Get-HealthM20Plan|ConvertTo-Json -Depth 15}
else{Invoke-HealthM20Simulation -Scenario $Scenario|ConvertTo-Json -Depth 15}
