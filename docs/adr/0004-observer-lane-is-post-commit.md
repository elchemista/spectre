# ADR 0004: The inference observer lane is post-commit

Status: accepted

## Context

`Spectre.Operation.Events` has historically published canonical facts. Letting
a StreamSession publish raw progress directly would introduce an uncommitted
event bus and could also turn pub/sub into a second data plane. An Instance
still needs a liveness signal during a long provider request.

## Decision

The session sends throttled, text-free heartbeats directly to its owning
Instance. A heartbeat contains full live fences, cumulative usage, output byte
count, provider request/cursor digests and an optional confidential recovery
checkpoint. It never contains a text delta or raw provider identifier.

The Instance handles two independent concerns:

- every valid heartbeat refreshes an ephemeral monotonic liveness clock;
- when `:inference_observer_lane` is enabled and the commit interval has
  elapsed, the Instance commits the latest progress value into the canonical
  `:inference_progress` section.

Only after that commit does `Spectre.Inference.Events` publish a
`:progress_committed` event through the existing duplicate-key Registry.
Terminal, supersession and interruption lifecycle events are likewise
published only after their receipt/canonical boundary has committed.

The observer lane is lossy and non-authoritative. Subscribers receive
lifecycle summaries for UI, telemetry or operations; they cannot acknowledge
provider data, advance a Run, enforce a budget or recover a stream. Raw deltas
are forbidden from the lane.

The default progress commit interval is five seconds. Liveness heartbeat and
canonical progress commit intervals are configurable separately. A heartbeat
never extends an absolute inference budget or maximum stream duration.

## Security consequence

The local Registry subscription is not an authorization protocol. A process
that can resolve the Instance ref may subscribe. Text-free, bounded summaries
limit the exposure, but hosts must still treat inference ids and usage as local
operational data. Adding text to this lane would require a new authorization
decision and is outside this ADR.
