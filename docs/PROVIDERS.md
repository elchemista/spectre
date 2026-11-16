# Provider resilience in 0.4

Spectre isolates routing-critical and turn-owning external calls behind
`Spectre.Provider.Call`. The boundary protects the caller from adapter crashes,
enforces a bounded wait, and produces a sanitized
`Spectre.Provider.Failure` for infrastructure failures.

In AgentServer, routing and cognitive services execute in workers while the
Runtime remains the coordination owner. The existing provider-call boundary
continues to normalize failures inside those services. Installed tool adapters
also have their own prepare/invoke/project boundary, documented in
[Stack tools](STACK_TOOLS.md); not every arbitrary direct application call is
wrapped automatically.

These controls do not grant authority. Cognitive use does not automatically
ask for consent, but any protected disclosure or consumption declared in the
host's governed surface must use that boundary. See [GAM](GAM.md).

The shared provider boundary covers:

- main response-model completion;
- LLM classifier completion;
- local classifier adapters;
- router embedding adapters;
- native Router Adapters;
- semantic-cache lookups;
- legacy turn-handler callbacks (the retained Instance/Turn integration).

Provider-specific training and semantic-cache administration remain explicit
host operations and are not silently given runtime retry policies.

## Default Timeouts

| Provider | Option | Default |
| --- | --- | ---: |
| LLM completion | `llm_timeout` | 60 seconds |
| Local classifier | `local_classifier_timeout` | 30 seconds |
| Embedding | `embedding_timeout` | 30 seconds |
| Semantic-cache lookup | `semantic_cache_timeout` | 30 seconds |
| Router Adapter | `router_adapter_timeout` | 30 seconds |
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
  router_adapter_timeout: 5_000,
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
classifier :local, MyApp.LocalClassifier, timeout: 2_000
classifier :llm, MyApp.ClassifierLLM, timeout: 12_000
```

Embedding and semantic lookup deadlines can be configured through their normal
agent/router options:

```elixir
embedding MyApp.Embeddings, embedding_timeout: 8_000

router strategies: [:intent_dataset, :embedding, :local_classifier, :llm_classifier],
  semantic_cache_timeout: 1_500,
  router_adapter_timeout: 5_000
```

`router_adapter_timeout` bounds one native Adapter call. `router_timeout`
continues to bound the complete routing pipeline; changing one does not change
the other. Resolution order is `router_adapter_timeout`, then
`provider_timeout`, then the 30-second default.

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

A native Router Adapter uses `provider: :router_adapter` and its compiled id as
the purpose. The same enriched event reaches the observer and generic provider
telemetry, so Router receipts and corpus evaluation see the call without a
second instrumentation path. Adapter-specific events are emitted as
`[:spectre, :router, :adapter, :start]` and
`[:spectre, :router, :adapter, :stop]`; they contain only id, outcome,
invocation state, duration, and result count. Every Adapter step reached emits
this span. A pre-invocation skip uses `outcome: :skip`, `invoked?: false`, and a
bounded `skip_reason` such as `:hard_candidate`, `:no_visible_rules`, or
`:descriptor_unavailable`. Because no provider boundary was entered, the skip
does not create a synthetic `provider_calls` receipt entry.

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

The synchronous provider-call boundary does not automatically retry a failed
call. Adapter retries need provider-specific rate-limit, idempotency and billing
knowledge. This is distinct from Server crash recovery: an unfinished safe
cognitive command may be invoked again with the same command identity. A tool
declaring `retry: :never` becomes uncertain after interruption or loss of a usable
receipt. Governed effects use their original GAM journal instead of a generic
provider retry. See [AgentServer recovery](AGENT_SERVER.md#checkpoints-and-reconciliation).

## Streaming adapters

Streaming inference uses a different transport contract from synchronous
`Spectre.LLM.complete/2`. A provider package implements
`Spectre.Inference.StreamAdapter`. In the new Server path, a monitored worker
and transport guard own provider transport while the Runtime owns conversation
coordination and terminal continuations. The retained Instance path owns its
separate Run/stream-handle protocol. See [Streaming inference](STREAMING_INFERENCE.md).

Prefer adapters with `:pull_transport`. Spectre issues one transport credit at
a time and bounds every normalized batch. A push adapter is accepted only when
it declares both `:push_transport` and `:bounded_push_transport`; that second
capability certifies that the provider/client imposes a real bound before
messages enter the session mailbox. The core never treats an Erlang mailbox as
a backpressure mechanism.

Adapter callbacks run in their owning stream worker/session, must return promptly,
and must never expose credentials or raw provider errors in normalized events.
Provider request ids and resume cursors are confidential recovery coordinates,
not observer or receipt fields. The shared adapter contract can declare
`:resume`, `:reconcile`, `:incremental_usage` and `:cost_usage`; their use depends
on the owning runtime. Do not infer the retained Instance resume/steering
semantics for Server generation from adapter capability flags alone.

The core supplies `max_transport_chunk_bytes` and
`max_parser_residual_bytes` to every streaming adapter under the
`:spectre_bounds` keyword namespace. The adapter owns and must enforce those
raw transport/parser bounds with `:provider_stream_overflow`; the conformance
runner exercises both limits through the adapter's `conformance_fixture/4`.
Normalized delta binaries may cross UTF-8 codepoint boundaries because the
core reassembles them incrementally.

The supplied values default to 256 KB but are not hard ceilings. Applications
override them with `stream_max_transport_chunk_bytes` and
`stream_max_parser_residual_bytes`; adapters must use the resolved values in
`:spectre_bounds`, never their own copy of Spectre's defaults.

Adapters decode transport and emit provider text; they do not own visible-text
policy. Model-specific cleanup belongs in an optional module implementing the
`Spectre.Reply.Sanitizer` callbacks, configured with `:reply_sanitizer`. That
module can live in Pulse or another host package while Spectre retains the
mandatory structural and bounded-memory boundary.

See [Streaming inference](STREAMING_INFERENCE.md) for the callback contract,
limits and restart semantics.
