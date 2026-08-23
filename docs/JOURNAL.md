# Journal

Spectre's journal is an opt-in stream of structured explanation records. It is
separate from chat history and logs:

- chat history is context that may influence a later turn;
- journal records explain an individual runtime decision;
- logs and telemetry describe operational health.

The current implementation records Run, routing/arbitration, policy, lifecycle,
execution, and persistence boundaries. All phases carry stable correlation
identities and exclude conversation content, effect arguments, action results,
and provider errors by default.

For a Stack-bound Agent, every record also carries authoritative deployment
identity: Stack id, owner and digest plus each installation's id, package
version, and digest. This lets an audit correlate behavior with the exact
installed implementation without copying package configuration, secrets,
clients, PIDs, connections, or other runtime handles.

## Configure A Store

Declare a store on an agent:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent

  journal MyApp.SpectreJournal,
    events: [:run, :routing, :policy, :lifecycle, :execution, :persistence],
    mode: :async,
    on_error: :warn,
    sample_rate: 1.0,
    include_input: false,
    buffer_size: 1_000,
    overflow: :drop_newest,
    store_opts: [index: "agent-decisions"]
end
```

`:arbitration` is accepted as an alias for `:routing`. Use `events: [:all]` to
record every supported phase.

The store implements one append callback:

```elixir
defmodule MyApp.SpectreJournal do
  @behaviour Spectre.Journal.Store

  @impl true
  def append(%Spectre.Journal.Record{} = record, opts) do
    MyApp.AgentJournal.insert(record, opts)
  end
end
```

Valid success results are `:ok` and `{:ok, value}`. Return
`{:error, reason}` when the append fails.

An application-wide default can be configured without changing every agent:

```elixir
config :spectre,
  journal:
    {MyApp.SpectreJournal,
     [events: [:routing], mode: :async, on_error: :warn]}
```

Use `journal(false)` on an agent to disable that application default. A host can
also pass `journal: {Store, opts}` to one `Spectre.ask/3` or `Spectre.turn/3`
call; per-call options win over agent configuration.

## Privacy Defaults

Routing records contain labels, providers, scores, margins, configured
thresholds, the selected route, and structured reason codes. They do not
contain:

- user input text or raw input payloads;
- model output or visible reply text;
- candidate match text and examples;
- state data, effect arguments, or action results.

Set `include_input: true` only when the store's access, redaction, and retention
policy can safely handle conversation content. Reply recording is reserved but
requires `include_reply: true`.

Use `redact:` for a final application-controlled record transformation and
`retention:` for metadata the store can enforce:

```elixir
journal MyApp.AuditJournal,
  events: [:all],
  redact: {MyApp.JournalRedactor, :redact},
  retention: [days: 30]
```

The redactor receives a `%Spectre.Journal.Record{}` and returns a record,
`{:ok, record}`, or `{:error, reason}`. Policy and execution phases default to
unsampled delivery; `sample_rates: %{policy: 0.5}` can override that explicitly.

Stores used by the offline Instance erasure coordinator also implement the
optional idempotent `erase_instance/2` callback. It receives an exact stable or
legacy `%Spectre.Instance.Ref{}` and must delete only records indexed to that
Ref. `Spectre.Privacy.erasure_plan/3` and `Spectre.Doctor` inspect this
capability without invoking the store; see [Offline Instance erasure](ERASURE.md).

## Delivery And Failures

The monitoring default is `mode: :async, on_error: :warn`. A supervised,
bounded queue serializes appends and keeps journal latency outside the turn.
`buffer_size` defaults to `1_000` including the active write.

Overflow policies are:

- `:drop_newest` rejects the incoming record and logs a warning;
- `:drop_oldest` replaces the oldest queued record and logs a warning.

Delivery is ordered through one worker. A store crash is isolated to that
append and the buffer continues with the next queued record.

Set `on_error: :ignore` when the host intentionally wants silent best-effort
delivery. Async mode cannot use `on_error: :error`, because an append finishes
after the turn has continued.

For a required audit artifact, use:

```elixir
journal MyApp.AuditJournal,
  events: [:routing],
  mode: :sync,
  on_error: :error
```

Before state persistence, a failed append returns
`{:error, {:journal_append_failed, reason}}` from the turn.

The persistence record is necessarily appended after compare-and-set. If that
strict append fails, the state is already committed and Spectre returns
`{:error, {:persistence_journal_failed,
{:journal_append_failed, reason}, committed_result}}`. A Session retains the
committed result so its in-memory revision does not move backward.
Request-scoped callers should retain that result or reload durable state before
continuing.

If state and audit records must commit atomically, use an application outbox in
the same storage transaction rather than relying on a remote append. A remote
strict journal can report the post-commit failure, but it cannot roll the state
write back.

## Correlation And Idempotency

Every runtime turn receives a UUIDv7 `turn_id` and uses it as the default
`trace_id`. A record ID is deterministically derived from the agent, turn,
phase, and sequence. Pass a durable `turn_id:` when retrying the same logical
turn so the store can enforce uniqueness on `record.id`:

```elixir
Spectre.turn(MyApp.SupportAgent, input,
  conversation_id: conversation.id,
  turn_id: inbound_message.id
)
```

Without a host-provided ID, each call is a new logical turn and receives a new
identifier.

Run lifecycle records keep the Run's shared `trace_id`, while their `turn_id`
is derived deterministically from the Run id, revision, and event. This gives
each lifecycle fact its own retry-stable journal identity. A successful
`Runtime.resume/3` records both `:run_resumed` and the resulting
`:run_awaiting`, `:run_boundary`, or `:run_completed` event; their sequences
preserve that order.

## Sampling

`sample_rate` accepts a value from `0.0` through `1.0`. Sampling is deterministic
for a record ID, so a retry with the same `turn_id` makes the same sampling
decision. Routing records can be sampled; future policy and execution records
will default to unsampled because they are audit-sensitive.

## Record Shape

The current `:arbitration` record includes:

```elixir
%Spectre.Journal.Record{
  schema_version: 1,
  id: "journal:...",
  agent: MyApp.SupportAgent,
  conversation_id: "chat-123",
  turn_id: "...",
  trace_id: "...",
  sequence: 1,
  phase: :arbitration,
  decision: %{
    kind: :route_selected,
    label: :BILLING,
    strategy: :local_classifier,
    accepted?: true
  },
  reason: %{
    code: :candidate_selected,
    provider: :local_classifier,
    label: :BILLING
  },
  evidence: [
    %{
      provider: :local_classifier,
      label: :BILLING,
      score: 0.97,
      margin: 0.21,
      accepted?: true
    }
  ],
  input: nil,
  reply: nil
}
```

Stores should persist `schema_version` and tolerate newly added optional fields.
They should use `record.id` as an idempotency key rather than generating a new
identity during append.

Persisted schema-v1 maps can be checked with
`Spectre.Journal.Record.restore/1`. Unknown additive fields are ignored and an
unsupported schema version returns an explicit error.

For a per-agent timeline, query by `agent`, `conversation_id`, and `turn_id`,
then order by `sequence, occurred_at`. For aggregate dashboards, group by
`phase`, `decision.kind`, `reason.code`, and the arbitration strategy; content
fields are unnecessary for those queries.
