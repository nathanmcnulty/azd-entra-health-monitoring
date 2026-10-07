# Operations

## Verify

After deployment, inspect the printed resource group, Logic App names, and Teams connection status. In the Azure portal, confirm the lifecycle workflow has a successful run and the alert workflow is enabled. Confirm delivery with an actual health alert when one is available to the tenant.

The status script prints the current Logic App names, Teams connection status, and latest lifecycle run:

```powershell
pwsh ./scripts/status.ps1
```

The receiver validates declared notification field types before processing. Missing change types, mismatched `clientState` and empty alert IDs do not reach alert lookup or delivery. Identical normalized notifications in one batch are processed once; separate webhook requests can still deliver the same alert more than once. Acknowledging a request does not establish Teams receipt. A failed lifecycle renewal explicitly fails the workflow even if its warning relay succeeds.

## Rerun and recover

The prompts reuse values stored in the `azd` environment. If Teams consent was skipped or interrupted, complete the browser flow and run:

```powershell
azd hooks run postprovision
```

The Graph role assignments and subscription lifecycle operations are designed to be idempotent. A 403 while assigning a Graph application role requires a **Global Administrator or Privileged Role Administrator** to complete or authorize the Graph consent/assignment step; a Teams or Azure role cannot substitute for it. Investigate the exact Azure, Teams, and Graph error before rerunning; do not bypass consent or tenant validation.

The Graph notification `clientState` is generated once as a random Key Vault secret and reused by every ordinary redeployment. Graph's subscription list omits `clientState`; the lifecycle workflow stops if that listing has another page or multiple matches for the exact callback, then retrieves the sole matching subscription by ID and verifies its callback, resource, change type, and `clientState` before renewal. A missing or mismatched detail response fails closed. The workflow does not adopt, renew, or delete a mismatched subscription. A legacy deployment with no `GRAPH_SUBSCRIPTION_CLIENT_STATE` Key Vault reference also stops before changing the receiver. These cases require the following explicit migration or rotation procedure:

