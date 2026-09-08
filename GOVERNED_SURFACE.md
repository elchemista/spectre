# Governed surface — Spectre 0.4.0

This document defines the implementation boundary of the **unreleased 0.4.0
line**, not a certification of a particular deployment. Read it alongside the
[Governed Act Model](GOVERNED_ACT_MODEL.md). The model's four laws apply only to
consequences whose paths the host actually mediates.

The library supplies a governed-act kernel and integration contracts. It is not
a complete agent service, operating-system sandbox or source of institutional
authority. A deployment must name its own governed classes, endpoints, owners,
credentials, bypasses and external trust anchors.

## Paths and ownership

| Boundary | Library contract | Host obligation |
| --- | --- | --- |
| Input → Evidence | One configured Ingress authenticates SubmissionContext; observations retain source and context bindings | Authenticate real people/services; validate payloads, provenance, tenant ownership and freshness |
| Mind → Candidate | Deliberation returns proposals, not Grants; routing happens before Admission | Keep credentials and direct governed I/O out of deliberative code |
| Candidate → Act | Kernel checks Surface, Mandate, recognition, disclosure and Meter constraints; commit precedes Grant minting | Declare the full consequence accurately, including cost, targets and disclosure |
| Act → world | Grant consumption records Attempt before checkout; broker and executor receive bound execution context | Enforce capability scope, protect secrets, close alternate effect paths and report outcomes honestly |
| World → ledger | Observations and Outcomes are separate from authorization; ambiguity retains containment | Supply authenticated receipts and explicit reconciliation, not blind retries |
| Governance → governance | Supported administrative Candidates cross the same kernel and ledger | Establish Genesis externally and grant only the intended administrative routes |
| Ledger → audit | Canonical chain and shared pure semantics are independently replayed, without reading a live projection | Protect storage, retain exports and independently establish their origin and completeness |

The supported facade is `Spectre`; lower-level modules also expose functions for
adapters, pure evaluation and internal orchestration. Elixir `@doc false` hides
documentation, **not access**. A same-BEAM host can call internal Sequencer APIs
and obtain internal values. A raw Grant still requires validated consumption
into a durable Attempt on the supported execution path, but the library cannot
stop arbitrary host code from using its own credentials outside that path.

There is one logical ledger order per Domain. The local registry prevents two
locally supervised Domains with the same reference. Store CAS does not replace
deployment-level ownership and fencing across nodes, disconnected clusters or
multiple applications sharing the same external resources.

## What is governed

The Surface names application consequence classes, effect rows, executor
contracts and closed consequence schemas. Reads, model calls, messages, payments,
audio output or secret access are governed **only when declared and mediated**.
The presence of an adapter or a log entry does not prove complete mediation.

Built-in governance includes subtractive Mandate delegation/restriction,
revocation and Meter devolution, Duty disposition, Definition/Surface/HostProfile
revision, governed child Scope promises, declassification and erasure. These are
not privileged shortcuts: their Candidates need the appropriate authority and
bindings. There is no runtime `mandate.issue` that invents another root.

Agent/Skill/Stack declarations compose handlers, flow/route plans and prompt
templates; Extension packages contribute portable data and named ports.
Developer-owned EEx templates are compiled at build time; user context is not
evaluated as template source. Executable adapter ports remain explicit host
configuration. Morph
changesets and rollback prepare new Definitions, not hot code replacement.
Instance state and its optional CAS checkpoints are non-authoritative. Restoring
a checkpoint requires a separately authenticated Scope and cannot restore
execution capabilities or overwrite ledger state. Definition publication through
an application store is not activation. Work and Vigil express Scope promises; they do not supply
an autonomous scheduling or transport system. No VoIP/TTS pipeline is shipped.

The generic Input.Pipeline composes local, host-selected plugs over bounded
portable values. It does not run automatically in the sequencer, authenticate
input or convert a halt into a Decision. Transforming an observation does not
upgrade its provenance: interpretations remain derived Evidence with their
original parents and labels. Resource limits apply between callbacks; they are
not a memory or CPU sandbox for arbitrary application code.

