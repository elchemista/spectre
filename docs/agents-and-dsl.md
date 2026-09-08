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

Read this guide as a progression: one handler → a flow → an optional model
request → reusable components. You do not need a Stack, Skill or LLM to start.
For alternatives with complete callback code, see [recipes](agent-recipes.md).
For defaults and the meaning of each keyword, see [configuration](configuration.md).

## A small Agent

<!-- spectre:example guide_agent -->
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
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

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

Here `:orders` is the group of interactions, `:lookup`/`:help` are handler
branches and `"orders.lookup"`/`"support.help"` are governed action classes.
They are not interchangeable names. Named regex captures give `%{"id" => "42"}`;
string-bag matching compares the input to example strings, not to embeddings.
`accept: 0.85` is a routing-score threshold; `margin: 0.05` requires the winning
nomination to lead the runner-up by at least 0.05. A tie is not broken at random.

`_turn` is the correlated authenticated input/context; `_` means this handler
does not need to inspect it. `state` is your component's local value, not the
ledger or a budget. Returning an updated state does not attest an external fact.

Publication time is explicit; compiling a module never chooses a new revision
or activates it. Publish the Definition through the governed revision path.
After the host has provisioned the Domain, published the Definition and opened
an authenticated Scope:

<!-- spectre:example guide_instance -->
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
  {:ok, next_turn} -> {:completed, next_turn.result}
  {:pending, ref} -> {:watch, ref}
  {:error, reason} -> {:failed, reason}
end
```

These are host-wiring fragments, not a permissive foundation. `class_bindings`
maps each class to its explicit Candidate occurrence bindings: Mandate,
executor/contract, accountable parties, purpose and other required coverage.
The DSL derives Row from the current Surface, not from a `row:` option.
Consequence contracts can derive target/disclosure/Meter bindings; missing or
conflicting facts are errors, never authority defaults.
For these examples the host Surface binds `orders.lookup`'s `order_id` and
`support.help`'s `target_ref` as consequence targets. The host Mandate still has
to cover the exact requested order/help target; a matching regex grants nothing.
The final tuple is for the application's UI; it does not deliver content or
retry an operation. The tests supply explicit host fixtures to execute these
fragments, not a library-generated permissive foundation.

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

The names line up this way: handler `{:request, ...}` → prepared Instance ticket
→ `advance` → ordinary `Spectre.propose` → governed result → `handle_result`.
`ask` and `classify` use that same path after preparing model-specific data.
The application chooses whether to advance immediately or after approval.
Do not call the provider in `handle_turn` or in a request-preparation adapter
when its effect belongs to your governed Surface.

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

<!-- spectre:example extracted_router -->
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

defmodule MyApp.RoutedOrders do
  use Spectre.Agent, namespace: "shop", name: "routed-orders"
  router MyApp.OrderRoutes
  adapter :router, :binary, MyApp.BinaryMatcher

  @impl true
  def handle_turn({:orders, :help, _captures}, _turn, state),
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn(event, _turn, state), do: {:error, {:unhandled_route, event}, state}
end
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

Use a Stack when several agents share prompt instructions or adapter choices.
It is like reusing application configuration, not installing a new agent engine.
A Skill instead reuses behavior and local substate; use whichever problem you
actually have. [The component recipe](agent-recipes.md#reusable-skills-workers-and-vigils)
shows both together.


`use Spectre.Stack` creates a reusable configuration plan. An Agent uses
`stack: MyApp.Shared`; a local replacement of an inherited declaration requires
`override: true`. Stack does not resolve dependencies or start processes.

`install Package do ... end` calls that package's `c:Spectre.Extension.configure/1`
at compile time. It returns portable data and named adapter ports. No package
can contribute a new runtime, credentials, implicit authority or an installer.

`ports/0` is the single manifest for authoring and Doctor. A statically declared
module/options pair is already wired; the host supplies only missing resources.
Runtime options cannot silently replace fixed semantic options. Component
bindings use names such as `"faq/history/chat"`; in grouped startup options,
use `history: %{"faq/chat" => {MyApp.History, ...}}`.

## Prompts and injection

A prompt is a named template. An injection adds another named template around
the selected base prompt. An ask renders those parts into a model request.
None of those declarations contacts a model on its own.


<!-- spectre:example prompts -->
```elixir
# Inside Agent or Stack:
prompt_root Path.expand("../examples/prompts", __DIR__)
prompt :system, file: "answer.text.eex"
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
This guide's path uses the shipped example template. In an application, choose
the directory relative to the Agent/Stack source file, for example
`prompt_root Path.join(__DIR__, "prompts")`.

