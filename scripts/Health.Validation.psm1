#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HealthValidationContext = $null

function Import-AzdEnvironment {
    $values = & azd env get-values
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the selected azd environment.' }

    foreach ($line in @($values)) {
        if ([string]::IsNullOrWhiteSpace($line) -or -not $line.Contains('=')) { continue }
        $parts = $line.Split('=', 2)
        Set-Item -Path "env:$($parts[0])" -Value $parts[1].Trim('"')
    }
}

function Assert-HealthGuid {
    param([Parameter(Mandatory)][string] $Name, [AllowEmptyString()][string] $Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Name must be a non-empty GUID."
    }
}

function Assert-HealthNameSegment {
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][ValidateSet('environment', 'resourceGroup', 'workflow', 'connection', 'run')][string] $Kind
    )

    $maximum = if ($Kind -eq 'environment') { 64 } elseif ($Kind -eq 'resourceGroup') { 90 } elseif ($Kind -eq 'run') { 128 } else { 80 }
    $pattern = if ($Kind -eq 'run') { '^[A-Za-z0-9._~-]+$' } else { '^[A-Za-z0-9_.()-]+$' }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $maximum -or
        $Value -in '.', '..' -or $Value.EndsWith('.', [StringComparison]::Ordinal) -or $Value -cnotmatch $pattern) {
        throw "$Name must be one bounded legal $Kind name segment."
    }
}

function Get-HealthValidationContext {
    if ($null -ne $script:HealthValidationContext) { return $script:HealthValidationContext }

    Import-AzdEnvironment
    Assert-HealthGuid -Name 'AZURE_TENANT_ID' -Value ([string] $env:AZURE_TENANT_ID)
    Assert-HealthGuid -Name 'AZURE_SUBSCRIPTION_ID' -Value ([string] $env:AZURE_SUBSCRIPTION_ID)
    foreach ($name in 'AZURE_ENV_NAME', 'AZURE_RESOURCE_GROUP', 'LOGIC_APP_NAME', 'LIFECYCLE_LOGIC_APP_NAME', 'TEAMS_CONNECTION_NAME') {
        if ([string]::IsNullOrWhiteSpace([string] (Get-Item -Path "env:$name" -ErrorAction SilentlyContinue).Value)) {
            throw "$name is required for deployment validation."
        }
    }
    Assert-HealthNameSegment -Name 'AZURE_ENV_NAME' -Value ([string] $env:AZURE_ENV_NAME) -Kind environment
    Assert-HealthNameSegment -Name 'AZURE_RESOURCE_GROUP' -Value ([string] $env:AZURE_RESOURCE_GROUP) -Kind resourceGroup
    Assert-HealthNameSegment -Name 'LOGIC_APP_NAME' -Value ([string] $env:LOGIC_APP_NAME) -Kind workflow
    Assert-HealthNameSegment -Name 'LIFECYCLE_LOGIC_APP_NAME' -Value ([string] $env:LIFECYCLE_LOGIC_APP_NAME) -Kind workflow
    Assert-HealthNameSegment -Name 'TEAMS_CONNECTION_NAME' -Value ([string] $env:TEAMS_CONNECTION_NAME) -Kind connection

    $accountText = (& az account show --subscription $env:AZURE_SUBSCRIPTION_ID --output json --only-show-errors | Out-String)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountText)) {
        throw 'The selected Azure subscription is unavailable in the cached Azure CLI context.'
    }
    try { $account = $accountText | ConvertFrom-Json -Depth 10 } catch { throw 'Azure CLI returned invalid account context data.' }
    $accountSubscription = [guid]::Empty
    $accountTenant = [guid]::Empty
    if (-not [guid]::TryParse([string] $account.id, [ref] $accountSubscription) -or
        -not [guid]::TryParse([string] $account.tenantId, [ref] $accountTenant)) {
        throw 'Azure CLI returned account context without valid subscription and tenant IDs.'
    }
    if ($accountSubscription -ne [guid] $env:AZURE_SUBSCRIPTION_ID -or
        $accountTenant -ne [guid] $env:AZURE_TENANT_ID) {
        throw 'The selected Azure subscription and tenant do not match the cached Azure CLI context.'
    }

    $script:HealthValidationContext = [pscustomobject] [ordered]@{
        environmentName = [string] $env:AZURE_ENV_NAME
        tenantId = $accountTenant.ToString()
        subscriptionId = $accountSubscription.ToString()
        resourceGroup = [string] $env:AZURE_RESOURCE_GROUP
        alertWorkflow = [string] $env:LOGIC_APP_NAME
        lifecycleWorkflow = [string] $env:LIFECYCLE_LOGIC_APP_NAME
        teamsConnection = [string] $env:TEAMS_CONNECTION_NAME
    }
    return $script:HealthValidationContext
}

