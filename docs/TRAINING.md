# Training

Training examples live in labeled datasets. Runtime routing does not accept a
`train:` DSL flag; local classifier artifacts and semantic-cache dataset
mirroring are separate systems.

For modern labeled datasets, write rows with `text` and `label`/`intent` and let
the classifier trainer consume them directly:

```json
[
  {"text": "how much does it cost?", "label": "PRICING"},
  {"text": "my API key is failing", "intent": "TECHNICAL_SUPPORT"}
]
```

Classifier artifacts route by label when `:classifier` can see the route.
Semantic cache mirrors labeled dataset rows by default unless the route uses
`cache: false`.

You can configure those sources globally:

```elixir
config :spectre, :classifier,
  dataset_path: "training/dataset.json",
  artifact_dir: "artifacts/spectre"
```

Do not put training examples in the DSL. `train:`, `training:`,
`train: [...]`, `train: "file.jsonl"`, and similar inline training forms are
invalid.

Dataset files can be:

- `.json` list of objects
- `.jsonl` one object per line

Rows can use either `label` or `intent`. Labeled `.json` and `.jsonl` rows are
also mirrored into the built-in semantic cache by default for cacheable routes:

```json
[
  {"text": "how much does it cost?", "label": "PRICING"},
  {"text": "my API key is failing", "intent": "TECHNICAL_SUPPORT"}
]
```

Export rows from an agent:

```bash
mix spectre.classifier.dataset MyApp.SupportAgent \
  training/support/dataset.json \
  --source training/raw/support.jsonl
```

Train a local classifier artifact:

```bash
mix spectre.classifier.download_model --model intfloat/multilingual-e5-small
mix spectre.classifier.train training/support/dataset.json priv/spectre/support
```

Configure the classifier:

```elixir
config :spectre, :classifier,
  artifact_dir: "priv/spectre/support",
  encoder_model: "intfloat/multilingual-e5-small",
  embedding_adapter: Spectre.Classifier.Embeddings.ExFastembed
```

Classifier artifacts use compact centroids by default. At runtime, Spectre
indexes centroids with Vettore, so only one vector per label is mirrored into
the native index.

For larger datasets, nearest-example routing can be worth the extra memory:

```elixir
config :spectre, :classifier,
  local_classifier_mode: :examples,
  local_classifier_index: :hnsw,
  local_classifier_index_options: [ef_search: 64],
  local_example_score: :max
```

Use `:mean` for `local_example_score` if you prefer averaging returned hits per
label.
