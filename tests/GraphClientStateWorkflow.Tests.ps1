BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $bicep = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/main.bicep') -Raw
    $parameters = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/main.parameters.json') -Raw | ConvertFrom-Json
    $receiver = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/workflow-definition.json') -Raw | ConvertFrom-Json -Depth 100
    $lifecycle = Get-Content -LiteralPath (Join-Path $repoRoot 'infra/lifecycle-workflow-definition.json') -Raw | ConvertFrom-Json -Depth 100

    function Get-MockedLifecycleDecision {
        param($List, $Detail, [string]$Callback, [string]$ClientState)
        if ($List.'@odata.nextLink') { return 'Reject' }
        $matches = @($List.value | Where-Object {
            $_.changeType -eq 'created' -and
            $_.resource -in @('/reports/healthmonitoring/alerts', 'reports/healthmonitoring/alerts') -and
            $_.notificationUrl -eq $Callback
        })
        if ($matches.Count -gt 1) { return 'Reject' }
        if ($matches.Count -eq 0) { return 'Create' }
        $listed = $matches[0]
        if ($null -eq $Detail -or $Detail.id -ne $listed.id -or
            $Detail.notificationUrl -ne $Callback -or $Detail.changeType -ne 'created' -or
            $Detail.resource -notin @('/reports/healthmonitoring/alerts', 'reports/healthmonitoring/alerts') -or
            $Detail.clientState -cne $ClientState) { return 'Reject' }
        return 'Renew'
    }

    function Get-WorkflowActions {
        param($Actions)
        foreach ($entry in $Actions.PSObject.Properties) {
            $entry.Value
            if ($entry.Value.actions) { Get-WorkflowActions -Actions $entry.Value.actions }
            if ($entry.Value.else -and $entry.Value.else.actions) {
                Get-WorkflowActions -Actions $entry.Value.else.actions
            }
        }
    }

    function Assert-SiblingDependencies {
        param($Actions)
        $names = @($Actions.PSObject.Properties.Name)
        foreach ($entry in $Actions.PSObject.Properties) {
            $action = $entry.Value
            $prior = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $pending = [Collections.Generic.Stack[string]]::new()
            foreach ($dependency in @($action.runAfter.PSObject.Properties.Name | Where-Object { $_ })) {
                if ($dependency -notin $names) { throw "Unknown runAfter dependency '$dependency' for '$($entry.Name)'." }
                $pending.Push($dependency)
            }
            while ($pending.Count -gt 0) {
                $dependency = $pending.Pop()
                if ($prior.Add($dependency)) {
                    foreach ($earlier in @($Actions.$dependency.runAfter.PSObject.Properties.Name | Where-Object { $_ })) {
                        $pending.Push($earlier)
                    }
                }
            }
            $ownInputs = @{
                expression = $action.expression
                inputs = $action.inputs
                foreach = $action.foreach
            } | ConvertTo-Json -Depth 100 -Compress
            foreach ($match in [regex]::Matches($ownInputs, "(?:outputs|body|actions)\('([^']+)'\)")) {
                $referenced = $match.Groups[1].Value
                if ($referenced -in $names -and -not $prior.Contains($referenced)) {
                    throw "'$($entry.Name)' references sibling '$referenced' without a runAfter path."
                }
            }
            if ($action.actions) { Assert-SiblingDependencies -Actions $action.actions }
            if ($action.else -and $action.else.actions) { Assert-SiblingDependencies -Actions $action.else.actions }
        }
    }

    function Assert-UniqueJsonProperties {
        param([System.Text.Json.JsonElement]$Element, [string]$Path)
        if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $seen.Add($property.Name)) { throw "Duplicate JSON property at $Path/$($property.Name)." }
                Assert-UniqueJsonProperties -Element $property.Value -Path "$Path/$($property.Name)"
            }
        }
        elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
            $index = 0
            foreach ($item in $Element.EnumerateArray()) {
                Assert-UniqueJsonProperties -Element $item -Path "$Path/$index"
                $index++
            }
        }
    }
}

