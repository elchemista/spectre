# Provider Resilience

Spectre isolates routing-critical and turn-owning external calls behind
`Spectre.Provider.Call`. The boundary protects the caller from adapter crashes,
enforces a bounded wait, and produces a sanitized
`Spectre.Provider.Failure` for infrastructure failures.

The boundary currently covers:

- main response-model completion;
- LLM classifier completion;
- local classifier adapters;
- router embedding adapters;
- semantic-cache lookups;
- turn-handler callbacks.

Provider-specific training and semantic-cache administration remain explicit
host operations and are not silently given runtime retry policies.

## Default Timeouts

| Provider | Option | Default |
| --- | --- | ---: |
| LLM completion | `llm_timeout` | 60 seconds |
| Local classifier | `local_classifier_timeout` | 30 seconds |
| Embedding | `embedding_timeout` | 30 seconds |
| Semantic-cache lookup | `semantic_cache_timeout` | 30 seconds |
| Turn handler | `turn_handler_timeout` | 30 seconds |

`provider_timeout` is a common fallback when the provider-specific option is
absent. Use `:infinity` explicitly to remove the Spectre deadline.

Application defaults are ordinary configuration:

```elixir
config :spectre, :provider,
  llm_timeout: 45_000,
  local_classifier_timeout: 5_000,
  embedding_timeout: 10_000,
  semantic_cache_timeout: 2_000,
  turn_handler_timeout: 20_000
```

Closer configuration wins. Main model options can carry the LLM deadline:

```elixir
model MyApp.LLM,
  model: "small",
  llm_timeout: 30_000
```

Classifier-specific deadlines remain next to the classifier declaration:

```elixir
classifier MyApp.ClassifierLLM,
  local: MyApp.LocalClassifier,
  local_classifier_timeout: 2_000,
  llm_opts: [llm_timeout: 12_000]
```

Embedding and semantic lookup deadlines can be configured through their normal
agent/router options:

```elixir
embedding MyApp.Embeddings, embedding_timeout: 8_000

router
  via: [:semantic_cache, :embedding, :classifier, :llm_classifier],
  semantic_cache_timeout: 1_500
```

Per-call options passed to `Spectre.ask/3`, `Spectre.turn/3`, or
`Spectre.Router.evaluate/3` override agent and application defaults.

## Failure Contract

An adapter's deliberate `{:error, reason}` reply is preserved. Spectre does not
guess whether a domain/provider error is retryable.

Failures created by the execution boundary use:

```elixir
%Spectre.Provider.Failure{
  provider: :llm,
  kind: :timeout,
  reason: :deadline_exceeded,
  timeout: 30_000,
  retryable?: true
}
```

Kinds are:

- `:timeout`
- `:exception`
- `:exit`
- `:throw`
- `:crash`
- `:invalid_reply`
- `:configuration`

The failure excludes prompts, inputs, raw adapter output, exception messages,
and stack traces. It contains only the provider, category, safe reason code,
deadline, and a retryability hint for infrastructure failures.

During `Spectre.Router.evaluate/3`, the same boundary contributes a sanitized
call fact to the routing receipt. Each fact contains the provider, normalized
outcome, elapsed microseconds, whether a worker was invoked, and an optional
purpose such as `:classifier`. This is the canonical source for evaluation LLM
usage: a prompt-rendering failure before `Spectre.LLM` is entered does not count
as a model call. No prompt, input, provider response, or raw error is retained.

## Reply Validation

The boundary validates provider-specific success payloads before routing uses
them:

- LLM completion must return a binary;
- embeddings must be a non-empty list of numbers;
- local-classifier and semantic-cache route maps must carry a boolean
  `accepted?`, a label when accepted, numeric score fields, an atom strategy,
  and map-shaped metadata/scores when those optional fields are present.

Invalid values become a sanitized `:invalid_reply` failure that records the
field and value shape, never the value itself. A semantic-cache
`{:ok, %{accepted?: false}}` is a valid negative result and degrades like a
miss.

## Cancellation Semantics

Provider code runs in an isolated worker. Spectre terminates that worker when:

- its deadline expires; or
- the requesting process dies.

Logger metadata and Elixir's `$callers` chain are forwarded to the worker so
logging context and caller-aware test doubles continue to work.

Terminating the local adapter worker cannot guarantee that a remote HTTP
service cancels work it has already accepted. An adapter that needs remote
cancellation must implement it in its own client. Spectre guarantees that the
turn does not continue waiting for the abandoned call.

## Fallback And Retry Policy

Configured LLM fallback models still run after a timeout or other normalized
primary failure. The fallback receives the primary failure under
`opts[:primary_error]`.

Spectre does not automatically retry calls. Retries require provider-specific
knowledge about rate limits, idempotency, and billing, and therefore belong in
the adapter or an optional provider middleware package. The core boundary
supplies stable failure categories that such middleware can inspect.

## Streaming adapters

Streaming inference uses a different transport contract from synchronous
`Spectre.LLM.complete/2`. A provider package implements
`Spectre.Inference.StreamAdapter`; Spectre keeps Run ownership, budgets,
cancellation, steering, fences and terminal processing in the Instance.

Prefer adapters with `:pull_transport`. Spectre issues one transport credit at
a time and bounds every normalized batch. A push adapter is accepted only when
it declares both `:push_transport` and `:bounded_push_transport`; that second
capability certifies that the provider/client imposes a real bound before
messages enter the session mailbox. The core never treats an Erlang mailbox as
a backpressure mechanism.

Adapter callbacks run in the supervised stream session, must return promptly,
and must never expose credentials or raw provider errors in normalized events.
Provider request ids and resume cursors are confidential recovery coordinates,
not observer or receipt fields. A transport can optionally declare `:resume`,
`:reconcile`, `:incremental_usage` and `:cost_usage`; missing capabilities fail
closed when the requested recovery or budget guarantee depends on them.

The core supplies `max_transport_chunk_bytes` and
`max_parser_residual_bytes` to every streaming adapter. The adapter owns and
must enforce those raw transport/parser bounds with
`:provider_stream_overflow`; normalized delta binaries may cross UTF-8
codepoint boundaries because the core reassembles them incrementally.

See [Streaming inference](STREAMING_INFERENCE.md) for the callback contract,
limits and restart semantics.
