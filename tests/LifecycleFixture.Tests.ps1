BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scripts/Health.LifecycleFixture.psm1') -Force
    $profilePath = Join-Path $repoRoot 'validation/profiles/health-logic-fixture.v1.json'
}

Describe 'Health M1 local fixture profile and source gates' {
    It 'plans exactly three source-bound cases with inclusive trigger accounting' {
        $plan = Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $profilePath
        $plan.Cases.Count | Should -Be 3
        $plan.InclusiveTriggerCount | Should -Be 5
        $plan.SourceCommit | Should -BeExactly '4d3273335aed8f59dc4df2151f28e8694dced7d9'
        $plan.Cases.Where({$_.id -eq 'lifecycle-create'}).expected.fixtureStubTriggers | Should -Be 2
    }

    It 'rejects a case-insensitive duplicate profile property' {
        $raw = [IO.File]::ReadAllText($profilePath)
        $bad = $raw.Replace('"schemaVersion": 1,', '"schemaVersion": 1, "SCHEMAVERSION": 1,')
        $path = Join-Path $TestDrive 'duplicate-profile.json'
        [IO.File]::WriteAllText($path,$bad,[Text.UTF8Encoding]::new($false))
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path } | Should -Throw '*Duplicate JSON property*'
    }

    It 'rejects reordered cases and array-shaped profile identity or source pins' {
        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $first = $doc.cases[0]; $doc.cases[0] = $doc.cases[1]; $doc.cases[1] = $first
        $path = Join-Path $TestDrive 'reordered-cases.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path } | Should -Throw '*case order*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.profileId = @('health-logic-fixture')
        $path2 = Join-Path $TestDrive 'array-profile-id.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path2
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path2 } | Should -Throw '*identity*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.sourceCommit = @('4d3273335aed8f59dc4df2151f28e8694dced7d9')
        $path3 = Join-Path $TestDrive 'array-source-commit.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path3
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path3 } | Should -Throw '*identity*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.sourceFiles['infra/workflow-definition.json'] = @('AAD1248D010DB7C134C27E4A8BDADE28C9B8AA1DDFF764FACFAF8F35186F923D')
        $path4 = Join-Path $TestDrive 'array-source-hash.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path4
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path4 } | Should -Throw '*source pin*'
    }

    It 'rejects unknown profile properties and over-budget retry attempts' {
        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc['unknownField'] = $true
        $path = Join-Path $TestDrive 'unknown-profile.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path } | Should -Throw '*Unknown or missing profile property*'

        { Test-HealthFixtureTriggerBudget -OuterTriggerInvocations 3 -NestedStubTriggerInvocations 2 -ConfiguredRetryAttempts 16 -Limit 20 } | Should -Throw '*budget exceeded*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.budgets['unreviewedLimit'] = 1
        $path2 = Join-Path $TestDrive 'unknown-budget.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path2
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path2 } | Should -Throw '*Closed budget property set*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.cases[0].expected['unexpectedClaim'] = $true
        $path3 = Join-Path $TestDrive 'unknown-expectation.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path3
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path3 } | Should -Throw '*Closed expected-result shape*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.cases[2].source = 'infra/workflow-definition.json'
        $path4 = Join-Path $TestDrive 'wrong-source-mapping.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path4
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path4 } | Should -Throw '*Source mapping mismatch*'

        $doc = Get-Content -Raw $profilePath | ConvertFrom-Json -AsHashtable
        $doc.cases[0].fixtureInput.value[0].resourceData.id = 'fixture-other-alert'
        $path5 = Join-Path $TestDrive 'wrong-fixture-input.json'
        $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path5
        { Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $path5 } | Should -Throw '*Fixture input/oracle mismatch*'
    }

    It 'rejects pinned source drift before planning' {
        $tempRepo = Join-Path $TestDrive 'source-drift'
        New-Item -ItemType Directory -Path (Join-Path $tempRepo 'infra') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tempRepo 'infra/workflow-definition.json'),'tampered')
        [IO.File]::WriteAllText((Join-Path $tempRepo 'infra/lifecycle-workflow-definition.json'),'tampered')
        $pins = [ordered]@{
            'infra/workflow-definition.json' = 'AAD1248D010DB7C134C27E4A8BDADE28C9B8AA1DDFF764FACFAF8F35186F923D'
            'infra/lifecycle-workflow-definition.json' = '2E154EE1DA0F33DA7018DC6FC486872CBFCBBFDC5D0BA01FAC9DBB6C1F7F21CF'
        }
        { Test-HealthFixtureSourcePins -RepositoryRoot $tempRepo -SourceFiles $pins } | Should -Throw '*source drift*'
    }

    It 'exports only local deterministic artifacts with no provider connection or literal callback' {
        $plan = Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $profilePath
        $out = Join-Path $TestDrive 'export-once'
        $result = Export-HealthLogicFixture -Plan $plan -OutputDirectory $out
        $result.localOnly | Should -BeTrue
        $result.inclusiveTriggerTotal | Should -Be 5
        $manifest = Get-Content -Raw (Join-Path $out 'manifest.json') | ConvertFrom-Json -AsHashtable
        $manifest.dependencies.Graph | Should -BeFalse
        $manifest.dependencies.Teams | Should -BeFalse
        $manifest.budget.worstCaseBillableActionActivations | Should -Be 32
        $manifest.budget.maxAggregatePayloadBytes | Should -Be 10485760
        $manifest.caseAccounting.Where({$_.caseId -eq 'lifecycle-create'}).nestedStubTriggerInvocations | Should -Be 2
        $definition = Get-Content -Raw (Join-Path $out 'cases/lifecycle-create/definition.json')
        $definition | Should -Not -Match "parameters\('NotificationUrl'\)"
        $definition | Should -Match "parameters\('FixtureStubCallback'\)"
        $definition | Should -Not -Match 'https?://(?!schema\.management\.azure\.com)'
        $lifecycleDefinition = $definition | ConvertFrom-Json -AsHashtable
        $listAction = $lifecycleDefinition.actions.List_subscriptions
        $listAction.inputs.retryPolicy.type | Should -BeExactly 'none'
        $listAction.Contains('retryPolicy') | Should -BeFalse
        $createAction = $lifecycleDefinition.actions.Check_existing_subscription.actions.Create_subscription
        $createAction.inputs.retryPolicy.type | Should -BeExactly 'none'
        $createAction.Contains('retryPolicy') | Should -BeFalse
        $createAction.inputs.uri | Should -BeExactly "@parameters('FixtureStubCallback')"
        $filter = $lifecycleDefinition.actions.Filter_callback_subscriptions
        $filter.inputs.from | Should -BeExactly "@body('List_subscriptions')?['value']"
        $filter.inputs.where | Should -Match "parameters\('FixtureStubCallback'\)"
        $filter.runAfter.List_subscriptions | Should -HaveCount 1
        $filter.runAfter.List_subscriptions -is [array] | Should -BeTrue
        $stubValues = $listAction.inputs.body.fixtureReply.body.value
        ($stubValues -is [array]) | Should -BeTrue
        $stubValues.Count | Should -Be 0
        $receiverDefinition = Get-Content -Raw (Join-Path $out 'cases/receiver-duplicate-batch/definition.json')
        $receiverDefinition | Should -Match "outputs\('Get_alert_details'\)"
        $receiverDefinition | Should -Not -Match "body\('Get_alert_details'\)"
        $receiverDuplicate = Get-Content -Raw (Join-Path $out 'cases/receiver-duplicate-batch/configuration.json') | ConvertFrom-Json -AsHashtable
        $receiverDuplicate.fixtureInput.value | Should -HaveCount 2
        $receiverDefinition = Get-Content -Raw (Join-Path $out 'cases/receiver-duplicate-batch/definition.json') | ConvertFrom-Json -AsHashtable
        $receiverDefinition.parameters.Keys | Should -HaveCount 2
        $receiverDefinition.parameters.Contains('GraphSubscriptionClientState') | Should -BeTrue
        $receiverDefinition.parameters.Contains('TargetTeamId') | Should -BeFalse
        $receiverDefinition.parameters.Contains('TargetChannelDisplayName') | Should -BeTrue
        $receiverConfig = $receiverDuplicate
        $receiverConfig.workflowParameters.GraphSubscriptionClientState | Should -BeExactly 'fixture-client-state'
        $receiverConfig.workflowParameters.TargetChannelDisplayName | Should -BeExactly 'Fixture Channel'
        $receiverMismatch = Get-Content -Raw (Join-Path $out 'cases/receiver-mismatched-state/configuration.json') | ConvertFrom-Json -AsHashtable
        $receiverMismatch.fixtureInput.value | Should -HaveCount 1
        $lifecycleConfig = Get-Content -Raw (Join-Path $out 'cases/lifecycle-create/configuration.json') | ConvertFrom-Json -AsHashtable
        $lifecycleConfig.workflowParameters.GraphSubscriptionClientState | Should -BeExactly 'fixture-client-state'
        $lifecycleConfig.fixtureStubCallback.materialized | Should -BeFalse
        $lifecycleConfig.fixtureStubCallback.Contains('value') | Should -BeFalse
        $lifecycleDefinition.parameters.Keys | Should -HaveCount 2
        $lifecycleDefinition.parameters.Contains('NotificationUrl') | Should -BeFalse

        foreach ($caseId in @('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create')) {
            $caseRoot = Join-Path $out "cases/$caseId"
            $generated = Get-Content -Raw (Join-Path $caseRoot 'definition.json') | ConvertFrom-Json -AsHashtable
            $configuration = Get-Content -Raw (Join-Path $caseRoot 'configuration.json') | ConvertFrom-Json -AsHashtable
            $references = [regex]::Matches((Get-Content -Raw (Join-Path $caseRoot 'definition.json')), "(?i)parameters\('([^']+)'\)") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            foreach ($reference in $references) { $generated.parameters.Contains($reference) | Should -BeTrue }
            foreach ($declared in $generated.parameters.Keys) {
                if ($caseId -eq 'lifecycle-create' -and $declared -eq 'FixtureStubCallback') { continue }
                $configuration.workflowParameters.Contains($declared) | Should -BeTrue
            }
            foreach ($configured in $configuration.workflowParameters.Keys) { $generated.parameters.Contains($configured) | Should -BeTrue }
        }
        { Export-HealthLogicFixture -Plan $plan -OutputDirectory $out } | Should -Throw '*new; fixture export is CreateNew only*'
    }
}

