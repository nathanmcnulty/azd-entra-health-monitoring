BeforeAll {
    $harness=Join-Path $PSScriptRoot 'Invoke-SyntheticWorkflowValidation.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($harness,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Fixture harness must parse.'}
    if(-not('EntraHealthFixtures.BoundedIO'-as[type])){Add-Type -Path (Join-Path $PSScriptRoot 'Health.FixtureIO.cs')}
    $names=@('Seconds','Record-Intent','Parse-Object','Assert-FixtureText','Complete-List','Arm','Submit','Invoke-OwnedFixtureCleanup')
    foreach($f in $ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$true)){
        if($f.Name-cin$names){. ([scriptblock]::Create($f.Extent.Text))}
        if($f.Name-ceq'Save-Intent'){$script:saveIntentDefinition=$f.Extent.Text}
    }
    function Save-Receipt {$script:saves++}
    function Save-Intent {param([byte[]]$Bytes)$script:journalEntries++}
    function Invoke-FixtureArmTransport {param($Method,$Uri,$Token,$Body,$Seconds)throw 'Unexpected real transport.'}
    function Invoke-FixtureCallbackTransport {param($Uri,$Bytes,$ContentType,$Seconds)throw 'Unexpected real callback.'}
    function Reset-Fixture {
        $script:sub='11111111-1111-1111-1111-111111111111'
        $script:scope="/subscriptions/$sub/resourceGroups/rg-azd-health-fixtures-123456789abc"
        $script:run='123456789abc';$script:token='synthetic';$script:created=$true;$script:cleanupPhase=$false
        $script:watch=[Diagnostics.Stopwatch]::StartNew();$script:saves=0
        $script:deleteWatch=$null;$script:journalEntries=0
        $script:wf=$scope+'/providers/Microsoft.Logic/workflows/receiver-valid'
        $script:receipt=[ordered]@{intents=@();providerRequests=0;unknownMutation=$false;unknownInvocation=$false;cleanup='created';expectedResourceIds=@($wf)}
    }
    function Http-Reply([int]$Status,[string]$Json='{}',[string]$Run=''){@{StatusCode=$Status;Bytes=[Text.Encoding]::UTF8.GetBytes($Json);WorkflowRunId=$Run}}
}

Describe 'Bounded fixture ARM policy' {
    BeforeEach {Reset-Fixture;Mock Invoke-FixtureArmTransport {Http-Reply 200}}
    It 'refuses a foreign route before dispatch' {
        {Arm GET '/subscriptions/foreign?api-version=2021-04-01'}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 0 -Exactly
    }
    It 'refuses deletion of an individual resource' {
        {Arm DELETE "$wf`?api-version=2019-05-01"}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 0 -Exactly
    }
    It 'refuses a request beyond the total cap' {
        $receipt.providerRequests=1000
        {Arm GET "${scope}?api-version=2022-09-01"}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 0 -Exactly
    }
    It 'counts an attempted transport failure' {
        Mock Invoke-FixtureArmTransport {throw 'synthetic failure'}
        {Arm GET "${scope}?api-version=2022-09-01"}|Should -Throw
        $receipt.providerRequests|Should -Be 1
    }
    It 'rejects redirects without issuing a follow-up' {
        Mock Invoke-FixtureArmTransport {Http-Reply 302}
        {Arm GET "${scope}?api-version=2022-09-01"}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 1 -Exactly
    }
    It 'does not normalize a generic404 as group absence' {
        Mock Invoke-FixtureArmTransport {Http-Reply 404 '{"error":{"code":"NotFound"}}'}
        {Arm GET "${scope}?api-version=2022-09-01" -AllowMissing}|Should -Throw
    }
    It 'accepts only the exact group404 code and route' {
        Mock Invoke-FixtureArmTransport {Http-Reply 404 '{"error":{"code":"ResourceGroupNotFound"}}'}
        Arm GET "${scope}?api-version=2022-09-01" -AllowMissing|Should -BeNullOrEmpty
    }
    It 'rejects a200 create-or-update outcome' {
        {Arm PUT "${scope}?api-version=2022-09-01" @{location='westus2'}}|Should -Throw
    }
    It 'refuses workload reads after the workload deadline' {
        $script:watch=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=961}}
        {Arm GET "${scope}?api-version=2022-09-01"}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 0 -Exactly
    }
    It 'refuses a nonstring continuation even when it is an empty array' {
        {Complete-List @{value=@();nextLink=@()}}|Should -Throw
    }
    It 'writes the separate intent journal before a failing snapshot' {
        Mock Save-Receipt {throw 'snapshot failure'}
        {Record-Intent 'group-create' $scope}|Should -Throw
        $script:journalEntries|Should -Be 1
    }
    It 'appends durable journal records without replacing the prior record' {
        $path=Join-Path $TestDrive 'intents.ndjson'
        & {
            param($definition,$path)
            . ([scriptblock]::Create($definition))
            $intentStream=[IO.File]::Open($path,'CreateNew','Write','Read')
            try{Save-Intent ([Text.Encoding]::UTF8.GetBytes("first`n"));Save-Intent ([Text.Encoding]::UTF8.GetBytes("second`n"))}finally{$intentStream.Dispose()}
        } $script:saveIntentDefinition $path
        [IO.File]::ReadAllText($path)|Should -BeExactly "first`nsecond`n"
    }
    It 'allows only exact deletion observation to proceed after snapshot failure' {
        $script:cleanupPhase=$true;$script:deleteWatch=[Diagnostics.Stopwatch]::StartNew()
        Mock Save-Receipt {throw 'snapshot failure'}
        Mock Invoke-FixtureArmTransport {Http-Reply 404 '{"error":{"code":"ResourceGroupNotFound"}}'}
        Arm GET "${scope}?api-version=2022-09-01" -AllowMissing|Should -BeNullOrEmpty
        $receipt.observationSnapshotFailed|Should -BeTrue
        Should -Invoke Invoke-FixtureArmTransport -Times 1 -Exactly
        {Arm GET "$scope/resources?api-version=2021-04-01"}|Should -Throw
        Should -Invoke Invoke-FixtureArmTransport -Times 1 -Exactly
    }
}

