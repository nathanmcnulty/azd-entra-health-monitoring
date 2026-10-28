Set-StrictMode -Version Latest

$script:RequiredStages = @(
    'target-context', 'ownership', 'deployment', 'payload-readback',
    'intended-function', 'teardown-operation', 'terminal-state'
)
$script:EnvelopeKeys = @('schemaVersion', 'envelopeType', 'evaluationMode', 'attemptId', 'createdAt', 'admission', 'profile', 'bindings', 'attemptHistory', 'stages')
$script:BindingKeys = @('reviewedSourceCommit', 'testedSourceCommit', 'orchestrationCommit', 'targetSha256', 'sourceSha256', 'orchestrationSha256', 'lockSha256', 'artifactSha256', 'configurationSha256')
$script:ExpectedBindingKeys = @('reviewedSourceCommit', 'testedSourceCommit', 'orchestrationCommit', 'targetSha256', 'sourceSha256', 'orchestrationSha256', 'lockSha256', 'artifactSha256', 'configurationSha256', 'profileSha256')
$script:EvidenceBindingKeys = @('attemptId', 'targetSha256', 'sourceSha256', 'profileSha256', 'configurationSha256')
$script:HexSha256 = '^[0-9a-f]{64}$'
$script:SchemaRoots = @(
    [IO.Path]::GetFullPath($PSScriptRoot),
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\schemas'))
)

function Assert-LQExactKey {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Value, [Parameter(Mandatory)][string[]] $Allowed, [Parameter(Mandatory)][string[]] $Required, [Parameter(Mandatory)][string] $Context)
    foreach ($key in $Value.Keys) {
        if ($key -isnot [string] -or $key -cnotin $Allowed) { throw "$Context contains an unknown property." }
    }
    foreach ($key in $Required) {
        if (-not $Value.Contains($key)) { throw "$Context is missing a required property." }
    }
}

function Assert-LQOrdinaryPath {
    param([Parameter(Mandatory)][string] $Path, [switch] $Directory)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $cursor = $root
    $relative = [IO.Path]::GetRelativePath($root, $fullPath)
    $parts = $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)
    for ($index = 0; $index -lt $parts.Length; $index++) {
        $cursor = Join-Path $cursor $parts[$index]
        $item = Get-Item -LiteralPath $cursor -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Input path cannot traverse a reparse point.' }
        if ($index -lt ($parts.Length - 1) -and -not $item.PSIsContainer) { throw 'Input path has a non-directory parent.' }
    }
    $last = Get-Item -LiteralPath $fullPath -ErrorAction Stop
    if ($Directory -and -not $last.PSIsContainer) { throw 'Expected an ordinary directory.' }
    if (-not $Directory -and $last.PSIsContainer) { throw 'Expected an ordinary file.' }
    return $fullPath
}

function Assert-LQNoDuplicateJsonKey {
    param([Parameter(Mandatory)][string] $Json)
    $document = [System.Text.Json.JsonDocument]::Parse($Json, [System.Text.Json.JsonDocumentOptions]@{ MaxDepth = 32; CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow; AllowTrailingCommas = $false })
    try {
        $stack = [System.Collections.Generic.Stack[System.Text.Json.JsonElement]]::new()
        $stack.Push($document.RootElement)
        while ($stack.Count -gt 0) {
            $element = $stack.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $seen.Add($property.Name)) { throw 'JSON contains duplicate or case-colliding property names.' }
                    $stack.Push($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($child in $element.EnumerateArray()) { $stack.Push($child) }
            }
        }
    }
    finally { $document.Dispose() }
}

function Read-LQJsonFile {
    param([Parameter(Mandatory)][string] $Path, [int] $MaximumBytes = 1048576)
    $safePath = Assert-LQOrdinaryPath -Path $Path
    $bytes = Read-LQBoundedFile -Path $safePath -MaximumBytes $MaximumBytes
    if ($bytes.Length -lt 2) { throw 'JSON input length is outside the permitted bound.' }
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($bytes)
    Assert-LQNoDuplicateJsonKey -Json $text
    $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 32 -DateKind String -ErrorAction Stop
    if ($value -isnot [System.Collections.IDictionary]) { throw 'JSON root must be an object.' }
    [pscustomobject]@{ Value = $value; Text = $text; Bytes = $bytes; Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
}

function Read-LQBoundedFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][long] $MaximumBytes)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 0 -or $stream.Length -gt $MaximumBytes -or $stream.Length -gt [int]::MaxValue) { throw 'Input file length is outside the permitted bound.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'Input file changed or ended during its held read.' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) { throw 'Input file grew during its held read.' }
        return ,$bytes
    }
    finally { $stream.Dispose() }
}

function Assert-LQCanonicalSchema {
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][string] $SchemaName)
    $schemaPath = $null
    foreach ($schemaRoot in $script:SchemaRoots) {
        $candidate = Join-Path $schemaRoot $SchemaName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $schemaPath = $candidate; break }
    }
    if ($null -eq $schemaPath) { throw 'Canonical local schema is missing.' }
    $valid = Test-Json -Json $Text -SchemaFile $schemaPath -ErrorAction Stop
    if (-not $valid) { throw "Document does not satisfy canonical $SchemaName." }
}

function ConvertTo-LQCanonicalUtc {
    param([AllowNull()][object] $Value, [string] $Name)
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw "$Name must be canonical UTC with seven fractional digits." }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { throw "$Name is not a valid UTC timestamp." }
    return $parsed.ToUniversalTime()
}

function Assert-LQString {
    param([AllowNull()][object] $Value, [string] $Name, [int] $MaximumLength = 200)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength) { throw "$Name must be a non-empty bounded string." }
}

function Get-LQMemberValue {
    param([Parameter(Mandatory)][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw 'Expected object property is missing.' }
    return $property.Value
}

function Assert-LQSha {
    param([AllowNull()][object] $Value, [string] $Name)
    if ($Value -isnot [string] -or $Value -cnotmatch $script:HexSha256) { throw "$Name must be a lowercase SHA-256 digest." }
}

function Get-AzdLifecycleRequiredStage {
    [CmdletBinding()]
    param()
    return @($script:RequiredStages)
}

function New-AzdLifecyclePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProfileId,
        [Parameter(Mandatory)][string] $ProfileVersion,
        [Parameter(Mandatory)][string] $ProfileSha256
    )
    Assert-LQString $ProfileId 'ProfileId' 128
    Assert-LQString $ProfileVersion 'ProfileVersion' 32
    Assert-LQSha $ProfileSha256 'ProfileSha256'
    $plan = [pscustomobject][ordered]@{
        planVersion = '0.1'
        planType = 'azdLifecyclePlan'
        profile = [pscustomobject][ordered]@{ id = $ProfileId; version = $ProfileVersion; profileSha256 = $ProfileSha256 }
        requiredStages = @($script:RequiredStages)
        syntheticOutcome = 'planned'
        nativeLifecycleQualified = $false
        executionAllowed = $false
    }
    Assert-LQCanonicalSchema -Text (ConvertTo-Json -InputObject $plan -Depth 10 -Compress) -SchemaName 'lifecycle-plan.schema.json'
    return $plan
}

