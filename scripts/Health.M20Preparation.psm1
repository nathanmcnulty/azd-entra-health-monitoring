#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:M20Budgets=@{}

function Get-HealthM20Plan {
    [CmdletBinding()]
    param()
    [pscustomobject][ordered]@{
        planVersion='0.1.0';mode='offline-preparation';transport='fixed-in-process-fake'
        workflowAliases=@('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create','response-stub')
        plannedInclusiveTriggers=5;plannedActionActivations=32;configuredRetries=0
        requestBudget=[ordered]@{admission=300;recoveryReserve=200;total=500}
        recoveryTimeReserveSeconds=1800;targetLifetimeSeconds=7200
        capabilityKind='identity-free-workflows-with-secret-callback-capabilities'
        nativeQualified=$false;executionAuthorized=$false;publicationAuthorized=$false
        liveBlockers=@('native-ownership-continuity-unproved','secure-callback-provider-correlation-unimplemented','exact-live-source-artifact-not-approved','operator-inbound-controls-unverified','current-cost-credit-liability-unverified')
    }
}

function New-HealthM20Budget {
    [CmdletBinding()]
    param([ValidateRange(0,300)][int]$Admission=300,[ValidateRange(0,200)][int]$Recovery=200)
    # Tokens are process-local simulation state; not a durable/global admission service.
    $start=[DateTimeOffset]::UtcNow
    if($script:M20Budgets.Count -ge 128){throw 'Simulation attempt storage full.'}
    $id=[guid]::NewGuid().ToString('N')
    $script:M20Budgets[$id]=@{AdmissionRemaining=$Admission;RecoveryRemaining=$Recovery;Dispatches=0;Frozen=$false;StartedAt=$start;AdmissionDeadline=$start.AddSeconds(5400);RecoveryDeadline=$start.AddSeconds(7200);LastObservedAt=$start;WriteIntents=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);InclusiveTriggers=0;ActionActivations=0;PayloadBytes=0L;LogBytes=0L;WorkloadEvents=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)}
    return @{BudgetId=$id}
}

function Get-M20BudgetState([hashtable]$Handle){
    if($Handle.Count -ne 1 -or -not $Handle.ContainsKey('BudgetId') -or $Handle.BudgetId -isnot [string] -or -not $script:M20Budgets.ContainsKey($Handle.BudgetId)){throw 'Invalid simulation budget handle.'}
    return $script:M20Budgets[$Handle.BudgetId]
}

function Get-HealthM20BudgetStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Budget)
    $state=Get-M20BudgetState $Budget
    # Return a detached scalar snapshot; no ledger/set references escape.
    [pscustomobject]@{AdmissionRemaining=$state.AdmissionRemaining;RecoveryRemaining=$state.RecoveryRemaining;Dispatches=$state.Dispatches;Frozen=$state.Frozen;StartedAt=$state.StartedAt;AdmissionDeadline=$state.AdmissionDeadline;RecoveryDeadline=$state.RecoveryDeadline;InclusiveTriggers=$state.InclusiveTriggers;ActionActivations=$state.ActionActivations}
}

function Test-M20ClosedMap($Value,[string[]]$Keys) {
    if($Value -isnot [Collections.IDictionary]){throw 'Invalid observation shape.'}
    if(@($Value.Keys).Count -ne $Keys.Count){throw 'Invalid observation shape.'}
    foreach($key in $Value.Keys){if($key -cnotin $Keys){throw 'Invalid observation shape.'}}
    foreach($key in $Keys){if(-not $Value.Contains($key)){throw 'Invalid observation shape.'}}
}

