# When to use a Stack and how to add your invoice library

Start without a Stack. Add one to install reusable capabilities, such as a helper that reads a draft from your billing system and proposes issuing it.

## An agent that replies can start without a Stack

Put `use Spectre.Agent, server: MyApp.SupportServer` in the Agent and `use Spectre.Server` in the Server. That is what `mix spectre.gen.agent MyApp.SupportAgent --server` generates. You can declare routes, use `respond`, keep state and handle OTP messages without defining an empty module. [Try the minimal project](GETTING_STARTED.md).

An existing Elixir billing client can stay independent of Spectre. Add it as an ordinary application dependency. Choose the interface you need:

| You need | What to implement |
| --- | --- |
| A pure function in your own module | Call it in Elixir. Use a worker or actor for slow I/O; a synchronous call inside `handle_flow` occupies the Server. |
| A governed operation callable with `propose` | A package with `effects/1` and an adapter with `execute_effect/3`. [Minimal working example](HANDLER_WALKTHROUGH.md). |
| An `invoice(ctx, ...)` helper to read or issue | Add `tools/1`, describe the two paths and select the Stack in your Server. Follow the program below. |
| A supervised client or pool | Start it in the application’s OTP tree, or use the package’s `child_specs/2` and supervise the Stack runtime. A plain function module needs no dedicated process. |

## 1. Adapt your existing client

Copy the four Elixir blocks into `invoice_demo.exs` in a project using Spectre 0.4. The first module stands in for your existing SDK: test account draft D1 is at revision 3 with a total of EUR 24.00. Replace the **client boundary** with calls to your real billing system. The local example runs without a cloud account.

The adapter translates contracts. `prepare/3` validates locally; for `{:issue, draft}` the payload is the list `[draft]`. `invoke/3` can read in a worker; `project/2` selects the data returned to the Server. Here the billing system allows the user to read this draft. If reading also requires approval, register it as a governed operation. Only `execute_effect/3` calls the issuing endpoint.

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

  def prepare(:draft, [id], _) when is_binary(id), do: {:ok, id}
  def prepare(:issue, [%{"id" => id, "revision" => rev, "total_cents" => cents,
                         "currency" => "EUR"} = draft], _)
      when is_binary(id) and is_integer(rev) and is_integer(cents) do
    {:ok, Map.take(draft, ["id", "revision", "total_cents", "currency"])}
  end
  def prepare(_, _, _), do: {:error, :invalid_invoice_request}

  def invoke(:draft, id, context),
    do: BillingDemo.Client.draft(context.service_context.identity.subject, id)

  def project(:draft, result), do: {:ok, result}

  @impl true
  def execute_effect(:issue, draft, context),
    do: BillingDemo.Client.issue(context.identity.subject, draft)
end
```

The account comes from the application’s authenticated identity. In production the client enforces access and uses the approved draft version when issuing. The fixture makes this visible by accepting just one revision. Project explicit fields from your SDK’s response type before returning it; the fixture already returns selected fields. If the API times out after submission and the outcome is unknown, return `{:error, :ambiguous, :timeout}` and reconcile with the provider.

## 2. Register both operations and install the package

`tools/1` creates the helper name, `invoice`. For the `:draft` read, `:safe` permits replay of an interrupted read and `max_bytes` bounds portable data. For `:issue`, the `operation: :issue_invoice` field points to the **matching key** in `effects/1`. That entry registers the adapter GAM can call and the local atom `:issue` passed to `execute_effect/3`. The `[:subject]` partition requires a subject. Real credentials belong to the client configured by the application.

```elixir
defmodule BillingDemo.Package do
  use Spectre.Stack.Installable, id: :billing, version: "1.0.0"

  @impl true
  def tools(_) do
    %{invoice: %{contract: 1, adapter: BillingDemo.Adapter, default: nil,
                 operations: %{
                   draft: %{path: :cognitive, retry: :safe, max_bytes: 4096},
                   issue: %{path: :governed, operation: :issue_invoice, max_bytes: 4096}
                 }}}
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

## 3. Connect the route, helper and continuations

`stack:` on the Agent selects the installed package. `tools:` on the Server generates the local `invoice/3` function. When the user types “issue D1”, the first call reads the draft. The tag `:loaded` returns with the client reply. That clause calls the helper again, this time with `:issue` and `on_result: :issued`. This second call becomes a GAM proposal.

```elixir
defmodule BillingDemo.Agent do
  use Spectre.Agent, stack: BillingDemo.Stack, server: BillingDemo.Server
  router(strategies: [:regex])
  flow :billing do
    on(:issue, regex: ~r/^issue [A-Za-z0-9-]+$/)
  end
end

defmodule BillingDemo.Server do
  use Spectre.Server, tools: BillingDemo.Stack

  @impl true
  def handle_flow({:billing, :issue}, %{text: "issue " <> id}, ctx),
    do: invoice(ctx, {:draft, id}, on_result: :loaded)
  def handle_flow(key, input, ctx), do: super(key, input, ctx)

  @impl true
  def handle_result(:loaded, {:ok, draft}, ctx),
    do: invoice(ctx, {:issue, draft}, on_result: :issued)
  def handle_result(:loaded, {:error, :not_found}, ctx), do: respond(ctx, "Draft unavailable.")
  def handle_result(:issued, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Invoice issued.")
  def handle_result(:issued, {:consent, :rejected}, ctx), do: respond(ctx, "Issuing declined.")
  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

## 4. Try a missing draft, rejection and approval

The consumer below drives one conversation at a time. The `confirm: true` option requires consent for issuing on every route. A missing draft produces an immediate reply; for an existing draft you see the amount, currency and revision before choosing.

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

In your application, keep the client in your library, place the adapter and Installable in project modules, and put the consumer in your chat or LiveView. If you only need issuing via `propose(ctx, :issue_invoice, args, on_result: :issued)`, you can omit the generated helper and its `tools/1`. Keep `effects/1`, the installed Stack, application checks and GAM policy.
