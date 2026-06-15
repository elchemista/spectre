# Routing

Spectre routing is evidence-first. Router plugs collect candidates, then an
arbitrator decides which candidate becomes the route.

The common configuration is `via:`:

```elixir
router(
  via: [:regex, :semantic_cache, :bag, :jaro, :embedding, :classifier, :llm_classifier]
)
```

`via:` expands into router plugs and appends arbitration and terminalization for
you. The mapping is:

- `:regex` -> `Spectre.Router.Plugs.Regex`
- `:bag` -> `Spectre.Router.Plugs.BagDistance`
- `:jaro` -> `Spectre.Router.Plugs.JaroDistance`
- `:embedding` -> `Spectre.Router.Plugs.EmbeddingSimilarity`
- `:semantic_cache` -> `SemanticCacheExact` and `SemanticCacheSearch`
- `:classifier` -> `Spectre.Router.Plugs.LocalClassifier`
- `:llm_classifier` -> no evidence plug; the arbitrator can ask it when needed
- `:arbitrate` -> `Spectre.Router.Plugs.Arbitrate`
- `:terminalize` -> `Spectre.Router.Plugs.Terminalize`

`Spectre.Router.Plugs.LLMFallback` also exists for legacy or fully custom
pipelines. It is not inserted by modern `via:` expansion; normally the default
arbitrator is the place that asks the LLM classifier. If you add the fallback
plug yourself, enable it with `llm_fallback?: true`.

If you set `pipeline:`, Spectre uses that pipeline instead of expanding `via:`.
That is the escape hatch for advanced agents:

```elixir
router(
  pipeline: [
    Spectre.Router.Plugs.Regex,
    {MyApp.Router.Plugs.BusinessHours, [timezone: "Europe/Rome"]},
    Spectre.Router.Plugs.LocalClassifier,
    Spectre.Router.Plugs.Arbitrate,
    Spectre.Router.Plugs.Terminalize
  ]
)
```

When you provide a custom `pipeline:`, include `Arbitrate` if you want collected
candidates to become a route, and include `Terminalize` if you want terminal
metadata. `via:` adds those automatically; `pipeline:` is explicit.

You can also package a custom router pipeline as a module:

```elixir
defmodule MyApp.RouterPipeline do
  use Spectre.Pipeline

  pipeline do
    plug(Spectre.Router.Plugs.Regex)
    plug(MyApp.Router.Plugs.BusinessHours, timezone: "Europe/Rome")
    plug(Spectre.Router.Plugs.LocalClassifier)
    plug(Spectre.Router.Plugs.Arbitrate)
    plug(Spectre.Router.Plugs.Terminalize)
  end
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent

  router(pipeline: MyApp.RouterPipeline)
end
```

Router plugs implement `Spectre.Router.Plug`:

```elixir
defmodule MyApp.Router.Plugs.BusinessHours do
  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context

  def init(opts), do: opts

  def call(%Context{} = context, opts) do
    if MyApp.Calendar.open?(opts[:timezone]) do
      {:cont, context}
    else
      route =
        Spectre.Route.new(
          label: :AFTER_HOURS,
          handler: {:reply, :after_hours, []},
          strategy: :business_hours,
          accepted?: true,
          raw: context.input.text,
          labels: context.labels
        )

      {:halt, Context.put_route(context, route)}
    end
  end
end
```

Return values:

- `{:cont, context}` continues the router pipeline
- `{:halt, context}` stops routing and marks the context halted
- `{:error, reason}` fails routing

Most custom router plugs should add candidates or metadata and continue.
Decision plugs should halt.

Built-in strategy names:

- `:regex` matches explicit DSL regexes.
- `:bag` scores simple phrase examples.
- `:jaro` scores string similarity examples.
- `:embedding` embeds the user text and route examples, then compares vectors.
- `:classifier` uses a local trained classifier artifact.
- `:semantic_cache` asks your semantic cache adapter for exact or search hits.
- `:llm_classifier` asks the model to choose from labels when configured.

Built-in plug mechanics:

- Regex checks visible regex rules in evaluation order and adds the first match
  as a candidate.
