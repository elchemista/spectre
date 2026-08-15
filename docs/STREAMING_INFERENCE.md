# Streaming inference

Spectre exposes streaming as an Instance-owned Run capability. The provider
transport may live in another package, but selection, budgets, cancellation,
steering, terminal processing and recovery remain in the core runtime.

Streaming is intentionally opt-in. The first supported slice is text-only
response generation without Action planning or structured output. Unsupported
purposes and missing capabilities return typed errors; Spectre does not buffer
a synchronous completion and pretend it was a stream.

An Agent with a configured Action planner is admitted only when Action planning
is disabled for this call. A planner that also transforms visible reply text
must implement `incremental_cleaner?/0` and return `true`; otherwise streaming
fails closed because a complete-response cleaner cannot truthfully certify
individual deltas.

## Start and consume a stream

Configure a provider package that implements `Spectre.Inference.StreamAdapter`,
then pass its module and options through the ordinary model configuration or
the call:

```elixir
{:ok, stream} =
  Spectre.stream(instance, "Explain the result",
    plan_actions?: false,
    stream_adapter: MyApp.StreamAdapter,
    stream_adapter_opts: [profile: :fast]
  )

Enum.each(stream, fn
  %Spectre.Inference.StreamEvent{kind: :delta, payload: text} ->
    render_provisional(text)

  %Spectre.Inference.StreamEvent{kind: :usage, usage: usage} ->
    update_meter(usage)

  %Spectre.Inference.StreamEvent{kind: :inference_completed} ->
    mark_provider_complete()

  %Spectre.Inference.StreamEvent{kind: :result, payload: result} ->
    deliver_committed(result)

  %Spectre.Inference.StreamEvent{kind: kind}
  when kind in [:failed, :cancelled, :ambiguous, :interrupted] ->
    mark_terminal(kind)
end)
```

The handle is itself an Enumerable. It can be composed with `Stream.transform/3`,
`Enum.reduce/3` or a `for` comprehension. Enumeration is one-shot: a second
consumer receives `:already_consumed`. `Enum.take/2`, an exception in the
consumer, or consumer-process death runs cleanup and requests cancellation.

The handle contains a bearer token. Its custom `Inspect` output hides that
token, but serialization does not turn it into safe durable state. Do not put a
stream handle in a database, log, pub/sub payload or client response. It is
valid only for the live runtime generation and bounded terminal-retention
window.

## Provisional data and the canonical result

A stream has two terminal milestones:

| Event | Meaning |
| --- | --- |
| `:delta` | provisional provider text, incrementally screened but not a deliverable reply |
| `:inference_completed` | the provider attempt terminal receipt was accepted by the Instance |
| `:result` | full post-processing completed and `%Spectre.Result{}` was committed to the Run |

Never send a delta directly to an external user as though it were an approved
Agent response. Action planning, policy, complete-reply sanitization and host
guards operate on the complete response. Delta `content_class` is
`:provisional` when incremental sanitization is active and `:unsanitized` when
the host explicitly disables it.

The provisional lane is not promised to be a byte-for-byte prefix of the
terminal Result. In particular, an unterminated control marker causes the
incremental sanitizer to suppress the remaining provisional tail, while the
full-response sanitizer may preserve text for which it never observes a
complete control block. The committed Result is authoritative; consumers must
not reconstruct it by concatenating deltas.

If only the canonical terminal matters, do not enumerate:

```elixir
{:ok, stream} = Spectre.stream(instance, input, stream_options)
{:ok, %Spectre.Result{} = result} = Spectre.await_result(stream, 60_000)
```

The first `await_result/2` claims an unattached handle as a result-only
consumer and drives provider demand internally. If enumeration is already
active, it waits for that consumer's terminal Result. Waiters are bounded and
a timed-out waiter is removed without making the session retain an abandoned
caller.

## Backpressure

The preferred adapter mode is pull transport:

```elixir
MapSet.new([:stream, :pull_transport, :incremental_usage])
```

The StreamSession issues at most one transport credit at a time. Provider
chunks and logical events are different units: one chunk may contain several
SSE events, or one event may span chunks. The adapter assembles transport
framing and returns a bounded list of normalized `ProviderEvent` values.