Describe 'Health M1 lifecycle outcome and activity ledger' {
    It 'does not turn observed absence after an unknown delete into qualification' {
        $r = Resolve-HealthFixtureLifecycleOutcome -DeleteOperationOutcome unknown -AbsenceObserved $true -ProcessExitCode 1
        $r.recoveryObservation | Should -BeExactly 'absence-observed'
        $r.qualification | Should -BeExactly 'incomplete'
    }

    It 'keeps nonzero teardown and no-op cleanup incomplete despite absence' {
        (Resolve-HealthFixtureLifecycleOutcome -DeleteOperationOutcome failed -AbsenceObserved $true -ProcessExitCode 1).qualification | Should -BeExactly 'incomplete'
        (Resolve-HealthFixtureLifecycleOutcome -DeleteOperationOutcome not-attempted -AbsenceObserved $true -ProcessExitCode 0).qualification | Should -BeExactly 'incomplete'
    }

    It 'counts nested and retry invocations and refuses duplicate events or exceeded caps' {
        $plan = Get-HealthFixturePlan -RepositoryRoot $repoRoot -ProfilePath $profilePath
        $ledger = New-HealthFixtureLedger -Plan $plan
        Add-HealthFixtureActivity -Ledger $ledger -EventId outer-1 -Category outer-trigger -Amount 1 | Out-Null
        Add-HealthFixtureActivity -Ledger $ledger -EventId nested-1 -Category nested-stub-trigger -Amount 1 | Out-Null
        Add-HealthFixtureActivity -Ledger $ledger -EventId retry-1 -Category retry-attempt -Amount 1 -OperationId create -Attempt 1 | Out-Null
        $ledger.TriggerCount | Should -Be 3
        { Add-HealthFixtureActivity -Ledger $ledger -EventId outer-1 -Category outer-trigger -Amount 1 } | Should -Throw '*Duplicate activity event*'
        $ledger.TriggerCount = 20
        { Add-HealthFixtureActivity -Ledger $ledger -EventId retry-2 -Category retry-attempt -Amount 1 -OperationId create -Attempt 2 } | Should -Throw '*budget exceeded*'
    }
}
