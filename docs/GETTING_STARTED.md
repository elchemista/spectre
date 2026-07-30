# Getting Started

Spectre gives an Elixir application a deterministic runtime around an agent:
input normalization, routing evidence, policy gates, state transitions, and an
explicit boundary for side effects.

It does not own the application database, authorization rules, model provider,
or business operation. Those remain ordinary Elixir modules.

## 1. Define The Application Boundaries

An action module performs real work:

```elixir
defmodule MyApp.SupportActions do
  def delete_account(args, ctx) do
    user_id = Keyword.fetch!(ctx.opts, :user_id)
    MyApp.Accounts.delete(user_id, args)
  end
end
```

A deterministic reply renderer can avoid an LLM call for fixed responses:

```elixir
defmodule MyApp.SupportReplies do
  def render(:help, _input, _ctx) do
    "I can explain pricing, troubleshoot the API, or manage your account."
  end

  def render(:pricing, _input, _ctx) do
    "Plans start at €20 per month."
  end

  def render(prompt, _input, _ctx), do: Atom.to_string(prompt)
end
```

The host application also provides its model and optional classifier or
embedding adapters. Spectre only expects their documented callbacks.

## 2. Define The Agent

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM,
    purpose: :smart,
    fallback: MyApp.FallbackLLM
  )

  classifier(MyApp.SmallLLM,
    local: MyApp.LocalClassifier,
    artifact_dir: "priv/spectre/support",
    llm_opts: [temperature: 0.0, max_tokens: 8]
  )

  embedding(MyApp.Embeddings,
    model: "intfloat/multilingual-e5-small"
  )

  router(
    via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier],
    terminal_labels: [:PRICING, :TECHNICAL_SUPPORT, :DELETE_ACCOUNT]
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

    after_action(:delete_account,
      on: :delivered,
      run: {MyApp.SupportAudit, :after_delivery}
    )
  end

  policy :delete_account_confirmation do
    request(:confirm_delete_account)
    accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
    reject(:cancel_delete, regex: ~r/^(no|cancel)$/i)
    otherwise(ask: :confirm_delete_account_retry)
    attempts(3, then: :cancel_pending)
  end

  interrupt :HELP, regex: ~r/^(help|menu|what can you do)$/i do
    reply(:help, renderer: {MyApp.SupportReplies, :render})
  end

  flow :support do
    on :PRICING,
      regex: ~r/\b(price|pricing|cost)\b/i,
      embedding: ["how much does it cost?", "pricing plans"],
      via: [:regex, :embedding, :classifier] do
      reply(:pricing, renderer: {MyApp.SupportReplies, :render})
    end

    on :TECHNICAL_SUPPORT,
      embedding: ["my integration is failing", "the API returns an error"],
      via: [:embedding, :classifier, :semantic_cache, :llm_classifier] do
      ask(:technical_support)
    end

    on :DELETE_ACCOUNT,
      regex: ~r/\bdelete my account\b/i,
      cache: false,
      learn: false do
      action(:delete_account)
    end
  end
end
```

This module declares:

- how input is normalized;
- which routing evidence providers may see each route;
- which handlers call an LLM and which render locally;
- which action module owns side effects;
- which actions require approval;
- which policy labels accept or reject the operation;
- how many unmatched policy replies are allowed.

The policy is deterministic. A classifier or model cannot invent a valid
approval label.

Create these prompt files for the example:

```text
priv/agents/support/prompts/technical_support.text.heex
priv/agents/support/prompts/policies/delete_account_confirmation/confirm_delete_account.text.heex
priv/agents/support/prompts/policies/delete_account_confirmation/confirm_delete_account_retry.text.heex
```

## 3. Choose The Host Boundary

Use `Spectre.ask/3` when the host wants the raw `Spectre.Result` and already has
its own lifecycle reducer.

Use `Spectre.turn/3` when the host wants Spectre to normalize the next step:

| Decision | Meaning | Host responsibility |
| --- | --- | --- |
| `{:awaiting, awaitable, result}` | Input is required | Present or externally resolve it |
| `{:needs, effect, result}` | Work is staged and executable | Execute or enqueue the effect |
| `{:completed, completion, result}` | Work is terminal | Deliver, audit, or acknowledge it |
| `{:reply, result}` | Visible text is available | Deliver `result.reply_text` |
| `{:no_response, result}` | No visible output or lifecycle work | Finish quietly |

The decision vocabulary is closed, while effect and awaitable kinds remain open
data.

## 4. Run A Normal Turn

```elixir
{:ok, turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "  HOW MUCH DOES IT COST?  ",
    conversation_id: "chat-123"
  )

