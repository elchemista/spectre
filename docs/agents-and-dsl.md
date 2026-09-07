# Agents, DSL, Skills and Morph

The DSL produces portable declarations; it does not create authority or start
an agent. Read [architecture](architecture.md) for the execution boundary and
[the capability inventory](capabilities.md) for APIs still absent in 0.4.

## Definition, Mind, Instance and Runner

A `Spectre.Definition` identifies immutable application configuration by content
and revision. A `Spectre.Mind` uses observations and that configuration to propose
Candidates. An optional `Spectre.Instance` serializes use of a Mind around one
Scope and owns application state. A `Spectre.Attempt.Runner` executes a
committed world Act through its fixed broker and executor.

You can use `Spectre.turn/3` and `Spectre.propose/3` without an Instance. Do not
start a second kernel for each Skill or confuse local Mind state with durable
authority. Configuration data can be replaced; recorded causal facts cannot.

## Complete DSL vocabulary

| Declaration | Meaning | Does not do |
| --- | --- | --- |
| `use Spectre.Agent, ...` | Declare an immutable agent Definition with explicit metadata | Start a process or choose a clock |
| `use Spectre.Skill, ...` | Declare a reusable component using the same language | Grant privileges to the installing agent |
| `candidate name, attrs` | Fix request fields for a named Candidate template | Submit or execute it |
| `install module, as: name` | Expand and pin a component under an explicit namespace | Load a mutable latest version at every turn |
| `route name, to: template, match: ...` | Declare a local proposal-selection rule | Make a kernel Decision |
| `router via: ..., accept: ..., margin: ...` | Set ordered matchers and selection thresholds | Add Conditions or authority |
| `flow name do ... end` | Name an independent routing/pipeline composition; nesting namespaces the name | Start a process or inherit a parent's policy |
| `pipe_through name_or_names` | Select ordered host-prepared input pipelines in a flow | Load modules from the ledger or authenticate input |
| `asset name, value` | Store portable prompt/schema/configuration data | Execute the asset or treat it as a secret vault |
| `extend module, as: name, options: ...` | Install Extension data and separately named host ports | Wire or run those adapters automatically |

Metadata includes `namespace`, `name`, `revision`, `previous_ref` where
applicable, and `declared_at`. Supply it explicitly so recompiling the same
declaration does not invent a new identity. Module names and callback code are
not loaded from canonical Definition records.

This self-contained example compiles declarations and tests local routing only;
it deliberately performs no governed effect:

<!-- spectre:example authoring -->
```elixir
defmodule Guide.OrderSkill do
  use Spectre.Skill,
    namespace: "guide", name: "orders", revision: 1, declared_at: 0

  candidate "lookup", class: "orders.lookup", row: %{read: true}

  route "find", to: "lookup",
    match: [regex: ~r/^order (?<id>[0-9]+)$/u, string_bag: ["find my order"]]

  asset "prompt", "Suggest an order lookup; do not claim it has run."
end

defmodule Guide.SupportAgent do
  use Spectre.Agent,
    namespace: "guide", name: "support", revision: 1, declared_at: 0

  install Guide.OrderSkill, as: "orders"
  router via: [:regex, :string_bag], accept: 0.85, margin: 0.0
end

definition = Guide.SupportAgent.definition()
{:ok, router} = Guide.SupportAgent.router()
{:ok, selection} = Spectre.Router.route(router, "order 42")
"orders/lookup" = selection.candidate
true = definition.body["components"]["orders"] == Guide.OrderSkill.definition().ref
```

The generated public functions are `definition/0`, `ports/0`, `router/0,1`,
`flows/0`, `flow/1,2` and `candidate/3`. Build a proposal with
`Guide.SupportAgent.candidate("orders/lookup", turn, occurrence_attrs)`.
The remaining occurrence attributes must supply the exact consequence and all
required coverage/bindings. `Spectre.Mind.candidate/2` binds the proposer and
Scope from the Turn. A template-fixed field cannot be supplied again, even
with an equal value: this is a collision, not an override mechanism.

Installed templates, routes and assets are namespaced together. Component
references are pinned in the parent Definition. Select the router policy in the
root Agent for root routes; each named flow retains its own explicit policy.
Installing a Skill does not silently replace the root policy.

