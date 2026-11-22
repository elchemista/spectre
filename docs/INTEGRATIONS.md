# Connect an AgentServer to your application

`Spectre.Server.input/3` accepts an input and returns an interaction ID.
Callbacks build commands, and the runtime sends results and events
asynchronously. The host connects each transport to that conversation owner.

```text
UI / Beam / Pulse / application actor
    -> authenticated host input boundary
    -> Server.input -> owned wait or recognition
    -> Root, Skill or exposed Flow callback
    -> reply, tool, governed proposal or Activity start
    -> handle_result on the command owner or lifecycle event
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
setup. `subject:` selects an owned AgentServer and `identity:` supplies
authenticated business identity to GAM and tools. `consumer:` receives
response, wait and lifecycle events. `stack_runtime:` locates supervised
resources. `gam.storage:` selects the persistence backend, and
`gam.operations:` configures the host's consequential operations. Retain
`interaction_id` when rendering asynchronous responses and previews.
[GAM setup](MANAGED_GAM.md), [Store options](DOMAIN_STORAGE.md).

Beam's installed helpers can inspect endpoints and submit a bound delivery
operation. The host executor sends the message only after admission. Pulse
similarly exposes protocol/contact inspection and explicitly bound sends.
Installing either package does not create an authenticated user Scope or a
mandate to contact arbitrary people.

Use the ID suited to each reply. The outer interaction ID correlates chat
responses. An Activity `ref` identifies one background execution. Its
`{:waiting_input, wait}` event supplies the `{wait.id, wait.revision}` pair
for a targeted answer. A GAM decision uses its separate Presentation
reference. [Callback and event order](SERVER_CALLBACKS.md).

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

Packages declare tools and other bindings in `c:Spectre.Stack.Installable.integration/1`
with `Spectre.Integration`. Servers call `call_tool(ctx, {installation, operation}, args)`.
Existing `tools/1` declarations still generate helpers through
`use Spectre.Server, tools: MyApp.AI`. Both paths use the installed adapter,
acquire a command identity and deliver results through `on_result:`.
Live resources stay in the named Stack runtime.

Kinetic prepares proposals from consolidated model output. Mnemonic recalls
memory and can bind writes to a governed host operation. Lens provides browser
perception and can bind actions. Directive 0.2 runs its mission reducer in an
on-demand Activity. Start it with `start_activity(ctx, {:directive, :mission}, args)`
and control it by its execution reference. The host selects the tools the mission
can call. A governed proposal still goes through the Agent's Managed GAM before
its adapter executes. [Activities and reusable flows](AGENT_SERVER.md#run-a-background-activity).

The [complete integration](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md) exercises all
nine installable packages with a real Server and GAM kernel. Its external
providers are deterministic fixtures. See [Stack tools](STACK_TOOLS.md) for
current operation shapes and recovery semantics.

## Results, recovery and remote actors

Server checkpoints, GAM journals, package stores and remote task state have
their own owners. Use portable IDs to correlate them. A trusted producer with
an external result calls `Spectre.Server.deliver(server, event_id, tag, result, opts)`.
`event_id` deduplicates delivery and `tag` selects the pending or command
continuation. Bound `session:` to the session that issued the request.
After reset it is required for callback and pending tags. Governed results
must resolve the original kernel outcome. The OutcomeDispatcher requires an
explicit host recovery and delivery adapter.

Delivery is at least once. Safe cognitive work may be repeated after restart;
nonrepeatable tools and uncertain governed effects are not blindly retried.
A remote peer evaluates a received proposal under its own authority. A transport
receipt is not the recipient's permission, and a timeout is not proof that the
remote effect did not occur.

## Upgrade an existing integration

An older Turn, Instance or Run integration uses a different state and approval
protocol. Follow the migration guide to move ownership into an AgentServer and
review the authority records your application will carry forward.
[Migration](MIGRATING_TO_0_4.md), [compatibility](COMPATIBILITY.md).
