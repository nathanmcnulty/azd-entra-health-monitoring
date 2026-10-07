# Development and publishing

Contributor checks should be run from a clean checkout and must not use device-code authentication or tenant writes.

Recommended validation:

```powershell
Test-Path .\azure.yaml
az bicep build --file .\infra\main.bicep --stdout | Out-Null
pwsh -NoProfile -Command 'Get-ChildItem .\scripts -Filter *.ps1 | ForEach-Object { [scriptblock]::Create((Get-Content -Raw $_.FullName)) | Out-Null }; Invoke-Pester -Path .\tests'
```

Validate README links and ensure the root quickstart remains the exact default-branch `azd init -t` command. A real `azd init`/`azd up` smoke test requires an administrator's explicit Azure and Teams consent and is outside documentation-only validation. Publish changes through the default branch after local checks and hosted CI.

## Synthetic Azure workflow validation

After authorization for the selected commercial Azure lab, run the fixture harness with explicit subscription and tenant IDs and a fresh artifact directory outside the checkout:

```powershell
pwsh ./tests/Invoke-SyntheticWorkflowValidation.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ArtifactDirectory 'C:\lab-evidence\health-fixtures-new-attempt'
```

The harness uses cached standard Azure CLI authentication, creates a new tagged resource group, and runs copies of the actual receiver and lifecycle definitions in Azure Logic Apps. Graph actions call a synthetic HTTP stub; Teams actions become synthetic Compose actions. Each copied definition must contain no Graph endpoint, managed-identity authentication or connector dependency before deployment. No Graph subscriptions, role assignments or Teams messages are created. Signed fixture callbacks and ARM tokens remain in memory.

Fixtures cover malformed and ignored notifications, validation-token responses, duplicate normalization within one batch, create/renew decisions, missing subscription details, ambiguous or incomplete listings, and transient list/renewal failures. Lab retry timing is shortened and synthetic run data is visible for assertions. These results establish workflow-engine behavior, not actual Graph renewal, Teams receipt, production privacy configuration or cross-request deduplication.

The harness deletes only its exact tagged group after checking its expected resource inventory and direct role assignments, then polls for absence. Keep every attempt's receipt, including failures. If cleanup is incomplete or ownership checks fail, use the receipt's exact subscription, resource-group and expected resource IDs to investigate; do not retry in the same artifact directory or remove unverified resources.
