#Requires -Version 7.6
# A disabled, offline orchestration skeleton. Exit 0 means plan rendering only.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$componentRoot = Join-Path $PSScriptRoot 'vendor/Azd.LifecycleQualification'
Import-Module (Join-Path $componentRoot 'Azd.LifecycleQualification.psd1') -Force
$profilePath = Join-Path $componentRoot 'profiles/health-logic-fixture.v1.json'
$bytes = [IO.File]::ReadAllBytes($profilePath)
$profile = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable -DateKind String
$digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
New-AzdLifecyclePlan -ProfileId $profile.id -ProfileVersion $profile.version -ProfileSha256 $digest |
    ConvertTo-Json -Depth 12
