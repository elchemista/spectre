# Public API

This guide maps Spectre's public boundary to the job a host application needs
to perform. The module pages remain the exact function reference; this page
explains how the pieces fit together and which layer an integration should use.

Spectre `0.2.9` adds closed Definition ChangeSets, versioned gate receipts,
protected-corpus evaluation, deterministic human reports, separate approval
and activation commits, ancestor rollback, and conservative artifact GC while
retaining every earlier conformance gate and the schema-4 Skill-state runtime. The
exact modules, callables, DSL forms, callbacks, types, and
struct fields covered by its compatibility
promise are frozen in the normative [Public API Manifest](PUBLIC_API.md). The
0.1.6 conversational baseline remains included. This guide explains that
surface but does not enlarge it. Anything absent from the manifest is an
implementation detail even when it is exported or visible.

## Verify the foundation before an upgrade

Use `Spectre.Foundation.Conformance` to decode, migrate, validate, and rewrite
representative State, Run, and canonical Instance checkpoints. Use
`verify_definition/2` for both fixture bytes and compiled
Definition+Manifest pairs. Satellite suites should pass their entire package
set to `Spectre.Stack.Conformance.run/2` so cross-package requirements,
conflicts, compatibility, and ownership collisions are checked together. See
[Foundation Conformance](FOUNDATION_CONFORMANCE.md).

## Govern a Definition change

Use `Spectre.Governance.ChangeSet` to bind a portable proposal to the exact
current Activation, then pass it to `Spectre.Governance.Composer`. The trusted
host Registry resolves the closed operation vocabulary; data cannot select
code or expand effective authority. `Spectre.Governance.Review` verifies exact
receipts and a protected-corpus `EvaluationDelta`, while
`Spectre.Governance.Approval` makes the risk decision as a separate Store
commit.

Build the closure's protected corpus identity with
`Spectre.Governance.EvaluationDelta.protected_corpus_digest!/1` and pass those
same complete cases as `protected_cases:` to `EvaluationDelta.new/3`. The
digest binds canonical case content, not only case ids.

Only then may trusted host code call `Spectre.activate/3`. Governed activation
and recovery re-read Candidate, Definition, Manifest, publication receipt, and
gate receipts before the existing generation CAS. Use `Spectre.rollback/3`
only for an explicit ancestor Candidate; it creates a new activation generation
and does not reverse external Effects. `Spectre.Governance.GC.plan/3` produces
verified retention evidence but never deletes. See
[Governed Definition Changes](GOVERNANCE.md).

## Canonical behavior identity

Use `Spectre.Definition.canonical/2` to lower a compiled Agent or Skill into
portable typed data, then `Spectre.Definition.Canonical.ref/1` for its content
identity. `Spectre.Projection.generate/1` returns the exact Audit projection;
`generate/3` with `Spectre.Projection.Routing` derives a non-executable route
view bound to a versioned `Spectre.Router.IndexProfile`. Projection digests
bind the generator ID, version, and generated content. These APIs inspect
declared behavior only: they do not activate a Definition or grant authority. See
[Canonical Definitions and Audit Projections](CANONICAL_DEFINITIONS.md).

## Mount a declarative runtime Skill

Use `Spectre.Skill.Definition.new/1` for data-only runtime Skills or
`from_compiled/2` for a compiled Skill. Both expose the same semantic IR. A
trusted host creates `Spectre.Skill.Runtime` with an effective Authority
Envelope, kernel prompt reserve, and per-Skill ceiling, then performs lifecycle
changes with revision CAS.

Canonical runtime loads rederive prompt budgets and validate host-owned
fragment governance. This validation also applies to in-memory Canonical and
prebuilt Skill Definition structs; mount never treats their fields as already
trusted. JSON string operation refs are resolved only against the closed Agent
registry through `Spectre.Operation.Registry.resolve_id/2`; no atom or
executable entry is created from runtime data.