function Test-AzdLifecycleEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvelopePath,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary] $ExpectedBindings,
        [Parameter(Mandatory)][System.Collections.IDictionary] $BindingFiles
    )
    $evaluationStartedAt = [DateTimeOffset]::UtcNow
    $loaded = Read-LQJsonFile -Path $EnvelopePath
    $envelope = $loaded.Value
    Assert-LQCanonicalSchema -Text $loaded.Text -SchemaName 'lifecycle-qualification.schema.json'
    Assert-LQExactKey -Value $envelope -Allowed $script:EnvelopeKeys -Required $script:EnvelopeKeys -Context 'Envelope'
    if ($envelope.schemaVersion -cne '0.1' -or $envelope.envelopeType -cne 'azdLifecycleQualification' -or $envelope.evaluationMode -cne 'synthetic') { throw 'Envelope version, type, or evaluation mode is unsupported.' }
    $attemptGuid = [guid]::Empty
    if ($envelope.attemptId -isnot [string] -or -not [guid]::TryParseExact($envelope.attemptId, 'D', [ref]$attemptGuid) -or $attemptGuid -eq [guid]::Empty) { throw 'Envelope attemptId must be a non-empty UUID.' }
    $createdAt = ConvertTo-LQCanonicalUtc $envelope.createdAt 'Envelope createdAt'
    if ($createdAt -gt [DateTimeOffset]::UtcNow) { throw 'Attempt createdAt cannot be in the future.' }

    Assert-LQExactKey $envelope.admission @('expiresAt','reuseKey','dataOnly') @('expiresAt','reuseKey','dataOnly') 'Admission'
    $expiresAt = ConvertTo-LQCanonicalUtc $envelope.admission.expiresAt 'Admission expiresAt'
    if ($createdAt -gt $expiresAt) { throw 'Admission expiry predates this attempt.' }
    Assert-LQString $envelope.admission.reuseKey 'Admission reuseKey' 128
    if ($envelope.admission.dataOnly -isnot [bool] -or -not $envelope.admission.dataOnly) { throw 'Only data-only profiles are supported.' }

    Assert-LQExactKey $envelope.profile @('id','version','profileSha256','executableHooks') @('id','version','profileSha256','executableHooks') 'Profile'
    Assert-LQString $envelope.profile.id 'Profile id' 128
    if ($envelope.profile.version -isnot [string] -or $envelope.profile.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'Profile version is invalid.' }
    Assert-LQSha $envelope.profile.profileSha256 'Profile digest'
    if ($envelope.profile.executableHooks -isnot [bool] -or $envelope.profile.executableHooks) { throw 'Executable hooks are prohibited in M1 profiles.' }

    Assert-LQExactKey $envelope.bindings $script:BindingKeys $script:BindingKeys 'Bindings'
    foreach ($key in @('reviewedSourceCommit','testedSourceCommit','orchestrationCommit')) { if ($envelope.bindings[$key] -isnot [string] -or $envelope.bindings[$key] -cnotmatch '^[0-9a-f]{40}$') { throw "Binding $key must be a lowercase Git commit SHA." } }
    foreach ($key in $script:BindingKeys | Where-Object { $_ -notin @('reviewedSourceCommit','testedSourceCommit','orchestrationCommit') }) { Assert-LQSha $envelope.bindings[$key] "Binding $key" }
    Assert-LQExactKey $ExpectedBindings $script:ExpectedBindingKeys $script:ExpectedBindingKeys 'Expected bindings'
    Assert-LQExactKey $BindingFiles @('profile','target','source','orchestration','lock','artifact','configuration') @('profile','target','source','orchestration','lock','artifact','configuration') 'Binding files'
    foreach ($key in $script:ExpectedBindingKeys) {
        $actualValue = if ($key -eq 'profileSha256') { $envelope.profile.profileSha256 } else { $envelope.bindings[$key] }
        if ($ExpectedBindings[$key] -isnot [string] -or $ExpectedBindings[$key] -cne $actualValue) { throw "Envelope binding differs from externally supplied $key." }
    }
    $boundProfile = $null
    foreach ($role in $BindingFiles.Keys) {
        $path = $BindingFiles[$role]
        Assert-LQString $path "Binding file path $role" 1024
        $safeBindingPath = Assert-LQOrdinaryPath -Path $path
        $raw = Read-LQBoundedFile -Path $safeBindingPath -MaximumBytes 10485760
        $rawDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        $expectedDigest = if ($role -eq 'profile') { $envelope.profile.profileSha256 } else { $envelope.bindings["${role}Sha256"] }
        if ($rawDigest -cne $expectedDigest) { throw "Supplied $role file bytes do not match their bound digest." }
        if ($role -eq 'profile') {
            if ($raw.Length -gt 1048576) { throw 'Supplied profile exceeds its 1 MiB bound.' }
            $profileText = [System.Text.UTF8Encoding]::new($false, $true).GetString($raw)
            Assert-LQNoDuplicateJsonKey -Json $profileText
            Assert-LQCanonicalSchema -Text $profileText -SchemaName 'lifecycle-data-profile.schema.json'
            $boundProfile = ConvertFrom-Json -InputObject $profileText -AsHashtable -Depth 32 -DateKind String -ErrorAction Stop
            $profileKeys = @('schemaVersion','profileType','id','version','mode','selectedCaseIds','caseAccounting','maximumInclusiveTriggerInvocations','maximumCombinedRequestResponseBytes','maximumAggregateLogBytes','maximumAggregateBillableActions','countedSignals','dataOnly','executableHooks','providerCalls','proposalOnly','runtimeEnforced')
            Assert-LQExactKey $boundProfile $profileKeys $profileKeys 'Data profile'
            if ($boundProfile.schemaVersion -cne '0.1' -or $boundProfile.profileType -cne 'azdLifecycleDataProfile' -or $boundProfile.id -cne 'health-logic-fixture' -or $boundProfile.version -cne '1.0.0' -or $envelope.profile.id -cne $boundProfile.id -or $envelope.profile.version -cne $boundProfile.version) { throw 'Only the pinned M1 Health logic fixture profile is supported.' }
            if ($boundProfile.mode -cne 'synthetic-data-only' -or $boundProfile.maximumInclusiveTriggerInvocations -isnot [int] -and $boundProfile.maximumInclusiveTriggerInvocations -isnot [long] -or $boundProfile.maximumInclusiveTriggerInvocations -ne 20) { throw 'Health fixture trigger accounting policy is invalid.' }
            if ($boundProfile.maximumCombinedRequestResponseBytes -isnot [int] -and $boundProfile.maximumCombinedRequestResponseBytes -isnot [long] -or $boundProfile.maximumCombinedRequestResponseBytes -ne 10485760 -or $boundProfile.maximumAggregateLogBytes -isnot [int] -and $boundProfile.maximumAggregateLogBytes -isnot [long] -or $boundProfile.maximumAggregateLogBytes -ne 104857600 -or $boundProfile.maximumAggregateBillableActions -isnot [int] -and $boundProfile.maximumAggregateBillableActions -isnot [long] -or $boundProfile.maximumAggregateBillableActions -ne 40) { throw 'Health fixture aggregate payload, log, or action limits are invalid.' }
            if ($boundProfile.dataOnly -isnot [bool] -or -not $boundProfile.dataOnly -or $boundProfile.executableHooks -isnot [bool] -or $boundProfile.executableHooks -or $boundProfile.providerCalls -isnot [bool] -or $boundProfile.providerCalls -or $boundProfile.proposalOnly -isnot [bool] -or -not $boundProfile.proposalOnly -or $boundProfile.runtimeEnforced -isnot [bool] -or $boundProfile.runtimeEnforced) { throw 'Health profile must remain data-only, proposal-only, and non-executable.' }
            $expectedCases = @('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create')
            if ($boundProfile.selectedCaseIds -isnot [array] -or ($boundProfile.selectedCaseIds -join '|') -cne ($expectedCases -join '|') -or $boundProfile.countedSignals -isnot [array] -or ($boundProfile.countedSignals -join '|') -cne 'outerTriggerInvocations|nestedStubTriggerInvocations|configuredRetryAttempts') { throw 'Health fixture case selection or inclusive accounting signals are invalid.' }
            if ($boundProfile.caseAccounting -isnot [array] -or $boundProfile.caseAccounting.Count -ne 3) { throw 'Health fixture fixed case accounting is missing.' }
            $accountingIds = @('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create')
            $accountingValues = @(@(1,0,0,14), @(1,0,0,9), @(1,2,0,9))
            for ($caseIndex = 0; $caseIndex -lt $accountingIds.Count; $caseIndex++) {
                $accounting = $boundProfile.caseAccounting[$caseIndex]
                $accountingKeys = @('caseId','outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations')
                Assert-LQExactKey $accounting $accountingKeys $accountingKeys 'Profile case accounting'
                if ($accounting.caseId -cne $accountingIds[$caseIndex]) { throw 'Health profile case accounting order is invalid.' }
                for ($counterIndex = 0; $counterIndex -lt 4; $counterIndex++) {
                    $counterName = @('outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations')[$counterIndex]
                    if (($accounting[$counterName] -isnot [int] -and $accounting[$counterName] -isnot [long]) -or $accounting[$counterName] -ne $accountingValues[$caseIndex][$counterIndex]) { throw 'Health profile fixed case accounting values are invalid.' }
                }
            }
        }
    }
    if ($null -eq $boundProfile) { throw 'Bound Health data profile was not supplied.' }
    if ($envelope.attemptHistory -isnot [array] -or $envelope.attemptHistory.Count -gt 10) { throw 'Attempt history must be a bounded array.' }
    $seenAttempts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenReuseKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $previousCreatedAt = [DateTimeOffset]::MinValue
    [void]$seenAttempts.Add($envelope.attemptId)
    [void]$seenReuseKeys.Add($envelope.admission.reuseKey)
    foreach ($prior in $envelope.attemptHistory) {
        if ($prior -isnot [System.Collections.IDictionary]) { throw 'Attempt history entries must be objects.' }
        Assert-LQExactKey $prior @('attemptId','sourceSha256','outcome','reuseKey','createdAt') @('attemptId','sourceSha256','outcome','reuseKey','createdAt') 'Attempt history entry'
        $priorGuid = [guid]::Empty
        if ($prior.attemptId -isnot [string] -or -not [guid]::TryParseExact($prior.attemptId, 'D', [ref]$priorGuid) -or $priorGuid -eq [guid]::Empty -or -not $seenAttempts.Add($prior.attemptId)) { throw 'Attempt history contains an invalid or reused attempt id.' }
        Assert-LQSha $prior.sourceSha256 'Prior attempt source digest'
        Assert-LQString $prior.reuseKey 'Prior attempt reuseKey' 128
        if (-not $seenReuseKeys.Add($prior.reuseKey)) { throw 'Attempt history reuses an admission key.' }
        $priorCreated = ConvertTo-LQCanonicalUtc $prior.createdAt 'Prior attempt createdAt'
        if ($priorCreated -lt $previousCreatedAt -or $priorCreated -gt $createdAt) { throw 'Attempt history timestamps are not chronological.' }
        $previousCreatedAt = $priorCreated
        if ($prior.outcome -notin @('passed','failed','unknown','cancelled')) { throw 'Attempt history outcome is invalid.' }
        if ($prior.outcome -in @('unknown','cancelled')) { throw 'Unresolved prior attempts prevent a new qualifying attempt.' }
    }

    if ($envelope.stages -isnot [array] -or $envelope.stages.Count -ne 7) { throw 'Exactly seven lifecycle stages are required.' }
    $byStage = @{}
    $profileCaseSetPassed = $true
    $teardownFacts = $null
    $terminalFacts = $null
    $terminalObservedAt = $null
    foreach ($stage in $envelope.stages) {
        if ($stage -isnot [System.Collections.IDictionary]) { throw 'Stage entries must be objects.' }
        $allowedStageKeys = @('stageId','status','evidence','operationOutcome','absenceObserved','processExitCode','recoveryEvidence','retryCount','deleteAttemptCount','processExited')
        $requiredStageKeys = @('stageId','status','evidence')
        if ($stage.stageId -ceq 'teardown-operation') { $requiredStageKeys += @('operationOutcome','absenceObserved','processExitCode','recoveryEvidence','retryCount','deleteAttemptCount','processExited') }
        Assert-LQExactKey $stage $allowedStageKeys $requiredStageKeys 'Stage'
        if ($stage.stageId -isnot [string] -or $stage.stageId -cnotin $script:RequiredStages -or $byStage.ContainsKey($stage.stageId)) { throw 'Stage identifiers must be the exact unique required set.' }
        if ($stage.stageId -cne 'teardown-operation' -and @('operationOutcome','absenceObserved','processExitCode','recoveryEvidence','retryCount','deleteAttemptCount','processExited' | Where-Object { $stage.Contains($_) }).Count -gt 0) { throw 'Teardown summary fields are only valid on teardown-operation.' }
        if ($stage.status -isnot [string] -or $stage.status -cnotin @('pass','warning','fail','skipped','unknown','cancelled')) { throw 'Stage status is invalid.' }
        $byStage[$stage.stageId] = $stage
        if ($stage.evidence -isnot [System.Collections.IDictionary]) { throw 'Every stage requires a byte-bound evidence reference.' }
        Assert-LQExactKey $stage.evidence @('path','sha256','binding') @('path','sha256','binding') 'Evidence reference'
        Assert-LQString $stage.evidence.path 'Evidence path' 200
        if ($stage.evidence.path -match '(^|[\\/])\.\.([\\/]|$)' -or [IO.Path]::IsPathRooted($stage.evidence.path) -or $stage.evidence.path -match '[^A-Za-z0-9._/\\-]') { throw 'Evidence path must be a safe relative path.' }
        Assert-LQSha $stage.evidence.sha256 'Evidence digest'
        Assert-LQExactKey $stage.evidence.binding $script:EvidenceBindingKeys $script:EvidenceBindingKeys 'Evidence binding'
        $expectedEvidenceBinding = @{
            attemptId = $envelope.attemptId
            targetSha256 = $envelope.bindings.targetSha256
            sourceSha256 = $envelope.bindings.sourceSha256
            profileSha256 = $envelope.profile.profileSha256
            configurationSha256 = $envelope.bindings.configurationSha256
        }
        foreach ($key in $script:EvidenceBindingKeys) {
            if ($stage.evidence.binding[$key] -isnot [string] -or $stage.evidence.binding[$key] -cne $expectedEvidenceBinding[$key]) { throw "Evidence binding mismatch for $key." }
        }

        $root = Assert-LQOrdinaryPath -Path $EvidenceRoot -Directory
        if ((Get-Item -LiteralPath $EvidenceRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Evidence root cannot be a reparse point.' }
        $candidate = [IO.Path]::GetFullPath((Join-Path $root ($stage.evidence.path -replace '/', [IO.Path]::DirectorySeparatorChar)))
        $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence path escapes its root.' }
        $cursor = $root
        $relative = [IO.Path]::GetRelativePath($root, $candidate)
        foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar, [StringSplitOptions]::RemoveEmptyEntries)) {
            $cursor = Join-Path $cursor $part
            $item = Get-Item -LiteralPath $cursor -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Evidence path cannot traverse a reparse point.' }
        }
        $evidenceBytes = Read-LQBoundedFile -Path $candidate -MaximumBytes 1048576
        $actualDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($evidenceBytes)).ToLowerInvariant()
        if ($actualDigest -cne $stage.evidence.sha256) { throw 'Evidence byte digest mismatch.' }
        $evidenceText = [System.Text.UTF8Encoding]::new($false, $true).GetString($evidenceBytes)
        Assert-LQNoDuplicateJsonKey -Json $evidenceText
        $evidenceDocument = ConvertFrom-Json -InputObject $evidenceText -AsHashtable -Depth 16 -DateKind String -ErrorAction Stop
        if ($evidenceDocument -isnot [System.Collections.IDictionary]) { throw 'Evidence bytes must be a JSON object.' }
        $evidenceKeys = @('schemaVersion','evidenceType','stageId','status','attemptId','binding','profileCaseResults')
        $evidenceRequired = @('schemaVersion','evidenceType','stageId','status','attemptId','binding')
        if ($stage.stageId -ceq 'intended-function') { $evidenceRequired += 'profileCaseResults' }
        if ($stage.stageId -ceq 'teardown-operation') { $evidenceKeys += 'operationFacts'; $evidenceRequired += 'operationFacts' }
        if ($stage.stageId -ceq 'terminal-state') { $evidenceKeys += 'terminalFacts'; $evidenceRequired += 'terminalFacts' }
        Assert-LQExactKey $evidenceDocument $evidenceKeys $evidenceRequired 'Evidence document'
        if ($evidenceDocument.schemaVersion -cne '0.1' -or $evidenceDocument.evidenceType -cne 'azdLifecycleStageEvidence' -or $evidenceDocument.stageId -cne $stage.stageId -or $evidenceDocument.status -cne $stage.status -or $evidenceDocument.attemptId -cne $envelope.attemptId) { throw 'Evidence document does not bind to its stage and attempt.' }
        Assert-LQExactKey $evidenceDocument.binding $script:EvidenceBindingKeys $script:EvidenceBindingKeys 'Evidence document binding'
        foreach ($key in $script:EvidenceBindingKeys) { if ($evidenceDocument.binding[$key] -isnot [string] -or $evidenceDocument.binding[$key] -cne $expectedEvidenceBinding[$key]) { throw "Evidence byte binding mismatch for $key." } }
        Assert-LQCanonicalSchema -Text $evidenceText -SchemaName 'lifecycle-stage-evidence.schema.json'
        if ($stage.stageId -ceq 'teardown-operation') {
            $facts = $evidenceDocument.operationFacts
            Assert-LQExactKey $facts @('operationOutcome','dispatchCount','retryCount','processExited','processExitCode','transportAttemptCount','responseReceived','responseStatus') @('operationOutcome','dispatchCount','retryCount','processExited','processExitCode','transportAttemptCount','responseReceived','responseStatus') 'Operation facts'
            if ($facts.operationOutcome -isnot [string] -or $facts.operationOutcome -cne $stage.operationOutcome) { throw 'Teardown operation evidence does not match its typed envelope summary.' }
            foreach ($countName in @('dispatchCount','retryCount','processExitCode','transportAttemptCount')) { if ($facts[$countName] -isnot [int] -and $facts[$countName] -isnot [long]) { throw 'Teardown operation evidence has an invalid numeric field.' } }
            if ($facts.dispatchCount -ne $stage.deleteAttemptCount -or $facts.retryCount -ne $stage.retryCount -or $facts.transportAttemptCount -ne $stage.deleteAttemptCount -or $facts.processExited -isnot [bool] -or $facts.processExited -ne $stage.processExited -or $facts.processExitCode -ne $stage.processExitCode -or $facts.responseReceived -isnot [bool]) { throw 'Teardown operation evidence does not match its typed envelope summary.' }
            if ($facts.responseReceived -and ($facts.responseStatus -isnot [int] -and $facts.responseStatus -isnot [long] -or $facts.responseStatus -lt 100 -or $facts.responseStatus -gt 599)) { throw 'Teardown HTTP response status is invalid.' }
            if (-not $facts.responseReceived -and $null -ne $facts.responseStatus) { throw 'A missing teardown HTTP response cannot have a status.' }
            $teardownFacts = $facts
        }
        if ($stage.stageId -ceq 'terminal-state') {
            $facts = $evidenceDocument.terminalFacts
            Assert-LQExactKey $facts @('state','observationCompleted','observedAt') @('state','observationCompleted','observedAt') 'Terminal facts'
            if ($facts.state -isnot [string] -or $facts.state -cnotin @('absent','present','unknown') -or $facts.observationCompleted -isnot [bool]) { throw 'Terminal-state evidence is malformed.' }
            if ($facts.observationCompleted) { $terminalObservedAt = ConvertTo-LQCanonicalUtc $facts.observedAt 'Terminal observation time' }
            elseif ($null -ne $facts.observedAt) { throw 'An incomplete terminal observation cannot carry an observation time.' }
            $terminalFacts = $facts
        }
        if ($stage.stageId -ceq 'intended-function') {
            $caseIds = [System.Collections.Generic.List[string]]::new()
            $inclusiveTriggers = 0L
            $inclusiveActions = 0L
            $inclusiveInputBytes = 0L
            $inclusivePayloadBytes = 0L
            $inclusiveLogBytes = 0L
            if ($evidenceDocument.profileCaseResults -isnot [array] -or $evidenceDocument.profileCaseResults.Count -ne $boundProfile.selectedCaseIds.Count) { throw 'Intended-function evidence must account for every selected profile case.' }
            foreach ($case in $evidenceDocument.profileCaseResults) {
                $caseKeys = @('caseId','runStatus','outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations','inputBytes','nestedStubPayloadBytes','logBytes')
                Assert-LQExactKey $case $caseKeys $caseKeys 'Profile case evidence'
                if ($case.caseId -isnot [string] -or $case.caseId -cnotin $boundProfile.selectedCaseIds -or $case.runStatus -isnot [string] -or $case.runStatus -cnotin @('pass','warning','fail','skipped','unknown','cancelled')) { throw 'Profile case identity or status is invalid.' }
                if ($caseIds.Contains($case.caseId)) { throw 'Profile case evidence contains a duplicate case ID.' }
                $caseIds.Add($case.caseId)
                $expectedCase = @($boundProfile.caseAccounting | Where-Object { $_.caseId -ceq $case.caseId })
                if ($expectedCase.Count -ne 1) { throw 'Profile case has no unique fixed accounting rule.' }
                foreach ($counter in @('outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations')) {
                    if (($expectedCase[0][$counter] -isnot [int] -and $expectedCase[0][$counter] -isnot [long]) -or $case[$counter] -ne $expectedCase[0][$counter]) { throw "Profile case $counter does not match the fixed case accounting." }
                }
                foreach ($counter in @('outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations','inputBytes','nestedStubPayloadBytes','logBytes')) {
                    if (($case[$counter] -isnot [int] -and $case[$counter] -isnot [long]) -or $case[$counter] -lt 0) { throw "Profile case $counter must be a nonnegative integer." }
                }
                if ($case.outerTriggerInvocations -gt 20 -or $case.nestedStubTriggerInvocations -gt 20 -or $case.configuredRetryAttempts -gt 20 -or $case.billableActionActivations -gt 40 -or $case.inputBytes -gt 10485760 -or $case.nestedStubPayloadBytes -gt 10485760 -or $case.logBytes -gt 104857600) { throw 'Profile case evidence exceeds a v0.1 bound.' }
                $inclusiveTriggers += [long]$case.outerTriggerInvocations + [long]$case.nestedStubTriggerInvocations + [long]$case.configuredRetryAttempts
                $inclusiveActions += [long]$case.billableActionActivations
                $inclusiveInputBytes += [long]$case.inputBytes
                $inclusivePayloadBytes += [long]$case.nestedStubPayloadBytes
                $inclusiveLogBytes += [long]$case.logBytes
                if ($case.runStatus -cne 'pass') { $profileCaseSetPassed = $false }
            }
            if (($caseIds -join '|') -cne ($boundProfile.selectedCaseIds -join '|')) { throw 'Profile case evidence must match the selected case order exactly.' }
            $profileBudgetWithin = $inclusiveTriggers -le [long]$boundProfile.maximumInclusiveTriggerInvocations
            if ($inclusiveActions -gt [long]$boundProfile.maximumAggregateBillableActions -or ($inclusiveInputBytes + $inclusivePayloadBytes) -gt [long]$boundProfile.maximumCombinedRequestResponseBytes -or $inclusiveLogBytes -gt [long]$boundProfile.maximumAggregateLogBytes) { $profileBudgetWithin = $false }
            if (-not $profileBudgetWithin) { $profileCaseSetPassed = $false }
        }
    }
    foreach ($requiredStage in $script:RequiredStages) { if (-not $byStage.ContainsKey($requiredStage)) { throw 'A required lifecycle stage is missing.' } }
    if ($null -eq $teardownFacts -or $null -eq $terminalFacts) { throw 'Typed teardown and terminal-state evidence are required.' }
    if (($terminalFacts.state -ceq 'absent') -ne [bool]$byStage['teardown-operation'].absenceObserved) { throw 'Terminal-state absence does not match teardown summary.' }
    if ($byStage['teardown-operation'].absenceObserved -and $null -eq $terminalObservedAt) { throw 'Observed absence requires a canonical terminal observation time.' }
    if ($null -ne $terminalObservedAt -and ($terminalObservedAt -lt $createdAt -or $terminalObservedAt -gt $evaluationStartedAt)) { throw 'Terminal observation time must fall between the attempt and evaluation timestamps.' }

    $stageOutcomes = foreach ($requiredStage in $script:RequiredStages) {
        $item = $byStage[$requiredStage]
        $passed = $item.status -ceq 'pass'
        if ($requiredStage -ceq 'intended-function' -and -not $profileCaseSetPassed) { $passed = $false }
        if ($requiredStage -ceq 'terminal-state' -and (-not $terminalFacts.observationCompleted -or $terminalFacts.state -cne 'absent')) { $passed = $false }
        $recovery = $false
        if ($requiredStage -ceq 'teardown-operation') {
            if ($item.operationOutcome -notin @('succeeded','failed','unknown','notAttempted')) { throw 'Teardown operation outcome is invalid.' }
            if ($item.absenceObserved -isnot [bool] -or $item.recoveryEvidence -isnot [bool]) { throw 'Teardown observation flags must be Boolean.' }
            if ($item.processExitCode -isnot [int] -and $item.processExitCode -isnot [long]) { throw 'Teardown process exit code must be an integer.' }
            if ($item.processExited -isnot [bool]) { throw 'Teardown processExited must be Boolean.' }
            if ($item.retryCount -isnot [int] -and $item.retryCount -isnot [long]) { throw 'Teardown retryCount must be an integer.' }
            if ($item.retryCount -lt 0 -or $item.retryCount -gt 10) { throw 'Teardown retryCount is outside the bound.' }
            if ($item.deleteAttemptCount -isnot [int] -and $item.deleteAttemptCount -isnot [long]) { throw 'Teardown deleteAttemptCount must be an integer.' }
            if ($item.deleteAttemptCount -lt 0 -or $item.deleteAttemptCount -gt 1) { throw 'Teardown deleteAttemptCount is outside the bound.' }
            $recovery = $item.operationOutcome -in @('unknown','failed') -and $item.absenceObserved
            if ($item.recoveryEvidence -isnot [bool] -or $item.recoveryEvidence -ne $recovery) { throw 'Teardown recovery flag does not match operation and absence facts.' }
            if ($item.operationOutcome -ne 'succeeded' -or -not $item.processExited -or -not $item.absenceObserved -or $item.processExitCode -ne 0 -or $item.retryCount -ne 0 -or $item.deleteAttemptCount -ne 1 -or -not $teardownFacts.responseReceived -or $teardownFacts.responseStatus -notin @(200,202,204)) { $passed = $false }
        }
        $effectiveStatus = if (-not $passed -and $item.status -ceq 'pass') { 'fail' } else { [string]$item.status }
        if ($requiredStage -ceq 'teardown-operation') {
            [pscustomobject][ordered]@{ stageId = $requiredStage; status = $effectiveStatus; passed = [bool]$passed; recoveryEvidence = [bool]$recovery; operationOutcome = [string]$item.operationOutcome; absenceObserved = [bool]$item.absenceObserved; processExited = [bool]$item.processExited; processExitCode = [long]$item.processExitCode; retryCount = [long]$item.retryCount; deleteAttemptCount = [long]$item.deleteAttemptCount; responseReceived = [bool]$teardownFacts.responseReceived; responseStatus = $teardownFacts.responseStatus }
        } else {
            [pscustomobject][ordered]@{ stageId = $requiredStage; status = $effectiveStatus; passed = [bool]$passed; recoveryEvidence = [bool]$recovery }
        }
    }
    $overall = if (@($stageOutcomes | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' }
    $evidenceSetText = (@($script:RequiredStages | ForEach-Object { "${_}:$($byStage[$_].evidence.sha256)" }) -join "`n")
    $evidenceSetSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($evidenceSetText))).ToLowerInvariant()
    $evaluation = [pscustomobject][ordered]@{
        resultVersion = '0.1'
        resultType = 'azdLifecycleSyntheticEvaluation'
        attemptId = $envelope.attemptId
        attemptHistory = @($envelope.attemptHistory | ForEach-Object { [pscustomobject][ordered]@{ attemptId = $_.attemptId; sourceSha256 = $_.sourceSha256; outcome = $_.outcome; reuseKey = $_.reuseKey; createdAt = $_.createdAt } })
        profileId = $envelope.profile.id
        profileVersion = $envelope.profile.version
        profileSha256 = $envelope.profile.profileSha256
        createdAt = $envelope.createdAt
        admissionFreshness = 'historical-at-attempt'
        currentAdmissionAuthorized = $false
        envelopeSha256 = $loaded.Sha256
        evidenceSetSha256 = $evidenceSetSha256
        bindings = [pscustomobject][ordered]@{
            reviewedSourceCommit = $envelope.bindings.reviewedSourceCommit
            testedSourceCommit = $envelope.bindings.testedSourceCommit
            orchestrationCommit = $envelope.bindings.orchestrationCommit
            targetSha256 = $envelope.bindings.targetSha256
            sourceSha256 = $envelope.bindings.sourceSha256
            orchestrationSha256 = $envelope.bindings.orchestrationSha256
            lockSha256 = $envelope.bindings.lockSha256
            artifactSha256 = $envelope.bindings.artifactSha256
            configurationSha256 = $envelope.bindings.configurationSha256
        }
        syntheticOutcome = $overall
        stages = @($stageOutcomes)
        recoveryEvidenceObserved = [bool](@($stageOutcomes | Where-Object recoveryEvidence).Count -gt 0)
        nativeLifecycleQualified = $false
        executionAllowed = $false
    }
    return $evaluation
}