{:reply, result} = turn.decision

result.input.text
# => "how much does it cost?"

result.route.label
# => :PRICING

result.reply_text
# => "Plans start at €20 per month."
```

The runtime:

1. builds a `Spectre.Input`;
2. runs the input pipeline;
3. loads state and recalled memory;
4. resumes an open policy or collects normal routing evidence;
5. asks the configured arbitrator for one route;
6. runs the route handler;
7. records compact chat history;
8. persists state, then memory.

## 5. Start A Protected Action

```elixir
{:ok, awaiting_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "delete my account",
    conversation_id: "chat-123"
  )

{:awaiting, awaitable, awaiting_result} =
  awaiting_turn.decision

awaitable.name
# => :delete_account_confirmation

[%Spectre.Effect{status: :waiting_policy}] =
  awaiting_result.state.pending_effects
```

At this point `MyApp.SupportActions.delete_account/2` has not been called.
Calling `Spectre.execute/3` with this state returns
`{:error, {:effect_not_approved, effect_id}}`.

## 6. Resolve The Policy From User Input

For stateless calls, the returned state must be supplied to the next turn. A
configured state adapter can load the same state by conversation ID instead.

```elixir
{:ok, approved_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "yes, delete it",
    state: awaiting_result.state,
    conversation_id: "chat-123"
  )

{:needs, approved_effect, approved_result} =
  approved_turn.decision

approved_effect.status
# => :approved
```

Approval changes state; it does not execute the action. A configured state
adapter persists the transition, while a live session retains it in memory.

While the policy is open, input bypasses the ordinary router, local classifier,
semantic cache, and LLM classifier. This prevents a short reply such as `"yes"`
from becoming an unrelated normal intent.

### Unmatched Replies

```elixir
{:ok, retry_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "maybe",
    state: awaiting_result.state
  )

{:awaiting, retry, retry_result} = retry_turn.decision

retry.attempts
# => 1
```

The pending effect remains `:waiting_policy`. After the configured maximum
number of unmatched replies, Spectre cancels it:

```elixir
{:ok, second_retry_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "not sure",
    state: retry_result.state
  )

{:awaiting, _awaitable, second_retry_result} =
  second_retry_turn.decision

{:ok, final_retry_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "still unsure",
    state: second_retry_result.state
  )

{:completed, cancelled, cancelled_result} =
  final_retry_turn.decision

Spectre.Effect.outcome(cancelled)
# => {:cancelled, :policy_attempts_exceeded}

cancelled_result.state.pending_effects
# => []
```

### Explicit User Rejection

```elixir
{:ok, rejected_turn} =
  Spectre.turn(
    MyApp.SupportAgent,
    "no",
    state: awaiting_result.state
  )

{:completed, cancelled, rejected_result} =
  rejected_turn.decision

Spectre.Effect.outcome(cancelled)
# => {:cancelled, {:policy_rejected, :cancel_delete}}

rejected_result.state.pending_effects
# => []
```

Rejection is a successful state transition, not a runtime error. It is terminal,
auditable, clears pending work, and never invokes the action module.

## 7. Resolve A Policy From A Trusted Host

An application may already have durable proof that a policy is satisfied or
rejected. Resolve the declared branch directly instead of synthesizing user
text:

```elixir
{:ok, approved_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:accept, :confirmed_delete},
    assigns: %{user_id: user.id}
  )
```

Host rejection uses the same terminal path as user rejection:

```elixir
{:ok, rejected_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:reject, :cancel_delete}
  )
```

The label must exist in the corresponding policy branch:

```elixir
{:error,
 {:unknown_policy_resolution_label,
  :delete_account_confirmation,
  :reject,
  :unknown_label}} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:reject, :unknown_label}
  )
```

An invalid label does not mutate a live session. Once a policy has been
resolved, a second resolution returns `{:error, :no_open_policy}`.

## 8. Execute Approved Work

Execution is a separate capability boundary:

```elixir
ctx = %{
  agent: MyApp.SupportAgent,
  input: approved_result.input,
  state: approved_result.state,
  assigns: %{user_id: user.id},
  opts: [user_id: user.id]
}

{:ok, executed_result} =
  Spectre.execute(approved_result.state, ctx)