`respond/4` returns either a closed reply or a registered
`Spectre.Operation.Request`; it never executes the operation. Disable and
replacement keep old Definition generations only while exact pinned
continuations remain. Malformed routing input and non-map Canonical route or
requirement entries return structured errors rather than raising. See
[Runtime Skills and Routing Projections](RUNTIME_SKILLS.md).

## Materialize and start data-driven Work

Use `Spectre.Execution.Program.new/1` for JSON-shaped Work data or
`Spectre.Execution.Program.from_compiled/1` for a module built with
`Spectre.Execution.Work`. Runtime Skills carry the same Program IR and route
to it by stable id.

`Spectre.Execution.Materializer.materialize/4` resolves one mounted Skill
route and seals its exact Definition, Program, input evidence, prompt
plans/receipts, continuation, and Execution projection. Verify that value and
start it through `Spectre.start_execution/3`. The ordinary loop query and
pause/update/resume/stop APIs apply because data Work uses the existing
operational runtime rather than a parallel executor.

`Spectre.Execution.Handoff` carries typed Flow/Work exchanges;
`Spectre.Execution.Migration` prepares and commits pure registered state
migrations; and `Spectre.Execution.Rehearsal.run/4` replays exact recordings
without dispatching real Effects. See
[Data-driven execution](DATA_DRIVEN_EXECUTION.md).

## Publish and resolve canonical behavior

`Spectre.Definition.manifest/2` composes the canonical Definition with a Stack
Contract V2 authority envelope and execution closure. Existing Stack V1 data is
read-only input: declared capabilities become effective only when an explicit
`:authority_ceiling` grants them.

`Spectre.Definition.Store.publish/4` writes Definition, Manifest, and
publication receipt as one immutable artifact. `Spectre.Definition.Resolver`
re-reads and verifies that artifact, and reports compiled-build drift as
`:unobserved`, `:matched`, or a rejected/reported drift. See
[Definition Store, Resolver, and Manifest V2](DEFINITION_STORE.md).

## Activate a published Definition

Trusted host code creates a minimal immutable Candidate from a published
Definition, then passes only its Ref to the owning Instance:

```elixir
{:ok, candidate_ref} =
  Spectre.Definition.Resolver.bootstrap_candidate(
    definition_store,
    definition_ref,
    source: :compiled,
    checkpoint_store: checkpoint_store
  )

{:ok, activation} =
  Spectre.activate(instance, candidate_ref,
    expected_generation: 0,
    authority_epoch: 4
  )

^activation = Spectre.activation(instance)
```

The Instance re-reads Candidate, Definition, Manifest, and publication receipt
inside its sequencer. New Runs pin the committed Definition and execution
closure; open Runs preserve their prior pins. See
[Stable Identity, Activation, and Definition-Pinned Runs](IDENTITY_ACTIVATION.md).

## Admit an ownership-fenced event

`Spectre.admit_event/3` admits external events through the same Instance
mailbox that owns Runs, operations, activation, and canonical commits. A Run or
operation continuation selects its pinned Definition owner; an event origin is
retained only as evidence. New input and compatible global events use the
currently active Definition.

```elixir
{:ok, envelope} =
  Spectre.admit_event(instance,
    id: external_event_id,
    event_class: :policy_answer,
    continuation_ref: run_ref,
    correlation_id: correlation_id,
    payload_schema_ref: "my_app/policy-answer/1",
    payload: %{"answer" => "yes"}
  )
```

Missing, expired, mismatched, or ambiguous continuations are committed to the
quarantine window instead of being rebound. Use `admitted_events/2` and
`quarantined_events/2` for bounded inspection. See
[Event Ownership and Definition Lifecycle](EVENT_LIFECYCLE.md).

## Drain or revoke one Definition

`Spectre.drain_definition/3` rejects new Turns and operations while allowing
already-owned continuations to finish. `Spectre.revoke_definition/3` advances
the current authority epoch and blocks admission, continuation, commit, retry,
and Effect or operation dispatch. A Run's stored authority epoch records
lineage; it never overrides the current lifecycle record.