Describe 'Exact fixture invocation evidence' {
    BeforeEach {
        Reset-Fixture
        Mock Start-Sleep {}
        Mock Invoke-FixtureCallbackTransport {Http-Reply 202 '' 'exact-run-1'}
        Mock Arm {
            if($Path-ceq($wf+'/runs/exact-run-1?api-version=2019-05-01')){return @{id=$wf+'/runs/exact-run-1';name='exact-run-1';properties=@{status='Succeeded'}}}
            if($Path-ceq($wf+'/runs/exact-run-1/actions?api-version=2019-05-01')){return @{value=@()}}
            throw 'Unexpected run route.'
        }
    }
    It 'observes the exact returned run and never the latest run' {
        $r=Submit @{id=$wf;callback='https://fixture.logic.azure.com/invoke?sig=synthetic'} @{}
        $r.runId|Should -BeExactly 'exact-run-1'
        Should -Invoke Arm -Times 0 -Exactly -ParameterFilter {$Path-like'*$top*'}
        $receipt.intents.Count|Should -Be 2
    }
    It 'preserves an accepted invocation without an exact run ID' {
        Mock Invoke-FixtureCallbackTransport {Http-Reply 202 ''}
        {Submit @{id=$wf;callback='https://fixture.logic.azure.com/invoke?sig=synthetic'} @{}}|Should -Throw
        $receipt.unknownInvocation|Should -BeTrue
        Should -Invoke Arm -Times 0 -Exactly
    }
    It 'preserves a transport timeout and its durable invocation intent' {
        Mock Invoke-FixtureCallbackTransport {throw 'synthetic timeout'}
        {Submit @{id=$wf;callback='https://fixture.logic.azure.com/invoke?sig=synthetic'} @{}}|Should -Throw
        $receipt.unknownInvocation|Should -BeTrue
        $receipt.intents.Count|Should -Be 1
    }
    It 'keeps an empty validation body as a nonnull byte array' {
        Mock Invoke-FixtureCallbackTransport {
            if($null-eq$Bytes-or$Bytes-isnot[byte[]]-or$Bytes.Length-ne0){throw 'Empty byte body lost.'}
            Http-Reply 200 'SyntheticValidation' 'exact-run-1'
        }
        $r=Submit @{id=$wf;callback='https://fixture.logic.azure.com/invoke?sig=synthetic'} ([byte[]]::new(0)) '&validationToken=SyntheticValidation' 'text/plain;charset=utf-8' -RawBody
        $r.responseBody|Should -BeExactly 'SyntheticValidation'
        $r.requestWire.contentLength|Should -Be 0
    }
}