function ConvertFrom-AzdLifecycleLegacyReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ReportPath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $StageMap
    )
    $legacy = Read-LQJsonFile -Path $ReportPath
    Assert-LQCanonicalSchema -Text $legacy.Text -SchemaName 'deployment-validation.schema.json'
    if ($legacy.Value.reportType -cne 'azdDeploymentValidation' -or $legacy.Value.schemaVersion -notin @('1.0','1.1') -or $legacy.Value.checks -isnot [array]) { throw 'Input is not a supported deployment-validation 1.0/1.1 report.' }
    foreach ($key in $StageMap.Keys) { if ($key -isnot [string] -or $key -cnotin $script:RequiredStages) { throw 'Legacy mapping contains an unknown stage.' } }
    $checksById = @{}
    foreach ($check in $legacy.Value.checks) {
        if ($check -isnot [System.Collections.IDictionary] -or $check.id -isnot [string] -or $checksById.ContainsKey($check.id)) { throw 'Legacy checks contain malformed or duplicate IDs.' }
        $checksById[$check.id] = $check
    }
    $mapping = foreach ($stageId in $script:RequiredStages) {
        if (-not $StageMap.Contains($stageId)) {
            [pscustomobject][ordered]@{ stageId = $stageId; status = 'unknown'; legacyCheckIds = @() }
            continue
        }
        $ids = $StageMap[$stageId]
        if ($ids -isnot [array] -or $ids.Count -eq 0 -or $ids.Count -gt 32) { throw "Legacy map for $stageId must explicitly name 1-32 check IDs." }
        $statuses = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $ids) {
            if ($id -isnot [string] -or -not $checksById.ContainsKey($id)) { $statuses.Add('unknown'); continue }
            $status = $checksById[$id].status
            if ($status -isnot [string] -or $status -notin @('pass','fail','warning','info','skipped','planned','cancelled')) { $statuses.Add('unknown') }
            elseif ($status -eq 'info') { $statuses.Add('warning') }
            elseif ($status -eq 'planned') { $statuses.Add('skipped') }
            elseif ($status -eq 'cancelled') { $statuses.Add('fail') }
            else { $statuses.Add($status) }
        }
        $aggregate = if (@($statuses | Where-Object { $_ -in @('fail','unknown') }).Count) { 'fail' } elseif (@($statuses | Where-Object { $_ -in @('warning','skipped') }).Count) { 'warning' } elseif (@($statuses | Where-Object { $_ -ne 'pass' }).Count) { 'unknown' } else { 'pass' }
        [pscustomobject][ordered]@{ stageId = $stageId; status = $aggregate; legacyCheckIds = @($ids) }
    }
    $mappingResult = [pscustomobject][ordered]@{
        mappingVersion = '0.1'
        mappingType = 'azdLifecycleLegacyMapping'
        legacySchemaVersion = [string]$legacy.Value.schemaVersion
        legacyReportSha256 = $legacy.Sha256
        legacyOutcome = [string]$legacy.Value.outcome
        explicitStageMapping = @($mapping)
        qualification = 'not-established'
        nativeLifecycleQualified = $false
        executionAllowed = $false
    }
    return $mappingResult
}

