# Spectre

Spectre is an Elixir framework for agents with declarative routing, an OTP
process for application behaviour, and governed execution of consequences.

**0.4.0 development branch:** this README describes the AgentServer architecture
on `feature/agent-server-gam`. It changes the authoring model from 0.3; it is not
an announcement of a published Hex release. Start with the
[0.3 → 0.4 migration guide](docs/MIGRATING_TO_0_4.md) for existing applications.

## Three application modules, one conversation owner

```text
Stack: installed capabilities, providers and resources
  ↓
Agent: classifiers, router, flows and intent examples
  ↓
Server: handle_flow / handle_result / handle_pending + OTP callbacks
  ├─ cognitive commands → workers → results
  └─ consequence proposals → GAM admission → Act → executor → Outcome
```

`Spectre.Stack` connects packages. `Spectre.Agent` declares what input means.
`Spectre.Server` supplies ordinary Elixir callbacks for what happens next.
`Spectre.Server.Runtime` is the GenServer that owns the conversation, pending
intentions, command outbox and recovery. Your Server callbacks execute inside
that owner; a second application GenServer is not required.

The **Governed Act Model (GAM)** kernel records authority and causality at the
host's declared governed boundary. A model can propose deleting an account;
the proposal is not permission and is not proof of deletion. Admission precedes
the recorded Act and capability release; observed Outcomes describe what
actually happened. Read the [GAM manifesto](https://spectre.guide/en/governed-act-model)
and [how Spectre integrates GAM](docs/GAM.md).

## Install this development line

Requires Elixir `~> 1.19`:

```elixir
{:spectre, github: "elchemista/spectre", branch: "feature/agent-server-gam"}
```

Run `mix deps.get`. Keep `mix.lock` under version control, or pin an exact
reviewed commit with `ref:`. Companion libraries use `feature/stack-tools-0.4`;
see [Installation](docs/INSTALLATION.md) for compatible dependency and runtime
setup. Published 0.3 documentation does not describe this branch's Server API.

## A complete small agent

This example uses no model, credentials or external service. Put it in an `.exs`
file in an application depending on Spectre and run it with `mix run`:

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

The same executable example is in
[agent_server_quickstart.exs](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/examples/agent_server_quickstart.exs).
Use [Getting started](docs/GETTING_STARTED.md) to add generation, fallbacks,
installed tools and governed effects.

## Capabilities retained from 0.3

- Regex, intent-dataset, embedding, local-classifier, LLM-classifier and custom
  routing strategies, with explicit unmatched/ambiguous handling.
- Separate classification and generation models, including custom adapters.
- Online collection of labelled examples with `collect_intent`, dataset lookup,
  training and evaluation. Text examples are useful without embeddings; vector
  search only indexes valid compatible embeddings.
- Streaming generation. Preview tokens are provisional; only consolidated
  output can become executable proposals.
- Installed Stack packages and their standalone APIs.

The change is ownership: routing stays declarative, application logic moves to
Server callbacks, and governed effects enter GAM. Consent and its lifetime are
pending state with correlation and recovery, not an unscoped match on “yes”.
Native `handle_call`, `handle_cast` and `handle_info` remain available. See
[Architecture](docs/ARCHITECTURE.md) and [Pending lifecycle](docs/PENDING_LIFECYCLE.md).

## Installed tools

`c:Spectre.Stack.Installable.tools/1` lets a package register operations.
`use Spectre.Server, tools: MyApp.AI` generates helpers from that Stack's
registered names. You do **not** import invented helper functions from each
package. The helper builds a command; the runtime resolves the installed
adapter/resource and applies its cognitive or governed contract.

| Package | Helper / role in the Server loop |
| --- | --- |
| [Kinetic](https://github.com/elchemista/spectre_kinetic/tree/feature/stack-tools-0.4) | `kinetic`: consolidate Action Language into proposals |
| [Mnemonic](https://github.com/elchemista/spectre_mnemonic/tree/feature/stack-tools-0.4) | `mnemonic`: recall; bind writes to governed operations |
| [Lens](https://github.com/elchemista/spectre_lens/tree/feature/stack-tools-0.4) | `lens`: browser observations and bound actions |
| [Prism](https://github.com/elchemista/spectre_prism/tree/feature/stack-tools-0.4) | `prism`: model selection and installed inference services |
| [Beam](https://github.com/elchemista/spectre_beam/tree/feature/stack-tools-0.4) | `beam`: endpoints and governed delivery |
| [Directive](https://github.com/elchemista/spectre_directive/tree/feature/stack-tools-0.4) | `directive`: portable task-state reduction |
| [Pulse](https://github.com/elchemista/spectre_pulse/tree/feature/stack-tools-0.4) | `pulse`: protocol/contacts and bound sends |
| [Ledger](https://github.com/elchemista/spectre_ledger/tree/feature/stack-tools-0.4) | `ledger`: current checkpoint metadata; durable store adapter |
| [Lab](https://github.com/elchemista/spectre_lab/tree/feature/stack-tools-0.4) | `lab`: checkpoint inspection and validation |

See [Stack tools](docs/STACK_TOOLS.md) for exact requests, results, bindings and
replay rules. The [nine-package integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md)
includes browsing, memory, model-generated AL, email, consent, topic changes,
timers and crash recovery. Its external transports are simulated; the package
adapters, persistence and GAM loop are real.

## Documentation

Start at [Start here](docs/START_HERE.md), then read
[Getting started](docs/GETTING_STARTED.md), [Agent and Server](docs/AGENT_SERVER.md),
[GAM](docs/GAM.md), [Routing](docs/ROUTING.md) and [Training](docs/TRAINING.md).
[Migration](docs/MIGRATING_TO_0_4.md) identifies breaking changes and compatibility
boundaries. [Changelog](CHANGELOG.md) records version history.

The old `Instance`/`Run` APIs remain in the repository for compatibility; using
them does not automatically migrate an application or its checkpoints to GAM.
The host still owns authentication, mandates, executors, credentials and actual
external-effect boundaries. Spectre is not a sandbox for arbitrary Elixir code.

Apache-2.0; see [LICENSE](LICENSE).
