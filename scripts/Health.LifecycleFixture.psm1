# Deterministic, local-only fixture generator. This module has no Azure CLI, network,
# Azure, Graph, Teams, or workflow runtime dependencies.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LffGuidance([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$script:LffPinnedSourceCommit = '4d3273335aed8f59dc4df2151f28e8694dced7d9'
$script:LffPinnedSourceFiles = [ordered]@{
    'infra/workflow-definition.json' = 'AAD1248D010DB7C134C27E4A8BDADE28C9B8AA1DDFF764FACFAF8F35186F923D'
    'infra/lifecycle-workflow-definition.json' = '2E154EE1DA0F33DA7018DC6FC486872CBFCBBFDC5D0BA01FAC9DBB6C1F7F21CF'
}

function Test-LffJsonDuplicates([System.Text.Json.JsonElement]$Element, [string]$Path = '$') {
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw "Duplicate JSON property at $Path." }
            Test-LffJsonDuplicates $property.Value "$Path.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $i = 0
        foreach ($item in $Element.EnumerateArray()) { Test-LffJsonDuplicates $item "$Path[$i]"; $i++ }
    }
}

function Read-LffJsonSnapshot([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $strictUtf8.GetString($bytes)
    $document = [System.Text.Json.JsonDocument]::Parse($text)
    try { Test-LffJsonDuplicates $document.RootElement } finally { $document.Dispose() }
    $value=$text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    return [pscustomobject]@{ value=$value; bytes=$bytes; sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}

function Read-LffJson([string]$Path) {
    return ,(Read-LffJsonSnapshot $Path).value
}

function Assert-LffSafeOutputPath([string]$Root,[string]$Path) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $pathFull=[IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Generated path escaped the output root.' }
    $item=Get-Item -LiteralPath $rootFull -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output root cannot be a reparse point.' }
    $cursor=Split-Path -Parent $pathFull
    while ($cursor -and $cursor.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $part=Get-Item -LiteralPath $cursor -Force
            if ($part.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output ancestry cannot contain reparse points.' }
        }
        if ($cursor -ieq $rootFull) { break }
        $cursor=Split-Path -Parent $cursor
    }
}

function Write-LffCreateNewBytes([string]$Root,[string]$Path,[byte[]]$Bytes) {
    Assert-LffSafeOutputPath $Root $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function ConvertTo-LffCanonicalValue($Value) {
    if ($Value -is [System.Collections.IDictionary]) {
        $result=[ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $result[[string]$key]=ConvertTo-LffCanonicalValue $Value[$key] }
        return ,$result
    }
    if ($Value -is [array]) {
        $items=[Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-LffCanonicalValue $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function ConvertTo-LffCanonicalJson($Value) {
    $canonical=ConvertTo-LffCanonicalValue $Value
    return ConvertTo-Json -InputObject $canonical -Depth 100 -Compress
}

function Get-LffRepoHead([string]$RepositoryRoot) {
    $head = & git -C $RepositoryRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or $head -isnot [string] -or $head -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The local source commit could not be verified.'
    }
    return $head
}

function Get-LffPinnedSourceState([string]$RepositoryRoot, [System.Collections.IDictionary]$SourceFiles) {
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $required = @($script:LffPinnedSourceFiles.Keys)
    if ($SourceFiles.Count -ne $required.Count -or @($SourceFiles.Keys | Where-Object { $_ -notin $required }).Count -ne 0) { throw 'Closed source file set required.' }
    $bytesByPath = [ordered]@{}
    $hashes = [ordered]@{}
    foreach ($path in $required) {
        if (-not $SourceFiles.Contains($path)) { throw 'Required pinned source is absent.' }
        $absolute = [IO.Path]::GetFullPath((Join-Path $root $path))
        if (-not $absolute.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source path escaped repository.' }
        $bytes = [IO.File]::ReadAllBytes($absolute)
        $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if ($actualHash -cne [string]$script:LffPinnedSourceFiles[$path] -or $actualHash -cne [string]$SourceFiles[$path]) { throw "Pinned source drift refused for '$path'." }
        $bytesByPath[$path] = $bytes
        $hashes[$path] = $actualHash
    }
    return [pscustomobject]@{ bytes=$bytesByPath; hashes=$hashes }
}

function Test-HealthFixtureSourcePins {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$SourceFiles)
    $state=Get-LffPinnedSourceState $RepositoryRoot $SourceFiles
    return [pscustomobject]@{ verified=$true; sourceHashes=$state.hashes }
}

function Test-HealthFixtureTriggerBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,10000)][int]$OuterTriggerInvocations,
        [Parameter(Mandatory)][ValidateRange(0,10000)][int]$NestedStubTriggerInvocations,
        [Parameter(Mandatory)][ValidateRange(0,10000)][int]$ConfiguredRetryAttempts,
        [Parameter(Mandatory)][ValidateRange(1,10000)][int]$Limit = 20
    )
    $total = [long]$OuterTriggerInvocations + $NestedStubTriggerInvocations + $ConfiguredRetryAttempts
    if ($total -gt $Limit) { throw 'Inclusive outer, nested-stub, and retry trigger budget exceeded.' }
    return [pscustomobject]@{ outerTriggerInvocations=$OuterTriggerInvocations; nestedStubTriggerInvocations=$NestedStubTriggerInvocations; configuredRetryAttempts=$ConfiguredRetryAttempts; inclusiveTriggerTotal=[int]$total; limit=$Limit; withinLimit=$true }
}

function Resolve-HealthFixtureLifecycleOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('succeeded','failed','unknown','not-attempted')][string]$DeleteOperationOutcome,
        [Parameter(Mandatory)][bool]$AbsenceObserved,
        [AllowNull()][Nullable[int]]$ProcessExitCode
    )
    $operationPassed = $DeleteOperationOutcome -ceq 'succeeded' -and $null -ne $ProcessExitCode -and $ProcessExitCode -eq 0
    $recovery = if ($AbsenceObserved) { 'absence-observed' } else { 'not-established' }
    $qualification = if ($operationPassed -and $AbsenceObserved) { 'pass' } else { 'incomplete' }
    return [pscustomobject][ordered]@{ operationOutcome=$DeleteOperationOutcome; processExitCode=$ProcessExitCode; absenceObserved=$AbsenceObserved; recoveryObservation=$recovery; qualification=$qualification }
}

