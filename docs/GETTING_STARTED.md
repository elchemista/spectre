# Getting Started

This guide builds a support agent that answers questions and — the part most
agent frameworks get wrong — deletes an account only after a deterministic
confirmation policy passes and the host explicitly executes the effect. By the
end you will have seen the full lifecycle: routing, policy approval, rejection,
retries, execution, and supervised sessions.

Spectre gives an Elixir application a deterministic lifecycle around an agent:
input normalization, routing evidence, policy gates, state transitions, and an
explicit boundary for side effects. How the agent routes is your choice, from
pure regex to an LLM classifier; what happens after a route is chosen never is.

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
      reason(:technical_support)
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

## 11. Agent Recipes

The handler and runtime boundary should match the kind of work being requested.
These are the common choices:

| Need | Use | What happens |
| --- | --- | --- |
| Fixed answer | `reply/2` | A deterministic renderer returns text without an LLM |
| Model answer without tools | `reason/2` | The configured model runs with action planning disabled |
| Model answer with a closed action catalog | `act/2` | The model may propose only registered, authorized actions |
| Application orchestration | `run/2` | An Agent-local Elixir function returns a `Spectre.Result` |
| Known side effect | `action/2` | Spectre stages an Effect and applies its policy |
| Precise durable procedure | `work/2` or `Spectre.start_work/4` | A Work advances through checkpointed operation attempts |
| Repeated observation | `Spectre.register_vigil/4` | A Vigil observes, waits, and reacts to declared triggers |

### A Small Deterministic Agent

Use a renderer when the answer is fixed and does not benefit from a model:

```elixir
defmodule MyApp.SystemReplies do
  def render(:alive, _input, _context), do: "alive"
  def render(:version, _input, _context), do: MyApp.version()
end

defmodule MyApp.SystemAgent do
  use Spectre.Agent

  router(via: [:regex])

  flow :system do
    on :HEALTH, regex: ~r/^health$/i do
      reply(:alive, renderer: {MyApp.SystemReplies, :render})
    end

    on :VERSION, regex: ~r/^version$/i do
      reply(:version, renderer: {MyApp.SystemReplies, :render})
    end
  end
end

{:ok, %Spectre.Turn{observable: {:reply, "alive", _ref}}} =
  Spectre.turn(MyApp.SystemAgent, "health")
```

This is useful for health checks, menus, exact product facts, and other routes
where generated text would only add latency or uncertainty.

### A Reasoning Agent Without Side Effects

`reason/2` renders a prompt and calls the configured model, but explicitly
disables action planning:

```elixir
defmodule MyApp.ExplainerAgent do
  use Spectre.Agent, prompt_root: "priv/agents/explainer/prompts"

  model(MyApp.LLM)
  router(via: [:regex, :classifier])

  flow :explanations do
    on :EXPLAIN_ERROR, regex: ~r/^explain\s+.+/i do
      reason(:explain_error, temperature: 0.1)
    end
  end
end
```

Use `act/2` only when the Agent has a closed action planner and the selected
route is allowed to stage those actions. Use `action/2` when the operation is
already known and no model selection is needed.

### An Agent-Local Elixir Handler

`run/2` is useful for normal application orchestration that should remain in a
Flow but does not need an LLM:

```elixir
defmodule MyApp.AccountAgent do
  use Spectre.Agent

  router(via: [:regex])

  flow :account do
    on :STATUS, regex: ~r/^account status$/i do
      run(:account_status)
    end
  end

  def account_status(input, context) do
    subject_id = Keyword.fetch!(context.opts, :subject_id)
    account = MyApp.Accounts.fetch!(subject_id)

    {:ok,
     %Spectre.Result{
       input: input,
       route: context.route,
       state: context.state,
       reply_text: "Account status: #{account.status}"
     }}
  end
end
```

Keep the function short. Slow, retryable, or multi-step operations belong in a
Work so they do not own the conversational Run.

### Start A Precise Work From Chat

First declare the application operation and a finite Work:

```elixir
defmodule MyApp.Reports do
  def build(%{request: request}, _context) do
    {:ok, %{request: request, artifact: MyApp.ReportStore.build(request)}}
  end
end

defmodule MyApp.ReportWork do
  use Spectre.Work,
    id: :build_report,
    version: 1,
    input: :binary,
    state: :map,
    budget: [steps: 2, attempts: 3]

  uses_operation(:build_report)

  @impl true
  def init(request, _context), do: {:ok, %{request: request, result: nil}}

  @impl true
  def next(%{request: request, result: nil}, _context) do
    run(:build_report, %{request: request}, phase: :building)
  end

  def next(%{result: result}, _context), do: complete(result)

  @impl true
  def apply_result(state, _request, result, _context) do
    {:ok, %{state | result: result.value}}
  end

  @impl true
  def complete(%{result: nil}, _context), do: :continue
  def complete(%{result: result}, _context), do: complete(result)
end

defmodule MyApp.ReportAgent do
  use Spectre.Agent

  router(via: [:regex])

  operation(:build_report, {MyApp.Reports, :build},
    input: :map,
    output: :map,
    side_effect: :idempotent,
    retry: [max_attempts: 3]
  )

  flow :reports do
    on :BUILD_REPORT, regex: ~r/^build report\s+.+/i do
      work(MyApp.ReportWork,
        input: :text,
        origin: :chat,
        reply_text: "Report started"
      )
    end
  end
end
```

The `work/2` handler requires a subject-scoped Instance because that Instance
owns the Work checkpoint:

```elixir
{:ok, %Spectre.Turn{decision: {:reply, result}}} =
  Spectre.turn(instance, "build report for July")

work_ref = result.metadata.operation_ref
{:ok, view} = Spectre.loop(instance, work_ref)
```

The acknowledgement completes the current Turn. The Work continues through
temporary Runners and remains inspectable independently.

### Start The Same Work Without Chat

A host, scheduler, bootstrap callback, or internal event can start the Work
directly. There is no synthetic user message and no Beam dependency:

```elixir
{:ok, work_ref, initial_view} =
  Spectre.start_work(instance, MyApp.ReportWork, "report for July",
    origin: :scheduler,
    correlation_id: scheduled_job.id,
    provenance: %{source: :scheduler, job_id: scheduled_job.id}
  )

{:ok, current_view} = Spectre.loop(instance, work_ref)
```

Use this form for cron jobs, application bootstrap, queues, and other autonomous
hosts. It uses the same Work Definition, budgets, Runner isolation, and
checkpoint rules as a Work started from a Flow.

### Let A Work Ask An Internal Flow And Resume

The current public API can model an autonomous exchange with a declared wait
and trigger boundary:

```text
host starts Work
  -> Work commits an external wait
  -> :waiting event opens an internal Flow Run
  -> Flow reads the committed Work view
  -> Flow returns a schema-checked trigger
  -> Work reducer accepts the response
  -> a new Runner continues the Work
```

The Work declares exactly where it can wait and exactly which response it
accepts:

```elixir
defmodule MyApp.AutonomousResearch do
  use Spectre.Work,
    id: :autonomous_research,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external],
    triggers: [:external],
    budget: [steps: 10, attempts: 10]

  uses_operation(:collect_context)
  uses_operation(:research_query)

  def init(%{topic: topic}, _context) do
    {:ok, %{topic: topic, phase: :collect, evidence: nil, response: nil}}
  end

  def next(%{phase: :collect, topic: topic}, _context) do
    run(:collect_context, %{topic: topic}, phase: :collecting)
  end

  def next(%{phase: :ask_agent}, _context) do
    wait(:external,
      key: :next_query,
      payload: %{response_schema: %{query: :string, source: :string}}
    )
  end

  def next(%{phase: :research, response: response}, _context) do
    run(:research_query, response, phase: :researching)
  end

  def apply_result(state, %{operation: :collect_context}, result, _context) do
    {:ok, %{state | phase: :ask_agent, evidence: result.value}, phase: :awaiting_agent}
  end

  def apply_result(state, %{operation: :research_query}, result, _context) do
    {:ok, %{state | phase: :done, evidence: result.value}, phase: :finished}
  end

  def handle_trigger(state, {:external, %{query: query, source: source}}, _context)
      when is_binary(query) and query != "" and is_binary(source) and source != "" do
    {:ok, %{state | phase: :research, response: %{query: query, source: source}}}
  end

  def handle_trigger(_state, response, _context),
    do: {:error, {:invalid_internal_response, response}}

  def complete(%{phase: :done, evidence: result}, _context), do: complete(result)
  def complete(_state, _context), do: :continue
end
```

Route only the committed event classes the Agent intends to consume:

