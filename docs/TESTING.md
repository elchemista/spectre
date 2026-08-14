# Testing

Spectre's tests are designed around boundaries and invariants, not only
successful conversations.

## Local commands

```bash
mix test
mix test --cover
mix format --check-formatted
mix compile --warnings-as-errors
mix credo
mix dialyzer
mix docs --warnings-as-errors
mix test test/public_api_manifest_test.exs test/hex_release_contract_test.exs
mix hex.build --unpack --output /tmp/spectre-package-check
```

CI uses the default Credo priority threshold. `mix credo --strict` is useful
as an advisory cleanup pass, but lower-priority refactoring suggestions do not
form the release gate.

The repository coverage threshold is 93%. Do not lower or exclude modules to
make a change pass; add a meaningful test or explain why a private branch is
unreachable and simplify the implementation.

## Public conformance foundation

Core conformance runners return data and do not depend on ExUnit. Applications
and adapters can call them from any test framework. For example, an Instance
Checkpoint Store suite can exercise the same canonical codec, semantic
readback, exact-retry verification, stale-write rejection, and concurrent CAS
race used by Spectre:

```elixir
defmodule MyApp.CheckpointStoreTest do
  use ExUnit.Case, async: true

  test "implements the checkpoint contract" do
    server = start_supervised!({Agent, fn -> %{} end})
    ref = my_fresh_instance_ref()

    assert {:ok, report} =
             Spectre.Instance.CheckpointStore.Conformance.run(
               {MyApp.CheckpointStore, server: server},
               ref
             )

    assert report.concurrent_cas == :single_winner
  end
end
```

The runner writes through the adapter and leaves revision three under the
supplied Ref, so every run needs an isolated identity. The separate
`read_after_restart/3` helper compares the same checkpoint semantically through
two adapter configurations. Foundation, Definition Store, Stack, and
Checkpoint Store conformance live in core; replay fixtures, live-I/O fuses,
virtual sources, and a future `Spectre.Lab.TestCase` belong to `spectre_lab`
rather than the Spectre 0.3.1 core.

## Safe generators

Spectre includes small generators for the public integration boundaries:

```bash
mix spectre.gen.agent MyApp.SupportAgent
mix spectre.gen.installable MyApp.SupportPackage
mix spectre.gen.checkpoint_store MyApp.SpectreCheckpointStore
```

Each command creates a module and a focused contract test. Existing files are
rejected before any output is written. Use `--dry-run` to validate and inspect
the complete plan, or `--force` to replace existing regular files explicitly.
Generation refuses invalid aliases, path escapes, symlinked parent directories,
and non-regular overwrite targets.

The Agent keeps the DSL's module-based default identity. The Installable uses
the public Stack contract, and the generated Checkpoint Store is explicitly
process-local for tests and development. Every template includes an executable
contract test; the generator suite compiles and runs the generated files in a
separate test process. Evidence/replay generators are reserved for
`spectre_lab`, and database migration generators stay in the package that owns
the adapter.

## Foundation release gate

`test/foundation_conformance_test.exs` verifies the permanent 0.2.6 digest
manifest, migrates every guaranteed core fixture, exercises both fixture and
compiled Agent+Skill Definition paths, compiles a cross-package Stack matrix,
and rejects corrupt formats, incompatible versions, and ambiguous capability
ownership. Applications should use the same public conformance modules for
their private checkpoints and complete dependency set.

This integrated gate does not replace the deeper restart, crash, race, owner
fence, and ambiguous-commit suites below. A foundation release requires both.

`test/runtime_skill_definition_test.exs` and
`test/runtime_skill_lifecycle_test.exs` add the 0.2.7 gate. They prove
compiled/runtime semantic equivalence, JSON-shaped data lowering, code-ref and
prompt rejection, anti-hijack evaluation, versioned Routing projection
identity, authority and revision fences, kernel prompt reservation,
equal-specificity ambiguity, and Definition-pinned replace/disable drains. The
permanent 0.2.7 fixture pins Definition, semantic, projection, and cache
digests.

`test/data_driven_execution_test.exs`,
`test/execution_expression_test.exs`, and
`test/execution_handoff_test.exs` add the 0.2.8 gate. They prove
compiled/runtime Program identity, canonical reload, finite graph and budget
validation, registered binding/purity, exact materialization and prompt
receipts, shared lifecycle and recovery, governed amendments, typed handoffs,
registered migration receipts, real retry transitions, and rehearsal with
zero Effect dispatches. The permanent 0.2.8 fixture pins Program, input,
final-state, and rehearsal digests.

