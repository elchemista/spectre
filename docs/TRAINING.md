# Training

Training examples live in datasets. The DSL only marks which routes and policy
branches should consume those examples.

Mark a route as trainable:

```elixir
on :PRICING, train: true do
  reply(:pricing)
end
```

Use `train: true` for every trainable route:

```elixir
on :TECHNICAL_SUPPORT, train: true do
  ask(:technical_support)
end
```

You can configure those sources globally:

```elixir
config :spectre, :classifier,
  dataset_path: "training/dataset.json",
  artifact_dir: "artifacts/spectre"
```

`train:` is a boolean flag. Do not put examples in the DSL; `training:`,
`train: [...]`, `train: "file.jsonl"`, and similar inline training forms are
invalid.

Dataset files can be:

- `.json` list of objects
- `.jsonl` one object per line
- plain text, one example per non-empty non-comment line

Rows can use either `label` or `intent`:

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
