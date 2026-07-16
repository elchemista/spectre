# Spectre

Spectre is an OTP-native Elixir runtime for building agents whose routing,
state, policies, and side effects remain explicit.

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

> Spectre is still a work in progress. It is already used in real applications,
> but its public API may evolve while the runtime contracts are hardened.

## Lifecycle At A Glance

```text
input
  -> normalize
  -> collect routing evidence
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

See [Installation](docs/INSTALLATION.md) for the base dependency and optional
classifier and embedding dependencies.

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
- [DSL](docs/DSL.md) - agent macros, flows, handlers, policies, actions, input
  pipeline, and prompts.
- [Routing](docs/ROUTING.md) - evidence providers, precedence, arbitrators,
  embeddings, and semantic cache.
- [Routing Evaluation](docs/EVALUATION.md) - corpus-based route accuracy, LLM
  usage policies, CI thresholds, and privacy-safe receipts.
- [Training](docs/TRAINING.md) - datasets, classifier artifacts, verification,
  and semantic-cache training.
- [Actions](docs/ACTIONS.md) - protected actions, policies, hooks,
  SpectreKinetic, and Action Language planning.
- [Memory](docs/MEMORY.md) - state adapters, memory adapters, persistence, and
  supervised sessions.
- [Journal](docs/JOURNAL.md) - structured decision records, privacy defaults,
  buffering, sampling, and store adapters.
- [Public API](docs/API.md) - runtime entry points and lifecycle helpers.
- [Roadmap](docs/ROADMAP.md) - architectural hardening and package direction.