A push adapter must declare:

```elixir
MapSet.new([:stream, :push_transport, :bounded_push_transport])
```

`:bounded_push_transport` certifies a real bound before messages enter the
session mailbox. A bounded session queue alone cannot backpressure an Erlang
mailbox. Spectre rejects push adapters that omit the capability. Once inside
the session, event count, bytes per delta, buffered bytes, buffered event count
and events per transport item all have explicit limits. Overflow terminates the
attempt; text is never discarded silently.

## Adapter contract

The core behaviour is `Spectre.Inference.StreamAdapter`:

```elixir
@callback capabilities(profile, opts) :: MapSet.t(atom())
@callback open(descriptor, opts) :: {:ok, state, metadata} | {:error, term()}
@callback request_transport_item(state) :: {:ok, state} | {:error, term()}
@callback handle_transport(message, state) ::
            {:ok, [Spectre.Inference.ProviderEvent.t()], state}
            | {:ignore, state}
            | {:error, term(), state}
@callback cancel(state, reason) :: :ok | {:error, term()}
```

Optional `resume/3` and `reconcile/3` callbacks require matching declared
capabilities. `:cost_usage` means cumulative cost is authoritative for the
configured immutable pricing ref. Hard cost budgets are rejected when that
capability is unavailable. `:incremental_usage` means cumulative usage can be
enforced during generation.

Profile capability negotiation is fail-closed for selectors backed by a
profile catalog: the selected metadata must include `:stream` in
`profile_supports`. `Spectre.Inference.Selector.Default` is the narrow
exception because it has no catalog to query and therefore cannot produce
profile capability evidence. In that case the profile gate is not applicable
and `StreamAdapter.capabilities/2` is the authoritative gate; the adapter must
still declare `:stream` and one valid transport mode or preparation fails.
This is not a fallback from a known profile rejection.

Callbacks run in the session process and must initiate asynchronous transport
work and return promptly. In particular, `open/2` should start the request;
the first owned transport item proves provider progress. For pull mode,
`{:ignore, state}` means a mailbox message did not consume the outstanding
credit. A consumed chunk that produces no complete logical event returns
`{:ok, [], state}`.

Stream sessions trap exits so orderly supervisor shutdown can run `cancel/2`.
A linked provider helper therefore delivers `{:EXIT, pid, reason}` to
`handle_transport/2`; adapters should prefer monitoring helpers whose death is
a provider failure, or explicitly ignore expected exit messages. Cancellation
must return promptly: each session has a one-second shutdown grace period,
after which the supervisor kills it and remote cancellation remains
best-effort.

Provider sequencing is all-or-nothing for one attempt. An adapter may leave
`provider_sequence` unset on every normalized event. Once it emits the first
numbered event, every later delta, usage, started, completed or failed event
must carry exactly the next non-negative integer. In particular, a numbered
delta followed by unnumbered usage is a protocol violation. This rule spans
transport batches and also applies after resume from the durable sequence
floor.

Use `Spectre.LLM.provider_opts/2` when translating the supplied keyword list to
an HTTP/SDK request. Core state, control, budget and stream options must not be
sent to a provider endpoint.

Run `Spectre.Inference.StreamAdapter.Conformance.run/4` with a portable
descriptor and deterministic transport messages in every adapter repository.
It verifies capability negotiation, pull-credit calls, event batches, global
ordering, terminal cardinality and optional cancel/reconcile reply shapes. A
real local TCP/SSE integration test is still required to prove socket flow
control, parser bounds and remote cancellation.

## Cancellation and steering

Cancellation is idempotent:

```elixir
:ok = Spectre.Inference.Stream.cancel(stream, :user_requested)
```

The Instance commits the cancellation command before the session asks the
adapter to cancel remotely. A remote cancellation failure is not rewritten as
success: the terminal receipt records the remote status as ambiguous.

Steering replaces the attempt:

```elixir
{:ok, replacement} =
  Spectre.Inference.Stream.steer(stream, "Focus only on the last section")
```

The original Enumerable terminates with `:superseded`. It never follows the
replacement epoch. Start enumerating `replacement` explicitly. This keeps
sequence and fence validation local to one attempt and prevents a UI from
silently joining text generated under different instructions.

