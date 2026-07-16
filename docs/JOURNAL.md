# Journal

Spectre's journal is an opt-in stream of structured explanation records. It is
separate from chat history and logs:

- chat history is context that may influence a later turn;
- journal records explain an individual runtime decision;
- logs and telemetry describe operational health.

The current implementation records the routing and arbitration boundary. The
record schema already reserves lifecycle, policy, effect, and execution fields;
those phases remain roadmap work and are not emitted yet.

## Configure A Store

Declare a store on an agent:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent

  journal MyApp.SpectreJournal,
    events: [:routing],
    mode: :async,
    on_error: :warn,
    sample_rate: 1.0,
    include_input: false,
    buffer_size: 1_000,
    overflow: :drop_newest,
    store_opts: [index: "agent-decisions"]
end
```

`:arbitration` is accepted as an alias for the current `:routing` event filter.

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
is not emitted by the current routing-only implementation.

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

Then a failed append returns `{:error, {:journal_append_failed, reason}}` from
the turn. If state and audit records must commit atomically, use an application
outbox in the same storage transaction rather than relying on a remote append.

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

## Sampling

`sample_rate` accepts a value from `0.0` through `1.0`. Sampling is deterministic
for a record ID, so a retry with the same `turn_id` makes the same sampling
decision. Routing records can be sampled; future policy and execution records
will default to unsampled because they are audit-sensitive.

## Routing Record Shape

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
