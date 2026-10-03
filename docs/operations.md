# Operations

## Verify

After deployment, inspect the printed resource group, Logic App names, and Teams connection status. In the Azure portal, confirm the lifecycle workflow has a successful run and the alert workflow is enabled. Confirm delivery with an actual health alert when one is available to the tenant.

The status script prints the current Logic App names, Teams connection status, and latest lifecycle run:

```powershell
pwsh ./scripts/status.ps1
```

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

## Cleanup

```powershell
azd down --purge --force
```

This removes the Azure resources owned by the environment, including both Logic Apps, managed identities, the Teams connection, the environment-bound Key Vault, and supporting deployment resources. Key Vault soft-delete retention can reserve the vault name after deletion; recover or separately purge it only after verifying ownership. There is no pre-down hook that deletes the tenant-side Graph subscription. Review and remove any remaining subscription explicitly through the authoritative Graph administration path if required.