## Bind private Skill state to an Activation

Pass `:skill_state_transitions` to `activate/3` to initialize state or make an
explicit choice for a dormant target branch. A rollback never merges state:

```elixir
{:ok, _activation} =
  Spectre.activate(instance, candidate_ref,
    expected_generation: current_generation,
    skill_state_transitions: %{
      planner: {:resume, exact_branch_id}
    }
  )
```

The other explicit choices are `{:fork, schema_ref, state}`,
`{:migrate, source_branch_id, schema_ref, state}`, and
`{:abandon, branch_id}`. `{:init, schema_ref, state}` is valid only when no
retained dormant target branch exists.

Read through `skill_state/3` or `skill_state_branches/3`. Updates must present
the current `expected_generation`, `expected_revision`, and
`state_schema_ref`; Core also checks the active Definition and current owner
fence before committing. See [Generational Skill State](SKILL_STATE.md).

## Stack installation

`Spectre.Stack` is the compile-time package boundary. A Stack definition is
immutable and can resolve version-fenced `Spectre.Stack.Ref` values without
starting a provider. `use Spectre.Agent, stack: ...` records the selected Stack
and automatically registers every adapter listed in an installed package's
`agent_extensions` manifest field. Those adapters may contribute Agent
configuration, flow constraints and handlers, inference or action selection,
memory, turn handlers, providers, and effect executors.

This binding activates package behavior; it does not authorize every installed
Operation or Action. Capability visibility and policy remain explicit.

Use `Spectre.Stack.Runtime` only for explicitly started, caller-owned package
resources. PID, connections, clients, and secrets never belong in
`Spectre.Stack.Definition`.

## Choose the right turn API

| Need | API | Result |
| --- | --- | --- |
| Full runtime result | `Spectre.ask/3` | `{:ok, %Spectre.Result{}}` |
| One host-facing decision | `Spectre.turn/3` | `{:ok, %Spectre.Turn{}}` |
| Start a continuation | `Spectre.Runtime.start/3` | `{:continue, %Spectre.Run{}}` |
| Drive a continuation | `Spectre.Runtime.advance/2`, `resume/3` | one closed Runtime step |
| Activate a published Candidate | `Spectre.activate/3` | generation-fenced Activation snapshot |
| Inspect or update private Skill state | `skill_state/3`, `update_skill_state/4` | generation- and revision-fenced binding |
| Start precise background work | `Spectre.start_work/4` | operational ref and committed view |
| Register durable observation | `Spectre.register_vigil/4` | operational ref and committed view |
| Inspect or control a loop | `loop/3`, `pause_loop/3`, `update_and_resume_loop/4` | redacted committed view |
| Routing only | `Spectre.Router.evaluate/3` | `{:ok, %Spectre.Router.Receipt{}}` |
| Dataset evaluation | `Spectre.Eval.run/3` | `{:ok, %Spectre.Eval.Report{}}` |

`ask/3` is the low-level turn boundary. It returns reply text, effects,
awaitables, route evidence, state, and audit events:

```elixir
{:ok, result} =
  Spectre.ask(
    MyApp.SupportAgent,
    %{text: "create a project", meta: %{locale: "en"}},
    conversation_id: "conversation-42",
    assigns: %{account_id: "acct-7"}
  )

result.reply_text
result.route
result.effects
result.awaitables
result.state
```

`turn/3` starts and advances a Run to the first observable point. The Turn
contains a transport-safe `ref`, the typed `boundary`, and a compact public
`observable`:

```elixir
{:ok, turn} = Spectre.turn(MyApp.SupportAgent, "create a project")

case turn.observable do
  {:reply, output, ref} -> deliver_once(output, Spectre.Run.Ref.token(ref))
  {:needs, %Spectre.Run.Boundary{} = request} -> present_policy(request)
  {:awaiting, ref} -> enqueue(turn.boundary, ref)
end
```

