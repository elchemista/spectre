# Testing

Spectre's tests are designed around boundaries and invariants, not only
successful conversations.

## Local commands

```bash
mix test
mix test --cover
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
mix docs
```

The repository coverage threshold is 90%. Do not lower or exclude modules to
make a change pass; add a meaningful test or explain why a private branch is
unreachable and simplify the implementation.

## Strategy matrix

`test/strategy_matrix_test.exs` defines ten agents with different prevailing
strategies:

1. deterministic regex;
2. local classifier over weak regex evidence;
3. exact semantic cache;
4. vector semantic search after an exact miss;
5. bag distance;
6. Jaro distance;
7. local FastEmbed-compatible embeddings;
8. LLM fallback;
9. mounted Skill routing;
10. structured prompt injection.

Each agent executes 80 cases. Twenty are accepted routing scenarios and sixty
exercise unmatched input, invalid state, unknown flow, invalid pipeline, empty
input, serialized state, or malformed flow data. The resulting 800 cases keep
the same route vocabulary while varying which strategy is allowed to prevail.

## FastEmbed fixture

The committed ETF fixture was generated from local ExFastembed vectors and is
read through a deterministic test backend. The embedding strategy still calls
the production `Spectre.Classifier.Embeddings.ExFastembed` adapter, so adapter
normalization remains covered without downloading a model during CI.

To regenerate it from a local ExFastembed checkout:

```bash
mix run scripts/generate_strategy_embeddings.exs -- \
  --ex-fastembed-path ../ex_fastembed \
  --model BAAI/bge-small-en-v1.5
```

Review the resulting binary change and run the entire strategy matrix. Do not
regenerate fixtures opportunistically in CI.

## What requires a regression test

- every lifecycle source/status transition;
- policy accept, reject, retry, exhaustion, expiry, and invalid labels;
- stale and ambiguous persistence outcomes;
- provider success, declared error, invalid reply, timeout, exception, exit,
  throw, and cancellation;
- prompt source, target, condition, trust, path, and size failures;
- state codec migration and unsafe-value rejection;
- action registration, ownership, Skill scope, and idempotent replay;
- semantic-cache misses, thresholds, mutations, snapshot corruption, and index
  ownership;
- privacy of journal, telemetry, evaluation receipt, and failure metadata.

Application repositories should add end-to-end tests for their own state store,
action idempotency, authorization, delivery, prompts, models, and recovery
workflow. The Spectre suite cannot prove those host-owned boundaries.

