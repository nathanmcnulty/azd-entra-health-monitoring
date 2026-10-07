param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [string]$Repository = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$ArtifactDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sub = $SubscriptionId
$tenant = $TenantId
$run = [Guid]::NewGuid().ToString('N').Substring(0,12)
$rg = "rg-azd-health-fixtures-$run"
$scope = "/subscriptions/$sub/resourceGroups/$rg"
$Repository = [IO.Path]::GetFullPath($Repository)
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
if ($ArtifactDirectory.StartsWith($Repository.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep target-bound artifacts outside the repository.' }
if (Test-Path -LiteralPath $ArtifactDirectory) { throw 'Use a fresh artifact directory.' }
New-Item -ItemType Directory -Path $ArtifactDirectory | Out-Null
$account = az account show --subscription $sub -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $account.id -ne $sub -or $account.tenantId -ne $tenant -or $account.environmentName -ne 'AzureCloud') { throw 'Lab account mismatch.' }
$token = az account get-access-token --subscription $sub --resource https://management.azure.com/ --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) { throw 'Cached ARM authentication unavailable.' }
$headers = @{ Authorization = "Bearer $token" }
$state = 'SyntheticClientStateForWorkflowFixturesOnly'
$callbackParameter = 'https://example.invalid/synthetic-callback'
$receipt = [ordered]@{ runId=$run; subscription=$sub; tenant=$tenant; cloud='AzureCloud'; resourceGroup=$rg; sourceHashes=@{}; cases=@(); graphOrTeamsCalls=$false; cleanup='not-created' }
foreach ($file in @('infra/workflow-definition.json','infra/lifecycle-workflow-definition.json')) { $receipt.sourceHashes[$file] = (Get-FileHash -LiteralPath (Join-Path $Repository $file)).Hash.ToLowerInvariant() }
function Arm([string]$Method, [string]$Path, $Body=$null, [switch]$AllowMissing) {
    if (-not ($Path.StartsWith($scope+'/',[StringComparison]::Ordinal) -or $Path.StartsWith($scope+'?',[StringComparison]::Ordinal))) { throw 'ARM target escaped the owned test group.' }
    $request = @{ Method=$Method; Uri="https://management.azure.com${Path}"; Headers=$headers; SkipHttpErrorCheck=$true }
    if ($null -ne $Body) { $request.Body=$Body | ConvertTo-Json -Depth 100 -Compress; $request.ContentType='application/json' }
    try { $response=Invoke-WebRequest @request }
    catch { throw 'ARM transport failed; no credential-bearing request details retained.' }
    if ($AllowMissing -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -ge 300) {
        $receipt.armFailure=@{method=$Method;resourcePath=($Path -split '\?')[0];httpStatus=[int]$response.StatusCode}
        throw "ARM operation failed with HTTP $($response.StatusCode); method and resource path retained without response content."
    }
    if ($response.Content) { return $response.Content | ConvertFrom-Json -AsHashtable -Depth 100 }
}
function New-FixtureWorkflow([string]$Name, $Definition, $Parameters) {
    $id="$scope/providers/Microsoft.Logic/workflows/$Name"
    if ($id -notin $receipt.expectedResourceIds) { throw 'Unexpected fixture workflow name.' }
    $null=$Definition.parameters.Remove('$connections')
    $serialized=$Definition | ConvertTo-Json -Depth 100 -Compress
    if ($serialized -match 'ManagedServiceIdentity|ApiConnection|graph\.microsoft\.com|\$connections') { throw 'Synthetic definition still contains a real Graph or connector dependency.' }
    $null=Arm PUT "${id}?api-version=2019-05-01" @{location='westus2';tags=@{ 'codex-health-fixture'=$run };properties=@{state='Enabled';definition=$Definition;parameters=$Parameters}}
    $url=Arm POST "$id/triggers/When_a_HTTP_request_is_received/listCallbackUrl?api-version=2019-05-01" @{}
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
    try { $result=Invoke-WebRequest -Uri ($Workflow.callback+$Query) -Method POST -Body $body -ContentType $ContentType -SkipHttpErrorCheck }
    catch { throw 'Synthetic trigger transport failed; signed callback excluded from diagnostics.' }
    $requestMessage=$result.BaseResponse.RequestMessage
    $observedContentLength=$requestMessage.Content.Headers.ContentLength
    $requestWire=@{
        method=[string]$requestMessage.Method.Method
        mediaType=[string]$requestMessage.Content.Headers.ContentType.MediaType
        charset=[string]$requestMessage.Content.Headers.ContentType.CharSet
        contentLength=if($null -eq $observedContentLength){$null}else{[long]$observedContentLength}
    }
    if ($result.StatusCode -ge 400) { return @{httpStatus=[int]$result.StatusCode;runStatus='Rejected';actions=@{};runId=$null;requestWire=$requestWire} }
    for ($attempt=0;$attempt -lt 60;$attempt++) {
        $runs=Arm GET "$($Workflow.id)/runs?api-version=2019-05-01&`$top=1"
        if ($runs.value.Count -gt 0) {
            $latest=$runs.value[0]
            if ($latest.properties.status -in @('Succeeded','Failed','Cancelled')) {
                $actions=Arm GET "$($Workflow.id)/runs/$($latest.name)/actions?api-version=2019-05-01"
                $statuses=@{}; foreach ($action in $actions.value) { $statuses[$action.name]=$action.properties.status }
                return @{httpStatus=[int]$result.StatusCode;responseBody=[string]$result.Content;runStatus=$latest.properties.status;actions=$statuses;runId=$latest.name;requestWire=$requestWire}
            }
        }
        Start-Sleep -Seconds 2
    }
    throw 'Synthetic run did not reach a terminal state.'
}
$created=$false
$expectedWorkflowNames=@('fixture-http','receiver-valid','receiver-missing-change-type','receiver-mismatched-state','receiver-malformed-type','receiver-empty-id','receiver-duplicate-batch','receiver-validation','lifecycle-create','lifecycle-renew','lifecycle-mismatch','lifecycle-removed-detail','lifecycle-incomplete-list','lifecycle-duplicate-list','lifecycle-list-transient','lifecycle-renewal-failure')
$receipt.expectedResourceIds=@($expectedWorkflowNames | ForEach-Object { "$scope/providers/Microsoft.Logic/workflows/$_" })
try {
    if ($null -ne (Arm GET "${scope}?api-version=2022-09-01" -AllowMissing)) { throw 'Refuse an existing group.' }
    $created=$true
    $receipt.cleanup='created-or-unknown'
    $null=Arm PUT "${scope}?api-version=2022-09-01" @{location='westus2';tags=@{'codex-health-fixture'=$run}}
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
            $result.iterations=$iterations.value.Count
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
    try {
    if ($created) {
        $group=Arm GET "${scope}?api-version=2022-09-01" -AllowMissing
        if ($null -ne $group) {
            if ($group.tags['codex-health-fixture'] -ne $run) { throw 'Cleanup ownership mismatch; preserve resources and receipt.' }
            $resources=Arm GET "$scope/resources?api-version=2021-04-01"
            foreach ($resource in $resources.value) {
                if ($resource.id -notin $receipt.expectedResourceIds -or $resource.type -ne 'Microsoft.Logic/workflows' -or $resource.tags['codex-health-fixture'] -ne $run) { throw 'Unexpected resource in fixture group; preserve for recovery.' }
            }
            $assignments=Arm GET "$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
            if (@($assignments.value | Where-Object { $_.properties.scope -eq $scope }).Count -gt 0) { throw 'Unexpected direct role assignment; preserve for recovery.' }
            $null=Arm DELETE "${scope}?api-version=2022-09-01"
            $receipt.cleanup='delete-submitted'
            for ($attempt=0;$attempt -lt 180;$attempt++) {
                if ($null -eq (Arm GET "${scope}?api-version=2022-09-01" -AllowMissing)) { $receipt.cleanup='absent'; break }
                Start-Sleep -Seconds 2
            }
        } else { $receipt.cleanup='absent' }
    }
    } catch { $receipt.cleanup='failed'; throw 'Owned cleanup failed; receipt retained for recovery.' }
    finally { $receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'receipt.json') }
}
if ($receipt.cleanup -ne 'absent') { throw 'Owned cleanup has not reached absence.' }
