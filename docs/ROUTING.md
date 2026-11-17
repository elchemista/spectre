# Routing

Routing recognizes an input and selects a declared Server handler. An Agent
declares the available intents and evidence; its Server implements the response
or consequence. A route never grants execution authority.

## Combine regex, semantic matching and a classifier

Use explicit patterns for known commands, embeddings for similar meanings, and
an LLM classifier when earlier evidence cannot select a route:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  embedding MyApp.Embeddings
  classifier :llm, MyApp.IntentModel

  router strategies: [:regex, :embedding, :llm_classifier]

  flow :support do
    on :pricing,
      regex: ~r/\b(price|pricing|cost)\b/i,
      semantic_examples: ["How much does a subscription cost?"]

    on :technical,
      semantic_examples: ["My API key stopped working"]
  end
end
```

`MyApp.Embeddings` and `MyApp.IntentModel` are host adapters, not built-in
modules. Supply `embed(text, opts)` returning numeric vectors and
`complete(prompt, opts)` returning a declared intent label as text, with the
models and credentials your application requires. See [provider contracts](#host-providers).
The Stack and Server are application modules as shown in [Getting started](GETTING_STARTED.md).

`"What is the price?"` selects `handle_flow({:support, :pricing}, input, ctx)`
through its regex. Other inputs can be recognized by similarity to the declared
examples or classified as `:pricing` or `:technical`. Regex collects the first
visible matching rule as hard evidence; the classifier is a fallback and does
not run on every turn.

## Choose evidence strategies

| Strategy | Route declaration | Prerequisites |
| --- | --- | --- |
| `:regex` | `regex: ~r/.../` | None. |
| `:bag` | `bag: ["subscription plans"]` | None. |
| `:jaro` | `jaro: ["monthly subscription"]` | None. |
| `:intent_dataset` | Declared labels; optional example and collection options. | Built-in labeled-example store, or a host dataset adapter. Exact lookup needs no encoder; vector lookup needs compatible stored vectors and a query encoder. |
| `:embedding` | `semantic_examples: ["How much does it cost?"]` | An embedding adapter. |
| `:local_classifier` | Declared labels. | A local classifier adapter, or trained artifacts for `Spectre.Classifier`. |
| `:llm_classifier` | Declared labels, optionally with examples. | A classifier model, or a compatible configured response model. |
| Native Router Adapter module | Data under its declared adapter id. | A module using `Spectre.Router.Adapter`. |

Choose the strategies your application needs. A host with all the adapters
configured can combine them:

```elixir
router strategies: [:regex, :intent_dataset, :bag, :jaro,
                     :embedding, :local_classifier, :llm_classifier]
```

`strategies:` expands to provider plugs in the listed order, followed by
arbitration and terminalization. `:llm_classifier` enables an arbitration
fallback; it does not make an unconditional model call at that position.
Generated pipelines also append dataset lookup when any route permits it
(the default). `semantic_cache?: false` disables that automatic lookup;
`dataset_lookup: false` excludes an individual route.

The retained aliases are `via:` for `strategies:`, `:semantic_cache` for
`:intent_dataset`, and `:classifier` for `:local_classifier`. Route options
`embedding:`, `via:` and `learn:` remain the older spellings of
`semantic_examples:`, `match_with:` and `collect_intent:`. Conflicting option
aliases raise errors. The legacy `:llm` step remains accepted but does not
enable LLM classification; use `:llm_classifier`. `:arbitrate` and
`:terminalize` are pipeline control steps, not evidence sources.

## Local string matching

Regex, bag distance and Jaro distance work without a model or an embedding
provider. This variant uses only local string matching:

```elixir
# Inside the Agent:
router strategies: [:regex, :bag, :jaro]

flow :support do
  on :pricing,
    regex: ~r/\b(price|pricing|cost)\b/i,
    bag: ["subscription plans"],
    jaro: ["monthly subscription"]
end
```

`"What is the price?"`, `"subscription plans"` and `"monthly subscription"`
all select the pricing route. The [executable quickstart](https://github.com/elchemista/spectre/blob/main/docs/examples/agent_server_quickstart.exs)
supplies the Stack, Agent, Server and input loop for this variant.

Bag and Jaro compare input and examples after lowercasing, trimming and
collapsing whitespace. Bag uses `String.bag_distance/2` to compare character
multisets; Jaro uses `String.jaro_distance/2` for short, similar strings and
typos. Neither computes semantic meaning. Tune them against your own inputs.

## Add a labeled intent dataset

`Spectre.IntentDataset` stores labeled examples. Text-only examples support
exact recognition; vector lookup uses only valid compatible embeddings. It is
not a response cache. Start with exact lookup and no encoder:

```elixir
# Inside the Agent; uses the built-in dataset without a custom binding.
router strategies: [:regex, :intent_dataset], semantic_search?: false