```elixir
defmodule MyApp.ResearchAgent do
  use Spectre.Agent

  router(via: [:regex])
  route_operation_events([:waiting])

  operation(:collect_context, {MyApp.ResearchOperations, :collect_context},
    input: :map,
    output: :map,
    side_effect: :none
  )

  operation(:research_query, {MyApp.ResearchOperations, :research_query},
    input: :map,
    output: :map,
    side_effect: :idempotent,
    retry: [max_attempts: 3]
  )

  flow :autonomous_work do
    on :AUTONOMOUS_WORK_REQUEST, regex: ~r/^$/ do
      run(:answer_work_request)
    end
  end

  def answer_work_request(
        %{meta: %{spectre_event: %Spectre.Operation.Event{type: :waiting} = event}} = input,
        context
      ) do
    instance = Keyword.fetch!(context.opts, :instance_pid)

    with {:ok, %{definition: :autonomous_research, phase: :awaiting_agent} = view} <-
           Spectre.loop(instance, event.loop_id),
         response <- MyApp.ResearchPolicy.choose(view.partial_results),
         {:ok, resumed} <-
           Spectre.trigger_loop(instance, event.loop_id, {:external, response},
             correlation_id: event.correlation_id,
             causation_id: event.id,
             provenance: %{source: :internal_flow, operation_event_id: event.id}
           ) do
      {:ok,
       %Spectre.Result{
         input: input,
         route: context.route,
         state: context.state,
         metadata: %{internal_response: response, operation_view: resumed}
       }}
    else
      {:ok, %Spectre.Operation.View{}} ->
        {:ok,
         %Spectre.Result{
           input: input,
           route: context.route,
           state: context.state,
           metadata: %{operation_event_ignored?: true}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

The internal Flow can use deterministic policy, Mnemonic, or a constrained
inference before constructing `response`. It produces no `reply_text`, so it
finishes without a human reply or channel delivery. The Flow must verify the
event type, Work Definition, phase, visibility, and response shape; it must not
turn the Work into an open-ended planner. Use Directive when the procedure
itself must be discovered.

This is an application-level bridge built from current `0.2.0` APIs, not a new
Work DSL verb. The complete executable version is
`test/autonomous_work_flow_example_test.exs`; its assertions are summarized in
[Testing](TESTING.md#autonomous-work-and-internal-flow-example).

### Observe Repeatedly With A Vigil

Register a Vigil when the loop must remain known between timer or event
triggers:

```elixir
{:ok, vigil_ref, _view} =
  Spectre.register_vigil(instance, MyApp.WeatherVigil, %{city: "Rome"},
    origin: :scheduler,
    correlation_id: "weather-rome"
  )

{:ok, paused} = Spectre.pause_loop(instance, vigil_ref)
{:ok, resumed} = Spectre.resume_loop(instance, vigil_ref)

{:ok, _queued} =
  Spectre.trigger_loop(instance, vigil_ref, :external,
    generation: resumed.trigger_generation
  )
```

No Runner stays alive while the Vigil waits. Updating its declared resources or
frequency should use `update_loop/4` or `update_and_resume_loop/4`, so stale
triggers are fenced by the new generation.

### Inspect, Update, And Stop Operational Loops

Use committed views instead of reading process state:

```elixir
{:ok, active} = Spectre.loops(instance, status: [:active, :waiting, :paused])

# This Work Definition declares `update_fields: [:sources]`.
{:ok, selected} =
  Spectre.resolve_loop(instance,
    kind: :work,
    definition: :web_research,
    active: true
  )

{:ok, paused} = Spectre.pause_loop(instance, selected.id)

{:ok, resumed} =
  Spectre.update_and_resume_loop(instance, selected.id, %{sources: new_urls},
    correlation_id: turn_id,
    provenance: %{source: :chat, turn_id: turn_id}
  )

{:ok, stopped} = Spectre.stop_loop(instance, selected.id, :cancelled_by_user)
```

An update succeeds only for fields declared by the controller. Pause is
reversible; stop is terminal. When `resolve_loop/3` finds multiple candidates,
it returns an ambiguity instead of selecting one heuristically.

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
- session serialization and idle lifecycle;
- canonical Instance state, operational scheduling, Runner fencing, and
  committed loop views.

The application owns:

- model, classifier, embedding, and cache implementations;
- prompt contents;
- user authorization and tenant boundaries;
- durable state storage and concurrency control;
- registered operation implementations and their external idempotency records;
- action transactions and idempotency records;
- delivery, retries, monitoring, and audit retention.

Continue with [Actions](ACTIONS.md), [Routing](ROUTING.md),
[Memory](MEMORY.md), [Work and Vigil](OPERATIONS.md), and the architectural
[Roadmap](ROADMAP.md).
