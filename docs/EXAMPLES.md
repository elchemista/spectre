# AgentServer examples

These examples use the 0.4 architecture. Recognition lives in an Agent;
application behavior lives in a Server; installed capabilities live in a Stack.
The complete nine-package, GAM-backed workflow is in
[`integration/stack_tools`](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md).

## A complete deterministic agent with native OTP callbacks

This example needs only Spectre and does not call a model or external service.

```elixir
defmodule Demo.AI do
  use Spectre.Stack
end

defmodule Demo.SupportServer do
  use Spectre.Server, tools: Demo.AI

  def init(_arg, ctx), do: {:ok, assign(ctx, :price, 20)}

  def handle_flow({:support, :pricing}, _input, ctx),
    do: respond(ctx, "The price is €#{ctx.assigns.price} per month.")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Ask me about pricing.")

  def handle_call(:price, _from, ctx), do: {:reply, ctx.assigns.price, ctx}
  def handle_call(message, from, ctx), do: super(message, from, ctx)

  def handle_cast({:set_price, price}, ctx) when is_integer(price) and price >= 0,
    do: {:noreply, assign(ctx, :price, price)}

  def handle_cast(message, ctx), do: super(message, ctx)
end

defmodule Demo.SupportAgent do
  use Spectre.Agent, stack: Demo.AI, server: Demo.SupportServer
  router strategies: [:regex]

  flow :support do
    on :pricing, regex: ~r/price|cost/i
  end
end

{:ok, server} = Spectre.summon(
  agent: Demo.SupportAgent, subject: "demo", consumer: self())

{:ok, _interaction_id} = Spectre.Server.input(server, "What does it cost?")
:ok = GenServer.cast(server, {:set_price, 25})
25 = GenServer.call(server, :price)
```

The Server callback module is not a second GenServer. Framework messages and
workers belong to `Spectre.Server.Runtime`, while application calls/casts/info
are delegated in that same owner process. Add checkpoint storage when the price
must survive a restart.

## Independent classification, generation and unmatched handling

The following composition assumes the named model/embedding adapters and prompt
files are implemented by the host. They can be provided by a Stack instead.

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server, prompt_root: "priv/support/prompts"

  def handle_flow({:support, :pricing}, _input, ctx),
    do: generate(ctx, :pricing, on_result: :answer)

  def handle_flow({:support, :technical}, _input, ctx),
    do: generate(ctx, :technical, on_result: :answer)

  def handle_flow(:unmatched, input, ctx) do
    case ctx.routing.reason do
      :ambiguous -> respond(ctx, "Is this about pricing or technical support?")
      :no_match -> generate(ctx, :understand, input: input, on_result: :answer)
      _ -> respond(ctx, "Recognition is unavailable; please try again.")
    end
  end

  def handle_result(:answer, {:generated, response}, ctx),
    do: respond(ctx, response.text)

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  model MyApp.ResponseModel
  classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/intents"
  classifier :llm, MyApp.IntentModel, timeout: 8_000
  embedding MyApp.Embeddings

  router strategies: [:regex, :intent_dataset, :embedding,
                       :local_classifier, :llm_classifier]

  flow :support, defaults: [collect_intent: true] do
    on :pricing, semantic_examples: ["How much is a subscription?"]
    on :technical, semantic_examples: ["My API key is not working"]
  end
end
```

The response model need not be the classifier. `:understand` is an application
prompt, not a special DSL operation. Recognition evidence selects a declared
handler; it does not grant authority. Keep labeled example collection, review,
embedding preparation and training distinct; see [Training](TRAINING.md).

## Browse, remember, prepare email and ask permission to save

The executable [outreach integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md)
installs Kinetic, Mnemonic, Lens, Prism, Beam, Directive, Pulse, Ledger and Lab
in one Stack. Its essential continuation chain is:

```elixir
# Fragments inside a Server using tools: MyApp.AI.
def handle_result(:recalled, {:ok, memories}, ctx) do
  ctx
  |> assign(:memories, memories)
  |> lens({:open, "https://shop.example.test"}, on_result: :opened)
end

def handle_result(:opened, {:ok, tab}, ctx),
  do: ctx |> assign(:tab, tab) |> lens({:look, tab}, on_result: :looked)

def handle_result(:looked, {:ok, view}, ctx),
  do: ctx |> assign(:page, view) |> lens({:close, ctx.assigns.tab}, on_result: :closed)

def handle_result(:closed, {:ok, _}, ctx) do
  generate(ctx, :contact,
    assigns: %{page: ctx.assigns.page, memories: ctx.assigns.memories},
    on_result: :composed)
end

def handle_result(:composed, {:generated, response}, ctx),
  do: kinetic(ctx, response, on_result: :prepared)

def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
  propose(ctx, proposal.operation, proposal.args,
    proposal_metadata: proposal.metadata, on_result: :email)
end
```

The model generates the action language. Kinetic prepares a closed proposal;
the host's GAM binding and admitted executor perform the email operation.
Browser views are untrusted data, not instructions. Only portable logical
browser references are stored in assigns; live resources stay in the named
Stack runtime.

Mnemonic's `remember` can bind to a host operation requiring presentation and
consent before saving the report. The host candidate freezes the authenticated
memory partition; the executor resolves the same named runtime. The integration
also demonstrates topic change, a scheduled close, suspended consent and
explicit resume. A generic yes must not approve whichever operation happens to
be found later.

Read the integration's host and test files for the full domain, scope, ingress,
candidate, executor, ambiguity and recovery wiring. Its browser/model/email
providers are deterministic fixtures. Do not copy their test-only blocking or
fake network configuration into production.

## Further recipes and compatibility

- [Actions](ACTIONS.md): deterministic and model-produced proposals.
- [Pending lifecycle](PENDING_LIFECYCLE.md): application policy, durable timers and OTP timer ownership.
- [Routing](ROUTING.md): native custom adapters and route-only evaluation.
- [Stack tools](STACK_TOOLS.md): generated helpers and installation contracts.
- [0.3 examples](legacy/EXAMPLES_0_3.md): retained Instance/Turn/Effect compositions, not new Server scaffolding.