function Get-LffActionMap([System.Collections.IDictionary]$Actions, [string]$Prefix = '') {
    foreach ($name in $Actions.Keys) {
        $action = $Actions[$name]
        $path = if ($Prefix) { "$Prefix/$name" } else { [string]$name }
        if ($action -isnot [System.Collections.IDictionary] -or $action.type -isnot [string]) { throw "Malformed action at $path." }
        [pscustomobject]@{ path = $path; name = [string]$name; action = $action; type = [string]$action.type }
        if ($action.Contains('actions') -and $action.actions -is [System.Collections.IDictionary]) { Get-LffActionMap $action.actions $path }
        if ($action.Contains('else') -and $action.else -is [System.Collections.IDictionary] -and $action.else.Contains('actions') -and $action.else.actions -is [System.Collections.IDictionary]) { Get-LffActionMap $action.else.actions "$path/else" }
        if ($action.Contains('cases') -and $action.cases -is [System.Collections.IDictionary]) {
            foreach ($caseName in $action.cases.Keys) {
                $case = $action.cases[$caseName]
                if ($case.actions -is [System.Collections.IDictionary]) { Get-LffActionMap $case.actions "$path/cases/$caseName" }
            }
        }
    }
}

function Assert-LffKnownDefinition([System.Collections.IDictionary]$Definition, [ValidateSet('receiver','lifecycle')][string]$Kind) {
    if ($Definition.parameters -isnot [System.Collections.IDictionary] -or $Definition.actions -isnot [System.Collections.IDictionary] -or $Definition.triggers -isnot [System.Collections.IDictionary]) {
        throw 'Pinned workflow definition has an unsupported top-level shape.'
    }
    $allowed = if ($Kind -eq 'receiver') { @('Request','Compose','Response','If','Select','Foreach','Http','ApiConnection','Terminate') } else { @('Recurrence','Request','Compose','Query','If','Http','Terminate') }
    $all = @(Get-LffActionMap $Definition.actions)
    $triggers = @($Definition.triggers.Values)
    foreach ($trigger in $triggers) {
        if ($trigger.type -isnot [string] -or $trigger.type -notin @('Request','Recurrence')) { throw 'Unknown trigger type in pinned workflow.' }
    }
    foreach ($entry in $all) {
        if ($entry.type -notin $allowed) { throw "Unknown action type '$($entry.type)' at '$($entry.path)'." }
        if ($entry.action.Contains('inputs') -and $entry.action.inputs -is [System.Collections.IDictionary] -and $entry.action.inputs.Contains('retryPolicy') -and $entry.action.inputs.retryPolicy) {
            $type = $entry.action.inputs.retryPolicy.type
            $count = $entry.action.inputs.retryPolicy.count
            if ($type -isnot [string] -or ($count -isnot [int] -and $count -isnot [long] -and $null -ne $count)) { throw "Malformed retry policy at '$($entry.path)'." }
        }
    }
    if ($Kind -eq 'receiver' -and -not $all.Where({ $_.name -ceq 'Get_alert_details' -and $_.type -ceq 'Http' })) { throw 'The pinned receiver action contract changed.' }
    if ($Kind -eq 'lifecycle') {
        foreach ($required in @('List_subscriptions','Create_subscription')) {
            if (-not $all.Where({ $_.name -ceq $required -and $_.type -ceq 'Http' })) { throw "The pinned lifecycle create path is missing '$required'." }
        }
    }
    return $all
}

