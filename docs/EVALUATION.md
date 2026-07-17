# Routing Evaluation

Spectre's evaluation tools measure two different properties together:

- whether the router selected an expected route or outcome;
- whether it used the LLM classifier only when the case allowed or required it.

This catches a regression that route-only accuracy misses: a route can be
correct while still making an unnecessary model call.

## Run A Corpus

Store one JSON object per line:

```json
{"id":"deterministic-help","input":"help","expected_route":"HELP","expected_strategy":"regex","llm":"forbidden","tags":["deterministic","english"]}
{"id":"local-help","input":"show me the available commands","expected_route":"HELP","llm":"forbidden","tags":["local","english"]}
{"id":"ambiguous-billing","input":"something is wrong with the invoice for my project","allowed_routes":["BILLING","PROJECT_SUPPORT"],"llm":"required","tags":["ambiguous","english"]}
```

Then run:

```bash
mix spectre.eval MyApp.Agent test/fixtures/routing.jsonl
```

The equivalent `--agent` form is:

```bash
mix spectre.eval --agent MyApp.Agent test/fixtures/routing.jsonl
```

The summary includes case pass rate, route accuracy, LLM policy violations,
outcomes, strategy usage, and p50/p95 routing duration.

## Case Fields

- `id` is a required stable case identifier.
- `input` is a required string or Spectre input-shaped object.
- `expected_outcome` is `route`, `clarify`, `unknown`, or `error`; it defaults
  to `route`.
- `expected_route` is one accepted label.
- `allowed_routes` adds other accepted labels for genuinely ambiguous cases.
- `expected_strategy` optionally fixes the expected winning provider.
- `llm` is `forbidden`, `allowed`, or `required`; it defaults to `allowed`.
- `state` supplies an explicit state snapshot without loading the configured
  state adapter. Existing flow names may be written as strings.
- `tags` groups cases for report analysis.
- `max_duration_us` optionally sets a per-case duration ceiling. Avoid tight
  ceilings for network-backed providers.

Blank lines and lines beginning with `#` are ignored. Invalid JSON or invalid
fields report the exact source line.

[`docs/examples/routing-eval.jsonl`](examples/routing-eval.jsonl) is a small
starter corpus. Its labels and expectations are illustrative and should be
adapted to the agent under evaluation.

## CI Thresholds And JSON Artifacts

By default, every case must pass and no forbidden or required LLM policy may be
violated:

```bash
mix spectre.eval MyApp.Agent test/fixtures/routing.jsonl \
  --json tmp/spectre-routing.json
```

Thresholds can be relaxed explicitly while a corpus is being calibrated:

```bash
mix spectre.eval MyApp.Agent test/fixtures/routing.jsonl \
  --min-pass-rate 0.98 \
  --max-unnecessary-llm 1 \
  --max-missing-llm 0 \
  --max-errors 0
```

The task exits unsuccessfully when thresholds are not met, so it can be used as
a CI regression gate. The JSON artifact contains privacy-safe receipts and
structured violations for every case.

## Programmatic API

Evaluate a complete corpus:

```elixir
{:ok, report} =
  Spectre.Eval.run(
    MyApp.Agent,
    "test/fixtures/routing.jsonl",
    router_opts: [tenant_id: "evaluation"]
  )

if Spectre.Eval.Report.acceptable?(report) do
  :ok
else
  {:error, report}
end
```

Evaluate one route:

```elixir
{:ok, receipt} =
  Spectre.Router.evaluate(
    MyApp.Agent,
    "show me my invoices",
    state: %Spectre.State{current_flow: :billing}
  )

receipt.label
receipt.strategy
receipt.llm_called?
receipt.attempts
```

`Spectre.Router.Receipt` excludes input text, prompts, model output, candidate
matches, and route handlers. It contains the outcome, winning label and
strategy, sanitized provider attempts and candidates, total duration, and a
`provider_calls` list with the normalized outcome and duration of every shared
provider-boundary invocation. `llm_called?` becomes true only when an LLM
adapter worker was actually invoked; selecting LLM arbitration before prompt
construction is not counted as model use.

A provider-call entry has only operational metadata:

```elixir
%{
  provider: :llm,
  purpose: :classifier,
  outcome: :ok,
  duration_us: 12_430,
  invoked?: true
}
```

Configuration rejected before a worker starts is recorded with
`invoked?: false`. Raw provider errors and responses are never copied into this
list.

## Execution Boundary

Evaluation runs the configured input and router pipelines because testing a
different path would give misleading results. It does not:

- load or persist through the state adapter;
- load or write memory;
- run the selected route handler;
- plan or execute actions;
- deliver journal records;
- write online semantic-learning examples.

Classifier, embedding, semantic-cache lookup, and LLM adapters are router
providers and therefore may be called. A real LLM evaluation can incur latency
and provider charges. CI should normally use deterministic adapter fixtures;
run a separate opt-in corpus when measuring a live provider.

The receipt is intended to become the common fact source for evaluation,
journaling, and minimal telemetry. It does not calculate monetary token cost or
export metrics.
