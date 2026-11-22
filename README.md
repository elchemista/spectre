# Spectre

Spectre is an Elixir framework for building agents that understand messages,
use models and tools, and carry out work in supervised OTP processes. You choose
the recognition strategies, model providers and capabilities your application needs.

**Upgrading from 0.3?** Spectre 0.4 introduces substantial changes to agent
definitions, conversation ownership and tool execution. Follow the
[0.3 → 0.4 migration guide](docs/MIGRATING_TO_0_4.md) before upgrading an existing
application.

Spectre 0.4.1 adds supervised background Activities and a Stack integration API.
An agent can keep chatting while a mission runs. The host can inspect or revise
that mission by its execution reference, and its governed operations use the
same GAM Domain. [Run a background Activity](docs/AGENT_SERVER.md#run-a-background-activity).
For persisted sessions, see [upgrading a durable AgentServer](docs/INSTALLATION.md#upgrading-a-durable-agentserver).

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

- **Stack** installs models, tools, reusable flows and Activity types. Omit the
  Stack when the Agent only uses application callbacks or a directly configured
  model.
- **Agent** declares which routes the router can choose and which Stack flows
  are visible. A route names the handler that will receive the message.
- **Server** owns the conversation. Callbacks return a Context with state
  changes and commands. Workers run model and tool calls. An Activity gets a
  supervised process on demand and uses the Root's GAM Domain.

## Install

Requires Elixir `~> 1.19`.

```elixir
{:spectre, "~> 0.4.1"}
```

Run `mix deps.get` and commit `mix.lock`. [Installation](docs/INSTALLATION.md)
covers optional packages, source dependencies and supervision.

## Build a deterministic agent

This Agent recognizes pricing questions using local rules. The Server replies
with application text. No model configuration is needed.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, server: MyApp.SupportServer
  router strategies: [:regex, :bag, :jaro]

  flow :support do
    on(:pricing,
      regex: ~r/\b(price|pricing|cost)\b/i,
      bag: ["subscription plans"],
      jaro: ["monthly subscription"]
    )
  end
end

defmodule MyApp.SupportServer do
  use Spectre.Server

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

`:support` is the flow and `:pricing` is the route inside it. Together they
form the key in `handle_flow/3`. The router tries a pattern or compares the
message against the `bag:` and `jaro:` examples. An unrecognized message
reaches `:unmatched`. The second callback argument is a normalized
`%Spectre.Input{}`. This handler ignores it because the response is fixed.
The third is the current Context. Return it through `respond/2`.

`server:` binds the Agent to its callback module. At startup `agent:` chooses
the Agent and `consumer: self()` sends events to this caller. `input/2`
acknowledges intake with an interaction ID. Match that ID in the asynchronous
`:response` event. `text` is the reply and `_metadata` is its optional
response metadata. The five-second receive timeout belongs to the caller.
The same example is available with `mix run docs/examples/agent_server_quickstart.exs`.

In an application, supervise the Server or use `Spectre.summon/1`
for per-subject ownership. [Getting started](docs/GETTING_STARTED.md).

## Open chat with Directive missions

Give the Agent a chat route and a mission route. An LLM classifier can recognize
“Compare these markets and prepare a report” without a trigger word. Ordinary
chat, including an unmatched message, generates a reply in the Root. A mission
runs independently while the Root continues accepting chat.

With `[:llm_classifier]`, an ordinary chat turn can call the model once for
classification and again for the reply. Add a local recognition strategy
when explicit patterns or reviewed examples can settle some routes.

This example requires Spectre 0.4.1, Directive 0.2.0 and a host model adapter
`MyApp.TextModel` implementing `Spectre.LLM.complete(prompt, options)`. A model
can return `{:ok, text}` or `{:error, reason}`. Here one adapter is used for
classification, replies and mission reasoning. You can configure separate
adapters. [Model contracts and configuration](docs/PROVIDERS.md).

```elixir
defmodule MyApp.Workspace do
  use Spectre.Stack
  install Spectre.Directive
end

defmodule MyApp.Assistant do
  use Spectre.Agent, stack: MyApp.Workspace, server: MyApp.AssistantServer

  model MyApp.TextModel
  classifier :llm, MyApp.TextModel
  router strategies: [:llm_classifier]

  flow :assistant do
    on :chat, semantic_examples: ["How are you?", "Remind me what we discussed"]
    on :mission, semantic_examples: ["Compare these markets and prepare a report"]
  end
end

defmodule MyApp.AssistantServer do
  use Spectre.Server, prompt_root: "priv/prompts"

  def handle_flow({:assistant, :mission}, input, ctx) do
    start_activity(ctx, {:directive, :mission}, %{
      goal: input.text,
      context: %{recent_turns: Map.get(ctx.assigns, :turns, [])}
    })
  end

  def handle_flow({:assistant, :chat}, _input, ctx), do: chat(ctx)
  def handle_flow(:unmatched, _input, ctx), do: chat(ctx)

  def handle_result(:chat_reply, {:generated, %{text: text}}, ctx) do
    turns = Map.get(ctx.assigns, :turns, []) ++ [%{user: ctx.input.text, assistant: text}]
    ctx |> assign(:turns, Enum.take(turns, -6)) |> respond(text)
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  defp chat(ctx) do
    generate(ctx, :chat,
      assigns: %{recent_turns: Map.get(ctx.assigns, :turns, [])},
      on_result: :chat_reply
    )
  end
end
```

Add `priv/prompts/chat.text.heex` to the app.

```text
Answer the latest message in the user's language. Use earlier turns as context.
Earlier turns:
<%= Spectre.Prompt.data(Spectre.JSON.encode!(@recent_turns)) %>
Latest message:
<%= Spectre.Prompt.data(@input.text) %>
```

- `stack:` selects the installed packages. `{:directive, :mission}` names
  Directive's installation and its Activity type. Installing the package
  registers the type. `start_activity/3` creates each execution.
- `goal` is the user's request. `context` carries application data available
  to the mission. This example supplies six recent chat turns and uses the
  built-in Directive mission prompt. Include only the context the model needs.
- `semantic_examples:` describe the intent to the classifier. To use them for
  vector similarity as well, configure an embedder and enable `:embedding`.
  A classified label selects a declared handler. Permissions come from the host.
- `prompt_root:` locates the Root's prompts. `:chat` resolves the prompt shown
  above. A custom Activity can set its own prompt root and otherwise uses
  the Agent's configured root. `assigns:` adds template data for this
  command. `on_result: :chat_reply`
  sends the generation result to the matching callback clause. The tag is an
  application name. It differs from the `:chat` route and prompt name.
- The result handler records the generated text beside the input, keeps the
  six most recent chat turns and replies. `super/3` delegates the other results
  to Spectre, including the default failure reply. `Spectre.Prompt.data/1`
  marks user content and history as data within the prompt.

Call `Spectre.Server.input/2` on the same Root for chat and new missions.
The consumer receives `{:activity, identity, :started}` inside
`{Spectre.Server, root, event}`. `identity.ref` identifies this execution.
Use `Spectre.Server.activities(root)` to list work. Target a reference with
`Spectre.Server.signal_activity(root, ref, {:revise, notes})` or
`Spectre.Server.cancel_activity(root, ref)`. Here `notes` is the new instruction.
Wait for lifecycle events to show completion, failure or cancellation.
For a message such as “Focus only on Italy,” have the UI or application choose
the target execution and send a revision to that ref. When several missions
could match, ask the user which one. In the example, the `:mission` route
starts new work and the chat routes keep the conversation going.
[Activity lifecycle, options and replies](docs/AGENT_SERVER.md#run-a-background-activity).

This mission example reasons and asks questions. To give it an installed tool,
pass a map such as `tools: %{"read_document" => {:documents, :read}}` in the
mission arguments. `"read_document"` is the alias visible to the model.
`{:documents, :read}` is the Stack binding chosen by the application. A governed
tool goes through GAM. Use `scope:` on the start command to narrow access further.
Directive consumes structured mission decisions using these aliases. Kinetic is
an optional integration for interpreting Action Language and preparing proposals.
[Runnable examples and Directive](docs/EXAMPLES.md).

## Routing strategies

The Agent's router can combine several ways to recognize an intent. Choose the
strategies that suit your application:

| Strategy | Recognizes input using | Requires |
| --- | --- | --- |
| `:regex` | Explicit text patterns. | Route `regex:` patterns. |
| `:bag` | Character similarity to example phrases. | Route `bag:` examples. |
| `:jaro` | Spelling similarity to example phrases. | Route `jaro:` examples. |
| `:intent_dataset` | Reviewed exact examples and optional vector search. | Intent examples; an embedder for vector lookup. |
| `:embedding` | Meaning similarity to route examples. | An embedding adapter and `semantic_examples:`. |
| `:local_classifier` | A local intent classifier's prediction. | A configured local classifier. |
| `:llm_classifier` | A language model's choice among declared intents. | A configured intent model. |

Combine deterministic routes with embedding and LLM fallback. Supply your
embedding adapter and classifier model in the Agent.

```elixir
# Inside an Agent with regex and semantic_examples on its routes.
embedding MyApp.Embeddings
classifier :llm, MyApp.IntentModel

router strategies: [:regex, :embedding, :llm_classifier]
```

Regex recognizes explicit shortcuts. Embeddings compare vector similarity
against route examples. Strong local evidence can select a route before the
classifier is needed. [Router options and fallbacks](docs/ROUTING.md).

## Extend Spectre with your own library

For an existing document client, declare the integration once in the package.
The client in this example is your application's `MyApp.DocumentClient`.

```elixir
defmodule MyApp.Documents do
  use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

  @impl true
  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:read, __MODULE__, args: [id: :string])
  end

  def prepare(:read, %{id: id}, _binding) when is_binary(id), do: {:ok, id}
  def prepare(:read, %{"id" => id}, binding), do: prepare(:read, %{id: id}, binding)
  def prepare(:read, _payload, _binding), do: {:error, :invalid_document_id}
  def invoke(:read, id, _environment), do: MyApp.DocumentClient.fetch(id)
  def project(:read, result), do: {:ok, result}
end
```

The package ID is the default local name. `version:` identifies the library
release in the installable manifest. `install MyApp.Documents` adds it to the
Stack. `integration/1` receives the compiled installation configuration.
`:read` names the operation, `__MODULE__` supplies its adapter and `args:`
describes the public argument schema. `prepare/3` validates and normalizes the
actual request. A worker calls `invoke/3` with the normalized value and
`project/2` returns the portable value delivered to the continuation.
`MyApp.DocumentClient.fetch/1` accepts the normalized document ID and returns
`{:ok, document}` or `{:error, reason}`. The projection preserves that tuple.
The binding and environment arguments carry runtime context for adapters that
use named resources or need the authenticated subject.

From a Server callback, call
`call_tool(ctx, {:documents, :read}, %{id: "D12"}, on_result: :loaded)`.
In `handle_result(:loaded, result, ctx)`, `result` is the value projected by
the adapter. A local helper such as `kinetic/3` is available when the package
declares it and the Server uses `tools: MyApp.Stack`. Both paths use the same
resolved operation binding.

The same `integration/1` can register `service/4` for a behaviour, `flow/3`
for routes an Agent may expose, and `activity/4` for on-demand background
work. For a consequential operation, `governed:` connects the tool to a
registered GAM effect and the application sets its policy.
[Complete invoice-client example](docs/CUSTOM_STACK_TOOLS.md).
[Package contracts and options](docs/STACK.md#typed-package-integrations).

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
shows those calls. [The website-to-email example](docs/EXAMPLES.md#browse-remember-prepare-email-and-ask-permission-to-save)
connects website inspection, drafting, refusal and failure handling.

## Guides

| Goal | Start here |
| --- | --- |
| Add your own tool or cloud API | [Stack and invoice SDK walkthrough](docs/CUSTOM_STACK_TOOLS.md) |
| Follow input, approval and result end to end | [Step-by-step walkthrough](docs/HANDLER_WALKTHROUGH.md), [Callback order and return types](docs/SERVER_CALLBACKS.md) |
| Build and run an agent | [Getting started](docs/GETTING_STARTED.md) |
| Choose recognition strategies | [Routing](docs/ROUTING.md), [Training](docs/TRAINING.md) |
| Implement custom adapters and behaviours | [Behaviours and adapters](docs/BEHAVIOURS.md) |
| Understand processes, Context and continuations | [Architecture](docs/ARCHITECTURE.md), [Server](docs/AGENT_SERVER.md) |
| Add models, browser, memory and other packages | [Stack tools](docs/STACK_TOOLS.md) |
| Require local or external human consent | [Managed GAM](docs/MANAGED_GAM.md), [external approval](docs/EXTERNAL_APPROVALS.md) |
| Configure persistence and content storage | [Domain storage](docs/DOMAIN_STORAGE.md), [payload storage](docs/PAYLOAD_STORAGE.md) |
| Run parallel reusable capabilities | [Skills](docs/SKILLS.md) |
| Run a complete website-to-email workflow | [Examples](docs/EXAMPLES.md), [LiveView demo](docs/DEMO.md) |
| Generate an agent or package, inspect routes or run Doctor | [Mix tasks](docs/START_HERE.md#mix-tasks) |
| Deploy, test or migrate | [Production](docs/PRODUCTION.md), [Testing](docs/TESTING.md), [Migration](docs/MIGRATING_TO_0_4.md) |

The [documentation index](docs/START_HERE.md) links the full 0.4 reference.
Earlier Instance/Run APIs remain supported through the
[compatibility reference](docs/COMPATIBILITY.md).

[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md) ·
[Application authoring reference](LLMS.md)
