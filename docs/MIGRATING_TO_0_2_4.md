# Migrating to 0.2.4

Spectre 0.2.4 adds ownership-based event admission, current-time Definition
lifecycle authorization, and canonical checkpoint schema 3. Schema-1 and
schema-2 checkpoints remain readable and migrate in memory.

## What changes

- canonical writers add `lifecycles`, `event_admissions`, and
  `event_quarantine` and emit checkpoint/state schema 3;
- an existing schema-2 Activation becomes an active, accepting, granted,
  retained lifecycle record during decode;
- operation loops pin their owning Definition and activation/authority lineage;
- new Instance work consults the active Definition's admission axis;
- resumed Runs, policy answers, retries, commits, Effects, and operation
  dispatch consult the owning Definition's current authority;
- external events can be admitted with an exact owner and durable receipt.

## Rollout

1. Back up the canonical checkpoint namespace and verify every referenced
   Definition remains readable from the configured durable Definition Store.
2. Stop or drain old writers for an Instance key. Do not mix schema-2 and
   schema-3 writers on the same live record.
3. Deploy 0.2.4 and restore representative Instances before opening ingress.
4. Confirm checkpoint status, active lifecycle, and the owner fencing token.
5. Route external event ingestion through `Spectre.admit_event/3`; do not infer
   a Definition owner in a transport adapter.
6. Monitor `quarantined_events/2`. Resolve continuation mapping or schema
   problems outside the runtime, then submit a new event id with explicit
   evidence; never mutate a committed envelope.

Once a schema-3 checkpoint is written, a 0.2.3 binary cannot read it. Roll back
with the checkpoint backup or a tested reverse migration, after quiescing all
0.2.4 writers.

## Drain and revoke

Use drain for planned deployment: it rejects new work but lets pinned
continuations finish. Use revoke for an authority or integrity incident: it is
terminal for that Definition, advances its epoch, and blocks further dispatch.
Both transitions require lifecycle revision CAS in production control code.

Do not treat the epoch stored on a Run as an authorization grant. It is lineage
evidence only; the current lifecycle and current owner lease decide whether a
boundary may proceed.

The permanent fixture under `test/fixtures/compatibility/0.2.4` covers
checkpoint schema 3 with admitted and quarantined events plus a draining
Definition lifecycle. Older fixtures continue to prove schema-1 and schema-2
migration.