function Get-HealthManagementToken {
    param([Parameter(Mandatory)][string] $SubscriptionId)
    $token = & az account get-access-token --subscription $SubscriptionId --resource 'https://management.azure.com/' --query accessToken --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $token)) {
        throw 'Unable to acquire an Azure Resource Manager token from the cached Azure CLI context.'
    }
    return [string] $token
}

function New-HealthArmUri {
    param(
        [Parameter(Mandatory)][ValidateSet('connection', 'workflowRuns', 'expirationAction')][string] $Endpoint,
        [AllowNull()][object] $WorkflowName,
        [AllowNull()][object] $RunName
    )

    $context = Get-HealthValidationContext
    Assert-HealthGuid -Name 'subscriptionId' -Value ([string] $context.subscriptionId)
    Assert-HealthNameSegment -Name 'resourceGroup' -Value ([string] $context.resourceGroup) -Kind resourceGroup
    $subscription = ([guid] $context.subscriptionId).ToString()
    $resourceGroup = [uri]::EscapeDataString([string] $context.resourceGroup)
    $prefix = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$resourceGroup/providers"

    switch ($Endpoint) {
        'connection' {
            Assert-HealthNameSegment -Name 'teamsConnection' -Value ([string] $context.teamsConnection) -Kind connection
            if ($WorkflowName -or $RunName) { throw 'Connection endpoint does not accept workflow or run selectors.' }
            $connection = [uri]::EscapeDataString([string] $context.teamsConnection)
            $expected = "$prefix/Microsoft.Web/connections/${connection}?api-version=2016-06-01"
        }
        'workflowRuns' {
            Assert-HealthNameSegment -Name 'workflowName' -Value $WorkflowName -Kind workflow
            if ($WorkflowName -cnotin @([string] $context.alertWorkflow, [string] $context.lifecycleWorkflow) -or $RunName) {
                throw 'Workflow endpoint selector is not one of the configured workflows.'
            }
            $workflow = [uri]::EscapeDataString($WorkflowName)
            $expected = "$prefix/Microsoft.Logic/workflows/$workflow/runs?api-version=2019-05-01&`$top=1"
        }
        'expirationAction' {
            Assert-HealthNameSegment -Name 'workflowName' -Value $WorkflowName -Kind workflow
            Assert-HealthNameSegment -Name 'runName' -Value $RunName -Kind run
            if ($WorkflowName -cne [string] $context.lifecycleWorkflow) {
                throw 'Expiration action is allowed only for the configured lifecycle workflow.'
            }
            $workflow = [uri]::EscapeDataString($WorkflowName)
            $run = [uri]::EscapeDataString($RunName)
            $expected = "$prefix/Microsoft.Logic/workflows/$workflow/runs/$run/actions/Compose_expiration?api-version=2019-05-01"
        }
    }

    $uri = [uri] $expected
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'management.azure.com' -or
        $uri.AbsoluteUri -cne $expected) {
        throw 'The normalized Azure Resource Manager URI does not match the exact allowed endpoint.'
    }
    return $uri
}

function Invoke-HealthArmGet {
    param(
        [Parameter(Mandatory)][ValidateSet('connection', 'workflowRuns', 'expirationAction')][string] $Endpoint,
        [AllowNull()][object] $WorkflowName,
        [AllowNull()][object] $RunName
    )
    $uri = New-HealthArmUri -Endpoint $Endpoint -WorkflowName $WorkflowName -RunName $RunName
    $context = Get-HealthValidationContext
    $token = Get-HealthManagementToken -SubscriptionId $context.subscriptionId
    Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $token" } `
        -ConnectionTimeoutSeconds 10 -OperationTimeoutSeconds 30
}

function Get-HealthLatestWorkflowRun {
    param([Parameter(Mandatory)][object] $WorkflowName)
    @((Invoke-HealthArmGet -Endpoint workflowRuns -WorkflowName $WorkflowName).value) | Select-Object -First 1
}

function Get-HealthFiniteStatus {
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string[]] $Allowed)
    if ($Value -isnot [string]) { return 'Unknown' }
    foreach ($status in $Allowed) {
        if ([string]::Equals($Value, $status, [StringComparison]::Ordinal)) { return $status }
    }
    return 'Unknown'
}

function ConvertTo-HealthUtcTimestamp {
    param([AllowNull()][object] $Value)

    $timestamp = if ($Value -is [datetimeoffset]) {
        $Value
    }
    elseif ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return $null }
        [datetimeoffset] $Value
    }
    elseif ($Value -is [string] -and $Value.Length -le 64 -and
        $Value -cmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        $parsed = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($Value, [cultureinfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref] $parsed)) {
            return $null
        }
        $parsed
    }
    else { return $null }

    return $timestamp.UtcDateTime.ToString('o', [cultureinfo]::InvariantCulture)
}

