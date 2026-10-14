#Requires -Version 7.6
[CmdletBinding()]
param(
    [Alias('PlanOnly')]
    [switch] $Plan,

    [string] $OutputPath = 'reports/deployment-validation.json',

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$enginePath = Join-Path $PSScriptRoot 'vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    throw 'The deployment-validation component is missing. Synchronize the reviewed immutable component before validation.'
}

Import-Module $enginePath -Force
Import-Module (Join-Path $PSScriptRoot 'Health.Validation.psm1') -Force

$startedAt = [datetimeoffset]::UtcNow
$checks = @(Invoke-AzdValidationSet -Definitions @(Get-ProjectValidationDefinition) -Plan:$Plan)
$environment = if ($Plan) {
    @{ name = 'plan'; tenantId = '00000000-0000-0000-0000-000000000000' }
}
else {
    $context = Get-HealthValidationContext
    @{
        name = $context.environmentName
        tenantId = $context.tenantId
        subscriptionId = $context.subscriptionId
        resourceGroup = $context.resourceGroup
    }
}

$report = New-AzdValidationReport `
    -TemplateName 'azd-entra-health-monitoring' `
    -TemplateVersion '0.0.1' `
    -Mode $(if ($Plan) { 'plan' } else { 'verify' }) `
    -StartedAt $startedAt `
    -Checks $checks `
    -Environment $environment `
    -Requirements @{
        tools = @('az', 'azd')
        modules = @()
        permissions = @('Read access to the selected Azure resource group')
    } `
    -NextSteps @(
        'Treat Graph subscription freshness, workflow execution, and recipient confirmation as separate evidence.',
        'Confirm an actual entitled health alert in Teams before claiming recipient receipt.',
        'Keep managed-connector consent and lifecycle behavior solution-owned.'
    )

$writtenPath = Write-AzdValidationReport -Report $report -OutputPath $OutputPath -RepositoryRoot $repositoryRoot
Write-AzdValidationSummary -Report $report
Write-Host "Validation report: $writtenPath"
if ($PassThru) { $report }
Assert-AzdValidationSucceeded -Report $report