## Check fixed declarations against a Surface

`Spectre.Surface.verify_definition/2` is an optional pure authoring check. It
accepts an Agent or Skill Definition, including installed templates, and pins
its report to the exact Definition and Surface refs. It does not activate either
record or require a running Domain:

<!-- spectre:example definition_check -->
```elixir
defmodule Guide.VerifiedAgent do
  use Spectre.Agent,
    namespace: "guide", name: "verified", revision: 1, declared_at: 0

  candidate "lookup", class: "orders.lookup", row: %{read: true}
end

{:ok, contract} = Spectre.Consequence.Contract.new(
  shape: %{"order" => "target_ref"}
)
{:ok, surface} = Spectre.Surface.new(
  revision: 1,
  declarations: %{"orders.lookup" => %{read: true}},
  consequence_contracts: %{"orders.lookup" => contract}
)
{:ok, report} = Spectre.Surface.verify_definition(surface, Guide.VerifiedAgent.definition())
[:class, :row] = report.templates["lookup"].checked
true = :consequence in report.templates["lookup"].deferred
true = :target_refs in report.templates["lookup"].deferred
```

Each template has `checked`, `deferred` and `errors`. The check covers a fixed
class and row, a fixed consequence's complete closed schema, and any supplied
subject/target/disclosure destinations and Meter requests. Missing occurrence
fields are deferred, never filled from guesses. Intrinsic consequences without
a contract are deferred; their state-dependent facts always remain runtime work.
Errors across templates are collected in
`{:error, {:definition_surface_mismatch, report}}`. `checked` lists the fields
submitted to checks, not a claim that those checks passed.

Even a clean report with no deferred static fields is not a complete Candidate
validation or permission to act. Consent, authenticated bindings, current
authority, live Evidence, resources and executor wiring still need their normal
runtime checks. Supply the remaining occurrence attributes when materializing
the template; the core revalidates every actual proposal against the Surface
in force at admission. Re-run the authoring check explicitly when comparing
another Definition or Surface revision.

## Flows and ordinary Mind handlers

Prepare the plans once in host configuration, then reuse them. A flow names
which prepared `Input.Pipeline` objects it needs. The existing `Pipeline.new/2`
is the pipeline authoring API: there is no second pipeline compiler or `plug`
DSL here. Definitions contain names, not executable pipeline modules.

<!-- spectre:example flows -->
```elixir
defmodule Guide.FlowAgent do
  use Spectre.Agent,
    namespace: "guide", name: "flow-agent", revision: 1, declared_at: 0

  candidate "lookup", class: "orders.lookup", row: %{read: true}

  flow "support" do
    pipe_through "text"
    router via: [:regex, :string_bag]
    route "order", to: "lookup",
      match: %{regex: ~r/^order (?<id>[0-9]+)$/, string_bag: ["find my order"]}

    flow "raw" do
    end
  end
end

{:ok, text} = Spectre.Input.Pipeline.new([
  {Spectre.Input.Plugs.NormalizeText, case: :downcase}
])
{:ok, support} = Guide.FlowAgent.flow("support", pipelines: %{"text" => text})
{:ok, selection} = Spectre.Agent.Flow.route(support, "  ORDER 42  ")
"lookup" = selection.candidate
{:ok, raw} = Guide.FlowAgent.flow("support/raw")
{:unrouted, "  ORDER 42  "} = Spectre.Agent.Flow.route(raw, "  ORDER 42  ")
```

Root declarations such as Candidate templates, assets and installs stay outside
the flow block; their exact names are referenced by its routes. Nesting names
does not copy the parent's pipelines or router. `pipe_through` may be declared
once per flow; declare the full ordered list rather than relying on hidden
accumulation. Skill/Extension installation namespaces flow names, referenced
pipelines and Candidate targets together. A Skill's `"text"` pipeline mounted
under `"billing"` must be wired as `"billing/text"`.

`Flow.route/2` preserves the four Router results and adds `{:halt, input}` for
pipeline halt and `{:unrouted, input}` for an explicitly router-free flow.
Handle these as application decisions. The Controller is simply the role of
the Mind handler, not another behaviour or process. An agent may implement
both `use Spectre.Agent` and `use Spectre.Mind` in one module, using ordinary
functions/pattern matching to interpret the routing result. A handler can
produce no Candidate, several alternatives, a deterministic Candidate, or
prepare a Prompt; none of those choices automatically executes an effect.

