# Production Operations

This guide describes the host responsibilities for running Spectre in a real
product. Spectre provides deterministic runtime transitions; it does not replace
application-level authorization, persistence, queues, or observability.

## Release status

`0.2.0` is the first vNext core release. Runtime invariants are tested and the
suite exceeds 90% line coverage, but public APIs may still change in a minor
`0.x` release. Pin a compatible minor version and read `CHANGELOG.md` before
upgrading. The exact compatibility boundary is listed in `PUBLIC_API.md`.
Patch releases preserve that documented safe boundary. A patch may remove an
accidental raw-data exposure that contradicted an existing privacy or security
guarantee; such corrections and their replacement fields are identified in the
changelog rather than silently treated as ordinary feature work.

Before deploying an upgrade, run `Spectre.Foundation.Conformance` against
representative durable backups and verify every compiled Definition/Manifest
pair. Umbrella applications and satellite suites should also run
`Spectre.Stack.Conformance` against the complete installed package set. These
gates complement, rather than replace, restart and side-effect idempotency
tests. See [Foundation Conformance](FOUNDATION_CONFORMANCE.md).

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

### Canonical Instance checkpoints

`Spectre.State.Store` persists conversational state. Work, Vigil, external
controller, control, event, consent, and receipt sections belong to the
Instance's complete canonical checkpoint and use the separate
`Spectre.Instance.CheckpointStore` compare-and-swap boundary.

Configure a durable checkpoint store for any operational loop that must
survive process or node loss. If a write can have committed before an adapter
timeout or crash, return `{:error, {:ambiguous, reason}}`. Spectre fences
further automatic writes until `Spectre.reconcile_checkpoint/2` loads and
validates durable state. Monitor `checkpoint_status/1`, and use
`flush_checkpoint/2` as a deployment or graceful-shutdown barrier.

The format-tagged Instance checkpoint schema 3 includes the current Definition
Activation, retained Run continuations, Definition lifecycle and event records,
private Skill-state branches, inference control/progress, and the required
receipt outbox. Configure the same durable `Spectre.Definition.Store` on
restart so Spectre can re-read every pinned Definition and verify its closure.
The bundled in-memory Definition Store is not valid beside a durable
Checkpoint Store.

Before upgrading an existing checkpoint namespace to 0.2.3, implement
`migrate_instance_key/5` atomically and drain old owners. A local Registry is
not a distributed ownership guarantee; multi-node deployments must also
configure a linearizable `Spectre.Instance.Owner` lease adapter. See
[Migrating to 0.2.3](MIGRATING_TO_0_2_3.md).

Historical 0.2.x upgrade note: before upgrading live checkpoint namespaces to
0.2.5, operators had to quiesce schema-3 writers because 0.2.4 could not read
schema 4. Spectre 0.3.0 and 0.3.1 instead introduced a format-tagged schema 2;
the current v3 reader accepts that tagged family and rejects the untagged
legacy families. Do not point a current deployment at a legacy namespace
without an explicit, externally verified conversion. Quiesce v2 writers before
the first v3 write because an old reader cannot roll a v3 checkpoint back.
Inventory host-side references before marking any Skill-state branch
GC-eligible: core sees its Activation, Runs, operations, and child branches,
but not application tables or backups. See
[Migrating to 0.2.5](MIGRATING_TO_0_2_5.md).

Canonical operational history is bounded by default. An Instance retains the
256 most recently updated terminal loops and up to 1,024 additional historical
correlations, while always preserving live loops and their primary
correlations. Tune the limits when starting the Instance:

```elixir
operation_terminal_loop_retention: 256,
operation_correlation_retention: 1_024
```

Both options accept a non-negative integer or `:unlimited`. Use `:unlimited`
only with an external compaction policy: every checkpoint serializes the full
canonical value. The Subject Registry independently defaults to 4,096 live
link intents and 1,024 terminal audit intents (`link_intent_capacity` and
`link_intent_retention`), for a bounded maximum of 5,120 retained intents.

Nested custom structs in conversational state are restored from their module
name and fields. That is a storage representation, not a struct migration
protocol: keep the module loadable and backward compatible, or persist an
application-owned versioned map and migrate it before constructing the struct.

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

### Streaming inference

Use streaming only through an Agent Instance and a bounded
`Spectre.Inference.StreamAdapter`. Prefer pull-capable transports. A push
adapter must enforce its bound before the session mailbox and declare
`:bounded_push_transport`; otherwise admission fails.

