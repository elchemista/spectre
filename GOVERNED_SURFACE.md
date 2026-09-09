# Governed surface: what Spectre protects

This document describes the boundary of the unreleased Spectre 0.4.0 line.

“Governed surface” means **the operations your application declares must pass
through Spectre's permission and recording checks**. For example, your Surface
might include refunds, order reads and customer-message delivery.

Spectre supplies the kernel and integration contracts. Your application names
the operations, actors, endpoints and trusted services. It must also close
alternate paths that could perform those operations without the checks.

For a first explanation, read [the architecture walkthrough](docs/architecture.md).
The [Governed Act Model](GOVERNED_ACT_MODEL.md) is the formal model.
This page is the implementation's trust and limitation reference.

## Paths and ownership

### Before execution

The fixed Ingress authenticates the interaction and records accepted observations.
The host verifies the real user/service, tenant ownership, freshness and source.

The Mind and Router prepare proposals. They do not receive execution Grants.
The host must keep unrestricted credentials and direct governed I/O out of
that deliberative code.

The kernel checks the exact Candidate against the declared class, authority,
Evidence, information-flow and resource constraints. The host must accurately
describe the consequence, including material targets, cost and recipients.

### At execution

The Act is recorded before an internal Grant is released.
Grant consumption records an Attempt before broker checkout.

The host's broker/executor must enforce the scoped capability, protect secrets
and honestly report what happened. A valid proposal is not permission to use
another route to the external service.

### After execution

Observations and Outcomes record what the available Evidence supports.
They do not rewrite the original authorization.

The host supplies authenticated receipts and reconciliation. Uncertainty is
not a reason to blindly repeat the effect.

Audit replays a canonical export instead of trusting the live projection.
The host protects storage and establishes the export's origin and completeness.

### What the library cannot isolate

The supported host facade is `Spectre`; Agent authors start with
`Spectre.Agent`. Lower-level functions also exist for adapters and orchestration.

Elixir's `@doc false` hides documentation, not access.
Code in the same BEAM can call internal APIs and inspect values.
A raw Grant still needs valid consumption on the supported execution path,
but Spectre cannot prevent host code from using its own credentials elsewhere.

One Domain has one logical ledger order. The local Registry prevents duplicate
locally supervised Domain references. Store revision checks do not replace
cross-node ownership, fencing or coordination of shared external resources.

## What is governed

A Surface declares application action classes, their power flags (Rows),
execution contracts and accepted consequence structure.

Reads, model calls, messages, payments and audio output are governed only when
declared and actually mediated. Having an adapter or log entry is not proof
that every effect path crosses the boundary.

### Governance also goes through the checks

Supported governance includes Mandate delegation/restriction/revocation,
Meter devolution, Duty disposition, Definition/Surface/HostProfile revision,
child Scope promises, declassification and erasure.

These operations need their own authority and bindings. They are not privileged
shortcuts. There is no runtime `mandate.issue` that invents another root.

### Authoring does not create permission

Agent/Skill/Stack declarations compose handlers, routes and prompts.
Extensions supply configuration and ports. They do not grant authority.

Developer-owned EEx templates are compiled at build time; user context is not
evaluated as template source. Morph prepares new Definitions, not arbitrary
hot code replacement.

Instance state and checkpoints are application state. Restoring one cannot
restore execution credentials, overwrite ledger state or renew authentication.
Storing a Definition is not activating it.

Work/Vigil openings record promises. The host supplies scheduling and triggers.
Spectre does not ship a VoIP/TTS session or transport engine.

### Input and routing stay separate from admission

Pipelines transform bounded values. A halt is a pipeline result, not a kernel
Decision. Transforming input does not upgrade its provenance: derived Evidence
keeps its sources and constraints.

Routing methods operate before the kernel. A matcher nominates supplied rules;
its score is not authority. Built-in matching does not secretly invoke remote
inference.

Callbacks remain trusted host code. Their input/output limits do not bound
all internal allocations, CPU work or I/O.

Observer phase events provide payload-free operational information.
They are not GAM Evidence or a durable audit log.

### Scopes cannot be renewed by restoring a value

A Scope opening binds its original authenticated context and Domain generation.
Resume requires a compatible context in the live generation.

After a generation change, obtain fresh authentication and a new Scope
occurrence with suitable authority. It cannot inherit permission restricted
to the old Scope merely by reusing a reference.

Acts, Meter balances and Duties survive independently of those runtime handles.

### The contract language is intentionally limited

Consequence contracts support closed maps, scalar types, lists, optional and
nullable values, constants and endpoint/disclosure/Meter bindings.