Plans pin `definition_ref` and `name`, but contain no Turn or application state.
They are host-prepared objects, not ledger checkpoints. Rebuild explicitly when
selecting a new Definition or changing host adapter configuration. Pure routing
does not assert that the selected Definition is the active governed head.

## Prompt composition, not Candidate templates

`Spectre.Prompt` joins explicitly ordered contributions after the handler has
chosen what it needs. It is separate from `Spectre.Candidate.Template`, which
fixes fields of a proposed consequence. The renderer never calls a provider,
reads a store or evaluates EEx/code from an asset.

Inside a real Mind handler, where `turn`, `input` and an Agent Definition are
already available:

```elixir
{:ok, prompt} = Spectre.Prompt.compose(turn, [
  {:asset, definition, "instructions"},
  {:evidence, input.ref},
  {:text, "request", "Propose an answer; do not claim an effect happened."}
], max_bytes: 16_384)

text = Spectre.Prompt.text(prompt)
```

Asset values and rendered input must be UTF-8 text. Use `{:evidence, ref, text}`
for an explicit local rendering of structured input. All cited Evidence must
be in the Turn; arbitrary refs and missing assets fail. Composition keeps the
conservative union of the whole Turn's labels, even if some context is not
quoted. Input text does not become trusted instructions through interpolation.

Limits are `max_parts` (default 64) and `max_bytes` (default 65,536, including
the two-newline separators). Overflow rejects the complete composition without
truncating it. These are byte limits, not provider tokens or kernel Meter
accounting. A host may use the ordered `parts` with its own message/role format.

`Prompt.ref/1` binds text, order, sources and labels. `Prompt.evidence/4` can
build derived provenance with that digest and source metadata, without copying
the prompt text into its payload. Recording through `record_derivation` is
explicit. A digest is not proof of truth or anonymization. External inference
and disclosure still require an admitted Candidate and the normal executor
boundary; building a prompt is not permission to send it.

## Routing and custom methods

Built-ins are `:regex`, `:string_bag`, `:bag_distance` and `:jaro`.
String-bag/bag-distance use the same bag-distance scorer; Jaro uses its own
distance. Fuzzy examples are normalized once. Regex captures are diagnostic
data, not authenticated claims.

Methods run in `via` order. A nomination must meet `accept` and beat its runner-up
by `margin`; exact ties remain ambiguous even at margin zero. An undecided
method allows the next method to try. Errors do not become silent misses.
Handle all four results of `Spectre.Router.route/2`: `{:ok, selection}`,
`:no_match`, `{:ambiguous, rule_refs}` and `{:error, reason}`.

Custom identifiers such as `via: [:binary]` are supported:

<!-- spectre:example custom_router -->
```elixir
defmodule Guide.BinaryMatcher do
  use Spectre.Router.Adapter

  @impl true
  def evaluate(request, _opts) do
    {:ok,
     for rule <- request.rules, rule.data === request.input do
       result(rule, 1.0)
     end}
  end
end

{:ok, router} =
  Spectre.Router.new(
    %{"ping" => %{to: "respond", match: %{binary: <<0, 1>>}}},
    via: [:binary], adapters: [binary: Guide.BinaryMatcher]
  )

{:ok, selection} = Spectre.Router.route(router, <<0, 1>>)
"respond" = selection.candidate
```

Implement optional `prepare/2` to compile rule data once. `evaluate/2` receives
only its input and visible rule data; its bounded scores cannot nominate
invisible rules or install a module. The host supplies `adapters`, never the
ledger. Built-in method identifiers cannot be replaced.

`Spectre.Router.Selection.evidence/4` can describe a selection as derived
Evidence bound to a Turn. Persist it through `Spectre.record_derivation/4` when
needed. Recording the explanation still does not make the selection authority.

## Turn, proposal, Decision and an application-level ask

`Spectre.turn(scope, input, opts)` records ingress observations, constructs a
sealed capability-free Turn, invokes the configured Mind and returns
`{:ok, %{turn: turn, evidence: evidence, candidates: candidates}}` or an error.
It does not execute the Candidates. Observations already recorded are not rolled
back if deliberation fails.

