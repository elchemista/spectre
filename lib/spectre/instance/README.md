# Maintaining `Spectre.Instance`

`Spectre.Instance` is the OTP owner for one Agent/Subject pair. Keep the
GenServer as the only process that receives public calls, owns the canonical
state, and decides callback replies. Domain helpers may transform that state or
perform an explicitly documented owner-process side effect, but they must not
introduce a second authority.

## Responsibility map

- `Instance` owns the public API, `GenServer` callbacks, mailbox ordering, and
  the top-level orchestration of commits and worker results.
- `Configuration` normalizes startup options into one validated snapshot.
- `Restore` reconstructs durable activation and Run state before scheduling
  starts. It is fail-closed.
- `Activations` builds and durably commits Definition activations.
- `DefinitionCompatibility` owns the checks shared by activation, admission,
  dispatch, and recovery.
- `RuntimeOptions` builds the immutable execution snapshot and Definition pin
  handed to workers.
- `RunQueue` owns transient ready entries, caller replies, and stream result
  hand-off. Canonical Run state remains in `Runs`.
- `InferenceBudget` owns reservation, enforcement, and settlement policy.
- `InferenceAttempt` owns attempt timers, stream-session notifications, and
  observer lifecycle events.
- `InferenceHeartbeat` validates fenced liveness, throttles canonical progress
  and checkpoint writes, and publishes observers only after commit.
- `InferenceStreamControl` validates live Stream handles and builds cancel or
  steer commands before canonical state changes.

Existing modules such as `Commit`, `Receipts`, `ReceiptRecovery`, `Checkpoint`,
`Runs`, `Loops`, and `Timers` continue to own their corresponding durable
domains.

## Invariants for new code

1. Keep mailbox ordering in `Instance`. A helper must not call a public
   `GenServer` API back into the same Instance.
2. Keep canonical writes behind `Commit`; do not mutate `data.canonical`
   directly.
3. Publish authoritative events only after the corresponding canonical commit.
4. Validate generation, dispatch, invocation, control revision, stream epoch,
   and sequence fences before accepting asynchronous input.
5. Keep recovery checks at least as strict as the hot path. Shared validation
   belongs in one helper and should be called by both paths.
6. Treat `RunQueue`, timers, monitors, callers, workers, and stream ownership as
   transient state. Their cleanup must remain idempotent.
7. A helper that uses `self()`, sends a message, replies to a caller, or touches
   a monitor must state that it runs in the Instance owner process.

## Where a change belongs

- Add a callback clause to `Instance` when the change affects message ordering,
  reply/stop semantics, or ownership of an OTP resource.
- Add domain policy to the matching helper when it can be tested and reasoned
  about independently of callback ordering.
- Add a new helper only for a cohesive domain with more than one caller or a
  meaningful invariant. Avoid modules that merely rename a single expression.
- Prefer a small public-internal function with `@doc false` and a precise spec;
  keep implementation details private inside the helper.

When refactoring, first run the closest contract tests for the extracted domain.
Before merging, run formatting, compilation with warnings as errors, the full
test and coverage suite, ExDoc, Credo, and Dialyzer.
