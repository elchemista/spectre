# Production Operations

This guide describes the host responsibilities for running Spectre in a real
product. Spectre provides deterministic runtime transitions; it does not replace
application-level authorization, persistence, queues, or observability.

## Release status

`0.1.x` is a public preview. Runtime invariants are tested and the suite exceeds
90% line coverage, but public APIs may still change in a minor `0.x` release.
Pin a compatible minor version and read `CHANGELOG.md` before upgrading.

## State persistence

Use a durable state adapter for multi-process, multi-node, or restart-safe
conversations. Prefer compare-and-set persistence with the current revision:

```elixir
defmodule MyApp.AgentState do
  @behaviour Spectre.State.Store

  @impl true
  def load(input, opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    MyApp.AgentStates.fetch(conversation_id, input)
  end

  @impl true
  def persist(state, expected_revision, _input, _agent, _opts) do
    MyApp.AgentStates.compare_and_set(
      state.conversation_id,
      expected_revision,
      Spectre.State.Codec.encode!(state)
    )
  end
end
```

Treat `{:error, :stale_state}` as a concurrency signal. Treat
`{:error, {:persistence_ambiguous, reason, result}}` as an uncertain commit and
reconcile it from durable state before retrying external work. Spectre produces
that ambiguous result not only when an adapter explicitly returns
`{:error, {:ambiguous, reason}}`, but also when an invoked state callback
raises, exits, throws, is killed, times out, or returns a malformed result. Any
of those failures can happen after the store committed.

With a strict synchronous persistence journal, compare-and-set can succeed
before the audit append fails. That result is returned as
`{:error, {:persistence_journal_failed, reason, committed_result}}`. A Session
retains `committed_result`; request-scoped callers must do the same or reload
the durable state. Do not retry the old revision as though no write occurred.

## Action idempotency

Every effect has an `id` and `idempotency_key`. Store the key at the real
business boundary and make duplicate execution return the already committed
outcome:

```elixir
def perform(args, ctx) do
  key = Keyword.fetch!(ctx.opts, :idempotency_key)

  MyApp.Idempotency.once(key, fn ->
    MyApp.Payments.capture(args)
  end)
end
```

Do not retry an ambiguous effect merely because the terminal Spectre state was
not observed. First inspect the application idempotency record.

## Sessions and supervision

Start `Spectre.Supervisor` in the application tree when using live sessions:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

A session serializes calls for one conversation and protects against stale
execution results. It is not durable storage. Configure an explicit state
adapter when state must survive a process or node failure.

Use finite `idle` or `shutdown` values for high-cardinality conversation
workloads. Supervisors may recreate a session from durable state on demand.
Sessions use transient restart semantics: abnormal exits restart under a
supervisor, while normal dismiss and idle shutdown stay stopped. A failed
initial restore must not leave a registered process behind.

## Provider deadlines

Every external callback should have a finite deadline. Spectre supplies
conservative defaults and accepts provider-specific overrides:

```elixir
config :spectre, :provider,
  llm_timeout: 30_000,
  classifier_timeout: 5_000,
  embedding_timeout: 10_000,
  semantic_cache_timeout: 5_000,
  action_timeout: 60_000,
  state_timeout: 5_000
```

The local worker is terminated after a timeout. Cancellation of work already
sent to a remote service depends on the host adapter and its client library.

## Journal and telemetry

Journaling is disabled unless configured. A safe production default is
asynchronous delivery without conversation content:

```elixir
journal MyApp.SpectreJournal,
  events: :all,
  mode: :async,
  on_error: :warn,
  include_input: false,
  include_reply: false,
  buffer_size: 1_000,
  overflow: :drop_newest,
  retention: %{class: :operational, days: 30}
```

Add a redactor even when content recording is disabled if metadata can contain
tenant identifiers or regulated data. Journal writes, telemetry handlers, and
monitor fallback callbacks must not perform unbounded blocking work.

`Spectre.Telemetry` emits privacy-safe events under the `[:spectre, ...]`
prefix. A `telemetry_handler:` callback works without adding `:telemetry` as a
runtime dependency; if the standard library is installed, events are sent to it
as well.

## Semantic cache

The built-in cache is owned by a supervised process and survives individual
request-process exits, but its online rows are ETS data. Snapshot verified rows
or use a custom durable adapter when learned examples must survive application
restarts.

Only cache routes that are safe to replay as classifications. Keep destructive
or highly contextual routes at `cache: false`, and require review before using
unverified online examples in sensitive flows.

## Deployment checklist

- Pin Spectre and read the changelog.
- Use durable state with optimistic revisions where concurrency is possible.
- Make business actions idempotent by effect key.
- Configure finite provider deadlines.
- Keep authorization in the action/provider boundary.
- Keep prompt, journal, and telemetry content privacy-safe.
- Configure session idle shutdown for unbounded conversation IDs.
- Snapshot or externalize learned semantic-cache rows and their embeddings;
  runtime snapshot loading must not regenerate stored vectors.
- Run route evaluation against version-controlled cases before deployment.
- Exercise policy rejection, timeout, stale state, and ambiguous persistence in
  application integration tests.
- Inject failures immediately before and after each host-owned durable commit,
  then assert callback cardinality, durable state, restart behavior, and
  idempotent replay.