function Invoke-HealthM20FakeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Budget,
        [Parameter(Mandatory)][ValidateSet('target-read','group-create','inventory','deploy','payload-read','callback-read','callback-bind','enable','invoke','run-read','disable','cancel','delete','absence-read', IgnoreCase=$false)][string]$Operation,
        [ValidateSet('success','unknown','before-dispatch-fault', IgnoreCase=$false)][string]$Outcome='success',
        [bool]$CostFresh=$true,[bool]$TargetValid=$true,[bool]$ScopeValid=$true,
        [bool]$ModeledOwnership=$true,[bool]$RecoveryAuthorized=$true,
        [ValidateSet('Admission','Recovery', IgnoreCase=$false)][string]$Phase='Admission',
        [ValidateSet('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create', IgnoreCase=$false)][string]$WorkflowAlias='lifecycle-create',
        [DateTimeOffset]$Now=[DateTimeOffset]::UtcNow
    )
    $handle=$Budget
    $Budget=Get-M20BudgetState $handle
    if($Budget.AdmissionRemaining -lt 0 -or $Budget.AdmissionRemaining -gt 300 -or $Budget.RecoveryRemaining -lt 0 -or $Budget.RecoveryRemaining -gt 200 -or $Budget.Dispatches -ge 500){throw 'Invalid or exhausted attempt budget.'}
    if($Budget.AdmissionDeadline -ne $Budget.StartedAt.AddSeconds(5400) -or $Budget.RecoveryDeadline -ne $Budget.StartedAt.AddSeconds(7200) -or $Now -lt $Budget.LastObservedAt){throw 'Attempt deadline or clock changed.'}
    $Budget.LastObservedAt=$Now
    $recovery=$Operation -cin @('disable','cancel','delete','absence-read') -or ($Phase -eq 'Recovery' -and $Operation -cin @('target-read','inventory','run-read'))
    if($Phase -eq 'Recovery' -and -not $recovery){throw 'Operation cannot borrow recovery reserve.'}
    $spend=$Operation -cin @('group-create','deploy','callback-bind','enable','invoke')
    # No secret response/body, URL or exception text exists in this transport.
    if(-not $TargetValid -or -not $ScopeValid){return [pscustomobject]@{operation=$Operation;outcome='blocked-target-scope';dispatched=$false;secretBodyRetained=$false}}
    $deadline=if($recovery){$Budget.RecoveryDeadline}else{$Budget.AdmissionDeadline}
    if($Now -gt $deadline){return [pscustomobject]@{operation=$Operation;outcome='deadline-exhausted';dispatched=$false;secretBodyRetained=$false}}
    if($recovery -and (-not $ModeledOwnership -or -not $RecoveryAuthorized)){return [pscustomobject]@{operation=$Operation;outcome='blocked-recovery-authority';dispatched=$false;secretBodyRetained=$false}}
    if(-not $recovery -and ($Budget.Frozen -or ($spend -and -not $CostFresh))){return [pscustomobject]@{operation=$Operation;outcome='blocked-new-work';dispatched=$false;secretBodyRetained=$false}}
    $key=if($recovery){'RecoveryRemaining'}else{'AdmissionRemaining'}
    if($Budget[$key] -le 0){return [pscustomobject]@{operation=$Operation;outcome='exhausted';dispatched=$false;secretBodyRetained=$false}}
    if($Outcome -eq 'before-dispatch-fault'){$Budget.Frozen=$true;return [pscustomobject]@{operation=$Operation;outcome='interrupted-before-dispatch';dispatched=$false;secretBodyRetained=$false}}
    $write=$Operation -cin @('group-create','deploy','callback-read','callback-bind','enable','invoke','disable','cancel','delete')
    $intent=if($Operation -eq 'invoke'){$Operation+'-'+$WorkflowAlias}else{$Operation}
    if($write -and $Budget.WriteIntents.Contains($intent)){return [pscustomobject]@{operation=$Operation;outcome='write-replay-refused';dispatched=$false;secretBodyRetained=$false}}
    if($Operation -eq 'invoke'){
        $nested=if($WorkflowAlias -eq 'lifecycle-create'){2}else{0}
        $actions=if($WorkflowAlias -eq 'receiver-duplicate-batch'){14}else{9}
        Register-HealthM20WorkloadEvent -Budget $handle -EventId $intent -Outer 1 -Nested $nested -Actions $actions -PayloadBytes 1024 -LogBytes 2048 -Now $Now
    }
    if($write){$null=$Budget.WriteIntents.Add($intent)}
    # Invoke represents a callback capability request, not an ARM management call.
    if($Operation -ne 'invoke'){$Budget[$key]--; $Budget.Dispatches++}
    if($Outcome -eq 'unknown'){$Budget.Frozen=$true}
    [pscustomobject][ordered]@{operation=$Operation;outcome=$Outcome;dispatched=$true;secretBodyRetained=$false}
}

