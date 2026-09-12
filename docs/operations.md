# Operations

## Verify

After deployment, inspect the printed resource group, Logic App names, callback URL handling, and Teams connection status. In the Azure portal, confirm the lifecycle workflow has a successful run and the alert workflow is enabled. Confirm delivery with an actual health alert when one is available to the tenant.

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

## Cleanup

```powershell
azd down --purge --force
```

This removes the Azure resources owned by the environment, including both Logic Apps, managed identities, the Teams connection, and supporting deployment resources. There is no pre-down hook that deletes the tenant-side Graph subscription. Review and remove any remaining subscription explicitly through the authoritative Graph administration path if required.
