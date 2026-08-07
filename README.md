# Spectre

Spectre is an OTP-native Elixir runtime for building agents whose routing,
state, policies, and side effects remain explicit.

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)

Spectre treats an agent the way OTP treats a system: a supervised set of
processes with one canonical owner for every piece of state, explicit messages
at every boundary, and recovery designed in from the start. If you know
GenServer, supervision trees, and "let it crash", you already have the mental
model — Spectre applies it to conversations, model calls, and tool execution.
This direction is deliberate and permanent: as the ecosystem evolves, its
concepts converge on OTP and the actor model, never away from them.

The goal is to describe the stable shape of an agent in one readable module
without hiding application logic behind a large callback framework. The DSL
declares repetitive structure; normal Elixir modules still own business rules,
permissions, storage, and side effects.

Spectre is intentionally built around a safety boundary:

- models and routes may propose work;
- protected work must pass a deterministic policy;
- approval changes state but does not execute the work;
- execution happens only through an explicit host call;
- every terminal outcome is returned as data.

The lifecycle around that boundary is always deterministic. How the agent
*decides* — the routing — is a dial the agent author controls, from pure regex
to a fully model-driven LLM classifier; see
[Routing: a dial, not a dogma](#routing-a-dial-not-a-dogma).

The design takes inspiration from Phoenix routers, Ecto schemas, Oban workers,
Broadway pipelines, and OTP supervision trees. A Spectre agent should read like
a map, not a magic trick.

> Spectre `0.2.0` is the first vNext core release. The full suite exceeds 90%
> line coverage, but documented APIs may still evolve in a minor `0.x`
> release. Internal modules marked with `@moduledoc false` are not part of the
> compatibility contract.

## 0.2.0 Operational Runtime

Version `0.2.0` implements the vNext core around one canonical Agent Instance
owner. It adds typed Flow, Work, Vigil, external-controller, control,
correlation, and event sections; monotonic revisions; authorized snapshots;
conflict-aware merge; transition journaling; and strict portable restart
checkpoints.

Precise Work and durable Vigil loops share isolated one-attempt Runners,
Agent-decided retry and recovery, revision fencing, budgets, pause/update/resume
control, read-only views, committed events, selective memory, and governed
delivery receipts. External libraries can provide operations or controllers
without becoming state owners.

`Spectre.State` remains conversational state and `Spectre.Run` remains a
checkpointable conversational continuation; neither was renamed to Work. See
[Work, Vigil, and the operational runtime](docs/OPERATIONS.md) and
[Migrating from 0.1.x](docs/MIGRATING_TO_0_2.md).

## 0.1.6 Recoverable Baseline

Version `0.1.6` is a consolidation-only release: it adds no runtime feature and
makes no intentional breaking change. The initially guaranteed toolchain is
Elixir 1.19 on Erlang/OTP 28. Uniform CI runs formatting, compilation with
warnings as errors, tests, non-strict Credo, Dialyzer, ExDoc, and local package
validation with no publication. The normative surface is the
[public API manifest](docs/PUBLIC_API.md).

Permanent State v5 and Run v1 fixtures under
`test/fixtures/compatibility/0.1.6` continue to protect recovery in `0.2.0`.
Core has no dependency on Kinetic, including in its test environment.

## Lifecycle At A Glance

```text
input
  -> normalize
  -> restore state and memory
  -> resolve an already-open policy, or consult ordered turn handlers
  -> collect routing evidence when no integration claims the turn
  -> arbitrate one route
  -> run handler
       -> reply / no response
       -> stage effect
            -> unprotected: pending -> execute -> completed / failed
            -> protected: waiting_policy
                 -> accepted -> approved -> execute -> completed / failed
                 -> rejected / attempts exceeded -> cancelled
```

The host-facing types have separate roles:

- `Spectre.State` is the authoritative conversation machine state.
- `Spectre.Result` is the receipt for one transition: state, emitted effects,
  awaitables, reply text, route data, and audit events.
- `Spectre.Run` is the checkpointable continuation behind one unit of work.
- `Spectre.Turn` is the public projection at the first observable boundary.
- `Spectre.Invocation` describes one revision-fenced Effect execution request.
- `Spectre.Subject` is the canonical entity served across authenticated
  channels.
- `Spectre.Instance` owns that Subject's ordered State and retained Runs.
- `Spectre.Work` defines a precise terminating operational procedure.
- `Spectre.Vigil` defines a durable observation loop between triggers.
- `Spectre.Operation.View` exposes committed loop state without ownership.
- `Spectre.Effect` describes work and its lifecycle.
- `Spectre.Awaitable` describes input the runtime is waiting for.

`Spectre.ask/3` is the low-level result API. `Spectre.turn/3` is usually the
better integration boundary for applications. Its `observable` is one of:

```elixir
{:reply, output, run_ref}
{:awaiting, invocation_ref}
{:needs, policy_boundary}
```

Actor integrations that own continuations can use the closed
`Spectre.Runtime.start/3`, `advance/2`, and `resume/3` protocol. Runtime clients,
callbacks, and process handles are re-resolved rather than stored in a Run.
The Invocation descriptor is available as `turn.boundary` when the observable
is `{:awaiting, ref}`.

## Run A Subject-Scoped Instance

For stateful applications, one Instance is identified by the portable
`AgentRef + Subject` pair rather than by a chat or process id:

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

{:ok, turn} = Spectre.turn(instance, "continue")
```

Concurrent get-or-start calls converge on the same local PID. The Instance
retains multiple Runs, gives each Run its own Effect/policy lifecycle, schedules
ordered State changes through its mailbox, and dispatches Effect Invocations
without blocking calls such as `info/1`. Conversational Effect execution
remains serialized; operational attempts use their own bounded Runner pool.
Calls arriving during an Invocation continue afterward from the latest
committed State. An authenticated channel must resolve its exact
`Spectre.ExternalIdentity` through
`Spectre.Subject.Registry`; Spectre never merges Subjects from names, similar
numbers, message text, or model output. See
[Agent Instances and Subjects](docs/INSTANCES.md).

The same Instance can own independent operational loops:

```elixir
{:ok, work_ref, _view} =
  Spectre.start_work(instance, MyApp.ReadPages, %{pages: [1, 2, 3]})

{:ok, progress} = Spectre.loop(instance, work_ref)
{:ok, paused} = Spectre.pause_loop(instance, work_ref)
{:ok, resumed} = Spectre.resume_loop(instance, work_ref)
```

Each operation attempt runs in a temporary Runner outside the Instance
mailbox. Waiting Work and Vigil loops retain no live Runner.

## Installation

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre", tag: "0.2.0"}
  ]
end
```

See [Installation](docs/INSTALLATION.md) for GitHub installation, development
snapshot pinning, and optional
SpectreKinetic and ExFastembed integrations.

## A Small Agent

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM, purpose: :smart)

  classifier(MyApp.SmallLLM,
    local: MyApp.LocalClassifier,
    artifact_dir: "priv/spectre/support"
  )

  embedding(MyApp.Embeddings,
    model: "intfloat/multilingual-e5-small"
  )

  router(
    via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier]
  )

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText,
      trim: true,
      collapse_whitespace: true,
      case: :downcase
    )
  end

  actions MyApp.SupportActions do
    protect(:delete_account, with: :delete_account_confirmation)
  end

  policy :delete_account_confirmation do
    request(:confirm_delete_account)
    accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
    reject(:cancel_delete, regex: ~r/^(no|cancel)$/i)
    otherwise(ask: :confirm_delete_account_retry)
    attempts(3, then: :cancel_pending)
  end

  interrupt :HELP, regex: ~r/^(help|menu)$/i do
    reply(:help)
  end

  flow :support do
    on :PRICING,
      regex: ~r/\b(price|pricing|cost)\b/i,
      embedding: ["how much does it cost?", "pricing plans"] do
      reply(:pricing)
    end

    on :DELETE_ACCOUNT, regex: ~r/\bdelete my account\b/i do
      action(:delete_account)
    end
  end