flow :support do
  on :pricing,
    regex: ~r/^prices?$/i,
    semantic_examples: ["How much is a subscription?"],
    collect_intent: true
end
```

The built-in dataset includes static route examples from `semantic_examples:`,
`bag:` and `jaro:`, configured labeled offline sources, and reviewed online
examples. An exact hit makes no embedding call. Add and review an online example
explicitly with:

```elixir
{:ok, row} = Spectre.IntentDataset.put(
  "I need a custom subscription quotation",
  %{label: :pricing, strategy: :llm_classifier},
  agent: MyApp.SupportAgent)

{:ok, _verified} = Spectre.IntentDataset.verify(MyApp.SupportAgent, row.id)
```

`collect_intent: true` opts a route into eligible runtime collection; it does
not collect every recognized input or train a classifier. Online examples are
unverified by default and excluded from ordinary recognition until reviewed or
explicitly included. `dataset_lookup: false` excludes a route from dataset
recognition. The older `cache: false` has narrower custom-adapter behavior and
is not an equivalent replacement.

For a host store, bind `intent_dataset MyApp.Dataset, lookup: [exact: true,
semantic: false]`. Do not bind `Spectre.Router.SemanticCache` as its own adapter:
it is the dispatcher. See [Training](TRAINING.md) for offline sources, review,
snapshots, batch embedding and classifier training. Quantized Vettore search
can use Hamming distance with full-metric reranking; compatible embedding
profiles remain required.

## Add semantic matching

Use `:embedding` to compare the current text with route examples through a
host encoder:

```elixir
# Inside the Agent; MyApp.Embeddings must implement embed/2.
embedding MyApp.Embeddings, model: "your-encoder-model"

router strategies: [:regex, :embedding],
  embedding: [min_score: 0.85, min_margin: 0.05]

flow :support do
  on :pricing,
    regex: ~r/^prices?$/i,
    semantic_examples: ["How much does a subscription cost?"]

  on :technical,
    semantic_examples: ["My API key stopped working"]
end
```

The adapter receives query and example strings and returns numeric vectors.
Use the same compatible encoder for both. Example vectors are cached by
Agent/adapter/model identity; query encoding can still incur usage. Dataset
semantic lookup is a separate strategy over stored labeled vectors.

## Add a local classifier and an LLM fallback

Configure intent recognition independently from response generation. These
modules are host dependencies; the local adapter needs suitable trained
artifacts or its own classification implementation.

```elixir
# Inside the Agent; routes still need to be declared in its flows.
classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/intents"
classifier :llm, MyApp.IntentModel, timeout: 8_000

router strategies: [:regex, :intent_dataset, :local_classifier, :llm_classifier],
  local_classifier: [min_score: 0.93, min_margin: 0.08],
  on_no_decision: :llm,
  log_decisions: true
```

The local classifier contributes scored evidence. When arbitration cannot
select an eligible candidate, the LLM classifier may choose among visible,
declared labels. Configuring a response model alone does not enable LLM routing;
the strategy (or explicit `llm_classifier?: true` in a custom pipeline) is
required. The LLM result is added as evidence and arbitration runs again.

## Visibility, thresholds and arbitration

Restrict a route to chosen strategies with `match_with:`. Input checks apply
before providers see the route:

```elixir
flow :billing do
  on :invoice,
    semantic_examples: ["Send me my invoice"],
    match_with: [:embedding, :llm_classifier],
    check: {:language, ["en", "english"]}