`turn.decision` remains the lifecycle/result projection for local code that
needs the complete Effect or Awaitable. Transport code should prefer
`observable`, `boundary`, and `ref`. A terminal result without visible output
is projected as `{:reply, nil, ref}`; delivery adapters should skip `nil`.

Use `turn/3` for most HTTP, chat, and worker integrations. Use `ask/3` when the
host needs to inspect multiple effects or build its own reducer.

### Dispatching decisions without a hand-written switch

Most hosts branch on `turn.decision` the same way: deliver replies, execute
approved effects, surface policy requests, and pick a fallback when nothing is
deliverable. `Spectre.Turn.Dispatcher` owns that loop; the host implements
only delivery:

```elixir
defmodule MyApp.ChatDelivery do
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    MyApp.Chat.send(Keyword.fetch!(opts, :conversation_id), text)
  end
end

{:ok, turn} = Spectre.turn(instance, message.text, opts)
{:ok, _delivered} = Spectre.Turn.Dispatcher.dispatch(turn, MyApp.ChatDelivery, opts)
```

`deliver_reply/3` is the only required callback. Optional callbacks refine the
protocol: `no_response/2`, `policy_request/3`, `satisfied_resolution/2` (lets
the dispatcher auto-resolve a policy the host already knows the answer to and
continue in the same turn), `execute?/3` and `suppressed/3` (a final runtime
veto), `action_result/3`, and `fallback_reply/2` for empty outcomes. The loop
is bounded and every callback receives the merged turn options.

Use `Spectre.Runtime` only when the caller owns the continuation. Its return
vocabulary is closed:

```text
{:continue, run}
{:await, invocation, run}
{:boundary, observable, run}
{:complete, result, run}
{:error, reason, run}
```

See [Resumable Runs](RUNS.md) for fencing, checkpointing, and recovery.

## Results and lifecycle queries

`Spectre.Result` is the complete output of a turn. Prefer its query helpers to
matching internal state lists yourself:

```elixir
lifecycle = Spectre.Result.lifecycle(result)

lifecycle.open_awaitable
lifecycle.pending_effect
lifecycle.completions
lifecycle.latest_completion
lifecycle.action_outcome
lifecycle.visible_reply?

effect = Spectre.Result.pending_effect(result)
awaitable = Spectre.Result.open_awaitable(result)
completion = Spectre.Result.latest_completion(result)
outcome = Spectre.Result.action_outcome(result)
```

The important lifecycle statuses are:

```text
planned -> waiting_policy -> approved -> pending -> completed
                   |                         |        failed
                   +-------------------------+------> cancelled
```

`Spectre.State` is authoritative machine state. `revision` supports optimistic
concurrency, while `pending_effects`, `planned_effects`, and `awaitables`
describe execution safety. Treat the struct as a versioned value: persist it
through a state adapter or encode it with `Spectre.State.Codec` instead of
serializing arbitrary Erlang terms.

Extension-owned Effect builders running inside an Agent context must preserve
the current Instance lifecycle owner:

```elixir
run_id = Spectre.Context.lifecycle_run_id(ctx)
effect = Spectre.Effect.bind_run(effect, run_id)
pending = Spectre.State.pending_effect(state, run_id)
```

The helper returns `nil` for stateless calls and `Spectre.Session`, retaining
their single pending Effect behavior.

## Policy decisions and action execution

A routed handler may plan an action, but it cannot directly perform a protected
side effect. A protected action first produces a waiting effect and an open
policy awaitable:

```elixir
{:ok, result} = Spectre.ask(MyApp.ProjectAgent, "delete project 42")

[%Spectre.Effect{status: :waiting_policy}] = result.effects
[%Spectre.Awaitable{kind: :policy, status: :open}] = result.awaitables
```

The user's next message can resolve the policy through normal routing:

```elixir
{:ok, approved} =
  Spectre.ask(MyApp.ProjectAgent, "yes, delete it", state: result.state)

%Spectre.Effect{status: :approved} =
  Spectre.Result.pending_effect(approved)
```

