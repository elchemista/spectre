# Implementing Spectre extensions

Spectre exposes small contracts for applications and libraries to implement.
Start with the family that owns the work: a Server handles conversation, a
router adapter supplies recognition evidence, a model completes prompts, and an
installed package supplies tools or execution adapters. Storage and standalone
GAM hosts have separate contracts.

This catalogue covers all 52 public modules declaring `@callback` in core.
There are no public `@macrocallback` contracts. A module with functions named
`classify` or `embed` is not automatically an Elixir behaviour: the
[convention-based APIs](#module-apis-without-an-elixir-behaviour) are identified
separately. Satellite libraries can expose additional contracts in their own
documentation.

For application callbacks, go directly to [Server callbacks in dispatch order](SERVER_CALLBACKS.md). Use this catalogue when implementing an adapter or extending the runtime.

## Choose a contract

| What you are building | Contract family | Guide |
| --- | --- | --- |
| Conversation callbacks, pending work and continuations | [Server](#server-callbacks) | [AgentServer](AGENT_SERVER.md) |
| Recognition evidence, pipeline stages or route selection | [Routing](#routing-and-recognition) | [Routing](ROUTING.md) |
| Model completion, selection, embeddings or streaming | [Inference](#models-inference-and-text-boundaries) | [Providers](PROVIDERS.md), [streaming](STREAMING_INFERENCE.md) |
| Reusable tools and registered effects | [Stack packages](#stack-packages-tools-and-effects) | [Stack](STACK.md), [tools](STACK_TOOLS.md) |
| Conversation persistence, content storage or recovery policy | [Storage](#storage-payloads-and-recovery) | [Domain storage](DOMAIN_STORAGE.md), [payload storage](PAYLOAD_STORAGE.md) |
| External approval or durable result delivery | [Host integrations](#approval-and-result-delivery) | [External approvals](EXTERNAL_APPROVALS.md), [integrations](INTEGRATIONS.md) |
| A standalone governed host outside AgentServer | [Advanced GAM](#advanced-standalone-gam-host-contracts) | [GAM](GAM.md) |
| An existing Instance/Run, Work/Vigil or definition-evolution integration | [Retained contracts](#retained-instance-run-and-definition-contracts) | [Compatibility](COMPATIBILITY.md) |

Every behaviour below names its public API module, whose documentation includes
the callback types. Linked fixtures show complete bindings and failure cases.
**Required** means required by the Elixir behaviour. **Optional** means listed
in `@optional_callbacks`; a feature can still require an optional callback when
enabled. A `use` macro may provide implementations of required callbacks.
Declare `@impl true` when implementing a real callback. Use ordinary `@spec`
annotations for convention-based APIs; inventing an `@behaviour` does not make
those APIs implementable behaviours.

## Server callbacks

`Spectre.Server` is the application behaviour for
the conversation owner. `use Spectre.Server` declares it, imports helpers and
provides overridable defaults. The runtime owns the actual GenServer; the
callback module does not start another process.

| Callbacks | Return and purpose |
| --- | --- |
| `init/2` | `{:ok, ctx}`, `{:ok, ctx, init_option}`, `:ignore` or `{:stop, reason}`; initialize application state. |
| `handle_flow/3`, `handle_pending/3`, `handle_result/3`, `handle_skill/3` | An updated `Spectre.Server.Context`; select the next conversational step. |
| `handle_action/2` | `:default`, `:confirm`, `{:confirm, policy_context}` or `{:reject, reason}`; refine business policy before a governed proposal. |
| `handle_call/3`, `handle_cast/2`, `handle_info/2`, `handle_continue/2` | Native OTP callback tuples with `Context` as state. |
| `terminate/2`, `code_change/3`, `format_status/1` | Cleanup result, `{:ok, ctx} \| {:error, reason}`, and status map respectively. |
| Optional `handle_approval_inbox/2` | `:default` or an updated context; react to an external-approval inbox event. |
| Optional `assigns_schema/0`, `continuation_contracts/0` | `nil` or maps of schemas for durable assigns and continuation results. |

All callbacks other than the final two rows are formally required; `use`
supplies them. Override only the application paths you need, retaining default
handling with `super` when adding clauses to a callback.

```elixir
defmodule MyApp.HelpServer do
  use Spectre.Server

  @impl true
  def init(_arg, ctx), do: {:ok, assign(ctx, :requests, 0)}

  @impl true
  def handle_flow({:support, :help}, _input, ctx) do
    ctx
    |> assign(:requests, ctx.assigns.requests + 1)
    |> respond("Ask about pricing or your account.")
  end

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Please describe the help you need.")
end

defmodule MyApp.HelpAgent do
  use Spectre.Agent, server: MyApp.HelpServer
  router strategies: [:regex]

  flow :support do
    on :help, regex: ~r/\bhelp\b/i
  end
end
```

Start it with `Spectre.Server.start_link(agent: MyApp.HelpAgent, consumer:
self())`; submit input through `Spectre.Server.input/3`. Replies arrive at the
consumer asynchronously. Helpers such as `generate`, `classify`, `propose` and
installed tools return commands in the Context. Worker results reach
`handle_result/3` using the requested `on_result:` tag. Keep live handles in
`ctx.private`; durable assigns and result tags must be portable data.

See the [executable quickstart](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/examples/agent_server_quickstart.exs),
[pending lifecycle](PENDING_LIFECYCLE.md), [Skills](SKILLS.md) and
[application contracts](SERVER_CONTRACTS.md). Governing an operation still
requires a registered effect, enabled authority and admission; a callback name
does not authorize direct external effects.

## Routing and recognition

Routing evidence and the final route decision have different extension points.
Prefer a native Adapter for an additional evidence source. A Plug operates on
the complete router context, and an Arbitrator chooses among collected evidence.

| Behaviour | Required callbacks | Optional callbacks | Wiring, result and example |
| --- | --- | --- | --- |
| `Spectre.Router.Adapter` | `evaluate/1` | None | Put the module in `router strategies: [...]`. Return `{:ok, result_or_results}`, `:skip`, `{:skip, reason}` or `{:error, reason}`. Results reference visible rules and carry scores; at most 32 distinct rule refs. [Adapter guide](ROUTING.md#native-router-adapter). |
| `Spectre.Router.Plug` | `init/1`, `call/2` | None | Put modules or `{module, opts}` in `router pipeline: [...]`, or use `Spectre.Pipeline`. Return `{:cont, ctx}`, `{:halt, ctx}`, `{:inference, prepared}` or `{:error, reason}`. Explicit pipelines own arbitration/terminalization ordering. [Pipeline examples](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/ROUTING_0_3.md#configuration). |
| `Spectre.Router.Arbitrator` | `decide/2` | None | Configure `arbitrator: Module` or `{Module, opts}` in router options. Return `{:ok, route}`, `{:llm, arbitration}`, `{:clarify, text}` or `{:error, reason}`. [Arbitration reference](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/ROUTING_0_3.md). |
| `Spectre.Router.SemanticCache` | `lookup/2` | `put/3`, `examples/2`, `get_example/3`, `relabel/4`, `update_example/4`, `delete/3`, `verify/3`, `snapshot/2`, `load_snapshot/3`, `clear/2` | This remains the custom IntentDataset/semantic-lookup behaviour. `intent_dataset MyApp.Dataset, opts` selects a module. Lookup returns `{:ok, route_map}` or `{:error, reason}`; administrative methods use the declared success/error shapes. [Dataset setup and review](TRAINING.md), [adapter fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/semantic_cache_contract_test.exs). |
| `Spectre.Classifier.Embedding` | `load/2`, `embed/2` | `download/2` | The local classifier encoder selects it with `embedding_adapter:`. Load/download return `{:ok, positive_dimensions}`; embed returns `{:ok, float_vector}`; all may return `{:error, reason}`. [Training](TRAINING.md), [built-in adapter](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/classifier/embeddings/ex_fastembed.ex). |

The historical detailed routing guide contains retained handler examples; its
low-level Plug, Adapter and Arbitrator contracts are still shared by 0.4.
`Spectre.IntentDataset` is the public dataset facade, not another behaviour.
Implement only the optional administrative operations your adapter supports;
the facade reports unsupported operations. Do not configure the dispatching
`Spectre.Router.SemanticCache` module as its own adapter.

This deterministic Adapter needs no service or model. It only scores examples
declared under its own adapter id:

```elixir
defmodule MyApp.ExactExamples do
  use Spectre.Router.Adapter,
    id: :exact_examples, accept: 1.0, strength: :strong

  @impl true
  def evaluate(%Spectre.Router.Adapter.Request{text: text, rules: rules}) do
    matches =
      rules
      |> Enum.filter(fn rule -> text in examples(rule) end)
      |> Enum.take(32)
      |> Enum.map(&result(&1, 1.0))

    {:ok, matches}
  end
end

defmodule MyApp.ExampleServer do
  use Spectre.Server

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx),
    do: respond(ctx, "Choose a pricing plan.")

  def handle_flow(route, input, ctx), do: super(route, input, ctx)
end

defmodule MyApp.ExampleAgent do
  use Spectre.Agent, server: MyApp.ExampleServer
  router strategies: [MyApp.ExactExamples]

  flow :support do
    on :pricing, exact_examples: ["price", "plans"]
  end
end
```

The core resolves refs against visible rules and performs arbitration. An
adapter cannot supply an executable handler or select an undeclared route.
Use [Adapter conformance](TESTING.md) and [routing evaluation](EVALUATION.md)
when replacing a recognition provider.

## Models, inference and text boundaries

| Behaviour | Required callbacks | Optional callbacks | Wiring, result and example |
| --- | --- | --- | --- |
| `Spectre.LLM` | `complete/2` | `complete_plan/2` | `model MyApp.Model, opts` binds synchronous completion; `classifier :llm, MyApp.Model, opts` binds classifier completion. Return `{:ok, text_or_response}` or `{:error, reason}`. `complete_plan/2` receives a typed `Spectre.Prompt.Plan`; otherwise the module receives its serialized string. [Providers](PROVIDERS.md), example below. |
| `Spectre.Inference.Selector` | `select/4` | None | Bind the role through `Spectre.Integration.service/4` or an installed Extension such as Prism. Receive request, profiles, `Spectre.Context` and options. Return `{:ok, Spectre.Inference.Selection.t()}` or `{:error, reason}`. [Configure selection](PROVIDERS.md#select-a-model-from-the-stack). |
| `Spectre.Inference.StreamAdapter` | `capabilities/2`, `open/2`, `handle_transport/2`, `cancel/2` | `request_transport_item/1`, `resume/3`, `reconcile/3`, `conformance_fixture/4` | Configure `stream_adapter:` with the provider binding. Capabilities are a `MapSet`; open/resume return state and metadata; transport returns normalized `ProviderEvent` batches, ignore or error. Pull transport requires its demand callback; declared resume/reconcile capabilities require the corresponding callbacks. [Streaming contract and examples](STREAMING_INFERENCE.md), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/inference_stream_contract_test.exs). |
| `Spectre.Input.Plug` | `init/1`, `call/3` | `rehearsable?/0` | Install with `input_pipeline`. Return `{:cont, input}`, `{:halt, input}` or `{:error, reason}`. Input is normalized/enriched before downstream processing. [Input pipeline](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/DSL_0_3.md#input-pipeline), example below. |
| `Spectre.Reply.Sanitizer` | `sanitize/2` | `init_stream/1`, `sanitize_chunk/2`, `finish_stream/1` | Configure `reply_sanitizer: Module` or `{Module, opts}`. Terminal cleanup returns a string. Streaming needs all three optional callbacks, returning initialized state, text/state chunks and terminal text. [Sanitizer example](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/STREAMING_INFERENCE_0_3.md#optional-sanitizer-extensions), [fixtures](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/reply_sanitizer_test.exs). |
| `Spectre.Server.PublicProjection` | `init/1`, `push/2`, `finish/1` | None | Configure `public_projection: Module` or `{Module, opts}` on generation. Return `{:ok, state}`, `{:ok, public_utf8, state}` and `{:ok, public_utf8}` respectively, or errors. The host vouches for a public projection consistent with the terminal planning result. [Server streaming](STREAMING_INFERENCE.md), [projection fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/planning_boundaries_test.exs). |

An application can implement a small synchronous model directly:

```elixir
defmodule MyApp.FixedModel do
  @behaviour Spectre.LLM

  @impl true
  @spec complete(String.t(), keyword()) :: {:ok, String.t()}
  def complete(_prompt, _opts), do: {:ok, "A deterministic response."}
end

defmodule MyApp.ModelAgent do
  use Spectre.Agent
  model MyApp.FixedModel
end
```

This is a deterministic fixture. A network adapter should translate options
with `Spectre.LLM.provider_opts/2`, preserve deliberate provider errors, and
return valid completion data. `Spectre.Provider.Call` is the invocation facade,
not an implementable behaviour. See [provider deadlines and failure
semantics](PROVIDERS.md) before adding SDK calls or retries.

An input plug can attach portable metadata without changing recognition:

```elixir
defmodule MyApp.LocalePlug do
  @behaviour Spectre.Input.Plug

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :locale)

  @impl true
  def call(input, _context, locale),
    do: {:cont, Spectre.Input.put_meta(input, :locale, locale)}

  @impl true
  def rehearsable?, do: true
end

defmodule MyApp.LocaleAgent do
  use Spectre.Agent
  input_pipeline [{MyApp.LocalePlug, locale: "en"}]
end
```

Declare `rehearsable?/0` only for a deterministic plug that has no external
effects and does not depend on host-only callback context or turn options.
Streaming adapters enforce resolved transport/parser bounds, bounded demand
and sequence/usage rules; implement `conformance_fixture/4` when claiming
stream conformance. A custom sanitizer runs after structural cleanup, may
suppress text and must not expand it. PublicProjection is a separate planning
stream port; it does not execute proposals. Server and retained Instance
streaming have different ownership/restart semantics even when sharing an adapter.

## Module APIs without an Elixir behaviour

These supported bindings use functions and data contracts rather than a
dedicated `@callback` module. Keep their `@spec`s in application code and use
the corresponding adapter/provider guide for validation and configuration.

| API | Functions and wiring | Result and boundary |
| --- | --- | --- |
| Local classifier | `classify(text, opts)`; bind with `classifier :local, Module, opts`. Functions and `{module, function}` bindings are also supported by `Spectre.Router.LocalClassifier`. | `{:ok, route_map}` or `{:error, reason}`. An accepted result needs a declared label, boolean `accepted?` and numeric scores; see [provider validation](PROVIDERS.md#reply-validation) and [training](TRAINING.md). There is no `Spectre.Classifier` behaviour. |
| Router embedding | `embed(text, opts)`; bind with `embedding Module, opts`. The encoder also accepts supported function/tuple forms and one-argument functions. | `{:ok, nonempty_numeric_vector}` or `{:error, reason}`. The training encoder's `Spectre.Classifier.Embedding` above is a distinct actual behaviour with model loading. See [routing](ROUTING.md) and [encoder dispatch](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/classifier/encoder.ex). |
| Server cognitive services | Server startup `services: [generate: Module, classify: Module]` binds each module's `generate/3` or `classify/3`; a `{module, function}` binding is also supported. Receive request, service context and options. | Generation returns `{:generated, %{text: text, ...}}`; classification returns `{:classified, label}`; failures use `{:error, reason}`. These are worker service APIs, not replacement Server or GAM behaviours. See [service wiring](AGENT_SERVER.md), [fixtures](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/services_test.exs). |
| Automatic memory bridge | `memory MyApp.Memory, opts` binds `recall(text, opts)`; persistence checks `remember/4`, `persist/4`, `remember/2`, then `persist/2`. Four-argument forms receive input, result, Agent and options; two-argument forms receive a portable payload and options. | Recall returns `{:ok, memory}` or `{:error, reason}`; persistence accepts `:ok`, `{:ok, value}` or `{:error, reason}`. This bridge remains available, but application writes need an explicit governance audit. Prefer installed Mnemonic tools for explicit recall/write commands. [Memory guide](MEMORY.md#existing-automatic-memory-adapters). |
| Tool adapter | `prepare/3`, `project/2`, plus `invoke/3` for cognitive operations; selected by a package's `tools/1` descriptor. | Preparation returns `{:ok, args}` or error; projection returns `{:ok, portable_result}` or error. Governed preparation yields a map and becomes a proposal. See [Stack tools](STACK_TOOLS.md#package-descriptor-and-adapter-contract). |
| Checkpoint migration | `checkpoint_migrator: {Module, :migrate}` supplies `migrate/2`. | Receive saved projection and fingerprint metadata (`agent`, `server`, `schema_version`, `from`, `to`); return `{:ok, projection}`, `{:ok, projection, dispatch_key_map}` or an error, as described by [checkpoint migration](AGENT_SERVER.md#checkpoints-and-reconciliation) and its [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/checkpoint_route_migration_test.exs). It is not a storage behaviour. |

The completion behaviour is `Spectre.LLM`; the text output ports are Sanitizer
and PublicProjection. Model, memory and tool bindings may instead use the
convention-based APIs above. A `model` DSL declaration can also select a
compatible function/tuple binding without an Elixir behaviour implementation.

## Stack packages, tools and effects

| Behaviour | Required callbacks | Optional callbacks | Wiring, result and example |
| --- | --- | --- | --- |
| `Spectre.Stack.Installable` | `manifest/0` | `compile/3`, `integration/1`, `tools/1`, `effects/1`, `child_specs/2` | `install Package, opts` in a Stack. Manifest identifies the immutable package. Compile returns `{:ok, map_or_keyword}` or error. Integration returns a `Spectre.Integration` declaration. Tools and effects return descriptor maps. Child specs return identified specs, optionally wrapped in `{:ok, specs}`, or error. [Package authoring](STACK.md#installable-contract-v1). |
| `Spectre.Flow.Port` | `routes/0`, `handle_flow/3` | `handle_result/3` | Register a local scope with `Spectre.Integration.flow/3`. The Agent exposes that scope. Return a list of route declarations from `routes/0`. Selected handlers receive a local label, input and Context. Each handler returns Context. [Reusable flows](AGENT_SERVER.md#reusable-flows-and-targeted-answers). |
| `Spectre.Activity` | `handle_start/2` | `handle_signal/2` | Declare a module using `Spectre.Activity` in a Stack or a package integration. It receives the start arguments or signal and Context. Use the inherited Server result callback to continue commands. [Activity lifecycle](AGENT_SERVER.md#run-a-background-activity). |
| `Spectre.Extension` | None formally | `id/0`, `api_version/0`, `setup/2`, `compile/2`, `action_providers/1`, `action_planner/1`, `effect_executors/1`, `flow_constraints/2`, `inference_selector/1`, `agent_config/1`, `expand_handler/3` | An installable manifest's `agent_extensions:` registers these contributions automatically; explicit mounts remain compatible. Returns are immutable compilation data, lists/bindings of ports, normalized constraints or handler AST as declared. [Stack extension example](STACK.md#installable-contract-v1), [extension fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/stack_contract_test.exs). New packages publish Installable manifests; Agent owns its compile hook. |
| `Spectre.Server.GAM.EffectAdapter` | `execute_effect/3` | `effect_schema/2` | Register through `effects/1`, then enable the operation in Server `gam: [operations: ...]`. Execute receives the registered operation, frozen arguments and context. Return `{:ok, receipt}` or `{:error, :failed \| :definitive_no_effect \| :ambiguous, reason}`. Schema returns `{:ok, hash}` or error. [Effect registration](STACK_TOOLS.md#registered-execution-for-managed-gam), [complete fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/effect_boundary_test.exs). |
| `Spectre.Stack.PackageData` | `erasure_plan/2`, `erase_instance/2` | None | An installable that persists Instance-scoped data may additionally declare this behaviour. Return `{:ok, plan}` and `{:ok, outcome}`, or errors. This is the retained offline Instance-erasure integration, not automatic deletion on Server reset. [Package erasure](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/ERASURE.md#stack-package-data), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/stack_package_data_test.exs). |

The package below creates a pure cognitive tool. The adapter exposes
`prepare/3`, `invoke/3` and `project/2` as module functions. The package implements
`integration/1` and names those functions' adapter through `Integration.tool/4`.

```elixir
defmodule MyApp.UppercaseTool do
  @spec prepare(:convert, term(), map()) :: {:ok, String.t()} | {:error, atom()}
  def prepare(:convert, %{text: text}, _trusted) when is_binary(text), do: {:ok, text}
  def prepare(:convert, _value, _trusted), do: {:error, :text_required}

  @spec invoke(:convert, String.t(), map()) :: String.t()
  def invoke(:convert, text, _context), do: String.upcase(text)

  @spec project(:convert, String.t()) :: {:ok, String.t()}
  def project(:convert, text), do: {:ok, text}
end

defmodule MyApp.TextPackage do
  use Spectre.Stack.Installable,
    id: :text_tools, version: "0.1.0", spectre: "~> 0.4.1"

  @impl true
  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:convert, MyApp.UppercaseTool,
      args: [text: :string], retry: :safe, max_bytes: 65_536)
  end
end

defmodule MyApp.TextStack do
  use Spectre.Stack
  install MyApp.TextPackage
end

defmodule MyApp.TextServer do
  use Spectre.Server

  @impl true
  def handle_flow({:text, :uppercase}, input, ctx),
    do: call_tool(ctx, {:text_tools, :convert}, %{text: input.text}, on_result: :uppercased)

  def handle_flow(route, input, ctx), do: super(route, input, ctx)

  @impl true
  def handle_result(:uppercased, text, ctx) when is_binary(text),
    do: respond(ctx, text)

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

Bind `stack: MyApp.TextStack, server: MyApp.TextServer` on an Agent and add
`on :uppercase, regex: ~r/.+/` inside `flow :text` for a simple smoke test.
`:uppercase` is the route, `:convert` is the tool operation and
`:uppercased` is the callback tag. The adapter receives the text as a named
argument, produces a string, and sends that string through `project/2`.
`retry: :safe` allows interrupted pure work to repeat and `max_bytes:`
limits the size of prepared arguments and projected values. This adapter uses
only pure functions. For a client or pool, supervise a runtime and resolve the
expected resource from the worker. [All tool options and retries](STACK_TOOLS.md),
[billing example with an effect](CUSTOM_STACK_TOOLS.md).

## Storage, payloads and recovery

`Spectre.Server.Store` is the unified custom
storage behaviour. Configure `gam: [storage: {MyApp.Storage, reference}]`.
Every callback receives that same application-owned reference first; Spectre
does not start or stop the shared provider. Keep its pool/process in application
supervision. See [custom storage](DOMAIN_STORAGE.md#custom-storage) and the
[complete unified-store fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/unified_store_test.exs).

| Store callback group | Required/optional boundary and result |
| --- | --- |
| Coordination: `fetch/2`, `put_new/3`, `compare_and_swap/4`, `delete/3` | Required behaviour callbacks. Fetch returns `{:ok, %{revision: revision, value: value}}`, `:not_found` or error; writes acquire revisioned entries. CAS/deletion must fence the expected revision. |
| Namespace pages: `list/3` | Optional. Returns `{:ok, entries, cursor_or_nil}` or error using the Store entry shape; pages are bounded. |
| Canonical history: `ledger_append/6`, `ledger_load/3`, `ledger_head/3`, `ledger_read_batch/4`, `ledger_lookup_batch/4`, `ledger_export/3`; optional suffix optimization `ledger_load_from/4` | All are Elixir-optional so coordination-only adapters remain valid. Selecting the unified durable-history path requires the complete group except the suffix optimization. Results follow `ExGAM.Ledger.Store` with the provider reference prepended. |
| Projection: `projection_open/3`, `projection_head/3`, `projection_commit/6`, `projection_fetch/5`, `projection_page/5`, `projection_select/6` | Elixir-optional, but implement all six or none. Results follow `ExGAM.Domain.Projection.Store` with the provider reference prepended. Omitting the group retains the complete projection in RAM. |
| Resource bridges: `gam_domain/1`, `gam_ledger/1` | Optional. Return configured Domain resources/history bindings, `:not_configured` or errors. The explicit Domain bridge precedes unified callbacks, then the older history-only bridge. An actual storage error does not trigger fallback. |

The source types specify revision conflicts, ambiguous writes and exact page
shapes. `put_new/3` and CAS return `{:ok, revision}` or error; delete returns
`:ok` or error. Canonical append atomically persists a complete batch, fences
the expected revision and deduplicates batch ids. An uncertain acknowledgement
is `{:error, :ambiguous}`. Projection commits atomically advance the cursor with
their row changes; reads must use the exact generation and cursor. These are
three durability boundaries, not a single distributed transaction.

| Additional behaviour | Callbacks | Wiring, result and example |
| --- | --- | --- |
| `Spectre.Payload.Store` | Required `put/3`, `fetch/3`; no optional callbacks | Top-level `payload_store: {Module, opts}` on Server startup. Return `{:ok, opaque_portable_reference}` and `{:ok, original_value}`, or errors. The adapter chooses content storage and reference guarantees. [Payload guide](PAYLOAD_STORAGE.md), example below. |
| `ExGAM.Domain.Recovery.Policy` | Required `check/2`; optional `failed/2`, `recover/2` | Configure `recovery_policy:` in managed `gam:` options or standalone Domain options. Check returns `:ok` or error after verification; failed is a best-effort notification; recover returns `:wait`, `{:retry, milliseconds}` or `:memory`. [Recovery guide](DOMAIN_STORAGE.md#when-storage-disappears), [fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/recovery_policy_test.exs). |

A payload adapter can forward to an application-owned archive. This complete
module compiles without requiring a specific storage library; the supplied
archive module implements the indicated two functions.

```elixir
defmodule MyApp.Payloads do
  @behaviour Spectre.Payload.Store

  @impl true
  def put(value, context, opts) do
    archive = Keyword.fetch!(opts, :archive)
    archive.put(value, context)
  end

  @impl true
  def fetch(reference, context, opts) do
    archive = Keyword.fetch!(opts, :archive)
    archive.fetch(reference, context)
  end
end

defmodule MyApp.StorageRecovery do
  @behaviour ExGAM.Domain.Recovery.Policy

  @impl true
  def check(_verified_context, _opts), do: :ok

  @impl true
  def recover(_incident, _opts), do: {:retry, 1_000}
end
```

The archive's `put/2` returns `{:ok, reference}` and `fetch/2` returns
`{:ok, original_value}`; both may fail. Configure
`payload_store: {MyApp.Payloads, archive: YourArchive}`. Managed integration
passes encoded bytes and small routing contexts, and saved references must
remain resolvable after restart. Missing content is an error. Payload writes
and ledger writes have no automatic cross-store transaction.

Set `gam: [recovery_policy: MyApp.StorageRecovery, ...]` to use the example
policy. It deliberately schedules retry rather than repairing storage inside
the callback. `check/2` receives `%{domain_ref: ref, head: head_or_nil}`; a host
requiring existing history can reject a nil head. `:memory` explicitly creates
a distinct RAM Domain; it cannot reuse earlier consent or merge divergent
history into the repaired backend. See [reset and recovery](DOMAIN_STORAGE.md)
for their different session semantics.

## Approval and result delivery

| Behaviour | Callbacks | Wiring, result and example |
| --- | --- | --- |
| `Spectre.Server.GAM.Managed.Approval` | Required `send_message/2` | Configure the external approver transport in managed approval settings. Receive a portable approval message and options; return `{:ok, transport_receipt}` or `{:error, reason}`. Authentication, rendering acknowledgements and separate human decisions remain required. [External approval guide](EXTERNAL_APPROVALS.md), [executable example](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/examples/external_approval.exs). |
| `Spectre.Server.OutcomeDispatcher.Adapter` | Required `recover/3`, `deliver/4` | Explicitly supervise/configure an OutcomeDispatcher and track durable operations. Recover returns `{:ok, exact_event_revision, result}`, `:pending` or error; deliver returns `:ok` or error after receiver acquisition. Recovery reads recorded facts and never resubmits an effect. [Delivery/reconciliation guide](AGENT_SERVER.md#checkpoints-and-reconciliation), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/server/outcome_dispatcher_test.exs). |

These transports do not authenticate results merely by knowing an event id.
The recovery adapter reauthenticates/rebinds the right scope and must recover
the exact requested durable revision. Delivery can repeat after crashes and
requires receiver inbox deduplication. Installing a package alone does not
start an OutcomeDispatcher or choose its host bindings.

## Advanced standalone GAM host contracts

AgentServer manages its Domain, ingress and execution protocol automatically.
The following contracts serve applications building a **standalone GAM host**
through `ExGAM.start_domain/3` and related APIs. They are public host
ports, not alternate Server startup hooks. Their identity references, evidence
and capability boundaries must be preserved; helper macros supply identity
callbacks, not authentication, credentials or permissive execution defaults.

| Behaviour | Required callbacks; optional callbacks | Host binding and result | Example |
| --- | --- | --- | --- |
| `ExGAM.Ingress` | `ref/0`, `authenticate/5`, `observe/4` | Domain `ingress:`. Stable ref; authentication returns `{:ok, SubmissionContext}`; observation returns `{:ok, Evidence_or_list}`; failures return errors. Authentication cannot take its principal from a candidate payload. | [Authoring fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/adapter_authoring_test.exs), [ingress isolation](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/ingress_isolation_test.exs). |
| `ExGAM.Mind` | `ref/0`, `deliberate/2`; optional `deliberate/3` | Domain `mind:`. Stateless success is `{:ok, candidates}`; stateful success is `{:ok, candidates, next_state}`. Candidates remain proposals. `use ..., stateful: true` generates `/2` using nil state; never define default arguments that conflate the arities. | [Authoring fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/adapter_authoring_test.exs), example below. |
| `ExGAM.Attempt.Executor` | `executor_ref/0`, `contract_ref/0`, `execute/4` | Domain `executors:`. Receives committed Act, Attempt, short-lived capability and options. Return `{:ok, observation}` or `{:error, :failed \| :definitive_no_effect \| :ambiguous, observation}`. Observation contains validated evidence and an opaque nonempty `details_ref`. | [Executor fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/adapter_authoring_test.exs), [runner acknowledgement](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/runner_acknowledgement_test.exs). |
| `ExGAM.Attempt.Observer` | `observe/4` | Domain `late_observer:`. Independently inspect Act/Attempt/world input; return `{:ok, outcome_status, reference_or_nil, observation}` or error. It receives no execution capability. | [Late-observation fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/late_observation_test.exs). |
| `ExGAM.Secret.Broker` | `ref/0`, `profile/0`, `checkout/4` | Domain `broker:`. Declare the actual `:development`, `:mediated` or `:isolated` profile. Checkout returns `{:ok, short_lived_capability}` or `{:error, :ambiguous, failure_metadata}` containing evidence and `details_ref`; never a reusable credential. | [Broker fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/secret_broker_boundary_test.exs), [authoring helpers](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/adapter_authoring_test.exs). |
| `ExGAM.Genesis.Verifier` | `verify/2` | Domain `genesis_verifier:`. Verify the supplied authority root before boot; return `:ok` or error. Does not issue mandates. | [Standalone setup](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/lib/ex_gam.ex), [GAM fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/v0_4/support/fixture.ex). |
| `ExGAM.Definition.Verifier` | `verify/2` | Supply the verifier to `ExGAM.Surface.verify_definition/3`. Return `{:ok, definition_report}` or error for an immutable Definition/Surface. This is a static diagnostic, not admission. | [Verifier fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/definition_verifier_adapter_test.exs). |
| `ExGAM.Payload.Store` | `verify/2` | Standalone Domain `payload_store:`. Return `:ok` only after verifying presence and digest correspondence of `payload:<sha256>`; otherwise error, including `:not_found`. This differs from application `Spectre.Payload.Store.put/fetch`. | [Payload verifier fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/payload_store_contract_test.exs). |
| `ExGAM.Clock` | `now/0` | Domain `clock:`. Return a nonnegative governed timestamp; the sequencer persists its sample as decision input. | [GAM fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/v0_4/support/fixture.ex). |
| `ExGAM.Id.Source` | `generate/0` | Domain `id_source:`; direct callers can pass the source module to `ExGAM.Id.generate/1`. Return a valid UUIDv7 identifier. Identity and content refs have distinct purposes. | [Identifier source and configuration](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/lib/ex_gam/id.ex), [fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/v0_4/identity_and_content_ref_test.exs). |
| `ExGAM.Ledger.Store` | `append/5`, `load/2`, `lookup_batch/3`, `export/2`; optional `load_from/3`, `head/2`, `read_batch/3` | Domain `store:`. Append returns acquired revision or conflict/ambiguous/error; reads return snapshots/cursors, `:not_found` or error. Batches must be atomically visible, revision-fenced and deduplicated. Indexed batch paging is required for the projection-backed path. | [Storage guide](DOMAIN_STORAGE.md), [ledger fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/core/ledger_store_boundary_test.exs). |
| `ExGAM.Domain.Projection.Store` | `open/2`, `head/2`, `commit/5`, `fetch/4`, `page/4`, `select/5` | Domain `projection_store:`. Open returns generation handle; head returns handle/cursor or `:not_found`; commit returns `:ok`; fetch returns canonical row bytes by key; page/select return `{:ok, rows, cursor_or_nil}`; all may error. Cold startup rebuilds disposable rows from verified canonical batches. | [Projection storage guide](DOMAIN_STORAGE.md), [complete store fixture](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/test/gam/support/projection_store.ex). |

`ExGAM.Domain.Recovery.Policy` is also a standalone host port; its
callbacks and bounded execution are covered in [storage](#storage-payloads-and-recovery).
Unified Server.Store adapters can provide the last two resource contracts
through their prefixed callback groups instead of implementing separate modules.

A minimal capability-free Mind can deliberately decline to propose work:

```elixir
defmodule MyApp.QuietMind do
  use ExGAM.Mind, ref: "mind:quiet:v1"

  @impl true
  def deliberate(_turn, _opts), do: {:ok, []}
end
```

Set `mind: MyApp.QuietMind` when starting a standalone Domain whose remaining
host configuration is supplied as shown in the [GAM module
documentation](https://github.com/elchemista/ex_gam/blob/ffb026c8bc4ef0e91324e89c33b9f9a1274c75d1/lib/ex_gam.ex). `use` generates `ref/0`; proposals can be
built with `ExGAM.Mind.candidate/2` from the sealed Turn. A Mind receives
no grant, broker or ledger writer. For an application Agent/Skill, implement
Server callbacks and let the managed integration own these ports.

## Retained Instance, Run and definition contracts

These public behaviours support the earlier Instance/Run runtime, its
operations and definition-evolution system. They remain implementable for
existing clients. They use `Spectre.Context`/`State`, older policy/effect
decisions and their own persistence protocol; they are not substitutions for
the 0.4 Server Context, unified Store or GAM consent protocol.

### Actions, effects, operations and turn integration

| Behaviour | Required callbacks | Optional callbacks | Contract and dedicated guide/example |
| --- | --- | --- | --- |
| `Spectre.Action.Provider` | `execute/3` | `actions/1`, `schema_hash/2` | Register an action-provider mount through an Extension. Execution receives Action, legacy Context and options; discovery returns specs/list or error and must be side-effect free; schema hash returns string/nil, optionally inside `{:ok, value}`. [Action providers](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/ACTIONS_0_3.md), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/action_boundary_contract_test.exs). |
| `Spectre.Action.Planner` | `plan_response/3` | `plan/3`, `clean_reply/3`, `incremental_cleaner?/0` | Extension `action_planner/1` binds it. Plan-response returns `{:ok, %{reply_text: text, actions: actions}}` or error; optional plan returns one Action/map, cleaner returns text, capability returns boolean. This port is also used for installed planning integration; it never executes a proposal. [Actions](ACTIONS.md), [planning fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/action_boundary_contract_test.exs). |
| `Spectre.Effect.Executor` | `execute/3` | None | An Extension registers non-action effect mounts. Return outcome data, conventionally `{:ok, value}` or `{:error, reason}`; the retained execution runtime owns state/lifecycle. This differs from managed `Server.GAM.EffectAdapter`. [Executor fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/effect_executor_contract_test.exs), [migration](MIGRATING_TO_0_4.md). |
| `Spectre.Operation.Controller` | `__spectre_loop_definition__/0`, `init/2`, `next/2`, `apply_result/4`, `complete/2` | `apply_update/4`, `handle_trigger/3`, `budget_exhausted/3`, `checkpoint_compatible?/2` | Work/Vigil/operational controller reducers. Prefer `use Spectre.Work` or `use Spectre.Vigil`, which generate definition/default callbacks. Next returns run/wait/blocked/complete/error transitions; reducers return next data with optional intents; completion returns continue/false or terminal transitions. Definition callback is generated metadata, not an application hook to invent. [Controller contract and examples](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/OPERATIONS.md#controller-contract). |
| `Spectre.Turn.Handler` | `handle_turn/2` | None | Configure retained `turn_handler`/`turn_handlers`. Return `:cont`, `{:reply, %Spectre.Turn.Handler.Reply{}}` or error to temporarily own a legacy turn before routing. [Complete handler example](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/INTEGRATIONS_0_3.md#a-pre-route-turn-handler). |
| `Spectre.Turn.Dispatcher` | `deliver_reply/3` | `no_response/2`, `policy_request/3`, `satisfied_resolution/2`, `execute?/3`, `suppressed/3`, `action_result/3`, `fallback_reply/2` | Pass the implementation to `Spectre.Turn.Dispatcher.dispatch/3`. Delivery callbacks return `{:ok, delivered}` or error; satisfied-resolution returns `{:ok, resolution}` or `:not_satisfied`; execute returns boolean; fallback returns text/nil. [Complete delivery example and defaults](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/turn/dispatcher.ex). |

### Retained storage, ownership and replay

| Behaviour | Required callbacks | Optional callbacks | Contract and dedicated guide/example |
| --- | --- | --- | --- |
| `Spectre.State.Store` | None formally | `load/3`, `compare_and_swap/5` | Configure the retained Agent state adapter. Implement CAS for optimistic durable persistence; load returns State/map/encoded state, CAS returns success/error. Ambiguous commits cannot be retried blindly. [State persistence](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/PRODUCTION_0_3.md#state-persistence), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/state_store_session_resume_test.exs). |
| `Spectre.Instance.CheckpointStore` | None formally | `load/2`, `compare_and_swap/5`, `migrate_instance_key/5`, `erase/3`, `erasure_status/2` | Configure `checkpoint_store:` on an Instance. Durable adapters implement load/CAS; optional migration moves or aliases keys; erasure/status require their typed results. Preserve unknown commit outcomes. [Canonical checkpoints](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/PRODUCTION_0_3.md#canonical-instance-checkpoints), [generator](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/mix/tasks/spectre.gen.checkpoint_store.ex). |
| `Spectre.Instance.Owner` | `claim/2`, `validate/3` | `claim_maintenance/3`, `release/3` | Configure `owner:` for Instance ownership. Claim returns `{:ok, Lease}` or error; validate/release return `:ok` or error. Multi-node ownership requires linearizable fencing or a single canonical owner. [Ownership guide](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/PRODUCTION_0_3.md#multi-node-ownership-and-rolling-deploys), [conformance fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/instance_owner_conformance_test.exs). |
| `Spectre.Journal.Store` | `append/2` | `erase_instance/2` | Configure the journal Store. Append returns `:ok`, `{:ok, receipt}` or error; erasure returns `{:ok, :erased \| :already_erased}` or error. Indexing/retention are application responsibilities. [Journal setup](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/JOURNAL.md#configure-a-store), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/journal_recovery_contract_test.exs). |
| `Spectre.Receipt.Sink` | `append/2`, `lookup/2` | `put_payload/2`, `get_payload/2`, `delete_payload/2` | Configure `receipt_sink:` with the retained receipt mode. Append returns `{:ok, :appended \| :idempotent}` or error; lookup returns envelope/not-found/error; optional callbacks stage/delete receipt payloads. [Receipt contract](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/RECEIPTS.md), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/receipt_contract_test.exs). |
| `Spectre.Event.SchemaRegistry` | `compatible?/3` | None | Configure `event_schema_registry:` for global Events; receive Definition.Ref, Event.Envelope and options, return `:ok` or error. [Event lifecycle](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/EVENT_LIFECYCLE.md), [fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/event_lifecycle_semantics_test.exs). |
| `Spectre.Determinism.Source` | `system_time/2`, `monotonic_time/2`, `random_bytes/2` | None | Configure `determinism_source:` at the retained decision/replay boundary. Return integer time samples and the requested binary bytes. The source is resolved call-locally, not persisted in a Run. [Replay example](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/rehearsal_projection_subject_contract_test.exs), [receipt/replay guide](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/RECEIPTS.md). |

### Definition publication, reflection and evolution

| Behaviour | Required callbacks | Optional callbacks | Contract and dedicated guide/example |
| --- | --- | --- | --- |
| `Spectre.Definition.Store` | `identity/1`, `durability/1`, `get/2`, `put/3` | None | Pass a module or `{Module, opts}` to publication/resolution APIs. Stable identity; durability `:volatile \| :durable`; get binary/not-found/error; put `:ok`, `{:ok, :created \| :existing}` or error. Never replace different bytes under an existing immutable ref. Durable checkpoints require durable Definitions. [Definition store](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/DEFINITION_STORE.md), [in-memory implementation](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/definition/store/memory.ex). |
| `Spectre.Experience.Store` | `identity/1`, `durability/1`, `get/2`, `put/3`, `list/1`, `delete/2` | None | Configure the reflection/Experience Store. Persistence uses opaque verified bytes; list returns keyed binaries; delete returns `:ok`, `:not_found` or error. Redacted evidence is not authoritative Agent state. [Reflective runtime](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/REFLECTIVE_RUNTIME.md), [in-memory implementation](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/experience/store/memory.ex). |
| `Spectre.Projection` | `id/0`, `version/0`, `project/2` | None | Pass a projection module to the canonical projection API. Stable id/version and `{:ok, content}` or error; projection identity includes generator identity and input evidence. This differs from Domain storage or Server public text projection. [Canonical definitions](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/CANONICAL_DEFINITIONS.md), [audit implementation](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/lib/spectre/projection/audit.ex). |
| `Spectre.Forge.Critic` | `id/0`, `version/0`, `profile_ref/0`, `critique/3` | None | Host-register compiled critic adapters. Receive portable Reflection and redacted Experience; return `{:ok, critique_map}` or error. A model may propose an opinion/falsifiable case, never executable code. [Reflective runtime](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/REFLECTIVE_RUNTIME.md), [critic fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/reflective_runtime_test.exs). |
| `Spectre.Governance.ChangeSet.Handler` | `operation_types/0`, `component_classes/0`, `apply/3` | None | Register compiled handlers in the host-owned ChangeSet Registry. Declare allowed operation strings/component atoms; apply returns `{:ok, Composition}` or error. [Governance](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/GOVERNANCE.md), [registered-handler fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/governance_runtime_contract_coverage_test.exs). |
| `Spectre.Governance.GC.InventoryProvider` | `snapshot/2` | None | Supply the provider to governance GC planning. Receive Definition.Store config and options; return a complete, fenced `{:ok, inventory_map}` or error, including snapshot/revision/fencing and protected refs. [Governance GC](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/docs/legacy/GOVERNANCE.md), [inventory fixture](https://github.com/elchemista/spectre/blob/109684e0b5fa87ca2e352b2f7e28d0702a0cbc1c/test/governance_runtime_contract_coverage_test.exs). |

`Spectre.Stack.PackageData` appears with [Stack packages](#stack-packages-tools-and-effects)
because the installable owns the implementation; its erasure callbacks belong
to this retained lifecycle. `Spectre.Extension` also bridges retained action
ports and current package/selection contributions. Use [migration](MIGRATING_TO_0_4.md)
when moving runtime ownership rather than translating old policy records into
GAM consent.

## Verifying an implementation

Compile against the version of Spectre declared by the package. Behaviour
warnings catch missing callback names/arities; they do not establish the
storage, replay, authority or provider guarantees in the tables. Use the
relevant [conformance runner and lifecycle tests](TESTING.md), then exercise
the real application binding, failure results and restart path. Test fixture
links above illustrate contracts and are not production storage or host
implementations to copy without adapting their guarantees.

The [public API manifest](PUBLIC_API.md) indexes callable modules; this guide
explains which ones an application implements and how those implementations
are connected. Internal runtime modules with hidden module documentation are
not additional public extension points.