function Get-HealthConnectionReadinessOutcome {
    $context = Get-HealthValidationContext
    $connection = Invoke-HealthArmGet -Endpoint connection
    $firstStatus = @($connection.properties.statuses) | Select-Object -First 1
    $status = Get-HealthFiniteStatus -Value $(if ($null -eq $firstStatus) { $null } else { $firstStatus.status }) `
        -Allowed @('Authenticated', 'Connected', 'Ready', 'Error', 'Disconnected', 'Unauthenticated')
    if ($status -in 'Authenticated', 'Connected', 'Ready') {
        return New-AzdCheckOutcome -Status pass -Summary 'The Teams managed connection reports ready.' `
            -Expected @{ state = 'ready' } -Actual @{ state = 'ready'; providerStatus = $status } `
            -Evidence @{ source = 'arm.connectionResource' }
    }
    New-AzdCheckFailure -Code 'connection.notReady' -Summary 'The Teams managed connection does not report ready.' `
        -Expected @{ state = 'ready' } -Details @{ state = 'notReady'; providerStatus = $status } `
        -Remediation 'Reauthorize the existing Teams connection and rerun validation.'
}

function Get-HealthSubscriptionFreshnessOutcome {
    $context = Get-HealthValidationContext
    $run = Get-HealthLatestWorkflowRun -WorkflowName $context.lifecycleWorkflow
    if ($null -eq $run -or $null -eq $run.name) {
        return New-AzdCheckOutcome -Status warning -Summary 'Subscription freshness is unknown because no lifecycle run is available.' `
            -Expected @{ state = 'fresh' } -Actual @{ state = 'unknown'; reason = 'noLifecycleRun' } `
            -Evidence @{ source = 'arm.lifecycleRunAction' } -Remediation 'Run or await the lifecycle workflow, then rerun validation.'
    }

    try { Assert-HealthNameSegment -Name 'runName' -Value $run.name -Kind run }
    catch {
        return New-AzdCheckOutcome -Status warning -Summary 'Subscription freshness is unavailable because the lifecycle run identifier is invalid.' `
            -Expected @{ state = 'fresh' } -Actual @{ state = 'unknown'; reason = 'invalidRunEvidence' } `
            -Evidence @{ source = 'arm.lifecycleRunAction' } -Remediation 'Inspect the latest lifecycle run through an authorized path.'
    }

    try {
        $action = Invoke-HealthArmGet -Endpoint expirationAction -WorkflowName $context.lifecycleWorkflow -RunName $run.name
        $actionStatus = Get-HealthFiniteStatus -Value $action.properties.status -Allowed @('Succeeded')
        $expirationUtc = ConvertTo-HealthUtcTimestamp -Value $action.properties.outputs.body
        if ($actionStatus -cne 'Succeeded' -or $null -eq $expirationUtc) {
            throw 'Expiration evidence is unavailable.'
        }
        $expiration = [datetimeoffset]::ParseExact($expirationUtc, 'o', [cultureinfo]::InvariantCulture)
    }
    catch {
        return New-AzdCheckOutcome -Status warning -Summary 'Subscription freshness is unavailable from the safe lifecycle action.' `
            -Expected @{ state = 'fresh' } -Actual @{ state = 'unknown'; reason = 'expirationActionUnavailable' } `
            -Evidence @{ source = 'arm.lifecycleRunAction' } -Remediation 'Inspect the exact lifecycle run and Graph subscription through an authorized path.'
    }

    $remainingHours = [math]::Floor(($expiration.ToUniversalTime() - [datetimeoffset]::UtcNow).TotalHours)
    $plannedState = if ($remainingHours -lt 0) { 'past' } elseif ($remainingHours -le 168) { 'near' } else { 'future' }
    New-AzdCheckOutcome -Status warning `
        -Summary 'Current Graph subscription freshness is unknown; the lifecycle run only records a requested expiration.' `
        -Expected @{ state = 'fresh' } `
        -Actual @{ state = 'unknown'; reason = 'noAuthoritativeGraphRead'; requestedExpirationUtc = $expirationUtc; requestedExpirationState = $plannedState; remainingHours = $remainingHours } `
        -Evidence @{ source = 'arm.lifecycleRunAction'; semantics = 'requestedExpirationOnly' } `
        -Remediation 'Verify the exact owned subscription and its accepted expiration through an authorized Graph read path.'
}