If the host already has trusted, durable proof, resolve the declared label
without injecting synthetic user text:

```elixir
{:ok, approved} =
  Spectre.resolve_policy(
    MyApp.ProjectAgent,
    result,
    {:accept, :delete_confirmed},
    conversation_id: "conversation-42",
    assigns: %{actor_id: "user-9"}
  )
```

Execution remains explicit and separate from approval:

```elixir
{:ok, completed} =
  Spectre.execute(
    MyApp.ProjectAgent,
    approved,
    conversation_id: "conversation-42",
    assigns: %{actor_id: "user-9"}
  )

{:ok, value} = Spectre.Result.action_outcome(completed)
```

Module/Instance/Session execution persists transitions around the action boundary and
checks idempotency. `Spectre.execute(state, context)` is the lower-level form
for integrations that own those concerns themselves. See [Actions and Policy
Gates](ACTIONS.md) for action return values, protection, and hooks.

After an external delivery succeeds, lifecycle hooks can run independently:

```elixir
:ok =
  Spectre.after_action(
    MyApp.ProjectAgent,
    :delivered,
    completed,
    %{conversation_id: "conversation-42"}
  )
```

Use `Spectre.cancel/2` to cancel the active policy/effect boundary.

## Stateful Agent Instances

Calling an agent module is suitable for request-scoped runtimes backed by a
durable state adapter. An Agent Instance provides one unique local owner for
`AgentRef + Subject`, retains multiple Runs, and returns each call at its first
observable boundary:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]

subject = Spectre.Subject.new({:account, account.id})

{:ok, instance} =
  Spectre.instance(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    subject
  )

{:ok, turn} = Spectre.turn(instance, "hello")
%Spectre.State{} = Spectre.state(instance)
{:ok, ^instance} = Spectre.lookup_instance(MyApp.SupportAgent, subject)
:ok = Spectre.dismiss(MyApp.SpectreSupervisor, instance)
```

`Spectre.summon/1,3` selects the Instance runtime when `:subject` is supplied.
Prefer supervised `Spectre.instance/4` in production. See
[Agent Instances and Subjects](INSTANCES.md) for Run resume, identity linking,
per-Run lifecycle ownership, and serialized capability execution.

### Operational Work and Vigil

An Instance also owns durable operational loops that outlive the initiating
Turn. Start a versioned Work, inspect its read-only view, and control it with
revision-fenced commands:

```elixir
{:ok, ref, _view} =
  Spectre.start_work(instance, MyApp.ReadPages, %{pages: [1, 2, 3]})

{:ok, progress} = Spectre.loop(instance, ref)
{:ok, paused} = Spectre.pause_loop(instance, ref)

{:ok, resumed} =
  Spectre.update_and_resume_loop(instance, ref, %{pages: [4]},
    command_id: command_id,
    correlation_id: turn_id
  )
```

Use `register_vigil/4` for recurring observations that wait without retaining a
Runner. `start_controller/4` admits an authorized external controller onto the
same runtime; it does not give that library ownership of canonical state.

`loops/2` lists visible loops. `resolve_loop/3` returns either one exact match
or an explicit ambiguity error. `stop_loop/4` is terminal; pause is reversible.

Canonical persistence is available through `checkpoint/1`,
`flush_checkpoint/2`, `checkpoint_status/1`, and
`reconcile_checkpoint/2`. Committed events are read with
`operation_events/2` or a local subscription. Delivery consent and receipts
authorize transport but do not perform it.

See [Work, Vigil, and the operational runtime](OPERATIONS.md) for Definition,
operation, Runner, recovery, checkpoint, event, and delivery contracts.

### Legacy conversation sessions

Omitting `:subject` retains the 0.1.x Session adapter:

```elixir
{:ok, session} =
  Spectre.summon(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    conversation_id: "conversation-42"
  )
