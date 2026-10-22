# Development and publishing

Contributor checks should be run from a clean checkout and must not use device-code authentication or tenant writes.

Registered validation requires PowerShell 7.6+, Pester 6.2.0, and an explicit
local Bicep executable so an offline run never installs a compiler implicitly:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser -Force
./scripts/Test-Repository.ps1 -BicepPath C:\path\to\bicep.exe
```

The command parses PowerShell and JSON, verifies every locked component hash,
runs the full test suite, and compiles the Bicep template. It performs no Azure,
Graph, connector, workflow, or delivery operation. It records the actual runtime
and Pester versions and rejects empty, skipped, inconclusive or unexecuted tests.
CI selects a SHA-256-verified PowerShell 7.6.6 runtime and imports the same exact
Pester version.

The locked deployment-validation 2.0.0 bundle at Reference revision
`2b2e784ba11822272c0e4b8389976f95afafa9b9` declares
`PowerShellVersion = '7.6'`, matching this repository's supported tooling.
Update the bundle only through a
reviewed canonical component release and lock refresh. Git keeps these locked
files and permission-evidence sources as LF bytes so Windows checkouts preserve
the recorded SHA-256 values.

Validate README links and ensure the root quickstart remains the exact default-branch `azd init -t` command. A real `azd init`/`azd up` smoke test requires an administrator's explicit Azure and Teams consent and is outside documentation-only validation. Publish changes through the default branch after local checks and hosted CI.

## Synthetic Azure workflow validation

After authorization for the selected commercial Azure lab, run the fixture harness with explicit subscription and tenant IDs and a fresh artifact directory outside the checkout:

```powershell
pwsh ./tests/Invoke-SyntheticWorkflowValidation.ps1 `
  -SubscriptionId '<lab-subscription-id>' -TenantId '<lab-tenant-id>' `
  -ExpectedOperatorObjectId '<approved-operator-object-id>' `
  -RunId '<approved-run-guid>' -ResourceGroupName 'rg-azd-health-fixtures-<first-12-run-guid-hex-digits>' `
  -ArtifactDirectory 'C:\lab-evidence\health-fixtures-new-attempt'
```

The harness uses cached standard Azure CLI authentication, creates a new tagged resource group, and runs copies of the actual receiver and lifecycle definitions in Azure Logic Apps. Graph actions call a synthetic HTTP stub; Teams actions become synthetic Compose actions. Each copied definition must contain no Graph endpoint, managed-identity authentication or connector dependency before deployment. No Graph subscriptions, role assignments or Teams messages are created. Signed fixture callbacks and ARM tokens remain in memory.

Fixtures cover malformed and ignored notifications, validation-token responses, duplicate normalization within one batch, create/renew decisions, missing subscription details, ambiguous or incomplete listings, and transient list/renewal failures. Lab retry timing is shortened and synthetic run data is visible for assertions. These results establish workflow-engine behavior, not actual Graph renewal, Teams receipt, production privacy configuration or cross-request deduplication.

The harness deletes only its exact tagged group after checking its expected resource inventory and direct role assignments, then polls for absence. Keep every attempt's receipt, including failures. If cleanup is incomplete or ownership checks fail, use the receipt's exact subscription, resource-group and expected resource IDs to investigate; do not retry in the same artifact directory or remove unverified resources.

Bind the run GUID, group, actor, source hashes and proposed costs in the reviewed
action procedure before invoking this Azure harness. It requires a fresh enabled
subscription and matching cached actor/tenant/token audience. It has a 960-second
workload window and a 1,200-second overall cooperative deadline, 30-second CLI/HTTP
requests, a 1 MiB HTTP response cap, no redirects and a 1,000-request ceiling.
Use an outer process supervisor in the approved procedure; the cooperative
deadline does not bound a stalled filesystem or runtime initialization.

Intent is flushed to a separate append-only journal before each resource write
or synthetic invocation; snapshot receipts do not replace that history. Run status
comes from the exact run ID returned by the callback, rather than the latest run.
If the service omits that identity, the outcome is unknown and the group is
preserved. Unknown creation or invocation outcomes also prohibit deletion.
Cleanup requires two matching complete resource inventories, completed workflow
provisioning, terminal runs, no target or ancestor locks, and no direct or
descendant role grants. It submits at most one group DELETE and accepts absence
only from the exact ResourceGroupNotFound response. An uncertain DELETE response
starts bounded same-group GET observation without another DELETE, even when the
post-delete snapshot cannot be written; such an evidence failure stays unqualified.
Any refusal leaves evidence
for a separate recovery decision. These checks are observations, not an atomic
lock against another administrator changing the group concurrently.