`test/governance_gate_test.exs` adds the 0.2.9 gate. It proves stale-base
rejection, closed handler registration, authority and applicability ceilings,
Candidate-case anti-Goodhart weighting, checker-version and receipt binding,
separate human approval and activation, Store re-reads, owner/generation CAS,
ancestor-only rollback, JSON-stable reports and plans, and conservative GC
inventory closure. Regression cases also prove full-content protected-corpus
binding, retain-only partial GC, monotonic anti-hijack examples, inline mount
verification, and separate host-only semantic recovery/rollback escapes. The
permanent 0.2.9 fixture pins portable ChangeSet, Candidate-state, receipt,
evaluation, report, and GC schema identities.

`test/reflective_runtime_test.exs` adds the `0.3.0` gate. It proves explicit
Experience opt-in, constitutional redaction, retention and purge confirmation,
snapshot and JSON transport integrity, deterministic Reflection with honest
no-evidence output, policy-gated operation configuration, fixed Forge
vocabulary, independent oracle binding, model-agreement non-authority, stale
evidence rejection, explicit rebase, load-boundary hardening, collection caps,
and the absence of any Forge activation API. The permanent reflective fixture
pins Definition, Activation, Experience, Reflection, critic, oracle, ChangeSet
and Proposal identities.

## What a contract test must prove

A passing output assertion is not enough for code that crosses process,
persistence, provider, or side-effect boundaries. A regression test should
observe every relevant part of the invariant:

1. the returned value or process outcome;
2. the exact order and cardinality of callbacks that must run;
3. callbacks that must **not** run;
4. in-memory and durable state on both sides of the commit boundary; and
5. restart, retry, or replay behavior after the injected failure.

Coverage reports and large case matrices are useful diagnostics, but they are
supplementary. They do not prove that a provider was called once, that an
effect was not duplicated, or that a committed state survived a worker crash.

## Executable lifecycle contracts

`test/system_lifecycle_contract_test.exs` starts real supervised Spectre
processes and exercises their lifecycle instead of only inspecting child
specifications. It verifies:

- required application children are alive and restart after abnormal exits;
- semantic-cache collections die with their owner and ETS state is recreated
  without orphaned collection processes;
- sessions restore pending and terminal durable state after a crash;
- normal dismiss and idle shutdown do not restart transient sessions;
- every state-load failure shape leaves no registered zombie and a later start
  can recover;
- state writes that error before commit remain definite, while a callback that
  commits and then raises, exits, throws, is killed, times out, or returns a
  malformed result is treated as ambiguous;
- a strict persistence-journal failure after compare-and-set retains the
  already committed result; and
- an action crash after the business commit retries the same idempotency key,
  producing multiple attempts but one business effect.

`test/turn_mechanics_contract_test.exs` drives the public `Spectre.turn/3`,
policy continuation, and action continuation APIs through instrumented real
adapters. It asserts the complete boundary order:

```text
input -> state load -> memory recall -> turn handler -> arbitration journal
      -> render -> state compare-and-set -> persistence journal
      -> memory persist
```

The suite kills the turn at every boundary and proves that no later callback
runs, that durable revision changes only after the commit boundary, and that
the next full turn recovers. It also proves handler-owned turns, trusted policy
continuations, and idempotent terminal action replay.

## Flow, Work, and Vigil system example

`test/flow_work_vigil_system_test.exs` defines one complete executable Agent,
not a collection of disconnected mocks. Its closed operation catalog is used
by a paginated Work, a persistent weather Vigil, and a deliberately failing
Work. Ordinary Flow routes then exercise the public runtime end to end:

- `work/2` starts the paginated Work and returns a visible acknowledgement;
- the Flow remains responsive, inspects progress, and submits a durable update
  while an operation Runner is blocked;
- every page receives a distinct attempt, snapshot, Runner, and fencing token;
- another Flow route registers the Vigil, then pause, resume, and trigger drive
  silent and significant observations;
- completed, failed, and significant events re-enter the ordinary Flow router
  and are committed in conversational state;
- Work failure does not prevent later turns; and
- one checkpoint restores Flow state, an active Work, and a waiting Vigil
  together, with a fresh epoch and fencing for the recovered Runner.

This is the preferred regression location for behavior that crosses all three
loops. Lower-level runtime tests should still be used for exhaustive malformed
envelopes and individual transition matrices.

## Autonomous Work and internal Flow example

`test/autonomous_work_flow_example_test.exs` is the executable companion to the
autonomous recipe in Getting Started. It starts a Work directly from the host,
without `Spectre.turn/3`, a human Source, or Beam, and verifies this sequence:

1. the Work collects initial evidence in one temporary Runner;
2. the Work commits an `:external` wait and the Runner is gone;
3. the committed `:waiting` event creates an ordinary internal Flow Run;
4. the Flow reads the committed Work view and chooses a schema-valid query;
5. the Flow delivers a correlated trigger whose causation is the waiting event;
6. the Work reducer stores that response and a new Runner executes the query;
7. the terminal outcome, Flow decision, events, provenance, and empty Runner
   set are all asserted from committed state.

