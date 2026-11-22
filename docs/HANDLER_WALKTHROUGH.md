# Follow one input from route to result

Build an agent that answers “help” and asks for permission to simulate a delivery when you type “send”. Try both accepting and declining.

## 1. Create the example file

Use a Mix project with Spectre installed. Create `mail_demo.exs` in the project
root and copy **the four Elixir blocks, in order**, into that file. The example
uses only core and a terminal. In an application, put each module in its own
file under `lib/`. [Installation](INSTALLATION.md).

First register the operation `:send_email`. After GAM admits it, the Runtime
calls `MailDemo.Effect.execute_effect(:deliver, args, context)`. The example
reads the body from `args`, prints it and returns a simulated receipt.

```elixir
defmodule MailDemo.Effect do
  @behaviour Spectre.Server.GAM.EffectAdapter

  @impl true
  def execute_effect(:deliver, %{"body" => body}, _context) do
    IO.puts("EFFECT: " <> body)
    {:ok, %{simulated: true}}
  end
end

defmodule MailDemo.Package do
  use Spectre.Stack.Installable, id: :mail_demo, version: "1.0.0"

  def effects(_) do
    %{send_email: %{contract: 1, adapter: MailDemo.Effect, operation: :deliver,
                    side_effect: :non_idempotent, material: :arguments,
                    partition: [], schema_hash: nil, config: %{}}}
  end
end

defmodule MailDemo.Stack do
  use Spectre.Stack
  install(MailDemo.Package)
end
```

The operation map key is `:send_email`. The descriptor's `adapter` and
`operation` select the module and the clause, here `MailDemo.Effect` and
`:deliver`. `contract: 1` selects the current effect descriptor contract.
`material: :arguments` makes the prepared arguments the approval material.
`side_effect: :non_idempotent` declares that repeating the delivery could
duplicate it. `partition: []` selects no extra identity partition fields,
`schema_hash: nil` supplies no pinned schema hash, and `config: %{}` supplies
empty adapter configuration. The Stack installs that package under its
declared `:mail_demo` ID. [Effect descriptor and scope](STACK_TOOLS.md).

## 2. Name two routes in the Agent

`stack:` names the installed capabilities and `server:` names the callback
module. `router(strategies: [:regex])` selects matching by regular expression.
`flow :mail` groups two routes. Each `on` names an intent and supplies a
whole-message pattern. The `i` regex flag lets either case match.
The text “send” becomes `{:mail, :send}`. `protected: true` requires
confirmation for the governed operation proposed from that route.

```elixir
defmodule MailDemo.Agent do
  use Spectre.Agent, stack: MailDemo.Stack, server: MailDemo.Server

  router(strategies: [:regex])

  flow :mail do
    on(:help, regex: ~r/^help$/i)
    on(:send, regex: ~r/^send$/i, protected: true)
  end
end
```

## 3. Write the callbacks in the Server

“Help” needs only `handle_flow/3`. Spectre passes the key, a `%Spectre.Input{}` and the context for this call. `respond(ctx, text)` queues a response and returns the updated context. The turn can end there.

“Send” requests more work. `propose/4` queues the `:send_email` operation with its arguments and saves `on_result: :sent`. **You choose the name `:sent`.** When the result arrives, Spectre puts that tag in the first argument of `handle_result/3`. The second argument describes what happened. Elixir selects the first clause that matches both.

```elixir
defmodule MailDemo.Server do
  use Spectre.Server

  @impl true
  def handle_flow({:mail, :help}, _input, ctx), do: respond(ctx, "Type send.")

  def handle_flow({:mail, :send}, _input, ctx),
    do: propose(ctx, :send_email, %{"body" => "Report ready"}, on_result: :sent)

  def handle_flow(key, input, ctx), do: super(key, input, ctx)

  @impl true
  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Delivery completed.")

  def handle_result(:sent, {:consent, :rejected}, ctx),
    do: respond(ctx, "Delivery declined.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

Read the success clause from left to right. `:sent` identifies the command
to resume. `{:governed, details}` is the GAM result. The map pattern requires
`details.outcome.status` to be `:succeeded` and accepts additional fields.
Rejection arrives with **the same tag** and a different tuple. The last
clause invokes the inherited defaults for other results, including errors
and uncertain outcomes. The `handle_flow` catch-all similarly keeps the Root
fallback. To rename the continuation, change `on_result:` and both
`:sent` clauses.

## 4. Play the user and observe the outcome

This block is the consumer, the process that owns the chat or UI. `agent:`
selects the declarations, `consumer: self()` sends events to the script, and
`identity.subject` is the demo's authenticated subject. The
`gam:` configuration allows the named operation and uses
`confirm: true` for every invocation of it. Ordinary `input/2` returns an
interaction ID. The caller compares it with response and pending messages.

The consumer renders the exact material from the presentation event and calls
`presented(server, ref)` to acknowledge display. It waits for the
`:pending` event because a newly rendered proposal may still be entering its
foreground wait. Then `decide(server, nil, ref, choice)` passes the human
decision. `nil` selects the Root or one of its Activities. A named Skill
decision supplies that mount ID in the same position. The five-second
`receive` timeouts belong to the example client.

```elixir
alias Spectre.Server

{:ok, server} =
  Server.start_link(
    agent: MailDemo.Agent,
    consumer: self(),
    identity: %{subject: "demo-user"},
    gam: [operations: %{send_email: [confirm: true]}]
  )

{:ok, help_id} = Server.input(server, "help")
receive do
  {Server, ^server, {:response, ^help_id, text, _meta}} -> IO.puts(text)
after
  5_000 -> raise "No help response"
end

{:ok, send_id} = Server.input(server, "send")
ref =
  receive do
    {Spectre.Server.GAM.Managed, _owner, {:presentation, material}} ->
      IO.puts(material["rendered_payload"])
      material["presentation_ref"]
  after
    5_000 -> raise "No presentation"
  end
:ok = Server.presented(server, ref)

receive do
  {Server, ^server, {:pending, ^send_id, _pending_id}} -> :ok
after
  5_000 -> raise "No consent wait"
end

choice = if IO.gets("Confirm? [yes/no] ") == "yes\n", do: :confirm, else: :reject
{:ok, _decision_id} = Server.decide(server, nil, ref, choice)
receive do
  {Server, ^server, {:response, _interaction, text, _meta}} -> IO.puts(text)
after
  5_000 -> raise "No result response"
end
GenServer.stop(server)
```

Run `mix run mail_demo.exs`. You will see `Type send.`, then the request showing “Report ready”. Answer `no` to see `Delivery declined.`. Run the command again and answer `yes`. Only this run prints `EFFECT: Report ready` followed by `Delivery completed.`.

## Trace the two paths

```text
"help" → {:mail, :help} → handle_flow → respond → consumer

"send" → {:mail, :send} → handle_flow
           → propose(:send_email, ..., on_result: :sent)
           → handle_action (default) → GAM → presentation to consumer
           → human decision → handle_pending (default)
             ├─ reject  → handle_result(:sent, {:consent, :rejected}, ctx)
             └─ confirm → GAM checks → execute_effect → Outcome
                          → handle_result(:sent, {:governed, details}, ctx)
           → respond → consumer
```

`use Spectre.Server` provides the implementations of `init/2`,
`handle_action/2` and `handle_pending/3` used here. Explicit decisions become
the normalized words `"confermo"` or `"annulla"` inside that pending handler,
with proof linked to the original presentation. The worker executor runs
after the GAM Act commits. [Callback order, arguments and return values](SERVER_CALLBACKS.md).
