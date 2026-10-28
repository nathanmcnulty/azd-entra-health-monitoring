# Offline M1 review boundary

This candidate tests a Health **logic fixture** contract. It does not qualify the
provider-connected Health solution. The exporter creates local JSON files; it
does not deploy or invoke them. The integration tests model lifecycle facts in
synthetic records and assert contract behavior, including negative cases. They
do not supply observed Azure deployment, payload, function or cleanup evidence.

Two profiles have different roles:

- `validation/profiles/health-logic-fixture.v1.json` pins the original workflow
  inputs, exact fixture cases, transformations and accounting assumptions.
- The vendored `Azd.LifecycleQualification/profiles/health-logic-fixture.v1.json`
  defines the separate qualification contract and case accounting policy.

The component lock pins the locally reviewed Reference revision. Consumers use
vendored files; no runtime Reference fetch is introduced. Original source bytes,
generated definitions, case configuration, qualification profile, orchestration
and component lock have distinct bindings. Hashes establish correlation with
supplied bytes, not authenticated producer provenance or permission.

`Get-LifecycleQualificationPlan.ps1` is a disabled orchestration skeleton. Its
successful exit means only that a plan was rendered. It has no execution switch
or Azure authentication path. Synthetic evaluation and its proposed projection
cannot grant execution, native qualification or publication authority.

## Compatibility and threat review

The existing deployment-validation engine, report schemas 1.0/1.1, deployment
receipt semantics and existing consumer lock entry retain their contracts.
Warnings, skipped checks and wrapper exit zero cannot fulfill the new required
lifecycle evidence. Operation receipts remain correlation records, not proof
that validation ran. No provenance-tag or #139 `desiredTags` schema is widened.

The lifecycle projection has its own type/version and a fixed field allowlist.
It is a synthetic contract proposal for review, not website implementation or
an approved public record. Existing website readers are unchanged. Website #74
policy, freshness wording, authority, approval/revocation and exact public bytes
remain separate decisions; a field named `publicationAuthorized` cannot approve
itself. Raw evidence, target identity, account/recipient data, callback URLs and
free diagnostic text are outside that projection.

Profiles are data interpreted by reviewed local code. They cannot select
executable hooks or provider commands. The fixture manifest does not authorize
its own source, accounting or execution. The offline event ledger can reject
declared events crossing a bound; it cannot prevent unobserved provider activity
or establish actual billing. Test success is not a trusted admission service.

## Required before a live M2 decision

- Independently review the exact final source and dependency stack; approve the
  selected profile, generated definitions/configuration and proposed operations.
- Reconcile existing cleanup liabilities and fresh credit, expiry, retained
  commitments, delayed charges and disjoint headroom. The unchanged monthly
  envelope is not evidence of available credit. Financial planning decisions
  remain private and require separate approval.
- Approve an exact target, region, resource/SKU scope, time/activity/cost bounds,
  ephemeral callback handling and independent cleanup operator. Verify actual
  enforcement of the inclusive outer+nested+retry trigger, action, combined
  payload and log limits. No prior run's authorization carries to this source.
- Establish durable ownership of a fresh disposable boundary before mutations.
  Prove the normal deploy/readback/function/remove path and the chosen late
  interruption/recovery path. An unknown create outcome is not deletion authority
  through a name or tag. Narrow early-provisioning recovery under #135 remains
  open before M3. Adopted/shared state is excluded; #136 becomes applicable if
  that exclusion changes.
- Preserve operation/response/process outcomes separately from complete terminal
  observations. Unknown DELETE followed by absence stays incomplete; do not
  replay it or reinterpret recovery evidence as a clean lifecycle pass.

M3 admission, persistent identities/grants/federation, privileged workflows,
OIDC, public publication, merging, website deployment and retained schedules are
outside M1. Reference #142 remains the separate option-aware cost-model stream;
#143 remains the parent staged lifecycle plan. Stop at the M1 checkpoint for
review; this document does not schedule or authorize a next run.
