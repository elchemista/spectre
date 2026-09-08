# Authoring agents in 0.4

An Agent is a module of declarations and callbacks. One supervised
`Spectre.Instance` owns its local state; the existing Domain/kernel owns
authority and durable facts. A route selects a handler, **not an effect**.

```text
host input → flow/pipeline/router → handle_turn → prepared request
host advance → Candidate → kernel/commit/Attempt/executor → Outcome
             → handle_result → next prepared request, or local state
```

The host chooses each advance. No-match, ambiguity, approval, streaming and
automatic continuation are application decisions, not macro defaults.

## A small Agent

```elixir
defmodule MyApp.Orders do
  use Spectre.Agent, namespace: "shop", name: "orders"

  flow :orders do
    router via: [:regex, :string_bag], accept: 0.85, margin: 0.05
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
    route :help, match: [string_bag: ["help with orders"]]
  end

  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn({:orders, :help, _match}, _turn, state),
    do: {:request, "support.help", %{}, state}

  def handle_turn({:orders, :no_match, _input}, _turn, state),
    do: {:error, :clarification_needed, state}

  def handle_turn({_flow, :ambiguous, _refs}, _turn, state),
    do: {:error, :ambiguous_route, state}

  def handle_turn({_flow, :error, reason}, _turn, state),
    do: {:error, reason, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

definition = MyApp.Orders.definition(revision: 1, declared_at: published_at)
```

Publication time is explicit; compiling a module never chooses a new revision
or activates it. Publish the Definition through the governed revision path.
After the host has provisioned the Domain, published the Definition and opened
an authenticated Scope:

```elixir
{:ok, instance} = MyApp.Orders.start_link(
  scope: scope,
  definition: definition,
  state: %{},
  bindings: class_bindings
)
{:ok, turn} = MyApp.Orders.turn(instance, "order 42", flow: :orders)
[request] = turn.requests

case Spectre.Instance.advance(instance, request, wait: 1_000) do
  {:ok, next_turn} -> MyApp.UI.show_result(next_turn.result)
  {:pending, ref} -> MyApp.UI.track(ref)
  {:error, reason} -> MyApp.UI.show_error(reason)
end
```

These are host-wiring fragments, not a permissive foundation. `class_bindings`
maps each class to its explicit Candidate occurrence bindings: Mandate,
executor/contract, accountable parties, purpose and other required coverage.
The DSL derives Row from the current Surface, not from a `row:` option.
Consequence contracts can derive target/disclosure/Meter bindings; missing or
conflicting facts are errors, never authority defaults.

Configure the Domain with `mind: Spectre.Agent` for this handler path.
It uses `Spectre.open_turn/3` for authenticated input without calling a second
Mind. Low-level `Spectre.turn` with a custom Mind remains a separate supported
interface; it does not execute Agent handlers implicitly.

## Handler contract

`init/1` defaults to `{:ok, state}`. Other handlers are explicit. There is no
generated successful empty response for missing no-match/error clauses.

| Return | Meaning |
| --- | --- |
| `{:ok, state}` | Local state, no request |
| `{:request, "class", data, state}` | Prepare a Candidate for a business class |
| `{:request, :name, data, state}` | Prepare a declared request template |
| `{:ask, :name, assigns, state}` | Render the declared prompt and prepare inference |
| `{:classify, :name, input, state}` | Prepare an external classification |
| `{:request, candidate_or_list, state}` | Low-level Candidate, or at most 32 alternatives |
| `{:error, reason, state}` | Structured application error and local state |

A list offers alternatives, not instructions to execute all elements.
`advance/3` reserves one exact ticket and supersedes its siblings. Ticket
Instance, Definition, turn and state revision must still match. Calling it again
does not execute again. `handle_result/4` receives `{kind, name}`, the result,
the correlated Turn, and that component's local state.

The result retains `details` (the original governed result), `fallback`,
`operation`, `request_ref` and `turn_ref`. Its factual status is:

| Status | Fact |
| --- | --- |
| `:done` | Succeeded Outcome, or committed ledger-internal operation |
| `:refused` | Kernel refused |
| `:undecidable` | Evidence did not establish a decision |
| `:unknown_class` | Kernel did not recognize the class |
| `:not_attempted` | Durable dispatch cancellation, not just a missing Attempt |
| `:failed` | Failed Outcome |
| `:no_effect` | Explicit definitive-no-effect Outcome |
| `:unclear` | Ambiguous Outcome |

Pending is operational: `{:pending, request_ref}`, not `:unclear`.
`Instance.operation(instance, ref)` returns `:pending`, a retained completed
result, or an explicit error, without submission.
An evicted reference or lost process proves nothing about external effects.
Fallback results remain separate; fallback success does not rewrite refusal.

