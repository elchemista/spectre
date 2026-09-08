# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)
[![Hex](https://img.shields.io/hexpm/v/spectre.svg)](https://hex.pm/packages/spectre)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/spectre)

**An OTP-native Elixir runtime for agents, built on one rule: a proposal must
never carry the power to make itself happen.**

An agent can be wrong, be persuaded, invent a fact or change its plan. No
architecture makes a mind infallible, and Spectre does not try. It removes the
agent's ability to turn its own conclusions into consequences on its own.

You write the agent as ordinary Elixir: modules, callbacks, pattern matching and
OTP supervision. Your application declares, separately, which consequences are
governed and who may authorize them. Between the two sits a kernel the agent
does not control.

This checkout is **0.4.0, unreleased**. It is not a drop-in upgrade from 0.3,
and it is a library rather than a hosted service: you choose the providers,
credentials, storage and policy. See [current limits](docs/capabilities.md).

## Philosophy

Intelligence creates possibilities. Power turns them into consequences.
Governing an agent is not teaching it to be good — it is keeping those two
things apart.

Four things get confused constantly, and Spectre keeps them separate:

- A convincing answer is not a true one.
- A valid signature does not prove the signer had authority.
- A working key lets you act; it does not make the action legitimate.
- A human approval is worthless if the person never saw what would have changed
  their mind.

### Four distinctions

| | Question it answers | Example |
| --- | --- | --- |
| **Mandate** | Where does the right to act come from? | "This agent may propose refunds up to €100, on paid orders, until Friday" |
| **Evidence** | What do we have reason to believe? | The payment receipt, the customer identity, a model's classification |
| **Act** | Which exercise of that power did the system record? | The exact €50 refund, recorded as authorized *before* the payment service is contacted |
| **Duty** | What may we not yet call resolved? | The connection dropped after sending; we do not know whether the money moved |

Evidence informs a decision; it never authorizes it. A receipt proves a payment
happened, not that ordering it was allowed. Treating information as power is the
simplest way for hostile content to become a command.

### Four laws

**Mediate everything that counts.** Not every computation — an agent may reason
and generate freely. But every consequence your application declares governed
crosses one boundary. If the agent holds a key that produces the effect
directly, that boundary is decoration.

**Authority does not grow.** A delegation can only preserve or narrow the power
it came from. Running a hundred agents does not create a hundred budgets.
Knowing a credential does not widen a Mandate. New power requires a new Act from
an authority that already holds it.

**Causality is not rewritten.** The decision is recorded before the capability
to act is released, so the system cannot produce an effect and justify it
afterwards. What the world returns is recorded separately and does not change
what was authorized.

**Duty does not self-extinguish.** A timeout is not a failure and not a success.
Spectre will not retry the payment for you, and a restart, an expiry or someone's
silence cannot close an open case. Whoever created the debt cannot be the only
judge that discharges it.

### What this does not promise

Spectre does not promise that the agent tells the truth, that your code is
free of bugs, or that every effect is reversible. It promises something
narrower and checkable: **inside the perimeter you declare**, a proposal does
not create authority, evidence does not become a right, a capability does not
become a Mandate, and the present does not quietly rewrite the past.

A ledger shows what crossed the boundary; it does not prove there was no side
door. Callbacks in the same BEAM are not a security sandbox. The full reasoning
is in [GOVERNED_ACT_MODEL.md](GOVERNED_ACT_MODEL.md); the implementation's real
limits are in [GOVERNED_SURFACE.md](GOVERNED_SURFACE.md).

## Start with an agent, not kernel terminology

Want runnable files first? From your application:

```sh
mix spectre.gen.agent MyApp.Hello --dry-run
mix spectre.gen.agent MyApp.Hello
mix test test/my_app/hello_test.exs
mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings
```

This creates an Agent, a separate Router, a prompt template and tests. The
Hello World prepares a **local greeting** - no LLM, no credential, no Domain.
It does not send a message and does not create an authorized effect.
See [scaffolding and routing regression](docs/testing-and-release.md#scaffold-a-local-agent).

When you are ready for the first real effect,
`mix spectre.gen.host MyApp.Hello --class greeting.save` generates
**application-owned Host and Executor skeletons** plus a governed integration
test. It deliberately leaves the authority and backend choices unfinished; it is
not a permissive sandbox. Follow
[your first governed save](docs/host-setup.md#from-a-draft-to-your-first-governed-save).

Here is an order assistant, with no LLM and no Skill required:

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

1. `namespace` and `name` identify the agent's published definition. Neither
   creates a tenant, an identity or a permission.
2. `flow :orders` groups the routing choices for one kind of interaction.
3. `router via: [:regex]` picks the matching methods, in order. Routing is a
   dial: pure regex here, phrase matching, a cache, or a governed classifier.
4. `route :lookup` names a handler branch; `(?<id>...)` captures the order ID.
5. `handle_turn/3` **asks** to look up that order by returning plain data.
   `"orders.lookup"` is an application action class, not a function call.
6. `handle_result/4` runs after the governed result comes back. `result.status`
   distinguishes success, refusal, uncertainty and the other outcomes.
7. `definition/1` builds an immutable description of this code and
   configuration. `published_at` is an explicit host-chosen timestamp in Unix
   milliseconds. **This does not activate anything.**

The host declares once, in its Surface, which powers an action involves; the request builder reads it from
there. See [what a Row means](docs/architecture.md#what-is-a-row).

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

| Argument | What you supply |
| --- | --- |
| `scope` | A live authenticated handle into a Domain — not a string or a permission you invent |
| `definition` | The exact published revision activated in that Domain |
| `bindings` | The action-class map connecting requests to the host's Mandate, executor and accountability records |
| `state` | Your own local state; here an empty map |
| `flow: :orders` | Which declared flow receives this input |

These are prerequisites, not hidden global configuration.
[Host setup](docs/host-setup.md) explains how to obtain them, and
[the binding example](docs/host-setup.md#connect-a-handler-to-a-governed-action)
shows exactly what is inside `class_bindings`.

`turn` records the authenticated input and prepares requests. **It does not
execute them.** `advance` submits the one request you chose. Your application
can advance immediately, ask a person first, or pick among alternatives — the
model does not require a human click for every action.

`advance` returns `{:ok, next_turn}`, `{:pending, ref}` or `{:error, reason}`.
An `{:ok, next_turn}` can still contain a refusal: read `next_turn.result.status`.
Pending means *still in progress*, not *failed*, and the wait expiring does not
cancel the effect. See
[handling results and pending work](docs/agents-and-dsl.md#handler-contract).

## How an agent uses a model, and how it answers

The kernel never calls a provider. That is the only thing it refuses to do —
the model still gets called, by **your executor, after the decision is
recorded**. An inference is an Act exactly like a refund: same admission, same
commit, same outcome. That is why there is no separate "LLM subsystem" to learn.

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

Step by step, this is the whole agent loop:

1. **Prompts are compiled EEx templates rendered locally.** Declare them inline,
   as above, or as files under a `prompt_root`. `turn` renders them in your own
   process, with no network call, into an **ordered list of named parts** —
   policy first, task second — rather than one concatenated string. Your
   executor maps those parts onto whatever message format the provider expects.

2. **`ask` declares an inference the way a class declares any other effect.**
   `class: "model.generate"` is a Surface class *your host* defines, with its
   own contract and Mandate. `model_ref` and the other options are configuration
   your executor resolves: Spectre installs no provider and interprets no model
   identifier.

3. **`{:ask, :answer, assigns, state}` prepares; it does not call.** You get a
   ticket in `turn.requests` and nothing has left the machine yet.

4. **`advance` submits it.** The kernel checks the inference against its Mandate,
   contract and budget exactly as it would a €50 refund, records the Act, and
   only then releases the capability. Your executor calls the model and reports
   an Outcome.

5. **`handle_result` receives that Outcome and asks for the next thing.** Notice
   the answer is not delivered by returning it: the handler prepares a *second*
   request, `"chat.send"`. Generating text and showing it to a person are two
   consequences, with two records. If delivery is not governed in your
   application, send it from host code — but say so, instead of letting one Act
   appear to cover both.

`result.data` is whatever your `model.generate` contract declares and your
executor observed. Pattern-match it; do not assume it is a string.

### Work that outlives the conversation

When something must continue after the turn ends, use a **Worker** or a
**Vigil**: a separately supervised Instance with the same handler contract,
started under an explicit Scope opening that carries a deadline, a responsible
party and an independent disposition authority.

```text
handle_work(input, work, state)  →  {:request, ...} / {:ask, ...}  →  advance
handle_vigil(event, vigil, state) →  same returns                  →  advance
```

Killing that process does not fulfil its promise and a timer cannot close it —
that is the Duty law applied to background work. See
[Skills, Workers and Vigils](docs/agent-recipes.md#reusable-skills-workers-and-vigils).

## Router, controller, prompt and model: who does what?

The useful analogy is **Router → Controller**, with prompts and models chosen by
the controller. The controller is your Agent's callbacks, not a required
`Spectre.Controller` module.

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

A model is never a compulsory middle layer:

| You want | Use |
| --- | --- |
| Structured input, no routing | `handle_turn(input, turn, state)` directly |
| Commands without an LLM | Regex or string matching → handler → business request |
| A model-generated draft | Handler → prompt → governed `ask` → result handler |
| A model to choose a branch | Governed `classify` → confirmed labels → handler → separate business request |
| Reuse of past routing examples | `via: [:semantic_cache]` → handler; the cache nominates, it never executes |
| Different behaviour per domain | Separate flows, each with its own pipeline and Router |
| Reusable logic | A Skill in the same Instance, or a separately supervised Worker/Vigil |

See [worked combinations](docs/agent-recipes.md) for code and a complete modular
agent, [prompts and injection](docs/agents-and-dsl.md#prompts-and-injection) for
compiled EEx templates, and the
[configuration reference](docs/configuration.md) for every option — including
which ones are provider-specific rather than interpreted by Spectre.

## The kernel, in one refund

An application allows refunds from a €100 budget on paid orders. The agent
proposes €50. Nothing has moved yet.

The kernel asks one question: *is this exact proposal authorized on these
facts?* It compares amount, recipient, purpose and evidence against the Mandate.
It calls no model and writes no business data. If it recognizes the proposal,
the Domain records an Act describing exactly that refund — and only then does
the execution boundary release the capability to contact the payment service.

The executor reports what happened. That report does not rewrite what was
authorized. If a reliable receipt arrives, the case closes. If the connection
drops and nobody knows whether the money left, Spectre does not turn silence
into failure and does not send it again: it opens a Duty, which a proof, a
reconciliation or an authorized decision can close. A late receipt can still
reconcile the original attempt after the Mandate was revoked.

Alongside the four distinctions, four supporting records carry the rest:
the **Surface** is your catalog of governed action classes and their contracts;
a **Row** summarizes which kinds of power an action uses; a **Meter** accounts
for a limited resource, so copying an agent does not copy its budget; and a
**Domain** owns the shared order of these facts.

Read [the kernel explained](docs/architecture.md) next.

## Install and connect it to your application

Requires Elixir 1.19 or later in the supported 1.x line. CI targets
Elixir 1.19 / OTP 28 and Elixir 1.20 / OTP 29. Until 0.4.0 is published, use the
development checkout:

<!-- spectre:example checkout_dependency -->
```elixir
{:spectre, path: "../spectre"}
```

The host supplies authentication, a governed foundation, a Store and any
executors or broker. Configure the Domain with `mind: Spectre.Agent` to use the
handler API above; a custom `Spectre.Mind` is a separate lower-level
alternative, not an extra callback you must implement.
[Host setup](docs/host-setup.md) covers both static OTP supervision and
dynamically created Domains.

Spectre ships ledger adapters for ETS, Disk, Mnesia and PostgreSQL. ETS is
volatile. PostgreSQL uses **your application's Repo**: Spectre brings neither
Ecto nor a driver. Chat history, local agent checkpoints and the authority
ledger are three different things — see
[storage and recovery](docs/storage-and-recovery.md).

The Vettore semantic-cache adapter ships with Spectre, but its dependencies do
not: add Vettore in your own project if you select it, and choose your own
embedding provider. No model is loaded during a Router lookup.

## Spectre ecosystem

Spectre core stays focused on agent authoring and governed execution. The
satellite repositories each add one bounded capability, depending on Spectre's
public contracts while Spectre neither depends on nor discovers them. Each is
versioned independently.

**These packages were built against 0.3 contracts.** 0.4 changed the runtime
they integrate with, so each needs its own migration before it can be used here.
`spectre_prism` and `spectre_pulse` are the two currently being migrated;
treat the rest as not yet available for 0.4 rather than as drop-in additions.

| Repository | Responsibility |
| --- | --- |
| [`spectre_prism`](https://github.com/elchemista/spectre_prism) | Constraint-aware model and profile selection by capability, privacy, cost and latency. Provider credentials and runtime ownership stay with the host. |
| [`spectre_pulse`](https://github.com/elchemista/spectre_pulse) | Transport-independent agent-to-agent envelopes, discovery, routing and delivery receipts. Coordination policy and shared workflow state stay outside it. |
| [`spectre_mnemonic`](https://github.com/elchemista/spectre_mnemonic) | Durable memory, recall, search, consolidation and provenance. Not canonical agent state and not your application database. |
| [`spectre_kinetic`](https://github.com/elchemista/spectre_kinetic) | Tool retrieval and validated action planning. Authorization and execution remain explicit core and host boundaries. |
| [`spectre_lens`](https://github.com/elchemista/spectre_lens) | Backend-neutral browser perception and browser actions. Browser authorization and the effect lifecycle remain outside it. |
| [`spectre_beam`](https://github.com/elchemista/spectre_beam) | External-channel normalization and idempotent delivery. Identity, consent and policy remain host and core concerns. |
| [`spectre_directive`](https://github.com/elchemista/spectre_directive) | A resumable mission and evolving-plan loop. It does not replace Instance ownership or core scheduling. |
| [`spectre_lab`](https://github.com/elchemista/spectre_lab) | Verified offline playback and isolated testing tools for checkpoint bundles. It adds no runtime owner or storage backend. |

[`spectre_ecosystem`](https://github.com/elchemista/spectre_ecosystem) is
separate compatibility tooling, not a library or a runtime dependency. It
dispatches each repository's own test workflows and aggregates the results.

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
| Which features exist, and what is still incomplete? | [Capabilities](docs/capabilities.md) |
| How are examples and release checks verified? | [Testing](docs/testing-and-release.md) |

Every fenced Elixir example in these guides is executed by the documentation
tests against explicit host fixtures. Wiring fragments name their prerequisites
instead of generating permissive authority. The larger
[authoring example](docs/agent-recipes.md#a-complete-modular-authoring-example)
compiles without starting services and ships as `examples/authoring.exs`.

### Research and inspiration

The [Governed Holon Model](GOVERNED_HOLON_MODEL.md) explores how governed
identities could cooperate and retain responsibility across composed systems.
It is **research only** — not an implemented 0.4 capability, a runtime contract
or a release commitment. The implementation follows the Governed Act Model,
within the limits documented in GOVERNED_SURFACE.md.
