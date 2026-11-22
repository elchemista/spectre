# When to use a Stack and how to add your invoice library

Start without a Stack. Add one to install reusable capabilities, such as a helper that reads a draft from your billing system and proposes issuing it.

## An agent that replies can start without a Stack

Put `use Spectre.Agent, server: MyApp.SupportServer` in the Agent and `use Spectre.Server` in the Server. That is what `mix spectre.gen.agent MyApp.SupportAgent --server` generates. You can declare routes, use `respond`, keep state and handle OTP messages without defining an empty module. [Try the minimal project](GETTING_STARTED.md).

An existing Elixir billing client can stay independent of Spectre. Add it as an ordinary application dependency. Choose the interface you need:

| You need | What to implement |
| --- | --- |
| A pure function in your own module | Call it in Elixir. Use a worker or actor for slow I/O; a synchronous call inside `handle_flow` occupies the Server. |
| A governed operation callable with `propose` | A package with `effects/1` and an adapter with `execute_effect/3`. [Minimal working example](HANDLER_WALKTHROUGH.md). |
| Scoped calls from a Server, reusable Flow or Activity | Declare tools in `integration/1`, install the package and bind the Stack to the Agent. Follow the program below. |
| A generated `invoice_draft(ctx, ...)` helper | Declare `helper: :invoice_draft` on the tool and set `tools:` on the Server. [Generated helpers](STACK_TOOLS.md#generated-helper-contract). |
| A supervised client or pool | Start it in the application’s OTP tree, or use the package’s `child_specs/2` and supervise the Stack runtime. A plain function module needs no dedicated process. |

## 1. Adapt your existing client

Copy the four Elixir blocks into `invoice_demo.exs` in a project using Spectre
0.4.1. The first module stands in for your existing SDK. Its draft D1 belongs
to account-7 and is at revision 3 with a total of EUR 24.00. Replace the client
boundary with calls to your billing system. The supplied client runs locally.

The adapter translates contracts. `prepare(operation, payload, trusted)`
validates the payload passed to `call_tool/4`. `invoke/3` reads in a worker and
`project/2` selects the data returned to the Server. The client authorizes
reading the current subject's draft. Register the read as a governed operation
if your policy requires consent. `execute_effect/3` calls the issuing endpoint
after GAM admits the frozen draft.

```elixir
defmodule BillingDemo.Client do
  def draft("account-7", "D1"),
    do: {:ok, %{"id" => "D1", "revision" => 3, "total_cents" => 2400, "currency" => "EUR"}}
  def draft(_, _), do: {:error, :not_found}

  def issue("account-7", %{"id" => "D1", "revision" => 3, "total_cents" => 2400, "currency" => "EUR"}) do
    IO.puts("SDK: issued D1 revision 3")
    {:ok, %{invoice_id: "demo-invoice-1"}}
  end
  def issue(_, _), do: {:error, :definitive_no_effect, :draft_unavailable}
end

defmodule BillingDemo.Adapter do
  @behaviour Spectre.Server.GAM.EffectAdapter

  def prepare(:draft, %{id: id}, _trusted) when is_binary(id), do: {:ok, id}
  def prepare(:issue, %{"id" => id, "revision" => rev, "total_cents" => cents,
                        "currency" => "EUR"} = draft, _trusted)
      when is_binary(id) and is_integer(rev) and is_integer(cents) do
    {:ok, Map.take(draft, ["id", "revision", "total_cents", "currency"])}
  end
  def prepare(_, _, _), do: {:error, :invalid_invoice_request}

  def invoke(:draft, id, context),
    do: BillingDemo.Client.draft(context.service_context.identity.subject, id)

  def project(_operation, result), do: {:ok, result}

  @impl true
  def execute_effect(:issue, draft, context),
    do: BillingDemo.Client.issue(context.identity.subject, draft)
end
```

The account comes from the application’s authenticated identity. In production the client enforces access and uses the approved draft version when issuing. The fixture makes this visible by accepting just one revision. Project explicit fields from your SDK’s response type before returning it; the fixture already returns selected fields. If the API times out after submission and the outcome is unknown, return `{:error, :ambiguous, :timeout}` and reconcile with the provider.

## 2. Register both operations and install the package

`integration/1` registers `:draft` and `:issue` under the local installation
ID `:billing`. The adapter validates both payloads. The `args:` fields and
`access: :subject_scoped` describe the public tool schema. `retry: :safe`
permits replay of an interrupted read and `max_bytes:` bounds its portable data.
The issue tool's `governed: :issue_invoice` points to the matching key in
`effects/1`. That entry supplies the local operation `:issue` to
`execute_effect/3` and describes issuing as non-idempotent. `partition: [:subject]`
binds the effect to the authenticated subject. The example uses arguments as
effect material, no custom schema hash, and empty immutable adapter configuration.
[All tool and effect options](STACK_TOOLS.md).

```elixir
defmodule BillingDemo.Package do
  use Spectre.Stack.Installable, id: :billing, version: "1.0.0", spectre: "~> 0.4.1"

  @impl true
  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:draft, BillingDemo.Adapter,
      args: [id: :string], access: :subject_scoped, retry: :safe, max_bytes: 4096)
    |> Spectre.Integration.tool(:issue, BillingDemo.Adapter,
      args: [id: :string, revision: :integer, total_cents: :integer, currency: :string],
      governed: :issue_invoice, max_bytes: 4096)
  end

  @impl true
  def effects(_) do
    %{issue_invoice: %{contract: 1, adapter: BillingDemo.Adapter, operation: :issue,
                       side_effect: :non_idempotent, material: :arguments,
                       partition: [:subject], schema_hash: nil, config: %{}}}
  end
end

defmodule BillingDemo.Stack do
  use Spectre.Stack
  install(BillingDemo.Package)
end
```

## 3. Connect the route, tools and continuations

`stack:` on the Agent supplies the installed operations. The Agent routes
“issue D1” to `handle_flow({:billing, :issue}, input, ctx)`. Its
`call_tool(ctx, {:billing, :draft}, %{id: id}, on_result: :loaded)`
uses the installation and operation pair to fetch a draft. The
`:loaded` result clause receives that reply and schedules the `:issue` tool.
That command becomes a GAM proposal for `:issue_invoice`. The tag `:issued`
connects it to the final result clause, including approval, rejection or errors.
`super/3` delegates other cases to the Server's default callback.

```elixir
defmodule BillingDemo.Agent do
  use Spectre.Agent, stack: BillingDemo.Stack, server: BillingDemo.Server
  router(strategies: [:regex])
  flow :billing do
    on(:issue, regex: ~r/^issue [A-Za-z0-9-]+$/)
  end
end

defmodule BillingDemo.Server do
  use Spectre.Server

  @impl true
  def handle_flow({:billing, :issue}, %{text: "issue " <> id}, ctx),
    do: call_tool(ctx, {:billing, :draft}, %{id: id}, on_result: :loaded)
  def handle_flow(key, input, ctx), do: super(key, input, ctx)

  @impl true
  def handle_result(:loaded, {:ok, draft}, ctx),
    do: call_tool(ctx, {:billing, :issue}, draft, on_result: :issued)
  def handle_result(:loaded, {:error, :not_found}, ctx), do: respond(ctx, "Draft unavailable.")
  def handle_result(:issued, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Invoice issued.")
  def handle_result(:issued, {:consent, :rejected}, ctx), do: respond(ctx, "Issuing declined.")
  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

## 4. Try a missing draft, rejection and approval

The consumer below drives one conversation at a time. `agent:` selects the
router and Server, `consumer:` registers the host process to receive events,
and `identity.subject` supplies the authenticated account. The configured
operation's `confirm: true` requires consent on every route. `Server.input/2`
returns the interaction ID. A reply carries that ID as `turn`. For an
existing draft, acknowledge the presentation after showing the material, then
pass its exact reference to `Server.decide/4`. The second argument `nil`
selects the Root. The other option is the mount ID for a Skill-owned decision.

```elixir
alias Spectre.Server

{:ok, server} = Server.start_link(
  agent: BillingDemo.Agent, consumer: self(), identity: %{subject: "account-7"},
  gam: [operations: %{issue_invoice: [confirm: true]}]
)
[id] = System.argv()
{:ok, turn} = Server.input(server, "issue " <> id)

receive do
  {Server, ^server, {:response, ^turn, text, _}} ->
    IO.puts(text)
  {Spectre.Server.GAM.Managed, _owner, {:presentation, material}} ->
    IO.puts(material["rendered_payload"])
    ref = material["presentation_ref"]
    :ok = Server.presented(server, ref)
    receive do
      {Server, ^server, {:pending, ^turn, _}} -> :ok
    after
      5_000 -> raise "No consent wait"
    end
    choice = if IO.gets("Issue this revision? [yes/no] ") == "yes\n", do: :confirm, else: :reject
    {:ok, _} = Server.decide(server, nil, ref, choice)
    receive do
      {Server, ^server, {:response, _, text, _}} -> IO.puts(text)
    after
      5_000 -> raise "No outcome"
    end
after
  5_000 -> raise "No reply or presentation"
end
GenServer.stop(server)
```

Run `mix run invoice_demo.exs D2` for `Draft unavailable.`. Run `mix run invoice_demo.exs D1` and type `no` for `Issuing declined.`. Run it again with `yes` for `SDK: issued D1 revision 3` followed by `Invoice issued.`.

In your application, put the consumer in your chat or LiveView and configure the
client through your OTP supervision tree or the Stack runtime. To call the
same draft tool through a generated name, add `helper: :invoice_draft` to its
declaration and set `use Spectre.Server, tools: BillingDemo.Stack`.
Then `invoice_draft(ctx, %{id: id}, on_result: :loaded)` takes the same payload.
To issue a prepared draft through a direct proposal, call
`propose(ctx, :issue_invoice, draft, on_result: :issued)` with the package's
installed effect registration and the host's operation policy.