function New-AzdLifecyclePublicProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Evaluation)
    if ($Evaluation -isnot [System.Collections.IDictionary] -and $Evaluation -isnot [pscustomobject]) { throw 'Only a synthetic evaluation object can be projected.' }
    $evaluationKeys = @('resultVersion','resultType','attemptId','attemptHistory','profileId','profileVersion','profileSha256','createdAt','admissionFreshness','currentAdmissionAuthorized','envelopeSha256','evidenceSetSha256','bindings','syntheticOutcome','stages','recoveryEvidenceObserved','nativeLifecycleQualified','executionAllowed')
    if ($Evaluation -is [System.Collections.IDictionary]) { Assert-LQExactKey $Evaluation $evaluationKeys $evaluationKeys 'Evaluation result' }
    else {
        $actualEvaluationKeys = @($Evaluation.PSObject.Properties.Name)
        if (@($actualEvaluationKeys | Where-Object { $_ -cnotin $evaluationKeys }).Count -gt 0 -or @($evaluationKeys | Where-Object { $_ -notin $actualEvaluationKeys }).Count -gt 0) { throw 'Evaluation result is not closed.' }
    }
    if ($Evaluation.resultVersion -cne '0.1' -or $Evaluation.resultType -cne 'azdLifecycleSyntheticEvaluation' -or $Evaluation.nativeLifecycleQualified -isnot [bool] -or $Evaluation.nativeLifecycleQualified -or $Evaluation.executionAllowed -isnot [bool] -or $Evaluation.executionAllowed -or $Evaluation.admissionFreshness -cne 'historical-at-attempt' -or $Evaluation.currentAdmissionAuthorized -isnot [bool] -or $Evaluation.currentAdmissionAuthorized) { throw 'Only a fail-closed historical synthetic evaluation can be projected.' }
    if ($Evaluation.syntheticOutcome -isnot [string] -or $Evaluation.syntheticOutcome -cnotin @('passed','failed') -or $Evaluation.recoveryEvidenceObserved -isnot [bool]) { throw 'Evaluation outcome flags are invalid.' }
    $bindingResultKeys = @('reviewedSourceCommit','testedSourceCommit','orchestrationCommit','targetSha256','sourceSha256','orchestrationSha256','lockSha256','artifactSha256','configurationSha256')
    if ($Evaluation.bindings -isnot [pscustomobject] -and $Evaluation.bindings -isnot [System.Collections.IDictionary]) { throw 'Evaluation bindings must be an object.' }
    if ($Evaluation.bindings -is [System.Collections.IDictionary]) { Assert-LQExactKey $Evaluation.bindings $bindingResultKeys $bindingResultKeys 'Evaluation bindings' }
    else {
        $actualBindingKeys = @($Evaluation.bindings.PSObject.Properties.Name)
        if (@($actualBindingKeys | Where-Object { $_ -cnotin $bindingResultKeys }).Count -gt 0 -or @($bindingResultKeys | Where-Object { $_ -notin $actualBindingKeys }).Count -gt 0) { throw 'Evaluation bindings are not closed.' }
    }
    if ($Evaluation.profileId -cne 'health-logic-fixture' -or $Evaluation.profileVersion -cne '1.0.0') { throw 'Only the reviewed Health synthetic profile can be projected.' }
    foreach ($digest in @($Evaluation.envelopeSha256, $Evaluation.evidenceSetSha256, $Evaluation.bindings.sourceSha256, $Evaluation.bindings.artifactSha256, $Evaluation.profileSha256)) { Assert-LQSha $digest 'Projection digest' }
    foreach ($commit in @($Evaluation.bindings.reviewedSourceCommit, $Evaluation.bindings.testedSourceCommit, $Evaluation.bindings.orchestrationCommit)) { if ($commit -isnot [string] -or $commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Evaluation source revision is invalid for projection.' } }
    $null = ConvertTo-LQCanonicalUtc $Evaluation.createdAt 'Evaluation createdAt'
    if ($Evaluation.stages -isnot [array] -or $Evaluation.stages.Count -ne 7) { throw 'Projection requires exactly seven stages.' }
    $projectionStageIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $stages = foreach ($stage in $Evaluation.stages) {
        $allowedProjectionStageKeys = @('stageId','status','passed','recoveryEvidence','operationOutcome','absenceObserved','processExited','processExitCode','retryCount','deleteAttemptCount','responseReceived','responseStatus')
        if ($stage -isnot [pscustomobject] -and $stage -isnot [System.Collections.IDictionary]) { throw 'Evaluation stage must be an object.' }
        if ($stage -is [System.Collections.IDictionary]) { Assert-LQExactKey $stage $allowedProjectionStageKeys @('stageId','status','passed','recoveryEvidence') 'Evaluation stage' }
        else {
            $actualStageKeys = @($stage.PSObject.Properties.Name)
            if (@($actualStageKeys | Where-Object { $_ -cnotin $allowedProjectionStageKeys }).Count -gt 0 -or @(@('stageId','status','passed','recoveryEvidence') | Where-Object { $_ -notin $actualStageKeys }).Count -gt 0) { throw 'Evaluation stage is not closed.' }
        }
        if ($stage.stageId -isnot [string] -or $stage.stageId -cnotin $script:RequiredStages -or -not $projectionStageIds.Add($stage.stageId) -or $stage.status -isnot [string] -or $stage.status -cnotin @('pass','warning','fail','skipped','unknown','cancelled') -or $stage.passed -isnot [bool] -or ($stage.passed -and $stage.status -cne 'pass') -or ($stage.status -ceq 'pass' -and -not $stage.passed)) { throw 'Evaluation contains an invalid stage projection.' }
        if ($stage.stageId -ceq 'teardown-operation') {
            $requiredTeardownProjectionKeys = @('operationOutcome','absenceObserved','processExited','processExitCode','retryCount','deleteAttemptCount','responseReceived','responseStatus')
            foreach ($key in $requiredTeardownProjectionKeys) { if (($stage -is [System.Collections.IDictionary] -and -not $stage.Contains($key)) -or ($stage -is [pscustomobject] -and $key -notin $stage.PSObject.Properties.Name)) { throw 'Projected teardown outcome facts are incomplete.' } }
            foreach ($key in @('absenceObserved','processExited')) { if ((Get-LQMemberValue $stage $key) -isnot [bool]) { throw 'Projected teardown outcome flags must be Boolean.' } }
            if ($stage.operationOutcome -isnot [string] -or $stage.operationOutcome -cnotin @('succeeded','failed','unknown','notAttempted') -or ($stage.processExitCode -isnot [int] -and $stage.processExitCode -isnot [long]) -or ($stage.retryCount -isnot [int] -and $stage.retryCount -isnot [long]) -or ($stage.deleteAttemptCount -isnot [int] -and $stage.deleteAttemptCount -isnot [long]) -or $stage.responseReceived -isnot [bool]) { throw 'Projected teardown facts have invalid scalar types.' }
            if ($stage.responseReceived -and (($stage.responseStatus -isnot [int] -and $stage.responseStatus -isnot [long]) -or $stage.responseStatus -lt 100 -or $stage.responseStatus -gt 599)) { throw 'Projected teardown response status is invalid.' }
            if (-not $stage.responseReceived -and $null -ne $stage.responseStatus) { throw 'Projected missing response cannot have a status.' }
            $expectedRecovery = $stage.operationOutcome -in @('unknown','failed') -and $stage.absenceObserved
            if ($stage.recoveryEvidence -ne $expectedRecovery) { throw 'Projected teardown recovery flag is inconsistent.' }
            $expectedTeardownPassed = $stage.status -ceq 'pass' -and $stage.operationOutcome -ceq 'succeeded' -and $stage.processExited -and $stage.processExitCode -eq 0 -and $stage.absenceObserved -and $stage.retryCount -eq 0 -and $stage.deleteAttemptCount -eq 1 -and $stage.responseReceived -and $stage.responseStatus -in @(200,202,204)
            if ($stage.passed -ne $expectedTeardownPassed) { throw 'Projected teardown pass flag is forged or inconsistent.' }
        } elseif ($stage.recoveryEvidence) { throw 'Recovery evidence is only valid for teardown-operation.' }
        if ($stage.stageId -ceq 'teardown-operation') {
            [pscustomobject][ordered]@{ stageId = [string]$stage.stageId; status = [string]$stage.status; passed = [bool]$stage.passed; operationOutcome = [string]$stage.operationOutcome; absenceObserved = [bool]$stage.absenceObserved; processExited = [bool]$stage.processExited; processExitCode = [long]$stage.processExitCode; retryCount = [long]$stage.retryCount; deleteAttemptCount = [long]$stage.deleteAttemptCount; responseReceived = [bool]$stage.responseReceived; responseStatus = $stage.responseStatus }
        } else { [pscustomobject][ordered]@{ stageId = [string]$stage.stageId; status = [string]$stage.status; passed = [bool]$stage.passed } }
    }
    if (@($script:RequiredStages | Where-Object { -not $projectionStageIds.Contains($_) }).Count -ne 0) { throw 'Evaluation is missing a required projection stage.' }
    $computedRecovery = [bool](@($Evaluation.stages | Where-Object { $_.recoveryEvidence }).Count -gt 0)
    $computedOutcome = if (@($Evaluation.stages | Where-Object { -not $_.passed }).Count -eq 0) { 'passed' } else { 'failed' }
    if ($Evaluation.recoveryEvidenceObserved -ne $computedRecovery -or $Evaluation.syntheticOutcome -cne $computedOutcome) { throw 'Evaluation summary outcome does not match its closed stage set.' }
    $projection = [pscustomobject][ordered]@{
        projectionVersion = '0.1'
        projectionType = 'azdLifecyclePublicSyntheticProjection'
        profileId = [string]$Evaluation.profileId
        profileVersion = [string]$Evaluation.profileVersion
        createdAt = $Evaluation.createdAt
        admissionFreshness = 'historical-at-attempt'
        currentAdmissionAuthorized = $false
        sourceRepository = 'nathanmcnulty/azd-entra-health-monitoring'
        reviewedSourceCommit = $Evaluation.bindings.reviewedSourceCommit
        testedSourceCommit = $Evaluation.bindings.testedSourceCommit
        orchestrationCommit = $Evaluation.bindings.orchestrationCommit
        profileSha256 = $Evaluation.profileSha256
        artifactSha256 = $Evaluation.bindings.artifactSha256
        sourceSha256 = $Evaluation.bindings.sourceSha256
        envelopeSha256 = $Evaluation.envelopeSha256
        evidenceSetSha256 = $Evaluation.evidenceSetSha256
        syntheticOutcome = [string]$Evaluation.syntheticOutcome
        stages = @($stages)
        recoveryEvidenceObserved = [bool]$Evaluation.recoveryEvidenceObserved
        nativeLifecycleQualified = $false
        executionAllowed = $false
        publicationAuthorized = $false
    }
    Assert-LQCanonicalSchema -Text (ConvertTo-Json -InputObject $projection -Depth 10 -Compress) -SchemaName 'lifecycle-public-projection.schema.json'
    return $projection
}

Export-ModuleMember -Function Get-AzdLifecycleRequiredStage, New-AzdLifecyclePlan, Test-AzdLifecycleEnvelope, ConvertFrom-AzdLifecycleLegacyReport, New-AzdLifecyclePublicProjection
