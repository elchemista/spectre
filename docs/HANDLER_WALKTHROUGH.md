# Follow one input from route to result

Build an agent that answers “help” and asks for permission to simulate a delivery when you type “send”. Try both accepting and declining.

## 1. Create the example file

In a Mix project with the dependency `{:spectre, "~> 0.4.0"}`, run `mix deps.get`. Create `mail_demo.exs` in the project root. Copy **the four Elixir blocks on this page, in order**, into that file. You only need core and a terminal. In an application each module would normally live in its own file under `lib/`.

First register what the application can do. Its public operation name is `:send_email`. Once GAM admits the operation, the runtime calls `MailDemo.Effect.execute_effect(:deliver, args, context)`. Here the effect prints one line and returns a simulated receipt so you can see exactly when it runs.

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

The descriptor’s `adapter` and `operation` identify the module and clause to call. `material: :arguments` includes the arguments in the approval material. `:non_idempotent` declares that repeating delivery could duplicate it. Package and adapter authors write this registration. When a package already registers the effect, use its public operation name.

## 2. Name two routes in the Agent

`flow :mail` groups routes. Each `on` labels a recognizable input. The router matches the text and builds the key it passes to the Server. Here “send” becomes `{:mail, :send}`.

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

Read the success clause from left to right. `:sent` identifies the command to resume. `{:governed, details}` is the GAM result. The map pattern requires `details.outcome.status` to be `:succeeded` and accepts additional fields. Rejection arrives with **the same tag** and a different tuple. The last clause preserves default handling for other results, including errors and uncertain outcomes. To rename this continuation, change `on_result:` and the two `:sent` clauses. The route `:send` and operation `:send_email` still work.

## 4. Play the user and observe the outcome

This block is the consumer, the process that would own the chat or UI in an application. It starts the Server with a demo identity and enables the operation. It tries the simple reply, then displays the material GAM asks the user to approve. `presented/2` acknowledges display. After the `:pending` event, send the human choice with `decide/4`. Its second argument, `nil`, selects the root Server.

```elixir
alias Spectre.Server

{:ok, server} = Server.start_link(
  agent: MailDemo.Agent, consumer: self(), identity: %{subject: "demo-user"},
  gam: [operations: %{send_email: [confirm: true]}]
)

{:ok, help_id} = Server.input(server, "help")
receive do
  {Server, ^server, {:response, ^help_id, text, _meta}} -> IO.puts(text)
after
  5_000 -> raise "No help response"
end

{:ok, send_id} = Server.input(server, "send")
ref = receive do
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

`use Spectre.Server` provides the implementations of `init/2`, `handle_action/2` and `handle_pending/3` used here. The order of definitions in the file does not schedule events. For timers, Skill events, pending input and asynchronous commands, see [callback order, arguments and return values](SERVER_CALLBACKS.md).