The `via: [...]` routing mechanism, local regex/bag/Jaro matchers and custom
adapter registry operate before the kernel in Zone M. A matcher can nominate
only supplied rules; its score or optional derived Evidence is not authority.
No external inference is implicitly invoked by a built-in matcher. Application
adapters, stores and ports are not BEAM sandboxes: the host must mediate any
declared governed I/O. Current observability includes Scope views, ledger heads,
audit exports and optional payload-free Agent.Observer phase events. The legacy
telemetry API is not restored; host collectors and the separate Pulse migration
remain application/integration work. Operational events are not GAM Evidence.

A Scope opening freezes its original authenticated context, including the host
generation. Resume requires that same context to be authenticated by the live
Domain. A new generation or authentication needs a fresh Scope; it cannot
silently inherit a Mandate restricted to the old Scope. Durable Acts, Meter
balances and Duties survive independently of either Instance or Scope handle.

Consequence contracts support closed maps, scalar types, lists, optional and
nullable values, constants, and endpoint/disclosure/Meter bindings. They do not
support arbitrary predicates, numeric ranges or user evaluator code loaded from
the ledger. Business predicates require explicitly recognized Evidence or a
representation in the existing authority/accounting model. An unrelated amount
field is not automatically tied to a Meter debit.

## Authority and emergency

Genesis names the initial principals, Constitution and root Mandates. Its
recognition comes from outside Spectre through `Spectre.Genesis.Verifier`.
The supplied Allowlist verifier checks a configured attestation reference; it
does not verify a digital signature or establish a real-world identity.

In 0.4 the Constitution is an immutable Domain foundation, pinned by the
Genesis digest. There is no `constitution.revise` Act. Changing those rules
requires a new Domain and an explicitly governed application migration; changing
process options cannot revise the existing ledger's authority or Duty rules.
This differs from the supported in-Domain revisions of Surface, HostProfile and
Definition and is a limit of the current implementation surface.

Delegation cannot enlarge the parent's authority and moves delegated Meter
quantity out of the parent's available balance. Copies and Instances do not
create new authority. Recorded roles and causal conflicts remain relevant after
revocation. A Duty's discretionary disposition needs its configured independent
authority; configuring a different principal alone is not proof of independence.

An emergency Mandate is explicit, duration-limited and non-delegating. The
implementation forbids `mandate.delegate`, `mandate.restrict`, `surface.revise`,
`host_profile.revise` and `definition.revise` on that Mandate. It does **not**
categorically forbid `mandate.revoke`, `duty.dispose`, `data.declassify` or
`data.erase`; these still require their normal class-specific authority checks.
In particular, allowing emergency revocation against other roots is a powerful
administrative choice. The host must review classes, exact targets, independent
disposition routes and ownership conditions rather than treating “emergency” as
a harmless label or a universal superuser.

## Host profiles and isolation

`Spectre.HostProfile` records a claimed `:development`, `:mediated` or `:isolated`
profile, attestation reference and assumptions. Revisions are recorded so audit
can reconstruct the profile applicable to each Act. These are declarations,
not measurements of deployment isolation.

In a shared BEAM, loaded application modules, node administrators, process
inspection, filesystem permissions and connected Erlang nodes belong to the
trusted computing base. A malicious host can bypass this library. Neither
callback separation, sealed runtime values nor Doctor's bounded static checks
make arbitrary Elixir code safe to execute.

An isolated deployment must implement and independently verify its isolation,
credential broker and effect gateway outside that trust boundary. Do not claim
an isolated profile merely because it is accepted by a record constructor.

## Storage integrity is not external authenticity

Ledger entries and batches have canonical digests, chain links and verified
coordinates. Readers validate data instead of assuming that a successful store
callback returned a valid history. This detects malformed data, broken chains
and invalid governed transitions.