The plan preserves system/task/history/memory parts and template identities.
History/memory are data, not extra system instructions. Reserved context assigns
cannot be replaced by handler arguments. Rendering rejects missing assigns,
invalid UTF-8 or a combined budget above 64 parts / 65,536 text bytes.
It never formats an exception containing the complete assigns map.

`via: :inference` names an explicit `request/inference` adapter implementing
`Spectre.Agent.RequestBuilder.prepare/4`. Preparation performs no external
effect. A Prism integration must supply such a bridge; its separate 0.4
migration is still pending. Generation still needs the host's Surface,
executor and broker.

An inline inference plan becomes durable consequence data. For private material
that needs independent retention/erasure, use an application request adapter and
executor with protected payload references. Rendering alone does not store
private prompts safely or erase chat/backup copies.

## History and Memory

History answers “what was said in this conversation?”. Memory answers “what
relevant knowledge should this turn see?”. Neither answers “what is this
agent allowed to do?”—that belongs to the Domain's governed facts.


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

For a chat backend, the message fields are not arbitrary JSON:

| Field | Meaning |
| --- | --- |
| `ref` | Stable message identity chosen by the host; reuse only for the same message |
| `revision` | Nonnegative integer for exact concurrent-update checks |
| `role` | `:user`, `:assistant` or `:tool` |
| `status` | `:received`, `:draft`, `:delivered`, `:failed` or `:unclear`; generation alone only establishes a draft |
| `content` | Valid UTF-8 text, returned as data rather than evaluated prompt source |
| `evidence_refs` | References to the recorded facts supporting this context |

The usual sequence is: observe input → explicitly append the received message;
govern inference → explicitly save a draft; govern delivery → record its actual
receipt with `record_delivery`. The delivery receipt names `message_ref`, its
`expected_revision`, its own stable `ref`, delivery `status` and supporting
`evidence_refs`. This prevents a generated answer from being logged as sent
just because the model returned successfully.

Host wiring uses `history: [chat: {YourHistoryBackend, tenant_id: tenant,
conversation_id: conversation}]` inside Instance `adapters`. The backend must
implement `load/3`, `append/3`, `record_delivery/3`; summaries and erasure are
optional callbacks. Spectre supplies the contract, **not a bundled chat database**.
Implement it over your Repo/application store and enforce partition/limits in
the query. Loading protected context is not permission for unmediated remote I/O.

`memory :knowledge, limit: 5, max_bytes: 8_000` uses
`Spectre.Memory.retrieve/4` via its own tenant-bound adapter. Retrieved context
must cite available Evidence within the authenticated Turn. Chat windows do not
discard old Mandates, revocations or Duties from kernel evaluation.

## Semantic cache and classification

<!-- spectre:example exact_cache_declaration -->
```elixir
# Inside Agent/Stack:
adapter :semantic_cache, :routing, Spectre.Router.SemanticCache.Exact,
  max_entries: 2_000
semantic_cache :routing, learn: :review

flow :support do
  router via: [:regex, :semantic_cache], cache: :routing, accept: 0.9
  route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u], cache: true
end
```

The host supervises the backend with the same limits and binds it at startup:

<!-- spectre:example cache_wiring -->
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
the bridge. Exact lookup needs no vector. `Spectre.SemanticCache.Vettore` is
included in Spectre and shares the same review/storage engine; the host adds
`{:vettore, "~> 0.3.5"}` only when choosing that backend. There is no separate
Spectre cache package and no transitive Vettore or embedding dependency.