function Get-HealthWorkflowRunOutcome {
    $context = Get-HealthValidationContext
    $runs = [ordered]@{}
    foreach ($entry in @(
        @{ key = 'alert'; name = $context.alertWorkflow },
        @{ key = 'lifecycle'; name = $context.lifecycleWorkflow }
    )) {
        $run = Get-HealthLatestWorkflowRun -WorkflowName $entry.name
        $runs[$entry.key] = if ($null -eq $run) {
            [ordered]@{ state = 'unknown'; reason = 'noRun' }
        }
        else {
            $status = Get-HealthFiniteStatus -Value $run.properties.status `
                -Allowed @('Succeeded', 'Failed', 'Cancelled', 'Aborted', 'TimedOut', 'Running', 'Waiting', 'Skipped', 'Paused')
            $startedAt = ConvertTo-HealthUtcTimestamp -Value $run.properties.startTime
            try {
                Assert-HealthNameSegment -Name 'runName' -Value $(if ($run.name -is [string]) { $run.name } else { '' }) -Kind run
                $validRun = $true
            }
            catch { $validRun = $false }

            if ($status -eq 'Unknown' -or $null -eq $startedAt -or -not $validRun) {
                [ordered]@{ state = 'unknown'; reason = 'invalidRunEvidence' }
            }
            else {
                [ordered]@{ state = $status; startedAt = $startedAt }
            }
        }
    }

    $failed = @($runs.Values | Where-Object { $_.state -in 'Failed', 'Cancelled', 'Aborted', 'TimedOut' })
    if ($failed.Count -gt 0) {
        return New-AzdCheckFailure -Code 'workflow.runFailed' -Summary 'At least one latest workflow run failed.' `
            -Expected @{ state = 'Succeeded' } -Details @{ runs = $runs } -Remediation 'Inspect the exact failed Logic App run.'
    }
    if (@($runs.Values | Where-Object state -cne 'Succeeded').Count -gt 0) {
        return New-AzdCheckOutcome -Status warning -Summary 'Latest workflow-run evidence is incomplete or still in progress.' `
            -Expected @{ state = 'Succeeded' } -Actual @{ runs = $runs } -Evidence @{ source = 'arm.workflowRuns' } `
            -Remediation 'Await a completed run for each workflow and rerun validation.'
    }
    New-AzdCheckOutcome -Status pass -Summary 'The latest alert and lifecycle workflow runs succeeded.' `
        -Expected @{ state = 'Succeeded' } -Actual @{ runs = $runs } -Evidence @{ source = 'arm.workflowRuns' }
}

function Get-HealthRecipientReceiptOutcome {
    New-AzdCheckOutcome -Status warning -Summary 'Recipient receipt is unknown until a recipient confirms the Teams message.' `
        -Expected @{ state = 'confirmed' } `
        -Actual @{ state = 'unknown'; inferredFromConnection = $false; inferredFromWorkflowRun = $false } `
        -Evidence @{ source = 'externalRecipientConfirmation'; collected = $false } `
        -Remediation 'Send or await an entitled health alert and retain separate recipient confirmation.'
}

function Get-ProjectValidationDefinition {
    @(
        New-AzdValidationCheckDefinition -Id 'connection.readiness' -Phase infrastructure `
            -Title 'Teams connection readiness' -Summary 'Read the existing managed-connection status.' `
            -Action { Get-HealthConnectionReadinessOutcome } -SideEffect readOnly
        New-AzdValidationCheckDefinition -Id 'subscription.freshness' -Phase runtime `
            -Title 'Graph subscription freshness' -Summary 'Read safe expiration evidence from the latest lifecycle run.' `
            -Action { Get-HealthSubscriptionFreshnessOutcome } -SideEffect readOnly
        New-AzdValidationCheckDefinition -Id 'workflow.latest-runs' -Phase runtime `
            -Title 'Latest workflow runs' -Summary 'Read the latest alert and lifecycle workflow run states.' `
            -Action { Get-HealthWorkflowRunOutcome } -SideEffect readOnly
        New-AzdValidationCheckDefinition -Id 'recipient.receipt' -Phase delivery `
            -Title 'Recipient receipt' -Summary 'Keep recipient confirmation separate from provider and workflow evidence.' `
            -Action { Get-HealthRecipientReceiptOutcome } -SideEffect none
    )
}

Export-ModuleMember -Function @(
    'Get-HealthConnectionReadinessOutcome',
    'Get-HealthRecipientReceiptOutcome',
    'Get-HealthSubscriptionFreshnessOutcome',
    'Get-HealthValidationContext',
    'Get-HealthWorkflowRunOutcome',
    'Get-ProjectValidationDefinition'
)