## Restart and resume

Instance death interrupts the live session and best-effort cancels the
provider. Recovery inspects the canonical provider status:

- not started: dispatch may safely begin;
- cursor plus `:resume`: a successor Invocation is committed with a fresh
  epoch;
- provider request id plus `:reconcile`: the adapter can classify uncertain
  work;
- neither capability: the Run ends explicitly as interrupted or ambiguous.

The old handle is never updated in place. When recovery created a successor,
the owner can request it using the old handle as a bearer/fence proof:

```elixir
{:ok, replacement} = Spectre.resume_stream(instance, old_stream)
```

The call validates the previous consumer-token digest and recovery lineage.
It cannot attach a stale or foreign handle.

## Limits and budgets

Important options include:

| Option | Default | Purpose |
| --- | ---: | --- |
| `stream_attach_timeout` | 30 s | maximum wait for the authoritative consumer |
| `stream_open_timeout` | 15 s | maximum wait for the first provider signal |
| `stream_provider_stall_timeout` | 30 s | outstanding-demand liveness deadline |
| `stream_consumer_idle_timeout` | 30 s | maximum pause after a delivered batch |
| `stream_max_duration_ms` | 5 min | absolute data-plane lifetime |
| `stream_result_timeout` | 60 s | wait for post-processing/Run commit after provider terminal |
| `stream_terminal_retention` | 60 s | bounded terminal lookup window |
| `stream_max_transport_chunk_bytes` | 256 KB | adapter-owned raw transport item limit |
| `stream_max_parser_residual_bytes` | 256 KB | adapter-owned incomplete parser state limit |
| `stream_max_delta_bytes` | 64 KB | per-delta limit |
| `stream_max_buffer_events` | 64 | normalized event queue limit |
| `stream_max_buffer_bytes` | 256 KB | text queue limit |
| `max_stream_sessions` | 8 | live sessions admitted per Instance |

Node-wide capacity is owned by an internal supervised capacity process. A slot
is reserved before dispatch, transferred to the stream session, and released
on every terminal path, including never-attached consumers and process death.

`inference_budget` accepts `input_tokens`, `output_tokens`, `total_tokens`,
`cost`, `attempts` and `duration_ms`. The Instance owns aggregate reservation
and settlement; each session receives an immutable `BudgetSnapshot`. A hard
cost limit also requires `inference_pricing_ref` and authoritative cost usage.
Heartbeat activity never extends the absolute deadline.

Usage-bearing stream events expose `usage_quality` as `:provider`,
`:estimated` or `:unavailable`. Provider counters keep `:provider` only while
Spectre can retain them unchanged. If conservative accounting raises a token
counter from the reserved-input or output-byte floor, the attempt is labelled
`:estimated`; that weaker label remains sticky because a later cumulative
update cannot prove the retained maximum was token-exact.

The session passes the two adapter-owned limits as
`max_transport_chunk_bytes` and `max_parser_residual_bytes` to `open/2` and
`resume/3`. Adapters must fail with `:provider_stream_overflow` instead of
retaining or truncating excess bytes. Normalized delta binaries may split a
UTF-8 codepoint; Spectre buffers the bounded trailing bytes and yields only
complete, valid UTF-8 events.

## Observer lane

Enable text-free committed progress separately:

```elixir
opts = [
  inference_observer_lane: true,
  inference_progress_commit_interval: 5_000,
  inference_progress_limit: 256
]

{:ok, _subscription} = Spectre.Inference.Events.subscribe(instance)
```

Sessions send heartbeat snapshots to their Instance. The Instance updates its
ephemeral liveness clock immediately, commits a throttled latest-value progress
snapshot, and only then publishes an event. Raw deltas never use pub/sub.
The same configured LRU limit is enforced when canonical checkpoints are
restored or reconciled, so a forged progress map cannot bypass the live bound.

## Receipt modes

Streaming works with `:disabled`, `:observational` and `:required` receipt
modes. Required mode needs a durable Instance Checkpoint Store and a
payload-capable `Spectre.Receipt.Sink`. Selection and dispatch intent cross the
checkpoint/outbox barrier before provider start. See
[Boundary receipts](RECEIPTS.md).
