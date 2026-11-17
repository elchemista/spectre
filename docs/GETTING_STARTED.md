# Getting started

Start with a deterministic conversation, then add the capabilities your application
needs. The [README example](../README.md#build-an-agent) shows regex, semantic
matching and model classification;
[Installation](INSTALLATION.md) covers dependencies and supervision.

## Generate the Agent and Server

Inside your application:

```sh
mix spectre.gen.agent MyApp.SupportAgent --server
mix test test/my_app/support_agent_test.exs
```

The generator creates a declarative Agent, a Server callback module and a runtime
test. It does not overwrite existing files unless you pass `--force`; `--dry-run`
prints the plan first.

The Agent recognizes `hello`; the Server handles the declared route and unmatched
input. Add recognition rules in the Agent and behavior in `handle_flow/3`.
The Server callback module runs inside `Spectre.Server.Runtime`, which owns the
GenServer, workers and conversation.

## Start a conversation and receive replies

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: "customer-42",
  identity: %{subject: "customer-42"},
  consumer: self()
)

{:ok, interaction} = Spectre.Server.input(server, "hello")

receive do
  {Spectre.Server, ^server, {:response, ^interaction, text, _metadata}} ->
    IO.puts(text)
after
  5_000 -> raise "No response from the agent"
end
```

Your transport supplies the authenticated subject and owns the consumer process.
A subject ID identifies the local conversation owner; it is not authentication.
For a fixed supervised owner, use the `Spectre.Server` child specification shown
in [Installation](INSTALLATION.md#otp-supervision).

From this repository, the complete model-free smoke check is:

```sh
mix run docs/examples/agent_server_quickstart.exs
```

## Keep application state in the Context

`ctx.assigns` holds portable application data; `ctx.private` holds process-local
references and is not checkpointed. Initialize restored assigns without replacing
them. Identity, routing and pending fields are runtime views.

Conversation callbacks return an updated Context. Native `handle_call`,
`handle_cast` and `handle_info` keep their ordinary OTP return tuples, with the
Context as state. [Server](AGENT_SERVER.md) describes every callback.

## Choose how the Agent recognizes input

`router strategies: [...]` selects recognition sources. The README combines
`:regex`, `:embedding` and `:llm_classifier` with application-owned adapters.
For a model-free start, choose `[:regex, :bag, :jaro]` as in the executable
quickstart. Add `:intent_dataset` for reviewed examples or `:local_classifier`
for a configured local classifier.

The [Routing guide](ROUTING.md) shows combined model and semantic recognition,
then covers each strategy and its requirements. To provide your own implementation, use the
[behaviour catalogue](BEHAVIOURS.md) and its adapter examples.

## Add a model or installed tool

Install packages in a `Spectre.Stack`, bind it to the Agent and select
`tools: MyApp.AI` in the Server. Packages supply generated helpers such as `lens`
and `kinetic`; adapters and credentials belong to the host's runtime resources.

A helper queues a command and names its continuation:

```elixir
# Requires a configured model and the :answer prompt asset.
def handle_flow({:support, :question}, input, ctx),
  do: generate(ctx, :answer, input: input, on_result: :answered)

def handle_result(:answered, {:generated, response}, ctx),
  do: respond(ctx, response.text)

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

Recognition can combine regex, reviewed intent examples, embeddings, local
classifiers and LLM classification. Configure only the adapters you use; the
response model and classifier can differ. See [Routing](ROUTING.md),
[Training](TRAINING.md) and [Stack tools](STACK_TOOLS.md).

## Add an operation that needs consent

Register the effect, allow its operation in the root `gam:` configuration and
return `propose(ctx, operation, arguments, on_result: tag)`. The consumer renders
the exact Presentation, acknowledges rendering, then submits the human's separate
choice. GAM verifies consent and authority before releasing execution.

[Managed GAM](MANAGED_GAM.md) explains this setup. To ask a human using a different
agent, follow [External approval](EXTERNAL_APPROVALS.md); Pulse is optional.

## Continue with a complete workflow

The [outreach source](https://github.com/elchemista/spectre/blob/0.4.0/docs/examples/outreach_agent.exs)
shows website inspection, contact extraction, model drafting, typed Kinetic
proposals and email confirmation. It requires the named application adapters;
[the executable Stack integration](https://github.com/elchemista/spectre_ecosystem/tree/main/integration/stack_tools)
supplies deterministic providers and tests the full loop. The
[LiveView demo](DEMO.md) adds a browser UI, two Skill servers and PostgreSQL.

Use [Domain storage](DOMAIN_STORAGE.md) when history must survive restarts,
[payload storage](PAYLOAD_STORAGE.md) for application-owned content and
[Production](PRODUCTION.md) before deploying.
