# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)

Build Elixir agents with ordinary modules, callbacks and OTP supervision.
An agent can route a message, retrieve context, ask a model and propose work.
**Proposing something and having permission to do it are separate steps.**

Spectre supplies two layers:

- **Agent authoring:** flows, routes, handlers, prompts, Skills and reusable Stack
  configuration. This is where you write what the agent should try to do.
- **Governed execution:** a kernel checks authority and supporting facts, records
  the admitted action, and only then lets an executor attempt it. This is where
  the application limits what the agent may actually do.

This checkout is **0.4.0, unreleased**, not a drop-in upgrade from 0.3.
It is a library, not a hosted agent service: you choose providers, credentials,
storage and application policy. Production load and long-lived memory
qualification are still open; see [current limits](docs/capabilities.md).

## Start with an agent, not kernel terminology

Want runnable files first? From your application:

```sh
mix spectre.gen.agent MyApp.Hello --dry-run
mix spectre.gen.agent MyApp.Hello
mix test test/my_app/hello_test.exs
mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings
```

This creates an Agent, separate Router, prompt template and tests. The Hello
World prepares a **local greeting**, with no LLM, credential or Domain setup.
It does not send a message or create an authorized effect. To use the same
handler in an OTP Instance, supply the host setup described below.
See [scaffolding and routing regression](docs/testing-and-release.md#scaffold-a-local-agent).

Here is an order assistant with no LLM and no Skill required:

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

Read it from top to bottom:

1. `namespace: "shop", name: "orders"` identifies the agent's published
   definition. Neither creates a tenant, an identity or a permission.
2. `flow :orders` groups the routing choices for one kind of interaction.
3. `router via: [:regex]` tries regular-expression matching.
4. `route :lookup` names a handler branch. `(?<id>...)` captures the order ID.
5. `handle_turn/3` asks to look up that order by returning plain data.
   `"orders.lookup"` is an application action class, **not a function call**.
6. `handle_result/4` updates local state after the governed result comes back.
   `result.status` distinguishes success, refusal, uncertainty and other outcomes.
7. `definition(revision: 1, declared_at: published_at)` builds an immutable
   description of this code and configuration. `published_at` is an explicit
   host-chosen timestamp in Unix milliseconds. This does not activate the agent.

There is intentionally no `row:` in a handler. The host declares what powers
an action involves once, in its Surface; the request builder reads that
declaration. See [what Row actually means](docs/architecture.md#what-is-a-row).

## Prepare, then advance

Once the host has activated that Definition and opened an authenticated Scope:

<!-- spectre:example readme_instance -->
```elixir
{:ok, instance} = MyApp.Orders.start_link(
  scope: scope, definition: definition, bindings: class_bindings, state: %{}
)
{:ok, turn} = MyApp.Orders.turn(instance, "order 42", flow: :orders)
[request] = turn.requests
Spectre.Instance.advance(instance, request)
```

Every startup argument has a different job:

| Argument | What you supply |
| --- | --- |
| `scope` | A live authenticated handle into a Domain, not a string or a permission you invent |
| `definition` | The exact published revision activated in that Domain |
| `bindings` | The action-class map connecting requests to the host's Mandate, executor and accountability records |
| `state` | Your own local state; here an empty map |
| `flow: :orders` | Which declared flow receives this input |

The variables are prerequisites, not hidden global configuration.
[Host setup](docs/host-setup.md) explains how to obtain them;
[the binding example](docs/host-setup.md#connect-a-handler-to-a-governed-action)
shows exactly what is inside `class_bindings`.

`turn` records authenticated input and prepares requests. It **does not execute
those requests**. `advance` submits the chosen request. Your application can
advance immediately, ask the user, or choose among alternatives. GAM does not
require a human click for every action.

The result of `advance` is `{:ok, next_turn}`, `{:pending, operation_ref}` or
`{:error, reason}`. An `{:ok, next_turn}` can contain a refusal: inspect
`next_turn.result.status`. Pending means “still in progress”, not “failed”.
[Handling results and pending work](docs/agents-and-dsl.md#handler-contract)
explains the complete contract and how to observe without resubmitting.

## Router, controller, prompt and model: who does what?

The useful analogy is **Router → Controller**, with optional prompts and models
chosen by the controller. The controller is your Agent's callbacks, not a
required `Spectre.Controller` module.

```text
input → optional pipeline → Router → handle_turn
                                      ├─ update local state
                                      ├─ prepare a business request
                                      └─ render a prompt and prepare a model request

chosen request → host advance → kernel → record Act → executor
                                                       ↓
                                      handle_result ← Outcome
                                            ↓
                                state or another prepared request
```

A model is not a compulsory middle layer. Common combinations are:

| You want | Use |
| --- | --- |
| Structured input, no routing | `handle_turn(input, turn, state)` directly |
| Commands without an LLM | Regex/string matching → handler → business request |
| A model-generated draft | Handler → prompt → governed `ask` → result handler |
| A model to choose a branch | Governed `classify` → confirmed labels → handler → separate business request |
| Reuse past routing examples | `via: [:semantic_cache]` → handler; the cache nominates, it does not execute |
| Different behavior for support and billing | Separate flows, each with its own pipeline and Router |
| Reusable logic | Skill in the same Instance, or a separately supervised Worker/Vigil |

See [worked combinations](docs/agent-recipes.md) for code and a complete modular
agent. [Prompt files and injection](docs/agents-and-dsl.md#prompts-and-injection)
use compiled EEx templates. [Configuration reference](docs/configuration.md)
explains names, defaults and options—including what is provider-specific
rather than interpreted by Spectre.

## The new kernel, in one example

Suppose the application allows refunds from a €100 budget for paid orders.

| GAM term | In this example |
| --- | --- |
| **Mandate** | The explicit permission: who can refund, which orders, for whom, until when and within which budget |
| **Evidence** | The observed payment receipt and other facts needed to decide |
| **Act** | The exact €50 refund recorded as authorized before contacting the payment service |
| **Duty** | The unresolved case if the payment may have happened but its receipt is missing |

The **Surface** is the application's catalog of governed actions and their
contracts. A **Row** summarizes which kinds of power an action uses.
A **Meter** accounts for a limited resource; copying an agent does not copy its
budget. A **Domain** owns the shared order of these facts.

The pure kernel asks “is this exact proposal authorized on these facts?”.
It neither calls an LLM nor writes the database. The Domain records an admitted
Act before the execution boundary releases the capability needed to attempt it.
The executor then reports what happened; that result does not rewrite what was
authorized.

If the payment request times out, Spectre does not automatically send it again.
A late receipt can reconcile the original attempt even after its Mandate was
revoked. A restart or a timer cannot silently close an unresolved Duty.

Read [the kernel explained](docs/architecture.md), then the
[Governed Act Model](GOVERNED_ACT_MODEL.md) for the full reasoning.
[GOVERNED_SURFACE.md](GOVERNED_SURFACE.md) documents implementation limits and
deployment assumptions: a hash chain is not a signature, and callbacks in the
same BEAM are not a security sandbox.

### Research and inspiration

The [Governed Holon Model](GOVERNED_HOLON_MODEL.md) explores how governed
identities could cooperate and retain responsibility across composed systems.
It is **research and architectural inspiration only**, not an implemented
0.4 capability, a runtime contract, or a release commitment. The current
implementation follows the Governed Act Model within the limits documented
in GOVERNED_SURFACE.md.

## Install and connect it to your application

Requires Elixir 1.19 or later in the supported 1.x line. CI targets
Elixir 1.19 / OTP 28 and Elixir 1.20 / OTP 29.
Until 0.4.0 is published, use the development checkout:

<!-- spectre:example checkout_dependency -->
```elixir
{:spectre, path: "../spectre"}
```

The host supplies authentication, a governed foundation, a Store and any
executors/broker. Configure the Domain with `mind: Spectre.Agent` for the handler
API above. [Host setup](docs/host-setup.md) covers static OTP supervision and
dynamic Domain creation. A custom `Spectre.Mind` is a separate lower-level
alternative, not an extra callback you need to implement for this Agent.

Spectre includes ledger adapters for ETS, Disk, Mnesia and PostgreSQL.
ETS is volatile. PostgreSQL uses **your application's Repo**; Spectre does not
bring Ecto or a driver. Chat history, local agent checkpoints and the authority
ledger have different purposes; see [storage](docs/storage-and-recovery.md).

The Vettore semantic-cache adapter ships with Spectre, but its dependencies do
not. Add Vettore in your app if you select it; choose your own embedding
provider. No model is loaded during Router lookup. Prism and Pulse still need
their separate 0.4 migrations; they are not ready-to-use integrations here.

## Where to go next

| Question | Read |
| --- | --- |
| How do I write handlers, routes, prompts and Skills? | [Authoring guide](docs/agents-and-dsl.md) |
| How do the no-model, model, classifier and reusable-component variants work? | [Recipes](docs/agent-recipes.md) |
| What does each configuration field mean? | [Configuration reference](docs/configuration.md) |
| How do I declare authority and start my application's processes? | [Host setup](docs/host-setup.md) |
| What is in the kernel, and where is it implemented? | [Architecture](docs/architecture.md) |
| How do streaming, voice, steering and cancel fit? | [Input and control](docs/integration-and-streaming.md) |
| What can be persisted, recovered or erased? | [Storage and recovery](docs/storage-and-recovery.md) |
| Which features exist and what is still incomplete? | [Capabilities](docs/capabilities.md) |
| How are examples and release checks verified? | [Testing](docs/testing-and-release.md) |

All fenced Elixir examples in these guides are executed by the documentation
tests with explicit host fixtures. Wiring fragments name their prerequisites;
they do not generate permissive authority. The larger
[authoring example](docs/agent-recipes.md#a-complete-modular-authoring-example)
compiles without starting services and is also shipped as `examples/authoring.exs`.