1. Confirm the selected AzureCloud tenant, subscription, resource group, and alert/lifecycle workflows. Disable `la-graph-subscription-management` in the Azure portal and verify its state is **Disabled**. Keep the alert workflow available until the old subscription is gone.
2. Using an authorized Graph context that can see the lifecycle managed identity's subscriptions, enumerate **all pages** of `/beta/subscriptions`. A Global Administrator with the delegated `Subscription.Read.All` permission [can inventory subscriptions from other apps](https://learn.microsoft.com/en-us/graph/api/subscription-list?view=graph-rest-1.0); a normal delegated listing may omit the managed identity's subscription. In memory, compare the full signed alert callback URL from the alert trigger's Azure management `listCallbackUrl` operation with each subscription's `notificationUrl`. Identify exactly one subscription with that callback, `changeType: created`, and resource `/reports/healthmonitoring/alerts` (with or without the leading slash). Because the list omits `clientState`, retrieve that ID through [GET `/beta/subscriptions/{id}`](https://learn.microsoft.com/en-us/graph/api/subscription-get?view=graph-rest-beta) and verify the same ID, callback, resource, change type, and clientState against the current Key Vault secret or the legacy deployed value in memory. Do not display, save, or paste the callback URL or clientState. If the listing or detail is incomplete, ambiguous, mismatched, or inaccessible, stop.
3. Through an authorized Graph administration path, remove **only that verified subscription ID**, or wait for its confirmed expiration if the authorized context cannot delete it. Verify a complete listing no longer contains the exact callback-bound subscription. This creates a notification gap until the new subscription is created; plan the change window accordingly. Do not remove other health-alert subscriptions.
4. For a legacy deterministic-state deployment, set `GRAPH_SUBSCRIPTION_MIGRATION_READY=true` in the current `azd` environment and run `azd provision`. The hook requires the lifecycle workflow to remain Disabled and then creates the protected random secret. Set the marker back to `false` afterward. For a later deliberate rotation of an already protected deployment, run `pwsh ./scripts/Rotate-GraphClientState.ps1 -VerifiedSubscriptionAbsent` while the lifecycle workflow is Disabled, then run `azd provision`. The rotation script creates a new Key Vault secret version; it never prints the value or changes the `akvs://` reference.
5. Complete postprovision consent if needed. Run or await the lifecycle workflow, verify one new Graph subscription is bound to the exact callback and its run succeeded, and confirm an actual health alert reaches the Teams channel. If renewal or creation fails, leave the mismatch fail-closed and investigate; do not restore an unverified subscription.

The rotation flag is an operator assertion of step 3, not a Graph deletion command. The [Graph subscription PATCH operation](https://learn.microsoft.com/en-us/graph/api/subscription-update?view=graph-rest-1.0) cannot change `clientState`, and a [duplicate POST](https://learn.microsoft.com/en-us/graph/api/subscription-post-subscriptions?view=graph-rest-1.0) for the same resource/change type can return 409. Never overwrite the Key Vault secret in place while the old subscription is active.

## Prepare a historical callback exposure assessment

This preparation does not assert that any environment, host history, pipeline, or retained artifact has been assessed. Complete the target-bound inventory and obtain separate approval before rotating an access key, changing a Graph subscription, deleting an environment value or artifact, or testing delivery.

The alert workflow callback is a signed bearer credential. Its Logic Apps Primary access key and the Graph subscription `clientState` are separate credentials: regenerating the callback access key does not rotate `clientState`, and rotating `clientState` does not invalidate a callback URL. Microsoft documents that [regenerating an access key invalidates URLs signed with the old key](https://learn.microsoft.com/en-us/azure/logic-apps/set-up-security-permissions#regenerate-access-keys). The current template's `listCallbackUrl` call uses Logic Apps' default Primary key and passes the result directly into the lifecycle workflow's secure `NotificationUrl` parameter.

Prepare a redacted assessment packet with these boundaries:

1. Record the selected AzureCloud tenant and subscription, resource group, alert workflow resource ID, lifecycle workflow resource ID, and alert trigger resource ID ending in `/triggers/When_a_HTTP_request_is_received`. Verify that every resource is owned by the selected `azd` environment. Record IDs and states only; do not record a callback URL, signature, `clientState`, token, or other secret.
2. Inventory the exact `azd` environment names through a name-only metadata source. For each selected environment, use an approved value-safe check that returns only whether the legacy key `GRAPH_NOTIFICATION_URL` exists. Do not run `azd env get-values` or `azd env get-value` interactively because those commands can disclose values. Stop if presence cannot be established without exposing the value.
3. Identify locations that an authorized operator must assess for pre-PR #8 disclosure: terminal scrollback or transcripts, local command logs, CI run logs and artifacts, issue or support attachments, copied deployment output, and retained environment backups. For each location, record only its owner, retention boundary, assessment state, and an opaque evidence reference. Never inspect or copy secret-bearing content into the packet. An unassessed or inaccessible location remains an explicit gap.
4. Define the impact window before requesting rotation. Disabling `la-graph-subscription-management`, removing or expiring the exact verified Graph subscription, and regenerating the Primary access key create a notification gap until provisioning refreshes the lifecycle workflow and a new subscription is verified. Regeneration also invalidates every callback URL for a request trigger in the exact alert workflow that was signed with the old Primary key; inventory those consumers before requesting the action.

If the assessment supports a separate rotation request, bind that request to the recorded resource IDs and require this fail-closed sequence:

1. Disable the exact lifecycle workflow and verify **Disabled**. Use the complete-list and exact-detail ownership checks in the preceding procedure to identify the sole Graph subscription bound to the alert callback. Enumerate all pages and stop if any page or continuation cannot be retrieved, or on ambiguity, mismatch, missing access, or any target drift.
2. Through a separately authorized Graph administration path, delete only the verified subscription ID or wait for its confirmed expiration. Verify its absence from a complete listing. Do not alter another subscription.
3. Through a separately authorized Azure management path, use the [workflow access-key API](https://learn.microsoft.com/en-us/rest/api/logic/workflows/regenerate-access-key?view=rest-logic-2019-05-01) exactly against `POST {alert-workflow-resource-id}/regenerateAccessKey?api-version=2019-05-01` with body `{ "keyType": "Primary" }`. Stop unless the response succeeds for the recorded tenant, subscription, resource group, and workflow. Never print or retain the old or new callback URL.
4. During the controlled change window, run `azd provision` for the exact selected environment. The current template calls `listCallbackUrl` for `When_a_HTTP_request_is_received`, passes the result into the lifecycle workflow's secure `NotificationUrl` parameter, and sets that workflow's state to **Enabled**. Provisioning is therefore the release point: the recurrence can run as soon as deployment re-enables the lifecycle workflow. Immediately verify successful deployment, the exact target binding without reading the URL, the Enabled state, and the first lifecycle run. If any of those checks fails or cannot be completed, disable the exact lifecycle workflow and stop.
5. Allow the Graph subscription to be recreated only through that ordinary lifecycle path. Verify the sole subscription's exact ID, callback, resource, change type, and `clientState` using the value-safe checks above. Actual alert receipt remains a separate delivery gate.
6. Only after successful recreation and verification, request separate approval to remove the one legacy `GRAPH_NOTIFICATION_URL` entry and any confirmed historical artifacts under their owners' retention rules. If any step fails, keep the lifecycle workflow disabled, preserve the redacted evidence, and do not delete environment entries or historical records.

The completion receipt contains the selected resource IDs, old-subscription ID and absence result, access-key operation status, deployment and lifecycle run IDs, new-subscription ID, timestamps, assessment state for each historical location, and approved cleanup outcomes. It never contains callback URLs, signatures, `clientState`, environment values, tokens, message data, or copied log content.

## Cleanup

```powershell
azd down --purge --force
```

This removes the Azure resources owned by the environment, including both Logic Apps, managed identities, the Teams connection, the environment-bound Key Vault, and supporting deployment resources. Key Vault soft-delete retention can reserve the vault name after deletion; recover or separately purge it only after verifying ownership. There is no pre-down hook that deletes the tenant-side Graph subscription. Review and remove any remaining subscription explicitly through the authoritative Graph administration path if required.
