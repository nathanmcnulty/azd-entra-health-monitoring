#Requires -Version 7.6
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][guid]$ExpectedOperatorObjectId,
    [Parameter(Mandatory)][guid]$RunId,
    [Parameter(Mandatory)][ValidatePattern('^rg-azd-health-fixtures-[0-9a-f]{12}$')][string]$ResourceGroupName,
    [string]$Repository = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$ArtifactDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sub = $SubscriptionId
$tenant = $TenantId
$watch=[Diagnostics.Stopwatch]::StartNew()
$run = $RunId.ToString('N').Substring(0,12)
$rg = $ResourceGroupName
if($rg -cne "rg-azd-health-fixtures-$run"){throw 'The approved group and run identity must match.'}
foreach($value in @($sub,$tenant)){if($value -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'){throw 'Exact lowercase scope GUIDs required.'}}
if($ExpectedOperatorObjectId -eq [guid]::Empty -or $RunId -eq [guid]::Empty){throw 'Nonempty run/operator IDs required.'}
$scope = "/subscriptions/$sub/resourceGroups/$rg"
$Repository = [IO.Path]::GetFullPath($Repository)
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
if ($ArtifactDirectory.StartsWith($Repository.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep target-bound artifacts outside the repository.' }
if (Test-Path -LiteralPath $ArtifactDirectory) { throw 'Use a fresh artifact directory.' }
$ancestor=Get-Item -LiteralPath (Split-Path -Parent $ArtifactDirectory)
while($null-ne$ancestor){if($ancestor.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Artifact ancestry must be ordinary directories.'};$ancestor=$ancestor.Parent}
New-Item -ItemType Directory -Path $ArtifactDirectory | Out-Null
$receiptStream=[IO.File]::Open((Join-Path $ArtifactDirectory 'receipt.json'),'CreateNew','ReadWrite','None')
$intentStream=[IO.File]::Open((Join-Path $ArtifactDirectory 'intents.ndjson'),'CreateNew','Write','Read')
$receipt=[ordered]@{runId=$RunId.ToString();subscription=$sub;tenant=$tenant;resourceGroup=$rg;sourceHashes=@{};cases=@();intents=@();providerRequests=0;graphOrTeamsCalls=$false;cleanup='not-created';deleteOutcome='not-attempted';resourceGroupAbsent=$false;cleanupEvidenceQualified=$false;unknownMutation=$false;unknownInvocation=$false;validation='not-started';boundSeconds=1200;workloadSeconds=960;requestSeconds=30;maxRequests=1000;functionalAcceptance=$false}
function Save-Receipt { $b=[Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 24 -Compress));$receiptStream.Position=0;$receiptStream.SetLength(0);$receiptStream.Write($b);$receiptStream.Flush($true) }
function Seconds([switch]$Cleanup){$limit=if($Cleanup){1200}else{960};$left=[math]::Floor($limit-$watch.Elapsed.TotalSeconds);if($Cleanup-and$null-ne$script:deleteWatch){$left=[math]::Min($left,[math]::Floor(120-$script:deleteWatch.Elapsed.TotalSeconds))};if($left-lt1){throw 'Fixture phase deadline expired; preserve unknown work.'};[int][math]::Min(30,$left)}
function Save-Intent([byte[]]$Bytes){$intentStream.Write($Bytes);$intentStream.Flush($true)}
function Record-Intent([string]$Operation,[string]$Resource){$entry=@{sequence=$receipt.intents.Count+1;operation=$Operation;resource=$Resource;utc=[DateTimeOffset]::UtcNow.ToString('o')};Save-Intent ([Text.UTF8Encoding]::new($false).GetBytes(($entry|ConvertTo-Json -Compress)+"`n"));$receipt.intents+=,$entry;Save-Receipt}
function Parse-Object([byte[]]$Bytes){$text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes);[EntraHealthFixtures.BoundedIO]::ValidateJsonObject($text);$text|ConvertFrom-Json -AsHashtable -DateKind String -Depth 32}
function Assert-FixtureText($Value,[string]$Expected){if($Value-isnot[string]-or$Value-cne$Expected){throw 'Exact scalar fixture identity required.'}}
function Complete-List($Value){if($Value -isnot[Collections.IDictionary] -or -not$Value.Contains('value') -or $Value.value -isnot[array]){throw 'Complete bounded collection required.'};if($Value.Contains('nextLink')-and$null-ne$Value.nextLink-and($Value.nextLink-isnot[string]-or$Value.nextLink-cne'')){throw 'Nonempty or malformed continuation refused.'};return ,$Value.value}
Save-Receipt
$holds=[Collections.Generic.List[IO.FileStream]]::new()
$token=$null
$created=$false
$cleanupPhase=$false
$script:deleteWatch=$null
try {
foreach($file in @($PSCommandPath,(Join-Path $PSScriptRoot 'Health.FixtureIO.cs'),(Join-Path $PSScriptRoot 'Health.FixtureCliRead.ps1'),(Join-Path $Repository 'infra/workflow-definition.json'),(Join-Path $Repository 'infra/lifecycle-workflow-definition.json'))){$item=Get-Item -LiteralPath $file;while($null-ne$item){if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Reparse source ancestry refused.'};$item=if($item-is[IO.FileInfo]){$item.Directory}else{$item.Parent}};$holds.Add([IO.File]::Open($file,'Open','Read','Read'));$receipt.sourceHashes[$file]=(Get-FileHash -LiteralPath $file).Hash}
if('EntraHealthFixtures.BoundedIO'-as[type]){throw 'Fresh fixture process required.'}
Add-Type -Path (Join-Path $PSScriptRoot 'Health.FixtureIO.cs')
$cli=Join-Path $PSScriptRoot 'Health.FixtureCliRead.ps1'
$runtime=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
$account=Parse-Object ([Text.UTF8Encoding]::new($false).GetBytes([EntraHealthFixtures.BoundedIO]::Run($runtime,$cli,(@{action='Account';subscription=$sub}|ConvertTo-Json -Compress),(Seconds)).GetAwaiter().GetResult()))
Assert-FixtureText $account.id $sub;Assert-FixtureText $account.tenantId $tenant;Assert-FixtureText $account.environmentName 'AzureCloud';Assert-FixtureText $account.state 'Enabled';Assert-FixtureText $account.user.type 'user'
$td=Parse-Object ([Text.UTF8Encoding]::new($false).GetBytes([EntraHealthFixtures.BoundedIO]::Run($runtime,$cli,(@{action='ArmToken';subscription=$sub}|ConvertTo-Json -Compress),(Seconds)).GetAwaiter().GetResult()))
Assert-FixtureText $td.tenant $tenant;Assert-FixtureText $td.subscription $sub
if($td.accessToken-isnot[string] -or $td.accessToken.Length-lt1 -or $td.accessToken.Length-gt32768){throw 'Token shape mismatch.'}
$token=$td.accessToken;$parts=$token.Split('.');if($parts.Count-ne3){throw 'Token shape mismatch.'};$p=$parts[1].Replace('-','+').Replace('_','/');$p=$p.PadRight($p.Length+((4-$p.Length%4)%4),'=');$claims=Parse-Object ([Convert]::FromBase64String($p))
Assert-FixtureText $claims.tid $tenant;Assert-FixtureText $claims.oid $ExpectedOperatorObjectId.ToString();Assert-FixtureText $claims.aud 'https://management.azure.com/'
if(($claims.exp-isnot[long]-and$claims.exp-isnot[int]) -or $claims.exp-lt[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+1260){throw 'Remaining token lifetime required.'}
$state = 'SyntheticClientStateForWorkflowFixturesOnly'
$callbackParameter = 'https://example.invalid/synthetic-callback'
foreach ($file in @('infra/workflow-definition.json','infra/lifecycle-workflow-definition.json')) { $receipt.sourceHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $Repository $file)).Hash.ToLowerInvariant() }
function Invoke-FixtureArmTransport($Method,$Uri,$Token,$Body,$Seconds){[EntraHealthFixtures.BoundedIO]::Send($Method,$Uri,$Token,$Body,$Seconds).GetAwaiter().GetResult()}
function Invoke-FixtureCallbackTransport($Uri,$Bytes,$ContentType,$Seconds){[EntraHealthFixtures.BoundedIO]::SendCallback($Uri,$Bytes,$ContentType,$Seconds).GetAwaiter().GetResult()}
function Arm([string]$Method, [string]$Path, $Body=$null, [switch]$AllowMissing) {
    $subscriptionGet="/subscriptions/${sub}?api-version=2021-04-01"
    $subscriptionLocks="/subscriptions/$sub/providers/Microsoft.Authorization/locks?api-version=2016-09-01"
    if ($Method-cnotin@('GET','PUT','POST','DELETE') -or -not (($Method-ceq'GET'-and$Path-cin@($subscriptionGet,$subscriptionLocks))-or$Path.StartsWith($scope+'/',[StringComparison]::Ordinal)-or$Path.StartsWith($scope+'?',[StringComparison]::Ordinal))) { throw 'ARM target escaped the owned test group.' }
    if($Method-ceq'DELETE'-and$Path-cne"${scope}?api-version=2022-09-01"){throw 'Only one exact group deletion is permitted.'}
    if($Method-ceq'POST'-and$Path-cnotmatch '/triggers/When_a_HTTP_request_is_received/listCallbackUrl\?api-version=2019-05-01$'){throw 'Only callback metadata POST is permitted.'}
    if($Method-ceq'PUT'-and$Path-cne"${scope}?api-version=2022-09-01"-and@($receipt.expectedResourceIds|Where-Object {($_+'?api-version=2019-05-01')-ceq$Path}).Count-ne1){throw 'Fixed workflow creation target required.'}
    if($receipt.providerRequests-ge1000){throw 'Fixture request cap reached.'};$seconds=Seconds -Cleanup:$cleanupPhase
    $receipt.providerRequests++
    if($cleanupPhase-and$null-ne$script:deleteWatch-and$Method-ceq'GET'-and$Path-ceq"${scope}?api-version=2022-09-01"){
        try{Save-Receipt}catch{$receipt.observationSnapshotFailed=$true}
    }else{Save-Receipt}
    $bodyText=if($null-ne$Body){$Body|ConvertTo-Json -Depth 100 -Compress}else{[System.Management.Automation.Language.NullString]::Value}
    $seconds=Seconds -Cleanup:$cleanupPhase
    try{$response=Invoke-FixtureArmTransport $Method ([uri]"https://management.azure.com${Path}") $token $bodyText $seconds}catch{throw 'Bounded ARM transport failed; preserve uncertain work.'}
    $null=Seconds -Cleanup:$cleanupPhase
    if ($AllowMissing -and $response.StatusCode -eq 404) { $errorBody=Parse-Object $response.Bytes;if($Path-cne"${scope}?api-version=2022-09-01"){throw 'Exact ResourceGroupNotFound route required.'};Assert-FixtureText $errorBody.error.code 'ResourceGroupNotFound';return $null }
    if ($response.StatusCode -ge 300) {
        $receipt.armFailure=@{method=$Method;resourcePath=($Path -split '\?')[0];httpStatus=[int]$response.StatusCode}
        throw "ARM operation failed with HTTP $($response.StatusCode); method and resource path retained without response content."
    }
    if($Method-ceq'PUT'-and$response.StatusCode-ne201){throw 'Create request did not return201; preserve uncertain target.'}
    if($Method-ceq'DELETE'-and$response.StatusCode-notin@(200,202,204)){throw 'Unexpected delete response; observe without replay.'}
    if ($response.Bytes.Length) { return (Parse-Object $response.Bytes) }
}
function New-FixtureWorkflow([string]$Name, $Definition, $Parameters) {
    $id="$scope/providers/Microsoft.Logic/workflows/$Name"
    if ($id -notin $receipt.expectedResourceIds) { throw 'Unexpected fixture workflow name.' }
    $null=$Definition.parameters.Remove('$connections')
    $serialized=$Definition | ConvertTo-Json -Depth 100 -Compress
    if ($serialized -match 'ManagedServiceIdentity|ApiConnection|graph\.microsoft\.com|\$connections') { throw 'Synthetic definition still contains a real Graph or connector dependency.' }
    Record-Intent 'workflow-create' $id;$receipt.unknownMutation=$true;Save-Receipt
    $null=Arm PUT "${id}?api-version=2019-05-01" @{location='westus2';tags=@{ 'codex-health-fixture'=$run };properties=@{state='Enabled';definition=$Definition;parameters=$Parameters}}
    $receipt.unknownMutation=$false;Save-Receipt
    $url=Arm POST "$id/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01" @{}
    $callback=[uri]$url.value;if($callback.Scheme-cne'https'-or$callback.Port-ne443-or$callback.UserInfo-or$callback.Fragment-or$callback.DnsSafeHost-cnotmatch '^[a-z0-9.-]+\.logic\.azure\.com$'-or$callback.AbsolutePath-cnotmatch '^/workflows/[a-f0-9]{32}/triggers/When_a_HTTP_request_is_received/paths/invoke$'){throw 'Exact commercial Logic Apps callback shape required.'}
    return @{ id=$id; callback=$url.value }
}
function SanitizeActions($Actions, [string]$StubCallback, $Replies, [switch]$Receiver) {
    foreach ($name in @($Actions.Keys)) {
        $action=$Actions[$name]
        $null=$action.Remove('runtimeConfiguration')
        if ($action.type -eq 'ApiConnection') {
            $Actions[$name]=@{type='Compose';runAfter=$action.runAfter;inputs=@{syntheticDelivery=$true}}
        } elseif ($action.type -eq 'Http') {
            if ($Receiver) {
                $Actions[$name]=@{type='Compose';runAfter=$action.runAfter;inputs=@{id='synthetic-alert';alertType='synthetic';scenario='fixture';category='fixture';state='active'}}
            } else {
                $reply=$Replies[$name].Clone()
                # Keep literal OData keys out of the workflow-expression parser.
                $reply.body=$reply.body | ConvertTo-Json -Depth 30 -Compress
                $action.inputs=@{method='POST';uri=$StubCallback;body=$reply;retryPolicy=@{type='fixed';count=1;interval='PT5S'}}
            }
        }
        if ($action.ContainsKey('actions')) { SanitizeActions $action.actions $StubCallback $Replies -Receiver:$Receiver }
        if ($action.ContainsKey('else')) { SanitizeActions $action.else.actions $StubCallback $Replies -Receiver:$Receiver }
    }
}
function Submit($Workflow, $Payload, [string]$Query='', [string]$ContentType='application/json', [switch]$RawBody) {
    $body=if($RawBody){$Payload}else{$Payload | ConvertTo-Json -Depth 20 -Compress}
    [byte[]]$bytes=if($RawBody){,([byte[]]$Payload)}else{,([Text.UTF8Encoding]::new($false).GetBytes($body))}
    if($Query-cnotin@('','&validationToken=SyntheticValidation')){throw 'Fixed callback query required.'}
    if($receipt.providerRequests-ge1000){throw 'Fixture request cap reached.'};$seconds=Seconds
    Record-Intent 'synthetic-invoke' $Workflow.id;$receipt.unknownInvocation=$true;$receipt.providerRequests++;Save-Receipt
    $seconds=Seconds
    try { $result=Invoke-FixtureCallbackTransport ([uri]($Workflow.callback+$Query)) $bytes $ContentType $seconds }
    catch { throw 'Bounded synthetic trigger failed; signed callback excluded; preserve uncertain invocation.' }
    $null=Seconds
    $requestWire=@{
        method='POST'
        mediaType=([Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)).MediaType
        charset=([Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)).CharSet
        contentLength=$bytes.Length
        source='Bounded ByteArrayContent configuration; not a network packet capture'
    }
    if($result.StatusCode-eq400){$receipt.unknownInvocation=$false;Save-Receipt;return @{httpStatus=400;runStatus='Rejected';actions=@{};runId=$null;requestWire=$requestWire}}
    if($result.StatusCode-cnotin@(200,202)-or$result.WorkflowRunId-cnotmatch '^[A-Za-z0-9._~-]{1,128}$'){throw 'Accepted callback needs an exact provider run identity; preserve uncertain invocation.'}
    $runName=$result.WorkflowRunId;$receipt.unknownInvocation=$false;Record-Intent 'observe-exact-run' ($Workflow.id+'/runs/'+$runName)
    for ($attempt=0;$attempt -lt 60;$attempt++) {
        $latest=Arm GET "$($Workflow.id)/runs/${runName}?api-version=2019-05-01"
        if ($null-ne$latest) {
            Assert-FixtureText $latest.id ($Workflow.id+'/runs/'+$runName);Assert-FixtureText $latest.name $runName
            if ($latest.properties.status -in @('Succeeded','Failed','Cancelled')) {
                $actions=Arm GET "$($Workflow.id)/runs/$($latest.name)/actions?api-version=2019-05-01"
                $statuses=@{}; foreach ($action in (Complete-List $actions)) { $statuses[$action.name]=$action.properties.status }
                $responseBody=if($Query-ceq'&validationToken=SyntheticValidation'-and[Text.UTF8Encoding]::new($false,$true).GetString($result.Bytes)-ceq'SyntheticValidation'){'SyntheticValidation'}else{''}
                return @{httpStatus=[int]$result.StatusCode;responseBody=$responseBody;runStatus=$latest.properties.status;actions=$statuses;runId=$latest.name;requestWire=$requestWire}
            }
        }
        Start-Sleep -Seconds 2
    }
    throw 'Synthetic run did not reach a terminal state.'
}
function Invoke-OwnedFixtureCleanup {
    try {
    $cleanupPhase=$true
    if ($created) {
        if($receipt.unknownMutation-or$receipt.unknownInvocation){throw 'Unknown create/invocation outcome; preserve the group without delete.'}
        $group=Arm GET "${scope}?api-version=2022-09-01" -AllowMissing
        if ($null -ne $group) {
            Assert-FixtureText $group.id $scope;Assert-FixtureText $group.tags['codex-health-fixture'] $run
            $baseline=$null
            foreach($snapshot in 1..2){
                $resources=Complete-List (Arm GET "$scope/resources?api-version=2021-04-01")
                $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($resource in $resources) {
                    if ($resource.id -isnot[string] -or $resource.id -cnotin $receipt.expectedResourceIds -or -not$ids.Add($resource.id)) { throw 'Unexpected resource in fixture group; preserve for recovery.' }
                    Assert-FixtureText $resource.type 'Microsoft.Logic/workflows';Assert-FixtureText $resource.tags['codex-health-fixture'] $run
                    $workflow=Arm GET "$($resource.id)?api-version=2019-05-01"
                    Assert-FixtureText $workflow.id $resource.id;Assert-FixtureText $workflow.properties.provisioningState 'Succeeded'
                    if($workflow.Contains('identity')-and$null-ne$workflow.identity){if($workflow.identity-isnot[Collections.IDictionary]){throw 'Malformed workflow identity; preserve.'};Assert-FixtureText $workflow.identity.type 'None'}
                    $runs=Complete-List (Arm GET "$($resource.id)/runs?api-version=2019-05-01&`$top=100")
                    foreach($workflowRun in $runs){if($workflowRun.id-isnot[string]-or-not$workflowRun.id.StartsWith($resource.id+'/runs/',[StringComparison]::Ordinal)-or$workflowRun.properties.status-isnot[string]-or$workflowRun.properties.status-cnotin@('Succeeded','Failed','Cancelled','TimedOut','Aborted')){throw 'All existing workflow runs must be conclusively terminal.'}}
                }
                $fingerprint=(@($ids|Sort-Object)-join "`n")
                if($null-ne$baseline-and$fingerprint-cne$baseline){throw 'Resource inventories changed; preserve.'};$baseline=$fingerprint
                $lockPaths=@("/subscriptions/$sub/providers/Microsoft.Authorization/locks?api-version=2016-09-01","$scope/providers/Microsoft.Authorization/locks?api-version=2016-09-01")+@($ids|ForEach-Object {$_+'/providers/Microsoft.Authorization/locks?api-version=2016-09-01'})
                foreach($lockPath in $lockPaths){foreach($lock in (Complete-List (Arm GET $lockPath))){if($lock.id-isnot[string]-or$lock.id-inotmatch '/providers/Microsoft\.Authorization/locks/[^/]+$'){throw 'Malformed lock inventory; preserve.'};$lockScope=$lock.id.Substring(0,$lock.id.LastIndexOf('/providers/Microsoft.Authorization/locks/',[StringComparison]::OrdinalIgnoreCase));if($lockScope-ieq"/subscriptions/$sub"-or$lockScope-ieq$scope-or$lockScope.StartsWith($scope+'/',[StringComparison]::OrdinalIgnoreCase)){throw 'Existing target/ancestor lock; preserve.'}}}
                $assignments=Complete-List (Arm GET "$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01")
                foreach($assignment in $assignments){if($assignment.properties.scope-isnot[string]){throw 'Malformed assignment inventory; preserve.'};if($assignment.properties.scope-ieq$scope-or$assignment.properties.scope.StartsWith($scope+'/',[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected direct/descendant role assignment; preserve.'}}
            }
            if((1200-$watch.Elapsed.TotalSeconds)-lt150-or(1000-$receipt.providerRequests)-lt61){throw 'Insufficient bounded deletion-observation reserve; preserve.'}
            Record-Intent 'group-delete' $scope
            try{$null=Arm DELETE "${scope}?api-version=2022-09-01";$receipt.deleteOutcome='accepted-http-response';$receipt.cleanup='delete-submitted'}catch{$receipt.deleteOutcome='unknown';$receipt.cleanup='delete-outcome-unknown'}
            # Once dispatch may have happened, never replay DELETE. A snapshot
            # failure must not prevent bounded GET-only same-target observation.
            $snapshotFailed=$false;try{Save-Receipt}catch{$snapshotFailed=$true}
            $script:deleteWatch=[Diagnostics.Stopwatch]::StartNew()
            for ($attempt=0;$attempt -lt 60;$attempt++) {
                $null=Seconds -Cleanup
                try{if ($null -eq (Arm GET "${scope}?api-version=2022-09-01" -AllowMissing)) { $receipt.resourceGroupAbsent=$true;$receipt.cleanup='absent'; break }}catch{if($script:deleteWatch.Elapsed.TotalSeconds-ge120){break}}
                Start-Sleep -Seconds 2
            }
            if($snapshotFailed-or($receipt.Contains('observationSnapshotFailed')-and$receipt.observationSnapshotFailed)){throw 'Post-delete snapshot failed; GET observation completed but evidence remains unqualified.'}
            $receipt.cleanupEvidenceQualified=$receipt.resourceGroupAbsent
        } else { $receipt.resourceGroupAbsent=$true;$receipt.cleanupEvidenceQualified=$true;$receipt.cleanup='absent' }
    }
    } catch { $receipt.cleanupEvidenceQualified=$false;$receipt.cleanup=if($receipt.Contains('resourceGroupAbsent')-and$receipt.resourceGroupAbsent){'absence-observed-evidence-incomplete'}else{'preserved-or-unknown'}; throw 'Owned cleanup incomplete; receipt retained; no deletion retry.' }
    finally { Save-Receipt }

}
$expectedWorkflowNames=@('fixture-http','receiver-valid','receiver-missing-change-type','receiver-mismatched-state','receiver-malformed-type','receiver-empty-id','receiver-duplicate-batch','receiver-validation','lifecycle-create','lifecycle-renew','lifecycle-mismatch','lifecycle-removed-detail','lifecycle-incomplete-list','lifecycle-duplicate-list','lifecycle-list-transient','lifecycle-renewal-failure')
$receipt.expectedResourceIds=@($expectedWorkflowNames | ForEach-Object { "$scope/providers/Microsoft.Logic/workflows/$_" })
try {
    $freshSubscription=Arm GET "/subscriptions/${sub}?api-version=2021-04-01"
    Assert-FixtureText $freshSubscription.subscriptionId $sub;Assert-FixtureText $freshSubscription.tenantId $tenant;Assert-FixtureText $freshSubscription.state 'Enabled'
    if ($null -ne (Arm GET "${scope}?api-version=2022-09-01" -AllowMissing)) { throw 'Refuse an existing group.' }
    Record-Intent 'group-create' $scope;$created=$true;$receipt.unknownMutation=$true;Save-Receipt
    $receipt.cleanup='created-or-unknown'
    $null=Arm PUT "${scope}?api-version=2022-09-01" @{location='westus2';tags=@{'codex-health-fixture'=$run}}
    $receipt.unknownMutation=$false;Save-Receipt
    $stub=@{ '$schema'='https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#';contentVersion='1.0.0.0';parameters=@{};triggers=@{When_a_HTTP_request_is_received=@{type='Request';kind='Http';inputs=@{method='POST'}}};actions=@{Reply=@{type='Response';kind='Http';runAfter=@{};inputs=@{statusCode="@triggerBody()?['statusCode']";headers=@{'Retry-After'='1'};body="@json(triggerBody()?['body'])"}}};outputs=@{} }
    $mock=New-FixtureWorkflow 'fixture-http' $stub @{}
    $valid=@{clientState=$state;changeType='created';resourceData=@{id='synthetic-alert'}}
    $receiverCases=@(
        @{name='valid';payload=@{value=@($valid)};expected='Succeeded';http=202},
        @{name='missing-change-type';payload=@{value=@(@{clientState=$state;resourceData=@{id='synthetic-alert'}})};expected='Succeeded';http=202},
        @{name='mismatched-state';payload=@{value=@(@{clientState='wrong';changeType='created';resourceData=@{id='synthetic-alert'}})};expected='Succeeded';http=202},
        @{name='malformed-type';payload=@{value=@(@{clientState=$state;changeType=123})};expected='Rejected';http=400},
        @{name='empty-id';payload=@{value=@(@{clientState=$state;changeType='created';resourceData=@{id=''}})};expected='Succeeded';http=202},
        @{name='duplicate-batch';payload=@{value=@($valid,$valid)};expected='Succeeded';http=202},
        @{name='validation';payload=[byte[]]::new(0);query='&validationToken=SyntheticValidation';contentType='text/plain;charset=utf-8';rawBody=$true;expected='Succeeded';http=200;wire=@{method='POST';mediaType='text/plain';charset='utf-8';contentLength=0;queryParameter='validationToken'}}
    )
    foreach ($case in $receiverCases) {
        $definition=Get-Content -LiteralPath (Join-Path $Repository 'infra/workflow-definition.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        SanitizeActions $definition.actions '' @{} -Receiver
        $null=$definition.triggers.When_a_HTTP_request_is_received.Remove('runtimeConfiguration')
        $text=$definition | ConvertTo-Json -Depth 100
        $definition=$text.Replace("body('Get_alert_details')","outputs('Get_alert_details')") | ConvertFrom-Json -AsHashtable -Depth 100
        $fixture=New-FixtureWorkflow "receiver-$($case.name)" $definition @{GraphSubscriptionClientState=@{value=$state};TargetTeamId=@{value='synthetic-team'};TargetChannelId=@{value='synthetic-channel'};TargetChannelDisplayName=@{value='synthetic-channel'}}
        $query=if($case.ContainsKey('query')){$case.query}else{''}
        $contentType=if($case.ContainsKey('contentType')){$case.contentType}else{'application/json'}
        $rawBody=$case.ContainsKey('rawBody') -and $case.rawBody -eq $true
        $result=Submit $fixture $case.payload $query $contentType -RawBody:$rawBody
        if ($case.name -eq 'duplicate-batch' -and $result.runId) {
            $iterations=Arm GET "$($fixture.id)/runs/$($result.runId)/actions/For_each_notification/scopeRepetitions?api-version=2019-05-01"
            $result.iterations=(Complete-List $iterations).Count
        }
        $receiptCase=@{name=$case.name;kind='receiver';result=$result}
        if($case.ContainsKey('wire')){$receiptCase.wire=$case.wire}
        $receipt.cases+=$receiptCase
        Write-Output ("Receiver {0}: {1}, HTTP {2}" -f $case.name, $result.runStatus, $result.httpStatus)
        if ($result.runStatus -ne $case.expected -or $result.httpStatus -ne $case.http) { throw "Receiver fixture '$($case.name)' failed." }
        if ($case.name -eq 'duplicate-batch' -and $result.iterations -ne 1) { throw 'Duplicate normalization did not reduce the batch to one iteration.' }
        if ($case.name -in @('missing-change-type','mismatched-state','empty-id')) {
            if ($result.actions.Get_alert_details -ne 'Skipped' -or $result.actions.Post_message_in_a_chat_or_channel -ne 'Skipped') { throw 'Ignored notification reached alert processing or delivery.' }
        }
        if ($case.name -in @('valid','duplicate-batch')) {
            if ($result.actions.Get_alert_details -ne 'Succeeded' -or $result.actions.Post_message_in_a_chat_or_channel -ne 'Succeeded') { throw 'Valid notification did not reach synthetic delivery.' }
        }
        if ($case.name -eq 'validation') {
            if ($result.responseBody -ne 'SyntheticValidation') { throw 'Validation token response did not match.' }
            if ($result.requestWire.method -ne 'POST' -or $result.requestWire.mediaType -ine 'text/plain' -or $result.requestWire.charset -ine 'utf-8' -or $result.requestWire.contentLength -ne 0) { throw 'Observed validation request did not match the Graph wire contract.' }
        }
    }
    $owned=@{id='synthetic-subscription';notificationUrl=$callbackParameter;changeType='created';resource='/reports/healthmonitoring/alerts';clientState=$state;expirationDateTime=[DateTime]::UtcNow.AddDays(3).ToString('o')}
    foreach ($name in @('create','renew','mismatch','removed-detail','incomplete-list','duplicate-list','list-transient','renewal-failure')) {
        $list=@{value=@($owned)}; $detail=$owned.Clone(); $listStatus=200; $detailStatus=200; $renewStatus=200
        switch ($name) {
            'create' {$list.value=@()}
            'mismatch' {$detail.clientState='wrong'}
            'removed-detail' {$detailStatus=404}
            'incomplete-list' {$list['@odata.nextLink']='https://example.invalid/more'}
            'duplicate-list' {$list.value=@($owned,$owned)}
            'list-transient' {$listStatus=503}
            'renewal-failure' {$renewStatus=503}
        }
        $replies=@{List_subscriptions=@{statusCode=$listStatus;body=$list};Get_subscription_by_id=@{statusCode=$detailStatus;body=$detail};Create_subscription=@{statusCode=201;body=@{id='synthetic-created'}};Reauthorize_subscription=@{statusCode=200;body=@{}};Renew_subscription=@{statusCode=$renewStatus;body=@{}};Relay_lifecycle_warning=@{statusCode=202;body=@{}}}
        $definition=Get-Content -LiteralPath (Join-Path $Repository 'infra/lifecycle-workflow-definition.json') -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $definition.triggers=@{When_a_HTTP_request_is_received=@{type='Request';kind='Http';inputs=@{method='POST'}}}
        SanitizeActions $definition.actions $mock.callback $replies
        $fixture=New-FixtureWorkflow "lifecycle-$name" $definition @{NotificationUrl=@{value=$callbackParameter};GraphSubscriptionClientState=@{value=$state}}
        $result=Submit $fixture @{}
        $receipt.cases+=@{name=$name;kind='lifecycle';result=$result}
        Write-Output ("Lifecycle {0}: {1}" -f $name, $result.runStatus)
        $expected=if($name -in @('create','renew')){'Succeeded'}else{'Failed'}
        if ($result.runStatus -ne $expected) { throw "Lifecycle fixture '$name' failed." }
        if ($name -eq 'create' -and $result.actions.Create_subscription -ne 'Succeeded') { throw 'Create case did not create the synthetic subscription.' }
        if ($name -eq 'renew' -and $result.actions.Renew_subscription -ne 'Succeeded') { throw 'Renew case did not renew the synthetic subscription.' }
        if ($name -notin @('create','renew','renewal-failure') -and ($result.actions.Create_subscription -ne 'Skipped' -or $result.actions.Renew_subscription -ne 'Skipped')) { throw 'Fail-closed case reached create or renewal.' }
        if ($name -eq 'renewal-failure' -and $result.actions.Renew_subscription -ne 'Failed') { throw 'Renewal failure was not observed.' }
        if ($name -eq 'renewal-failure' -and ($result.actions.Relay_lifecycle_warning -ne 'Succeeded' -or $result.actions.Fail_on_renewal_failure -ne 'Succeeded')) { throw 'Renewal failure did not terminate after the synthetic warning succeeded.' }
    }
    $receipt.validation='passed'
} catch {
    $receipt.validation='failed'
    $receipt.failure='Validation did not complete; credential-bearing diagnostics excluded.'
    throw
} finally {
    Invoke-OwnedFixtureCleanup
}
if ($receipt.cleanup -ne 'absent') { throw 'Owned cleanup has not reached absence.' }
} catch {
    $receipt.validation='failed';$receipt.failureType=$_.Exception.GetType().FullName
    throw 'Fixture qualification incomplete; use its private receipt without replaying unknown operations.'
} finally {
    $token=$null;$receipt.completedUtc=[DateTimeOffset]::UtcNow.ToString('o');try{Save-Receipt}finally{$receiptStream.Dispose();$intentStream.Dispose();foreach($hold in $holds){$hold.Dispose()}}
}