function Register-HealthM20WorkloadEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Budget,[Parameter(Mandatory)][ValidatePattern('\A[a-z0-9-]{1,64}\z', Options=[Text.RegularExpressions.RegexOptions]::None)][string]$EventId,[ValidateRange(0,20)][int]$Outer=0,[ValidateRange(0,20)][int]$Nested=0,[ValidateRange(0,20)][int]$Retries=0,[ValidateRange(0,40)][int]$Actions=0,[ValidateRange(0,10485760)][long]$PayloadBytes=0,[ValidateRange(0,104857600)][long]$LogBytes=0,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    $Budget=Get-M20BudgetState $Budget
    if($Now -lt $Budget.LastObservedAt -or $Now -gt $Budget.AdmissionDeadline){throw 'Workload deadline exhausted or clock rewound.'}
    $Budget.LastObservedAt=$Now
    if($Budget.Frozen -or $Budget.WorkloadEvents.Contains($EventId)){throw 'Workload frozen or event duplicated.'}
    $triggers=$Budget.InclusiveTriggers+$Outer+$Nested+$Retries
    if($triggers -gt 20 -or $Budget.ActionActivations+$Actions -gt 40 -or $Budget.PayloadBytes+$PayloadBytes -gt 10485760 -or $Budget.LogBytes+$LogBytes -gt 104857600){$Budget.Frozen=$true;throw 'Workload bound exceeded.'}
    $null=$Budget.WorkloadEvents.Add($EventId);$Budget.InclusiveTriggers=$triggers;$Budget.ActionActivations+=$Actions;$Budget.PayloadBytes+=$PayloadBytes;$Budget.LogBytes+=$LogBytes
}

function Test-HealthM20OwnershipModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Facts)
    $keys=@('durableIntent','exclusiveWriter','createAcknowledged','responseCorrelated','ledgerIntact','continuityObserved','groupAppearedBeforePut','sameArmIdRecreated')
    Test-M20ClosedMap $Facts $keys
    foreach($key in $keys){if($Facts[$key] -isnot [bool]){throw 'Ownership facts must be Boolean.'}}
    $passed=$Facts.durableIntent -and $Facts.exclusiveWriter -and $Facts.createAcknowledged -and $Facts.responseCorrelated -and $Facts.ledgerIntact -and $Facts.continuityObserved -and -not $Facts.groupAppearedBeforePut -and -not $Facts.sameArmIdRecreated
    [pscustomobject]@{simulationOwnership=$passed;nativeOwnershipProved=$false;nativeCreateDeleteAllowed=$false;reason='model-only-no-immutable-Azure-incarnation-proof'}
}

function Test-HealthM20OracleModel {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Facts)
    $keys=@('expectedAttempt','observedAttempt','expectedCase','observedCase','parentRun','actionParentRun','expectedStubRun','observedStubRun','requestCorrelation','stubCorrelation','bindingObserved','oracleObserved','redacted','listWasEmpty','createBranchObserved','fixedReplyObserved')
    Test-M20ClosedMap $Facts $keys
    foreach($key in @('bindingObserved','oracleObserved','redacted','listWasEmpty','createBranchObserved','fixedReplyObserved')){if($Facts[$key] -isnot [bool]){throw 'Oracle facts have invalid types.'}}
    foreach($key in $keys|Where-Object{$_ -notin @('bindingObserved','oracleObserved','redacted','listWasEmpty','createBranchObserved','fixedReplyObserved')}){
        if($Facts[$key] -isnot [string] -or $Facts[$key] -cnotmatch '\A[a-z0-9-]{1,64}\z'){throw 'Invalid bounded correlation identifier.'}
    }
    $match=$Facts.expectedAttempt -ceq $Facts.observedAttempt -and $Facts.expectedCase -ceq $Facts.observedCase -and $Facts.parentRun -ceq $Facts.actionParentRun -and $Facts.expectedStubRun -ceq $Facts.observedStubRun -and $Facts.requestCorrelation -ceq $Facts.stubCorrelation
    $observed=$Facts.bindingObserved -and $Facts.oracleObserved -and -not $Facts.redacted
    [pscustomobject]@{simulationOraclePassed=($match -and $observed -and $Facts.listWasEmpty -and $Facts.createBranchObserved -and $Facts.fixedReplyObserved);nativeOracleObserved=$false;unobserved=(-not $observed);reason='proposed-nonsecret-protocol-not-present-in-M1-artifacts'}
}