- Bag and Jaro score the best example per visible rule.
- Embedding embeds the user text and each route example, then uses cosine score
  and score margin.
- Semantic cache runs exact lookup early with `semantic_search?: false`, then
  broader search later with `semantic_search?: true`.
- Local classifier calls `classify`, `classifier`, or Spectre's own classifier
  artifact.
- Arbitrate turns candidates into a final route, LLM arbitration, clarification,
  or error.
- Terminalize adds `terminal?` and `escalation_reason` after a route exists.

Per-route `via:` limits which strategies can see a route:

```elixir
on :BILLING,
  regex: ~r/\b(invoice|billing)\b/i,
  embedding: ["question about an invoice"],
  via: [:regex, :embedding, :classifier] do
  ask(:billing)
end
```

The default arbitrator is conservative:

- hard/global evidence wins first
- agreement from multiple providers is strong
- confident classifier evidence can beat weak regex
- confident embedding evidence can route semantic phrasing
- bag and Jaro are useful for cheap approximate matching
- unresolved conflicts can fall back to LLM arbitration or clarification

Default thresholds include classifier acceptance, classifier margin, embedding
acceptance, embedding margin, bag acceptance, and Jaro acceptance. You can
replace the arbitrator if your product needs different behavior:

```elixir
arbitrator(MyApp.Router.Arbitrator, conflict: :best)
```

The important design point is that regex, embedding, classifier, and semantic
cache do not overwrite each other in secret. They produce evidence. The
arbitrator makes the final decision.


## Default Arbitrator

The default arbitrator lives in `Spectre.Router.Arbitrators.Default`. It receives
a `%Spectre.Router.Arbitration{}` with:

- the normalized input
- the current state
- the visible rules
- the visible labels
- the candidates collected by router plugs
- the full router context

Each candidate has a label, provider, score, margin, strength, handler, and the
rule that produced it. The default arbitrator first removes candidates that
cannot actually run a handler, then applies thresholds and sorts by strength,
provider rank, and score.

The default thresholds are:

```elixir
[
  classifier_accept: 0.93,
  classifier_margin: 0.08,
  embedding_accept: 0.84,
  embedding_margin: 0.05,
  bag_accept: 0.72,
  jaro_accept: 0.9,
  conflict: :llm,
  no_decision: :clarify
]
```

The decision order is:

1. Pick hard evidence first. Global interrupts are hard by default, so cancel,
   help, unsafe, spam, and similar commands can cut through normal routing.
2. If two or more providers agree on the same label, accept that agreement and
   keep the highest-scored candidate for that label.
3. Accept a confident local classifier candidate.
4. Accept a confident embedding candidate.
5. Accept a confident bag-distance candidate.
6. Accept a confident Jaro candidate.
7. If eligible candidates disagree and `conflict: :llm`, ask the LLM classifier
   to arbitrate among labels.
8. If there is still no decision and `no_decision: :clarify`, return a clarify
   route with `"Please rephrase your request."`.
9. Otherwise return `{:error, :no_route_candidate}`.

Provider rank only matters after eligibility. It is not a magic override; it is
how the default arbitrator sorts candidates once they have already cleared their
thresholds. The built-in rank is:

```elixir
llm_classifier > local_classifier > embedding > semantic_cache > bag/jaro > regex
```

That ordering is why a weak regex can be beaten by a strong classifier, while a
hard interrupt still wins immediately.

You can tune the default arbitrator without replacing it:

```elixir
router(
  via: [:regex, :embedding, :classifier, :llm_classifier],
  arbitrator:
    {Spectre.Router.Arbitrators.Default,
     [
       classifier_accept: 0.9,
       embedding_accept: 0.82,
       embedding_margin: 0.03,
       conflict: :llm,
       no_decision: :clarify
     ]}
)
```

You can also set rule strength when a route should carry more weight:

```elixir
on :LIST_MY_PROJECTS,
  bag: ["show my projects", "list my job posts"],
  strength: :strong,
  via: [:bag, :classifier, :llm_classifier] do
  action(:list_my_projects)
end
```

