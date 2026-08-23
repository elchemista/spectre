# Generational Skill State

Spectre 0.2.5 makes private Skill state a canonical, branch-aware value owned
by the Instance sequencer. It is distinct from conversational Flow state,
shared Memory, versioned artifacts, experience evidence, and external Effect
receipts. Those categories are not copied or rolled back with a Skill branch.

## State binding

`Spectre.Skill.StateBinding` records:

- a stable textual Skill id and state schema Ref;
- a monotonically increasing state generation;
- a unique branch id and optional parent branch id;
- the exact owning Definition Ref;
- state revision CAS and the latest Instance owner fencing token;
- active/dormant status and retained/gc-eligible/abandoned/purged retention;
- portable state, timestamps, provenance, and a deterministic receipt.

Schema, generation, branch lineage, and Definition owner are immutable within
a binding. Updating state increments its revision. Activation can select or
dormant a retained branch. Retention is monotonic, and purge clears state while
preserving a receipt-bearing tombstone.

## Initialize state during activation

When no dormant branch exists for a Skill and target Definition, trusted host
code may initialize one as part of the activation commit:

```elixir
{:ok, activation} =
  Spectre.activate(instance, candidate_ref,
    expected_generation: 0,
    skill_state_transitions: %{
      planner: {:init, "my_app/planner-state/1", %{"step" => "collect"}}
    }
  )
```

Activation, lifecycle changes, branch selection, and the new Activation's
state-binding pointers commit atomically. `:init` is rejected when the target
already has a retained dormant branch.

If no branch exists and no initialization is supplied, activation succeeds
without state for that Skill. A future declared initialization or migration
policy can create it; the ordinary stateless case does not require a choice.

## Rollback creates branches

Given A → B → A, activation of B makes A's selected branch dormant. A `:fork`
creates a new generation whose parent is A's current branch; it does not copy
state automatically, so trusted host code supplies the exact portable value:

```elixir
{:ok, _activation_b} =
  Spectre.activate(instance, candidate_b,
    expected_generation: 1,
    skill_state_transitions: %{
      planner: {:fork, "my_app/planner-state/1", state_for_b}
    }
  )
```

Rolling back to A now finds a dormant A branch and fails closed until the host
makes one explicit choice:

```elixir
# Resume the exact old A branch.
planner: {:resume, branch_a_id}

# Create a same-schema child from the currently selected source branch.
planner: {:fork, "my_app/planner-state/1", new_state}

# Create a new generation with trusted migrated data and possibly a new schema.
planner: {:migrate, source_branch_id, "my_app/planner-state/2", migrated_state}

# Abandon the exact old target branch and activate with no selected state.
planner: {:abandon, branch_a_id}
```

Bare `:resume` and `:abandon` are accepted only when exactly one eligible
target branch exists. Explicit ids are required for ambiguity. A fork requires
the source schema to match; use migration to change schema. Branches with the
same schema remain distinct because history, owner, generation, and parent are
part of their identity. An abandoned branch cannot be resumed or used as a
fork/migration source. There is no automatic merge.

## Read and update state

```elixir
{:ok, binding} = Spectre.skill_state(instance, :planner)
{:ok, branches} = Spectre.skill_state_branches(instance, :planner)

{:ok, updated} =
  Spectre.update_skill_state(instance, :planner, %{"step" => "execute"},
    expected_generation: binding.state_generation,
    expected_revision: binding.revision,
    state_schema_ref: binding.state_schema_ref
  )
```

`skill_state/3` accepts `branch_id:` for exact inspection.
`skill_state_branches/3` excludes purged tombstones unless
`include_purged?: true` is supplied.

An update succeeds only for the selected active branch owned by the active
Definition. The caller must present the exact generation, revision, and schema
Ref. Core then checks current Definition authority and the current Instance
owner lease, records that fence on the binding, and commits through the same
sequencer. A stale saved generation or fencing token never grants authority.

## Retention and GC

Only dormant branches can leave `:retained`:

```elixir
{:ok, eligible} =
  Spectre.transition_skill_state_retention(
    instance,
    :planner,
    dormant_branch_id,
    :gc_eligible,
    expected_revision: dormant_revision
  )

{:ok, tombstone} =
  Spectre.transition_skill_state_retention(
    instance,
    :planner,
    dormant_branch_id,
    :purged,
    expected_revision: eligible.revision
  )
```

GC is conservative. Active or Activation-referenced branches are blocked.
Any retained Run or operation owned by the branch's Definition blocks
collection, as does a non-purged child branch. Definition lifecycle purge also
fails while any non-purged Skill binding references that Definition.

The runtime never purges automatically and cannot inspect host records outside
its canonical checkpoint. Hosts with Candidate, lineage, backup, or external
checkpoint references must keep the branch retained until those references are
retired too.

## Checkpoint compatibility

Current canonical checkpoint writers emit format-tagged schema 3 with a
`skill_states` section. The 0.3.3 reader accepts tagged versions 2 and 3;
untagged 0.2.x schemas are retired. Their historical migration sequence remains
documented in [Migrating to 0.2.5](MIGRATING_TO_0_2_5.md).