<!-- spectre:example native_cache_declaration -->
```elixir
# Inside Agent/Stack: replace Exact with the supplied native-index adapter.
adapter :semantic_cache, :routing, Spectre.SemanticCache.Vettore,
  max_entries: 2_000, dimensions: 384
```

The host supervises the matching child, without any implicit startup:

<!-- spectre:example native_cache_child -->
```elixir
{Spectre.SemanticCache.Vettore,
 name: MyApp.Cache,
 namespace: "tenant-a/support",
 definition_ref: published_definition.ref,
 flow: "support",
 labels: ["support/lookup"],
 profile_ref: encoder_profile.ref,
 dimensions: 384,
 max_entries: 2_000,
 index: :flat}
```

Wire the same namespace and encoder `profile_ref` to the Instance. Native search
supports `:flat` and `:hnsw`; both use normalized cosine vectors. Starting this
adapter without Vettore returns `{:error, {:adapter_module_not_loaded, Vettore}}`.
The Spectre test suite uses `vettore` and `ex_fastembed` as **test-only**
dependencies; it exercises actual model-generated vectors as well as native
index boundaries. They are not needed to compile or run Spectre itself.

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

For the complete classifier handler—including low scores and ambiguity—see
[the classifier recipe](agent-recipes.md#a-classifier-before-the-business-handler).
For the difference between router `via`, ask `via`, and a model identifier,
see [model configuration](configuration.md#ask-and-classifier-declarations).

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

Morph changes use `:test` (exact precondition), `:put` or `:delete` with a
`path` into maps or zero-based list indexes and, where needed, `value`.
`prepare/3` returns a new Definition or rejects the whole changeset; `diff/2`
prepares reviewable changes and `rollback/3` creates a **new forward revision**
from an earlier body. It does not rewind the ledger. A data change to a compiled
Agent plan must still match its newly published code; Morph is not a way to
hot-swap prompt code in an Instance without the normal publication checks.

## Instance lifecycle and checkpoint

One Instance owns the last completed state. A temporary worker performs slow
mutations; the bounded FIFO defaults to 32 waiting operations. Pure
`state/info/scope/current_turn` reads remain responsive and accept a timeout,
including `:infinity`. Returned local state is not a world-effect receipt.

`advance` waits up to 5 seconds by default, or a supplied `wait:`, then reports
the known pending ref. That is not cancellation. If the proposal itself returns
pending, its worker is released immediately: no background polling is started.
`operation/3` can refresh that same durable occurrence once and continue the
handler, without resubmitting an effect. A slow executor still needs its own
host-configured timeout; `wait:` does not stop it.

Retention keeps the last 64 completed or deferred operations, plus active/queued
work. A forgotten ticket does not imply that its effect never occurred; query
the ledger's durable facts. New input supersedes unsubmitted tickets, not
already committed effects. If a deferred result completes after a newer turn,
`operation/3` returns `{:error, {:instance_continuation_superseded, result}}`:
the result remains available, but its old handler cannot overwrite newer state.

Domain loss stops the Instance. Restart with fresh authentication and an
appropriately governed Scope; a stale child-spec Scope is not renewable.
`Instance.checkpoint/4` stores portable local state and Skill substate via the
application store. It does not save Scope authentication, resumable request
tickets, Grants or a projection checkpoint. It never replays an executor.

The [complete modular example](agent-recipes.md#a-complete-modular-authoring-example)
is also shipped as `examples/authoring.exs`.
Its host bindings are intentionally explicit, not a generated sandbox.

## Check fixed declarations against a Surface

`Spectre.Surface.verify_definition/2` validates fixed template declarations and
reports deferred occurrence facts. It is not kernel admission. Use
`mix spectre.routes MyApp.Agent` to inspect flow/route sources, policy, prompt
injection and ports. Extend the existing Doctor configuration with actual
`port_wiring`; these diagnostics do not prove external identity or safety.
