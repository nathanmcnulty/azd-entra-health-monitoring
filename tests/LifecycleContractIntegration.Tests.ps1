# These records MODEL lifecycle observations; they do not execute Logic Apps.
BeforeAll {
    $script:contractRepo = Split-Path $PSScriptRoot -Parent
    $script:contractVendor = Join-Path $script:contractRepo 'scripts/vendor/Azd.LifecycleQualification'
    Import-Module (Join-Path $script:contractRepo 'scripts/Health.LifecycleFixture.psm1') -Force
    Import-Module (Join-Path $script:contractVendor 'Azd.LifecycleQualification.psd1') -Force

    function Write-ContractJson([string]$Path, $Value) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 40 -Compress))
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        try { $stream.Write($bytes) } finally { $stream.Dispose() }
        return $Path
    }
    function Get-ContractSha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

    function New-HealthContractFixture([string]$Teardown = 'succeeded', [string]$PayloadStatus = 'pass') {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $plan = Get-HealthFixturePlan -RepositoryRoot $script:contractRepo
        $generated = Join-Path $root 'generated'
        Export-HealthLogicFixture -Plan $plan -OutputDirectory $generated | Out-Null
        $manifestPath = Join-Path $generated 'manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        foreach ($entry in $manifest.generatedFiles.GetEnumerator()) {
            (Get-ContractSha (Join-Path $generated $entry.Key)) | Should -BeExactly $entry.Value.ToLowerInvariant()
        }
        $files = [ordered]@{
            profile = Join-Path $script:contractVendor 'profiles/health-logic-fixture.v1.json'
            target = Write-ContractJson (Join-Path $root 'target.json') @{ kind = 'synthetic-local-model'; ownedBoundary = 'fixture-only' }
            source = Write-ContractJson (Join-Path $root 'source.json') @{ transformationInputCommit = $plan.SourceCommit; checkout = $plan.SourceCheckoutHead; workflowHashes = $plan.SourceHashes }
            orchestration = Join-Path $PSScriptRoot 'LifecycleContractIntegration.Tests.ps1'
            lock = Join-Path $script:contractRepo 'azd-components.lock.json'
            artifact = $manifestPath
            configuration = Write-ContractJson (Join-Path $root 'configuration.json') @{ adapterProfileSha256 = $plan.ProfileSha256; generatedConfigurationSha256 = $manifest.generatedConfigurationSha256 }
        }
        $bindings = [ordered]@{
            reviewedSourceCommit = $plan.SourceCheckoutHead
            testedSourceCommit = $plan.SourceCheckoutHead
            orchestrationCommit = $plan.SourceCheckoutHead
        }
        $expected = [ordered]@{}
        foreach ($key in $bindings.Keys) { $expected[$key] = $bindings[$key] }
        foreach ($role in @('target','source','orchestration','lock','artifact','configuration')) {
            $bindings["${role}Sha256"] = Get-ContractSha $files[$role]
            $expected["${role}Sha256"] = $bindings["${role}Sha256"]
        }
        $expected.profileSha256 = Get-ContractSha $files.profile
        $attempt = [guid]::NewGuid().ToString('D')
        $createdAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).UtcDateTime.ToString('o')
        $evidenceBinding = [ordered]@{
            attemptId = $attempt; targetSha256 = $bindings.targetSha256; sourceSha256 = $bindings.sourceSha256
            profileSha256 = $expected.profileSha256; configurationSha256 = $bindings.configurationSha256
        }
        $caseResults = @($manifest.caseAccounting | ForEach-Object {
            [ordered]@{
                caseId = $_.caseId; runStatus = 'pass'; outerTriggerInvocations = $_.outerTriggerInvocations
                nestedStubTriggerInvocations = $_.nestedStubTriggerInvocations; configuredRetryAttempts = $_.configuredRetryAttempts
                billableActionActivations = $_.worstCaseActionActivations; inputBytes = $_.outerInputBytes
                nestedStubPayloadBytes = ($_.nestedStubRequestBytes + $_.nestedStubResponseBytes); logBytes = 0
            }
        })
        $stages = @(foreach ($id in Get-AzdLifecycleRequiredStage) {
            $status = if ($id -eq 'payload-readback') { $PayloadStatus } else { 'pass' }
            $doc = [ordered]@{ schemaVersion = '0.1'; evidenceType = 'azdLifecycleStageEvidence'; stageId = $id; status = $status; attemptId = $attempt; binding = $evidenceBinding }
            if ($id -eq 'intended-function') { $doc.profileCaseResults = $caseResults }
            if ($id -eq 'teardown-operation') {
                $doc.operationFacts = [ordered]@{
                    operationOutcome = $Teardown; dispatchCount = 1; retryCount = 0; processExited = $true
                    processExitCode = if ($Teardown -eq 'succeeded') { 0 } else { 1 }
                    transportAttemptCount = 1; responseReceived = ($Teardown -eq 'succeeded')
                    responseStatus = if ($Teardown -eq 'succeeded') { 202 } else { $null }
                }
            }
            if ($id -eq 'terminal-state') {
                $doc.terminalFacts = [ordered]@{ state = 'absent'; observationCompleted = $true; observedAt = $createdAt }
            }
            $name = "stage-$id.json"
            $path = Write-ContractJson (Join-Path $root $name) $doc
            $stage = [ordered]@{ stageId = $id; status = $status; evidence = [ordered]@{ path = $name; sha256 = Get-ContractSha $path; binding = $evidenceBinding } }
            if ($id -eq 'teardown-operation') {
                $stage.operationOutcome = $Teardown; $stage.absenceObserved = $true
                $stage.processExitCode = if ($Teardown -eq 'succeeded') { 0 } else { 1 }
                $stage.processExited = $true; $stage.recoveryEvidence = ($Teardown -ne 'succeeded')
                $stage.retryCount = 0; $stage.deleteAttemptCount = 1
            }
            $stage
        })
        $envelope = [ordered]@{
            schemaVersion = '0.1'; envelopeType = 'azdLifecycleQualification'; evaluationMode = 'synthetic'; attemptId = $attempt
            createdAt = $createdAt
            admission = @{ expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).UtcDateTime.ToString('o'); reuseKey = "health-logic-fixture:$attempt"; dataOnly = $true }
            profile = @{ id = 'health-logic-fixture'; version = '1.0.0'; profileSha256 = $expected.profileSha256; executableHooks = $false }
            bindings = $bindings; attemptHistory = @(); stages = $stages
        }
        $envelopePath = Write-ContractJson (Join-Path $root 'envelope.json') $envelope
        [pscustomobject]@{ Root = $root; EnvelopePath = $envelopePath; Files = $files; Expected = $expected; Manifest = $manifest }
    }
    function Invoke-HealthContractFixture($Fixture) {
        Test-AzdLifecycleEnvelope -EnvelopePath $Fixture.EnvelopePath -EvidenceRoot $Fixture.Root -ExpectedBindings $Fixture.Expected -BindingFiles $Fixture.Files
    }
}