Describe 'Owned fixture cleanup' {
    BeforeEach {
        Reset-Fixture
        $script:deleted=$false;$script:scenario='safe';$script:resourceLists=0
        $script:lockOverride=$null;$script:roleOverride=$null
        Mock Start-Sleep {}
        Mock Arm {
            if($Method-ceq'DELETE'){$script:deleted=$true;if($script:scenario-ceq'lost-delete'){throw 'synthetic lostresponse'};return}
            if($Path-ceq("${scope}?api-version=2022-09-01")){if($script:deleted){return $null};return @{id=$scope;tags=@{'codex-health-fixture'=$run}}}
            if($Path-ceq("$scope/resources?api-version=2021-04-01")){
                $script:resourceLists++
                $rows=@(@{id=$wf;type='Microsoft.Logic/workflows';tags=@{'codex-health-fixture'=$run}})
                if($script:scenario-ceq'foreign'){$rows[0].id=$scope+'/providers/Microsoft.Storage/storageAccounts/unknown'}
                return @{value=$rows;nextLink=$(if($script:scenario-ceq'continuation'){'https://example.invalid/more'}else{''})}
            }
            if($Path-ceq("$wf`?api-version=2019-05-01")){return @{id=$wf;properties=@{provisioningState='Succeeded'}}}
            if($Path-like'*/runs?*'){return @{value=@(@{id=$wf+'/runs/exact-run';properties=@{status=$(if($script:scenario-ceq'active'){'Running'}elseif($script:scenario-ceq'array-status'){,@('Succeeded')}else{'Succeeded'})}})}}
            if($Path-like'*/locks?*'){return @{value=@(if($script:lockOverride){@{id=$script:lockOverride}}elseif($script:scenario-ceq'lock'){@{id=$scope+'/providers/Microsoft.Authorization/locks/existing'}})}}
            if($Path-like'*/roleAssignments?*'){return @{value=@(if($script:roleOverride){@{properties=@{scope=$script:roleOverride}}}elseif($script:scenario-ceq'role'){@{properties=@{scope=$wf}}})}}
            throw 'Unexpected cleanup route.'
        }
    }
    It 'deletes once only after two complete matching inventories and terminal runs' {
        Invoke-OwnedFixtureCleanup
        $receipt.cleanup|Should -BeExactly 'absent'
        $script:resourceLists|Should -Be 2
        Should -Invoke Arm -Times 1 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
    }
    It 'preserves an unknown invocation before all cleanup requests' {
        $receipt.unknownInvocation=$true
        {Invoke-OwnedFixtureCleanup}|Should -Throw
        Should -Invoke Arm -Times 0 -Exactly
    }
    It 'preserves case-varied <kind> at <position> scope before DELETE' -ForEach @(
        @{kind='lock';position='subscription'},@{kind='lock';position='group'},@{kind='lock';position='descendant'},
        @{kind='role';position='group'},@{kind='role';position='descendant'}
    ) {
        $blockedScope=switch($position){'subscription'{"/subscriptions/$sub"};'group'{$scope};'descendant'{$wf}}
        if($kind-ceq'lock'){
            $script:lockOverride=($blockedScope+'/providers/microsoft.authorization/locks/Existing').ToUpperInvariant()
            {Invoke-OwnedFixtureCleanup}|Should -Throw '*Owned cleanup incomplete*'
        }else{
            $script:roleOverride=$blockedScope.ToUpperInvariant()
            {Invoke-OwnedFixtureCleanup}|Should -Throw '*Owned cleanup incomplete*'
        }
        Should -Invoke Arm -Times 0 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
    }
    It 'keeps segment boundaries for unrelated locks and permits inherited subscription roles' {
        $script:lockOverride=($scope+'-unrelated/providers/microsoft.authorization/locks/Existing').ToUpperInvariant()
        $script:roleOverride=("/subscriptions/$sub").ToUpperInvariant()
        Invoke-OwnedFixtureCleanup
        $receipt.cleanup|Should -BeExactly 'absent'
        Should -Invoke Arm -Times 1 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
    }
    It 'preserves an unknown creation outcome' {
        $receipt.unknownMutation=$true
        {Invoke-OwnedFixtureCleanup}|Should -Throw
        Should -Invoke Arm -Times 0 -Exactly
    }
    It 'observes exact group absence without replay after a lost DELETE response' {
        $script:scenario='lost-delete'
        Invoke-OwnedFixtureCleanup
        $receipt.cleanup|Should -BeExactly 'absent'
        Should -Invoke Arm -Times 1 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
        Should -Invoke Arm -Times 2 -Exactly -ParameterFilter {$Method-ceq'GET'-and$Path-ceq("${scope}?api-version=2022-09-01")}
    }
    It 'still observes absence after a post-delete snapshot failure' {
        Mock Save-Receipt {if($script:deleted){throw 'snapshot failure'}}
        {Invoke-OwnedFixtureCleanup}|Should -Throw
        Should -Invoke Arm -Times 1 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
        Should -Invoke Arm -Times 2 -Exactly -ParameterFilter {$Method-ceq'GET'-and$Path-ceq("${scope}?api-version=2022-09-01")}
    }
    It 'preserves <scenario> instead of deleting' -ForEach @(
        @{scenario='foreign'},@{scenario='continuation'},@{scenario='active'},@{scenario='array-status'},@{scenario='lock'},@{scenario='role'}
    ) {
        $script:scenario=$scenario
        {Invoke-OwnedFixtureCleanup}|Should -Throw
        Should -Invoke Arm -Times 0 -Exactly -ParameterFilter {$Method-ceq'DELETE'}
    }
}