The example deliberately uses public `0.2.0` APIs rather than introducing a
pseudo Work-to-Flow DSL. It proves the current application-level event/trigger
bridge; lower-level contracts remain responsible for malformed triggers,
duplicates, stale generations, and restart matrices.

## Strategy matrix

`test/strategy_matrix_test.exs` defines ten agents with different prevailing
strategies:

1. deterministic regex;
2. local classifier over weak regex evidence;
3. exact semantic-cache adapter;
4. semantic-cache adapter search after an exact miss;
5. bag distance;
6. Jaro distance;
7. local FastEmbed-compatible embeddings;
8. LLM fallback;
9. mounted Skill routing;
10. structured prompt injection.

Each agent executes 80 cases. Twenty are accepted routing scenarios and sixty
exercise unmatched input, invalid state, unknown flow, invalid pipeline, empty
input, serialized state, or malformed flow data. The resulting 800 cases keep
the same route vocabulary while varying which strategy is allowed to prevail.
The semantic-cache matrix agents are adapter doubles: they test precedence and
visibility, not the built-in cache's persistence or provider-call behavior.

## Built-in semantic-cache contract

`test/semantic_cache_contract_test.exs` is the deterministic behavioral suite
for the built-in cache. It asserts exact provider-call cardinality and the
actual persisted vectors across exact hits, semantic hits, LLM-learned misses,
legacy vectorless snapshots, clear, snapshot, and restore. These assertions are
required even when a route's final label would have been correct.

The scale tripwire loads 1,000 stored vectors whose text raises if it is ever
sent to the embedding adapter. Loading and exact lookup make zero calls;
semantic lookup makes exactly one call for the new query. A dimension mismatch
must fail before even that query call.

## FastEmbed fixture

The committed ETF fixture was generated from local ExFastembed vectors and is
read through a deterministic fake backend. The embedding strategy still calls
the production `Spectre.Classifier.Embeddings.ExFastembed` adapter, so adapter
normalization is covered, but this fixture does **not** prove native model
loading or inference.

To regenerate it from a local ExFastembed checkout:

```bash
mix run scripts/generate_strategy_embeddings.exs -- \
  --ex-fastembed-path ../ex_fastembed \
  --model BAAI/bge-small-en-v1.5
```

Review the resulting binary change and run the entire strategy matrix. Do not
regenerate fixtures opportunistically in CI.

## Real ExFastembed system test

`test/real_ex_fastembed_semantic_cache_test.exs` runs separately from the
offline suite. It compiles the actual ExFastembed Rust NIF, loads
`Xenova/bge-small-en-v1.5`, and exercises the complete semantic-cache lifecycle:

- train rows and persist their real vectors;
- route an exact hit with zero inference calls;
- route a semantic hit with exactly one query inference;
- route a semantic miss and learn it with exactly one query inference;
- snapshot and restore the learned vector without inference; and
- route the restored exact hit with zero inference calls.

Run it against a local ExFastembed checkout:

```bash
MIX_ENV=test \
SPECTRE_EX_FASTEMBED_PATH=../ex_fastembed \
SPECTRE_REAL_EMBEDDING_TESTS=1 \
mix deps.get

MIX_ENV=test \
SPECTRE_EX_FASTEMBED_PATH=../ex_fastembed \
SPECTRE_REAL_EMBEDDING_TESTS=1 \
mix test test/real_ex_fastembed_semantic_cache_test.exs \
  --include real_ex_fastembed
```

The normal `mix test` command excludes this tagged test so the unit suite stays
deterministic. CI has a dedicated real-ExFastembed job; a fixture-only pass is
not a substitute for that job.

## What requires a regression test

- application startup, child ownership, abnormal restart, normal shutdown, and
  resource cleanup;
- session start, durable restore, idle stop, dismiss, crash, and on-demand
  recovery;
- every turn boundary in execution order, including forbidden downstream calls
  after a failure;
- every lifecycle source/status transition;
- policy accept, reject, retry, exhaustion, expiry, and invalid labels;
- state before and after definite, stale, ambiguous, and post-commit journal
  persistence outcomes;
- provider success, declared error, invalid reply, timeout, exception, exit,
  throw, and cancellation;
- prompt source, target, condition, trust, path, and size failures;
- state codec migration and unsafe-value rejection;
- action registration, ownership, Skill scope, pre-commit failure,
  commit-then-crash recovery, and idempotent replay;
- semantic-cache provider-call cardinality, exact-hit short-circuiting, stored
  vectors, dataset-size invariance, misses, thresholds, mutations, snapshot
  restore, and index ownership;
- privacy of journal, telemetry, evaluation receipt, and failure metadata.

Application repositories should add end-to-end tests for their own state store,
action idempotency, authorization, delivery, prompts, models, and recovery
workflow. The Spectre suite cannot prove those host-owned boundaries.
