BeforeAll {
    $script:repo=Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repo 'scripts/Health.M20Preparation.psm1') -Force
    function New-OwnershipFacts { @{durableIntent=$true;exclusiveWriter=$true;createAcknowledged=$true;responseCorrelated=$true;ledgerIntact=$true;continuityObserved=$true;groupAppearedBeforePut=$false;sameArmIdRecreated=$false} }
}
Describe 'M2.0 disabled plan and fake controller' {
    It 'has no live mode and never claims native authority' {
        $plan=Get-HealthM20Plan
        $plan.transport|Should -BeExactly fixed-in-process-fake
        $plan.nativeQualified|Should -BeFalse;$plan.executionAuthorized|Should -BeFalse
        $plan.workflowAliases.Count|Should -Be 4
        $plan.requestBudget.total|Should -Be 500
        $command=Get-Command (Join-Path $script:repo 'scripts/Get-M20Preparation.ps1')
        $command.Parameters.Keys|Should -Not -Contain Execute
    }
    It 'runs each fixed fault scenario only through the local fake' -TestCases @(
        @{Scenario='normal'},@{Scenario='create-race'},@{Scenario='create-response-lost'},@{Scenario='ledger-lost'},@{Scenario='recreated'},@{Scenario='wrong-stub'},@{Scenario='swapped-run'},@{Scenario='missing-correlation'},@{Scenario='redacted-oracle'},@{Scenario='billing-unavailable'},@{Scenario='admission-exhausted'},@{Scenario='recovery-exhausted'},@{Scenario='before-disable'},@{Scenario='before-cancel'},@{Scenario='before-delete'},@{Scenario='before-absence'},@{Scenario='unknown-delete'},@{Scenario='unknown-invoke'}
    ) {
        param($Scenario)
        $r=Invoke-HealthM20Simulation -Scenario $Scenario
        $r.nativeQualified|Should -BeFalse;$r.executionAuthorized|Should -BeFalse;$r.publicationAuthorized|Should -BeFalse
        $r.evidenceMode|Should -BeExactly simulation
        if($Scenario -eq 'normal'){$r.modeledOutcome|Should -BeExactly passed;$r.modeledInclusiveTriggers|Should -Be 5;$r.modeledActions|Should -Be 32}else{$r.modeledOutcome|Should -BeExactly incomplete}
    }
    It 'rejects unknown ownership from races, missing receipts, ledger loss and recreation' -TestCases @(@{Field='groupAppearedBeforePut';Value=$true},@{Field='createAcknowledged';Value=$false},@{Field='ledgerIntact';Value=$false},@{Field='sameArmIdRecreated';Value=$true},@{Field='continuityObserved';Value=$false},@{Field='exclusiveWriter';Value=$false}) {
        param($Field,$Value)
        $f=New-OwnershipFacts;$f[$Field]=$Value;$r=Test-HealthM20OwnershipModel $f
        $r.simulationOwnership|Should -BeFalse;$r.nativeOwnershipProved|Should -BeFalse;$r.nativeCreateDeleteAllowed|Should -BeFalse
    }
    It 'does not accept secret fields or arbitrary correlation values' {
        $f=New-OwnershipFacts;$f.callback='secret-canary-value'
        {Test-HealthM20OwnershipModel $f}|Should -Throw
        try{Test-HealthM20OwnershipModel $f}catch{$_.Exception.Message|Should -Not -Match secret-canary-value}
        (Invoke-HealthM20Simulation -Scenario redacted-oracle).modeledOutcome|Should -BeExactly incomplete
    }
    It 'allows reserved recovery when billing is unavailable without admitting new spend' {
        $b=New-HealthM20Budget
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy -CostFresh $false).dispatched|Should -BeFalse
        (Invoke-HealthM20FakeRequest -Budget $b -Operation disable -CostFresh $false).dispatched|Should -BeTrue
        $s=Get-HealthM20BudgetStatus $b;$s.AdmissionRemaining|Should -Be 300;$s.RecoveryRemaining|Should -Be 199
    }
    It 'cannot borrow the recovery pool for new spend or reset an immutable deadline' {
        $b=New-HealthM20Budget -Admission 0
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy).outcome|Should -BeExactly exhausted
        {Invoke-HealthM20FakeRequest -Budget $b -Operation deploy -Phase Recovery}|Should -Throw
        (Get-HealthM20BudgetStatus $b).RecoveryRemaining|Should -Be 200
        $b.RecoveryDeadline=[DateTimeOffset]::UtcNow.AddDays(1)
        {Invoke-HealthM20FakeRequest -Budget $b -Operation disable}|Should -Throw
    }
    It 'charges every management dispatch including unknown response and refuses write replay' {
        $b=New-HealthM20Budget
        $first=Invoke-HealthM20FakeRequest -Budget $b -Operation delete -Outcome unknown
        $again=Invoke-HealthM20FakeRequest -Budget $b -Operation delete
        $first.dispatched|Should -BeTrue;$again.outcome|Should -BeExactly write-replay-refused
        (Get-HealthM20BudgetStatus $b).RecoveryRemaining|Should -Be 199
        (Invoke-HealthM20FakeRequest -Budget $b -Operation absence-read).dispatched|Should -BeTrue
        (Get-HealthM20BudgetStatus $b).RecoveryRemaining|Should -Be 198
    }
    It 'keeps authority and exact target checks mandatory even for recovery' -TestCases @(@{Which='target'},@{Which='scope'},@{Which='ownership'},@{Which='approval'}) {
        param($Which)
        $a=@{Budget=(New-HealthM20Budget);Operation='disable'}
        switch($Which){target{$a.TargetValid=$false};scope{$a.ScopeValid=$false};ownership{$a.ModeledOwnership=$false};approval{$a.RecoveryAuthorized=$false}}
        (Invoke-HealthM20FakeRequest @a).dispatched|Should -BeFalse
    }
    It 'stops at the attempt deadline without erasing liability or growing the reserve' {
        $b=New-HealthM20Budget
        $s=Get-HealthM20BudgetStatus $b
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy -Now $s.AdmissionDeadline.AddSeconds(1)).dispatched|Should -BeFalse
        (Invoke-HealthM20FakeRequest -Budget $b -Operation disable -Now $s.RecoveryDeadline.AddSeconds(1)).outcome|Should -BeExactly deadline-exhausted
        (Get-HealthM20BudgetStatus $b).RecoveryRemaining|Should -Be 200
    }
    It 'keeps unknown delete plus later absence incomplete with recovery evidence' {
        $r=Invoke-HealthM20Simulation -Scenario unknown-delete
        $r.absenceObserved|Should -BeTrue;$r.recoveryEvidence|Should -BeTrue;$r.modeledOutcome|Should -BeExactly incomplete
        @($r.requests|Where-Object operation -eq delete).Count|Should -Be 1
    }
    It 'never guesses a run ID or deletes after an uncertain invocation' {
        $r=Invoke-HealthM20Simulation -Scenario unknown-invoke
        @($r.requests|Where-Object operation -eq delete).Count|Should -Be 0
        @($r.requests|Where-Object operation -eq cancel).Count|Should -Be 0
        $r.remainingLiability|Should -BeTrue
    }
    It 'counts nested/retry work and refuses duplicate or excessive workload events' {
        $b=New-HealthM20Budget
        Register-HealthM20WorkloadEvent -Budget $b -EventId batch-one -Outer 3 -Nested 2 -Retries 1 -Actions 32
        (Get-HealthM20BudgetStatus $b).InclusiveTriggers|Should -Be 6
        {Register-HealthM20WorkloadEvent -Budget $b -EventId batch-one -Outer 1}|Should -Throw
        {Register-HealthM20WorkloadEvent -Budget $b -EventId excess -Nested 15}|Should -Throw
        (Get-HealthM20BudgetStatus $b).Frozen|Should -BeTrue
    }
    It 'does not let a detached snapshot refill tokens, clear intents or shift deadlines' {
        $b=New-HealthM20Budget -Admission 0
        $s=Get-HealthM20BudgetStatus $b;$s.AdmissionRemaining=300;$s.StartedAt=$s.StartedAt.AddDays(1);$s.AdmissionDeadline=$s.AdmissionDeadline.AddDays(1)
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy).outcome|Should -BeExactly exhausted
        (Get-HealthM20BudgetStatus $b).AdmissionRemaining|Should -Be 0
    }
    It 'reserves workload before a callback dispatch and refuses exhausted work or deadline' {
        $b=New-HealthM20Budget
        Register-HealthM20WorkloadEvent -Budget $b -EventId already-reserved -Outer 20
        {Invoke-HealthM20FakeRequest -Budget $b -Operation invoke}|Should -Throw
        $b=New-HealthM20Budget;$s=Get-HealthM20BudgetStatus $b
        {Register-HealthM20WorkloadEvent -Budget $b -EventId late -Outer 1 -Now $s.AdmissionDeadline.AddSeconds(1)}|Should -Throw
        (Get-HealthM20BudgetStatus $b).InclusiveTriggers|Should -Be 0
    }
    It 'exports actual bound bytes with the first five stages unobserved' {
        $p=Export-HealthM20ObservationPrototype -OutputDirectory (Join-Path $TestDrive 'observation')
        $r=Get-Content $p.recordPath -Raw|ConvertFrom-Json -AsHashtable -DateKind String
        $r.evidenceMode|Should -BeExactly simulation;$r.stages.Count|Should -Be 7
        foreach($key in $p.bindingFiles.Keys){(Get-FileHash (Join-Path $p.evidenceRoot $p.bindingFiles[$key]) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $r.bindings[$key]}
        foreach($stage in $r.stages|Select-Object -First 5){$facts=Get-Content (Join-Path $p.evidenceRoot $stage.evidence.path) -Raw|ConvertFrom-Json -AsHashtable -DateKind String;$facts.observationComplete|Should -BeFalse;$facts.result|Should -BeExactly unobserved}
        {Export-HealthM20ObservationPrototype -OutputDirectory $p.evidenceRoot}|Should -Throw
    }
    It 'verifies all frozen artifact bytes against the generated manifest' {
        $root=Join-Path $script:repo 'validation/m20-generated'
        $m=Get-Content (Join-Path $root 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable -DateKind String
        $m.generatedFiles.Count|Should -Be 7
        foreach($key in $m.generatedFiles.Keys){(Get-FileHash (Join-Path $root $key) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $m.generatedFiles[$key].ToLowerInvariant()}
        $m.budget.inclusiveTriggerTotal|Should -Be 5
    }
    It 'has no network, authentication, process-launch or live CLI transport path' {
        $source=Get-Content (Join-Path $script:repo 'scripts/Health.M20Preparation.psm1') -Raw
        $source|Should -Not -Match 'Invoke-RestMethod|Invoke-WebRequest|HttpClient|Start-Process|ProcessStartInfo|Connect-Az|Connect-Mg|az login|gh auth'
        $r=Invoke-HealthM20Simulation -Scenario normal
        ($r|ConvertTo-Json -Depth 15)|Should -Not -Match 'https?://|[?&]sig=|secret-canary'
    }
    It 'enforces the exact 300 plus 200 management-request boundary attempt-wide' {
        $b=New-HealthM20Budget
        for($i=0;$i -lt 300;$i++){Invoke-HealthM20FakeRequest -Budget $b -Operation target-read|Out-Null}
        for($i=0;$i -lt 200;$i++){Invoke-HealthM20FakeRequest -Budget $b -Operation run-read -Phase Recovery|Out-Null}
        $s=Get-HealthM20BudgetStatus $b;$s.Dispatches|Should -Be 500;$s.AdmissionRemaining|Should -Be 0;$s.RecoveryRemaining|Should -Be 0
        {Invoke-HealthM20FakeRequest -Budget $b -Operation absence-read}|Should -Throw
        (Get-HealthM20BudgetStatus $b).Dispatches|Should -Be 500
    }
    It 'matches the fixed operation parameter enum to the planned allowlist' {
        $m=Get-Content (Join-Path $script:repo 'validation/m20-operation-allowlist.v1.json') -Raw|ConvertFrom-Json
        $values=@((Get-Command Invoke-HealthM20FakeRequest).Parameters.Operation.Attributes|Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]})[0].ValidValues
        @(Compare-Object @($m.operations.id) @($values)).Count|Should -Be 0
        $m.liveEnabled|Should -BeFalse
    }
}