```

Supervised sessions restart after abnormal exits and restore from the configured
durable state adapter. Normal dismiss and idle shutdown do not restart a
transient session. When a persistence callback may have committed before
failing, the Session retains the candidate state and returns
`{:error, {:persistence_ambiguous, reason, result}}`; after a post-commit strict
journal failure it retains the committed state and returns
`{:error, {:persistence_journal_failed, reason, result}}`.

## Route-only evaluation

`Spectre.Router.evaluate/3` normalizes input and runs routing without loading
conversation state, memory, prompts for a selected handler, or actions:

```elixir
{:ok, receipt} =
  Spectre.Router.evaluate(MyApp.SupportAgent, "I need a refund")

receipt.outcome
receipt.label
receipt.strategy
receipt.attempts
receipt.provider_calls
receipt.llm_called?
```

`Spectre.Router.Receipt` deliberately excludes input text, generated prompts,
model output, regex matches, raw errors, and handlers. It is safe to use for
aggregate routing telemetry, subject to the metadata your adapters add.

For regression suites, `Spectre.Eval.run/3` accepts JSONL or in-memory cases:

```elixir
{:ok, report} =
  Spectre.Eval.run(
    MyApp.SupportAgent,
    [
      %{
        id: "greeting-1",
        input: "hello",
        expected_route: :greeting,
        llm: :forbidden,
        tags: [:release]
      },
      %{
        id: "refund-1",
        input: "refund order 42",
        expected_route: :refund,
        llm: :allowed,
        tags: [:release]
      }
    ]
  )

report.route_accuracy
report.confusion_matrix
report.unnecessary_llm_calls
```

See [Routing Evaluation](EVALUATION.md) for the JSONL schema and the
`mix spectre.eval` CI task.

## Routing and strategy precedence

The agent's `router` declaration selects evidence providers and their order:

```elixir
router via: [
  :regex,
  :semantic_cache,
  :classifier,
  :embedding,
  :llm_classifier
]
```

Strategies propose candidates; the configured arbitrator decides the winning
route from normalized evidence. A strategy miss is not automatically an
error. Timeouts, malformed provider replies, confidence thresholds, margins,
and ties remain visible in sanitized attempts and receipts.

The lower-level `Spectre.Router.route/2` accepts an already normalized
`Spectre.Input` and a complete `Spectre.Context`. Application integrations
should usually prefer `evaluate/3` for diagnostics or `ask/3` for a complete
turn.

See [Routing](ROUTING.md) for precedence, cache behavior, confidence, and
arbitration.

## Semantic-cache review API

`Spectre.Router.SemanticCache` is the stable facade for both custom adapters
and the built-in learned cache:

```elixir
alias Spectre.Router.SemanticCache

{:ok, examples} = SemanticCache.examples(MyApp.SupportAgent)
{:ok, example} = SemanticCache.get_example(MyApp.SupportAgent, id)
{:ok, example} = SemanticCache.verify(MyApp.SupportAgent, id)
{:ok, example} = SemanticCache.relabel(MyApp.SupportAgent, id, :billing)
:ok = SemanticCache.delete(MyApp.SupportAgent, id)
```

Online examples are editable. Static DSL examples and mirrored classifier
datasets are reviewable but read-only. Labels must still exist and allow
semantic caching, preventing a stale snapshot from introducing an undeclared
route.

Snapshots include each online row's stored embedding and can be kept in source
control or moved between deployments:

```elixir
{:ok, path} =
  SemanticCache.snapshot(
    MyApp.SupportAgent,
    path: "priv/semantic/support.jsonl"
  )

{:ok, %{loaded: loaded, skipped: skipped}} =
  SemanticCache.load_snapshot(MyApp.SupportAgent, path, strict?: false)