Spectre.Result.action_outcome(executed_result)
# => {:ok, action_value}
```

The action callback receives `:effect_id` and `:idempotency_key` inside
`ctx.opts`. Use the idempotency key in the same transaction as the real business
operation. In-memory checks cannot protect against process or node restarts.

`Spectre.execute/3` returns the state containing the completed or failed effect.
The host must persist that terminal state. With a live session:

```elixir
:ok = Spectre.reset(session, executed_result.state)
```

For a durable state adapter, save `executed_result.state` in the host transaction
or execution workflow. This post-execution ownership is intentionally explicit
in the current API.

## 9. Use A Subject-Scoped Agent Instance

An Instance serializes the ordered State for one canonical Subject while
retaining each Run separately:

```elixir
subject = Spectre.Subject.new({:account, account.id})

{:ok, instance} =
  Spectre.instance(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    subject,
    idle: :timer.minutes(10)
  )

{:ok, awaiting_turn} =
  Spectre.turn(instance, "delete my account")

{:ok, approved_turn} =
  Spectre.Turn.resolve_policy(
    awaiting_turn,
    {:accept, :confirmed_delete}
  )

{:needs, _effect, approved_result} =
  approved_turn.decision

Spectre.state(instance)
# => approved_result.state
```

Instances restore configured durable State on startup when no explicit state
is provided. They retain the committed state even when memory persistence
reports a strict failure. Calls without an explicit `:subject` can still use
the legacy conversation-scoped `Spectre.Session`.

An Instance assigns each pending Effect and policy Awaitable to its Run. This
allows different channel conversations for the same Subject to wait or be
approved independently. State commits and capability execution remain ordered;
a turn received during an in-flight Invocation waits and then resumes from the
latest committed State.

Resolve authenticated channel identities to the canonical Subject before
looking up the Instance. Concurrent stateless calls that load the same snapshot
still require host-side optimistic locking. See
[Agent Instances and Subjects](INSTANCES.md).

## 10. Build A Host Dispatcher

A host such as `freelance.fast` can keep capability execution outside the turn
matcher:

```elixir
defmodule MyApp.AgentDispatcher do
  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.Turn

  def next(%Turn{decision: {:awaiting, awaitable, result}}) do
    {:await_input, awaitable, result}
  end

  def next(%Turn{decision: {:needs, effect, result}}) do
    {:execute_effect, effect, result}
  end

  def next(%Turn{decision: {:completed, %Effect{} = effect, result}}) do
    {:action_finished, Effect.outcome(effect), result}
  end

  def next(%Turn{decision: {:completed, awaitable, result}}) do
    {:awaitable_finished, awaitable, result}
  end

  def next(%Turn{decision: {:reply, %Result{} = result}}) do
    {:deliver, result.reply_text, result}
  end

  def next(%Turn{decision: {:no_response, result}}) do
    {:done, result}
  end
end
```

The dispatcher does not need separate branches for each action name or policy.
`Spectre.Result.lifecycle/1` exposes the same normalized state for logging and
telemetry:

```elixir
%{
  open_awaitable: open,
  pending_effect: pending,
  completions: completions,
  latest_completion: latest,
  action_outcome: outcome,
  visible_reply?: visible?
} = Spectre.Result.lifecycle(result)
```

## How Options Flow

Runtime reads compiled DSL metadata; it does not re-evaluate DSL blocks for each
turn. Per-call options override compiled defaults.

```elixir
Spectre.turn(MyApp.SupportAgent, "price?",
  conversation_id: "chat-123",
  via: [:regex],
  assigns: %{tenant: tenant},
  classify: &MyApp.TestClassifier.classify/2
)
```

Common groups are:

- model and classifier adapters;
- routing pipeline and arbitrator thresholds;
- embedding and semantic-cache adapters;
- `conversation_id`, `state`, `memory`, and prompt `assigns`;
- chat-history limits;
- mounted action-planner and tool-selection options;
- action execution context and idempotency metadata.

Use explicit state and adapter overrides for deterministic tests. Avoid passing
authorization decisions from model output; derive them from trusted host
context or policy branches.

## What The Application Owns

Spectre owns:

- normalized input and routing orchestration;
- deterministic policy matching;
- effect and awaitable lifecycle state;
- turn decisions and audit events;
- session serialization and idle lifecycle.

The application owns:

- model, classifier, embedding, and cache implementations;
- prompt contents;
- user authorization and tenant boundaries;
- durable state storage and concurrency control;
- action transactions and idempotency records;
- delivery, retries, monitoring, and audit retention.

Continue with [Actions](ACTIONS.md), [Routing](ROUTING.md),
[Memory](MEMORY.md), and the architectural [Roadmap](ROADMAP.md).