Describe 'Health offline adapter to lifecycle contract to synthetic projection' {
    It 'models all seven stages with actual local artifact bindings and no native or publication authority' {
        $fixture = New-HealthContractFixture
        $result = Invoke-HealthContractFixture $fixture
        $result.syntheticOutcome | Should -BeExactly 'passed'
        $fixture.Manifest.budget.inclusiveTriggerTotal | Should -Be 5
        $fixture.Manifest.budget.worstCaseBillableActionActivations | Should -Be 32
        $projection = New-AzdLifecyclePublicProjection -Evaluation $result
        $projection.nativeLifecycleQualified | Should -BeFalse
        $projection.executionAllowed | Should -BeFalse
        $projection.publicationAuthorized | Should -BeFalse
        ($projection | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $script:contractVendor 'lifecycle-public-projection.schema.json') -ErrorAction Stop) | Should -BeTrue
        ($projection | ConvertTo-Json -Depth 20) | Should -Not -Match 'fixture-only|targetSha256|stage-.*\.json|configurationSha256|callback'
    }
    It 'keeps unknown DELETE followed by absence failed through projection' {
        $result = Invoke-HealthContractFixture (New-HealthContractFixture -Teardown unknown)
        $result.syntheticOutcome | Should -BeExactly 'failed'
        $result.recoveryEvidenceObserved | Should -BeTrue
        (New-AzdLifecyclePublicProjection -Evaluation $result).syntheticOutcome | Should -BeExactly 'failed'
    }
    It 'keeps missing payload observation non-passing' {
        (Invoke-HealthContractFixture (New-HealthContractFixture -PayloadStatus unknown)).syntheticOutcome | Should -BeExactly 'failed'
    }
    It 'maps a legacy warning with the self-contained vendored schema and never qualifies it' {
        $report = [ordered]@{
            schemaVersion = '1.0'; reportType = 'azdDeploymentValidation'
            startedAt = '2026-01-01T00:00:00Z'; completedAt = '2026-01-01T00:00:01Z'; durationMs = 1000
            template = @{ name = 'fixture'; version = '1.0' }; mode = 'verify'
            requirements = @{ tools = @(); modules = @(); permissions = @() }
            outcome = 'passedWithWarnings'; summary = @{ pass = 0; fail = 0; warning = 1; info = 0; skipped = 0; planned = 0 }
            nextSteps = @(); checks = @(
                @{ id = 'legacy-warning'; phase = 'context'; title = 'Fixture'; status = 'warning'; summary = 'review'; evidence = @{}; durationMs = 0; sideEffect = 'none' }
            )
        }
        $reportPath = Join-Path $TestDrive ('legacy-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($reportPath, (ConvertTo-Json $report -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
        $mapped = ConvertFrom-AzdLifecycleLegacyReport -ReportPath $reportPath -StageMap @{ ownership = @('legacy-warning') }
        $mapped.qualification | Should -BeExactly 'not-established'
        ($mapped.explicitStageMapping | Where-Object stageId -eq ownership).status | Should -BeExactly 'warning'
        $mapped.nativeLifecycleQualified | Should -BeFalse
        $mapped.executionAllowed | Should -BeFalse
    }

    It 'renders a disabled plan whose successful wrapper exit is only a plan' {
        $raw = & (Join-Path $script:contractRepo 'scripts/Get-LifecycleQualificationPlan.ps1')
        $plan = $raw | ConvertFrom-Json
        $plan.syntheticOutcome | Should -BeExactly 'planned'
        $plan.nativeLifecycleQualified | Should -BeFalse
        $plan.executionAllowed | Should -BeFalse
        ($raw | Test-Json -SchemaFile (Join-Path $script:contractVendor 'lifecycle-plan.schema.json') -ErrorAction Stop) | Should -BeTrue
    }
}