Strength can be general (`strength: :strong`) or provider-specific
(`regex_strength: :hard`, `embedding_strength: :medium`). Use this sparingly:
most routes should be decided by evidence quality, not manual force.


## Custom Arbitrator

If your product has different risk rules, replace the arbitrator instead of
rewriting router plugs.

```elixir
defmodule MyApp.Router.Arbitrator do
  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Candidate

  @impl Spectre.Router.Arbitrator
  def decide(arbitration, _opts) do
    candidates =
      Enum.filter(arbitration.candidates, fn candidate ->
        candidate.handler && candidate.accepted?
      end)

    cond do
      billing = Enum.find(candidates, &(&1.label == :BILLING_ESCALATION)) ->
        {:ok, Candidate.to_route(billing, arbitration.labels)}

      confident = Enum.find(candidates, &confident?/1) ->
        {:ok, Candidate.to_route(confident, arbitration.labels)}

      candidates != [] ->
        {:llm, %{arbitration | candidates: candidates}}

      true ->
        {:clarify, "Can you say that another way?"}
    end
  end

  defp confident?(%{provider: :local_classifier, score: score, margin: margin}) do
    is_number(score) and score >= 0.92 and is_number(margin) and margin >= 0.1
  end

  defp confident?(%{provider: :embedding, score: score}) do
    is_number(score) and score >= 0.88
  end

  defp confident?(_candidate), do: false
end
```

Then configure it in the agent:

```elixir
arbitrator(MyApp.Router.Arbitrator, product: :support)
```

or inside `router/1`:

```elixir
router(
  via: [:regex, :classifier, :embedding, :llm_classifier],
  arbitrator: {MyApp.Router.Arbitrator, [product: :support]}
)
```

An arbitrator may return:

- `{:ok, %Spectre.Route{}}` to accept a route
- `{:llm, arbitration}` to ask the LLM classifier to break a conflict
- `{:clarify, text}` to produce a clarification route
- `{:error, reason}` to fail routing

This keeps policy separate from evidence. Regex, embedding, semantic cache, and
classifier plugs explain what they found; the arbitrator decides what your
product trusts.


## Router Options And Adapters

Router opts are just keyword opts merged into the router context. The built-in
plugs look for a few well-known keys:

```elixir
router(
  via: [:regex, :semantic_cache, :classifier, :embedding, :llm_classifier],

  # Local classifier artifacts and adapter override.
  artifact_dir: "artifacts/spectre",
  classifier_local: {MyApp.IntentClassifier, :classify},

  # Semantic cache adapter and built-in learned-cache capacity.
  semantic_cache: MyApp.SemanticCache,
  semantic_cache_capacity: 100,

  terminal_labels: [:PRICING, :SUPPORT],
  high_confidence_threshold: 0.9,
  classification_log?: true,
  semantic_after_classifier?: true
)
```

Important options:

- `:via` chooses built-in strategies and auto-appends arbitration/terminalize.
- `:pipeline` replaces `via` with an explicit plug list or pipeline module.
- `:arbitrator` sets `{Module, opts}` for final route selection.
- `:terminal_labels` or `:terminal_intents` marks labels that can end a flow.
- `:high_confidence_threshold` is used by terminalization.
- `:classification_log?` turns router/classifier logs on or off.
- `:llm_fallback?` enables the legacy `LLMFallback` plug if a custom pipeline
  uses it.
- `:semantic_cache?` disables semantic cache when false.
- `:semantic_after_classifier?` disables the later semantic-search pass when
  false.
- `:semantic_lookup` can be a function.
- `:semantic_cache` can be a module or `{module, function}`.
- `:classify` can be a function.
- `:classifier_local` can be a module or `{module, function}`.
- `:artifact_dir` points Spectre's local classifier to trained artifacts.
- `classifier MyApp.SmallLLM, prompt: ..., llm_opts: ...` customizes the LLM
  classifier.
- `:recent_chat` is included in the default LLM classifier prompt.
- `:semantic_cache_capacity` limits Spectre's built-in learned cache indexes.

Adapter shapes are intentionally simple:

