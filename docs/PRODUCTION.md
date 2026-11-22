# Running AgentServer in production

The application owns authentication, external service credentials, database
migrations and deployment topology. Spectre owns conversation execution and GAM
checks at the declared effect boundary. Pin a reviewed compatible dependency set
and follow [Migration](MIGRATING_TO_0_4.md) when changing runtime ownership.

## Supervise resources and conversation owners

Supervise each Root Server. When a package declares `child_specs/2`, start the
named Stack runtime that owns those resources and pass it in `stack_runtime:`.
Give fixed Server children distinct `id:` values. `Spectre.summon/1` supplies
local per-subject ownership for Agents with a `server:` binding.
[Supervisor setup](INSTALLATION.md#otp-supervision).

A local registry is not a distributed placement or ownership protocol. The host
must ensure exclusive ownership of each durable namespace and provide fencing
appropriate to its database and deployment topology. Independent agents require
distinct identities, Domains and checkpoint namespaces. A Root shares its
GAM Domain with its mounted Skills and started Activities.

A supervised replacement Root can reattach to the live Managed GAM owner on the
same node. `gam: [shutdown_timeout: milliseconds]` bounds that owner's wait
after losing the Root. Durable cold recovery uses checkpoint and GAM
reconciliation, including a fresh presentation for recovered consent. Use
`Spectre.Server.activities(root)` from the authorized consumer to see the
execution references and revisions of current work.
[Activity lifecycle](AGENT_SERVER.md#run-a-background-activity).

Keep portable state in assigns and process handles in private state. Shared model,
browser, Repo and other clients belong to supervised Stack resources. Provider
calls and tools run in workers; application OTP callbacks should return promptly.

## Persist coherent state

Choose one coherent setup for canonical GAM history, coordination records and
Server checkpoints:

- `:ephemeral` for RAM-only operation.
- `{:disk, path}` for durable local history.
- `:ledger` for a configured Ledger resource, with application-owned Repo and
  migrations installed before startup.
- `{MyApp.Storage, reference}` for your own unified Store provider.

Database persistence does not automatically protect payload contents. Configure
`payload_store` when operation arguments, consent material, assigns or other
application content need encryption or a separate backend. The host chooses
retention and reference handling. See [Managed GAM](MANAGED_GAM.md),
[Domain storage](DOMAIN_STORAGE.md) and [Payload storage](PAYLOAD_STORAGE.md).

Restart reuses and verifies the exact authority configuration. Do not reuse an
existing namespace with changed identity or operation policy. Upgrading database
projection schemas requires an application migration; selecting Ledger does not
convert an old disk history.

When upgrading a compiled 0.4.0 Server, rehearse the checkpoint migrator
against a backup. Drain running effects and verify the expected old and new
definition fingerprints. [Upgrade a durable AgentServer](INSTALLATION.md#upgrading-a-durable-agentserver).

## Handle database loss explicitly

The default policy waits rather than allowing unverified work. A failed Domain
leaves the Managed owner available to report failure and accept recovery policy.
The host can repair and retry verified recovery or explicitly start a fresh RAM
Domain through the configured policy or `Spectre.Server.recover_storage/2`.

A fresh Domain invalidates previous grants, consent and governed outbox work.
Its history is not merged back into the old database. Lost canonical batches
cannot be reconstructed from a surviving derived projection. Back up canonical
history, authority configuration and application payload objects coherently.
Exercise outage, partial deletion and restore against your actual adapters.

## Preserve external effect semantics

Register every effect with accurate idempotent, reconcilable or non-idempotent
semantics. Keep a real business idempotency record when the provider supports it.
A command ID, admitted Act or technical transport receipt alone does not prove
that an external action completed.

After an ambiguous result, reconcile provider truth before retrying. A conversation
close, approval expiry or authority revocation cannot erase an already committed
Act or unresolved Duty. Configure independent review only when your application
has an authenticated reviewer role and real supporting evidence.

The consumer acknowledges rendering separately from the human's choice.
Bind consent controls to the exact Presentation and its owner. For a normal
question in an Activity, bind the reply to its execution reference and
pending ID/revision. For a governed command in that Activity, send the
decision through the Root using the Presentation reference. [Activity consent](MANAGED_GAM.md#consent-from-an-activity),
[transport-independent external approval](EXTERNAL_APPROVALS.md).

Test an Activity revision before admission and after admission. A revision
invalidates an earlier pending consent. Effects already admitted retain their
original identity and may report outcomes after the Activity ends. Reconcile
those outcomes independently of whether the UI still shows a running Activity.

## Bound provider waits and cancellation

Configure finite adapter deadlines and stream limits for your deployment.
Termination of a local worker does not guarantee cancellation of a request already
accepted remotely. The final consolidated response is distinct from provisional
stream deltas; only finalized validated proposals may enter governed execution.

[Providers](PROVIDERS.md) defines timeout/failure contracts and
[Streaming](STREAMING_INFERENCE.md) describes liveness, limits and recovery.
[Pending lifecycle](PENDING_LIFECYCLE.md) covers application timers, suspension
and expiry while other conversation work continues.

## Observe without retaining content

Use the authorized [diagnostic API](DIAGNOSTICS.md) for current status, paginated
GAM views and commit notifications. Avoid repeated full-ledger polling. The host
must keep log and metric labels bounded and redact application data; IDs and
digests may still be linkable.

`mix spectre.doctor --agent MyApp.Agent --strict` checks compiled contracts.
It does not prove live provider or database health. Test connectivity, installed
migrations, credentials and actual recovery at the owning adapter boundary.
[Server contracts](SERVER_CONTRACTS.md) adds permission and state-schema diagnostics.

## Measure memory for your workload

Projection-backed Domains release historical records after commands. Active
Duties, proof groups and full-history reads can still grow. RAM-only operation
retains the complete projection. Application assigns and configured Server caches
have their own lifetimes; database persistence does not automatically evict them.

Use idle hibernation where it helps compact process memory. Measure memory,
referenced binaries, reductions, mailboxes and database writes after warmup
and cleanup. Include parallel missions and repeated cancellation. Track
latency for unrelated chat turns as Activities run. [Profiling](OTP_PROFILE_0_4.md)
contains reproducible probes and their limits.

## Deploy a fixed candidate

Run the supported CI matrix, real PostgreSQL tests, Stack integration and demo
checks on the same frozen revisions. Verify a clean checkout with exact dependency
pins, then rehearse backup/restore and ambiguous-effect reconciliation using the
production adapters. [Testing](TESTING.md) and [Release checks](RELEASE_0_4.md)
list the commands and handoff.

Retained Instance/Run deployments have different checkpoint, receipt, ownership
and erasure contracts. Use the [compatibility reference](COMPATIBILITY.md) for
those runbooks rather than applying them to a Server checkpoint.
