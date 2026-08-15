# ADR 0002: Stream delivery, backpressure and restart

Status: accepted

## Context

An Elixir `Stream` is an idiomatic consumer surface, but it executes in the
enumerating process and is not a transport. Pub/sub is useful for lossy
observers, but it cannot provide authoritative flow control. Restart also
changes every live process fence, so an old Enumerable must never be joined
silently to a recovered provider request.

## Decision

`Spectre.stream/3` returns a one-shot `%Spectre.Inference.Stream{}` implementing
`Enumerable`. Internally `Stream.resource/3` attaches to a temporary
`:gen_statem` session:

```text
consumer demand -> StreamSession -> adapter transport credit
provider event  -> StreamSession -> fenced StreamEvent batch
terminal receipt -> Instance -> canonical Result -> StreamSession
```

The session states are `:awaiting_consumer`, `:opening`, `:streaming`,
`:committing_terminal`, `:awaiting_result` and terminal variants. State
timeouts distinguish consumer attachment, provider open, provider stall,
consumer idle, terminal commit and Result delivery. An absolute maximum stream
duration and optional budget deadline are independent of heartbeats.

Pull adapters declare `:stream` and `:pull_transport`. Each
`request_transport_item/1` grants at most one transport item. The session
allows only one outstanding request, keeps a bounded event/byte queue, and
never drops text to recover from overflow.

Push adapters declare `:stream`, `:push_transport` and
`:bounded_push_transport`. The last capability is a promise that the adapter
bounds production before the session mailbox. The session's own bounded queue
does not make an Erlang mailbox bounded; a push adapter without this capability
is rejected.

Selectors with a profile catalog must attest `:stream` in the selected
profile metadata. The built-in default selector has no catalog and cannot
make that attestation, so its profile check is explicitly not applicable; the
adapter capability set remains the fail-closed authority for streaming. A
missing adapter `:stream` capability is still a typed rejection, never a
synchronous fallback.

Every public event carries inference, Invocation, attempt, Run revision,
Instance generation, dispatch, control revision, epoch and sequence fences.
The consumer validates all fences and exact sequence progression.

The public handle is process-free but is not a durable value. It contains a
bearer token authorizing attach and control operations, must not be logged or
persisted, and may be consumed once. Its `Inspect` implementation omits the
token.

On Instance or session restart, the existing Enumerable terminates with
`:interrupted` or another explicit terminal classification. A recoverable
provider cursor may create a new session, fresh generation/dispatch fences and
a new epoch. `Spectre.resume_stream/3` returns the replacement handle; no event
from that epoch can appear in the old Enumerable.

## Terminal ordering

The data plane exposes three different facts:

1. `:delta` and `:usage` are provisional observations.
2. `:inference_completed` means the provider attempt receipt was accepted.
3. `:result` means post-processing and the canonical Run Result commit
   completed.

Only `%Spectre.Result{}` is a deliverable Agent outcome. The complete response
still passes the normal sanitizer, action planning and policy path. Calling
`Spectre.await_result/2` before enumeration claims the stream as a result-only
consumer and drains provisional events internally.

## Consequences

- `Enum.take/2`, exceptions and consumer death run cleanup and cancel the
  attempt best-effort.
- A consumer that never attaches produces `:consumer_never_attached`, commits
  a terminal receipt and releases capacity.
- A slow consumer ends with `:consumer_too_slow`; text is not silently dropped.
- Provider adapter callbacks must initiate asynchronous work and return
  promptly. A callback that blocks its session violates the behaviour.
- Terminal events are retained only for a bounded interval.