**This version does not sign entries, publish witnessed heads or provide an
external append-only anchor.** Runtime HMAC seals protect ephemeral values such
as Grants and authenticated contexts; they do not sign the durable history for
a third party. Genesis attestation references alone do not provide that property.

An actor able to replace storage can construct a different semantically valid
history and recompute its chain. An auditor given only that replacement cannot
prove it is the original, complete or latest history. A successful audit means
internal structural and semantic consistency under the supplied foundation and
trusted times, **not non-repudiation, external attribution or absence of forks**.
Deployments needing those guarantees must separately retain/authenticate trusted
heads or exports and establish an external verification protocol. No such
protocol is supplied or certified here.

`recovery_policy: {module, options}` is an optional host integration point, not
an external witness implementation. Its `check/2` runs after core recovery
checks and can reject the recovered head against independently retained facts.
It also sees a nil head before first bootstrap, so a host can reject a missing
ledger for an already known Domain. Optional `failed/2` receives startup and
fatal runtime incidents; its result never overrides the error. Each callback
runs in an isolated process bounded by `recovery_timeout` (default 5 seconds).
Notifications are best effort, not durable, and can repeat during restarts.
Runtime failure notifications run independently of the stopping Domain: a slow
host callback cannot hold its mailbox open until the notification timeout.
The host owns repair/quarantine and must restart through verification afterward.
Do not repair an ambiguous external effect by blindly executing it again.

Incremental recovery trusts its already verified in-memory prefix and checks
the newly read suffix. It does not continuously re-read old storage bytes.
Detecting subsequent changes to old rows requires a fresh full verification or
independent monitoring; detecting a coherent rewrite additionally requires an
external anchor. A checksum or an untrusted projection checkpoint is not one.

### Recovery-time budget

Cold startup verifies every live external payload reference before serving
commands. With 100,000 live objects on a remote payload store this can require
100,000 verification requests, in addition to ledger recovery. Plan recovery
time and provider quotas for that work; the incremental commit path does not
remove it. There is no sampling or deferred-verification option that declares
an unchecked payload valid. Hosts may implement a trustworthy local manifest
or cache behind their payload adapter, but own its freshness and integrity.

The adapter guarantees are different:

- ETS is volatile and loses its ledger when its owner dies. Compression is an
  optional memory/CPU tradeoff, not durability.
- Disk acknowledges complete frames after its durability barriers. Corrupt
  frames fail closed. Optional incomplete-tail truncation is an explicit
  recovery policy, not permission to discard corrupt history. Filesystem and
  disconnected-writer fencing remain deployment responsibilities.
- Mnesia requires an appropriately configured durable schema, tables and node
  topology. Its transactions do not protect against authorized table tampering.
- PostgreSQL uses the host Repo, database and migration. Write transactions
  request synchronous commit; the host must keep `fsync` enabled and configure
  permissions, replication, backup and availability. Spectre imports no Ecto or
  PostgreSQL dependency. Scripted Repo tests are not real database fault tests.
- Mock is for deterministic fault injection, not production persistence.

## Time and audit horizons

Host time is a trust assumption, not signed or independently measured time.
The default clock uses system milliseconds. `clock_tolerance_ms` defaults to
60,000: each reading is checked against the initial wall reading plus elapsed
BEAM monotonic time. Excessive forward/backward drift is rejected before it can
enter a new commit; the anchor is not moved by rejected readings. Legitimate
idle time is elapsed time, not a clock jump. A prefix more than that tolerance
ahead of current host time is also rejected rather than clamped indefinitely.
Within tolerance, ledger acquisition time remains `max(host_now, last_recorded_at)`.
Clock failures do not fabricate a normative Duty; fatal runtime handling fences
the Domain and uses the optional recovery failure notification.

