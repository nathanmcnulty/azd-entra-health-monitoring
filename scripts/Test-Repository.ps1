#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $BicepPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$parseErrors = @()
Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Include *.ps1, *.psm1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref] $tokens, [ref] $errors) | Out-Null
    $parseErrors += @($errors)
}
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }

Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter *.json | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100 | Out-Null
}

$lock = Get-Content -LiteralPath (Join-Path $repositoryRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
foreach ($component in @($lock.components)) {
    foreach ($file in @($component.files)) {
        $path = Join-Path $repositoryRoot $file.target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Locked component file is missing: $($file.target)" }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string] $file.sha256) { throw "Locked component file drifted: $($file.target)" }
    }
}

# Existing repository suites rely on ordinary missing-property behavior. Do not
# inherit a caller's strict-mode setting into the shared Pester run.
Set-StrictMode -Off
Import-Module Pester -RequiredVersion 5.7.1 -Force
$pester = Invoke-Pester -Path (Join-Path $repositoryRoot 'tests') -PassThru
if ($pester.Result -ne 'Passed') { throw "Pester validation failed: $($pester.Result)." }

& $BicepPath build (Join-Path $repositoryRoot 'infra/main.bicep') --stdout | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Bicep validation failed with exit code $LASTEXITCODE." }

Write-Output "Repository validation passed: PowerShell parsed, JSON parsed, component hashes matched, Pester $($pester.PassedCount)/$($pester.TotalCount), Bicep compiled."
