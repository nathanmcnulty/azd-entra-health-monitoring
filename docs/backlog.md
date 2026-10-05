# Backlog: nathanmcnulty/azd-entra-health-monitoring

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-entra-health-monitoring
- **Source revision:** `7bdae8bad4497331bf50083d8614053348a998b3`
- **Captured:** 2026-10-03
- **Items:** 6

## HEALTH-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
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

- 2026-10-03 reconciliation ran in clean owned worktree E&colon;&bsol;azd-backlog-worktrees&bsol;20261003&bsol;health-reconcile at exact origin/main revision 7bdae8bad4497331bf50083d8614053348a998b3. Origin is https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring.git; the canonical permission-metadata checkout was older and was not modified. Worktree inspection found no nested Git repository, .azure, .env, .local or node&lowbar;modules path.
- Read-only GitHub verification found issue &num;7 closed with PR &num;9 merged into current main and no open issues or pull requests. PR &num;9 checks passed for validation, dependency review and CodeQL. Existing local .azure/.env contents and credential values were not read.
- Exact-source offline validation passed&colon; all PowerShell files parsed, all JSON parsed, Pester passed 14/14, Bicep compiled, and git diff --check passed. Bicep retained the existing BCP187 warning for Microsoft.Web/connections kind at infra/main.bicep; no hook, cloud mutation or live delivery ran.
- Classification at this revision&colon; HEALTH-002 is implemented; HEALTH-003 has substantial PR &num;9 implementation but remains proposed for its broader fixture gates; HEALTH-004 still requires separately authorized live consent, renewal and delivery evidence; HEALTH-005 has no compatible component adoption yet; HEALTH-006 remains proposed pending an exact-target historical exposure assessment and separately authorized rotation/cleanup.

**Review and authorization note:**

Review HEALTH-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

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

- PR &num;8 merged as c2c63371ec182060b0e7e24f534e37e62c84d84e and is retained in current main 7bdae8bad4497331bf50083d8614053348a998b3. Callback output and unused GRAPH&lowbar;NOTIFICATION&lowbar;URL persistence paths remain removed.
- Current-main offline validation passed 14/14 tests, including the callback-output regression suite. This proves the source behavior only; no historical environment, transcript or callback credential was inspected, rotated or deleted.

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

PR &num;9 replaced deterministic clientState and hardened exact subscription ownership, but the broader malformed-notification, duplicate-delivery, removed-subscription and transient-failure fixture gates remain incomplete.

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
- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/pull/9
- https&colon;//github.com/nathanmcnulty/azd-entra-health-monitoring/commit/7bdae8bad4497331bf50083d8614053348a998b3

**Evidence:**

- Current main includes merged PR &num;9&colon; an environment-bound random 256-bit Key Vault clientState, stable ordinary redeployment, explicit migration/rotation, secure workflow parameters, complete-list ambiguity checks, exact subscription GET ownership verification and fail-closed renewal behavior. Issue &num;7 is closed.
- Current-main offline validation passed 14/14 tests across callback output, Graph clientState and lifecycle workflow suites. The implementation does not complete every original acceptance fixture&colon; malformed receiver notification shapes, removed subscriptions, duplicate delivery suppression, API transient/retry failures and renewal failure behavior still lack the requested behavioral coverage.
- No live Graph subscription, Teams receipt or runtime-history confidentiality evidence was produced during reconciliation, so the broader item remains proposed.

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

- Current main contains source and offline tests for exact subscription ownership, consent boundaries and fail-closed lifecycle behavior. Reconciliation performed no Graph role grant, subscription execution, Teams consent, alert delivery or tenant-side cleanup.
- The acceptance criteria require selected-tenant renewal/recovery and recipient-visible alert evidence, so this external-delivery item remains proposed pending separate authorization.

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
- docs/operations.md
- https&colon;//learn.microsoft.com/en-us/azure/logic-apps/set-up-security-permissions&num;regenerate-access-keys
- https&colon;//learn.microsoft.com/en-us/rest/api/logic/workflows/regenerate-access-key?view=rest-logic-2019-05-01

**Evidence:**

- Current main and docs/operations.md cover exact Graph subscription ownership plus clientState migration/rotation. They do not establish whether a selected environment still contains the legacy GRAPH&lowbar;NOTIFICATION&lowbar;URL key or whether pre-PR &num;8 terminals, transcripts, CI history, artifacts or copied output retain a callback credential.
- The operations guide now defines a value-safe, redacted assessment packet; exact workflow/trigger ownership; Primary callback access-key impact; fail-closed preparation; secure reprovisioning; and separate authorization boundaries for Graph mutation, access-key regeneration, environment/artifact cleanup and delivery.
- No target-bound environment or historical location was assessed, and no callback URL, secret value, access key, clientState or token was read. No rotation, Graph mutation, environment deletion, cleanup or delivery ran. The item therefore remains proposed with no active claim.

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

- Current main has no azd-components.lock.json and no vendored deployment-validation or notification-contracts component. Existing status and workflow behavior remain solution-owned.
- Compatibility and adoption still require a separate bounded design; reconciliation did not infer readiness or delivery from unrelated component availability.

**Review and authorization note:**

Review HEALTH-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