function Get-HealthFixturePlan {
    [CmdletBinding()]
    param(
        [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
        [string]$ProfilePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'validation/profiles/health-logic-fixture.v1.json'),
        [string]$SourceCommit
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $profileSnapshot=Read-LffJsonSnapshot ([IO.Path]::GetFullPath($ProfilePath))
    $profile=$profileSnapshot.value
    $allowedProfileKeys=@('schemaVersion','profileId','profileVersion','sourceCommit','sourceFiles','budgets','cases','accounting','resourceSemantics','lifecycleOutcomeSemantics')
    if (@($profile.Keys | Where-Object { $_ -notin $allowedProfileKeys }).Count -ne 0 -or @($allowedProfileKeys | Where-Object { -not $profile.Contains($_) }).Count -ne 0) { throw 'Unknown or missing profile property refused.' }
    if (($profile.schemaVersion -isnot [int] -and $profile.schemaVersion -isnot [long]) -or $profile.schemaVersion -ne 1 -or
        $profile.profileId -isnot [string] -or $profile.profileId -cne 'health-logic-fixture' -or
        $profile.profileVersion -isnot [string] -or $profile.profileVersion -cne '1.0.0' -or
        $profile.sourceCommit -isnot [string] -or $profile.sourceCommit -cne $script:LffPinnedSourceCommit) { throw 'Unsupported fixture profile identity, source, or schema.' }
    if ([string]::IsNullOrEmpty($SourceCommit)) { $SourceCommit = [string]$profile.sourceCommit }
    if ($profile.sourceCommit -cne $script:LffPinnedSourceCommit -or $SourceCommit -cne $script:LffPinnedSourceCommit) { throw 'Source commit identity mismatch refused.' }
    $currentHead = Get-LffRepoHead $root
    & git -C $root merge-base --is-ancestor $profile.sourceCommit $currentHead 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Pinned source commit is not an ancestor of the adapter checkout.' }
    if ($profile.sourceFiles -isnot [System.Collections.IDictionary] -or $profile.sourceFiles.Count -ne 2) { throw 'Closed source file set required.' }
    foreach ($sourcePath in $script:LffPinnedSourceFiles.Keys) {
        if (-not $profile.sourceFiles.Contains($sourcePath) -or $profile.sourceFiles[$sourcePath] -isnot [string] -or $profile.sourceFiles[$sourcePath] -cne $script:LffPinnedSourceFiles[$sourcePath]) { throw 'Profile source pin differs from the adapter pin.' }
    }
    $budgetKeys = @('inclusiveTriggerLimit','billableActionActivationLimit','maxInputBytes','maxAggregatePayloadBytes','maxLogBytes','maxEvents')
    if ($profile.budgets -isnot [System.Collections.IDictionary] -or $profile.budgets.Count -ne $budgetKeys.Count -or @($profile.budgets.Keys | Where-Object { $_ -notin $budgetKeys }).Count -ne 0) { throw 'Closed budget property set required.' }
    $accountingKeys = @('outerTriggerInvocations','nestedStubTriggerInvocations','configuredRetryAttempts','billableActionActivations','inclusiveTriggerTotal','receiverDuplicateLoopIterations','receiverMismatchLoopIterations','lifecycleCreateHttpActions','billableActionAssumption')
    if ($profile.accounting -isnot [System.Collections.IDictionary] -or $profile.accounting.Count -ne $accountingKeys.Count -or @($profile.accounting.Keys | Where-Object { $_ -notin $accountingKeys }).Count -ne 0) { throw 'Closed accounting property set required.' }
    $resourceKeys = @('fixtureResourcesCreated','adoptedResources','sharedResourcesTouched','unknownCreationCanAuthorizeCleanup','sharedRestorationClaimed')
    if ($profile.resourceSemantics -isnot [System.Collections.IDictionary] -or $profile.resourceSemantics.Count -ne $resourceKeys.Count -or @($profile.resourceSemantics.Keys | Where-Object { $_ -notin $resourceKeys }).Count -ne 0) { throw 'Closed resource semantics required.' }
    $outcomeKeys = @('unknownDeleteWithObservedAbsence','nonzeroTeardownWithObservedAbsence','noOpCleanup')
    if ($profile.lifecycleOutcomeSemantics -isnot [System.Collections.IDictionary] -or $profile.lifecycleOutcomeSemantics.Count -ne $outcomeKeys.Count -or @($profile.lifecycleOutcomeSemantics.Keys | Where-Object { $_ -notin $outcomeKeys }).Count -ne 0) { throw 'Closed lifecycle semantics required.' }
    $expectedCaseKeys = @{
        'receiver-duplicate-batch' = @('runStatus','iterations','actionActivations','graphCalls','teamsCalls','fixtureStubTriggers')
        'receiver-mismatched-state' = @('runStatus','iterations','actionActivations','graphCalls','teamsCalls','fixtureStubTriggers')
        'lifecycle-create' = @('runStatus','created','actionActivations','fixtureStubTriggers','stubActions','graphCalls','teamsCalls')
    }
    foreach ($case in $profile.cases) {
        if ($case.id -isnot [string] -or -not $expectedCaseKeys.ContainsKey($case.id)) { throw 'Unknown fixture case refused.' }
        if ($case.expected -isnot [System.Collections.IDictionary] -or @($case.expected.Keys | Where-Object { $_ -notin $expectedCaseKeys[$case.id] }).Count -ne 0 -or @($expectedCaseKeys[$case.id] | Where-Object { -not $case.expected.Contains($_) }).Count -ne 0) { throw "Closed expected-result shape required for '$($case.id)'." }
    }
    if ($profile.budgets.maxAggregatePayloadBytes -ne 10485760 -or $profile.budgets.maxInputBytes -ne 10485760 -or $profile.budgets.maxLogBytes -ne 104857600) { throw 'Payload and log budgets are outside the reviewed profile.' }
    if ($profile.budgets.billableActionActivationLimit -ne 40 -or $profile.budgets.maxEvents -ne 128 -or
        $profile.accounting.outerTriggerInvocations -ne 3 -or $profile.accounting.nestedStubTriggerInvocations -ne 2 -or $profile.accounting.configuredRetryAttempts -ne 0 -or
        $profile.accounting.billableActionActivations -ne 32 -or $profile.accounting.inclusiveTriggerTotal -ne 5 -or
        (ConvertTo-LffCanonicalJson $profile.accounting.lifecycleCreateHttpActions) -cne '["List_subscriptions","Create_subscription"]' -or
        $profile.accounting.billableActionAssumption -cne 'one potential Logic Apps action activation is one conservative billable action unit; actual billing may differ') { throw 'Reviewed accounting values changed.' }
    foreach ($key in $resourceKeys) { if ($profile.resourceSemantics[$key] -isnot [bool] -or $profile.resourceSemantics[$key] -ne $false) { throw 'Resource/ownership claims must remain false.' } }
    $fixedBudgets=[ordered]@{inclusiveTriggerLimit=20;billableActionActivationLimit=40;maxInputBytes=10485760;maxAggregatePayloadBytes=10485760;maxLogBytes=104857600;maxEvents=128}
    $fixedAccounting=[ordered]@{outerTriggerInvocations=3;nestedStubTriggerInvocations=2;configuredRetryAttempts=0;billableActionActivations=32;inclusiveTriggerTotal=5;receiverDuplicateLoopIterations=1;receiverMismatchLoopIterations=1;lifecycleCreateHttpActions=@('List_subscriptions','Create_subscription');billableActionAssumption='one potential Logic Apps action activation is one conservative billable action unit; actual billing may differ'}
    if ((ConvertTo-LffCanonicalJson $profile.budgets) -cne (ConvertTo-LffCanonicalJson $fixedBudgets) -or (ConvertTo-LffCanonicalJson $profile.accounting) -cne (ConvertTo-LffCanonicalJson $fixedAccounting)) { throw 'Reviewed budgets/accounting values or scalar types changed.' }
    if ((ConvertTo-LffCanonicalJson $profile.lifecycleOutcomeSemantics.unknownDeleteWithObservedAbsence) -cne '{"absenceObserved":true,"operationOutcome":"unknown","qualification":"incomplete"}' -or
        (ConvertTo-LffCanonicalJson $profile.lifecycleOutcomeSemantics.nonzeroTeardownWithObservedAbsence) -cne '{"absenceObserved":true,"processExitCode":1,"qualification":"incomplete"}' -or
        (ConvertTo-LffCanonicalJson $profile.lifecycleOutcomeSemantics.noOpCleanup) -cne '{"operationOutcome":"not-attempted","qualification":"incomplete"}') { throw 'Lifecycle operation and recovery semantics changed.' }
    $sourceState=Get-LffPinnedSourceState $root $profile.sourceFiles
    $sourceBytes=$sourceState.bytes
    if ($profile.cases -isnot [array] -or $profile.cases.Count -ne 3) { throw 'The profile must contain exactly the three reviewed fixture cases.' }
    $caseIds = @($profile.cases | ForEach-Object { $_.id })
    $expectedIds = @('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create')
    if (@(Compare-Object $expectedIds $caseIds -CaseSensitive).Count -ne 0) { throw 'Unknown, missing, or duplicate fixture case.' }
    $expectedSources = @('infra/workflow-definition.json','infra/workflow-definition.json','infra/lifecycle-workflow-definition.json')
    for ($i=0; $i -lt 3; $i++) {
        if ($profile.cases[$i].id -cne $expectedIds[$i]) { throw 'Fixture case order differs from the reviewed profile.' }
        if ($profile.cases[$i].source -isnot [string] -or $profile.cases[$i].source -cne $expectedSources[$i]) { throw "Source mapping mismatch for '$($expectedIds[$i])'." }
    }
    $fixedInputs = @(
        [ordered]@{ value=@([ordered]@{clientState='fixture-client-state';changeType='created';resourceData=[ordered]@{id='fixture-alert-01'}},[ordered]@{clientState='fixture-client-state';changeType='created';resourceData=[ordered]@{id='fixture-alert-01'}}) },
        [ordered]@{ value=@([ordered]@{clientState='fixture-wrong-state';changeType='created';resourceData=[ordered]@{id='fixture-alert-02'}}) },
        [ordered]@{ case='create-when-list-is-empty' }
    )
    $fixedExpected = @(
        [ordered]@{runStatus='Succeeded';iterations=1;actionActivations=14;graphCalls=0;teamsCalls=0;fixtureStubTriggers=0},
        [ordered]@{runStatus='Succeeded';iterations=1;actionActivations=9;graphCalls=0;teamsCalls=0;fixtureStubTriggers=0},
        [ordered]@{runStatus='Succeeded';created=$true;actionActivations=9;fixtureStubTriggers=2;stubActions=@('List_subscriptions','Create_subscription');graphCalls=0;teamsCalls=0}
    )
    for ($i=0; $i -lt 3; $i++) {
        if ((ConvertTo-LffCanonicalJson $profile.cases[$i].fixtureInput) -cne (ConvertTo-LffCanonicalJson $fixedInputs[$i]) -or
            (ConvertTo-LffCanonicalJson $profile.cases[$i].expected) -cne (ConvertTo-LffCanonicalJson $fixedExpected[$i])) { throw "Fixture input/oracle mismatch for '$($expectedIds[$i])'." }
    }
    if (($profile.budgets.inclusiveTriggerLimit -isnot [int] -and $profile.budgets.inclusiveTriggerLimit -isnot [long]) -or $profile.budgets.inclusiveTriggerLimit -ne 20 -or
        $profile.accounting.outerTriggerInvocations -ne 3 -or $profile.accounting.nestedStubTriggerInvocations -ne 2 -or
        $profile.accounting.configuredRetryAttempts -ne 0 -or $profile.accounting.inclusiveTriggerTotal -ne 5 -or $profile.accounting.billableActionActivations -ne 32 -or
        ($profile.accounting.outerTriggerInvocations + $profile.accounting.nestedStubTriggerInvocations + $profile.accounting.configuredRetryAttempts) -ne $profile.accounting.inclusiveTriggerTotal -or
        $profile.accounting.billableActionActivations -gt $profile.budgets.billableActionActivationLimit -or
        $profile.accounting.inclusiveTriggerTotal -gt $profile.budgets.inclusiveTriggerLimit) { throw 'Inclusive trigger budget is invalid or exceeded.' }
    $null = Test-HealthFixtureTriggerBudget -OuterTriggerInvocations ([int]$profile.accounting.outerTriggerInvocations) -NestedStubTriggerInvocations ([int]$profile.accounting.nestedStubTriggerInvocations) -ConfiguredRetryAttempts ([int]$profile.accounting.configuredRetryAttempts) -Limit ([int]$profile.budgets.inclusiveTriggerLimit)
    $definitions = @{}
    foreach ($pair in $sourceBytes.GetEnumerator()) {
        $tmp = [IO.Path]::GetTempFileName()
        try { [IO.File]::WriteAllBytes($tmp, $pair.Value); $definitions[$pair.Key] = Read-LffJson $tmp } finally { Remove-Item -LiteralPath $tmp -Force }
    }
    $receiver = $definitions['infra/workflow-definition.json']
    $lifecycle = $definitions['infra/lifecycle-workflow-definition.json']
    $receiverActions = @(Assert-LffKnownDefinition $receiver receiver)
    $lifecycleActions = @(Assert-LffKnownDefinition $lifecycle lifecycle)
    if ($receiver.triggers.Count -ne 1 -or $lifecycle.triggers.Count -ne 1 -or $receiver.triggers.Values[0].type -cne 'Request' -or $lifecycle.triggers.Values[0].type -cne 'Recurrence') { throw 'Source trigger contract changed.' }
    $fixtureCasePlans = [Collections.Generic.List[object]]::new()
    foreach ($case in $profile.cases) {
        $allowedCaseKeys=@('id','source','fixtureInput','expected')
        if ($case -isnot [System.Collections.IDictionary] -or @($case.Keys | Where-Object { $_ -notin $allowedCaseKeys }).Count -ne 0 -or @($allowedCaseKeys | Where-Object { -not $case.Contains($_) }).Count -ne 0) { throw 'Unknown or missing case property refused.' }
        $json = $case.fixtureInput | ConvertTo-Json -Depth 40 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        if ($bytes.Length -gt $profile.budgets.maxInputBytes) { throw "Fixture '$($case.id)' exceeds input-byte budget." }
        $fixtureCasePlans.Add([pscustomobject]@{ id = [string]$case.id; source = [string]$case.source; input = $case.fixtureInput; inputBytes = $bytes.Length; expected = $case.expected })
    }
    return [pscustomobject]@{
        RepositoryRoot = $root
        ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
        Profile = $profile
        SourceCommit = $SourceCommit
        SourceCheckoutHead = $currentHead
        ProfileSha256 = $profileSnapshot.sha256
        SourceHashes = [ordered]@{ 'infra/workflow-definition.json' = $profile.sourceFiles['infra/workflow-definition.json']; 'infra/lifecycle-workflow-definition.json' = $profile.sourceFiles['infra/lifecycle-workflow-definition.json'] }
        ReceiverDefinition = $receiver
        LifecycleDefinition = $lifecycle
        ReceiverActionCount = $receiverActions.Count
        LifecycleActionCount = $lifecycleActions.Count
        Cases = @($fixtureCasePlans)
        InclusiveTriggerCount = [int]$profile.accounting.inclusiveTriggerTotal
    }
}

function Set-LffStringsInPlace($Value, [string[]]$ConvertedHttpActions, [bool]$RewriteCallbackParameter, [bool]$RewriteBodyOutputs) {
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child=$Value[$key]
            if ($child -is [string]) {
                $result=$child
                if ($RewriteBodyOutputs) { foreach ($name in $ConvertedHttpActions) { $result=[regex]::Replace($result,"body\('$([regex]::Escape($name))'\)","outputs('$name')",[Text.RegularExpressions.RegexOptions]::IgnoreCase) } }
                if ($RewriteCallbackParameter) { $result=$result.Replace("parameters('NotificationUrl')","parameters('FixtureStubCallback')") }
                $Value[$key]=$result
            } elseif ($child -is [System.Collections.IDictionary] -or $child -is [array]) {
                Set-LffStringsInPlace $child $ConvertedHttpActions $RewriteCallbackParameter $RewriteBodyOutputs
            }
        }
    } elseif ($Value -is [array]) {
        for ($i=0; $i -lt $Value.Count; $i++) {
            $child=$Value[$i]
            if ($child -is [string]) {
                $result=$child
                if ($RewriteBodyOutputs) { foreach ($name in $ConvertedHttpActions) { $result=[regex]::Replace($result,"body\('$([regex]::Escape($name))'\)","outputs('$name')",[Text.RegularExpressions.RegexOptions]::IgnoreCase) } }
                if ($RewriteCallbackParameter) { $result=$result.Replace("parameters('NotificationUrl')","parameters('FixtureStubCallback')") }
                $Value[$i]=$result
            } elseif ($child -is [System.Collections.IDictionary] -or $child -is [array]) {
                Set-LffStringsInPlace $child $ConvertedHttpActions $RewriteCallbackParameter $RewriteBodyOutputs
            }
        }
    }
}

