# Resumable Runs

Spectre 0.1.3 separates a unit of work from the process that happens to execute
it. `%Spectre.Run{}` is the logical continuation; `Spectre.Runtime` advances it
through a small, closed protocol:

```elixir
{:continue, run} = Spectre.Runtime.start(MyApp.Agent, input)

case Spectre.Runtime.advance(run) do
  {:await, invocation, run} ->
    Spectre.Runtime.resume(run, {:execute, invocation})

  {:boundary, boundary, run} ->
    handle_boundary(boundary, run)

  {:complete, result, run} ->
    handle_result(result, run)

  {:error, reason, run} ->
    reconcile(reason, run)
end
```

Every call returns exactly one of:

```text
{:continue, run}
{:await, invocation, run}
{:boundary, observable, run}
{:complete, result, run}
{:error, reason, run}
```

There are no capability-specific additions to this vocabulary. Extensions add
effect kinds and executors; they do not add new Runtime return shapes.

## Start, advance, and resume

`start/3` normalizes input and restores logical State. It does not run routing,
providers, actions, or memory persistence.

`advance/2` re-resolves the Agent and Stack configuration, recalls memory,
performs one turn, commits the resulting State, and stops at the first boundary:

- an open policy becomes a `Spectre.Run.Boundary` with `kind: :needs`;
- an executable Effect becomes a `Spectre.Invocation`;
- visible output becomes a reply boundary;
- a result with no further observable work completes the Run.

`resume/3` accepts only revision-fenced commands:

```elixir
{:boundary, policy, run} = Spectre.Runtime.advance(run)

{:await, invocation, run} =
  Spectre.Runtime.resume(
    run,
    {:policy, policy.ref, {:accept, :approved}}
  )

{:boundary, reply, run} =
  Spectre.Runtime.resume(run, {:execute, invocation})
```

A stale `Spectre.Run.Ref`, foreign Invocation, wrong Invocation id, or command
against a completed Run is rejected before a lifecycle transition. Effect
execution still uses the core's durable two-commit workflow and the Effect's
stable idempotency key.

## Public Turn projection

`Spectre.turn/3` remains the normal host API. It starts and advances a Run, then
returns `%Spectre.Turn{}` at the first observable point. The Turn does not
contain the continuation. It exposes:

- `turn.ref` — a transport-safe, revision-fenced `Spectre.Run.Ref`;
- `turn.boundary` — the reply, policy request, or Invocation descriptor;
- `turn.observable` — exactly `{:reply, output, ref}`,
  `{:awaiting, invocation_ref}`, or `{:needs, policy_boundary}`;
- `turn.result` and `turn.decision` — lifecycle/result projections used by
  existing local integrations.

Transport packages should derive reply idempotency from
`Spectre.Run.Ref.token/1`. A technical transport receipt is not a semantic Run
completion. A terminal result without visible output uses
`{:reply, nil, ref}` and must not produce a transport delivery.

Only `ref`, `boundary`, and `observable` form the transport projection. The
complete Turn also carries a local Result and lifecycle decision for host code;
it should not be serialized as an envelope.

## Checkpoint and recovery

```elixir
{:ok, binary} = Spectre.Run.checkpoint(run)
{:ok, restored} = Spectre.Run.restore(binary)
```

The versioned checkpoint:

- writes Run checkpoint schema 2 with the exact Definition Ref, activation
  generation, authority epoch, execution-closure digest, and optional portable
  deployment requirement;
- uses an atom-free tagged payload before typed decoding; modules are loaded
  from deployed code and only existing atoms are rehydrated, while unknown
  dynamic atoms fail closed;
- removes `Input.raw`;
- retains only portable input/source metadata;
- reduces a compiled Route to a logical `%Spectre.Route{}` without executable
  handlers or rules;
- never stores runtime options, recalled memory, Stack processes, provider
  clients, callbacks, PID, Port, reference, or function values;
- rejects non-portable values in authoritative State/Result data;
- validates lifecycle combinations and revision-fenced descriptors before
  encode and after restore;
- enforces a configurable encoded-size limit (2 MB by default).

The reader also accepts Run checkpoint schema 1. It immediately produces a
schema-2 Run with an explicit generation-0 legacy Definition pin; current
writers never emit schema 1.

After restore, `advance/2` and `resume/3` resolve runtime dependencies again.
Secrets and clients belong in runtime configuration or Stack resources, not in
the checkpoint.

Inside an Instance, retained Run checkpoints are stored atomically with the
observed Flow state. Canonical schema 2 introduced retained Runs; current
writers emit schema 4. Activating Definition B
changes the pin only for Runs admitted afterward: a Run already open under A
continues under A, including after process restart. Restart re-resolves every
non-legacy Definition and verifies the stored closure digest before resuming.

Checkpoint blobs are continuation state, not untrusted input. `restore/2`
validates schema and lifecycle but does not authenticate a blob; use storage
with integrity and access controls when a Run can authorize effects.

## Ownership boundary in 0.1.x

A caller that directly uses `Spectre.Runtime` remains the single owner of its
Run value. Checkpoint replay is at-least-once: restoring the same awaiting
snapshot twice can retry the capability, and both attempts carry the same
Effect idempotency key. Providers must deduplicate that key.

For a stateful actor, `Spectre.Instance` now owns multiple retained Runs for one
`AgentRef + Subject`. It schedules a deduplicated FIFO ready queue through its
mailbox, replies at the first observable boundary, and correlates in-flight
Invocation work with an internal capability plus Instance generation, Run
revision, Invocation id, and dispatch id. Only the owning Instance applies the
returned continuation; stale, duplicate, foreign, and malformed receipts are
ignored.

Effects and policy Awaitables staged inside an Instance carry the owning Run
id. This permits independent lifecycle boundaries across Runs while the
Instance continues to serialize State commits and actual capability
invocation. Direct Runtime callers and Sessions retain the unowned,
single-lifecycle compatibility model.

The local active-Run registry and Subject Registry are in-memory in this
phase. Durable checkpoints, passivation, cross-node claims, and recovery are
separate continuity-plane responsibilities. See
[Agent Instances and Subjects](INSTANCES.md).
