# Routing in AgentServer 0.4

Routing recognizes an input and selects a declared Server handler. It does not
execute the handler's consequence or confer authority. The existing evidence
pipeline, arbitration, classifiers and fallback remain; the new Server owns the
conversation around them.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/intents"
  classifier :llm, MyApp.IntentModel, timeout: 8_000
  embedding MyApp.Embeddings

  router strategies: [:regex, :intent_dataset, :bag, :jaro,
                       :embedding, :local_classifier, :llm_classifier]

  flow :support, defaults: [collect_intent: true] do
    on :pricing,
      regex: ~r/^prices?$/i,
      semantic_examples: ["How much does it cost?", "Subscription plans"]

    on :delete_account, regex: ~r/^delete my account$/i,
      collect_intent: false, dataset_lookup: false, protected: true
  end
end
```

The named adapters are application dependencies. The response model can be
configured separately; using a small intent model does not force responses to
use that model too. Installed Stack extensions may provide these bindings.

## Recognition pipeline

The Runtime prepares input once, handles an existing foreground pending intention
if applicable, and runs recognition in a worker. The router collects evidence
from visible rules; arbitration selects a result. A successful route reaches
`handle_flow({:support, :pricing}, input, ctx)`. Nested flows and mounted Skills
retain their complete path/scope in the dispatch key.

| Strategy | Evidence |
| --- | --- |
| `:regex` | Declared text patterns. |
| `:intent_dataset` | Verified exact examples and, when enabled, compatible vector examples. |
| `:bag`, `:jaro` | Declared string-similarity examples. |
| `:embedding` | Similarity against route `semantic_examples`. |
| `:local_classifier` | Local classifier/host adapter result. |
| `:llm_classifier` | Model arbitration over declared visible labels. |
| Native Router Adapter module | Closed route refs and scores from a host evidence source. |

`strategies:` expands to router plugs and appends arbitration/terminalization.
The default arbitrator can short-circuit sufficient hard evidence; do not
assume every listed provider always runs. An explicit custom `pipeline:` owns
its complete plug ordering and must include the arbitration/terminalization
steps it needs.

The legacy spellings `via:`, `:semantic_cache` and `:classifier` remain aliases.
New examples use `strategies:`, `:intent_dataset` and `:local_classifier`.
Conflicting aliases are errors rather than precedence rules.

## Thresholds, visibility and scope

```elixir
router strategies: [:regex, :embedding, :local_classifier, :llm_classifier],
  embedding: [min_score: 0.85, min_margin: 0.05],
  local_classifier: [min_score: 0.90, min_margin: 0.05],
  log_decisions: true

flow :billing do
  on :invoice, semantic_examples: ["Send me my invoice"],
    match_with: [:embedding, :llm_classifier],
    check: {:language, ["en", "english"]}
end
```

Per-route visibility and input checks apply before a provider sees a rule.
Current flow/scope prioritization does not erase other declared routes. A local
classifier or model cannot invent an undeclared destination. Native adapters
return refs that Spectre resolves against the current visible rule set.

The default arbitrator keeps provider evidence separate. Similarity scores,
acceptance thresholds, margins and conflict/no-decision settings are recognition
policy, not execution authorization. Custom arbitrators remain supported. The
[retained detailed router reference](legacy/ROUTING_0_3.md) documents low-level
plug options, adapter contracts and arbitration rules; its older handler examples
belong to the compatibility runtime.

## No match, ambiguity and provider failures

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

`:understand` is a prompt/continuation chosen by the application. There is no
implicit `understand/` helper to implement. The application can ask another
model, clarify with the user, consult memory or start an explicitly bounded
classification step from this callback.

A dataset miss is not an infrastructure failure. Working later strategies can
still recognize the input. If the recognition path fails, its cause is retained
instead of being turned into a confident intent. A legacy declared `UNKNOWN`
route remains a declared route and is separate from technical failure.

## Pending input precedes ordinary routing

A short yes/no while consent is open belongs to `handle_pending/3`; it does not
need a global yes route. That handler may call a classifier with explicit
choices or use ordinary functions. Its result selects a transition, while GAM's
fixed ingress still interprets and authenticates the original response against
the actual Presentation.

For a new topic, use `route_current_input(ctx, suspend: pending.id)`. This routes
the same prepared input without running the input pipeline twice. Add a durable
closure policy if the old intention should expire. See
[Pending lifecycle](PENDING_LIFECYCLE.md).

Classifying or embedding does not automatically require a consent ceremony.
If a host declares protected access, disclosure or consumption as governed,
that transition must use its governed boundary; a cognitive callback name is
not an exemption. `protected: true` also requests the standard bridge's
confirmation path; a router result still never supplies a Mandate. See [GAM](GAM.md) and the
[manifesto](https://spectre.guide/en/governed-act-model).

## IntentDataset, semantic lookup and collection

`Spectre.IntentDataset` names the labeled-example store. It is not a response
cache. Text-only examples support exact recognition and later training; the
vector index includes only valid compatible embeddings. An exact hit makes no
embedding call. A semantic miss may require an embedding of the incoming text.

`collect_intent: true` opts a route into eligible collection. New online examples
are unverified by default and excluded from ordinary recognition until reviewed
or explicitly included. Collection does not train the local classifier.
`dataset_lookup: false` excludes a route from dataset recognition; do not replace
it casually with the narrower legacy `cache: false` custom-adapter behavior.

Export/review, batch embedding, classifier training and loading stored vectors
are explained in [Training](TRAINING.md). Quantized Vettore candidate search
can use Hamming distance with full-metric reranking; it does not remove the need
for compatible embeddings or turn unlabeled text into an authorized route.

## Add a native Router Adapter

```elixir
defmodule MyApp.TicketRouter do
  use Spectre.Router.Adapter,
    id: :ticket_vectors, accept: 0.87, margin: 0.04, strength: :medium

  def evaluate(%Spectre.Router.Adapter.Request{text: text, rules: rules}) do
    allowed = Map.new(rules, &{&1.ref, &1})

    with {:ok, hits} <- MyApp.TicketIndex.search(text, limit: 32) do
      {:ok,
       Enum.flat_map(hits, fn hit ->
         case Map.fetch(allowed, hit.rule_ref) do
           {:ok, rule} -> [result(rule, hit.score, margin: hit.margin)]
           :error -> []
         end
       end)}
    end
  end
end
```

Register the adapter module in `router strategies: [:regex, MyApp.TicketRouter,
:llm_classifier]`. Declare relevant route options under `ticket_vectors:` and
use `match_with:` when restricting visibility. The index is a host dependency.
The request contains bounded input/rule views, not executable handlers or
runtime capabilities. Treat text and metadata as application data when logging.
Run `Spectre.Router.Adapter.Conformance` with isolated fixtures in CI.

## Evaluate recognition without running a handler

```elixir
{:ok, receipt} = Spectre.Router.evaluate(MyApp.SupportAgent, "show prices")
```

This runs configured input/router providers and returns a bounded recognition
receipt. It does not execute the winning handler, load normal state/memory
adapters or collect new examples. Provider calls may still incur usage. Use
[Routing evaluation](EVALUATION.md) for corpus comparisons; a routing score does
not validate downstream GAM bindings or effects.