function Convert-LffActions([System.Collections.IDictionary]$Actions, [ValidateSet('receiver','lifecycle')][string]$Kind, [Collections.Generic.List[string]]$ExternalNames = $null) {
    $isRoot=$null -eq $ExternalNames
    if ($isRoot) { $ExternalNames=[Collections.Generic.List[string]]::new() }
    foreach ($name in @($Actions.Keys)) {
        $action = $Actions[$name]
        $type = [string]$action.type
        if ($type -eq 'Http') {
            $ExternalNames.Add([string]$name)
            if ($Kind -eq 'receiver') {
                $runAfter = if ($action.Contains('runAfter')) { $action.runAfter } else { [ordered]@{} }
                $fixed = if ($name -ceq 'Get_alert_details') { [ordered]@{ id='fixture-alert-01'; alertType='fixture'; scenario='fixture'; category='fixture'; state='active' } } else { throw "Unknown receiver HTTP action '$name'." }
                $Actions[$name] = [ordered]@{ type='Compose'; runAfter=$runAfter; inputs=$fixed }
            } else {
                $runAfter = if ($action.Contains('runAfter')) { $action.runAfter } else { [ordered]@{} }
                $fixtureReply = switch -CaseSensitive ($name) {
                    'List_subscriptions' { [ordered]@{ statusCode=200; body=[ordered]@{ value=@() } } }
                    'Create_subscription' { [ordered]@{ statusCode=201; body=[ordered]@{ id='fixture-created-subscription' } } }
                    'Get_subscription_by_id' { [ordered]@{ statusCode=200; body=[ordered]@{ id='fixture-subscription'; clientState='fixture-client-state' } } }
                    'Reauthorize_subscription' { [ordered]@{ statusCode=200; body=[ordered]@{} } }
                    'Renew_subscription' { [ordered]@{ statusCode=200; body=[ordered]@{} } }
                    'Relay_lifecycle_warning' { [ordered]@{ statusCode=202; body=[ordered]@{ accepted=$true } } }
                    default { throw "Unknown lifecycle HTTP action '$name'." }
                }
                $Actions[$name] = [ordered]@{
                    type='Http'; runAfter=$runAfter
                    runtimeConfiguration=[ordered]@{ secureData=[ordered]@{ properties=@('inputs','outputs') } }
                    inputs=[ordered]@{ method='POST'; uri="@parameters('FixtureStubCallback')"; headers=[ordered]@{ 'Content-Type'='application/json' }; body=[ordered]@{ fixtureCase='lifecycle-create'; fixtureAction=$name; fixtureReply=$fixtureReply }; retryPolicy=[ordered]@{ type='none' } }
                }
            }
        } elseif ($type -eq 'ApiConnection') {
            $runAfter = if ($action.Contains('runAfter')) { $action.runAfter } else { [ordered]@{} }
            $Actions[$name] = [ordered]@{ type='Compose'; runAfter=$runAfter; inputs=[ordered]@{ fixtureDelivery='synthetic'; sourceAction=$name } }
        } else {
            if ($action.Contains('runtimeConfiguration')) { $null = $action.Remove('runtimeConfiguration') }
            if ($action.Contains('actions') -and $action.actions -is [System.Collections.IDictionary]) { $null=Convert-LffActions $action.actions $Kind $ExternalNames }
            if ($action.Contains('else') -and $action.else -is [System.Collections.IDictionary] -and $action.else.Contains('actions') -and $action.else.actions -is [System.Collections.IDictionary]) { $null=Convert-LffActions $action.else.actions $Kind $ExternalNames }
            if ($action.Contains('cases') -and $action.cases -is [System.Collections.IDictionary]) { foreach ($case in $action.cases.Values) { if ($case.actions -is [System.Collections.IDictionary]) { $null=Convert-LffActions $case.actions $Kind $ExternalNames } } }
        }
    }
    if ($isRoot) { return ,$ExternalNames.ToArray() }
}

