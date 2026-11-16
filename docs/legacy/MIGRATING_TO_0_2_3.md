# Migrating to 0.2.3

Spectre 0.2.3 changes durable Instance identity and writes Run and canonical
checkpoint schema 2. Read compatibility is automatic; moving a persisted
Instance from its legacy key to its stable key is intentionally adapter
controlled.

## What changes

- `AgentRef` and `Instance.Ref` keys no longer include the compiled module,
  declared Definition version, or Stack digest.
- canonical checkpoint writers add `activation` and `runs` sections and emit
  checkpoint/state schema 2;
- Run checkpoint writers emit schema 2 with Definition and closure pins;
- retained Runs are part of the canonical Instance checkpoint;
- an Instance claims an owner lease and checks its fence at authoritative
  boundaries.

State v5, Run checkpoint schema 1, and canonical checkpoint schema 1 remain
readable. A decoded legacy Run receives an explicit generation-0 legacy pin;
it is never silently rebound to the current Activation.

## Implement atomic Instance-key migration

Before deploying 0.2.3 against an existing durable Checkpoint Store, implement
the optional behaviour callback that becomes required when a legacy record is
found:

```elixir
@impl Spectre.Instance.CheckpointStore
def migrate_instance_key(legacy_ref, stable_ref, observed, migrated, opts) do
  MyBackend.transaction(fn ->
    # Lock/read the exact legacy value and reject if it differs from `observed`.
    # Reject a different value already stored under `stable_ref`.
    # Put `migrated` under `stable_ref`, then move or retain a controlled alias.
  end)

  {:ok, :moved}
end
```

Core validates the legacy checkpoint under the legacy Ref, changes its
correlation key through one canonical transition, supplies the resulting
schema-2 bytes to the adapter, and reads the stable target back byte-for-byte.
The callback may return `:ok`, `{:ok, :moved}`, or `{:ok, :aliased}`.

If both keys exist with different histories, startup returns
`{:divergent_instance_key_histories, legacy_key, stable_key}`. Spectre never
merges them. Missing migration support, ambiguous adapter outcomes, and failed
read-back also fail closed.

## Configure Definition durability

An Instance that restores an Activation or a generation-pinned Run must receive
the same trusted `:definition_store`. Durable canonical checkpoints cannot be
paired with `Spectre.Definition.Store.Memory`; use a durable adapter whose
artifacts remain resolvable after process and node restart.

Publish the Definition and bootstrap Candidate before activation. Keep every
Definition referenced by an Activation, Run, Candidate, checkpoint, or state
binding. This release performs no automatic Definition garbage collection.

## Configure ownership for the deployment topology

The default owner is safe only for a single canonical local deployment. If the
same Instance key can be active on more than one node, configure `:owner` with
a linearizable lease adapter that returns monotonically increasing
`Spectre.Instance.Owner.Lease` fencing tokens.

Lease loss blocks new admission, commits, activation, and Effect/operation
dispatch. It does not retroactively cancel an external side effect that was
already accepted by its provider, so the business boundary must still honor
the Effect idempotency key.

## Suggested rollout

1. Deploy the Checkpoint Store migration callback and durable Definition Store
   support while old workers are still quiescent.
2. Stop or drain all old owners for the affected Instance keys.
3. Back up the checkpoint namespace.
4. Deploy 0.2.3 and start each Instance through its stable AgentRef.
5. Verify the `instance_key_migration` correlation receipt and checkpoint
   status before admitting external work.
6. Publish and activate Definitions only after all referenced artifacts pass
   read-after-restart verification.

Once schema-2 checkpoints have been written, an older Spectre binary cannot
read them. Roll back using the pre-migration checkpoint backup or a separately
tested reverse migrator; do not point old and new writers at the same live
Instance record.

The permanent fixture under `test/fixtures/compatibility/0.2.3` covers a
schema-2 Activation and its Definition-pinned Run. The older 0.1.6 and 0.2.0
fixtures continue to prove boundary migration.
