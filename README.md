# Spectre

Spectre is an Elixir framework for building agents that understand messages,
use models and tools, and carry out work in supervised OTP processes. You choose
the recognition strategies, model providers and capabilities your application needs.

**Upgrading from 0.3?** Spectre 0.4 introduces substantial changes to agent
definitions, conversation ownership and tool execution. Follow the
[0.3 → 0.4 migration guide](docs/MIGRATING_TO_0_4.md) before upgrading an existing
application.

## What is GAM?

**GAM stands for Governed Act Model.** It defines how an agent's proposal becomes
an authorized operation. Your application declares which operations are governed,
who may authorize them and when human consent is required. Spectre checks that
authority and records the decision before allowing execution, then tracks the
observed result separately.

For example, an agent can prepare an email, but sending it must pass through the
application's configured permissions and consent checks. Approval applies to the
specific operation shown to the person, including its recipient and content.

Read the [GAM manifesto](https://spectre.guide/en/governed-act-model) for the model's
principles and [GAM in Spectre](docs/GAM.md) for their implementation.

## Stack → Agent → Server

![Spectre: From conversation to governed work](docs/assets/readme-architecture.svg)

[Diagram source](docs/assets/readme-architecture.mmd).

- **Stack** installs the capabilities available to the application: models,
  browser access, memory and other tools.
- **Agent** declares the router, flows and intents that recognize input and
  select a route.
- **Server** implements the callbacks for those routes and manages the
  conversation's state, pending work and results inside an OTP process.

The Server can ask workers to generate a response or use a tool. Operations on
the application's governed surface go through GAM before their effect adapter
can execute them.

## Install

Requires Elixir `~> 1.19`.

```elixir
{:spectre, "~> 0.4.0"}
```

Run `mix deps.get` and commit `mix.lock`. [Installation](docs/INSTALLATION.md)
covers optional packages, source dependencies and supervision.

## A minimal agent

The code follows the diagram: first the Stack, then the Agent's router, then the
Server's callbacks. This example uses regex routing and needs no model, database
or external service:

```elixir
# 1. Stack: the application's capabilities; no packages are needed here.
defmodule MyApp.AI do
  use Spectre.Stack
end

# 2. Agent: recognize a pricing question and select the support/pricing route.
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer
  router(strategies: [:regex])

  flow :support do
    on(:pricing, regex: ~r/\b(price|pricing|cost)\b/i)
  end
end

# 3. Server: handle the route selected by the Agent.
defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx),
    do: respond(ctx, "Plans start at EUR 20 per month.")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Ask me about pricing.")
end

{:ok, server} = Spectre.Server.start_link(agent: MyApp.SupportAgent, consumer: self())
{:ok, interaction} = Spectre.Server.input(server, "What is the price?")

receive do
  {Spectre.Server, ^server, {:response, ^interaction, text, _metadata}} ->
    IO.puts(text)
after
  5_000 -> raise "No response from the agent"
end
```

The Agent recognizes the pricing question; the Server's
`handle_flow({:support, :pricing}, ...)` replies with the price. `input/3` returns
an interaction ID; replies arrive asynchronously at the consumer.

In an application, supervise the Server or use `Spectre.summon/1`
for per-subject ownership. [Getting started](docs/GETTING_STARTED.md) covers
these next steps and the generator.

## Satellite libraries

All nine libraries are optional. Install only the capabilities your Stack needs.

| Library | Purpose |
| --- | --- |
| [spectre_beam](https://github.com/elchemista/spectre_beam) | Receive and deliver messages through external channels. |
| [spectre_directive](https://github.com/elchemista/spectre_directive) | Manage resumable missions, plans and their next steps. |
| [spectre_kinetic](https://github.com/elchemista/spectre_kinetic) | Turn model output into validated action proposals. |
| [spectre_lab](https://github.com/elchemista/spectre_lab) | Inspect agents and checkpoints; test and compare recorded runs. |
| [spectre_ledger](https://github.com/elchemista/spectre_ledger) | Persist Server state and GAM history, with file and PostgreSQL storage. |
| [spectre_lens](https://github.com/elchemista/spectre_lens) | Browse websites, inspect pages and perform browser actions. |
| [spectre_mnemonic](https://github.com/elchemista/spectre_mnemonic) | Store, search and recall agent memory. |
| [spectre_prism](https://github.com/elchemista/spectre_prism) | Select models for generation, classification and embeddings. |
| [spectre_pulse](https://github.com/elchemista/spectre_pulse) | Exchange authenticated messages between agents across transports. |

Related tools: [spectre_ecosystem](https://github.com/elchemista/spectre_ecosystem)
runs compatibility checks across packages;
[spectre_studio](https://github.com/elchemista/spectre_studio) provides a LiveView
control panel for the retained Instance runtime.

## From conversation to governed work

Server helpers return commands in the Context. `on_result:` names the callback
continuation. Models, classifiers and tools run in workers; native OTP callbacks
remain available in the same conversation owner.

Configure permitted effects through `gam: [operations: ...]`. Confirmation,
when required, binds the human's decision to the exact presented operation.
Installing a tool or receiving a model proposal does not grant authority.
Mounted Skill servers have independent state and workers while sharing their
root AgentServer's GAM Domain and the mount's restrictions.

RAM-only operation is supported. Ledger can persist canonical GAM history,
Server coordination and the Domain's historical projection in the application's
PostgreSQL database. Application payload callbacks choose where content is stored
and how it is protected.

`Spectre.Server.reset(server)` starts a fresh session, including mounted Skills,
while keeping the root PID. Use `storage: :ephemeral` to explicitly reset into RAM.
See [Server lifecycle](docs/AGENT_SERVER.md#resetting-an-agent-session) and
[custom storage](docs/DOMAIN_STORAGE.md) for reset semantics and the single
`Spectre.Server.Store` behaviour.

## Example: ask before sending an email

After registering the email effect, configure the operation on the root:

```elixir
# Options for Spectre.Server.start_link/1; the application authenticates the user.
identity: %{subject: user.id},
consumer: chat_process,
gam: [operations: %{{:kinetic, :send_email} => [confirm: true]}]
```

The business callback proposes the concrete draft instead of sending it directly:

```elixir
def handle_flow({:mail, :send}, _input, ctx) do
  propose(ctx, {:kinetic, :send_email},
    %{"to" => ctx.assigns.recipient, "body" => ctx.assigns.draft},
    on_result: :sent)
end

def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
  do: respond(ctx, "The mail service confirmed the send operation.")
```

These are application fragments: the effect registration, draft preparation and
chat consumer are supplied by the host. The consumer displays the exact draft,
acknowledges rendering and submits the human's separate confirm/reject decision.
GAM checks that decision before execution. [Managed GAM](docs/MANAGED_GAM.md)
shows those calls; [the full outreach source](https://github.com/elchemista/spectre/blob/main/docs/examples/outreach_agent.exs)
connects website inspection, drafting, refusal and failure handling.

## Guides

| Goal | Start here |
| --- | --- |
| Build and run an agent | [Getting started](docs/GETTING_STARTED.md) |
| Understand processes, Context and continuations | [Architecture](docs/ARCHITECTURE.md), [Server](docs/AGENT_SERVER.md) |
| Add models, browser, memory and other packages | [Stack tools](docs/STACK_TOOLS.md) |
| Require local or external human consent | [Managed GAM](docs/MANAGED_GAM.md), [external approval](docs/EXTERNAL_APPROVALS.md) |
| Configure persistence and content storage | [Domain storage](docs/DOMAIN_STORAGE.md), [payload storage](docs/PAYLOAD_STORAGE.md) |
| Run parallel reusable capabilities | [Skills](docs/SKILLS.md) |
| Run a complete website-to-email workflow | [Examples](docs/EXAMPLES.md), [LiveView demo](docs/DEMO.md) |
| Deploy, test or migrate | [Production](docs/PRODUCTION.md), [Testing](docs/TESTING.md), [Migration](docs/MIGRATING_TO_0_4.md) |

The [documentation index](docs/START_HERE.md) links the full 0.4 reference.
Earlier Instance/Run APIs remain supported through the
[compatibility reference](docs/COMPATIBILITY.md).

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md) ·
[Application authoring reference](LLMS.md)