The explicit stateful form `Spectre.turn(scope, input, state, opts)` also
returns `state`. `use Spectre.Mind, ref: "mind:example", stateful: true`
generates the `/2` bridge for your `/3`; plain behaviours define both arities
separately. Never use `def deliberate(turn, state, opts \\ [])`: that generates
a `/2` whose second argument would accidentally receive stateless options.

Choose which Candidate to submit in application code. A list returned by a Mind
can represent alternatives, not a command to execute every item. Submit one
with `Spectre.propose(scope, candidate)` and inspect
`result.primary.decision.outcome`. `Spectre.Proposal.Result` wraps the primary
runner result and any declared fallback result; it is not a new permission.
`Spectre.Proposal.Result.status/1` returns separate primary/fallback summaries
with `admission`, `act_committed?`, `attempted?` and `outcome`. An absent Outcome
is `nil`, never an invented failure or a claim of no effect.

| Result | Application interpretation |
| --- | --- |
| `:admitted` | Admission succeeded; inspect Act, Attempt and Outcome to know what happened |
| `:refused` | A recognized proposal was denied; an explicitly declared fallback may be eligible |
| `:undecidable` | Required recognition/support cannot establish a decision; not refusal |
| `:unknown_class` | The Surface does not recognize this class; not refusal |
| `{:error, reason}` | The call failed; after an external attempt, never infer no effect merely from this |

There is currently no `Spectre.ask` function or `ask` DSL macro. An app may call
its own orchestration function `ask`: observe, deliberate, select, propose,
inspect the result, and optionally continue under an explicit budget. That name
must not collapse proposal into authorization or silently loop/retry. Fallback
is bounded and applies to explicit refusal, not ambiguity or an unknown class.

## Instance lifecycle and checkpoint

Start an Instance only with an already authenticated, durable Scope and a
governed Definition visible to it:

```elixir
{:ok, instance} =
  Spectre.Instance.start_link(scope: scope, definition_ref: definition.ref, state: %{})
```

This is a wiring fragment: the host must first provision the Domain and register
the Definition through its authorized revision path. Use your application's
supervision tree for the live process.

The selected Definition is exact and immutable but need not remain the current
head. Pinning is application configuration, not proof that every Candidate
originates in that Definition. The kernel independently checks every proposal.
The reserved Mind options `definition_ref` and `state_revision` cannot be
overridden by callers.

`Instance.state/1` returns the local value and its revision. The revision advances
only when a successful turn changes that value; errors leave it unchanged.
`scope/1` and `info/1` are local snapshots, not new authentication. `definition/1`
queries through the facade and checks the Scope fence. On Domain loss or an
observed invalid fence, the Instance shuts down so the host can authenticate
again. A previous Scope cannot be restored as authority from a checkpoint.

Slow mutations run in a single linked, monitored temporary worker. The Instance
remains the one persistent state owner. Local reads return its last completed
value while a Mind, executor or checkpoint store is busy. Definition lookup
obtains a small binding from the owner and queries the Domain in the caller,
preserving the fence without blocking other Instance reads.

`max_pending_operations` limits the waiting FIFO (default 32, excluding the
active operation). Zero permits idle work but rejects concurrent mutations with
`{:error, :instance_busy}`. A queued turn uses the state completed by the preceding
turn; a queued checkpoint saves that completed state. Request counts are bounded,
not arbitrary mailbox messages or the bytes retained by host callbacks.

The four reads accept an optional timeout in milliseconds or `:infinity`,
default 5,000 ms. For `definition/2`
it bounds the Instance binding lookup, not the separate Domain verification.
Mutation calls still wait indefinitely. Caller death or timeout does not cancel
accepted work. Worker death returns `{:error, {:instance_operation_stopped, kind}}`
without retry and without updating local state. This error does not imply that
a proposed world effect did not occur.

Detected Domain/Scope loss replies with an error before stopping the owner and
worker; an abrupt process kill retains ordinary OTP call-exit behavior. A slow
Mind's successful result is checked against the live Scope before adoption.
This is lifecycle support, not an implicit streaming or cancellation engine.

`Instance.checkpoint/4` explicitly saves portable application state through
`Spectre.Store` with compare-and-swap. `checkpoint: {store, key}` restores that
state under a fresh authenticated Scope. It cannot restore a Grant, erase a
Duty, replay an executor or certify that an external effect completed.

