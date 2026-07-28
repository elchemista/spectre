# Spectre

Spectre is an OTP-native Elixir runtime for building agents whose routing,
state, policies, and side effects remain explicit.

[![Hex.pm](https://img.shields.io/hexpm/v/spectre.svg)](https://hex.pm/packages/spectre)
[![HexDocs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/spectre)
[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)

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

The design takes inspiration from Phoenix routers, Ecto schemas, Oban workers,
Broadway pipelines, and OTP supervision trees. A Spectre agent should read like
a map, not a magic trick.

> Spectre `0.1.x` is a public preview. Runtime invariants are hardened and the
> full suite exceeds 90% line coverage, but documented APIs may still evolve in
> a minor `0.x` release. Internal modules marked with `@moduledoc false` are not
> part of the compatibility contract.

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
- `Spectre.Turn` adds one normalized next-step decision for host dispatch.
- `Spectre.Effect` describes work and its lifecycle.
- `Spectre.Awaitable` describes input the runtime is waiting for.

`Spectre.ask/3` is the low-level result API. `Spectre.turn/3` is usually the
better integration boundary for applications because it returns one of:

```elixir
{:awaiting, awaitable, result}
{:needs, effect, result}
{:completed, completion, result}
{:reply, result}
{:no_response, result}
```

## Installation

```elixir
def deps do
  [
    {:spectre, "~> 0.1.2"}
  ]
end
```

See [Installation](docs/INSTALLATION.md) for Git previews and optional
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

Package verbs are parsed only inside that package's install block. Installing
an Action does not automatically expose or authorize it; later Flow, Work,
Skill, and policy bindings select capabilities through logical Stack Refs.
Runtime clients and secrets remain outside the compiled definition. See
[Stack](docs/STACK.md) for the manifest contract, dependency validation,
runtime supervision, and legacy adapters.

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
transition lists. An open awaitable wins over a pending effect; a pending effect
wins over a terminal completion; a completion wins over a visible reply.

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

`Spectre.execute/3` returns the terminal state; it does not silently write that
state into an existing session. The host must durably store
`executed_result.state`, or call `Spectre.reset(session, executed_result.state)`
when using a live session. Action adapters also receive `:effect_id` and
`:idempotency_key` in `ctx.opts` so the real side-effect boundary can deduplicate
retries.

## Conversation Sessions

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
- [Changelog](CHANGELOG.md) - release notes and compatibility changes.
- [Roadmap](docs/ROADMAP.md) - architectural hardening and package direction.

## License

Spectre is released under the [Apache License 2.0](LICENSE).