They are not an arbitrary predicate or JSON-Schema engine.
Numeric ranges and application evaluator code are not loaded from the ledger.

Represent business requirements through the supported authority/accounting
model or Conditions backed by appropriate Evidence. An unrelated `amount`
field is not automatically equal to a Meter debit.

## Authority and emergency

Genesis identifies the initial actors, Constitution and root Mandates.
The host's `Spectre.Genesis.Verifier` establishes which foundation it recognizes.

The supplied Allowlist checks configured attestation references. It is not
a digital-signature verifier or proof of a real-world identity.

### What can change?

Delegation may narrow authority, not enlarge it. Delegated Meter quantity moves
out of the parent's available balance; another Instance does not duplicate it.

Surface, HostProfile and Definition can be revised through governed actions.
The Constitution is immutable within a Domain in 0.4.
There is no `constitution.revise` Act. A change needs a new Domain and explicit
handling of the old obligations.

### Who may resolve a Duty?

The configured independent authority is checked against recorded roles and
causal conflicts. Those relationships remain relevant after revocation.

Choosing a different principal name alone is not proof of independence.

### An emergency Mandate is not a universal superuser

It is explicit, duration-limited and non-delegating. The implementation forbids:

- `mandate.delegate`;
- `mandate.restrict`;
- `surface.revise`;
- `host_profile.revise`;
- `definition.revise`.

It does not categorically forbid `mandate.revoke`, `duty.dispose`,
`data.declassify` or `data.erase`. Their normal checks still apply.

Review the exact classes and targets. In particular, emergency permission to
revoke other roots is a powerful administrative choice, not a harmless label.

## Host profiles and isolation

A HostProfile declares `:development`, `:mediated` or `:isolated`, with
attestation references and assumptions. Revisions let audit reconstruct which
profile applied to an Act.

A profile is a declaration, not a measurement. Passing its constructor does
not prove isolation.

In a shared BEAM, application code, node administrators, process inspection,
filesystem access and connected Erlang nodes are part of the trust boundary.
Seals and static Doctor checks do not make arbitrary Elixir code safe to run.

If you need isolation, implement and independently verify the credential broker,
effect gateway and deployment boundary. Do not claim it merely because the
profile is named `:isolated`.

## Storage integrity is not external authenticity

Spectre checks record encoding, digests, chain links, batch coordinates and
permitted state transitions. A successful storage callback alone is not trusted
as a valid history.

This detects malformed data, broken chains and invalid transitions.

**It does not sign ledger entries, publish witnessed heads or provide an
external append-only anchor.**

Runtime HMAC seals protect temporary values such as Grants and authenticated
contexts. They do not sign durable history for an outside verifier.

### What if the entire database is rewritten?

An actor with sufficient storage access may replace the history and recompute
a consistent chain. An auditor given only that replacement cannot establish
that it is the original, latest or complete history.

A successful audit establishes internal consistency under the supplied
foundation and trusted times. It does not establish external attribution,
absence of forks or non-repudiation.

If your threat model requires those properties, retain and authenticate
independent heads/exports through a host-owned verification protocol.

### How a recovery policy helps

`recovery_policy: {module, options}` provides two hooks:

- `check/2` may reject the verified recovered head using independently retained
  facts. It also sees a nil head before first bootstrap, allowing the host to
  reject a missing ledger for a known Domain.
- Optional `failed/2` reports startup or fatal runtime incidents. Its response
  cannot override the failure or substitute authority state.

Callbacks run in isolated processes with `recovery_timeout` (default five
seconds). Runtime notification does not keep the failing Domain's mailbox open.
Notifications are best effort, may repeat and are not a durable incident log.

The host owns quarantine/repair and restarts through verification afterward.
Repairing uncertain execution does not mean executing the effect again.

Incremental recovery trusts its verified in-memory prefix and checks the new
suffix. It does not continually reread old storage bytes. Detecting later
tampering needs fresh full verification or independent monitoring; a coherent
rewrite additionally needs an external anchor.

### Recovery-time budget

Cold startup verifies every live external payload reference before serving
commands. For 100,000 live remote objects, that can mean 100,000 verification
requests in addition to ledger recovery.

Budget for that work. There is no sampling/deferred-verification option that
declares unchecked payloads valid. A host may use a trustworthy local manifest
or cache behind its adapter, but owns its freshness and integrity.

The ledger adapters have different guarantees:

