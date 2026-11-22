# Intent examples, semantic lookup and training

`Spectre.IntentDataset` stores labeled examples for recognition. A reviewed
text example can support exact matching. A compatible vector lets that example
participate in semantic lookup. A local classifier has a separate training step.

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
  use Spectre.Agent, server: MyApp.SupportServer

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

Provide the Server, encoder and classifier modules. The built-in dataset needs
no separate Stack installation. If you bind a custom store, supply that
store's adapter to `intent_dataset`.

`semantic_examples:` gives the router known phrases for a route.
`collect_intent: true` enables runtime collection under the configured
collection policy. The flow default reaches `:pricing`, while
`collect_intent: false` opts `:delete_account` out. `dataset_lookup: false`
also excludes that route from dataset lookup. `protected: true` requests
confirmation for proposals made through that route. Training remains an
explicit offline operation. [Recognition strategy options](ROUTING.md).

## Review runtime examples

```elixir
{:ok, row} = Spectre.IntentDataset.put(
  "I need a custom subscription quotation",
  %{label: :pricing, strategy: :llm_classifier},
  agent: MyApp.SupportAgent)

{:ok, examples} = Spectre.IntentDataset.examples(MyApp.SupportAgent)
{:ok, verified} = Spectre.IntentDataset.verify(MyApp.SupportAgent, row.id)
```

The first argument to `put/3` is the example text. The result map names the
declared label and origin strategy. `agent:` identifies the owning Agent.
`row.id` identifies the exact example to review. Marking it verified makes it
eligible for lookup under the route and store policy.

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

The export command takes the Agent module and target JSONL path. By default,
it includes verified rows from the online dataset. `--include-unverified`
includes rows waiting for review. `--source all` also includes static
sources, and `--source online` selects only the online rows. Existing vectors
and profile metadata are preserved.

The embed command takes the Agent module, source and output paths. It uses the
encoder already configured by the Agent or Stack. The task validates labels
and profiles, reuses compatible saved vectors, and embeds rows missing a vector.
It replaces the target after the whole batch succeeds. Incompatible or
unidentified stored vectors fail validation.

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

| Task | Arguments and switches |
| --- | --- |
| `spectre.classifier.dataset` | Agent module, output path and optional repeated `--source` labeled files. `--pretty` controls JSON formatting. The default output is `training/dataset.json`. |
| `spectre.classifier.download_model` | Optional `--model` chooses the encoder model ID. Otherwise the task uses the configured classifier encoder. |
| `spectre.classifier.train` | Dataset path and output directory. Override the encoder with `--model`. `--accept-threshold` sets the minimum top score, `--margin-threshold` sets its gap over the second score, and `--high-confidence-threshold` lets a sufficiently strong score pass the classifier's margin rule. |

With the ExFastembed encoder, add the optional `:ex_fastembed` dependency to
your application before downloading or training. The trainer writes
classifier artifacts and a `semantic_cache.jsonl` companion containing the
training rows and saved vectors. Runtime filtering respects route eligibility
and reuses compatible vectors on load.

```elixir
config :spectre, :classifier,
  artifact_dir: "priv/spectre/support",
  encoder_model: "intfloat/multilingual-e5-small",
  embedding_adapter: Spectre.Classifier.Embeddings.ExFastembed
```

For the built-in adapter, declare
`classifier :local, Spectre.Classifier, artifact_dir: "priv/spectre/support"`
and add `:local_classifier` to the Agent's router strategies. The
`artifact_dir:` value points to the trainer's output, and the encoder
configuration must match the artifacts. The router's arbitration thresholds
can impose additional acceptance conditions. [Arbitration](ROUTING.md#visibility-thresholds-and-arbitration).

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
[retained training reference](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/TRAINING_0_3.md) for older configuration
and index-tuning details.
