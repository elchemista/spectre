# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)
[![Hex](https://img.shields.io/hexpm/v/spectre.svg)](https://hex.pm/packages/spectre)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/spectre)
[Website](https://spectre.guide)

**Build agents in Elixir. Keep their suggestions separate from permission to act.**

Write handlers, add routes and prompts when you need them, and connect your
own services. Spectre checks each governed request and records authorization
before the executor receives the capability to act.

It does not require an LLM. It does not choose your database, credentials,
transport or application policy.

> **Upgrading from 0.3?** Version 0.4 is a complete rewrite. The philosophy,
> public APIs, process layout, durable records and integration contracts have
> changed. Existing agents, checkpoints and satellite packages need review
> and migration; this is not a drop-in upgrade.

This checkout targets **0.4.0**. See
[what is available and what remains limited](docs/capabilities.md).

## Start with an agent, not kernel terminology

After adding Spectre to your application, generate a small working example:

```sh
mix spectre.gen.agent MyApp.Hello --dry-run
mix spectre.gen.agent MyApp.Hello
mix test test/my_app/hello_test.exs
mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings
```

You get an Agent, a separate Router, a prompt template and tests.
This first example prepares a local greeting. It needs no model or credentials,
and does not send anything.

For a first real save operation, the next step is
`mix spectre.gen.host MyApp.Hello --class greeting.save`.
That creates host/executor skeletons with an explicit setup checklist.
Follow [your first governed save](docs/host-setup.md#from-a-draft-to-your-first-governed-save)
to connect your application's actual permission and backend.

### Read a small order agent

This agent recognizes “order 42” and proposes a lookup:

<!-- spectre:example readme_agent -->
```elixir
defmodule MyApp.Orders do
  use Spectre.Agent, namespace: "shop", name: "orders"

  flow :orders do
    router via: [:regex]
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
  end

  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn({:orders, :no_match, _input}, _turn, state),
    do: {:error, :clarification_needed, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

definition = MyApp.Orders.definition(revision: 1, declared_at: published_at)
```

The important lines are:

- `flow :orders` names the interaction.
- `route :lookup` selects a handler branch and captures the order ID.
- `handle_turn` returns a request for `"orders.lookup"`, an application action
  class. It does not call the order service.
- `handle_result` stores the eventual status in local state.

`namespace` and `name` identify the declaration, not a tenant login.
`definition/1` constructs its published version; `published_at` is an
application-supplied Unix-millisecond timestamp. Activation is a later host step.

For the full explanation, continue with [building an agent](docs/agents-and-dsl.md).

## Prepare, then advance

After the host activates that Definition and opens an authenticated Scope:

<!-- spectre:example readme_instance -->
```elixir
{:ok, instance} = MyApp.Orders.start_link(
  scope: scope, definition: definition, bindings: class_bindings, state: %{}
)
{:ok, turn} = MyApp.Orders.turn(instance, "order 42", flow: :orders)
[request] = turn.requests
Spectre.Instance.advance(instance, request)
```

These are the values you supply:

| Value | Meaning |
| --- | --- |
| `scope` | The authenticated interaction in a Domain |
| `definition` | The agent version activated there |
| `class_bindings` | Connections to existing permission, executor and accountability records |
| `state` | Your local initial value |
| `flow: :orders` | The flow that should handle the input |

[Host setup](docs/host-setup.md) explains where they come from.

**`turn` prepares. `advance` submits the choice.**
Your application may advance immediately or ask someone first. Human approval
is only necessary where your rules require it.

An advance can return a completed Turn, a pending reference, or an error.
Even a completed Turn can contain a refusal: inspect `next_turn.result.status`.

Pending is not failure. Keep its reference and use `Instance.operation` to
observe it later; do not submit the effect again to find out what happened.

## Router, controller, prompt and model: who does what?

If you know Phoenix, “controller” here means your Agent's callbacks. You do
not need a separate controller module.

```text
input → optional pipeline/Router → handle_turn
                                    ├─ update local state
                                    ├─ request a business operation
                                    └─ prepare an ask using a prompt

chosen request → advance → kernel check → recorded authorization → executor
                                                                      ↓
                                         handle_result ← recorded observations
```

A model is an optional service, not a mandatory middle layer.

| Your input or task | Start with |
| --- | --- |
| A structured order-ID map | A handler with pattern matching |
| Text commands | Regex/string matching, then a handler |
| Generate an answer | A prompt and `ask` |
| Let a model choose a route | A governed `classify` request, then its confirmed labels |
| Reuse approved routing examples | `via: [:semantic_cache]` |
| Share behavior | A Skill |
| Share settings | A Stack |
| Run separate work or a watch | A Worker or Vigil, started and scheduled by the host |

[The recipes](docs/agent-recipes.md) show these combinations separately before
assembling a larger agent.

## How an agent uses a model, and how it answers

An `ask` selects local prompt templates and prepares a model request.
The integration's executor calls the provider after the request is admitted.

Here the answer handler prepares a second request to send the generated text:

<!-- spectre:example readme_assistant -->
```elixir
defmodule MyApp.Assistant do
  use Spectre.Agent, namespace: "shop", name: "assistant"

  # Supplied preparation adapter: it builds request data, it never calls a provider.
  adapter :request, :inference, Spectre.Agent.RequestBuilder

  flow :support do
    router via: [:regex]
    route :question, match: [regex: ~r/^(?<text>.+\?)$/u]
  end

  prompt :policy, "Answer the customer. Never claim an action has already run."
  prompt :question, "Customer asked: <%= @question %>"

  ask :answer,
    class: "model.generate",
    prompt: :policy,
    task: :question,
    via: :inference,
    model_ref: "support-writer"

  @impl true
  def handle_turn({:support, :question, %{"text" => text}}, _turn, state),
    do: {:ask, :answer, %{question: text}, state}

  def handle_turn({:support, _outcome, _input}, _turn, state),
    do: {:error, :question_required, state}

  # The model produced text. Putting it in front of a person is a second effect.
  @impl true
  def handle_result({:ask, :answer}, %{status: :done, data: %{"text" => draft}}, _turn, state),
    do: {:request, "chat.send", %{"text" => draft}, state}

  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end
```

Read this as two operations:

1. `model.generate`: use the templates and obtain a draft.
2. `chat.send`: deliver that draft.

Both classes and their execution contracts are supplied by the host.
The second request still needs its own `advance`; returning it does not send.

`via: :inference` names the preparation adapter.
`model_ref: "support-writer"` is an example identifier for your integration
to resolve—not a model Spectre downloads or selects automatically.

`result.data` follows your observed-result contract. This handler expects a
map containing `"text"`; other integrations can use a different shape.

Use a string for a small prompt, or compile an EEx file under `prompt_root`.
See [prompts and injection](docs/agents-and-dsl.md#prompts-and-injection).

### Work that outlives the conversation

Workers and Vigils reuse the handler style in separate supervised Instances.
Their openings record the promised work, time bounds and responsibility.
The host supplies scheduling and triggers.

Stopping a process does not fulfill its promise.
See [Skills, Workers and Vigils](docs/agent-recipes.md#reusable-skills-workers-and-vigils).

## The kernel, in one refund

Suppose an agent proposes a €50 refund.

The kernel checks whether the exact proposal is covered by the current
permission, supporting facts and resource budget. A good model answer or a
matching route is not enough.

If admitted, the Domain records the authorization before the external
execution boundary releases capability. The executor then reports what it
observed.

If the payment service times out, Spectre does not assume nothing happened
and repeat the refund. The resource may remain held, and the unresolved case
may need later Evidence and an authorized resolution.

These are the names used in the guides:

| Name | Plain meaning |
| --- | --- |
| Mandate | Permission with limits |
| Evidence | Information supporting or contradicting a claim |
| Act | The exact operation recorded as authorized |
| Duty | An obligation that still needs resolution |
| Surface | Your catalog of governed action classes |
| Row | The kinds of power an action uses, such as read or write |
| Meter | Accounting for a limited resource |
| Domain | Shared authority, accounting and ordered history |

You normally declare powers in host setup, not in handlers.
[The architecture guide](docs/architecture.md) walks through the lifecycle and
explains [Row](docs/architecture.md#what-is-a-row) with an order lookup.

## Philosophy

An agent can misunderstand a request, invent a fact or suggest the wrong
operation. Spectre does not make it infallible.

It keeps four distinctions intact:

- Evidence can inform a decision without granting permission.
- A working credential is not, by itself, authority.
- Recorded authorization is not proof that the operation succeeded.
- Silence or a timeout is not resolution of an obligation.

For consequences your application declares governed, the rules are: mediate
execution, keep delegated authority within its source, preserve causal history,
and require proper resolution of Duties.

Your host must actually close alternate effect paths. Arbitrary code in the
same BEAM is not sandboxed, and an unsigned ledger does not independently prove
every external assertion.

The [Governed Act Model](GOVERNED_ACT_MODEL.md) is the formal model.
[The governed surface](GOVERNED_SURFACE.md) explains exactly what this
implementation promises and what it trusts the host to provide.

## Install and connect it to your application

Requires Elixir 1.19 or later in the supported 1.x line.
CI targets Elixir 1.19 / OTP 28 and Elixir 1.20 / OTP 29.

Until 0.4.0 is published, use the development checkout:

<!-- spectre:example checkout_dependency -->
```elixir
{:spectre, path: "../spectre"}
```

For the handler API, configure the Domain with `mind: Spectre.Agent`.
A custom `Spectre.Mind` is a lower-level alternative, not another callback
required by every Agent.

Ledger adapters include ETS, Disk, Mnesia and PostgreSQL. ETS is volatile.
PostgreSQL uses your Repo; Spectre adds neither Ecto nor a driver.

The Vettore cache adapter is included, but its native dependency and encoder
are optional host choices. Cache lookup does not call an embedding provider.

Follow [host setup](docs/host-setup.md) for ordinary OTP supervision and
[storage](docs/storage-and-recovery.md) for the different store contracts.

## Spectre ecosystem

Optional packages provide models, memory, browsers and channels.
They depend on Spectre's contracts; Spectre does not depend on or discover them.

**Check each package's supported version.** A 0.3 integration is not
automatically compatible with 0.4. The following describes package roles, not
a claim that every current release is integration-tested against this checkout.

| Repository | Responsibility |
| --- | --- |
| [`spectre_prism`](https://github.com/elchemista/spectre_prism) | Choose a model that fits capability, privacy, cost and response-time requirements. |
| [`spectre_pulse`](https://github.com/elchemista/spectre_pulse) | Discover other agents, exchange messages and track delivery receipts. |
| [`spectre_mnemonic`](https://github.com/elchemista/spectre_mnemonic) | Save and retrieve longer-term memory while keeping its sources. |
| [`spectre_kinetic`](https://github.com/elchemista/spectre_kinetic) | Find tools and prepare action plans for validation. |
| [`spectre_lens`](https://github.com/elchemista/spectre_lens) | Read and interact with browsers through different backends. |
| [`spectre_beam`](https://github.com/elchemista/spectre_beam) | Adapt external messaging channels and handle duplicate delivery requests. |
| [`spectre_directive`](https://github.com/elchemista/spectre_directive) | Run an application-level loop that can revise and resume a plan. |
| [`spectre_lab`](https://github.com/elchemista/spectre_lab) | Replay checkpoint bundles offline and test them in isolation. |

These services do not grant authority or replace the Instance and Domain.
Your application still owns credentials, scheduling and the actual service
connections. In particular, long-term memory is not the authority ledger.

[`spectre_ecosystem`](https://github.com/elchemista/spectre_ecosystem) is
separate compatibility tooling, not a library or a runtime dependency. It
dispatches each repository's own test workflows and aggregates the results.

## Where to go next

You do not need to read everything in order.

| You want to… | Read |
| --- | --- |
| Write your first handler | [Build an agent](docs/agents-and-dsl.md) |
| Choose a no-model, model or classifier pattern | [Recipes](docs/agent-recipes.md) |
| Connect authority and real services | [Host setup](docs/host-setup.md) |
| Look up one option | [Configuration reference](docs/configuration.md) |
| Understand the kernel and process layout | [Architecture](docs/architecture.md) |
| Handle streams, UI progress and cancellation | [Input and control](docs/integration-and-streaming.md) |
| Store, recover or erase data | [Storage and recovery](docs/storage-and-recovery.md) |
| Check available features and limits | [Capabilities](docs/capabilities.md) |
| Test your agent or prepare a release | [Testing](docs/testing-and-release.md) |

The fenced Elixir examples have executable documentation tests. Wiring
fragments use explicit test-host fixtures; they are not permissive production
defaults. The [complete authoring example](docs/agent-recipes.md#a-complete-modular-authoring-example)
also ships in the package.

### Research and inspiration

The [Governed Holon Model](GOVERNED_HOLON_MODEL.md) explores cooperation and
responsibility across composed systems. It is research, not an implemented
0.4 feature or a release commitment.
