# Turn semantics and integration boundaries

Spectre uses one local turn vocabulary, not one callback or one serialized
message for every runtime.

```text
protocol / UI / GenServer / FSM
              │
              │ validated input + stable identities
              ▼
        Spectre.turn/3
              │
              ├─ open Spectre policy
              │
              ├─ ordered Turn.Handler ownership
              │
              └─ normal Agent routing
              │
              ▼
    %Spectre.Turn{decision: ...}
              │
              ▼
       host / protocol adapter
```

The layers deliberately have different responsibilities:

| Layer | Contract | Owner |
| --- | --- | --- |
| Local Agent turn | `Spectre.turn/3` returning `%Spectre.Turn{}` | Spectre |
| Pre-route dialogue ownership | `Spectre.Turn.Handler` | configured Agent/application |
| Durable mission and plan | Directive snapshot plus Store | SpectreDirective/application |
| Remote envelope and task lifecycle | protocol adapter | SpectrePulse/application |

This keeps the semantics consistent without forcing an Agent, `GenServer`,
`gen_statem`, durable workflow, and distributed transport to pretend they have
the same execution or failure model.

## The canonical local turn

Hosts should prefer `Spectre.turn/3` when they need to decide what happens
after an Agent call:

```elixir
{:ok, %Spectre.Turn{decision: decision} = turn} =
  Spectre.turn(MyApp.Agent, input,
    conversation_id: conversation_id,
    turn_id: message_id,
    trace_id: trace_id
  )

case decision do
  {:awaiting, awaitable, result} ->
    MyApp.Channel.request_input(awaitable, result)

  {:needs, effect, result} ->
    MyApp.Effects.dispatch(effect, result)

  {:completed, completion, result} ->
    MyApp.Channel.complete(completion, result)

  {:reply, result} ->
    MyApp.Channel.reply(result.reply_text)

  {:no_response, _result} ->
    :ok
end
```

Agent modules and supervised `Spectre.Session` processes return the same turn
shape. A `GenServer` or `gen_statem` can call this API as a client and translate
the decision into its own replies or state transitions. Spectre does not guess
the native message protocol of an arbitrary process.

If a foreign process itself is the remote target, its adapter should translate
between the process's explicit API and the same conceptual turn vocabulary.
That adapter belongs beside the process or in the transport package; it does
not require Spectre to dispatch arbitrary messages to arbitrary pids.

## Choose the narrowest boundary

| Integration owns | Spectre boundary |
| --- | --- |
| Input validation or decoding | `Spectre.Input.Plug` or the host before `turn/3` |
| Reusable routes, prompts, policies, or actions | `Spectre.Skill` |
| Conversation recall and memory persistence | `memory/1` adapter |
| Durable Spectre machine state | `Spectre.State.Store` |
| A capability or external side effect | `actions/2` |
| An already-active dialogue before routing | `Spectre.Turn.Handler` |
| Observation of decisions and timings | telemetry or `Spectre.Journal.Store` |
| Remote addressing and delivery | the protocol/host around `Spectre.turn/3` |

For example, SpectreMnemonic naturally belongs behind the memory adapter.
SpectreLens browser operations belong behind trusted actions or mounted Skills,
and its Agent-safe projection can enter prompt context as data. Neither package
needs authority over every turn.

## A pre-route turn handler

A handler is the intentionally narrow escape hatch for an external runtime
that already owns a conversation-scoped interaction, such as a durable
Directive mission or an active `gen_statem` dialogue.

```elixir
defmodule MyApp.ActiveWorkflowTurn do
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request

  @impl true
  def handle_turn(%Request{} = request, opts) do
    case MyApp.Workflow.resume(request.conversation_id, request.input,
           server: opts[:server],
           turn_id: request.turn_id
         ) do
      :not_active ->
        :cont

      {:reply, text, workflow_id, status} ->
        {:reply,
         Reply.new(text,
           events: [%{type: :external_workflow_turn}],
           metadata: %{workflow_id: workflow_id, status: status}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Register handlers in explicit precedence order:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  turn_handler MyApp.ActiveCheckout, namespace: :checkout
  turn_handler MyApp.ActiveWorkflowTurn, server: MyApp.Workflow
end
```

The first handler returning `{:reply, reply}` owns the turn. `:cont` consults
the next handler and eventually the normal router. An error, crash, malformed
reply, or timeout fails closed; Spectre does not reinterpret the same input as
a different integration or route.

Handlers run:

