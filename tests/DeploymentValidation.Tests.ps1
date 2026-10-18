BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/Health.Validation.psm1') -Force

    function ConvertFrom-InvokeRestMethodJson {
        param([Parameter(Mandatory)][string] $Json)
        $method = [Microsoft.PowerShell.Commands.InvokeRestMethodCommand].GetMethod(
            'TryConvertToJson',
            [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic
        )
        $arguments = [object[]]@($Json, $null, $null)
        if (-not $method.Invoke($null, $arguments)) { throw $arguments[2] }
        return $arguments[1]
    }
}

Describe 'HEALTH-005 immutable component adoption' {
    It 'matches the locked deployment-validation version and file hashes' {
        $root = Split-Path -Parent $PSScriptRoot
        $lock = Get-Content -LiteralPath (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'deployment-validation')
        $manifest = Test-ModuleManifest (Join-Path $root 'scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1')

        $component.Count | Should -Be 1
        $component[0].version | Should -Be '1.1.1'
        $component[0].version | Should -Be $manifest.Version.ToString()
        $component[0].sourceRevision | Should -Be '0c96cc89c554ffc3b3ca82ceda12da6591e816c1'
        foreach ($file in @($component[0].files)) {
            (Get-FileHash -LiteralPath (Join-Path $root $file.target) -Algorithm SHA256).Hash.ToLowerInvariant() |
                Should -Be $file.sha256
        }
    }

    It 'does not claim adoption of the incompatible notification result schema' {
        $root = Split-Path -Parent $PSScriptRoot
        $lock = Get-Content -LiteralPath (Join-Path $root 'azd-components.lock.json') -Raw | ConvertFrom-Json
        @($lock.components | Where-Object id -eq 'notification-contracts').Count | Should -Be 0
        Test-Path (Join-Path $root 'contracts/notifications/notification-delivery-result.schema.json') | Should -BeFalse
    }
}