```elixir
semantic_lookup = fn text, opts ->
  MyApp.SemanticCache.lookup(text, opts)
end

classify = fn text, opts ->
  MyApp.IntentClassifier.classify(text, opts)
end

Spectre.ask(MyApp.SupportAgent, "hello",
  semantic_lookup: semantic_lookup,
  classify: classify
)
```

Or use modules:

```elixir
defmodule MyApp.IntentClassifier do
  def classify(text, opts) do
    {:ok, %{label: :SUPPORT, accepted?: true, confidence: 0.95, margin: 0.2}}
  end
end

defmodule MyApp.SemanticCache do
  def lookup(text, opts) do
    {:error, :miss}
  end
end

Spectre.ask(MyApp.SupportAgent, "hello",
  classifier_local: MyApp.IntentClassifier,
  semantic_cache: MyApp.SemanticCache
)
```

Classifier and semantic-cache adapters should return route-like maps:

```elixir
%{
  label: :SUPPORT,
  accepted?: true,
  confidence: 0.95,
  margin: 0.2,
  strategy: :local_classifier
}
```

Spectre maps the returned label back onto a visible DSL rule. A good adapter
cannot route to labels that the current agent state, `via`, or `check` rules
hide.


## Embedding Routing

Embedding routing is useful when users say the right thing with different words.

```elixir
embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

flow :sales do
  on :PROJECT_PROPOSAL,
    regex: ~r/\b(proposal|quote|estimate)\b/i,
    embedding: [
      "scope an MVP build",
      "estimate a marketplace launch",
      "prepare a project proposal"
    ],
    via: [:regex, :embedding] do
    ask(:project_proposal)
  end
end
```

Adapter example:

```elixir
defmodule MyApp.Embeddings do
  @behaviour Spectre.Classifier.Embedding

  def load(model, opts), do: Spectre.Classifier.Embeddings.ExFastembed.load(model, opts)
  def embed(text, opts), do: Spectre.Classifier.Embeddings.ExFastembed.embed(text, opts)
end
```

For tests, use a deterministic adapter instead of loading a real model. The
router only needs `embed/2` to return stable vectors.


## Semantic Search And Cache

Semantic cache is an adapter boundary. Spectre does not force a vector database,
embedding model, table shape, or cache strategy. It is independent from the
local classifier: a semantic-cache miss does not block classifier routing, and
`cache: false` never hides a route from `:classifier`.

For the common local case, Spectre's built-in cache reads labeled offline
dataset rows and route examples by default:

```elixir
embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

on :PRICING, learn: true do
  reply(:pricing)
end

on :DELETE_ACCOUNT,
  cache: false,
  learn: false do
  action(:delete_account)
end
```

Labeled rows from configured classifier datasets are mirrored into semantic
search by default when the label maps to a cacheable route. `learn: true` means
online learning only: after the LLM classifier fallback accepts a final route,
Spectre can store the user text as an editable online example. `cache: false`
excludes offline rows, static route examples, and online examples for that
route from semantic cache.

Exact lookup runs without embeddings; semantic search embeds examples and
indexes them with Vettore. If no router `via:` is configured, Spectre adds
`:semantic_cache` automatically when cacheable rules exist. If a rule has an
explicit route-level `via:`, it must include `:semantic_cache` for semantic
cache to see that route.

Clear the learned cache at runtime when examples, thresholds, or tenant data
have changed:

```elixir
:ok = Spectre.Router.SemanticCache.clear(MyApp.SupportAgent)
```

Limit the built-in learned cache index count with `semantic_cache_capacity:`.
When the cache is full, Spectre drops the oldest learned Vettore index before
storing the newest one. Custom semantic cache adapters manage their own
capacity.

```elixir
Spectre.ask(MyApp.SupportAgent, "pricing please",
  # Keeps at most 100 learned Vettore indexes in Spectre's built-in ETS cache.
  semantic_cache_capacity: 100
)
```

For the built-in cache, clearing drops Spectre's in-memory Vettore cache and
online learned rows for that agent by default. Static dataset rows are read from
their configured sources again on the next lookup. Clearing does not edit source
files, DSL declarations, or classifier artifacts.

