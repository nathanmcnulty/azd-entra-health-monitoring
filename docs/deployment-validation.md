# Deployment validation and result contracts

`scripts/Test-Deployment.ps1` is a read-only operator check. It uses the pinned
`deployment-validation@1.1.1` component and writes a schema-valid report to the
ignored `reports/deployment-validation.json` path.

```powershell
./scripts/Test-Deployment.ps1 -Plan
./scripts/Test-Deployment.ps1
```

Plan mode performs no environment read, authentication, HTTP request, Azure
request, Graph request, connector operation, workflow run, or delivery. Verify
mode uses the selected cached Azure CLI context and ARM GET requests. It never
creates or changes a subscription, connector, workflow, role assignment, or
message.

Every environment selector is validated as one bounded resource-name segment
before account or token access. The adapter builds only the exact configured
Teams connection, alert/lifecycle latest-run, and lifecycle
`Compose_expiration` endpoints, with fixed API versions and query keys. It
escapes each segment and rejects a normalized URI that differs from that exact
allowlist before acquiring a token or sending a request.

Each ARM GET has a 10-second connection timeout and 30-second operation
timeout. These deadlines cover `Invoke-RestMethod`; the preceding Azure CLI
cached-account and token subprocesses do not have an adapter-enforced deadline.

The report keeps four evidence classes independent:

| Check | Evidence | What it does not prove |
| --- | --- | --- |
| Connection readiness | Current ARM status of the existing Teams API connection | Graph subscription health, workflow execution, or Teams receipt |
| Subscription freshness | Explicit `unknown` actual state, plus the requested expiration emitted by the safe `Compose_expiration` action as qualified supporting evidence | Graph's accepted/current subscription expiration or freshness |
| Workflow run | Latest ARM run status for the alert and lifecycle workflows | Connector delivery or recipient receipt |
| Recipient receipt | External confirmation only | A ready connection or successful run never substitutes for confirmation |

Subscription freshness always remains explicitly `unknown`: the safe lifecycle
action records a requested/planned expiration, not Graph's accepted or current
subscription state. Future, near, and past requested expirations are reported
only as qualified supporting evidence. The validator does not read the
subscription-create action because its outputs can contain the signed callback
and notification secret, and it has no separately authorized Graph read path.
Failed workflows are failures; unknown freshness and unconfirmed receipt are
warnings.

Provider output is reduced to finite connection and workflow statuses. A run
identifier must be a raw scalar string before it is validated for the
expiration-action URI, and it is omitted from the report. Malformed identifiers
cannot start the downstream action read. Run timestamps accept the PowerShell
REST `DateTime` shape, `DateTimeOffset`, or a bounded ISO 8601 string with an
explicit offset, and are emitted in canonical UTC form. Unspecified `DateTime`
values and malformed, oversized, control-containing, or unexpected status,
identifier, and timestamp values become bounded `unknown` evidence and cannot
produce a passing workflow result.

## Shared contract decision

The stable deployment-validation component is compatible because it represents
read-only checks, planned checks, warnings, failures, redaction, and bounded
report output without changing the solution's runtime.

`notification-contracts@1.0.0` is not adopted by this change. Its delivery
result requires a concrete event ID, idempotency key, route, attempt, and
provider result. Connection readiness and lifecycle requested-expiration evidence are not delivery
attempts, and a Logic App or connector success is not recipient receipt.
Fabricating those required fields would weaken the evidence boundary. The
schema remains a compatible future option if the solution later produces a
safe result for each real provider attempt.

The Graph `/beta` receiver, subscription reconciliation, Teams connector
authorization, and connector lifecycle remain solution-owned. Validation adds
no permission and no runtime dependency on `azd-reference`.