```

Loading a snapshot restores those vectors without invoking the embedding
adapter. A legacy vectorless snapshot remains usable for exact lookup but is
not rebuilt through remote embedding calls during a request.

Custom cache modules implement `Spectre.Router.SemanticCache` callbacks.
Mutation callbacks are optional; read-only custom caches can implement only
`lookup/2` and return a controlled error for review operations.

## Journaling, telemetry, and monitoring

`Spectre.Journal.Store` receives versioned `Spectre.Journal.Record` values.
Journaling is disabled by default and configured at agent, application, or
call level:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  journal MyApp.JournalStore,
    include_input: false,
    failure_mode: :continue
end
```

Arbitration records have stable identifiers derived from turn identity and do
not include conversation content unless `include_input: true` is explicit.
See [Journal](JOURNAL.md) for delivery and privacy semantics.

`Spectre.Telemetry.emit/4` emits events only when `:telemetry` is available;
telemetry handlers cannot crash the runtime. Event metadata is intended for
identifiers, strategies, statuses, durations, and counts—not prompts or user
content. `Spectre.Monitor` provides the built-in aggregate observer.

## Adapter contracts

Spectre exposes behaviors where a strict callback contract is useful and
function conventions where adapters may be supplied as modules, tuples, or
functions:

| Behavior | Responsibility |
| --- | --- |
| `Spectre.LLM` | Complete rendered prompts and return normalized provider output |
| `Spectre.State.Store` | Load and compare-and-swap durable conversation state |
| `Spectre.Instance.CheckpointStore` | Load and compare-and-swap the complete canonical Instance checkpoint |
| `Spectre.Operation.Controller` | Reduce deterministic Work, Vigil, or external-controller transitions |
| `Spectre.Classifier.Embedding` | Produce embedding vectors |
| `Spectre.Router.SemanticCache` | Lookup and optionally review learned routes |
| `Spectre.Journal.Store` | Append structured audit records idempotently |
| `Spectre.Turn.Handler` | Optionally own one complete normal turn before routing |

Memory adapters use `recall/2` and an optional persistence callback documented
in [Memory](MEMORY.md). Local classifier adapters expose `classify/2`; the
built-in `Spectre.Classifier` is also available for trained artifacts. Router
and input pipelines implement `Spectre.Router.Plug` and `Spectre.Input.Plug`,
while custom arbitration implements `Spectre.Router.Arbitrator`.

Turn handlers are ordered Agent infrastructure for external conversational
runtimes. They run after an already-open policy and before routing, return only
`:cont` or a typed reply, and fail closed. They are not the host turn protocol:
that contract is `Spectre.turn/3` and `%Spectre.Turn{}`. See
[Turn semantics and integration boundaries](INTEGRATIONS.md) before choosing
this broader port.

Routing-critical providers run through `Spectre.Provider.Call`, which enforces
deadline validation, isolation, reply normalization, and sanitized failures.
Provider-declared `{:error, reason}` values are preserved; crashes, exits,
throws, timeouts, and malformed replies become `Spectre.Provider.Failure`
values. See [Provider Resilience](PROVIDERS.md).

## Option precedence

Unless a module documents a narrower rule, runtime options are resolved from
least to most specific:

1. Spectre defaults.
2. Application configuration.
3. Agent DSL configuration.
4. Adapter tuple options.
5. Per-call options.

This lets production defaults remain centralized while a single evaluation or
turn can override a timeout, threshold, state, adapter, or diagnostic flag.
Do not pass untrusted user fields directly as runtime options.

## Errors

Public operations use tagged tuples and avoid raising for provider or user
failures:

```elixir
case Spectre.turn(MyApp.Agent, input) do
  {:ok, turn} -> handle(turn)
  {:error, %Spectre.Provider.Failure{} = failure} -> retry_or_degrade(failure)
  {:error, {:state_conflict, details}} -> reload_and_retry(details)
  {:error, reason} -> report(reason)
end
```

Configuration and DSL validation may raise at compile time because the agent
definition is invalid. Runtime adapter implementations should preserve the
documented tagged-tuple contracts and must not place secrets or raw user input
inside error reasons that could reach logs.

For a complete deployable setup, continue with [Production](PRODUCTION.md).
