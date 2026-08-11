# Reflective Runtime

Spectre `0.3.0-rs` completes the core reflective-runtime path without giving
models control over code, authority, evaluation policy, publication, approval,
or activation. Reflection is mechanical inspection; Forge emits an inert,
governed proposal.

## Three separate planes

| Plane | Reads | Produces | Cannot do |
| --- | --- | --- | --- |
| Execution | sealed Definition, Manifest, Work and current authority | lifecycle transitions and receipts | invent code or widen authority |
| Reflection | canonical Definition, effective Activation and redacted Experience | versioned `Spectre.Projection.Reflection` | execute inspected instructions or call a model |
| Forge | verified Reflection plus the same redacted Experience snapshot | content-addressed `Spectre.Forge.Proposal` | publish, approve, activate, register code, or change the kernel |

The planes share content identities, not hidden mutable state. Declared,
Effective and Observed facts remain separate throughout the projection.

## Record Experience explicitly

Experience is optional observational evidence. Recording is disabled unless a
trusted host opts in for each call:

```elixir
{:ok, evidence_ref} =
  Spectre.Experience.record(
    experience_store,
    %{
      definition_ref: activation.definition_ref,
      activation_generation: activation.generation,
      kind: "routing.observation",
      source_ref: "journal:redacted:42",
      observed_at: now,
      expires_at: now + :timer.hours(24),
      retention: :bounded,
      facts: %{"route" => "support", "token" => raw_token},
      provenance: %{"collector" => "host:v1"}
    },
    enabled?: true
  )
```

Built-in sensitive keys are always redacted. A host may add keys with
`:redact_keys`, but cannot remove the constitutional denylist. Evidence is
portable, content-addressed and tied to one Definition Ref and activation
generation. `:ephemeral` and `:bounded` evidence require an expiry;
`:retained` evidence is never purged by the expiry operation.

The reference in-memory adapter is deliberately volatile:

```elixir
{:ok, pid} = Spectre.Experience.Store.Memory.start_link(id: :local_experience)
experience_store = {Spectre.Experience.Store.Memory, server: pid}
```

Production hosts may implement `Spectre.Experience.Store`. Experience is not
canonical Instance state and is never consulted for authorization,
continuation ownership, or Effect dispatch.

## Reflect the active Definition

Reflection requires a host-owned policy, exact actor, purpose and snapshot
time:

```elixir
policy =
  Spectre.Reflection.Policy.new!(
    actor_refs: ["operator:release"],
    purposes: ["inspect"],
    max_evidence: 100
  )

{:ok, projection} =
  Spectre.Reflection.reflect(
    definition_store,
    activation.definition_ref,
    activation,
    policy: policy,
    actor_ref: "operator:release",
    purpose: "inspect",
    as_of: now,
    experience_store: experience_store
  )
```

The projection contains three independent sections:

- `declared`: canonical declarations quoted as data;
- `effective`: verified Manifest authority, execution closure and Activation;
- `observed`: the exact redacted Experience snapshot, or an explicit
  `no_evidence` limitation.

The generator ID and version participate in the projection digest. Loading a
transported projection regenerates it from its Definition, Manifest,
Activation and Experience snapshot; digest-only verification is insufficient.
No prompt is assembled and no inspected instruction is active in this plane.

Hosts that want Reflection in an operation registry can register the compiled
`Spectre.Reflection.Operation.spec/0`. Runtime input may carry only the
Definition Ref, actor, purpose and time. Stores, Activation and policy come
from trusted operation configuration.

## Run compiled critics, including Prism adapters

`Spectre.Forge.Critic` is the narrow adapter contract for Prism or another
compiled model client:

```elixir
defmodule MyApp.PrismCritic do
  @behaviour Spectre.Forge.Critic

  def id, do: "my_app.prism.routing"
  def version, do: 1
  def profile_ref, do: "prism:routing-review-v1"

  def critique(reflection_data, snapshot_data, opts) do
    MyApp.Prism.review(reflection_data, snapshot_data, opts)
  end
end
```

Core supplies only portable Reflection data and the redacted snapshot. A
critic response may contain prose and one falsifiable `Spectre.Eval.Case`.
Prose remains opinion. A proposed case becomes a ChangeSet obligation only
when its exact content digest and `oracle_ref` are independently approved by
`Spectre.Forge.OracleApproval`, or when trusted host configuration names that
oracle. Agreement among critics is not oracle approval.

## Propose, compose and activate

Forge can emit only the fixed safe subset of governance operations. It cannot
select callbacks, evaluator modules, authority grants, projection generators,
or kernel policy:

```elixir
{:ok, proposal} =
  Spectre.Forge.propose(
    activation,
    projection,
    experience_snapshot,
    [%{type: "disable_skill", payload: %{"mount_id" => "legacy_lookup"}}],
    critics: [MyApp.PrismCritic],
    oracle_approvals: approvals,
    author_ref: "forge:release-review",
    reason: "Remove the superseded route",
    created_at: now
  )

evidence = Spectre.Forge.evidence(projection, experience_snapshot)

{:ok, composed_ref} =
  Spectre.Governance.Composer.compose(
    definition_store,
    proposal.change_set,
    activation: activation,
    evidence: evidence,
    created_at: now
  )
```

The ordinary Review and Approval gates still follow. Immediately before the
generation CAS, activation must receive the same current external evidence:

```elixir
{:ok, next_activation} =
  Spectre.activate(instance, approved_candidate_ref,
    expected_generation: activation.generation,
    evidence: evidence
  )
```

The Candidate commits the ChangeSet digest, and the Proposal commits the exact
Reflection, Experience, critic, oracle and parent-proposal lineage. Hosts must
retain Proposal artifacts in their audit store when that lineage must remain
independently inspectable.

## Staleness and explicit rebase

Any change to Activation receipt, Candidate Ref, Definition Ref, authority
epoch, Reflection digest or Experience snapshot makes the old ChangeSet stale.
There is no implicit rebase:

```elixir
{:ok, rebased} =
  Spectre.Forge.rebase(
    old_proposal,
    current_activation,
    current_projection,
    current_snapshot,
    critics: [MyApp.PrismCritic],
    oracle_approvals: current_approvals,
    created_at: now
  )
```

Rebase creates a new content identity and points at the previous Proposal. It
reruns critics and never copies Candidate-authored evaluation cases forward as
trusted evidence.

## Conformance boundary

`Spectre.Foundation.Conformance.verify_reflection/5` verifies transported
Reflection against all exact inputs.
`Spectre.Foundation.Conformance.verify_forge_proposal/1` verifies complete
Proposal lineage. The permanent
`test/fixtures/compatibility/0.3.0-rs/reflective-runtime-v1.json` fixture pins
the schema, Definition, Activation, Experience, Reflection, critic, oracle,
ChangeSet and Proposal identities for this release.

Reflection and Forge never provide an activation API. Publication, Review,
Approval, activation, rollback and storage policy remain explicit host
responsibilities.