Custom adapters still win. Configure one of these when your app owns the cache:

```elixir
router(
  via: [:regex, :semantic_cache, :classifier],
  semantic_lookup: &MyApp.SemanticCache.lookup/2
)

# or
router(
  via: [:semantic_cache],
  semantic_cache: MyApp.SemanticCache
)

# or
router(
  via: [:semantic_cache],
  semantic_cache: {MyApp.SemanticCache, :lookup}
)
```

The adapter receives the text and opts:

```elixir
defmodule MyApp.SemanticCache do
  @behaviour Spectre.Router.SemanticCache

  def lookup(text, opts) do
    if Keyword.get(opts, :semantic_search?) do
      search_similar(text, opts)
    else
      exact_lookup(text, opts)
    end
  end

  defp exact_lookup(text, _opts) do
    case MyApp.Cache.get(text) do
      nil -> {:error, :miss}
      route -> {:ok, route}
    end
  end

  defp search_similar(text, _opts) do
    case MyApp.VectorStore.search(text, top_k: 3) do
      %{label: label, score: score} when score > 0.88 ->
        {:ok, %{label: label, accepted?: true, confidence: score, strategy: :semantic_cache_search}}

      _ ->
        {:error, :miss}
    end
  end

  def clear(agent, opts) do
    MyApp.VectorStore.clear(namespace: {agent, opts[:tenant_id]})
  end
end
```

`Spectre.Router.SemanticCache.clear/2` also calls configured module adapters'
`clear/2` callback. If `semantic_cache: MyApp.SemanticCache` is configured and
the module does not implement `clear/2`, clearing returns an error. A bare
`semantic_lookup:` function can be used for lookup, but it is lookup-only:
write, review, snapshot, and clear operations require either the built-in cache
or a `semantic_cache:` module.

There are two semantic-cache moments:

1. Exact lookup runs early, before classifier fallback. A trusted hot cache hit
   is cheap and stable.
2. Semantic search runs later, after local classifier evidence. That lets a
   broad vector search use classifier context without hiding deterministic or
   high-confidence local evidence.

Return a route-like map:

```elixir
%{
  label: :TECHNICAL_SUPPORT,
  accepted?: true,
  confidence: 0.91,
  strategy: :semantic_cache_search
}
```

Spectre maps the label back to the agent rule. If the label is not routeable for
the current rule set, the hit is ignored and traced.

Useful built-in learned-cache options:

- `semantic_cache_threshold` or `semantic_cache_search_threshold` changes the
  default search acceptance threshold of `0.88`.
- `semantic_cache_top_k` changes the Vettore search limit, default `3`.
- `semantic_cache_index` and `semantic_cache_index_options` configure the
  Vettore index, default `:flat`.
- `semantic_cache_compressed?` controls compressed ETS storage for the learned
  Vettore collection, default `true`.
- `semantic_cache_source` supplies dataset files.
- `semantic_cache_static?: false` disables offline/static rows for a call.
- `mirror_training_dataset?: false` disables labeled dataset mirroring.
- `semantic_learn_failure: :error` makes online learning write failures strict.

Online learned examples are reviewable:

```elixir
{:ok, rows} = Spectre.Router.SemanticCache.examples(MyApp.SupportAgent)
{:ok, row} = Spectre.Router.SemanticCache.verify(MyApp.SupportAgent, "scx_123")
{:ok, row} = Spectre.Router.SemanticCache.relabel(MyApp.SupportAgent, "scx_123", :BILLING)
:ok = Spectre.Router.SemanticCache.delete(MyApp.SupportAgent, "scx_123")
{:ok, path} = Spectre.Router.SemanticCache.snapshot(MyApp.SupportAgent, path: "priv/spectre/cache.jsonl")
{:ok, _summary} = Spectre.Router.SemanticCache.load_snapshot(MyApp.SupportAgent, path: "priv/spectre/cache.jsonl")
```

`examples/2` returns online learned rows by default. Use `source:
:offline_dataset`, `source: :static_route_example`, or `source: :all` to inspect
read-only static rows.
