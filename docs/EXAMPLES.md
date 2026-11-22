# AgentServer examples

These examples use the 0.4 architecture. Recognition lives in an Agent;
application behavior lives in a Server; installed capabilities live in a Stack.
The complete nine-package, GAM-backed workflow is in
[`integration/stack_tools`](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md).

## Deterministic quickstart

From the Core checkout, run `mix run docs/examples/agent_server_quickstart.exs`.
The Agent recognizes pricing by pattern or local text similarity. The Server
returns a fixed reply. The script starts the process, sends one input and
reads the response using its interaction ID.
[Source walkthrough](../README.md#build-a-deterministic-agent).

## Chat and reusable Documents flow

From a Spectre source checkout, run the 0.4.1 examples.

```sh
mix run docs/examples/core_agents/run.exs
```

Both agents use the same local model fixture and `:chat` prompt. Hello Agent
sends its unmatched input to `generate/2` and uses the Server's default reply.
Documents installs a package, exposes its flow through `expose :documents`,
and reads a document with `call_tool(ctx, {:documents, :read}, args)`. Its
flow handles the successful result. Framework defaults report provider and tool
errors as failed results. Ordinary chat and document lookup start zero Activities.
Copy the modules and replace the local model and document adapter with your own.
Place the prompt under `priv/prompts` and point your Server's `prompt_root` there.
[Example source](examples/core_agents/core_agents.exs).

## Open chat and parallel Directive missions

Run the example from a Directive 0.2.0 checkout alongside the Core checkout.
`SPECTRE_PATH` points its Mix project at the local Core 0.4.1 source.

```sh
SPECTRE_PATH=../spectre mix run examples/agent_server_activity.exs
```

[Directive repository](https://github.com/elchemista/spectre_directive).

The script starts one Root and classifies natural-language requests as chat
or mission. It remembers the project mentioned in chat, starts two missions with
distinct references, answers chat while both run, revises one and answers the
other's question. It also shows the failure event when the model fails.
The provider fixtures make the run repeatable. In an application, configure your
model provider to classify and generate from arbitrary messages.
[Open chat code](../README.md#open-chat-with-directive-missions).

## A complete deterministic agent with native OTP callbacks

Start with Agent and Server. This example has no installed capabilities, so it omits both `stack:` and `tools:`. For a runnable example with a custom tool, follow [the invoice client](CUSTOM_STACK_TOOLS.md). To trace a route and its result tag, try [the mail walkthrough](HANDLER_WALKTHROUGH.md).

```elixir
defmodule Demo.SupportServer do
  use Spectre.Server

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
  use Spectre.Agent, server: Demo.SupportServer
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

The executable [outreach integration](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md)
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

Read the integration's `support/configuration.ex`, registered adapters and tests
for operation configuration, consent, ambiguity and recovery. AgentServer
automatically creates the Domain, Scope, ingress and execution protocol; no
application Host is required. The external providers are deterministic fixtures,
not validation of live transport credentials.

The integration also runs the workflow in a dedicated Skill Server with the
same GAM Domain and authority ledger as the root. It verifies the email/save
Acts and Skill invocation Evidence through the root consumer. Each child keeps
its own state, pending intentions and checkpoint; mount restrictions and exact
presentation correlation isolate permissions and consent. The [LiveView demo](DEMO.md)
adds two concurrent Skills so these boundaries can be exercised interactively.

## Two agents with external human consent

Run `mix run docs/examples/external_approval.exs` from the core checkout. It
starts separate customer and owner AgentServers with independent GAM Domains,
exchanges protocol maps using a small mailbox adapter, and verifies confirm,
reject and replay rejection. Human interaction and the browser are simulated.
Pulse is optional; see [External approval](EXTERNAL_APPROVALS.md).

## Further recipes and compatibility

- [Actions](ACTIONS.md): deterministic and model-produced proposals.
- [Pending lifecycle](PENDING_LIFECYCLE.md): application policy, durable timers and OTP timer ownership.
- [Routing](ROUTING.md): native custom adapters and route-only evaluation.
- [Stack tools](STACK_TOOLS.md): generated helpers and installation contracts.
- [0.3 examples](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/EXAMPLES_0_3.md): retained Instance/Turn/Effect compositions, not new Server scaffolding.
