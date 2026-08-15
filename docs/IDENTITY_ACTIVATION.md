# Stable Identity, Activation, and Definition-Pinned Runs

Spectre 0.2.3 separates three values that previously moved together:

- `Spectre.AgentRef` identifies one logical Agent independently of its compiled
  module, Definition version, and Stack digest;
- `Spectre.Instance.Activation` records which immutable Definition is current
  for an Instance;
- every `Spectre.Run` records the exact Definition Ref, activation generation,
  authority epoch, and execution-closure digest it started with.

Changing behavior therefore no longer creates a different Instance, and
activating new behavior never rewrites an open continuation.

## Publish a bootstrap Candidate

An activation accepts only a `Spectre.Definition.Candidate.Ref`. The Candidate
is a small immutable binding to an already-published Definition, Manifest, and
publication receipt. From 0.2.9, trusted hosts may alternatively derive a
governed Candidate through the ChangeSet workflow; legacy bootstrap Candidates
remain unchanged.

```elixir
canonical = Spectre.Definition.canonical!(MyApp.SupportAgent)

manifest =
  Spectre.Definition.manifest!(MyApp.SupportAgent,
    authority_ceiling: %{actions: [:send_reply]},
    publisher_ref: "publisher:my-app",
    provenance_refs: ["git:0123456789abcdef"]
  )

{:ok, receipt} =
  Spectre.Definition.Store.publish(definition_store, canonical, manifest,
    checkpoint_store: checkpoint_store
  )

{:ok, candidate_ref} =
  Spectre.Definition.Resolver.bootstrap_candidate(
    definition_store,
    receipt.definition_ref,
    source: :compiled,
    checkpoint_store: checkpoint_store
  )
```

Only trusted host code or compiled Definition lowering should create this
bootstrap Candidate. Publishing it verifies its Definition binding and reads
the stored bytes back before returning its content-addressed Ref.

## Activate through the Instance sequencer

Configure the same Definition Store on the Instance. A durable checkpoint
requires a Definition Store whose adapter reports `:durable`.

```elixir
{:ok, instance} =
  Spectre.instance(supervisor, MyApp.SupportAgent, subject,
    definition_store: definition_store,
    checkpoint_store: checkpoint_store,
    owner: MyApp.InstanceLease
  )

{:ok, activation} =
  Spectre.activate(instance, candidate_ref,
    expected_generation: 0,
    authority_epoch: 12,
    skill_state_transitions: %{
      planner: {:init, "my_app/planner-state/1", %{"step" => "collect"}}
    },
    provenance: %{approved_by: "deployment:2026-08-10"}
  )
```

`expected_generation` is mandatory and is `0` before the first activation.
The Instance re-reads Candidate, Definition, Manifest, and publication receipt
from the configured Store. For a governed Candidate it also re-reads and binds
every required gate and approval receipt. It then verifies its current owner fence, constructs the
Activation receipt, and commits the canonical activation section with CAS.
A stale generation or authority/fencing rollback is rejected.

When durable checkpointing is enabled, activation waits for a current
checkpoint revision and writes the activation synchronously. An ambiguous
write stops the Instance instead of guessing whether the new Definition is
active. `Spectre.activation/1` returns the committed snapshot.

## Run pinning across an activation

New Runs copy the current Activation pin at admission. Existing Runs retain
their original pin through every boundary and checkpoint:

```text
Run A starts under Definition A
        │
        ├── activation CAS selects Definition B
        │
        ├── new Run B uses Definition B
        │
        └── resumed Run A still uses Definition A
```

The current format-tagged canonical checkpoint schema 3 stores the Activation
and all retained Run checkpoints. On restart, Spectre re-resolves every non-legacy
pinned Definition and verifies its closure digest before accepting work. A
missing or changed artifact fails closed.

Run checkpoint schemas 1, 2 and 3 remain readable. The 0.3.2 Instance reader
accepts format-tagged schemas 2 and 3; retired untagged Instance schemas are
rejected rather than interpreted as the new format. Historical 0.2.5 schema-4
deployment guidance remains in [Migrating to 0.2.5](MIGRATING_TO_0_2_5.md).

## Canonical owner and fencing

`Spectre.Instance.Owner` is the host contract for one canonical owner and a
monotonic fencing token. Spectre validates the lease before admission,
activation commit, canonical commits, and Effect or operation dispatch.

The default `Spectre.Instance.Owner.Local` adapter is explicitly single-owner
and VM-local. `Spectre.Instance.Registry` routes to a local PID; it is not a
distributed lease. Multi-node deployments must route all work to one owner or
provide an adapter backed by a linearizable lease/fencing authority.

## Governed activation and rollback

The 0.2.9 governed flow is documented in
[Governed Definition Changes](GOVERNANCE.md). Approval and activation are
separate host commits. `Spectre.rollback/3` accepts only an ancestor Candidate,
uses the same owner fence and generation CAS, and records that external Effects
were not reversed. Neither a model nor a ChangeSet can activate itself.

Distributed consensus remains outside core. A bootstrap Candidate is trusted
host input, while a governed Candidate is evidence of completed checks; neither
one grants authority beyond its sealed Manifest.
