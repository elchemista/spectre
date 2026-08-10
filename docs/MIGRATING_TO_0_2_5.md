# Migrating to 0.2.5

Spectre 0.2.5 adds first-class generational Skill state and canonical
checkpoint schema 4. Checkpoint schemas 1, 2, and 3 remain readable and gain
an empty Skill-state section in memory.

## What changes

- canonical writers add `skill_states` and emit checkpoint/state schema 4;
- Activation state bindings can contain immutable Skill branch pointers;
- activation may atomically initialize, resume, fork, migrate, or abandon
  private Skill-state branches;
- a target Definition with a retained dormant branch requires an explicit
  branch choice before activation can commit;
- state writes require the exact active branch generation, revision, and
  schema Ref and are authorized against current Definition and owner fences;
- Definition retention treats non-purged Skill bindings as live references.

Arbitrary legacy values in `Activation.state_bindings` remain readable. New
typed Skill pointers are identified separately and coexist with non-Skill
bindings unless the same textual key would collide; a collision fails closed.

## Rollout

1. Back up the canonical checkpoint namespace and inventory host-side records
   that reference Definitions or private Skill state.
2. Quiesce schema-3 writers. Do not run schema-3 and schema-4 writers against
   the same live Instance key.
3. Deploy 0.2.5 and restore representative schema-1, schema-2, and schema-3
   checkpoints. Verify they report no active Skill branch unless one was
   explicitly created by a new activation.
4. Add `skill_state_transitions:` to deployment and rollback control code for
   Definitions that own private state.
5. Persist branch ids and revisions in control-plane receipts; never choose a
   branch by list order.
6. Exercise A → B → A in staging and verify A and B values remain distinct
   across checkpoint restart.

Once a schema-4 checkpoint is written, a 0.2.4 binary cannot read it. Roll back
using the backup or a separately tested reverse migration after stopping all
0.2.5 writers.

## Migration data and secrets

Core does not execute migration callbacks. Trusted host code computes the
portable state supplied to `{:migrate, ...}` and records provenance. A fork
also receives explicit state; it is not an implicit copy or merge.

State remains subject to the canonical portable-value contract. Credentials,
clients, PID, functions, and dynamic runtime resources do not belong in a
binding. Store a `secret_ref` or resolver Ref rather than secret material.

## Retention

Do not mark a branch GC-eligible until every core and host reference has been
retired. Core checks its current Activation, retained Runs, operations, and
child branches, but it cannot discover external backups or application tables.
Purge is explicit, monotonic, and leaves a tombstone for audit and stale-write
rejection.

The permanent fixture under `test/fixtures/compatibility/0.2.5` contains a
dormant A branch, a selected B child branch, and a schema-4 Activation. Older
fixtures continue to prove migrations from schemas 1 through 3.
