# Integration boundaries in 0.4

The public AgentServer loop is asynchronous: `Spectre.Server.input/3` admits an
input, and callbacks build durable next-step commands. Transports, actor systems
and workflow packages connect to that owner without pretending to share one
serialized turn or one failure model.

```text
UI / Beam / Pulse / application actor
    -> authenticated host input boundary
    -> Server.input -> pending handler or Agent recognition
    -> Server callback -> cognitive tool or governed proposal
    -> durable result -> handle_result -> response/next step
```

The host validates identities, scopes and transport provenance. A Subject names
a local conversation owner; arbitrary process messages are not authenticated
user consent. The [GAM guide](GAM.md) explains Evidence and authority boundaries.

## Connect a user-facing transport

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: customer.id,
  identity: %{subject: customer.id, conversation: conversation.id},
  consumer: transport_pid,
  stack_runtime: MyApp.AIRuntime,
  gam: [
    storage: {:disk, "var/conversations/" <> to_string(conversation.id)},
    operations: allowed_operations
  ]
)

{:ok, interaction_id} = Spectre.Server.input(server, validated_input)
```

The referenced Agent, named resources and allowed operations are application
setup. The runtime supplies its GAM ingress and coherent stores. Authenticate
the user at the configured consumer/transport boundary and
retain correlation ids when rendering asynchronous responses or previews.
Do not treat input acceptance as completion or execute an external consequence
because a consumer event sounds confident.

Beam's installed helpers can inspect endpoints and submit a bound delivery
operation. The host executor sends the message only after admission. Pulse
similarly exposes protocol/contact inspection and explicitly bound sends.
Installing either package does not create an authenticated user Scope or a
mandate to contact arbitrary people.

## Reusable Skill processes

A Skill with `server:` has its own GenServer, callbacks, workers, streams, pending
intentions and checkpoint key. The root AgentServer automatically connects that
child to its existing GAM Domain, shared ledger and execution boundary. Stack
resources are reused; a Skill requires neither another GAM bootstrap nor a Host.

Effects must be enabled by the root's operation configuration and permitted by
the mount's `governed:` references. The shared kernel orders admission and retains
Skill invocation provenance while workers can operate concurrently. Confirmation
must identify the originating mount and exact presentation; it cannot cross to
another Skill's pending request. Timer closure is recorded in the same Domain
and never disposes of a Duty. See [Skills](SKILLS.md) and the [demo](DEMO.md).

## Use native OTP callbacks for application events

```elixir
def handle_info({:inventory_updated, sku, quantity}, ctx) do
  inventory = Map.put(ctx.assigns[:inventory] || %{}, sku, quantity)
  {:noreply, assign(ctx, :inventory, inventory)}
end

def handle_info(message, ctx), do: super(message, ctx)

def handle_flow({:stock, :check}, _input, ctx),
  do: call_actor(ctx, MyApp.Inventory, {:count, ctx.assigns.sku}, on_result: :stock)

def handle_result(:stock, quantity, ctx) when is_integer(quantity),
  do: respond(ctx, "Available: #{quantity}")

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

These are Server callback fragments, with the named actor supplied by the host.
Framework worker/timer messages are handled before application callbacks.
`call_actor` runs the request in a worker; a direct synchronous GenServer call
inside a callback still blocks the owner. Direct external effects in native
callbacks do not become governed simply because the callback belongs to a Server.

For asynchronous actor replies use `await_reply` plus `resolve_await` from a
native callback. This background wait does not capture the next user message.
`await_input` explicitly owns a foreground user answer. Store live monitor/timer
references in `ctx.private`, not durable assigns.

## Install tools once and use continuations

Packages implement the `tools/1` callback of `Spectre.Stack.Installable`.
`use Spectre.Server, tools: MyApp.AI` generates package-named helpers; no manually
invented imports are needed. Helpers normalize inputs, acquire a command identity
and deliver results through `on_result:`. Their implementation stays in package
adapters; live resources stay in the named runtime.

Kinetic prepares proposals from consolidated model output. Mnemonic recalls
memory and can bind writes to a governed host operation. Lens provides browser
perception and can bind actions. Directive is a reducer of mission state: a
returned proposed effect still needs the application's concrete dispatch path.
A plan or workflow snapshot never grants execution authority.

The [complete integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md) exercises all
nine installable packages with a real Server and GAM kernel. Its external
providers are deterministic fixtures. See [Stack tools](STACK_TOOLS.md) for
current operation shapes and recovery semantics.

## Results, recovery and remote actors

Server checkpoints, GAM journals, package stores and a remote protocol's task
state have separate owners. Keep their stable ids rather than serializing live
process handles. `Spectre.Server.deliver/4` is the durable result ingress;
governed results resolve real kernel references and original continuations.
The OutcomeDispatcher requires an explicit host recovery/delivery adapter.

Delivery is at least once. Safe cognitive work may be repeated after restart;
nonrepeatable tools and uncertain governed effects are not blindly retried.
A remote peer evaluates a received proposal under its own authority. A transport
receipt is not the recipient's permission, and a timeout is not proof that the
remote effect did not occur.

## Existing Turn/Instance integrations

`Spectre.turn/3`, `%Spectre.Turn{}`, Turn.Handler, Session, Instance and legacy
Directive/Pulse integration paths remain available. They use the older decision
and state protocol. Do not translate their approval records into GAM consent
Evidence without a deliberate host migration.

The complete [0.3 integration guide](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/INTEGRATIONS_0_3.md) remains for those
clients. [Migration](MIGRATING_TO_0_4.md) describes when to retain an old owner and
when to move behavior into a Server.
