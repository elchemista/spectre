# Getting started with AgentServer

Build three small modules: a Stack for capabilities, an Agent for recognition,
and a Server for behaviour. This tutorial targets the unreleased 0.4 branch;
follow [Installation](INSTALLATION.md) first. The retained
[0.3 tutorial](GETTING_STARTED_0_3.md) uses a different runtime.

## 1. Run an agent without external services

Save this as `quickstart.exs` in your Mix application:

```elixir
defmodule Quickstart.AI do
  use Spectre.Stack
end

defmodule Quickstart.SupportServer do
  use Spectre.Server, tools: Quickstart.AI

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx) do
    respond(ctx, "Plans start at EUR 20 per month.")
  end

  def handle_flow(:unmatched, _input, ctx) do
    respond(ctx, "Ask me about pricing.")
  end
end

defmodule Quickstart.SupportAgent do
  use Spectre.Agent, stack: Quickstart.AI, server: Quickstart.SupportServer

  router strategies: [:regex]

  flow :support do
    on :pricing, regex: ~r/\b(price|pricing|cost)\b/i
  end
end

{:ok, server} = Spectre.Server.start_link(agent: Quickstart.SupportAgent, consumer: self())
{:ok, interaction} = Spectre.Server.input(server, "What is the price?")

receive do
  {Spectre.Server, ^server, {:response, ^interaction, text, _metadata}} ->
    IO.puts(text)
after
  5_000 -> raise "No response from the agent"
end

GenServer.stop(server)
```

Run `mix run quickstart.exs`. It prints `Plans start at EUR 20 per month.`
The [checked executable copy](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/examples/agent_server_quickstart.exs) can also be
run from the core repository. The callback returns a context carrying a response
command; the runtime owns execution and emits the correlated consumer event.

## 2. Separate declarations from behaviour

Add recognition strategies to the Agent only when their adapters and data are
configured:

```elixir
# Inside an Agent; these modules are supplied by your application.
classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/spectre/intents"
classifier :llm, MyApp.IntentModel, timeout: 8_000

router strategies: [:regex, :intent_dataset, :embedding,
                    :local_classifier, :llm_classifier]

flow :support, defaults: [collect_intent: true] do
  on :pricing, semantic_examples: ["How much does it cost?"]
  on :delete_account, regex: ~r/^delete my account$/i,
    collect_intent: false, protected: true
end
```

This is a configuration fragment, not another runnable no-dependency example.
The classifier can use a different model from response generation. IntentDataset
stores useful labelled text examples; embeddings are required for vector lookup,
not for every training example. `collect_intent` collects examples and does not
train a classifier immediately. [Routing](ROUTING.md) and [Training](TRAINING.md)
explain adapter configuration, dataset lookup, thresholds and protected routes.

## 3. Generate a response and handle the result

With a generation service/model connected and a `pricing` prompt under the
configured `prompt_root`, change the Server callbacks to:

```elixir
# Inside a Server using prompt_root: "priv/support/prompts"
def handle_flow({:support, :pricing}, _input, ctx) do
  generate(ctx, :pricing, on_result: :pricing)
end

def handle_flow(:unmatched, _input, ctx) do
  case ctx.routing.reason do
    :ambiguous -> respond(ctx, "Do you mean pricing or account deletion?")
    :no_match -> generate(ctx, :understand, on_result: :understood)
    _ -> respond(ctx, "Recognition is unavailable. Please try again.")
  end
end

def handle_result(tag, {:generated, response}, ctx)
    when tag in [:pricing, :understood] do
  respond(ctx, response.text)
end

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

`understand` here is your prompt name, not a hidden framework function. Use
`classify(ctx, input, on_result: tag)` when you want a classification command;
its callback receives `{:classified, label}` on success. A label is recognition
evidence, never consent. Choose explicitly what your callback does with it.

`ctx` contains identity, the current input/routing view, portable `assigns`,
pending intentions and volatile `private` state. It is not an initialized
Kinetic struct or a container for credentials and live clients. Use generated
helpers to resolve installed tools through the runtime.

## 4. Interpret model output with an installed tool

Install Kinetic in your Stack with your action catalog, then use
`use Spectre.Server, tools: MyApp.AI`. Inside that Server:

```elixir
def handle_result(:drafted, {:generated, response}, ctx) do
  kinetic(ctx, response, on_result: :prepared)
end

def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
  propose(ctx, proposal.operation, proposal.args,
    proposal_metadata: proposal.metadata, on_result: :sent)
end

def handle_result(:prepared, {:prepared, %{text: text, actions: []}}, ctx) do
  respond(ctx, text)
end
```

This fragment deliberately handles a single-action workflow. Handle multiple
proposals explicitly or use the documented planner path; do not silently drop
the tail. `generate(..., planning: true)` is the alternative automatic planner
path, so do not interpret the same response a second time. The model produces
AL; `kinetic` prepares proposals; GAM admits consequences; an executor performs
them. Partial streamed tokens are never dispatched as actions.

See [Actions](ACTIONS.md) and [Stack tools](STACK_TOOLS.md) for complete setup,
result handling, bound memory writes and other helpers.

## 5. Add governed consequences and consent

For a deterministic route the proposal is equally explicit:

```elixir
def handle_flow({:support, :delete_account}, _input, ctx) do
  propose(ctx, :delete_account, %{account_id: ctx.identity.account_id},
    on_result: :deleted)
end

def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx) do
  respond(ctx, "Account deleted.")
end

def handle_result(:deleted, {:governed_unknown, _details}, ctx) do
  respond(ctx, "The deletion is still under verification.")
end
```

This requires authenticated host identity, a bound GAM operation, contracts,
mandate and executor. `protected: true` is not that configuration. Only report
success from a successful observed Outcome; a refusal is not a request to
invent another permission, and uncertainty is not permission to retry.

The host defines the consent presentation and interpretation functions. Your
Server can implement `handle_pending` to confirm/reject, ask for clarification,
or suspend an intention on a topic change. A closure timer records its lifecycle
through GAM; it does not erase a committed effect or an unresolved Duty. Read
[GAM](GAM.md) and [Pending lifecycle](PENDING_LIFECYCLE.md) before connecting an
external write.

## 6. Use OTP and durability

Native `handle_call/3`, `handle_cast/2` and `handle_info/2` are available. Their
state argument is the context and their return shape follows GenServer:

```elixir
@impl true
def handle_info({:price_version, version}, ctx) do
  {:noreply, assign(ctx, :price_version, version)}
end

def handle_info(message, ctx), do: super(message, ctx)
```

Framework task/timer messages are consumed before application callbacks.
Keep callbacks quick and use command workers for slow operations. Put transient
PIDs/timer handles in `private`, not durable `assigns`. Use durable pending
schedules when deadlines must survive restart. [Agent and Server](AGENT_SERVER.md)
covers stores, result envelopes, recovery and actor waits.

For a complete multi-tool loop, run the
[nine-package integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md). It uses real
package/GAM contracts with simulated external transports and explicitly tests
consent, topic changes, deadlines and recovery.