The initial reading, cross-restart time and monotonic clock are still host trust
assumptions, not external attestations. A bad first reading cannot be discovered
from a local anchor alone. Hosts must monitor clock health and choose tolerance
for their deployment. Explicit `clock_tolerance_ms: :infinity` disables these
plausibility fences (useful for virtual test clocks) and restores unbounded
clamping; it must not be mistaken for clock validation.

An audit export carries a trusted capture time. Export validation checks its
shape and relation to entry times; it does not independently authenticate it.
Completeness is checked at capture: already-required missing Duties and dispatch
cancellations are errors. With a later `--at`, the auditor reports additional
`pending_duty_causes` and `expired_dispatches` without appending or repairing
anything. `open_duties`, recorded counts and Meter balances still describe the
captured ledger. A later report does not know what the live system did after
capture. The strict three-argument `Spectre.Audit.verify/3` treats its supplied
time as both capture and observation time.

## Evidence, privacy and the external world

Evidence has scope, provenance, freshness, assumptions and labels. It is neither
truth by construction nor authority. The host authenticates issuers and must
not turn model assertions into observed facts without a real observation path.

Presentation preparation, delivery and approval are distinct. Approval is tied
to the material Candidate occurrence; presenting something is not consent.
The host remains responsible for the actual UI, identity of the approver and
accuracy of the rendering attestation.

Derived data retains declared source constraints. Spectre cannot discover all
influences of an opaque model or stop a host from omitting a source. The host
must supply conservative lineage and mediate all protected disclosure paths.

Erasure records preserve causal metadata and can retain a Duty for lost
verifiability. External payload stores must actually delete the intended bytes;
backups, provider copies, logs and replicas are not erased by a ledger tombstone.
Do not put secrets or personal payloads in the append-only ledger when their
content must later be removed. Digests and references can themselves be sensitive.

The technical erasure path is `data.erase` admission, durable Attempt, host
executor deletion, receipt and Outcome, and any resulting verification Duty.
`Payload.Store.verify/2` checks presence/digest; it is not a deletion callback.
A failed or ambiguous deletion is not reported as successful erasure and is
never automatically retried. Restoring the same retired content-addressed bytes
does not make them usable again. Shared payload consumers remain affected.

The filesystem lifecycle tests exercise these mechanisms, not legal compliance
of a deployment. Identity checks, applicable exceptions/holds, recipients,
backups, logs, derived copies and sensitive metadata need application policy.
GDPR erasure and recipient obligations have qualifications; see the official
[Regulation, Articles 17 and 19](https://eur-lex.europa.eu/eli/reg/2016/679/oj).
Inline personal data already written to this append-only ledger is not removed
by deleting a different external payload. Compression is not anonymization or
deletion. No automatic ledger rewrite or global erasure certificate is provided.

An Attempt does not prove the external effect happened, and an Outcome depends
on the supplied Evidence. There is no cross-system exactly-once transaction,
automatic safe retry, universal rollback or guarantee of an honest provider.

## Release limits

0.3 checkpoints and runtime APIs are incompatible. No automatic legacy importer
is provided. Legacy evidence and unresolved effects require explicit host-led
reconciliation; copying data does not create retroactive authority or dispose
of old obligations.

The historical P1 baseline recorded severe history-dependent latency (including
roughly 1.4 complete cycles/s at 100 proponents for ETS) and was a no-go for that
revision. Incremental Duty/erasure/authority indexes, delta payload verification
and prepared-commit reuse now remove several repeated scans. Renewed performance
qualification still remains; old measurements are not current throughput claims.
Native batch paging bounds ledger input buffers, not the accumulated projection.
There is no general durable projection checkpoint/compaction or bounded-history
guarantee. See the [capability inventory](docs/capabilities.md) and
[operations guide](docs/storage-and-recovery.md).

Coverage and adversarial validation are incomplete. Neither a green static
analysis nor a count of 1,000 tests is proof of the four laws. Do not present this
checkout as a stable, performance-qualified 0.4.0 release.
