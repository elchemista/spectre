# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)

An Elixir library for agents whose proposals cross an explicit authority boundary
before they can cause governed effects.

This checkout targets **0.4.0, unreleased**. It replaces the 0.3 runtime; it is
not a drop-in upgrade. Functional validation, adversarial tests and performance
qualification remain release work. Historical P1 measurements were a performance
**no-go**; subsequent indexed-path improvements are not a production throughput
or bounded-memory claim.

Start with [Governed surface and trust assumptions](GOVERNED_SURFACE.md).
The [Governed Act Model](GOVERNED_ACT_MODEL.md) defines the intended semantics;
the surface document explains what this implementation can actually promise.

## Documentation map

| Question | Guide |
| --- | --- |
| Where are GAM laws implemented, and who owns state? | [Architecture](docs/architecture.md) |
| What must my app provision before using an agent? | [Host setup](docs/host-setup.md) |
| What do the DSL, Skills, Instance, router and Morph do? | [Agent authoring](docs/agents-and-dsl.md) |
| Who handles intake, streaming, voice, steering and cancel? | [Input and control](docs/integration-and-streaming.md) |
| Which store do I implement? What happens after corruption or erasure? | [Storage and recovery](docs/storage-and-recovery.md) |
| What exists, what is host-owned, and what is still missing? | [Capability inventory](docs/capabilities.md) |
| How do I verify a complete agent and a release? | [Testing and release](docs/testing-and-release.md) |

These guides describe the new 0.4 authoring contracts. The implementation is
still being qualified; library compilation does not replace integration tests.
Package wiring stays explicit through `install`, `ports/0`, Mix and OTP;
Stack is a shared preset, not a resolver.

## The core

A Mind proposes; it does not create authority. Four records keep different
questions separate:

| Record | What it means |
| --- | --- |
| Mandate | Who may propose which consequences, for whom, within which limits |
| Evidence | What supports a proposition, with provenance and assumptions |
| Act | The exact exercise of authority committed before capability release |
| Duty | Unresolved causal debt and the conditions for disposing of it |

A governed execution follows this order:

```text
authenticated input → Evidence → Mind → Candidate
    → kernel Decision → ledger commit of Act
    → internal Grant → durable Attempt → broker / executor
    → Evidence and Outcome → settlement or retained Duty
```

Not every Decision admits an Act. Refusal, inability to decide and unknown class
remain distinct. An ambiguous external result is not permission to retry.
A late receipt does not need the old Mandate to become active again.

One Domain owns one logical ledger order and shared authority accounting.
Projection and offline audit use the same pure governed-act semantics, with
separate input drivers. Agent processes never own a second authoritative budget.

## Use the development checkout

Requires Elixir 1.19 or later within the supported 1.x line. CI exercises
Elixir 1.19 / OTP 28 and Elixir 1.20 / OTP 29.

Before 0.4.0 is published, use a local checkout in the host application's deps:

```elixir
{:spectre, path: "../spectre"}
```

Spectre starts its Domain supervision infrastructure as an OTP application.
The host chooses and supervises storage and its own optional agent Instances.

There is no automatic credential discovery, model provider, default business
authority or transport server.

## Host integration

The following is a wiring outline, **not a self-contained payment application**.
The host must first construct valid Genesis, Principal, HostProfile, Surface
and root Mandate records and supply the adapters named here.

```elixir
{:ok, store_pid} = Spectre.Ledger.Store.ETS.start_link()
store = {Spectre.Ledger.Store.ETS, server: store_pid}

{:ok, domain} =
  Spectre.start_domain("domain:payments", store,
    constitution: constitution,
    genesis: genesis,
    principals: principals,
    host_profile: host_profile,
    surface: surface,
    root_mandates: root_mandates,
    genesis_verifier: MyApp.GenesisVerifier,
    ingress: MyApp.Ingress,
    mind: MyApp.PaymentMind,
    executors: [MyApp.PaymentExecutor],
    broker: MyApp.CredentialBroker
  )

{:ok, context} = Spectre.authenticate(domain, scope_ref, authenticated_request)
{:ok, scope} = Spectre.open_scope(domain, context, opened_at: now)

{:ok, %{candidates: candidates}} = Spectre.turn(scope, input)
# Application policy selects a proposal; the list may contain alternatives.
candidate = MyApp.select_proposal(candidates)
{:ok, result} = Spectre.propose(scope, candidate)
```

ETS is volatile: use it for tests or ephemeral Domains, not durable promises.
In an application supervision tree, supervise the Store instead of starting it
from a short-lived request process. Inspect each proposal's Decision and Outcome;
an `{:ok, result}` is not synonymous with an admitted or successful effect.

