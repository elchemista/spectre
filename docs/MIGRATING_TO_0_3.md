# Migrating to Spectre 0.3.0

Spectre `0.3.0` is the core cutover to the governed reflective runtime. It
promotes the single canonical Definition, Activation, runtime Skill,
data-driven Execution and governance model already hardened across the 0.2.x
development gates, then adds policy-gated Reflection, opt-in Experience and
propositional Forge.

It does not grant self-publication or self-activation. Models may criticize
and propose data; trusted host code still owns policy, oracles, persistence,
Review, Approval and the activation CAS.

## Historical 0.3.0 upgrade sequence

This sequence records the original 0.3.0 cutover. For a current installation,
use the 0.3.1 dependency and compatibility procedure in the erratum below.

1. Update the core dependency to `{:spectre, "~> 0.3.0"}`, refresh the lockfile,
   and compile with warnings as errors.
2. Run every historical compatibility fixture plus
   `test/fixtures/compatibility/0.3.0/reflective-runtime-v1.json`.
3. Run `Spectre.Foundation.Conformance.matrix/0` and the complete local
   `Spectre.Stack.Conformance` package matrix before starting Instances.
4. Keep the Definition Store durable whenever Instance checkpoints are
   durable. The reference Definition and Experience memory stores remain
   volatile test adapters.
5. Configure Experience only if recording is intentional; recording calls
   must pass `enabled?: true` and bounded evidence must expire.
6. Create a closed `Spectre.Reflection.Policy` for every actor and purpose
   allowed to inspect active behavior.
7. If Forge is enabled, register compiled critics and oracle implementations
   in host code. Never treat prose or model agreement as a gate receipt.
8. Pass `Spectre.Forge.evidence/2` unchanged to both Composer and activation;
   changed Reflection or Experience requires an explicit Forge rebase.

## Durable compatibility

### 0.3.1 erratum

The table originally published for 0.3.0 repeated the historical untagged
0.2.x Instance matrix. The released 0.3.0 code actually introduced a distinct
`"spectre/instance-checkpoint"` format-tagged writer v2 and accepts only that
v2 family. Spectre 0.3.1 preserves the released behavior and freezes a real
0.3.0 fixture instead of claiming a migration that the reader does not
implement.

An application updating from 0.3.0 should select `{:spectre, "~> 0.3.1"}`, run
its normal State and Run compatibility fixtures, and verify a representative
tagged Instance checkpoint. Adapter suites can run
`Spectre.Instance.CheckpointStore.Conformance` against a fresh isolated Ref;
the runner writes through the adapter. `mix spectre.doctor --strict` verifies
the running release and Foundation matrix without touching a store. No durable
data migration is required between the released 0.3.0 and 0.3.1 codecs.

The core keeps one runtime representation and one current writer per durable
format. Spectre 0.3.1 does not rewrite the already-current State, Run, or
canonical Instance writer schemas:

| Artifact | Current writer | Guaranteed readers |
| --- | ---: | --- |
| conversational State | 5 | 2, 3, 4, 5 |
| Run checkpoint | 2 | 1, 2 |
| format-tagged canonical Instance checkpoint | 2 | 2 |

Guaranteed State and Run legacy fixtures remain inputs to their production
decoders. Retired untagged Instance checkpoints do not. Definition, Manifest,
publication receipt, Candidate and gate artifacts must remain resolvable after
restart before a durable Activation is accepted.

## Existing module-first applications

`use Spectre.Agent`, `use Spectre.Skill`, `Spectre.ask/2,3`,
`Spectre.turn/3` and `Spectre.ensure_instance/3,4` remain the source-compatible
golden path. Compiled definitions lower through the same canonical IR used by
runtime-authored Skills. Runtime origin is provenance, never weaker
validation or extra authority.

Stack Contract V1 is accepted only as trusted adapter input. Sealed runtime
Definitions use Contract V2 authority and closure semantics; unknown
`must_understand` components fail closed.

## Add Reflection without Experience

Experience is not required. With no Experience Store, Reflection emits an
explicit `no_evidence` Observed section:

```elixir
policy =
  Spectre.Reflection.Policy.new!(
    actor_refs: ["operator:release"],
    purposes: ["inspect"]
  )

{:ok, projection} =
  Spectre.Reflection.reflect(
    definition_store,
    activation.definition_ref,
    activation,
    policy: policy,
    actor_ref: "operator:release",
    purpose: "inspect",
    as_of: System.system_time(:millisecond)
  )
```

Adding an Experience Store later changes the evidence digest and therefore
requires fresh Reflection and a new or rebased proposal.

## Govern Forge output

Forge outputs `Spectre.Forge.Proposal`, not a Candidate and not authority. The
host passes `proposal.change_set` through the existing governance chain:

```text
Reflection + redacted Experience
  -> Forge Proposal
  -> Composer
  -> composed Candidate
  -> Review + protected evaluation
  -> Approval
  -> Store re-read
  -> owner-fenced generation CAS
```

Candidate-authored cases may add obligations but cannot improve the protected
score that makes a Candidate pass. Forge cannot target the constitutional
kernel, evaluator registry, projection generator, authority envelope or
activation API.

## Intentional 0.3 boundary changes

- The package version is `0.3.0`; constraints that intentionally stop at
  `< 0.3.0` must be reviewed by their owning packages.
- The normative public API manifest now includes Experience, Reflection,
  Forge and their conformance helpers.
- Reflection is denied without a host policy, actor, purpose and explicit
  `as_of` timestamp.
- Experience recording is denied unless each call explicitly opts in.
- A governed ChangeSet bound to external Reflection evidence is stale unless
  the exact evidence is supplied again at composition and activation.
- Rebase is always a new Proposal identity; it is never an implicit mutation.

No sibling `spectre_*` package is changed by this core release. Their owners
must update version constraints and run their own real adapter matrices when
adopting `0.3.0`.

## Release checks

Before deployment, run:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix test --cover
mix credo
mix dialyzer
mix docs --warnings-as-errors
mix test test/public_api_manifest_test.exs test/hex_release_contract_test.exs
mix hex.build --unpack --output /tmp/spectre-package-check
git diff --check
```

See [Reflective Runtime](REFLECTIVE_RUNTIME.md),
[Governed Definition Changes](GOVERNANCE.md), and
[Foundation Conformance](FOUNDATION_CONFORMANCE.md) for the exact contracts.