end
```

Interrupt rules are prioritized, then current-flow/current-scope rules, then
remaining routes. Current flow prioritization does not hide other topics.
Nested flows and mounted Skills keep their complete callback path and scope.
Label-only providers exclude ambiguous duplicate labels; native adapters can
identify rules by scoped refs. No provider can create an undeclared handler.

The default arbitrator excludes rejected, unrouteable or below-threshold
evidence. Its built-in thresholds are:

| Evidence | Minimum score | Minimum margin |
| --- | --- | --- |
| Local classifier | `0.93` | `0.08` |
| Embedding | `0.84` | `0.05` when supplied |
| Bag | `0.72` | None. |
| Jaro | `0.90` | None. |

Configure them with `local_classifier: [min_score: ..., min_margin: ...]`,
`embedding: [min_score: ..., min_margin: ...]`, `bag: [min_score: ...]` and
`jaro: [min_score: ...]` on `router` or `arbitrator`.

Selection precedence is accepted hard evidence, agreement between at least two
providers for the same scoped route, local classifier, embedding, dataset
evidence, bag, then Jaro. Native adapters have additional strength slots:
`:strong` before local classifier, `:medium` after embedding, and `:weak`
after Jaro; `:hard` participates in the initial hard-evidence step. Adapter
slots are skipped once an LLM candidate exists, while hard evidence and provider
agreement are still considered. Scores are not globally interchangeable across
providers, and declaration order is not the final ranking rule.

With the default arbitrator, accepted hard evidence lets dataset, embedding,
local classifier and native adapter stages skip later work. Bag and Jaro still
collect their inexpensive evidence. Custom arbitrators receive the complete
evidence stream unless `hard_short_circuit: true` is set. A strategy list is
therefore not a promise that every configured provider runs on each turn.

## No match, ambiguity and provider failures

Handle unmatched input in the Server and inspect `ctx.routing.reason`:

```elixir
def handle_flow(:unmatched, input, ctx) do
  case ctx.routing.reason do
    :ambiguous -> respond(ctx, "Do you mean pricing or account management?")
    :no_match -> generate(ctx, :understand, input: input, on_result: :answer)
    {:classifier_error, _reason} -> respond(ctx, "Recognition is temporarily unavailable.")
    _ -> respond(ctx, "Please clarify your request.")
  end
end
```

`:understand` is an application-defined prompt/continuation. There is no
implicit `understand/` callback. This handler can clarify, consult memory or
start another explicitly bounded classification step.

A dataset miss is ordinary absence of evidence. A provider failure can still
be followed by a successful later strategy; if recognition remains unavailable,
the cause is retained. A declared legacy `UNKNOWN` route is separate from
technical failure. `on_no_decision: :clarify` requests clarification when no
eligible evidence exists; the default `:llm` policy also clarifies if no enabled,
available classifier model can run.

## Provider and extension contracts

### Host providers

| Binding | Required module callback | Reply |
| --- | --- | --- |
| `embedding MyApp.Embeddings, opts` | `embed(text, opts)` | `{:ok, nonempty_numeric_vector}` or `{:error, reason}`. |
| `classifier :local, MyApp.LocalClassifier, opts` | `classify(text, opts)` | `{:ok, result_map}` or `{:error, reason}`. The map requires a declared `label` and boolean `accepted?`; the default arbitrator also needs numeric `confidence` (or `score`) and `margin` to accept local evidence. |
| `classifier :llm, MyApp.IntentModel, opts` | `complete(prompt, opts)` | `{:ok, label_text}` or `{:error, reason}`. Text must resolve to a visible declared label. Modules may additionally implement `complete_plan/2` to receive a typed prompt plan. |
| `intent_dataset MyApp.Dataset, opts` | `lookup(text, opts)` | `{:ok, result_map}` or `{:error, reason}`. The map requires boolean `accepted?` and a label when accepted. Lookup receives `semantic_search?: false` for exact and `true` for vector lookup. |

`opts` are keyword lists. Provider credentials, models and artifacts belong to
the host adapter. Dataset `put(text, result, opts)` is needed for custom-store
collection; review, snapshot and `clear/2` operations require their corresponding
callbacks when used. A lookup-only function is not a writable or clearable
dataset. See the [detailed provider reference](https://github.com/elchemista/spectre/blob/109684e/docs/legacy/ROUTING_0_3.md#router-options-and-adapters)
for retained tuple/function forms and optional dataset callbacks.

### Native Router Adapter

Use a native adapter when the evidence source should return scoped rule refs
rather than labels. This complete example recognizes host command strings:

```elixir
defmodule MyApp.CommandRouter do
  use Spectre.Router.Adapter, id: :commands, accept: 0.95, strength: :medium

  @impl Spectre.Router.Adapter
  @spec evaluate(Spectre.Router.Adapter.Request.t()) :: Spectre.Router.Adapter.reply()
  def evaluate(%Spectre.Router.Adapter.Request{text: text, rules: rules}) do
    command = text |> String.downcase() |> String.trim()

    results =
      rules
      |> Enum.filter(&(command in examples(&1)))
      |> Enum.take(32)
      |> Enum.map(&result(&1, 1.0, matched: command))

    {:ok, results}
  end
end
```

Register the module and declare data under its id:

```elixir
router strategies: [:regex, MyApp.CommandRouter, :llm_classifier]

flow :support do
  on :pricing, commands: ["subscription prices"],
    match_with: [:commands, :llm_classifier]