## Flow, Router and custom methods

Extract precisely the same flow block when it helps readability:

```elixir
defmodule MyApp.OrderRoutes do
  use Spectre.Router
  flow :orders do
    pipe_through :normalize
    router via: [:regex, :binary], accept: 0.9
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
    route :help, match: [binary: "help"]
  end
end

defmodule MyApp.BinaryMatcher do
  use Spectre.Router.Adapter
  @impl true
  def evaluate(request, _opts) do
    {:ok, for(rule <- request.rules, rule.data === request.input,
      do: result(rule, 1.0))}
  end
end

# Inside the Agent:
# router MyApp.OrderRoutes
# adapter :router, :binary, MyApp.BinaryMatcher
```

Prepare pipelines once with `Spectre.Input.Pipeline.new/2`; pass them as
`adapters: [pipelines: [normalize: pipeline]]`. Each flow has its own policy;
the host selects the flow rather than the library guessing among several.
Handlers see `{flow, route, captures}`, `{flow, :no_match, input}`,
`{flow, :ambiguous, refs}`, `{flow, :error, reason}`,
`{flow, :halted, input}`, or `{flow, :unrouted, input}`.

Matcher order and thresholds use the existing Router algebra. A skipped
optional method differs from corrupted data or callback failure. Methods see
only their own rule data and explicit input, not the Scope or executor.
Selected-route provenance is recorded as derived Evidence against the Turn;
it still carries no permission to execute.

## Stack and Extension

`use Spectre.Stack` creates a reusable configuration plan. An Agent uses
`stack: MyApp.Shared`; a local replacement of an inherited declaration requires
`override: true`. Stack does not resolve dependencies or start processes.

`install Package do ... end` calls that package's `Spectre.Extension.configure/1`
at compile time. It returns portable data and named adapter ports. No package
can contribute a new runtime, credentials, implicit authority or an installer.

`ports/0` is the single manifest for authoring and Doctor. A statically declared
module/options pair is already wired; the host supplies only missing resources.
Runtime options cannot silently replace fixed semantic options. Component
bindings use names such as `"faq/history/chat"`; in grouped startup options,
use `history: %{"faq/chat" => {MyApp.History, ...}}`.

## Prompts and injection

```elixir
# Inside Agent or Stack:
prompt_root Path.join(__DIR__, "prompts")
prompt :system, file: "support.text.eex"
prompt :question, "Order <%= @order_id %>: <%= @question %>"
prompt :safety, "A draft is not a delivered answer."
inject :safety, into: :system, position: :start

ask :answer,
  class: "model.generate",
  prompt: :system,
  task: :question,
  via: :inference,
  max_tokens: 300
```

Templates are compiled EEx (`.text.eex` or `.txt.eex`), not Phoenix HEEx or
runtime file lookups. Paths are build dependencies. Injection order is Agent,
flow, route within the selected start/end position. A route can declare
`inject: :safety`; flow blocks can use `inject` directly.

The plan preserves system/task/history/memory parts and template identities.
History/memory are data, not extra system instructions. Reserved context assigns
cannot be replaced by handler arguments. Rendering rejects missing assigns,
invalid UTF-8 or a combined budget above 64 parts / 65,536 text bytes.
It never formats an exception containing the complete assigns map.

`via: :inference` names an explicit `request/inference` adapter implementing
`Spectre.Agent.RequestBuilder.prepare/4`. Preparation performs no external
effect. Prism supplies such a bridge in its optional package; generation
still needs the host's Surface, executor and broker.

An inline inference plan becomes durable consequence data. For private material
that needs independent retention/erasure, use an application request adapter and
executor with protected payload references. Rendering alone does not store
private prompts safely or erase chat/backup copies.

## History and Memory

`history :chat, keep: 30, max_bytes: 24_000` declares a bounded chat window.
The host wires a `Spectre.History` backend with explicit tenant/conversation
binding. The backend limits the DB query before returning records. Each message
has ref, revision, role, status, content and Evidence references.

Loading does not save input or generated drafts. The host explicitly calls
`History.append/2`, `record_delivery/2`, `load_summary/1`, `save_summary/3`
and `erase/2` at appropriate points. Stable message IDs are idempotent;
a delivery receipt uses CAS and actual Evidence. A draft is never marked
delivered because generation completed. Summarization does not call a model
inside the store; it is a separate governed request when needed.

`memory :knowledge, limit: 5, max_bytes: 8_000` uses
`Spectre.Memory.retrieve/4` via its own tenant-bound adapter. Retrieved context
must cite available Evidence within the authenticated Turn. Chat windows do not
discard old Mandates, revocations or Duties from kernel evaluation.

## Semantic cache and classification

