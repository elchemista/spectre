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
- an executable Effect or selected inference attempt becomes a
  `Spectre.Invocation`;
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
stable idempotency key. Inference is resumed with a typed, correlated
`{:inference, invocation_or_id, %Spectre.Inference.Response{}}` command; an
Instance owns that command in normal operation so provider output cannot skip
the canonical receipt path.

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

- writes Run checkpoint schema 3 with the exact Definition Ref, activation
  generation, authority epoch, execution-closure digest, and optional portable
  deployment requirement;
- retains a typed start continuation for every recoverable `:ready` Run and a
  typed inference continuation while awaiting a model attempt;
- uses an atom-free tagged payload before typed decoding; modules are loaded
  from deployed code and only existing atoms are rehydrated, while unknown
  dynamic atoms fail closed;
- orders tagged map entries by deterministic bytes of their encoded keys, so
  equivalent portable values produce the same checkpoint across BEAM module
  and atom load orders;
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

The reader also accepts Run checkpoint schemas 1 and 2. It immediately
produces a schema-3 Run. Schema 1 receives its explicit generation-0 legacy
Definition pin. A schema-2 ready Run becomes explicitly nonrecoverable because
the older format did not retain its admission continuation; recovery fails it
instead of guessing or leaving an orphan. Current writers never emit schemas 1
or 2.

After restore, `advance/2` and `resume/3` resolve runtime dependencies again.
Secrets and clients belong in runtime configuration or Stack resources, not in
the checkpoint.

Inside an Instance, retained Run checkpoints are stored atomically with the
observed Flow state. Canonical schema 2 introduced retained Runs; current
Instance writers emit the format-tagged schema 3. Activating Definition B
changes the pin only for Runs admitted afterward: a Run already open under A
continues under A, including after process restart. Restart re-resolves every
non-legacy Definition and verifies the stored closure digest before resuming.

Run v3 inference state contains only portable selection identity, request
semantics, budgets, attempt/control fences, bounded provider recovery
coordinates, and prior-attempt summaries. It never contains an HTTP client,
socket, PID, bearer token, credentials, callback or raw provider error. A live
stream handle is a separate ephemeral capability and is never checkpointed.

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
revision, Invocation id, dispatch id, and—where applicable—attempt, control
revision and stream epoch. Only the owning Instance applies the returned
continuation; stale, duplicate, foreign, and malformed receipts are ignored.

Effects and policy Awaitables staged inside an Instance carry the owning Run
id. This permits independent lifecycle boundaries across Runs while the
Instance continues to serialize State commits and actual capability
invocation. Direct Runtime callers and Sessions retain the unowned,
single-lifecycle compatibility model.

Inference attempts use the same Run owner. One-shot calls execute in isolated
workers; streaming calls use a supervised `:gen_statem` data plane and resume
the Run only after the Instance accepts the terminal receipt. Raw deltas are
provisional and never become Run state. See [Streaming inference](STREAMING_INFERENCE.md)
for cancellation, steering, budgets and restart behavior.

The local active-Run registry and Subject Registry remain in-memory. Durable
checkpoints, passivation and distributed owner claims are separate
continuity-plane responsibilities. See [Agent Instances and Subjects](INSTANCES.md).
