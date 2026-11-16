# Running AgentServer in production

The application owns authentication, external service credentials, database
migrations and deployment topology. Spectre owns conversation execution and GAM
checks at the declared effect boundary. Pin a reviewed compatible dependency set
and follow [Migration](MIGRATING_TO_0_4.md) when changing runtime ownership.

## Supervise resources and conversation owners

Start the named Stack runtime and application Servers under supervision as shown
in [Installation](INSTALLATION.md#otp-supervision). Give fixed Server children
distinct `id:` values. `Spectre.summon/1` supplies local per-subject ownership for
Agents with a `server:` binding.

A local registry is not a distributed placement or ownership protocol. The host
must ensure exclusive ownership of each durable namespace and provide fencing
appropriate to its database and deployment topology. Independent agents require
distinct identities, Domains and checkpoint namespaces. Share a GAM Domain only
through an intentional root/Skill relationship.

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

Database persistence does not automatically protect payload contents. Configure
`payload_store` when operation arguments, consent material, assigns or other
application content need encryption or a separate backend. The host chooses
retention and reference handling. See [Managed GAM](MANAGED_GAM.md),
[Domain storage](DOMAIN_STORAGE.md) and [Payload storage](PAYLOAD_STORAGE.md).

Restart reuses and verifies the exact authority configuration. Do not reuse an
existing namespace with changed identity or operation policy. Upgrading database
projection schemas requires an application migration; selecting Ledger does not
convert an old disk history.

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

The consumer must acknowledge actual rendering separately from the human's choice.
Bind UI controls to the exact Skill, pending record and presentation revision;
never derive authority from model-generated text. See [External approval](EXTERNAL_APPROVALS.md)
for transport-independent remote consent.

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

Use idle hibernation where it helps, and measure memory, referenced binaries,
reductions and mailboxes after warmup and cleanup. Hibernation compacts a process;
it does not implement passivation or discard history. [Profiling](OTP_PROFILE_0_4.md)
contains the reproducible probes and their limits.

## Deploy a fixed candidate

Run the supported CI matrix, real PostgreSQL tests, Stack integration and demo
checks on the same frozen revisions. Verify a clean checkout with exact dependency
pins, then rehearse backup/restore and ambiguous-effect reconciliation using the
production adapters. [Testing](TESTING.md) and [Release checks](RELEASE_0_4.md)
list the commands and handoff.

Retained Instance/Run deployments have different checkpoint, receipt, ownership
and erasure contracts. Use the [compatibility reference](COMPATIBILITY.md) for
those runbooks rather than applying them to a Server checkpoint.