| Adapter | Host responsibility |
| --- | --- |
| ETS | Accept volatility; owner loss loses the ledger |
| Disk | Suitable filesystem durability and exclusive/disconnected-writer ownership |
| Mnesia | Durable schema, table copies, node topology and protection against table edits |
| PostgreSQL | Repo, migration, permissions, `fsync`, replication, backup and availability |
| Mock | Test-only fault injection, not durable storage |

Disk acknowledges complete frames after its durability barriers. Incomplete-tail
truncation is an explicit policy, not permission to discard corrupt history.

PostgreSQL transactions request synchronous commit. Spectre brings no Ecto or
PostgreSQL dependency; the host supplies them. Scripted Repo tests do not qualify
a real database deployment.

## Time and audit horizons

Time comes from the host, not an independent timestamp authority.

The default clock reads system milliseconds. The guard compares each reading
with the initial wall reading plus elapsed BEAM monotonic time.

With the default `clock_tolerance_ms: 60_000`:

- excessive forward/backward drift is rejected before a new commit;
- rejected readings do not move the anchor;
- legitimate idle time counts as elapsed time;
- a recovered prefix too far in the future is rejected;
- accepted time remains nondecreasing through
  `max(host_now, last_recorded_at)`.

A clock failure does not invent a Duty. Fatal handling fences the Domain and
uses the optional incident notification.

The first reading, monotonic clock and time across restarts are still host
assumptions. A bad initial clock cannot be diagnosed from that same anchor alone.
`:infinity` disables the guard and restores unbounded clamping; it is not
clock validation.

### Reading an audit at a later time

An export carries a trusted capture time. Validation checks its relationship
to the entries, not its independent authenticity.

Missing Duties or dispatch cancellations already required at capture are errors.

With a later `--at`, audit reports newly due `pending_duty_causes` and
`expired_dispatches`. It does not append or repair records.
Recorded counts, `open_duties` and Meter balances still describe the capture,
not what the live system may have done afterward.

The strict three-argument `Spectre.Audit.verify/3` uses its supplied time for
both capture and observation.

## Evidence, privacy and the external world

### Evidence is not truth by construction

The host authenticates issuers and supplies conservative provenance, freshness,
assumptions and labels.

A model assertion is not an observed fact merely because it was put in an
Evidence record. Spectre also cannot discover every hidden influence of an
opaque model or prevent a dishonest host from omitting a source.

### Presentation is not consent

Preparation, delivery and approval are separate steps. Approval belongs to
the material Candidate occurrence.

The host supplies the actual UI, approver authentication and accurate rendering
attestation. Presenting material alone does not establish consent.

### Deletion is an operation, not just a tombstone

The erasure path is:

```text
data.erase admitted → Attempt recorded → host deletes bytes
  → receipt/Outcome recorded → any verifiability Duty remains
```

`Payload.Store.verify/2` verifies presence/digest; it is not a deletion callback.
Failed or ambiguous deletion is not successful erasure and is not automatically
retried.

Restoring retired content-addressed bytes does not make them usable again.
Other consumers of a shared payload remain affected.

A ledger tombstone does not delete provider copies, replicas, backups or logs.
Do not store personal content inline in an append-only record if those bytes
must later be removed. Digests and references can themselves be sensitive.

The tests establish technical lifecycle behavior, not legal compliance.
The host must assess applicable holds, recipients, copies and retention.
For the legal text, see
[GDPR Articles 17 and 19](https://eur-lex.europa.eu/eli/reg/2016/679/oj).
Compression is neither anonymization nor deletion; no global erasure certificate
or automatic ledger rewrite is supplied.

### External systems still have their own failure modes

An Attempt does not prove an effect happened. An Outcome depends on the supplied
Evidence.

There is no cross-system exactly-once transaction, universal rollback, automatic
safe retry or guarantee of an honest provider.

## Release limits

0.3 runtime APIs and checkpoints are incompatible. There is no automatic legacy
importer. Existing unresolved effects need host-led reconciliation; copying old
data does not create retroactive authority or dispose of obligations.

Internal historical collections still grow. Paging bounds ledger input buffers,
not the accumulated projection. General durable projection checkpoints,
compaction and bounded-history guarantees are not implemented.

The host owns backend infrastructure, application retention and deployment
qualification. Those responsibilities are separate from the library's own
resource limits.

Historical benchmarks found severe history-dependent latency in older revisions.
Later indexing, delta verification and prepared-commit reuse remove several
repeated scans. Neither old results nor passing tests are current production
throughput guarantees.

See [capabilities](docs/capabilities.md) and
[storage/recovery](docs/storage-and-recovery.md) before deciding whether a
workload fits. Publication of the library is not certification of every host
adapter, retention policy or long-running deployment.
