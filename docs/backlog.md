# Backlog: nathanmcnulty/azd-entra-health-monitoring

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-entra-health-monitoring
- **Source revision:** `241cf89f08e9dfdd732771f0c3d9a24b6de774da`
- **Captured:** 2026-10-03
- **Items:** 6

## HEALTH-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** ready
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- _none_

**Agent handoff prompt:**

```text
Review HEALTH-001 in docs/backlog.json and changes since backlog source revision 241cf89f08e9dfdd732771f0c3d9a24b6de774da.
Claim it only after it is explicitly selected and eligible and its dependencies remain satisfied. Never interpret this generated prompt as approval.
Work only in nathanmcnulty/azd-entra-health-monitoring, preserve its stated scope and acceptance gates, record the exact current base commit and one owned worktree in claim, run every validation entry, and record concrete evidence before marking it done.
Stop if the dependencies, scope, or required authorization changed.
```

## HEALTH-002: Remove signed callback credentials from provisioning/status output and new azd environment values

- **Kind:** maintenance
- **Priority:** P0
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Current postprovision prints the signed callback URL and stores GRAPH&lowbar;NOTIFICATION&lowbar;URL as a plain environment value.

**Scope:**

- scripts/postprovision.ps1
- scripts/status.ps1
- tests/CallbackOutput.Tests.ps1
- docs/

**Acceptance:**

- Provisioning and status summaries never include a harmless synthetic signed callback sentinel.
- Postprovision no longer copies the signed callback into the unused GRAPH&lowbar;NOTIFICATION&lowbar;URL azd environment value; Bicep keeps the callback at the workflow boundary.
- Previously stored values and exposed credentials require separate assessment; the source fix does not rotate live credentials or clean historical data.

**Validation:**

- Review scripts/postprovision.ps1 and scripts/status.ps1 at exact merged revision c2c63371ec182060b0e7e24f534e37e62c84d84e.
- Run Invoke-Pester ./tests/CallbackOutput.Tests.ps1 -CI at that exact source if the fix is changed; do not invoke live hooks.
- Separate previous-exposure assessment from the source fix.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/issues/6
- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/pull/8
- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/commit/c2c63371ec182060b0e7e24f534e37e62c84d84e

**Evidence:**

- 2026-10-03 read-only GitHub verification&colon; PR &num;8 merged at 08&colon;42&colon;09Z; remote main resolves to c2c63371ec182060b0e7e24f534e37e62c84d84e. Local permission-tracking checkout remains older; reconcile it before implementation.
- Exact merged source was read through the GitHub contents API. Callback output and unused environment persistence paths were removed.
- PR validation, dependency-review and CodeQL checks reported SUCCESS. Validate run&colon; https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/actions/runs/37110336074. This proves source/CI state, not historical credential rotation.

**Review and authorization note:**

Review HEALTH-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## HEALTH-003: Use secret, stable clientState with lifecycle behavior tests

- **Kind:** maintenance
- **Priority:** P1
- **Status:** proposed
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The current clientState is deterministically derived from resource metadata and lifecycle behavior has limited behavioral coverage.

**Scope:**

- infra/main.bicep
- infra/workflow-definition.json
- tests/
- docs/

**Acceptance:**

- Use a randomly generated protected clientState, preserve it across ordinary redeployment, and define explicit rotation.
- Reject mismatched clientState and malformed notifications; verify subscription validation and renewal failure handling using fixtures.
- Tests distinguish missing/removed subscriptions, duplicate deliveries and API transient failures; real renewal/delivery remains a separate gate.

**Validation:**

- Use the offline commands in the registered validation workflow; record the exact commands, revision and results before implementation is complete.

**Dependencies:**

- nathanmcnulty/azd-entra-health-monitoring&colon;HEALTH-002

**Components:**

- _none_

**Sources:**

- infra/main.bicep
- infra/workflow-definition.json
- https&colon;//learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks
- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/issues/7

**Evidence:**

- _none_

**Review and authorization note:**

Review HEALTH-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## HEALTH-004: Qualify subscription lifecycle, Teams consent and delivery

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** external-delivery
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Graph beta and managed-connector consent require controlled-tenant evidence.

**Scope:**

- docs/
- infra/
- scripts/

**Acceptance:**

- Verify Teams browser consent, actual alert receipt and Graph subscription renewal/recovery under the selected tenant.
- Record exact subscription ownership and tenant-side cleanup separately from Azure teardown.
- Use normal browser/WAM only; retain callback/clientState secrets outside logs and public evidence.

**Validation:**

- Use the offline commands in the registered validation workflow; record the exact commands, revision and results before implementation is complete.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- nathanmcnulty/azd-entra-health-monitoring&colon;HEALTH-002
- nathanmcnulty/azd-entra-health-monitoring&colon;HEALTH-003

**Components:**

- _none_

**Sources:**

- README.md
- AGENTS.md

**Evidence:**

- _none_

**Review and authorization note:**

Review HEALTH-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## HEALTH-006: Prepare assessment of historical callback exposure

- **Kind:** discovery
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Merged PR &num;8 stops new callback disclosure/storage but leaves any existing azd values, transcripts and previously exposed callback credentials for separate assessment.

**Scope:**

- docs/operations.md
- Operator assessment and rotation packet only

**Acceptance:**

- Identify whether previous logs/environment values may retain the credential without printing or committing its value.
- Prepare exact owned workflow/target, operational impact, regeneration and verification steps before requesting separate live rotation or historical-data cleanup authorization.
- No credential rotation, environment deletion, access widening or alert delivery occurs from this local assessment task.

**Validation:**

- Read PR &num;8 and prepare a redacted local assessment packet; do not access or publish credential values.
- Review exact-target rotation/cleanup boundaries with the maintainer before any external action.

**Dependencies:**

- HEALTH-002

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/pull/8

**Evidence:**

- _none_

**Review and authorization note:**

Review HEALTH-006 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## HEALTH-005: Evaluate shared deployment and notification result contracts

- **Kind:** discovery
- **Priority:** P2
- **Status:** proposed
- **Wave:** 2
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Contract reuse can expose readiness without replacing Graph webhook or Teams connector behavior.

**Scope:**

- scripts/
- infra/
- docs/
- azd-components.lock.json

**Acceptance:**

- Separate connection readiness, subscription freshness, workflow run and recipient receipt.
- Adopt only compatible result schemas and bounded deployment-validation; preserve beta disclosure.
- Managed-connector lifecycle extraction remains a reference candidate, not an available component.

**Validation:**

- Use the offline commands in the registered validation workflow; record the exact commands, revision and results before implementation is complete.

**Dependencies:**

- _none_

**Components:**

- deployment-validation
- notification-contracts

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review HEALTH-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