`Spectre.Foundation.new/2` can assemble Genesis links from explicitly supplied
records without choosing policy or replacing the external verifier. See
[foundation assembly](docs/host-setup.md#assemble-the-links-without-choosing-policy).
Before deployment, `Spectre.Surface.verify_definition/2` can check fixed Agent
declarations and report occurrence fields still required; this is
[an authoring diagnostic](docs/agents-and-dsl.md#check-fixed-declarations-against-a-surface),
not permission to execute.

The main extension points are ordinary behaviours:

| Host implements | Responsibility |
| --- | --- |
| `Spectre.Ingress` | Authenticate principals and turn input into observed Evidence |
| `Spectre.Mind` | Route, plan and return capability-free Candidates |
| `Spectre.Attempt.Executor` | Attempt the committed consequence and report observations |
| `Spectre.Secret.Broker` | Release an Act/Attempt-scoped execution capability |
| `Spectre.Genesis.Verifier` | Check the externally recognized foundation |
| `Spectre.Ledger.Store` | Atomic append, CAS, identity lookup and recovery |
| `Spectre.Payload.Store` | Verify presence and digest of external payload bytes; deletion belongs to the governed executor |
| `Spectre.Clock` | Supply trusted host time |

Text, audio, TTS and VoIP require no new kernel-specific pipeline. The application
owns codecs, sessions, routing, authentication, rate limits and transport
security. Use `Spectre.Ingress.evidence/3` to bind observations to authenticated
context; use `Spectre.Mind.candidate/2` to bind proposals to a Turn. A remote
model call or audio transmission is governed only if included in the declared
Surface and routed through the executor boundary.
The [streaming guide](docs/integration-and-streaming.md) explains why transport
chunks are not automatically admission units and why local cancel is not an
Outcome or Duty disposition.

## Agent DSL, Skills and local state

A route names the handler to call, not a Candidate row or an effect:

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

The host publishes that Definition, supplies the foundation and class bindings,
and opens an authenticated Scope. Configure `mind: Spectre.Agent` on the Domain
for this authoring path. One supervised Instance owns the application's state:

```elixir
{:ok, instance} = MyApp.Orders.start_link(
  scope: scope, definition: definition, bindings: class_bindings, state: %{}
)
{:ok, turn} = MyApp.Orders.turn(instance, "order 42", flow: :orders)
[request] = turn.requests
Spectre.Instance.advance(instance, request)
```

`turn` prepares; `advance` submits one chosen ticket. A returned continuation
may contain another request, which is not automatically submitted. Slow work
uses the existing temporary worker, leaving state reads responsive. Pending,
refusal, inability to decide and ambiguous execution remain distinct.

The [authoring guide](docs/agents-and-dsl.md) covers extracted Routers, reusable
Stack presets, Skill substate, Worker/Vigil, request/ask/classify callbacks,
compiled EEx prompt files, injection, History/Memory adapters and semantic cache.
The [complete example](examples/authoring.exs) compiles without starting services.
Row, authority and execution are derived/checked against the governed Surface,
not hidden in DSL syntax.

`use Spectre.Stack` shares explicit configuration; it is not a dependency
resolver. `install Package do ... end` contributes data and named adapter ports.
Mix and host OTP supervision still own dependencies and resources. Built-in
router methods, including the semantic-cache bridge, use the same extension
contract as `via: [:binary]`. Optional Vettore/Prism/Pulse integrations do not
become core dependencies.

A custom `Spectre.Mind` remains available for lower-level authoring.
`Spectre.Store` and `Instance.checkpoint/4` persist portable application state,
not authentication or a duplicate authority ledger. Morph prepares an exact
Definition revision; governed activation, code deployment and state migration
remain distinct. Active Instances do not silently follow a new Definition head.

## Business constraints

Consequence contracts define closed shapes, constants and exact boundary
bindings. They are **not a general predicate or JSON Schema engine**: there are
no arbitrary comparisons, numeric ranges or callback predicates in the ledger.

For a refund budget, represent the authoritative amount in Meter requests and
bind those requests in the consequence contract. A duplicate amount field is
not automatically proven equal to the charged Meter amount. Per-operation
business conditions such as “this order was paid” or a separate amount limit
need an explicitly recognized Evidence proposition or a suitable authority
model. The host owns the truth and authentication of that observation.

## Persistence and audit

Available ledger adapters: ETS (volatile), Disk, Mnesia, PostgreSQL and Mock.
PostgreSQL uses the **host application's Repo**; Spectre adds no Ecto or driver
dependency. Generate, review and run the migration in the host application:

```sh
mix spectre.gen.postgres_ledger_migration
```

`Spectre.Audit.Export` encodes a canonical ledger, pinned Constitution and
trusted capture time. It can be verified without the live Domain:

```sh
mix spectre.audit domain.spectre
mix spectre.audit domain.spectre --at 1735689600000
```

The second form requires an observation time at or after capture. Missing Duties
already required at capture are errors. Causes becoming due afterwards appear
as `pending_duty_causes`, separately from recorded `open_duties`; later dispatch
expirations appear as `expired_dispatches`. Auditing never repairs the export.

Hash-chain integrity is **not externally anchored authenticity**. This version
does not sign ledger entries or publish witnessed heads. See the surface
document before using an export as third-party evidence.

## Migration and readiness

0.3 checkpoints, Stack.Runtime, flow/policy/effect declarations and old provider
APIs are incompatible. There is no automatic 0.3 checkpoint importer in this
checkout. Rebuild integrations against the behaviours above; reconcile legacy
effects and unresolved obligations explicitly. Importing records as Evidence
does not turn legacy effects into authorized Acts or settle their debt.

The remaining release work includes granular current-state persistence and
bounded lifetime memory, lifecycle/overload consolidation, package wiring checks and
performance qualification. Existing incremental indexes and batch paging do not
close those gates. Consult the [inventory](docs/capabilities.md), not historical
API names, to determine what is available.

From this checkout:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
mix test --cover
mix credo --strict
mix dialyzer
mix docs --warnings-as-errors
mix hex.build
```

Coverage retains its configured 95% gate; do not lower it to claim readiness.
Generate API docs locally with `mix docs`. See [Changelog](CHANGELOG.md) for the
breaking release and [Security policy](SECURITY.md) for reporting vulnerabilities.