function Invoke-HealthM20Simulation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('normal','create-race','create-response-lost','ledger-lost','recreated','wrong-stub','swapped-run','missing-correlation','redacted-oracle','billing-unavailable','admission-exhausted','recovery-exhausted','before-disable','before-cancel','before-delete','before-absence','unknown-delete','unknown-invoke', IgnoreCase=$false)][string]$Scenario)
    $admission=if($Scenario -eq 'admission-exhausted'){0}else{300}
    $recovery=if($Scenario -eq 'recovery-exhausted'){0}else{200}
    $budget=New-HealthM20Budget -Admission $admission -Recovery $recovery
    $own=@{durableIntent=$true;exclusiveWriter=$true;createAcknowledged=$true;responseCorrelated=$true;ledgerIntact=$true;continuityObserved=$true;groupAppearedBeforePut=$false;sameArmIdRecreated=$false}
    switch($Scenario){
        'create-race'{$own.groupAppearedBeforePut=$true}
        'create-response-lost'{$own.createAcknowledged=$false}
        'ledger-lost'{$own.ledgerIntact=$false}
        'recreated'{$own.sameArmIdRecreated=$true}
    }
    $ownership=Test-HealthM20OwnershipModel $own
    $oracle=@{expectedAttempt='attempt-one';observedAttempt='attempt-one';expectedCase='lifecycle-create';observedCase='lifecycle-create';parentRun='parent-one';actionParentRun='parent-one';expectedStubRun='stub-one';observedStubRun='stub-one';requestCorrelation='request-one';stubCorrelation='request-one';bindingObserved=$true;oracleObserved=$true;redacted=$false;listWasEmpty=$true;createBranchObserved=$true;fixedReplyObserved=$true}
    switch($Scenario){
        'wrong-stub'{$oracle.observedStubRun='stub-wrong'}
        'swapped-run'{$oracle.actionParentRun='parent-wrong'}
        'missing-correlation'{$oracle.bindingObserved=$false}
        'redacted-oracle'{$oracle.redacted=$true}
    }
    $observed=Test-HealthM20OracleModel $oracle
    $requests=[Collections.Generic.List[object]]::new()
    $costFresh=$Scenario -cne 'billing-unavailable'
    $deploymentPassed=$false;$payloadPassed=$false;$functionPassed=$false
    if($ownership.simulationOwnership){
        $deploy=Invoke-HealthM20FakeRequest -Budget $budget -Operation deploy -CostFresh $costFresh
        $requests.Add($deploy);$deploymentPassed=$deploy.outcome -ceq 'success'
        if($deploymentPassed){
            $payload=Invoke-HealthM20FakeRequest -Budget $budget -Operation payload-read
            $requests.Add($payload);$payloadPassed=$payload.outcome -ceq 'success'
            $invokeOutcome=if($Scenario -eq 'unknown-invoke'){'unknown'}else{'success'}
            $functionPassed=$observed.simulationOraclePassed
            foreach($alias in @('receiver-duplicate-batch','receiver-mismatched-state','lifecycle-create')){
                $invoke=Invoke-HealthM20FakeRequest -Budget $budget -Operation invoke -WorkflowAlias $alias -Outcome $invokeOutcome
                $requests.Add($invoke)
                if($invoke.outcome -cne 'success'){$functionPassed=$false;break}
            }
        }
    }
    $deleteResult='not-dispatched';$absenceObserved=$false;$quiescent=$Scenario -cne 'unknown-invoke'
    if($ownership.simulationOwnership){
        foreach($op in @('disable','cancel','delete','absence-read')){
            if($op -eq 'cancel' -and $Scenario -eq 'unknown-invoke'){break}
            if($op -in @('delete','absence-read') -and -not $quiescent){break}
            $fault=($Scenario -ceq ('before-'+$(if($op -eq 'absence-read'){'absence'}else{$op})))
            $outcome=if($fault){'before-dispatch-fault'}elseif($op -eq 'delete' -and $Scenario -eq 'unknown-delete'){'unknown'}else{'success'}
            $r=Invoke-HealthM20FakeRequest -Budget $budget -Operation $op -Outcome $outcome -CostFresh $costFresh -ModeledOwnership $ownership.simulationOwnership
            $requests.Add($r)
            if($op -eq 'delete'){$deleteResult=$r.outcome}
            if($op -eq 'absence-read' -and $r.outcome -eq 'success'){$absenceObserved=$true}
            if($r.outcome -notin @('success','unknown')){break}
        }
    }
    $teardownPassed=$deleteResult -ceq 'success' -and $absenceObserved
    $passed=$ownership.simulationOwnership -and $deploymentPassed -and $payloadPassed -and $functionPassed -and $teardownPassed
    $status=Get-HealthM20BudgetStatus $budget
    [pscustomobject][ordered]@{
        simulationVersion='0.1.0';evidenceMode='simulation';scenario=$Scenario
        stages=[ordered]@{'target-context'='model-only';ownership=$ownership.simulationOwnership;deployment=$deploymentPassed;'payload-readback'=$payloadPassed;'intended-function'=$functionPassed;'teardown-operation'=$teardownPassed;'terminal-state'=$absenceObserved}
        modeledOutcome=$(if($passed){'passed'}else{'incomplete'})
        deleteOperationOutcome=$deleteResult;absenceObserved=$absenceObserved
        recoveryEvidence=($deleteResult -ceq 'unknown' -and $absenceObserved)
        remainingLiability=(-not $ownership.simulationOwnership -or -not $absenceObserved)
        requests=@($requests);admissionRemaining=$status.AdmissionRemaining;recoveryRemaining=$status.RecoveryRemaining
        modeledInclusiveTriggers=$status.InclusiveTriggers;modeledActions=$status.ActionActivations
        nativeOwnershipProved=$false;nativeOracleObserved=$false
        nativeQualified=$false;executionAuthorized=$false;publicationAuthorized=$false
    }
}