Describe 'Actual cleanup and ARM policy composed with a recording transport' {
    BeforeEach {
        Reset-Fixture
        $script:deleted=$false;$script:scenario='safe';$script:calls=[Collections.Generic.List[string]]::new()
        Mock Start-Sleep {}
        Mock Invoke-FixtureArmTransport {
            $script:calls.Add($Method+' '+$Uri.AbsolutePath)
            $path=$Uri.AbsolutePath
            if($Method-ceq'DELETE'){$script:deleted=$true;if($script:scenario-ceq'lost-delete'){throw 'synthetic response lost'};return (Http-Reply 202 '')}
            if($path-ceq$scope){if($script:deleted){return (Http-Reply 404 '{"error":{"code":"ResourceGroupNotFound"}}')};$data=@{id=$scope;tags=@{'codex-health-fixture'=$run}}}
            elseif($path-ceq($scope+'/resources')){$data=@{value=@(@{id=$wf;type='Microsoft.Logic/workflows';tags=@{'codex-health-fixture'=$run}})}}
            elseif($path-ceq$wf){$data=@{id=$wf;properties=@{provisioningState='Succeeded'}}}
            elseif($path-ceq($wf+'/runs')){$data=@{value=@(@{id=$wf+'/runs/one';properties=@{status='Succeeded'}})}}
            elseif($path.EndsWith('/locks')-or$path.EndsWith('/roleAssignments')){$data=@{value=@()}}
            else{throw 'Unexpected recording transport route.'}
            Http-Reply 200 ($data|ConvertTo-Json -Depth 10 -Compress)
        }
    }
    It 'counts actual dispatch attempts and permits one owned deletion' {
        Invoke-OwnedFixtureCleanup
        $receipt.cleanup|Should -BeExactly 'absent'
        $receipt.providerRequests|Should -Be $script:calls.Count
        @($script:calls|Where-Object {$_-like'DELETE *'}).Count|Should -Be 1
        $script:journalEntries|Should -Be 1
    }
    It 'reconciles a lost delete response with only same-target GETs' {
        $script:scenario='lost-delete'
        Invoke-OwnedFixtureCleanup
        $receipt.cleanup|Should -BeExactly 'absent'
        $receipt.deleteOutcome|Should -BeExactly 'unknown'
        $receipt.resourceGroupAbsent|Should -BeTrue
        $receipt.cleanupEvidenceQualified|Should -BeTrue
        $receipt.providerRequests|Should -Be $script:calls.Count
        $script:calls[$script:calls.Count-1]|Should -BeExactly ('GET '+$scope)
        @($script:calls|Where-Object {$_-like'DELETE *'}).Count|Should -Be 1
    }
    It 'continues exact GET observation after snapshot writes fail' {
        Mock Save-Receipt {if($script:deleted){throw 'post-delete snapshot fault'}}
        {Invoke-OwnedFixtureCleanup}|Should -Throw
        $receipt.observationSnapshotFailed|Should -BeTrue
        $receipt.deleteOutcome|Should -BeExactly 'accepted-http-response'
        $receipt.resourceGroupAbsent|Should -BeTrue
        $receipt.cleanupEvidenceQualified|Should -BeFalse
        $receipt.cleanup|Should -BeExactly 'absence-observed-evidence-incomplete'
        $script:calls[$script:calls.Count-1]|Should -BeExactly ('GET '+$scope)
        @($script:calls|Where-Object {$_-like'DELETE *'}).Count|Should -Be 1
    }
}