Describe 'Graph notification clientState workflow' {
    It 'uses the Key Vault backed secure deployment parameter in both workflows' {
        $bicep | Should -Match '@secure\(\)\s+@minLength\(43\)\s+@maxLength\(43\)\s+param graphSubscriptionClientState string'
        $bicep | Should -Not -Match 'guid\([^\r\n]*graph-subscription-client-state'
        $parameters.parameters.graphSubscriptionClientState.value | Should -Be '${GRAPH_SUBSCRIPTION_CLIENT_STATE}'
        $receiver.parameters.GraphSubscriptionClientState.type | Should -Be 'securestring'
        $lifecycle.parameters.GraphSubscriptionClientState.type | Should -Be 'securestring'
        $lifecycle.parameters.NotificationUrl.type | Should -Be 'securestring'
    }

    It 'lists by callback then GETs the exact ID before any renewal' {
        $actions = $lifecycle.actions
        $actions.Filter_callback_subscriptions.inputs.where | Should -Match "equals\(item\(\)\?\['notificationUrl'\], parameters\('NotificationUrl'\)\)"
        $actions.Filter_callback_subscriptions.inputs.where | Should -Not -Match 'clientState'
        $actions.Listing_is_ambiguous.inputs | Should -Match '@odata.nextLink'
        $actions.Listing_is_ambiguous.inputs | Should -Match 'greater\(length\(body\(''Filter_callback_subscriptions''\)\), 1\)'
        $actions.Assert_subscription_ownership.actions.Stop_on_incomplete_or_mismatched_subscription.type | Should -Be 'Terminate'
        $actions.Check_existing_subscription.expression.equals[0] | Should -Be "@outputs('Has_callback_subscription')"
        $detailActions = $actions.Check_existing_subscription.else.actions
        $detailActions.Get_subscription_by_id.inputs.method | Should -Be 'GET'
        $detailActions.Get_subscription_by_id.inputs.uri | Should -Be "https://graph.microsoft.com/beta/subscriptions/@{outputs('Get_matching_subscription')?['id']}"
        $detailActions.Verify_subscription_ownership.runAfter.Get_subscription_by_id | Should -Contain 'Succeeded'
        foreach ($field in @('id', 'notificationUrl', 'changeType', 'resource', 'clientState')) {
            $detailActions.Verify_subscription_ownership.inputs | Should -Match "\['$field'\]"
        }
        $detailActions.Verify_subscription_ownership.inputs | Should -Match "parameters\('GraphSubscriptionClientState'\)"
        $detailActions.Stop_on_subscription_mismatch.actions.Fail_on_subscription_mismatch.type | Should -Be 'Terminate'
        $detailActions.Compose_expiration.runAfter.Stop_on_subscription_mismatch | Should -Contain 'Succeeded'
    }

    It 'renews a callback-bound subscription when list hides clientState but detail matches' {
        $callback = 'https://example.invalid/signed-callback'
        $state = 'SyntheticStateOnly'
        $item = [pscustomobject]@{
            id = '6f0a16f8-36e5-4008-a1e2-37a406bd5c6e'
            resource = '/reports/healthmonitoring/alerts'
            changeType = 'created'
            notificationUrl = $callback
            clientState = $null
        }
        $list = [pscustomobject]@{ value = @($item) }
        $detail = [pscustomobject]@{
            id = $item.id; resource = $item.resource; changeType = $item.changeType
            notificationUrl = $callback; clientState = $state
        }
        Get-MockedLifecycleDecision -List $list -Detail $detail -Callback $callback -ClientState $state | Should -Be 'Renew'
        $detail.clientState = 'DifferentState'
        Get-MockedLifecycleDecision -List $list -Detail $detail -Callback $callback -ClientState $state | Should -Be 'Reject'
        $detail.clientState = $state
        $detail.notificationUrl = 'https://example.invalid/other'
        Get-MockedLifecycleDecision -List $list -Detail $detail -Callback $callback -ClientState $state | Should -Be 'Reject'
        $detail.notificationUrl = $callback
        $list | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue 'https://graph.microsoft.com/beta/subscriptions?skiptoken=more'
        Get-MockedLifecycleDecision -List $list -Detail $detail -Callback $callback -ClientState $state | Should -Be 'Reject'
        $list.'@odata.nextLink' = $null
        $list.value = @($item, $item)
        Get-MockedLifecycleDecision -List $list -Detail $detail -Callback $callback -ClientState $state | Should -Be 'Reject'
        $list.value = @()
        Get-MockedLifecycleDecision -List $list -Detail $null -Callback $callback -ClientState $state | Should -Be 'Create'
    }

    It 'uses supported secure-data settings and passes sanitized values to controls' {
        $receiver.triggers.When_a_HTTP_request_is_received.runtimeConfiguration.secureData.properties | Should -Contain 'inputs'
        $lifecycle.actions.List_subscriptions.runtimeConfiguration.secureData.properties | Should -Contain 'outputs'
        $lifecycle.actions.Check_existing_subscription.actions.Create_subscription.runtimeConfiguration.secureData.properties | Should -Contain 'inputs'
        $lifecycle.actions.Check_existing_subscription.else.actions.Get_subscription_by_id.runtimeConfiguration.secureData.properties | Should -Contain 'outputs'
        $select = $receiver.actions.Check_for_validation_token.else.actions.Select_notifications
        $select.runtimeConfiguration.secureData.properties | Should -Contain 'outputs'
        @($select.inputs.select.PSObject.Properties.Name | Sort-Object) | Should -Be @('alertId', 'subscriptionExpirationDateTime', 'valid')
        $receiver.actions.Check_for_validation_token.else.actions.Check_for_notifications.actions.For_each_notification.foreach | Should -Be "@union(body('Select_notifications'), body('Select_notifications'))"
        foreach ($workflow in @($receiver, $lifecycle)) {
            foreach ($action in @(Get-WorkflowActions -Actions $workflow.actions)) {
                $properties = @($action.runtimeConfiguration.secureData.properties | Where-Object { $null -ne $_ })
                if ($action.type -in @('If', 'Foreach')) {
                    $properties.Count | Should -Be 0
                    if ($action.type -eq 'If') {
                        ($action.expression | ConvertTo-Json -Compress -Depth 20) | Should -Not -Match 'GraphSubscriptionClientState|NotificationUrl|clientState|triggerBody'
                    }
                }
                if ($action.type -eq 'Compose') { $properties | Should -Not -Contain 'outputs' }
            }
        }
    }

    It 'rejects duplicate workflow JSON properties and preserves the validation dependency' {
        foreach ($file in @('infra/workflow-definition.json', 'infra/lifecycle-workflow-definition.json')) {
            $document = [System.Text.Json.JsonDocument]::Parse((Get-Content -LiteralPath (Join-Path $repoRoot $file) -Raw))
            try { Assert-UniqueJsonProperties -Element $document.RootElement -Path $file }
            finally { $document.Dispose() }
        }
        $receiver.actions.Check_for_validation_token.runAfter.Has_validation_token | Should -Contain 'Succeeded'
    }

    It 'orders sibling output and body references after their producers' {
        { Assert-SiblingDependencies -Actions $receiver.actions } | Should -Not -Throw
        { Assert-SiblingDependencies -Actions $lifecycle.actions } | Should -Not -Throw
    }
}
