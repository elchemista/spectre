# ADR 0005: Boundary receipts, delivery modes and replay claims

Status: accepted

## Context

Reconstructing a Run does not require a log of every internal mutation. It
requires durable evidence for admitted input, nondeterministic outputs and
decisions, plus a digest linking each boundary to canonical state.

The core cannot claim the durability of a database it does not own, and a
BEAM-local worker receipt cannot survive restart because its capability
reference and Instance generation are intentionally ephemeral.

## Decision

The core defines three distinct concepts:

- `Spectre.Invocation.WorkerReceipt`: live, capability-fenced, non-portable
  worker evidence;
- `Spectre.Receipt.Envelope`: portable, deterministic boundary evidence;
- a sink-specific append acknowledgement: external and not modeled as a Run
  terminal.

Portable receipt kinds cover input admission, selection, attempt start and
terminal, supersession, missing consumer, policy/authority decisions,
Effect/Action terminal outcomes and nondeterminism samples. Existing typed
domain receipts are payloads; the envelope does not replace their validation.
There is no generic `:canonical_commit` kind in schema v1: state roots belong
to the boundary receipt that caused the commit. The name remains reserved
until a later schema defines both a real emitter and verification semantics.

The canonical state-digest operation hashes every authoritative section and a
semantic root. It excludes transition journal, applied-change cache and
`:receipt_outbox`. Delivery retries and acknowledgements therefore do not
change the state root they prove. `recorded_at` is uniformly Unix time in
milliseconds and is excluded from deterministic receipt identity; the
separate `canonical_revision` field is the logical boundary coordinate. The
full-envelope digest is a different contract: it covers every serialized
field, including `recorded_at`, and is the content address used by the payload
store. Consequently, a failure after staging but before the durable outbox
commit can leave an unreferenced object if a retry observes a new wall-clock
time. Sinks must garbage-collect those staging orphans. Once the outbox is
committed, recovery reuses its exact envelope digest and payload reference.

Before an Instance computes the payload digest, it applies the same
constitutional key denylist used by Experience evidence to typed payloads and
metadata. The traversal preserves structs, tuples and keys, replaces only
sensitive values, and records redacted paths. The privacy class still matters:
ordinary input and output remain confidential evidence and require sink-side
encryption, access control and tenancy.

Receipt policy is configured per Instance:

| Mode | Commit behavior | Failure behavior |
| --- | --- | --- |
| `:disabled` | boundary commits without an external append | no receipt claim |
| `:observational` | boundary commits, append runs asynchronously | append failure cannot block the Run |
| `:required` | payload stage, boundary+outbox commit, checkpoint barrier, idempotent append, acknowledged outbox removal | boundary progression stays fenced; admission fails only when outbox capacity is exhausted |

Required mode needs both a durable Checkpoint Store and a sink implementing
content-addressed `put_payload/2` and `get_payload/2`. The canonical outbox is
bounded and contains only id, digest and payload reference. A pending entry
keeps its boundary behind the acknowledgement barrier but does not reject a
new admission below the configured capacity. A full outbox blocks new
admission rather than dropping evidence.

Inference terminal payloads carry both cumulative usage and `usage_quality`.
Any conservative token floor that changes a provider counter is recorded as
`:estimated`, so a receipt never presents an adjusted value as token-exact.

The hot receipt path requires Invocation id, Run id/revision, Instance
generation, dispatch id and an unforgeable capability. The recovered path
requires the persisted Invocation/attempt fences and an exact envelope digest
already present in the sink/outbox. Recovery never weakens hot-path fences.

## Replay claim

The manifest claim remains:

```text
capture: nondeterministic_boundaries
state_digest_linkage: true
deterministic_replay: false
exactly_once_external_effects: false
```

`Spectre.Determinism` can capture and replay selected decision-relevant clock,
UUID and random samples and fails on type/order mismatches or unused samples.
Coverage is intentionally incremental. Full deterministic replay must not be
advertised until a verifier can replay all relevant branches against pinned
Definition/Stack identities and reproduce every post-state digest.

## Consequences

- The in-memory sink proves idempotency and envelope conformance only.
- Payload stores need retention for referenced objects and garbage collection
  for objects staged before an outbox commit that never became durable.
- An ambiguous append is reconciled with lookup; it is never assumed absent.
- Provider and sink failures are reduced to bounded classes before entering
  canonical state or telemetry.
- A Ledger implementation can consume this contract later without changing
  Spectre's runtime ownership.
