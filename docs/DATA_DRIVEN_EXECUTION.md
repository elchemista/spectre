# Data-driven execution

Spectre 0.2.8 adds precise Work programs authored as portable data. Compiled
and runtime-authored programs normalize into the same
`Spectre.Execution.Program` IR and execute through the existing
`Spectre.Operation.Runtime`. They therefore share one lifecycle, runner,
checkpoint, fencing, retry, control, query, and recovery implementation.

Authored data describes a finite graph. It never supplies a module, callback,
MFA, evaluator, executor, authority grant, or lifecycle policy. Every step,
predicate, inference, and migration names an operation that the host Agent
already registered.

## One IR from compiled or runtime declarations

A compiled Work uses the closed DSL:

```elixir
defmodule MyApp.ResolveTicket do
  use Spectre.Execution.Work,
    id: :resolve_ticket,
    version: 1,
    entry: :lookup,
    input: :map,
    state: :map,
    initial: :input,
    budget: %{steps: 4, attempts: 4, duration_ms: 10_000, cost: 5}

  step :lookup,
    operation: :lookup_ticket,
    input: :state,
    save_as: ["ticket"],
    next: :decide

  decide :decide,
    predicate: :resolved?,
    input: :state,
    on_true: :done,
    on_false: :failed

  finish :done, output: :state
  fail :failed, :ticket_not_resolved
end
```

The runtime equivalent is ordinary JSON-shaped data:

```elixir
{:ok, program} =
  Spectre.Execution.Program.new(%{
    "id" => "resolve_ticket",
    "version" => 1,
    "entry" => "lookup",
    "input" => "map",
    "state" => "map",
    "initial" => "input",
    "budget" => %{
      "steps" => 4,
      "attempts" => 4,
      "duration_ms" => 10_000,
      "cost" => 5
    },
    "nodes" => [
      %{
        "id" => "lookup",
        "kind" => "step",
        "operation_ref" => "lookup_ticket",
        "input" => "state",
        "save_as" => ["ticket"],
        "next" => "decide"
      },
      %{
        "id" => "decide",
        "kind" => "decide",
        "predicate_ref" => "resolved?",
        "input" => "state",
        "on_true" => "done",
        "on_false" => "failed"
      },
      %{"id" => "done", "kind" => "complete", "output" => "state"},
      %{"id" => "failed", "kind" => "fail", "reason" => "ticket_not_resolved"}
    ]
  })
```

`Program.from_compiled/1` and `Program.new/1` produce byte-identical
`Program.to_data/1` values and equal digests for equivalent declarations.
The graph must be reachable and terminating. Cycles are rejected unless they
cross an explicit bounded `repeat` node, and every program has positive step
and attempt limits.

## Closed expressions and registered operations

`Spectre.Execution.Expression` can read only the immutable input, current
state, or last operation result; embed a portable fixed value; or assemble a
map/list from those values. State writes use declared paths. Negative indices,
duplicate atom/string key forms, modules, MFAs, PIDs, functions, references,
and non-portable values fail closed. Program-authored literals and metadata
normalize recursively to JSON-stable values (non-contract atoms become their
string names), and expression nesting is bounded before identity is digested.

The host owns operation code:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  operation :lookup_ticket, {MyApp.Tickets, :lookup},
    input: :map,
    output: :map,
    side_effect: :none

  operation :resolved?, {MyApp.Tickets, :resolved?},
    input: :map,
    output: :boolean,
    domain: [true, false],
    side_effect: :none
end
```

`decide` predicates and state migrations must resolve to pure
`side_effect: :none` operations. `infer` nodes resolve only to registered
cognitive operations and carry typed inference constraints. JSON operation
names are bridged only to an identically named existing registry entry; no
atom or executable code is created from authored data. Known inference enum
strings normalize to the existing contract atoms, while unknown enum values
are rejected instead of depending on the VM atom table.

## Materialization and execution

A runtime Skill embeds one or more Programs and routes to a Work handler.
Mount validates every operation binding and checks Work cost and duration
against the effective Authority Envelope. Selection then produces one sealed
materialization:

```elixir
{:ok, materialization, skill_runtime} =
  Spectre.Execution.Materializer.materialize(
    skill_runtime,
    %{text: "resolve ticket 42", meta: %{}},
    %{scope: :support},
    expected_revision: 1
  )

