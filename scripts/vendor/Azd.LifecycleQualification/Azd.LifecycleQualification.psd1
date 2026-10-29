@{
    RootModule = 'Azd.LifecycleQualification.psm1'
    ModuleVersion = '0.1.1'
    GUID = '52f04d1d-4782-4719-aaf6-a370f0ecce62'
    Author = 'azd-reference maintainers'
    CompanyName = 'Community'
    Copyright = 'Released into the public domain under the Unlicense.'
    Description = 'Fail-closed synthetic lifecycle evidence qualification, separate from deployment validation.'
    PowerShellVersion = '7.6'
    FunctionsToExport = @(
        'Get-AzdLifecycleRequiredStage',
        'New-AzdLifecyclePlan',
        'Test-AzdLifecycleEnvelope',
        'ConvertFrom-AzdLifecycleLegacyReport',
        'New-AzdLifecyclePublicProjection'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('azd', 'lifecycle', 'qualification', 'synthetic') } }
}