end
```

The application still owns `MyApp.LLM`, `MyApp.SupportActions`,
`MyApp.Embeddings`, prompt templates, durable storage, permissions, and the
actual business operation.

## Routing: A Dial, Not A Dogma

Two different things decide what an agent does, and Spectre refuses to blur
them:

- The **lifecycle** is always deterministic. Once a route is chosen, policy
  gates, Effect states, approvals, and execution follow fixed rules that no
  model output can override.
- The **decision** — which route handles this input — is exactly as
  deterministic as the agent author configures it to be.

The `via:` list is that dial. Each entry is an evidence provider, ordered from
cheapest and most predictable to most flexible:

```elixir
# Fully deterministic: only explicit patterns route; everything else
# falls through.
router(via: [:regex])

# Hybrid: deterministic matches win first, semantic evidence covers
# paraphrases.
router(via: [:regex, :embedding, :classifier])

# Model-in-the-loop: the arbitrator may ask an LLM to choose between
# declared labels when cheaper evidence is inconclusive.
router(via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier])
```

With `:llm_classifier` in the chain, routing is genuinely model-driven — but
only between labels the Agent declares, only after cheaper evidence was not
decisive, and never with the power to invent a route, skip a policy, or execute
an Effect. A refunds bot can run pure regex; an open-ended assistant can lean
on the LLM; both get the same deterministic lifecycle around the decision.
See [Routing](docs/ROUTING.md) for evidence providers, arbitration, and custom
pipelines.

## Install Packages With A Stack

`Spectre.Stack` resolves package manifests and configuration without a global
capability registry:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install MyApp.Inference do
    provider(:openrouter, MyApp.OpenRouter)
    model(:fast, id: "small-model")
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

Package verbs are parsed only inside that package's install block. When a
package declares `agent_extensions`, selecting the Stack automatically binds
those adapters to the Agent: installed configuration can therefore contribute
inference selectors, memory, turn handlers, action providers, flow syntax, and
effect executors without a second `use Package` call.

Activation is not authorization. Installing an Action does not automatically
make it planner-visible or grant permission to execute it; Flow, Work, Skill,
and policy bindings still select and protect capabilities through logical
Stack Refs. Runtime clients, processes, and secrets remain outside the compiled
definition. See [Stack](docs/STACK.md) for the manifest contract, dependency
validation, Agent binding, runtime supervision, and migration adapters.

## Two Realistic Agents

The support agent above is deliberately minimal. These two compositions show
what a useful agent looks like with one satellite package each.

### Answer questions from your database (core + Kinetic)

Each query is an ordinary function. The `@al` attribute, doc, and typespec are
all Kinetic needs to build its planning registry — no JSON schemas, no tool
catalog in the prompt:

```elixir
defmodule MyApp.Warehouse do
  use SpectreKinetic

  @al ~s(COUNT ORDERS WITH: ACCOUNT="acme" PERIOD="last_month")
  @doc "Counts orders placed by an account in a period."
  @spec count_orders(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_orders(account, period),
    do: MyApp.Reports.count_orders(account, period)

  @al ~s(TOP CUSTOMERS WITH: LIMIT="5")
  @doc "Lists the accounts with the most orders."
  @spec top_customers(String.t()) :: {:ok, [map()]} | {:error, term()}
  def top_customers(limit), do: MyApp.Reports.top_customers(limit)
end

defmodule MyApp.AnalyticsAgent do
  use Spectre.Agent

  use Spectre.Kinetic,
    actions: MyApp.Warehouse,
    modes: [count_orders: :read, top_customers: :read]

  model(MyApp.LLM, purpose: :smart)

  router(via: [:regex, :llm_classifier])

  flow :analytics do
    on :DATA_QUESTION,
      regex: ~r/\b(how many|orders|customers|revenue)\b/i do
      act(:data_question)
    end
  end
end
```

Ask a question:

```elixir
{:ok, turn} =
  Spectre.turn(MyApp.AnalyticsAgent,
    "how many orders did acme place last month?"
  )
```

`act` renders the prompt and calls the model; the model answers in compact
Action Language (`COUNT ORDERS WITH: ACCOUNT="acme" PERIOD="last_month"`);
Kinetic maps it onto `MyApp.Warehouse.count_orders/2` with validated, canonical
argument names. The planner never touches the database: the selected Action is
staged as a `:read` Effect, and the query runs only when the host executes the
`{:needs, effect, result}` decision. Add `protect(...)` to any function that
writes, and the same policy machinery from the support example guards it.

### Read a page and answer (core + Lens)

Lens gives the agent browser perception through a Stack, with browser
processes kept in an explicitly started runtime:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Lens, planner_exposure: [:look, :discover] do
    backend(SpectreLens.Browsers.Lightpanda,
      instances: 1,
      protocol: SpectreLens.Protocol.Lightpanda
    )
  end
end

defmodule MyApp.ResearchAgent do
  use Spectre.Agent, stack: MyApp.AI

  model(MyApp.LLM, purpose: :smart)

  router(via: [:regex])

  flow :research do
    on :CHECK_RELEASES, regex: ~r/\brelease page\b/i do
      action({:lens, :look},
        args: %{
          url: "https://github.com/elchemista/spectre/releases",
          opts: [include: [:markdown, :links]]
        },
        mode: :read
      )
    end
  end
end
```

Run it with the browser runtime supplied at the boundary, never stored in the
definition:

```elixir
{:ok, stack_runtime} =
  Spectre.Stack.start_link(MyApp.AI, packages: [lens: [binary: "/opt/lightpanda"]])

{:ok, turn} =
  Spectre.turn(MyApp.ResearchAgent, "check the release page",
    stack_runtime: stack_runtime
  )
```

The deterministic route stages the `:look` Action; executing it returns the
page as structured data marked `trust: :untrusted`, which the host converts
with `agent_context/2` before any model sees it. Because the Stack declares
`planner_exposure: [:look, :discover]`, an `act` route may also let the model
plan browsing — but only over those two operations, and every browser step
still passes through the same staged-Effect lifecycle.

## Run And Dispatch A Turn

```elixir
{:ok, turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "How much does it cost?",
    conversation_id: "chat-123"
  )

case turn.decision do
  {:awaiting, awaitable, result} ->
    present_policy(awaitable, result)

  {:needs, effect, result} ->
    enqueue_or_execute(effect, result)

  {:completed, completion, result} ->
    deliver_completion(completion, result)

  {:reply, result} ->
    deliver(result.reply_text)

  {:no_response, _result} ->
    :ok
end
```

`Spectre.Turn.Decision` always uses authoritative pending state before local
transition lists. Instance results scope that state to the owning Run. An open
awaitable wins over a pending effect; a pending effect wins over a terminal
completion; a completion wins over a visible reply.

## Reusable Skills

A `Spectre.Skill` is a reusable, scoped set of flows, handlers, prompts, and
policies. A Skill is not run on its own: an Agent mounts it and supplies runtime
infrastructure such as the model, router, state, memory, and action module.

```elixir
defmodule MyApp.Skills.Greeting do
  use Spectre.Skill, id: :greeting, version: 1

  flow :greeting do
    on :HELLO, regex: ~r/^hello$/i do
      run(:greet)
    end
  end

  def greet(_input, _ctx), do: {:ok, "Hello from the greeting skill!"}
end

defmodule MyApp.Agent do
  use Spectre.Agent

  skill(MyApp.Skills.Greeting, as: :greeting)
end

{:ok, result} = Spectre.ask(MyApp.Agent, "hello")
"Hello from the greeting skill!" = result.reply_text
{:skill, :greeting} = result.route.scope
```

Skills can declare logical action requirements with `requires_action/2`; the
mounting Agent binds those names to its concrete actions. This keeps reusable
behavior independent of application-specific action names and implementations.
See [Skills](docs/SKILLS.md) for a complete example, action binding, scoped
prompts and policies, and composition rules.

## Turn Semantics And Optional Owners

`Spectre.turn/3` is the canonical local host boundary: Agent modules and
supervised Sessions return the same `%Spectre.Turn{decision: ...}` vocabulary.
An external runtime that already owns a conversation-scoped interaction can
join the normal Agent path through an ordered `Spectre.Turn.Handler`.
Already-open Spectre policies keep precedence, the first replying integration
wins, and a typed handler reply cannot inject state, routes, effects, or
awaitables. Agents without handlers follow the existing route path.

This is intentionally not the integration point for every library. Memory,
Skills, actions, input transformation, telemetry, journaling, and transport
keep their narrower boundaries. SpectrePulse can wrap `Spectre.turn/3` while
owning remote addressing, correlation, task lifecycle, retries, and delivery.
See [Turn semantics and integration boundaries](docs/INTEGRATIONS.md),
including the intended shapes for SpectreDirective, SpectreLens,
SpectreMnemonic, SpectrePulse, and future packages.

## Protected Actions

Starting a protected action does not execute it:

```elixir
{:ok, awaiting_turn} =
  Spectre.turn(MyApp.SupportAgent, "delete my account")

{:awaiting, %Spectre.Awaitable{status: :open}, awaiting_result} =
  awaiting_turn.decision

[%Spectre.Effect{status: :waiting_policy}] =
  awaiting_result.state.pending_effects
```

For a stateless call, pass the returned state into the policy reply:

```elixir
{:ok, approved_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "yes, delete it",
    state: awaiting_result.state
  )

{:needs, %Spectre.Effect{status: :approved}, approved_result} =
  approved_turn.decision
```

While a policy is open, user input bypasses normal classifiers and routing.
An unknown reply increments the attempt counter. Rejection or exhausted
attempts cancels pending work, produces a terminal completion, and never calls
the action module.

A trusted host that already has durable proof can resolve the declared label
without manufacturing user text:

```elixir
{:ok, approved_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:accept, :confirmed_delete}
  )
```

Only labels declared by the policy are valid. The same API supports explicit
host rejection:

```elixir
{:ok, rejected_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:reject, :cancel_delete}
  )

{:completed, cancelled, _result} = rejected_turn.decision
{:cancelled, {:policy_rejected, :cancel_delete}} =
  Spectre.Effect.outcome(cancelled)
```

When a state adapter is configured, Spectre persists the accepted or rejected
policy transition before returning. A live `Spectre.Session` updates its
in-memory state in the same operation.

## Explicit Execution

Only `:pending` unprotected effects and `:approved` protected effects are
executable:

```elixir
ctx = %{
  agent: MyApp.SupportAgent,
  input: approved_result.input,
  state: approved_result.state,
  opts: [user_id: user.id]
}

{:ok, executed_result} =
  Spectre.execute(approved_result.state, ctx)

case Spectre.Result.action_outcome(executed_result) do
  {:ok, value} -> {:delivered, value}
  {:error, reason} -> {:failed, reason}
  {:cancelled, reason} -> {:cancelled, reason}
  nil -> :no_action_completion
end
```

`Spectre.execute/3` dispatches `:action` through the configured Action provider
and any other effect kind through the unique executor contributed by an
installed Agent extension. The lower-level State/context form returns terminal
state to its host owner; the live Instance and Session forms commit through
their process owner. Executors receive `:effect_id` and `:idempotency_key` so
the real side-effect boundary can deduplicate retries.

## Legacy Conversation Sessions

```elixir
{:ok, session} =
  Spectre.summon(
    agent: MyApp.SupportAgent,
    conversation_id: "chat-123",
    idle: :timer.minutes(10)
  )

{:ok, awaiting_turn} =
  Spectre.turn(session, "delete my account")

{:ok, rejected_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:reject, :cancel_delete}
  )

{:completed, cancelled, _result} = rejected_turn.decision
{:cancelled, _reason} = Spectre.Effect.outcome(cancelled)
```

Sessions serialize turns, retain the latest state, restore configured state
adapters on startup, and can stop after an idle timeout.

## Documentation

- [Getting Started](docs/GETTING_STARTED.md) - a complete agent and host
  lifecycle, including approval, rejection, retries, execution, and sessions.
- [System Overview](SYSTEM.md) - package responsibilities, compatibility,
  composition examples, and the design rationale for a small core with
  explicit libraries.
- [Architecture](docs/ARCHITECTURE.md) - ownership, lifecycle, trust, and host
  boundaries.
- [Integration Boundaries](docs/INTEGRATIONS.md) - input, Skills, memory,
  complete-turn ownership, Pulse protocol transport, and composition rules.
- [DSL](docs/DSL.md) - agent macros, flows, handlers, policies, actions, input
  pipeline, and prompts.
- [Skills](docs/SKILLS.md) - reusable scoped behavior, mounting, action
  requirements, prompts, policies, and complete examples.
- [Stack](docs/STACK.md) - installable packages, immutable definitions,
  logical references, and caller-owned runtime resources.
- [Resumable Runs](docs/RUNS.md) - closed Runtime steps, revision fencing,
  checkpoint/recovery, and the public Turn projection.
- [Agent Instances and Subjects](docs/INSTANCES.md) - subject-scoped ownership,
  multi-Run scheduling, Invocation receipts, and explicit identity linking.
- [Work, Vigil, and the Operational Runtime](docs/OPERATIONS.md) - Definitions,
  Runners, control, checkpoints, events, and governed delivery.
- [Migrating to 0.2.0](docs/MIGRATING_TO_0_2.md) - compatibility, checkpoint
  adapters, and incremental adoption from 0.1.x.
- [Routing](docs/ROUTING.md) - evidence providers, precedence, arbitrators,
  embeddings, and semantic cache.
- [Routing Evaluation](docs/EVALUATION.md) - corpus-based route accuracy, LLM
  usage policies, CI thresholds, and privacy-safe receipts.
- [Provider Resilience](docs/PROVIDERS.md) - timeout, cancellation, normalized
  failure, and fallback contracts for routing providers.
- [Training](docs/TRAINING.md) - datasets, classifier artifacts, verification,
  and semantic-cache training.
- [Actions](docs/ACTIONS.md) - generic providers, protected actions, policies,
  hooks, and optional planner integrations.
- [Memory](docs/MEMORY.md) - state adapters, memory adapters, persistence, and
  supervised sessions.
- [Journal](docs/JOURNAL.md) - structured decision records, privacy defaults,
  buffering, sampling, and store adapters.
- [Production Operations](docs/PRODUCTION.md) - persistence, idempotency,
  deadlines, supervision, privacy, and deployment checklist.
- [Testing](docs/TESTING.md) - verification commands, the ten-agent strategy
  matrix, local FastEmbed fixtures, and regression expectations.
- [Public API](docs/API.md) - runtime entry points and lifecycle helpers.
- [0.2.0 Public API Manifest](docs/PUBLIC_API.md) - the exact normative
  compatibility surface, including the retained 0.1.6 baseline.
- [Changelog](CHANGELOG.md) - release notes and compatibility changes.
- [Roadmap](docs/ROADMAP.md) - architectural hardening and package direction.

## License

Spectre is released under the [Apache License 2.0](LICENSE).
