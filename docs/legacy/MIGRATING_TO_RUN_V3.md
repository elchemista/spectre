# Migrating Run checkpoints from v2 to v3

The current Run writer emits schema 3. The reader accepts schemas 1, 2 and 3
and always returns a validated `%Spectre.Run{run_version: 3}`.

## What changed

Run v3 adds two portable continuation fields:

- `%Spectre.Run.StartContinuation{}` retains normalized admission input and
  safe runtime options while a Run is `:ready`;
- `%Spectre.Run.InferenceContinuation{}` retains selection, Invocation,
  aggregate budget, provider recovery state and post-processing intent while a
  Run is awaiting inference.

`Spectre.Invocation.kind` now accepts `:effect | :inference`. Inference
Invocations add attempt, control revision and stream epoch fences. Runtime
bindings, provider clients, credentials, functions, PIDs, ports and references
remain outside checkpoints.

The v3 validator rejects a nonterminal Run that lacks the continuation needed
for deterministic recovery. A newly admitted ready Run therefore always has a
`StartContinuation`; once it advances, that field is cleared.

## Reading v2 data

No offline byte rewrite is required. `Spectre.Run.restore/2` migrates a v2
checkpoint in memory. A v2 ready Run did not retain the lost OTP queue entry,
so migration creates an explicit nonrecoverable continuation:

```elixir
%Spectre.Run.StartContinuation{
  recoverable?: false,
  reason: :legacy_ready_run_without_start_continuation
}
```

This is deliberate. Recovery terminalizes the orphan instead of guessing
runtime options or leaving it live forever. Other valid v2 boundary and
terminal Runs migrate without inventing an inference continuation.

Schema 1 continues to receive its established legacy Definition pin before
the same v3 validation.

## Deployment procedure

1. Back up representative Run blobs and the complete Instance checkpoint
   namespace.
2. Before rollout, run `Spectre.Foundation.Conformance.verify_run/1` against
   those blobs under the new code.
3. Quiesce old writers if the same blob location can be updated concurrently.
   Old readers do not understand writer v3.
4. Deploy readers/writers together for every process sharing the Run store.
5. Restart representative Instances and confirm that legacy ready Runs become
   explicit terminal failures rather than remaining live.
6. Once rollback to the old reader is no longer required, allow normal
   checkpoints to rewrite records as v3.

## Application impact

Code that pattern-matches `%Spectre.Run{}` should not assume the new fields are
nil. Use public Runtime/Instance APIs instead of mutating continuations.

If a call needs a nonportable model binding or semantic runtime option,
admission marks its continuation nonrecoverable. Move clients and secrets into
stable host configuration and resolve them again after restart; do not put
them into Run metadata.

The migration does not retry an external Effect or provider request. External
idempotency and reconciliation remain host/adapter responsibilities.