Describe 'HEALTH-005 validation plan boundary' {
    It 'plans exactly four independent evidence checks without invoking adapters' {
        InModuleScope Health.Validation {
            Mock Get-HealthConnectionReadinessOutcome { throw 'must not run' }
            Mock Get-HealthSubscriptionFreshnessOutcome { throw 'must not run' }
            Mock Get-HealthWorkflowRunOutcome { throw 'must not run' }
            Mock Get-HealthRecipientReceiptOutcome { throw 'must not run' }

            $definitions = @(Get-ProjectValidationDefinition)
            $results = @(Invoke-AzdValidationSet -Definitions $definitions -Plan)

            $definitions.id | Should -Be @(
                'connection.readiness',
                'subscription.freshness',
                'workflow.latest-runs',
                'recipient.receipt'
            )
            @($results | Where-Object status -ne 'planned').Count | Should -Be 0
            @($definitions | Where-Object sideEffect -notin @('none', 'readOnly')).Count | Should -Be 0
            Should -Invoke Get-HealthConnectionReadinessOutcome -Times 0 -Exactly
            Should -Invoke Get-HealthSubscriptionFreshnessOutcome -Times 0 -Exactly
            Should -Invoke Get-HealthWorkflowRunOutcome -Times 0 -Exactly
            Should -Invoke Get-HealthRecipientReceiptOutcome -Times 0 -Exactly
        }
    }

    It 'writes a schema-valid report without environment, authentication, or provider input' {
        $relative = "reports/health-plan-$([guid]::NewGuid().Guid).json"
        $root = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $root $relative
        try {
            $report = & (Join-Path $root 'scripts/Test-Deployment.ps1') -Plan -PassThru -OutputPath $relative
            $report.mode | Should -Be 'plan'
            $report.outcome | Should -Be 'planned'
            @($report.checks).Count | Should -Be 4
            (Get-Content -LiteralPath $path -Raw) | Test-Json `
                -SchemaFile (Join-Path $root 'scripts/vendor/Azd.DeploymentValidation/deployment-validation.schema.json') |
                Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'HEALTH-005 connection readiness' {
    It 'accepts only a ready managed-connection provider status' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ subscriptionId='11111111-1111-1111-1111-111111111111'; resourceGroup='rg'; teamsConnection='teams' } }
            Mock Invoke-HealthArmGet { [pscustomobject]@{ properties=[pscustomobject]@{ statuses=@([pscustomobject]@{ status='Connected' }) } } }
            $result = Get-HealthConnectionReadinessOutcome
            $result.status | Should -Be 'pass'
            $result.actual.state | Should -Be 'ready'
        }
    }

    It 'fails a disconnected or missing provider status' -ForEach @('Error', '') {
        InModuleScope Health.Validation -Parameters @{ ProviderStatus = $_ } {
            param($ProviderStatus)
            Mock Get-HealthValidationContext { [pscustomobject]@{ subscriptionId='11111111-1111-1111-1111-111111111111'; resourceGroup='rg'; teamsConnection='teams' } }
            Mock Invoke-HealthArmGet { [pscustomobject]@{ properties=[pscustomobject]@{ statuses=@([pscustomobject]@{ status=$ProviderStatus }) } } }
            $result = Get-HealthConnectionReadinessOutcome
            $result.status | Should -Be 'fail'
            $result.actual.state | Should -Be 'notReady'
        }
    }
}

Describe 'HEALTH-005 cached target boundary' {
    AfterEach {
        Remove-Item Env:AZURE_ENV_NAME, Env:AZURE_TENANT_ID, Env:AZURE_SUBSCRIPTION_ID,
            Env:AZURE_RESOURCE_GROUP, Env:LOGIC_APP_NAME, Env:LIFECYCLE_LOGIC_APP_NAME,
            Env:TEAMS_CONNECTION_NAME -ErrorAction SilentlyContinue
    }

    It 'accepts the exact selected cached subscription and tenant without connecting' {
        InModuleScope Health.Validation {
            $script:HealthValidationContext = $null
            Mock Import-AzdEnvironment {
                $env:AZURE_ENV_NAME='dev'
                $env:AZURE_TENANT_ID='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
                $env:AZURE_SUBSCRIPTION_ID='BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB'
                $env:AZURE_RESOURCE_GROUP='rg-health'
                $env:LOGIC_APP_NAME='alert'
                $env:LIFECYCLE_LOGIC_APP_NAME='lifecycle'
                $env:TEAMS_CONNECTION_NAME='teams'
            }
            Mock az {
                $global:LASTEXITCODE = 0
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'
            }

            $context = Get-HealthValidationContext

            $context.resourceGroup | Should -Be 'rg-health'
            Should -Invoke az -Times 1 -Exactly
        }
    }

    It 'stops on a cached tenant mismatch before any ARM request' {
        InModuleScope Health.Validation {
            $script:HealthValidationContext = $null
            Mock Import-AzdEnvironment {
                $env:AZURE_ENV_NAME='dev'
                $env:AZURE_TENANT_ID='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $env:AZURE_SUBSCRIPTION_ID='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $env:AZURE_RESOURCE_GROUP='rg-health'
                $env:LOGIC_APP_NAME='alert'
                $env:LIFECYCLE_LOGIC_APP_NAME='lifecycle'
                $env:TEAMS_CONNECTION_NAME='teams'
            }
            Mock az {
                $global:LASTEXITCODE = 0
                '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","tenantId":"cccccccc-cccc-cccc-cccc-cccccccccccc"}'
            }
            Mock Invoke-RestMethod { throw 'must not run' }

            { Get-HealthValidationContext } | Should -Throw '*do not match*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    It 'rejects each malformed environment selector before account, token, or REST access' -ForEach @(
        @{ Field='AZURE_TENANT_ID'; Value='../tenant' },
        @{ Field='AZURE_SUBSCRIPTION_ID'; Value='?subscription' },
        @{ Field='AZURE_ENV_NAME'; Value="dev`nother" },
        @{ Field='AZURE_RESOURCE_GROUP'; Value='../../../subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/other' },
        @{ Field='LOGIC_APP_NAME'; Value='alert/../../other' },
        @{ Field='LIFECYCLE_LOGIC_APP_NAME'; Value='lifecycle?api-version=other' },
        @{ Field='TEAMS_CONNECTION_NAME'; Value='teams%2fother' }
    ) {
        InModuleScope Health.Validation -Parameters @{ Field=$Field; Value=$Value } {
            param($Field, $Value)
            $script:HealthValidationContext = $null
            Mock Import-AzdEnvironment {
                $env:AZURE_ENV_NAME='dev'
                $env:AZURE_TENANT_ID='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                $env:AZURE_SUBSCRIPTION_ID='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                $env:AZURE_RESOURCE_GROUP='rg-health'
                $env:LOGIC_APP_NAME='alert'
                $env:LIFECYCLE_LOGIC_APP_NAME='lifecycle'
                $env:TEAMS_CONNECTION_NAME='teams'
                Set-Item -Path "env:$Field" -Value $Value
            }
            Mock az { throw 'must not run' }
            Mock Get-HealthManagementToken { throw 'must not run' }
            Mock Invoke-RestMethod { throw 'must not run' }

            { Get-HealthValidationContext } | Should -Throw
            Should -Invoke az -Times 0 -Exactly
            Should -Invoke Get-HealthManagementToken -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    It 'builds only the exact fixed ARM endpoints before acquiring a token' {
        InModuleScope Health.Validation {
            $script:HealthValidationContext = [pscustomobject]@{
                subscriptionId='11111111-1111-1111-1111-111111111111'
                resourceGroup='rg-health'
                teamsConnection='teams'
                alertWorkflow='alert'
                lifecycleWorkflow='lifecycle'
            }
            Mock Get-HealthManagementToken { 'fake-token' }
            Mock Invoke-RestMethod { [pscustomobject]@{} }

            Invoke-HealthArmGet -Endpoint connection | Out-Null
            Invoke-HealthArmGet -Endpoint workflowRuns -WorkflowName alert | Out-Null
            Invoke-HealthArmGet -Endpoint expirationAction -WorkflowName lifecycle -RunName run-1 | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -ceq 'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-health/providers/Microsoft.Web/connections/teams?api-version=2016-06-01'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -ceq 'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-health/providers/Microsoft.Logic/workflows/alert/runs?api-version=2019-05-01&$top=1'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -ceq 'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-health/providers/Microsoft.Logic/workflows/lifecycle/runs/run-1/actions/Compose_expiration?api-version=2019-05-01'
            }
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter {
                $ConnectionTimeoutSeconds -eq 10 -and $OperationTimeoutSeconds -eq 30
            }
        }
    }

    It 'rejects endpoint selectors outside the configured allowlist before token or REST access' {
        InModuleScope Health.Validation {
            $script:HealthValidationContext = [pscustomobject]@{
                subscriptionId='11111111-1111-1111-1111-111111111111'
                resourceGroup='rg-health'
                teamsConnection='teams'
                alertWorkflow='alert'
                lifecycleWorkflow='lifecycle'
            }
            Mock Get-HealthManagementToken { throw 'must not run' }
            Mock Invoke-RestMethod { throw 'must not run' }

            { Invoke-HealthArmGet -Endpoint workflowRuns -WorkflowName other } | Should -Throw '*configured workflows*'
            { Invoke-HealthArmGet -Endpoint expirationAction -WorkflowName lifecycle -RunName '../other' } | Should -Throw '*bounded legal*'
            { Invoke-HealthArmGet -Endpoint expirationAction -WorkflowName alert -RunName run-1 } | Should -Throw '*lifecycle workflow*'

            Should -Invoke Get-HealthManagementToken -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }

    It 'rejects non-string run selectors before token or REST access' -ForEach @(
        @{ Label='null'; Value=$null },
        @{ Label='boolean'; Value=$true },
        @{ Label='number'; Value=123 },
        @{ Label='array'; Value=@('run-a','run-b') },
        @{ Label='dictionary'; Value=@{ value='run-a' } },
        @{ Label='object'; Value=[pscustomobject]@{ value='run-a' } }
    ) {
        InModuleScope Health.Validation -Parameters @{ Value=$Value } {
            param($Value)
            $script:HealthValidationContext = [pscustomobject]@{
                subscriptionId='11111111-1111-1111-1111-111111111111'
                resourceGroup='rg-health'
                teamsConnection='teams'
                alertWorkflow='alert'
                lifecycleWorkflow='lifecycle'
            }
            Mock Get-HealthManagementToken { throw 'must not run' }
            Mock Invoke-RestMethod { throw 'must not run' }

            { Invoke-HealthArmGet -Endpoint expirationAction -WorkflowName lifecycle -RunName $Value } | Should -Throw '*bounded legal*'
            Should -Invoke Get-HealthManagementToken -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }
    }
}

Describe 'HEALTH-005 subscription freshness' {
    It 'reports no lifecycle run as unknown without reading action output' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { $null }
            Mock Invoke-HealthArmGet { throw 'must not run' }
            $result = Get-HealthSubscriptionFreshnessOutcome
            $result.status | Should -Be 'warning'
            $result.actual.state | Should -Be 'unknown'
            Should -Invoke Invoke-HealthArmGet -Times 0 -Exactly
        }
    }

    It 'reports unavailable safe action evidence as unknown' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { [pscustomobject]@{ name='run-1' } }
            Mock Invoke-HealthArmGet { throw 'not found' }
            $result = Get-HealthSubscriptionFreshnessOutcome
            $result.status | Should -Be 'warning'
            $result.actual.state | Should -Be 'unknown'
            $result.actual.reason | Should -Be 'expirationActionUnavailable'
        }
    }

    It 'does not invoke the action endpoint for a malformed provider run identifier' -ForEach @(
        @{ Label='boolean'; Value=$true },
        @{ Label='number'; Value=123 },
        @{ Label='array'; Value=@('run-a','run-b') },
        @{ Label='dictionary'; Value=@{ value='run-a' } },
        @{ Label='object'; Value=[pscustomobject]@{ value='run-a' } }
    ) {
        InModuleScope Health.Validation -Parameters @{ Value=$Value } {
            param($Value)
            Mock Get-HealthValidationContext { [pscustomobject]@{ lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { [pscustomobject]@{ name=$Value } }
            Mock Invoke-HealthArmGet { throw 'must not run' }

            $result = Get-HealthSubscriptionFreshnessOutcome

            $result.status | Should -Be 'warning'
            $result.actual.reason | Should -Be 'invalidRunEvidence'
            Should -Invoke Invoke-HealthArmGet -Times 0 -Exactly
        }
    }

    It 'keeps actual freshness unknown while qualifying requested expiration evidence' -ForEach @(
        @{ OffsetHours=240; RequestedState='future' },
        @{ OffsetHours=48; RequestedState='near' },
        @{ OffsetHours=-1; RequestedState='past' }
    ) {
        InModuleScope Health.Validation -Parameters @{ OffsetHours=$OffsetHours; RequestedState=$RequestedState } {
            param($OffsetHours, $RequestedState)
            Mock Get-HealthValidationContext { [pscustomobject]@{ lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { [pscustomobject]@{ name='run-1' } }
            Mock Invoke-HealthArmGet {
                [pscustomobject]@{ properties=[pscustomobject]@{
                    status='Succeeded'
                    outputs=[pscustomobject]@{ body=[datetimeoffset]::UtcNow.AddHours($OffsetHours).ToString('o') }
                } }
            }
            $result = Get-HealthSubscriptionFreshnessOutcome
            $result.status | Should -Be 'warning'
            $result.actual.state | Should -Be 'unknown'
            $result.actual.reason | Should -Be 'noAuthoritativeGraphRead'
            $result.actual.requestedExpirationState | Should -Be $RequestedState
            $result.evidence.semantics | Should -Be 'requestedExpirationOnly'
        }
    }

    It 'accepts actual REST JSON DateTime requested-expiration evidence without promoting freshness' {
        $action = ConvertFrom-InvokeRestMethodJson '{"properties":{"status":"Succeeded","outputs":{"body":"2027-01-01T00:00:00Z"}}}'
        $action.properties.outputs.body.GetType().FullName | Should -Be 'System.DateTime'

        InModuleScope Health.Validation -Parameters @{ Action=$action } {
            param($Action)
            Mock Get-HealthValidationContext { [pscustomobject]@{ lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { [pscustomobject]@{ name='run-1' } }
            Mock Invoke-HealthArmGet { $Action }

            $result = Get-HealthSubscriptionFreshnessOutcome

            $result.status | Should -Be 'warning'
            $result.actual.state | Should -Be 'unknown'
            $result.actual.requestedExpirationUtc | Should -Be '2027-01-01T00:00:00.0000000Z'
        }
    }
}

Describe 'HEALTH-005 workflow and recipient evidence separation' {
    It 'accepts the actual PowerShell REST JSON DateTime shape and emits canonical UTC' {
        $parsed = ConvertFrom-InvokeRestMethodJson '{"name":"run-1","properties":{"status":"Succeeded","startTime":"2026-10-13T00:00:00Z"}}'
        $parsed.properties.startTime.GetType().FullName | Should -Be 'System.DateTime'

        InModuleScope Health.Validation -Parameters @{ Parsed=$parsed } {
            param($Parsed)
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { $Parsed }

            $result = Get-HealthWorkflowRunOutcome

            $result.status | Should -Be 'pass'
            $result.actual.runs.alert.startedAt | Should -Be '2026-10-13T00:00:00.0000000Z'
            $result.actual.runs.lifecycle.startedAt | Should -Be '2026-10-13T00:00:00.0000000Z'
        }
    }

    It 'normalizes DateTimeOffset and bounded offset strings without losing their instant' -ForEach @(
        @{ Value=[datetimeoffset]'2026-10-13T00:00:00+02:00'; Expected='2026-10-12T22:00:00.0000000Z' },
        @{ Value='2026-10-13T00:00:00+02:00'; Expected='2026-10-12T22:00:00.0000000Z' }
    ) {
        InModuleScope Health.Validation -Parameters @{ Value=$Value; Expected=$Expected } {
            param($Value, $Expected)
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun {
                [pscustomobject]@{ name='run-1'; properties=[pscustomobject]@{ status='Succeeded'; startTime=$Value } }
            }
            $result = Get-HealthWorkflowRunOutcome
            $result.status | Should -Be 'pass'
            $result.actual.runs.alert.startedAt | Should -Be $Expected
        }
    }

    It 'rejects malformed timestamp scalar and collection shapes as bounded unknown evidence' -ForEach @(
        @{ Label='null'; Value=$null },
        @{ Label='boolean'; Value=$true },
        @{ Label='number'; Value=123 },
        @{ Label='array'; Value=@('2026-10-13T00:00:00Z') },
        @{ Label='dictionary'; Value=@{ value='2026-10-13T00:00:00Z' } },
        @{ Label='object'; Value=[pscustomobject]@{ value='2026-10-13T00:00:00Z' } },
        @{ Label='unspecifiedDateTime'; Value=[datetime]::SpecifyKind([datetime]'2026-10-13T00:00:00', [DateTimeKind]::Unspecified) }
    ) {
        InModuleScope Health.Validation -Parameters @{ Value=$Value } {
            param($Value)
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun {
                [pscustomobject]@{ name='run-1'; properties=[pscustomobject]@{ status='Succeeded'; startTime=$Value } }
            }
            $result = Get-HealthWorkflowRunOutcome
            $serialized = $result | ConvertTo-Json -Depth 20
            $result.status | Should -Be 'warning'
            $result.actual.runs.alert.reason | Should -Be 'invalidRunEvidence'
            $serialized.Length | Should -BeLessThan 2000
        }
    }

    It 'runs the real four-check engine boundary with fake ARM input and leaves receipt unknown' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext {
                [pscustomobject]@{
                    subscriptionId='11111111-1111-1111-1111-111111111111'
                    resourceGroup='rg-health'
                    teamsConnection='teams'
                    alertWorkflow='alert'
                    lifecycleWorkflow='lifecycle'
                }
            }
            Mock Invoke-HealthArmGet {
                if ($Endpoint -eq 'connection') {
                    return [pscustomobject]@{ properties=[pscustomobject]@{ statuses=@([pscustomobject]@{ status='Connected' }) } }
                }
                if ($Endpoint -eq 'expirationAction') {
                    return [pscustomobject]@{ properties=[pscustomobject]@{
                        status='Succeeded'
                        outputs=[pscustomobject]@{ body=[datetimeoffset]::UtcNow.AddDays(20).ToString('o') }
                    } }
                }
                if ($Endpoint -eq 'workflowRuns') {
                    $name = if ($WorkflowName -eq 'alert') { 'alert-run' } else { 'lifecycle-run' }
                    return [pscustomobject]@{ value=@([pscustomobject]@{
                        name=$name
                        properties=[pscustomobject]@{ status='Succeeded'; startTime='2026-10-13T00:00:00Z' }
                    }) }
                }
                throw "Unexpected fake ARM endpoint: $Endpoint"
            }

            $results = @(Invoke-AzdValidationSet -Definitions @(Get-ProjectValidationDefinition))

            $results.id | Should -Be @('connection.readiness','subscription.freshness','workflow.latest-runs','recipient.receipt')
            $results.status | Should -Be @('pass','warning','pass','warning')
            ($results | Where-Object id -eq 'subscription.freshness').actual.state | Should -Be 'unknown'
            ($results | Where-Object id -eq 'recipient.receipt').actual.state | Should -Be 'unknown'
            Should -Invoke Invoke-HealthArmGet -Times 5 -Exactly
        }
    }

    It 'reports successful runs without converting them into recipient receipt' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun {
                [pscustomobject]@{ name="run-$WorkflowName"; properties=[pscustomobject]@{ status='Succeeded'; startTime='2026-10-13T00:00:00Z' } }
            }
            $workflow = Get-HealthWorkflowRunOutcome
            $receipt = Get-HealthRecipientReceiptOutcome
            $workflow.status | Should -Be 'pass'
            $receipt.status | Should -Be 'warning'
            $receipt.actual.state | Should -Be 'unknown'
            $receipt.actual.inferredFromWorkflowRun | Should -BeFalse
            $receipt.actual.inferredFromConnection | Should -BeFalse
        }
    }

    It 'fails a failed workflow and leaves receipt unknown' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun {
                $status = if ($WorkflowName -eq 'alert') { 'Failed' } else { 'Succeeded' }
                [pscustomobject]@{ name="run-$WorkflowName"; properties=[pscustomobject]@{ status=$status; startTime='2026-10-13T00:00:00Z' } }
            }
            (Get-HealthWorkflowRunOutcome).status | Should -Be 'fail'
            (Get-HealthRecipientReceiptOutcome).actual.state | Should -Be 'unknown'
        }
    }

    It 'reports missing runs as incomplete rather than receipt failure or success' {
        InModuleScope Health.Validation {
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle' } }
            Mock Get-HealthLatestWorkflowRun { $null }
            $result = Get-HealthWorkflowRunOutcome
            $result.status | Should -Be 'warning'
            $result.actual.runs.alert.state | Should -Be 'unknown'
            $result.actual.runs.lifecycle.state | Should -Be 'unknown'
        }
    }

    It 'bounds malformed provider primitives without persisting raw values or reporting pass' {
        InModuleScope Health.Validation {
            $secretLike = 'https://example.invalid/callback?sig=' + ('s' * 200000)
            Mock Get-HealthValidationContext { [pscustomobject]@{ alertWorkflow='alert'; lifecycleWorkflow='lifecycle'; teamsConnection='teams' } }
            Mock Invoke-HealthArmGet {
                [pscustomobject]@{ properties=[pscustomobject]@{ statuses=@([pscustomobject]@{ status=$secretLike }) } }
            } -ParameterFilter { $Endpoint -eq 'connection' }
            Mock Get-HealthLatestWorkflowRun {
                [pscustomobject]@{
                    name=$secretLike
                    properties=[pscustomobject]@{ status=@('Succeeded'); startTime="2026-10-13T00:00:00Z`n$secretLike" }
                }
            }

            $connection = Get-HealthConnectionReadinessOutcome
            $workflow = Get-HealthWorkflowRunOutcome
            $serialized = @($connection, $workflow) | ConvertTo-Json -Depth 20

            $connection.status | Should -Be 'fail'
            $connection.actual.providerStatus | Should -Be 'Unknown'
            $workflow.status | Should -Be 'warning'
            $workflow.actual.runs.alert.state | Should -Be 'unknown'
            $workflow.actual.runs.lifecycle.state | Should -Be 'unknown'
            $serialized.Length | Should -BeLessThan 4000
            $serialized | Should -Not -Match 'example\.invalid|sig=|ssssssssssssssss'
        }
    }
}