function Export-HealthM20ObservationPrototype {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDirectory,[ValidateSet('normal','unknown-delete','unknown-invoke','wrong-stub','redacted-oracle', IgnoreCase=$false)][string]$Scenario='normal')
    $out=[IO.Path]::GetFullPath($OutputDirectory)
    if(Test-Path -LiteralPath $out){throw 'Prototype output must be new.'}
    $ancestor=Get-Item -LiteralPath (Split-Path $out -Parent)
    while($null -ne $ancestor){if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked output ancestry refused.'};$ancestor=$ancestor.Parent}
    $simulation=Invoke-HealthM20Simulation -Scenario $Scenario
    New-Item -ItemType Directory -Path $out -ErrorAction Stop|Out-Null
    function Write-PrototypeContent($Name,[byte[]]$Bytes){$s=[IO.File]::Open((Join-Path $out $Name),[IO.FileMode]::CreateNew);try{$s.Write($Bytes)}finally{$s.Dispose()};[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
    function Write-PrototypeJson($Name,$Value){Write-PrototypeContent $Name ([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 25 -Compress)))}
    $repo=Split-Path $PSScriptRoot -Parent
    $generated=Get-Content (Join-Path $repo 'validation/m20-generated/manifest.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
    $bindings=[ordered]@{}
    $bindings.source=Write-PrototypeJson 'source.json' @{transformationInput=$generated.sourceCommit;generationCheckout=$generated.sourceCheckoutHead;sourceHashes=$generated.sourceHashes}
    $bindings.orchestration=Write-PrototypeContent 'orchestration.bin' ([IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Health.M20Preparation.psm1')))
    $bindings.artifact=Write-PrototypeContent 'artifact.json' ([IO.File]::ReadAllBytes((Join-Path $repo 'validation/m20-generated/manifest.json')))
    $bindings.configuration=Write-PrototypeJson 'configuration.json' $generated.generatedConfigurationSha256
    $bindings.profile=Write-PrototypeContent 'profile.json' ([IO.File]::ReadAllBytes((Join-Path $repo 'validation/profiles/health-logic-fixture.v1.json')))
    $bindings.lock=Write-PrototypeContent 'lock.json' ([IO.File]::ReadAllBytes((Join-Path $repo 'azd-components.lock.json')))
    $bindings.target=Write-PrototypeJson 'target.json' @{kind='simulation-only';liveTargetSelected=$false}
    $record=[ordered]@{schemaVersion='0.1.0';recordType='azdNativeLifecycleObservationCandidate';evidenceMode='simulation';attemptId=[guid]::NewGuid().ToString();createdAt=[DateTimeOffset]::UtcNow.AddSeconds(-1).UtcDateTime.ToString('o');bindings=$bindings;stages=@();nativeQualified=$false;executionAuthorized=$false;publicationAuthorized=$false}
    foreach($id in @('target-context','ownership','deployment','payload-readback','intended-function','teardown-operation','terminal-state')){
        # First five stages have no supported typed provider-proof protocol yet.
        $facts=[ordered]@{stageId=$id;attemptId=$record.attemptId;bindings=$bindings;observedAt=[DateTimeOffset]::UtcNow.UtcDateTime.ToString('o');observationComplete=$false;result='unobserved'}
        if($id -eq 'teardown-operation'){
            $dispatch=@($simulation.requests|Where-Object operation -ceq 'delete')
            $known=$dispatch.Count -eq 1 -and $dispatch[0].dispatched
            $received=$known -and $dispatch[0].outcome -ceq 'success'
            $facts.observationComplete=$known;$facts.result=if($received){'pass'}elseif($known){'unknown'}else{'unobserved'}
            $facts.operationFacts=@{intentRecorded=[bool]$known;dispatchCount=$(if($known){1}else{0});responseReceived=[bool]$received;responseStatus=$(if($received){202}else{0});processExited=$true;processExitCode=0}
        }
        if($id -eq 'terminal-state'){$facts.observationComplete=$simulation.absenceObserved;$facts.result=if($simulation.absenceObserved){'pass'}else{'unobserved'};$facts.terminalFacts=@{observationComplete=$simulation.absenceObserved;absent=$simulation.absenceObserved}}
        $name=$id+'.json';$sha=Write-PrototypeJson $name $facts
        $record.stages+=@{stageId=$id;evidence=@{kind='non-secret';path=$name;sha256=$sha}}
    }
    $null=Write-PrototypeJson 'record.json' $record
    [pscustomobject]@{recordPath=(Join-Path $out 'record.json');evidenceRoot=$out;bindingFiles=@{source='source.json';orchestration='orchestration.bin';artifact='artifact.json';configuration='configuration.json';profile='profile.json';lock='lock.json';target='target.json'};evidenceMode='simulation';nativeQualified=$false}
}

Export-ModuleMember -Function Get-HealthM20Plan,New-HealthM20Budget,Get-HealthM20BudgetStatus,Invoke-HealthM20FakeRequest,Register-HealthM20WorkloadEvent,Test-HealthM20OwnershipModel,Test-HealthM20OracleModel,Invoke-HealthM20Simulation,Export-HealthM20ObservationPrototype