function New-LffManualTrigger {
    param([System.Collections.IDictionary]$Definition)
    $Definition.triggers = [ordered]@{
        When_a_HTTP_request_is_received = [ordered]@{
            type='Request'; kind='Http'; inputs=[ordered]@{ method='POST' }
        }
    }
}

function New-LffStubDefinition {
    return [ordered]@{
        '$schema'='https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
        contentVersion='1.0.0.0'
        parameters=[ordered]@{}
        triggers=[ordered]@{
            When_a_HTTP_request_is_received=[ordered]@{
                type='Request'; kind='Http'; inputs=[ordered]@{
                    method='POST'
                    schema=[ordered]@{
                        type='object'
                        properties=[ordered]@{
                            fixtureCase=[ordered]@{ type='string' }
                            fixtureAction=[ordered]@{ type='string' }
                            fixtureReply=[ordered]@{
                                type='object'
                                properties=[ordered]@{
                                    statusCode=[ordered]@{ type='integer' }
                                    body=[ordered]@{ type='object' }
                                }
                            }
                        }
                        required=@('fixtureCase','fixtureAction','fixtureReply')
                    }
                }
            }
        }
        actions=[ordered]@{
            Return_fixture_response=[ordered]@{
                type='Response'; kind='Http'; runAfter=[ordered]@{}
                inputs=[ordered]@{ statusCode="@triggerBody()?['fixtureReply']?['statusCode']"; body="@triggerBody()?['fixtureReply']?['body']" }
            }
        }
        outputs=[ordered]@{}
    }
}