Describe 'HEALTH-005 source authority boundaries' {
    It 'uses only read-only ARM requests and retains solution-owned beta connector workflows' {
        $root = Split-Path -Parent $PSScriptRoot
        $module = Get-Content -LiteralPath (Join-Path $root 'scripts/Health.Validation.psm1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $root 'infra/workflow-definition.json') -Raw
        $lifecycle = Get-Content -LiteralPath (Join-Path $root 'infra/lifecycle-workflow-definition.json') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw

        $module | Should -Match 'Invoke-RestMethod -Method Get'
        $module | Should -Not -Match 'Invoke-RestMethod -Method (Post|Put|Patch|Delete)'
        $workflow | Should -Match 'Microsoft Graph beta health alerts|graph.microsoft.com/beta'
        $lifecycle | Should -Match 'graph.microsoft.com/beta/subscriptions'
        $readme | Should -Match 'Microsoft Graph `/beta`'
    }

    It 'records optional existing-resource reads without adding Graph permission or grants' {
        $root = Split-Path -Parent $PSScriptRoot
        $permissions = Get-Content -LiteralPath (Join-Path $root 'azd-permissions.json') -Raw | ConvertFrom-Json -Depth 30
        $validation = @($permissions.requirements | Where-Object feature -eq 'operator-validation')
        $moduleHash = (Get-FileHash -LiteralPath (Join-Path $root 'scripts/Health.Validation.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()

        $validation.Count | Should -Be 2
        @($validation | Where-Object defaultEnabled).Count | Should -Be 0
        ($validation.permission -join ';') | Should -Not -Match 'Graph|write|action$'
        foreach ($requirement in $validation) {
            $requirement.principal | Should -Be 'Selected Azure CLI validation operator'
            $requirement.phase | Should -Be 'discovery'
            $requirement.evidence[0].sha256 | Should -Be $moduleHash
        }
        foreach ($requirement in @($permissions.requirements | Where-Object evidenceState -eq 'code')) {
            foreach ($evidence in @($requirement.evidence)) {
                (Get-FileHash -LiteralPath (Join-Path $root $evidence.path) -Algorithm SHA256).Hash.ToLowerInvariant() |
                    Should -Be $evidence.sha256
            }
        }
    }

    It 'guards the registered workflow with 64-bit PowerShell 7.6.6 before validation' {
        $root = Split-Path -Parent $PSScriptRoot
        $workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/validate.yml') -Raw
        $guard = $workflow.IndexOf("`$PSVersionTable.PSVersion -ne [version]'7.6.6'", [StringComparison]::Ordinal)
        $validation = $workflow.IndexOf('./scripts/Test-Repository.ps1', [StringComparison]::Ordinal)

        $guard | Should -BeGreaterThan -1
        $workflow | Should -Match '\[Environment\]::Is64BitProcess'
        $validation | Should -BeGreaterThan $guard
    }
}