:ok = Spectre.Execution.Materialization.verify(materialization)

{:ok, loop_ref, view} =
  Spectre.start_execution(instance, materialization, id: "ticket-42")
```

Routing, Work input resolution, prompt rendering, Definition pinning, prompt
receipts, and Execution projection happen once. Starting execution revalidates
the materialization and feeds the exact Program to the shared operational
runtime. The Instance APIs `loop/2`, `loops/1`, `pause_loop/2`,
`update_and_resume_loop/3`, `resume_loop/2`, and `stop_loop/2` retain
their normal semantics. `Materialization.verify/1` repeats the construction
binding for mount, route, continuation, input, plans, receipts, and mandatory
projection evidence; a self-consistent materialization digest cannot hide
drift between those fields and its projection.

An amendment can change only state paths listed in `mutable_paths`. It cannot
replace the Program, input, history, receipts, prompt plans, Definition Ref, or
materialization lineage. Recovery reloads the exact embedded Program and
continues under a fresh epoch and snapshot fence.

## Prompt evidence and model constraints

An `infer` node refers to a governed prompt fragment in the owning Skill.
`Spectre.Prompt.Materializer` renders only declared scalar placeholders and
returns both a typed `Spectre.Prompt.Plan` and
`Spectre.Prompt.Receipt`. Replacement is a single pass over the original
template, so placeholder-like text inside a resolved value is never expanded
again. The receipt binds:

- the exact Definition Ref and fragment digest;
- rendered bytes and their digest, without copying prompt text;
- input evidence digest and provenance digest;
- effective placement, trust, visibility, priority, budget class, and cap; and
- generator id/version.

`Spectre.Projection.Execution` contains only stable program identity,
lineage, plan digests, receipt summaries, route evidence, and budgets. Input
and prompt content do not enter the projection. Prism or another selector may
choose a compatible model profile from the typed constraints, but that choice
does not grant operation or lifecycle authority.

## Typed handoffs

`Spectre.Execution.Handoff` represents Flow → Work, Work → Work, and Work →
Flow exchanges as portable data. A handoff binds an exact Definition Ref,
stable source and target ids, closed input, parent/correlation lineage,
provenance, and a content digest.

`Handoff.validate_target/2` requires the exact materialization Definition,
Work id, and input. `Handoff.event/1` emits a Flow-target event; it does not
call a Flow or start a Work by itself. Admission remains a host/runtime action.

## Registered state migrations

`Spectre.Execution.Migration.prepare/4` resolves a migration declared by the
Program and returns a normal registered operation request. The host executes
that request through its existing boundary. `Migration.commit/3` then
revalidates the operation contract, input, output schema, request lineage, and
digests before returning the migrated state and an integrity receipt.

There is no callback selected by state data, and migration preparation never
executes the operation.

## Rehearsal without Effects

`Spectre.Execution.Rehearsal.run/4` drives the real transition engine using
exact recorded operation boundaries. It never invokes the registered
executor, including for operations marked idempotent or non-idempotent.
Recordings bind the operation ref and exact input digest; missing, extra,
ambiguous, or malformed recordings fail closed.

The returned `Spectre.Execution.Rehearsal.Report` records privacy-safe trace,
retry/reconcile status, final-state and outcome digests, consumed recording
count, and `effect_dispatches: 0`. Running the same Program, input, and
recordings produces the same report digest.

The permanent fixture at
`test/fixtures/compatibility/0.2.8/data-driven-execution-v1.json` pins a
portable Program and its no-Effect rehearsal identities.

## Security and scope

- Runtime data cannot register code or select modules/MFAs.
- Security, executor, priority grants, authority, and lifecycle policy remain
  host-owned.
- Program and receipt digests are recomputed on every load boundary.
- Cost, duration, attempts, steps, retries, and repeat counts are explicit and
  bounded.
- Prompt and input content stay outside projections and receipts.
- Publication, Skill lifecycle, Candidate creation, and Activation remain
  explicit trusted-host actions.

This gate does not add generated callbacks, goal/mission hierarchies,
autonomous Forge behavior, governance, or model self-activation.
