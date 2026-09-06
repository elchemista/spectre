# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)

An Elixir library for agents whose proposals cross an explicit authority boundary
before they can cause governed effects.

This checkout targets **0.4.0, unreleased**. It replaces the 0.3 runtime; it is
not a drop-in upgrade. Functional validation, adversarial tests and performance
qualification remain release work. In particular, the current P1 baseline is a
performance **no-go**, not a production throughput claim.

Start with [Governed surface and trust assumptions](GOVERNED_SURFACE.md).
The [Governed Act Model](GOVERNED_ACT_MODEL.md) defines the intended semantics;
the surface document explains what this implementation can actually promise.

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
results = Enum.map(candidates, &Spectre.propose(scope, &1))
```

ETS is volatile: use it for tests or ephemeral Domains, not durable promises.
In an application supervision tree, supervise the Store instead of starting it
from a short-lived request process. Inspect each proposal's Decision and Outcome;
an `{:ok, result}` is not synonymous with an admitted or successful effect.

The main extension points are ordinary behaviours:

| Host implements | Responsibility |
| --- | --- |
| `Spectre.Ingress` | Authenticate principals and turn input into observed Evidence |
| `Spectre.Mind` | Route, plan and return capability-free Candidates |
| `Spectre.Attempt.Executor` | Attempt the committed consequence and report observations |
| `Spectre.Secret.Broker` | Release an Act/Attempt-scoped execution capability |
| `Spectre.Genesis.Verifier` | Check the externally recognized foundation |
| `Spectre.Ledger.Store` | Atomic append, CAS, identity lookup and recovery |
| `Spectre.Payload.Store` | Retrieve and erase external payload bytes |
| `Spectre.Clock` | Supply trusted host time |

Text, audio, TTS and VoIP require no new kernel-specific pipeline. The application
owns codecs, sessions, routing, authentication, rate limits and transport
security. Use `Spectre.Ingress.evidence/3` to bind observations to authenticated
context; use `Spectre.Mind.candidate/2` to bind proposals to a Turn. A remote
model call or audio transmission is governed only if included in the declared
Surface and routed through the executor boundary.

## Agent DSL, Skills and local state

The DSL creates immutable data, not another runtime or policy engine:

```elixir
defmodule MyApp.LookupSkill do
  use Spectre.Skill,
    namespace: "my_app", name: "lookup", revision: 1, declared_at: 0

  candidate "order", class: "orders.lookup", row: %{read: true}
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent,
    namespace: "my_app", name: "support", revision: 1, declared_at: 0

  install MyApp.LookupSkill, as: "lookup"
end
```

`MyApp.SupportAgent.definition/0` returns a Definition. Its
`candidate("lookup/order", turn, attrs)` fills an occurrence from a template.
The host supplies the remaining exact consequence, Mandate, executor and
contract fields. Installing a Skill neither grants authority nor reserves money.

A Mind implements `deliberate/2`; an optional `deliberate/3` supports local
application state. Define the two callbacks explicitly, without default
arguments that could interpret options as state.

Routing is a reusable Zone M component. Declare `route "lookup", to: "order",
match: [regex: ~r/^find order$/u, string_bag: ["lookup order"]]` in a Skill,
and choose `router via: [:regex, :string_bag]` in its Agent. Compile once with
`MyApp.SupportAgent.router/0`, then call `Spectre.Router.route/2` and materialize
the selected template. Regex, string-bag (`bag_distance` is also accepted) and
Jaro are built in. Custom methods implement `Spectre.Router.Adapter` and are
wired with `adapters: [binary: MyMatcher]` for `via: [:binary]`. A route is not
a GAM Decision; ties and callback errors are explicit. Optional provenance can
be built with `Spectre.Router.Selection.evidence/4` and recorded as a derivation.

`Spectre.Input.Pipeline.new/2` prepares reusable local input plugs; `run/2`
validates each intermediate value and distinguishes completion, halt and error.
Use the built-in `Spectre.Input.Plugs.NormalizeText` or implement
`Spectre.Input.Plug` for application-specific envelopes. No text/audio/VoIP schema
is imposed. Run it in host code or the Mind, preserve relevant raw observations,
and record interpretations with `Spectre.Mind.evidence/3`. Normalization does not
authenticate input, grant authority or implicitly call remote providers.

`extend MyPackage, as: "package", options: [...]` composes an extension's
Definition through the same namespace/pinning mechanism as Skills. The
`Spectre.Extension` contract separates portable templates/routes/assets from
host adapter ports exposed through `ports/0`. The application explicitly wires
ports to their boundaries; installing a package cannot grant authority.

The legacy telemetry API is not yet ported. Read-only Scope views, ledger heads
and audit exports provide the current governed observability surface.

`Spectre.Instance` is optional: one GenServer serializes one authenticated
Scope's deliberation and holds opaque application state. The host supervises
it. Domain loss stops the Instance; the host must re-authenticate before creating
a replacement. Scope openings bind their original authentication and host
generation: changing either requires a new Scope, already covered by the needed
Mandate. Local state is not a ledger checkpoint. `Instance.checkpoint/4` saves
portable Mind state through an explicit application-store CAS; start with
`checkpoint: {store, key}` and a currently authenticated Scope to restore it.
Restoration never replays an executor or resets governed Meter/Duty state.

`Spectre.Store` supplies a generic canonical-value/CAS adapter contract and a
compressed ETS `Spectre.Store.Memory` implementation. `Definition.Store` adds
immutable publication with verified readback. Application persistence is
separate from the append-only ledger; durable application adapters implement
the same small contract. No additional database dependency is imposed.

Work and Vigil are durable Scope promises, not extra worker runtimes. Their
Duty obligations survive the agent process. The host supplies scheduling and
work execution.

Morph is a Definition revision: `Spectre.Morph` prepares atomic `put`/`delete`/
`test` changesets, deterministic diffs, forward-only rollback and host-selected
transformation adapters. `Spectre.revise_definition/4` submits the resulting
Definition through governance. It does not hot-load
code, migrate process state or enlarge a Mandate. An Instance's pinned Definition
is configuration, not proof that every Candidate originated from its templates.

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

The remaining release work includes targeted adversarial testing and removal of
repeated whole-history work from the runtime hot path. Passing static checks or
reaching a test-count target does not close those gates.

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