```elixir
# Inside Agent/Stack:
adapter :semantic_cache, :routing, Spectre.Router.SemanticCache.Exact,
  max_entries: 2_000
semantic_cache :routing, learn: :review

# Inside a flow:
# router via: [:regex, :semantic_cache], cache: :routing, accept: 0.9
# route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u], cache: true
```

The host supervises the backend with the same limits and binds it at startup:

```elixir
adapters = [
  semantic_cache: [
    routing: [server: MyApp.Cache, namespace: "tenant-a/support", profile_ref: nil]
  ]
]
```

Backend identity includes namespace, exact Definition, flow and encoder profile.
A server cannot be reused under a different binding. For multiple flows, Memory
backends accept `server: %{complete_binding => server_address}`; the host
creates those partitions explicitly.

The built-in bridge implements ordinary Router.Adapter. `via: [:semantic_cache]`
does not require a custom matcher; an explicit router-method binding may replace
the bridge. Exact lookup needs no vector. Vettore lives in the optional
`packages/spectre_semantic_cache_vettore` project; only the host adds that
dependency. It shares the same review/storage engine.

Lookup never accepts `embed:` or computes an embedding. Supply a precomputed
vector **and** its matching profile ref. The expected `:embedding_required`
becomes `:skip` in the default bridge; corruption/binding failures remain errors.
`put/update/verify/delete` use quarantined examples and exact revision checks.
Pages are bounded; snapshot restore requires a fresh destination. Host backups
and deletion policy remain separate responsibilities.

With `learn: :review`, a cache-enabled route can save one quarantined example
after a confirmed request/ask result. It never promotes it, learns from ambiguity,
or self-learns from a cache hit. Storage failure cannot retry the business effect.

For external classification, declare a classifier with a class and request-port
`via`, and select `via: [..., :llm_classifier], classifier: :intent`.
No match may return `{:classify, :intent, input, state}`. Only after its governed
Outcome may `route_result(turn, result)` nominate the originating flow's declared
labels. It does not resubmit the next business request. Local classifiers
implement Router.Adapter and use `:local_classifier`; artifacts/loading/training
belong to the host.

## Skills, Worker/Vigil and Morph

`skill MyApp.Faq, as: :faq` mounts a component with its own substate in the same
Instance. Publish its exact Definition under `components: %{faq: faq_definition}`.
Route into it with `flow: "faq/questions"`; callbacks/results return to that
component. A Skill never receives a second authoritative budget.

Reusable `use Spectre.Worker` and `use Spectre.Vigil` modules implement
`handle_work/3` or `handle_vigil/3` plus `handle_result/4`.
Declare `worker :name, Module` / `vigil :name, Module` in the Agent.
`Agent.start_worker/start_vigil` require explicit input, published Definition,
host DynamicSupervisor and an ordinary governed opening bundle
(`context`, `attributes`, `candidate`, optional `options`).
No Scope is created from a bare string; failed startup does not silently close
the durable promise. Timers, trigger registration and scheduling belong to the
application.

Morph still prepares a new Definition; `Spectre.revise_definition/4` governs
activation. Deployment, substate migration and re-authentication are host work.
Active Instances remain pinned to the old Definition and loaded code fingerprint.
They never silently follow the latest head. This detects accidental upgrades,
not hostile code in the same BEAM.

## Instance lifecycle and checkpoint

One Instance owns the last completed state. A temporary worker performs slow
mutations; the bounded FIFO defaults to 32 waiting operations. Pure
`state/info/scope/current_turn` reads remain responsive and accept a timeout,
including `:infinity`. Returned local state is not a world-effect receipt.

`advance` waits 5 seconds by default, or a supplied `wait:`, then reports the
known pending ref. That is not cancellation. Completed results retain at most
64 entries; pending operations are not silently evicted. New input supersedes
unsubmitted tickets, not already committed effects.

Domain loss stops the Instance. Restart with fresh authentication and an
appropriately governed Scope; a stale child-spec Scope is not renewable.
`Instance.checkpoint/4` stores portable local state and Skill substate via the
application store. It does not save Scope authentication, resumable request
tickets, Grants or a projection checkpoint. It never replays an executor.

The complete compile-only example is [examples/authoring.exs](../examples/authoring.exs).
Its host bindings are intentionally explicit, not a generated sandbox.

## Check fixed declarations against a Surface

`Spectre.Surface.verify_definition/2` validates fixed template declarations and
reports deferred occurrence facts. It is not kernel admission. Use
`mix spectre.routes MyApp.Agent` to inspect flow/route sources, policy, prompt
injection and ports. Extend the existing Doctor configuration with actual
`port_wiring`; these diagnostics do not prove external identity or safety.
