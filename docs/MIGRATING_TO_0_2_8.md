# Migrating to 0.2.8

Spectre 0.2.8 adds data-driven Work materialization on the existing
operational runtime. State remains writer v5, Run remains writer v2, and
canonical Instance checkpoints remain schema 4. Existing durable checkpoints
need no migration.

## What changes

- Compiled and runtime-authored precise Work programs share
  `Spectre.Execution.Program`.
- Runtime Skills may carry a must-understand execution component and route to
  one of its Work ids.
- `Spectre.Execution.Materializer` seals the selected Definition, Program,
  input evidence, prompt plans/receipts, route, and continuation into an
  Execution projection and materialization.
- `Spectre.start_execution/3` and
  `Spectre.Instance.start_execution/3` start the verified materialization on
  the existing operation runtime.
- Closed typed handoffs, pure registered state migrations, and no-Effect
  rehearsal/replay are available as explicit host APIs.

## Upgrade steps

1. Pin `spectre` to tag `0.2.8` and compile with warnings as errors.
2. Run the retained State, Run, Instance, Definition, Stack, runtime Skill,
   and Routing fixture gates.
3. Run the new
   `test/fixtures/compatibility/0.2.8/data-driven-execution-v1.json`
   fixture or equivalent private Programs through
   `Spectre.Execution.Program.from_data/1`.
4. Register every referenced step, predicate, inference, and migration
   operation on the host Agent.
5. Grant those operation ids in the effective Authority Envelope and set
   explicit cost/duration ceilings where the host requires them.
6. Give every Program positive step and attempt limits; bound each repeat and
   declare every amendable state path.
7. Materialize only from a mounted Skill revision, persist the returned
   runtime value, verify the materialization, then start it through the
   Instance API.
8. Rehearse side-effecting Programs with exact recordings before enabling real
   host execution.

## Fail-closed differences

Programs reject unknown or ambiguous atom/string fields, code references,
modules and MFAs, non-portable literals, invalid schemas, unknown node kinds,
unreachable nodes, unbounded cycles, repeat-only control cycles, invalid
budgets, undeclared prompt fragments, impure predicates/migrations, and
unregistered operations.

Canonical object expressions now reload idempotently from
`Program.to_data/1`. Negative list indices cannot read or mutate trailing
elements. Erlang modules are rejected alongside Elixir modules. Authored
literal atoms and metadata normalize to JSON-stable strings, while inference
constraint strings normalize only to their known contract enums. Deep
expressions fail with a bounded validation error before canonical digesting.

Materialization revalidates Program, prompt plan, receipt, projection,
Definition Ref, continuation, input schema, and every digest. Amendments can
touch only declared state paths and cannot replace input, Program, history, or
lineage. Verification also recalculates the projection binding for mount,
route, continuation, input, prompt receipts, and mandatory input evidence;
`verify/1` is therefore as strict as construction. Handoffs require exact
Definition, target Work, and input equality.

Migration receipt operation refs are normalized before digesting and survive
ordinary JSON transport. Prompt substitution is single-pass over the original
template, so a resolved scalar containing `{{...}}` remains data. A raw
canonical Skill supplied to `mount/4` must declare `origin: :runtime`;
compiled Skills continue to mount through their trusted module or validated
Definition path.

Retry budget enforcement distinguishes the initial attempt from an actual
retry: `retries: 0` still permits the first attempt, while a configured retry
is not consumed and then denied by the ordinary prepare path.

## What does not change

- State, Run, and canonical Instance writer/reader versions are unchanged.
- Data Work uses `Spectre.Operation.Runtime`; there is no second executor or
  checkpoint model.
- A runtime Skill cannot register operation code, grant itself authority, or
  choose an executor.
- Publication, Activation, Skill mount/replace/disable, and side-effect
  execution remain trusted-host actions.
- Generated callbacks, open-ended goals, autonomous Forge behavior,
  empirical reflection, and governance remain outside this gate.

See [Data-driven execution](DATA_DRIVEN_EXECUTION.md) for the complete host
flow and [Preparing for Spectre 0.3](MIGRATING_TO_0_3.md) for the remaining
gate ledger.
