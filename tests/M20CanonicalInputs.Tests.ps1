BeforeAll {
    $script:repo=Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repo 'scripts/Health.M20Preparation.psm1') -Force
}
Describe 'M2.0 canonical input boundaries' {
    It 'rejects alternate-case operation aliases before dispatch or budget mutation' -TestCases @(
        @{Operation='target-read'},@{Operation='group-create'},@{Operation='inventory'},@{Operation='deploy'},@{Operation='payload-read'},@{Operation='callback-read'},@{Operation='callback-bind'},@{Operation='enable'},@{Operation='invoke'},@{Operation='run-read'},@{Operation='disable'},@{Operation='cancel'},@{Operation='delete'},@{Operation='absence-read'}
    ) {
        param($Operation)
        $b=New-HealthM20Budget
        {Invoke-HealthM20FakeRequest -Budget $b -Operation $Operation.ToUpperInvariant()}|Should -Throw
        $s=Get-HealthM20BudgetStatus $b
        $s.AdmissionRemaining|Should -Be 300;$s.RecoveryRemaining|Should -Be 200
        $s.Dispatches|Should -Be 0;$s.InclusiveTriggers|Should -Be 0
    }
    It 'cannot use casing to bypass stale-cost or recovery-authority gates' {
        $b=New-HealthM20Budget
        {Invoke-HealthM20FakeRequest -Budget $b -Operation DEPLOY -CostFresh $false}|Should -Throw
        {Invoke-HealthM20FakeRequest -Budget $b -Operation DELETE -ModeledOwnership $false -RecoveryAuthorized $false}|Should -Throw
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy -CostFresh $false).outcome|Should -BeExactly blocked-new-work
        (Invoke-HealthM20FakeRequest -Budget $b -Operation delete -ModeledOwnership $false -RecoveryAuthorized $false).outcome|Should -BeExactly blocked-recovery-authority
        (Get-HealthM20BudgetStatus $b).Dispatches|Should -Be 0
    }
    It 'cannot replay a callback under a case-variant workflow identity' {
        $b=New-HealthM20Budget
        (Invoke-HealthM20FakeRequest -Budget $b -Operation invoke -WorkflowAlias lifecycle-create).dispatched|Should -BeTrue
        {Invoke-HealthM20FakeRequest -Budget $b -Operation invoke -WorkflowAlias LIFECYCLE-CREATE}|Should -Throw
        (Invoke-HealthM20FakeRequest -Budget $b -Operation invoke -WorkflowAlias lifecycle-create).outcome|Should -BeExactly write-replay-refused
        $s=Get-HealthM20BudgetStatus $b
        $s.InclusiveTriggers|Should -Be 3;$s.ActionActivations|Should -Be 9
    }
    It 'rejects alternate-case outcome or phase without consuming an intent' -TestCases @(
        @{Key='Outcome';Value='SUCCESS'},@{Key='Outcome';Value='UNKNOWN'},@{Key='Outcome';Value='BEFORE-DISPATCH-FAULT'},@{Key='Phase';Value='admission'},@{Key='Phase';Value='recovery'}
    ) {
        param($Key,$Value)
        $b=New-HealthM20Budget;$requestArgs=@{Budget=$b;Operation='deploy'};$requestArgs[$Key]=$Value
        {Invoke-HealthM20FakeRequest @requestArgs}|Should -Throw
        (Get-HealthM20BudgetStatus $b).Dispatches|Should -Be 0
        (Invoke-HealthM20FakeRequest -Budget $b -Operation deploy).dispatched|Should -BeTrue
    }
    It 'rejects alternate-case workflow aliases' -TestCases @(
        @{Alias='receiver-duplicate-batch'},@{Alias='receiver-mismatched-state'},@{Alias='lifecycle-create'}
    ) {
        param($Alias)
        $b=New-HealthM20Budget
        {Invoke-HealthM20FakeRequest -Budget $b -Operation invoke -WorkflowAlias $Alias.ToUpperInvariant()}|Should -Throw
        (Get-HealthM20BudgetStatus $b).InclusiveTriggers|Should -Be 0
    }
    It 'rejects alternate-case scenarios and entry modes at every public boundary' {
        $entry=Join-Path $script:repo 'scripts/Get-M20Preparation.ps1'
        {Invoke-HealthM20Simulation -Scenario BILLING-UNAVAILABLE}|Should -Throw
        {Export-HealthM20ObservationPrototype -OutputDirectory (Join-Path $TestDrive 'rejected') -Scenario NORMAL}|Should -Throw
        Test-Path (Join-Path $TestDrive 'rejected')|Should -BeFalse
        {& $entry -Mode plan}|Should -Throw
        {& $entry -Mode SIMULATE}|Should -Throw
        {& $entry -Mode Simulate -Scenario NORMAL}|Should -Throw
    }
    It 'uses exact case for every public enum in the offline controller' {
        $commands=@('Invoke-HealthM20FakeRequest','Invoke-HealthM20Simulation','Export-HealthM20ObservationPrototype',(Join-Path $script:repo 'scripts/Get-M20Preparation.ps1'))
        $count=0
        foreach($name in $commands){
            foreach($parameter in (Get-Command $name).Parameters.Values){
                foreach($attribute in $parameter.Attributes){
                    if($attribute -is [Management.Automation.ValidateSetAttribute]){$attribute.IgnoreCase|Should -BeFalse;$count++}
                }
            }
        }
        $count|Should -Be 8
    }
    It 'rejects noncanonical workload event identities before changing counters' -TestCases @(@{Invalid='BATCH-ONE'},@{Invalid="batch-one`n"}) {
        param($Invalid)
        $b=New-HealthM20Budget
        Register-HealthM20WorkloadEvent -Budget $b -EventId batch-one -Outer 1
        {Register-HealthM20WorkloadEvent -Budget $b -EventId $Invalid -Outer 1}|Should -Throw
        {Register-HealthM20WorkloadEvent -Budget $b -EventId batch-one -Outer 1}|Should -Throw
        (Get-HealthM20BudgetStatus $b).InclusiveTriggers|Should -Be 1
    }
    It 'keeps every management operation recovery classification aligned with the allowlist' {
        $manifest=Get-Content (Join-Path $script:repo 'validation/m20-operation-allowlist.v1.json') -Raw|ConvertFrom-Json
        foreach($operation in $manifest.operations|Where-Object id -cne invoke){
            $b=New-HealthM20Budget
            if($operation.budget -cin @('recovery','admission-or-reserved-recovery')){
                (Invoke-HealthM20FakeRequest -Budget $b -Operation $operation.id -Phase Recovery).dispatched|Should -BeTrue
                $s=Get-HealthM20BudgetStatus $b;$s.AdmissionRemaining|Should -Be 300;$s.RecoveryRemaining|Should -Be 199
            }else{
                $operation.budget|Should -BeExactly admission
                {Invoke-HealthM20FakeRequest -Budget $b -Operation $operation.id -Phase Recovery}|Should -Throw
                $s=Get-HealthM20BudgetStatus $b;$s.AdmissionRemaining|Should -Be 300;$s.RecoveryRemaining|Should -Be 200
            }
        }
    }
    It 'requires whole-string canonical oracle identities even when paired facts match' {
        $valid=@{expectedAttempt='attempt-one';observedAttempt='attempt-one';expectedCase='lifecycle-create';observedCase='lifecycle-create';parentRun='parent-one';actionParentRun='parent-one';expectedStubRun='stub-one';observedStubRun='stub-one';requestCorrelation='request-one';stubCorrelation='request-one';bindingObserved=$true;oracleObserved=$true;redacted=$false;listWasEmpty=$true;createBranchObserved=$true;fixedReplyObserved=$true}
        (Test-HealthM20OracleModel $valid).simulationOraclePassed|Should -BeTrue
        $paired=$valid.Clone();$paired.expectedAttempt+="`n";$paired.observedAttempt+="`n"
        {Test-HealthM20OracleModel $paired}|Should -Throw
        foreach($key in @('expectedAttempt','observedAttempt','expectedCase','observedCase','parentRun','actionParentRun','expectedStubRun','observedStubRun','requestCorrelation','stubCorrelation')){
            $facts=$valid.Clone();$facts[$key]+="`n"
            {Test-HealthM20OracleModel $facts}|Should -Throw
        }
    }
}