Keep finite attach, open, provider-stall, consumer-idle, result and absolute
duration limits. Size `max_stream_sessions` per Instance and the node-wide
stream-capacity limit for the provider and deployment.
Monitor explicit `:consumer_never_attached`, `:interrupted` and `:ambiguous`
terminals. Never treat a provisional delta as a committed reply.

Recovery requires provider-specific truth. Configure a stable adapter binding
and use `:resume` only with a durable cursor or `:reconcile` only with a stable
provider request id. Without those capabilities Spectre fails explicitly; it
does not silently redispatch uncertain billed work. See
[Streaming inference](STREAMING_INFERENCE.md).

### Boundary receipt delivery

Receipt mode is disabled by default. `:observational` delivery is suitable for
best-effort audit/telemetry. `:required` delivery is a correctness boundary and
must use a durable Checkpoint Store plus a payload-capable, idempotent
`Spectre.Receipt.Sink`. Run the sink conformance suite, retain payload objects
while outbox entries can reference them, and alert on pending delivery or
checkpoint reconciliation.

Receipt envelopes can contain confidential portable payloads. Encrypt and
tenant-isolate the sink; do not send envelope payloads to logs or metrics.
Receipts prove evidence linkage and state roots, not exactly-once external work
or deterministic replay. See [Boundary receipts](RECEIPTS.md).

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
runtime dependency; if the standard library is installed, events are sent to
it as well. The two paths are failure-isolated. Treat measurements as numeric
aggregation fields. Instance metadata uses `{agent, instance_id, generation}`
plus event-specific revisions, reason classes, and digested IDs. The
opaque `instance_id` is linkable across restarts, so it is a pseudonym rather
than an authorization token or secret and should not be used as an unbounded
metric label.

For checkpoint monitoring, poll `Spectre.checkpoint_status/1` and compare
`canonical_revision` with `persisted_revision`. Alert when `error` is non-nil
or `reconciliation_required` is present; `error` is a redacted class, not the
adapter's raw failure. Status and Instance info reads are passive and do not
extend the Instance idle lifetime; `trace_id/1` inherits that behavior because
it derives from info. Direct host-facing state and domain reads intentionally
count as Instance activity and re-arm the idle timer; use the monitoring
projections for polling.

The `:checkpoint_failed` telemetry event includes `outcome: :failed` for a
known failed persist and `outcome: :ambiguous` when the commit result is
unknown and reconciliation is required. Alert on the latter as a persistence
fence, not as proof that the write did not commit.

Before deployment, `mix spectre.doctor --strict` performs read-only runtime and
Foundation checks. Pass `--agent MyApp.Agent` to inspect its compiled
Definition, Manifest, configured Stack, and Checkpoint Store callback shape;
use `--format json` for automation. `Spectre.Doctor.run/1` also accepts an
explicit package matrix for release tooling. Database connectivity, migrations,
and package-specific health checks remain in the adapter package that owns
them.

## Semantic cache

The built-in cache is owned by a supervised process and survives individual
request-process exits, but its online rows are ETS data. Snapshot verified rows
or use a custom durable adapter when learned examples must survive application
restarts.

Online rows are capped at 1,000 per Agent by default and the least recently
updated rows are evicted. Set `semantic_cache_online_capacity` per call or
`:online_capacity` under `config :spectre, :semantic_cache`; `:unlimited` is
available only for hosts that enforce their own retention. Rule-example
embeddings use a separate 2,048-entry bounded cache and can be tuned with
`embedding_example_cache_capacity`.

Only cache routes that are safe to replay as classifications. Keep destructive
or highly contextual routes at `cache: false`, and require review before using
unverified online examples in sensitive flows.

## Deployment checklist

- Pin Spectre and read the changelog.
- Use durable state with optimistic revisions where concurrency is possible.
- Persist canonical Instance checkpoints before relying on Work or Vigil
  recovery, and reconcile every ambiguous compare-and-swap result.
- Quiesce old checkpoint writers during schema upgrades, and retain private
  Skill-state branches until both core and host-side references are retired.
- Configure finite streaming limits and test consumer halt, provider stall,
  Instance restart, cancellation and steering races before enabling streaming.
- Use a durable, payload-capable sink before selecting required receipt mode;
  monitor and reconcile its checkpointed outbox.
- Make business actions idempotent by effect key.
- Give every operational side effect an accurate `:idempotent`,
  `:reconcilable`, or `:non_idempotent` declaration.
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
