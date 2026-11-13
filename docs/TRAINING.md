# Intent examples, semantic lookup and training

0.4 retains example collection, review, semantic lookup and classifier training.
The clearer application-facing name is **IntentDataset**: it stores labeled
examples, not cached model answers. Not every useful example already has a
vector; only rows with valid compatible embeddings enter the semantic index.

| Operation | What changes |
| --- | --- |
| Collect an accepted intent example | Adds an eligible labeled row, unverified by default. |
| Verify/relabel an example | Reviews its label and eligibility for ordinary lookup. |
| Exact lookup | Recognizes matching text without embedding the query. |
| Prepare embeddings | Adds compatible vectors for semantic lookup, without classifier training. |
| Train a local classifier | Builds classifier artifacts from a labeled corpus. |
| Load snapshots/artifact vectors | Reuses saved examples/vectors without regenerating every row. |

## Declare recognition and collection separately

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  embedding MyApp.Embeddings
  classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/intents"
  classifier :llm, MyApp.IntentModel, timeout: 8_000

  # Use the built-in dataset through the router strategy below.
  # A custom store can instead be bound with intent_dataset MyApp.Dataset, opts.

  router strategies: [:regex, :intent_dataset, :embedding,
                       :local_classifier, :llm_classifier]

  flow :support, defaults: [collect_intent: true] do
    on :pricing, semantic_examples: ["How much does a subscription cost?"]
    on :delete_account, regex: ~r/^delete my account$/i,
      collect_intent: false, dataset_lookup: false, protected: true
  end
end
```

The referenced embedding/classifier adapters and Server must be supplied by the
host. This example uses the built-in dataset without a custom adapter binding.
Do not bind `Spectre.Router.SemanticCache` as its own adapter: it is the dispatcher,
so that configuration would recurse instead of reaching the built-in store.
`collect_intent:` replaces the unclear `learn:` spelling in new declarations.
It enables eligible runtime collection under the configured collection policy;
it does not mean every matched input is automatically promoted to ground truth.
`train:`, `training:` and inline training DSL forms are not supported.

## Review runtime examples

```elixir
{:ok, row} = Spectre.IntentDataset.put(
  "I need a custom subscription quotation",
  %{label: :pricing, strategy: :llm_classifier},
  agent: MyApp.SupportAgent)

{:ok, examples} = Spectre.IntentDataset.examples(MyApp.SupportAgent)
{:ok, verified} = Spectre.IntentDataset.verify(MyApp.SupportAgent, row.id)
```

Use `update_example`, `relabel`, `delete`, `snapshot` and `load_snapshot` to manage
examples explicitly. Online rows remain unverified by default. Review APIs can
list them without making them available to ordinary recognition. An explicit
`lookup: [include_unverified: true]` changes that policy and should not be the
unexplained default in application examples.

A text-only verified row may support exact recognition. It does not enter the
vector index until a valid vector with compatible profile metadata exists.
Never fabricate a zero vector or silently relabel an unknown encoder profile
as the active one. Collection and review do not grant execution authority.

## Export and prepare vectors independently

```bash
mix spectre.intent_dataset.export MyApp.SupportAgent examples.jsonl
mix spectre.intent_dataset.embed MyApp.SupportAgent examples.jsonl vectors.jsonl
```

Export includes verified rows by default; `--include-unverified` is explicit.
The embedding command uses the encoder already configured by the Agent/Stack.
It validates labels and profiles, reuses compatible saved vectors and embeds
only rows missing them. It neither chooses a remote model nor trains a classifier.
The output replaces its target only after the whole batch succeeds; incompatible
or unidentified stored vectors fail instead of being silently reassigned.

Labeled sources can use JSON arrays or JSONL records with `text` and `label`
(or the retained `intent` field). Labels must correspond to the Agent's declared
routes and obey their dataset-lookup restrictions.

```json
[
  {"text": "How much is the monthly subscription?", "label": "pricing"},
  {"text": "My API key stopped working", "label": "technical"}
]
```

The example's `technical` label requires a corresponding route in your Agent.
No runtime-created atom or invented route is added when loading a dataset.

## Train a local classifier

The existing classifier tasks remain available:

```bash
mix spectre.classifier.dataset MyApp.SupportAgent \
  training/support/dataset.json --source training/raw/support.jsonl
mix spectre.classifier.download_model --model intfloat/multilingual-e5-small
mix spectre.classifier.train training/support/dataset.json priv/spectre/support
```

Model download/training requires the appropriate host embedding dependencies.
The trainer writes local classifier artifacts and a `semantic_cache.jsonl`
companion containing training rows and their saved vectors. That retained
filename is an artifact format, not a reason to call all text examples a cache.
Runtime filtering respects route eligibility and reuses vectors rather than
embedding every dataset row on load.

```elixir
config :spectre, :classifier,
  artifact_dir: "priv/spectre/support",
  encoder_model: "intfloat/multilingual-e5-small",
  embedding_adapter: Spectre.Classifier.Embeddings.ExFastembed
```

Classifier centroid/example indexes and semantic row lookup are distinct.
Vettore provides the indexes; quantized candidate search may use Hamming distance
and full-metric reranking. That optimization still requires compatible vectors.
Choose CPU/GPU/index options according to the installed Vettore release and the
actual workload; training an artifact does not change the response model.

## Retained storage and migration

`Spectre.IntentDataset` delegates to the existing supervised example store and
artifact/snapshot machinery. Existing `Spectre.Router.SemanticCache` management
APIs remain for compatibility. Old `learn`, `cache` and semantic-cache settings
are translated where supported; conflicting aliases fail rather than silently
changing collection policy.

Text-only rows remain useful for exact intent recognition and future corpus
preparation. The semantic index remains vector-only. These are separate uses of
the same reviewed examples, not two competing stores.

See [Routing](ROUTING.md), [DSL](DSL.md), [migration](MIGRATING_TO_0_4.md) and the
[retained training reference](legacy/TRAINING_0_3.md) for older configuration
and index-tuning details.