## Extensions and explicit host wiring

An Extension implements `c:Spectre.Extension.definition/1`, returning a valid
declaration, and optional `ports/1`, returning named host adapter configurations.
Install with `extend Package, as: "package", options: [...]`.

The compiled `ports/0` map separates executable host configuration from canonical
data. The application wires a port to its matching boundary: ingress, executor,
broker, router adapter, store or observer. Merely declaring an executor port
does not register it in the Domain or make a credential available.

There is deliberately no `Spectre.Stack` installer/resolver to complete. Mix
installs dependencies, `install`/`extend` compose declarations, and OTP supervises
host resources in the order the application declares. `mix spectre.doctor`
can compare declared ports with the host's named wiring map and report missing
or undeclared ports; it does not resolve them. See
[host setup](host-setup.md#read-and-diagnose) for the configuration and its limits.

## Behaviour helpers, not an implicit routing engine

`use Spectre.Mind, ref: "mind:support:v1"` generates only the behaviour and
overridable identity callback. Implement `deliberate/2` explicitly. Existing
plain `@behaviour` implementations remain valid.

The stateful variant supplies the correct stateless bridge without confusing
options with state:

<!-- spectre:example mind_adapter -->
```elixir
defmodule Guide.StatefulMind do
  use Spectre.Mind, ref: "mind:guide:v1", stateful: true

  @impl true
  def deliberate(_turn, state, opts) do
    {:ok, [], {state, Keyword.fetch!(opts, :message)}}
  end
end

# A stateless call deliberately uses nil and discards the returned local state.
{:ok, []} = Guide.StatefulMind.deliberate(:example_turn, message: "hello")
{:ok, [], {7, "hello"}} =
  Guide.StatefulMind.deliberate(:example_turn, 7, message: "hello")
```

The placeholder Turn above illustrates only callback shapes. Real calls enter
through `Spectre.turn`, which supplies and validates the sealed Turn and checks
every returned Candidate. Override `deliberate/2` if stateless use needs another
policy. Without `stateful: true`, the runtime already preserves Instance state
when only `deliberate/2` is implemented. Do not add default arguments to `/3`;
they would generate a conflicting `/2`.

Ingress, Executor and Broker also accept `use`, with explicit references:
`Ingress` requires `ref`; `Attempt.Executor` requires `executor_ref` and
`contract_ref`; `Secret.Broker` requires `ref` and `profile`. Identity callbacks
are overridable. No authentication, observation, checkout or execution callback
is provided by default, and no deployment profile is inferred.

Router and Pipeline configuration belongs to the flow/composition using it,
not a global Instance policy. Root routes and named flows are both supported.
Whether to clarify, return no Candidates, or offer several alternatives on
`no_match`/`ambiguous` remains explicit application logic. Constructing routing
Evidence may be mechanical, but choosing to durably record it and handling a
failed append must not become hidden side effects of `use Spectre.Mind`.

## Morph and governed activation

`Spectre.Morph.prepare/3` applies `:test`, `:put` and `:delete` operations to an
immutable Definition. Tests use exact equality. Invalid operations abort the
whole preparation. Paths traverse maps and zero-based list indexes; no script
or executable policy comes from a changeset.

`from_adapter/4` obtains proposed changes from a host-selected `changes/2`
callback. `diff/2` prepares reviewable changes. `rollback/3` copies an earlier
same-family body into a new forward revision; it does not rewind history.

All of these are preparation only. Use `Spectre.revise_definition/4` with a
properly authorized governance Candidate to activate the revision. Existing
Instances remain pinned; preparation or activation does not silently swap
their code, state or selected Definition.

## Work and Vigil

`Spectre.Scope.Opening` supports `:session`, `:child`, `:work` and `:vigil`.
Work/Vigil are governed promised scopes: they declare a finite due time,
closing Condition, accountable parties and an independent resolution route.
Open them with the governed `Spectre.open_scope/5` path. A promise that becomes
due without adequate closure derives a Duty.

These records are not cron jobs, autonomous infinite loops or task supervisors.
The application supplies scheduling and workers; each effect still crosses
the same admission boundary. Stopping a worker is not disposal of its promise.
