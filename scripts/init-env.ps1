param(
    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

function New-RandomEnvironmentName {
    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $suffix = -join (1..4 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    return "ehm-$suffix"
}

$targetEnvironmentName = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    New-RandomEnvironmentName
} else {
    $EnvironmentName.Trim()
}

Write-Host "Creating azd environment '$targetEnvironmentName'."
azd env new $targetEnvironmentName