end
```

Only `id:` is required. Optional descriptor settings default to `accept: 0.0`,
`margin: nil` and `strength: :weak`. Ids must be non-reserved atoms; acceptance
and configured margin thresholds must be numbers in `0..1`.

`evaluate/1` receives text, metadata, current flow/scope, recent chat and visible
`RuleView`s. Each view exposes `ref`, label, scope, flow/path, adapter `data` and
rule options. The request excludes executable handlers and runtime capabilities.
Return `{:ok, result_or_list}`, `:skip`, `{:skip, reason}` or `{:error, reason}`.
Each result is a plain map containing only required `rule` and `score`, with
optional `margin` and `matched`; `result/2,3` builds that map. `rule` must be a
visible `{scope, label}` ref; score and any margin must be in `0..1`. A configured
margin threshold is enforced when the adapter supplies a margin. Return at most
32 distinct refs; oversized or invalid responses are rejected, not silently
trimmed.

Spectre resolves refs and derives authoritative candidates; adapters cannot
return handlers, acceptance decisions or terminal routes. Treat request text
and metadata as application data when logging. Test deterministic fixtures with
`Spectre.Router.Adapter.Conformance.run(adapter, request)`; see the
[native adapter reference](https://github.com/elchemista/spectre/blob/109684e/docs/legacy/ROUTING_0_3.md#native-router-adapters).

### Router plugs and custom pipelines

A plug implements `Spectre.Router.Plug`: `init(keyword)` returns its state;
`call(context, state)` returns `{:cont, context}`, `{:halt, context}`,
`{:inference, prepared}` or `{:error, reason}`. Plugs work with the full router
context and are trusted application code. Use a native adapter for the narrower
read-only evidence contract.

```elixir
defmodule MyApp.SupportPipeline do
  use Spectre.Pipeline

  pipeline do
    plug Spectre.Router.Plugs.Regex
    plug Spectre.Router.Plugs.BagDistance
    plug Spectre.Router.Plugs.JaroDistance
    plug Spectre.Router.Plugs.Arbitrate
    plug Spectre.Router.Plugs.Terminalize
  end
end

# Inside the Agent:
router pipeline: MyApp.SupportPipeline
```

An explicit `pipeline:` owns the complete ordering; generated stages are not
appended. It accepts a pipeline module with `call/1` returning `{:ok, context}`,
`{:inference, prepared}` or `{:error, reason}`, or a list of plug modules and
`{module, opts}` specs. Include the arbitration/terminalization stages you need.
For a native adapter in a custom pipeline, register it with `strategies:` and
call `Spectre.Router.Adapter.run(context, :commands)` from a plug.

### Custom arbitrator

Bind `arbitrator MyApp.Arbitrator, opts` on the Agent. A module implementing
`Spectre.Router.Arbitrator` must define `decide(arbitration, opts)`. The
`Spectre.Router.Arbitration` snapshot contains input, state, visible rules and
labels, candidates in evaluation order, and the original router context.

Return `{:ok, route}`, `{:llm, arbitration}`, `{:clarify, text}` or
`{:error, reason}`. Use `Spectre.Router.Candidate.to_route(candidate,
arbitration.labels)` to convert a chosen candidate. The same arbitrator runs
again after LLM evidence is added, so it must handle that second decision and
empty candidate lists. The [detailed arbitration reference](https://github.com/elchemista/spectre/blob/109684e/docs/legacy/ROUTING_0_3.md#custom-arbitrator)
contains further examples; its older handler bodies use the compatibility runtime.

## Evaluate without running a handler

```elixir
{:ok, receipt} = Spectre.Router.evaluate(MyApp.SupportAgent, "show prices")
```

This runs configured input/router providers and returns a bounded recognition
receipt. It does not execute the winning handler, load normal state/memory
adapters or collect new examples. Provider calls may still incur usage. See
[Routing evaluation](EVALUATION.md) for corpus comparisons. Recognition scores
do not validate downstream GAM bindings or effects.

## Pending input and governed consequences

A short yes/no while consent is open belongs to `handle_pending/3`; it does not
need a global yes route. That handler may classify explicit choices or use
ordinary functions. GAM's fixed ingress still interprets and authenticates the
original response against the actual Presentation.

For a new topic, `route_current_input(ctx, suspend: pending.id)` routes the same
prepared input without repeating the input pipeline. Add a durable closure
policy if the old intention should expire. See [Pending lifecycle](PENDING_LIFECYCLE.md).

Classifying or embedding does not automatically require a consent ceremony.
Governed access, disclosure or consumption still uses its governed boundary.
`protected: true` requests the standard bridge's confirmation path; a router
result never supplies a Mandate. See [GAM](GAM.md) and the
[manifesto](https://spectre.guide/en/governed-act-model).