function Assert-LffSanitized([System.Collections.IDictionary]$Definition, [string]$Path) {
    $json = $Definition | ConvertTo-Json -Depth 100 -Compress
    foreach ($forbidden in @('graph.microsoft.com','ApiConnection','ManagedServiceIdentity','connectionId','$connections','https://example.invalid')) {
        if ($json.IndexOf($forbidden,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Generated artifact '$Path' retains a prohibited provider dependency." }
    }
    if ($json.IndexOf("parameters('NotificationUrl')",[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ($Definition.parameters -is [System.Collections.IDictionary] -and $Definition.parameters.Contains('NotificationUrl'))) {
        throw "Generated artifact '$Path' retains the original notification URL parameter."
    }
    if ($json -match '(?i)https?://(?!schema\.management\.azure\.com)') { throw "Generated artifact '$Path' contains a literal network URL." }
}

function Assert-LffParameterBindings([System.Collections.IDictionary]$Definition,[System.Collections.IDictionary]$Values,[string[]]$Unmaterialized) {
    $json=$Definition | ConvertTo-Json -Depth 100 -Compress
    foreach ($match in [regex]::Matches($json,"(?i)parameters\('([^']+)'\)")) {
        $name=$match.Groups[1].Value
        if (-not $Definition.parameters.Contains($name)) { throw "Generated parameter reference '$name' is undeclared." }
    }
    foreach ($name in $Definition.parameters.Keys) {
        if ($name -in $Unmaterialized) {
            if ($Values.Contains($name)) { throw "Unmaterialized parameter '$name' was assigned a value." }
        } elseif (-not $Values.Contains($name)) { throw "Generated parameter '$name' has no fixed fixture value." }
    }
    foreach ($name in $Values.Keys) { if (-not $Definition.parameters.Contains($name)) { throw "Fixture value '$name' has no generated parameter declaration." } }
}

function ConvertTo-LffBytes($Value) {
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    return ,([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Export-HealthLogicFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $out = [IO.Path]::GetFullPath($OutputDirectory)
    if (Test-Path -LiteralPath $out) { throw 'Output path must be new; fixture export is CreateNew only.' }
    $providedPlan=$Plan
    if ((Read-LffJsonSnapshot $providedPlan.ProfilePath).sha256 -cne $providedPlan.ProfileSha256) { throw 'Profile drift after planning refused.' }
    $Plan=Get-HealthFixturePlan -RepositoryRoot $providedPlan.RepositoryRoot -ProfilePath $providedPlan.ProfilePath
    $sourceDiff=@(Compare-Object @($Plan.SourceHashes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) @($providedPlan.SourceHashes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -CaseSensitive)
    if ($Plan.ProfileSha256 -cne $providedPlan.ProfileSha256 -or $Plan.SourceCommit -cne $providedPlan.SourceCommit -or $sourceDiff.Count -ne 0) { throw 'Export plan changed after preparation.' }
    $parent = Get-Item -LiteralPath (Split-Path -Parent $out)
    while ($null -ne $parent) { if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output ancestry cannot contain reparse points.' }; $parent=$parent.Parent }
    if (Test-Path -LiteralPath $out) { throw 'Output path appeared after planning; collision refused.' }
    $null = [IO.Directory]::CreateDirectory($out)
    if (-not (Test-Path -LiteralPath $out -PathType Container)) { throw 'Output directory creation could not be verified.' }
    Assert-LffSafeOutputPath $out (Join-Path $out 'manifest.json')
    $allFiles = [ordered]@{}
    $caseAccounting = [Collections.Generic.List[object]]::new()
    [long]$aggregatePayloadBytes = 0
    [long]$aggregateActionActivations = 0
    try {
        foreach ($case in $Plan.Cases) {
            $caseDir = Join-Path $out (Join-Path 'cases' $case.id)
            if (Test-Path -LiteralPath $caseDir) { throw "Case output path already exists: $($case.id)." }
            Assert-LffSafeOutputPath $out (Join-Path $caseDir 'definition.json')
            $null = [IO.Directory]::CreateDirectory($caseDir)
            Assert-LffSafeOutputPath $out (Join-Path $caseDir 'definition.json')
            $source = if ($case.source -ceq 'infra/workflow-definition.json') { $Plan.ReceiverDefinition } else { $Plan.LifecycleDefinition }
            $definition = ($source | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
            $kind = if ($case.source -ceq 'infra/workflow-definition.json') { 'receiver' } else { 'lifecycle' }
            $null = Assert-LffKnownDefinition $definition $kind
            $externalNames = @(Convert-LffActions $definition.actions $kind)
            New-LffManualTrigger $definition
            if ($definition.parameters.Contains('$connections')) { $null=$definition.parameters.Remove('$connections') }
            if ($kind -eq 'lifecycle') {
                if ($definition.parameters.Contains('NotificationUrl')) { $null=$definition.parameters.Remove('NotificationUrl') }
                $definition.parameters['FixtureStubCallback']=[ordered]@{type='securestring'}
                $definition.parameters['GraphSubscriptionClientState']=[ordered]@{type='securestring'}
            } else {
                foreach ($unused in @('TargetTeamId','TargetChannelId')) { if ($definition.parameters.Contains($unused)) { $null=$definition.parameters.Remove($unused) } }
            }
            Set-LffStringsInPlace $definition $externalNames ($kind -eq 'lifecycle') ($kind -eq 'receiver')
            $workflowParameters=[ordered]@{GraphSubscriptionClientState='fixture-client-state'}
            if ($kind -eq 'receiver') { $workflowParameters['TargetChannelDisplayName']='Fixture Channel' }
            $unmaterialized=@()
            if ($kind -eq 'lifecycle') { $unmaterialized=@('FixtureStubCallback') }
            Assert-LffParameterBindings $definition $workflowParameters $unmaterialized
            Assert-LffSanitized $definition "$($case.id)/definition.json"
            $defBytes=ConvertTo-LffBytes $definition
            $config=[ordered]@{
                schemaVersion=1; caseId=$case.id; fixtureInput=$case.input; expected=$case.expected
                sourceCommit=$Plan.SourceCommit; sourcePath=$case.source; sourceSha256=$Plan.SourceHashes[$case.source]
                workflowParameters=$workflowParameters
                fixtureStubCallback=[ordered]@{parameter='FixtureStubCallback';type='securestring';materialized=$false;valueIncluded=$false}
                accounting=[ordered]@{outerTriggerInvocations=1; nestedStubTriggerInvocations=[int]$case.expected.fixtureStubTriggers; configuredRetryAttempts=0; inclusiveTriggerCount=(1+[int]$case.expected.fixtureStubTriggers); worstCaseActionActivations=[int]$case.expected.actionActivations}
                budgets=[ordered]@{inclusiveTriggerLimit=[int]$Plan.Profile.budgets.inclusiveTriggerLimit;inputBytes=[int]$case.inputBytes;maxInputBytes=[int]$Plan.Profile.budgets.maxInputBytes;maxLogBytes=[int]$Plan.Profile.budgets.maxLogBytes}
            }
            $configBytes=ConvertTo-LffBytes $config
            $files=[ordered]@{ 'definition.json'=$defBytes; 'configuration.json'=$configBytes }
            if ($kind -eq 'lifecycle') {
                $stub=New-LffStubDefinition
                Assert-LffSanitized $stub "$($case.id)/response-stub-definition.json"
                $files['response-stub-definition.json']=ConvertTo-LffBytes $stub
            }
            $stubRequestBytes=0; $stubResponseBytes=0
            if ($kind -eq 'lifecycle') {
                $lifecycleActions=@(Get-LffActionMap $definition.actions)
                foreach ($actionName in $case.expected.stubActions) {
                    $entry=@($lifecycleActions | Where-Object { $_.name -ceq $actionName -and $_.type -ceq 'Http' })
                    if ($entry.Count -ne 1 -or $entry[0].action.inputs.uri -cne "@parameters('FixtureStubCallback')" -or $entry[0].action.inputs.retryPolicy.type -cne 'none' -or $entry[0].action.Contains('retryPolicy')) { throw "Nested stub binding for '$actionName' is not exact." }
                    $requestBytes=ConvertTo-LffBytes $entry[0].action.inputs.body
                    $stubRequestBytes += $requestBytes.Length
                    $responseBytes=ConvertTo-LffBytes $entry[0].action.inputs.body.fixtureReply.body
                    $stubResponseBytes += $responseBytes.Length
                }
            }
            $casePayloadBytes=[long]$case.inputBytes+$stubRequestBytes+$stubResponseBytes
            $aggregatePayloadBytes += $casePayloadBytes
            $aggregateActionActivations += [int]$case.expected.actionActivations
            $caseAccounting.Add([pscustomobject]@{caseId=$case.id;outerTriggerInvocations=1;nestedStubTriggerInvocations=[int]$case.expected.fixtureStubTriggers;configuredRetryAttempts=0;inclusiveTriggerCount=(1+[int]$case.expected.fixtureStubTriggers);worstCaseActionActivations=[int]$case.expected.actionActivations;outerInputBytes=[int]$case.inputBytes;nestedStubRequestBytes=[int]$stubRequestBytes;nestedStubResponseBytes=[int]$stubResponseBytes;payloadBytes=[int]$casePayloadBytes})
            foreach ($fileName in $files.Keys) {
                $path=Join-Path $caseDir $fileName
                Write-LffCreateNewBytes $out $path $files[$fileName]
                $allFiles["cases/$($case.id)/$fileName"]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        }
        if ($Plan.InclusiveTriggerCount -gt $Plan.Profile.budgets.inclusiveTriggerLimit) { throw 'Inclusive trigger budget exceeded.' }
        if ($aggregatePayloadBytes -gt [long]$Plan.Profile.budgets.maxAggregatePayloadBytes) { throw 'Aggregate outer and nested payload-byte budget exceeded.' }
        if ($aggregateActionActivations -gt [long]$Plan.Profile.budgets.billableActionActivationLimit) { throw 'Conservative potential billable-action activation budget exceeded.' }
        $manifest=[ordered]@{
            schemaVersion=1; profileId=$Plan.Profile.profileId; profileVersion=$Plan.Profile.profileVersion; profileSha256=$Plan.ProfileSha256
            sourceCommit=$Plan.SourceCommit; sourceCheckoutHead=$Plan.SourceCheckoutHead; sourceHashes=$Plan.SourceHashes; generatedFiles=$allFiles
            generatedConfigurationSha256=[ordered]@{}; generatedArtifactTreeSha256=$null
            caseAccounting=@($caseAccounting)
            budget=[ordered]@{outerTriggerInvocations=3;nestedStubTriggerInvocations=2;configuredRetryAttempts=0;inclusiveTriggerTotal=$Plan.InclusiveTriggerCount;inclusiveTriggerLimit=[int]$Plan.Profile.budgets.inclusiveTriggerLimit;worstCaseBillableActionActivations=[int]$aggregateActionActivations;billableActionActivationLimit=[int]$Plan.Profile.budgets.billableActionActivationLimit;aggregatePayloadBytes=[int]$aggregatePayloadBytes;maxInputBytes=[int]$Plan.Profile.budgets.maxInputBytes;maxAggregatePayloadBytes=[int]$Plan.Profile.budgets.maxAggregatePayloadBytes;maxLogBytes=[int]$Plan.Profile.budgets.maxLogBytes;billableActionAssumption=$Plan.Profile.accounting.billableActionAssumption;approval='proposal-only';liveRuntimeEnforcement='not-implemented-M2-gate'}
            dependencies=[ordered]@{Graph=$false;Teams=$false;managedIdentity=$false;externalProviderCalls=$false;fixtureStubHttpRequired=$true;runtimeNetwork='fixture-stub-only-if-approved'}
            resourceSemantics=$Plan.Profile.resourceSemantics
            lifecycleOutcomeSemantics=$Plan.Profile.lifecycleOutcomeSemantics
        }
        foreach ($entry in $allFiles.GetEnumerator()) { if ($entry.Key -like '*/configuration.json') { $manifest.generatedConfigurationSha256[$entry.Key]=$entry.Value } }
        $treeText=(@($allFiles.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
        $manifest.generatedArtifactTreeSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($treeText)))
        $manifestBytes=ConvertTo-LffBytes $manifest
        Write-LffCreateNewBytes $out (Join-Path $out 'manifest.json') $manifestBytes
        return [pscustomobject]@{ outputDirectory=$out; manifestSha256=(Get-FileHash (Join-Path $out 'manifest.json') -Algorithm SHA256).Hash; generatedFileCount=$allFiles.Count; inclusiveTriggerTotal=$Plan.InclusiveTriggerCount; localOnly=$true }
    } catch {
        # Preserve a partially written output; an uncertain artifact is never overwritten.
        throw
    }
}

function New-HealthFixtureLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    return [pscustomobject]@{
        SchemaVersion=1; TriggerLimit=[int]$Plan.Profile.budgets.inclusiveTriggerLimit
        InputByteLimit=[long]$Plan.Profile.budgets.maxInputBytes; LogByteLimit=[long]$Plan.Profile.budgets.maxLogBytes
        ActionActivationLimit=[int]$Plan.Profile.budgets.billableActionActivationLimit
        EventLimit=[int]$Plan.Profile.budgets.maxEvents; Events=[Collections.Generic.List[object]]::new()
        Seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        RetryNext=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
        TriggerCount=0; InputBytes=[long]0; LogBytes=[long]0; ActionActivations=0; RetryAttempts=0
    }
}

function Add-HealthFixtureActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._:-]{1,100}$')][string]$EventId,
        [Parameter(Mandatory)][ValidateSet('outer-trigger','nested-stub-trigger','retry-attempt','action-activation','input-bytes','log-bytes')][string]$Category,
        [Parameter(Mandatory)][ValidateRange(0,104857600)][long]$Amount,
        [string]$OperationId,
        [int]$Attempt
    )
    if ($Ledger.Events.Count -ge $Ledger.EventLimit) { throw 'Fixture event ledger limit exceeded.' }
    if (-not $Ledger.Seen.Add($EventId)) { throw 'Duplicate activity event refused; events cannot be double counted.' }
    if ($Category -eq 'retry-attempt') {
        if ($Amount -ne 1) { throw 'Each retry event records exactly one attempt.' }
        if ([string]::IsNullOrWhiteSpace($OperationId) -or $OperationId.Length -gt 100 -or $Attempt -lt 1) { throw 'Retry events require a bounded operation ID and positive attempt number.' }
        $expected = if ($Ledger.RetryNext.ContainsKey($OperationId)) { $Ledger.RetryNext[$OperationId] } else { 1 }
        if ($Attempt -ne $expected) { throw 'Retry attempts must be recorded once and in order.' }
        $Ledger.RetryNext[$OperationId] = $Attempt + 1
        $Ledger.RetryAttempts++
        $Ledger.TriggerCount++
    } elseif ($Category -in @('outer-trigger','nested-stub-trigger')) {
        if ($Amount -ne 1) { throw 'A trigger event records exactly one invocation.' }
        $Ledger.TriggerCount++
    } elseif ($Category -eq 'action-activation') { $Ledger.ActionActivations += [int]$Amount }
    elseif ($Category -eq 'input-bytes') { $Ledger.InputBytes += $Amount }
    elseif ($Category -eq 'log-bytes') { $Ledger.LogBytes += $Amount }
    if ($Ledger.TriggerCount -gt $Ledger.TriggerLimit -or $Ledger.InputBytes -gt $Ledger.InputByteLimit -or $Ledger.LogBytes -gt $Ledger.LogByteLimit -or $Ledger.ActionActivations -gt $Ledger.ActionActivationLimit) {
        throw 'Fixture activity budget exceeded; no activity is silently dropped.'
    }
    $Ledger.Events.Add([pscustomobject]@{ eventId=$EventId; category=$Category; amount=$Amount; operationId=$OperationId; attempt=if($Category -eq 'retry-attempt'){$Attempt}else{$null} })
    return [pscustomobject]@{ triggerCount=$Ledger.TriggerCount; inputBytes=$Ledger.InputBytes; logBytes=$Ledger.LogBytes; retryAttempts=$Ledger.RetryAttempts; actionActivations=$Ledger.ActionActivations; eventCount=$Ledger.Events.Count }
}

Export-ModuleMember -Function Get-HealthFixturePlan, Export-HealthLogicFixture, New-HealthFixtureLedger, Add-HealthFixtureActivity, Test-HealthFixtureTriggerBudget, Resolve-HealthFixtureLifecycleOutcome, Test-HealthFixtureSourcePins