1. after input normalization, state restoration, and memory recall;
2. after an already-open Spectre policy, which always has precedence;
3. before interrupts and ordinary routing.

The handler receives a `Spectre.Turn.Handler.Request` with normalized input,
loaded state and memory, conversation identity, turn identity, trace identity,
and assigns. It may only continue, return a typed
`Spectre.Turn.Handler.Reply`, or fail. A reply cannot replace Spectre state,
inject a route, stage effects, or manufacture awaitables. Spectre converts the
reply to a normal `Spectre.Result`, so the outer `Spectre.turn/3` still returns
the canonical `%Spectre.Turn{}`.

Use `turn_handlers false` in an Agent definition to disable the pipeline. A
trusted internal call can bypass configured handlers for one call:

```elixir
Spectre.ask(MyApp.Agent, internal_input, turn_handlers: false)
```

Do not build bypass values from untrusted message fields. Per-call options are
host authority.

## Durable Directive turns

SpectreDirective owns mission and plan state. Its Store persists a complete
snapshot at each externally visible boundary. The Directive handler only
decides whether the stored mission owns the current input and returns its
visible reply; it does not move Directive state into `Spectre.State`.

Use two stable identifiers for request/response transports:

- `conversation_id` selects the durable mission;
- `turn_id` identifies one external message/delivery attempt.

If a response is delivered ambiguously, retry the same input with the same
`turn_id`. Directive can replay the reply recorded in the snapshot without
consuming the answer twice. Reusing one `turn_id` with different input fails
closed. The Store must still perform an atomic revision check because stable
turn ids do not serialize concurrent different messages.

## SpectrePulse and agent-to-agent calls

SpectrePulse is the natural owner of the distributed protocol, not of local
Agent reasoning. Its future envelope can define:

- sender and recipient identities;
- message, context, correlation, causation, and remote task identifiers;
- request/reply, one-way event, streaming, cancellation, and terminal states;
- deadlines, retry rules, deduplication, and delivery guarantees;
- serialization, authentication, authorization context, and transport binding.

An inbound Pulse adapter should validate the envelope, map its payload to a
`Spectre.Input`, preserve stable identifiers, and call the ordinary local port:

```elixir
# Adapter sketch, not a promised SpectrePulse API.
Spectre.turn(target_agent, payload,
  conversation_id: envelope.context_id,
  turn_id: envelope.message_id,
  trace_id: envelope.trace_id
)
```

It then maps `%Spectre.Turn{}` into a Pulse reply or task transition. A remote
information request, command, or tool execution initiated by an Agent is an
outbound capability/effect, not a direct call from a pre-route handler. Today
that can be implemented as a trusted Spectre action whose adapter dispatches
through Pulse. A more general agent-effect executor should be added only when
the Pulse task contract is concrete.

An integration that stages a non-Action Effect directly must preserve the
Instance Run lifecycle:

```elixir
run_id = Spectre.Context.lifecycle_run_id(ctx)
effect = Spectre.Effect.bind_run(effect, run_id)

with {:ok, transition} <-
       Spectre.Lifecycle.apply(ctx.state, {:stage_effect, effect, policy}) do
  staged = Spectre.State.pending_effect(transition.to, run_id)
  {:ok, %{result | state: transition.to, effects: [staged]}}
end
```

The scoped lookup is significant when several Runs share one subject State.
For stateless calls and `Spectre.Session`, `lifecycle_run_id/1` returns `nil`
and the same code keeps the single-lifecycle compatibility behavior.

Pulse needs a `Turn.Handler` only when an already-active local or delegated
task must claim subsequent input before normal Agent routing. Registering a
global Pulse handler merely to decode every envelope would mix transport with
dialogue ownership.

## Composition rules

- Ordering is application-owned and visible in the Agent module; there is no
  hidden priority registry.
- A Skill cannot register handlers because a mounted Skill must not acquire
  Agent-wide infrastructure authority.
- Input plugs may enrich an input and continue. Handlers cannot mutate an
  input and continue; use the input pipeline for that job.
- Handlers are not post-turn hooks. Encode or deliver the result after
  `Spectre.turn/3`, and observe facts through telemetry or the journal.
- Persistence stays with the state machine that owns the state: Spectre state
  uses its state adapter; Directive missions use a Directive Store; Pulse task
  persistence belongs to Pulse.
- If an integration only needs one action, one memory lookup, or prompt
  context, use that dedicated port instead of claiming the turn.

The result is one clear local turn semantics with explicit adapters between
execution models, not one oversized callback that silently becomes a second
runtime and wire protocol.
