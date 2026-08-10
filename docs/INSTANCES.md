# Agent Instances and Subjects

Spectre provides a long-lived owner for the ordered state of one logical
Agent and one canonical Subject:

```text
Spectre.AgentRef + Spectre.Subject -> one local Spectre.Instance
```

An Instance is not addressed by a PID, chat id, sender name, phone number, or
conversation id. Those values can change across restarts and channels. The
logical pair is portable; `Spectre.Instance.Registry` maps it to the current
local process. Since 0.2.3, the AgentRef key contains only the logical Agent id.
Its compiled module, declared version, and Stack digest are resolver hints and
do not split the Instance when behavior changes.

## Start and find an Instance

Add the dynamic supervisor owned by the host application:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

Then start or find the unique Instance:

```elixir
subject = Spectre.Subject.new({:account, account.id})

{:ok, instance} =
  Spectre.instance(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    subject
  )

{:ok, ^instance} =
  Spectre.lookup_instance(MyApp.SupportAgent, subject)
```

Concurrent `instance/4` calls for the same pair converge on one PID. A
different Subject gets a different Instance and independent State. Supplying
an `Spectre.AgentRef` with an explicit logical id allows two intentionally
separate Agent identities to use the same compiled module.

`Spectre.summon/1,3` also selects this runtime when `:subject` is present:

```elixir
{:ok, instance} =
  Spectre.summon(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    subject: subject
  )
```

Calls without `:subject` retain the legacy conversation-scoped
`Spectre.Session` behaviour.

## Subject state and channel conversations

The persisted `%Spectre.State{conversation_id: ...}` of an Instance is its
opaque, stable `AgentRef + Subject` scope. It does not change when the same
Subject reaches that logical Agent through another authenticated channel, and
two logical AgentRefs backed by the same compiled module remain isolated.
Per-message channel origins remain on
`%Spectre.Input.Source{conversation_id: ...}` and are propagated to runtime
integrations as `:origin_conversation_id`.

`Spectre.Instance.info/1` exposes only hashed conversation keys with channel,
count, and last-Run metadata. It never exposes the raw chat, thread, or session
identifier. This lets one Subject share ordered state across authorized
channels without treating a conversation id as identity proof.

## Definition activation and ownership fencing

An Instance can bind its stable identity to one current immutable Definition:

```elixir
{:ok, activation} =
  Spectre.activate(instance, candidate_ref,
    expected_generation: 0,
    authority_epoch: 8
  )

^activation = Spectre.activation(instance)
```

The Candidate must already be published in the Instance's configured
`:definition_store`. Activation re-reads the Candidate and all publication
artifacts, checks generation CAS and the current owner fence, then commits the
canonical activation section. A durable checkpoint write is synchronous at
this boundary; conflict or ambiguity never falls back to the old or new value
by guesswork.

Every Instance claims a `Spectre.Instance.Owner.Lease`. The default local
adapter is suitable only when one VM/local Registry is the canonical owner.
Multi-node hosts must configure `:owner` with a linearizable lease and
monotonic fencing token. Lease loss blocks admission, commits, activation, and
Effect/operation dispatch.

See [Stable Identity, Activation, and Definition-Pinned Runs](IDENTITY_ACTIVATION.md)
for the publication flow and [Migrating to 0.2.3](MIGRATING_TO_0_2_3.md) for
legacy key migration.

### Private Skill state

Canonical schema 4 also retains private Skill state as Definition-owned,
generational branches. The active branch is selected by the current
Activation; older branches remain dormant until an explicit resume, fork,
migration, abandonment, or reference-safe retention transition. Activating
A → B → A never merges B's state into A.

State reads and writes remain serialized by the same Instance owner. Writes
require exact schema, generation, and revision checks plus current Definition
authority and owner fencing. See [Generational Skill State](SKILL_STATE.md)
and [Migrating to 0.2.5](MIGRATING_TO_0_2_5.md).

## Run ownership and observable boundaries

Each input creates a Run retained by the Instance. The ready queue is FIFO and
deduplicated. One Move is selected through an Instance mailbox message, so
calls, monitoring, registry failure, and correlated worker results remain
ordinary OTP messages rather than recursive reducer calls.

Run creation and its first advance form one bounded two-Move sequence. Input
normalization runs in the Move worker against the latest committed State, not
inside the GenServer callback. Later closed `{:continue, run}` steps return to
the FIFO tail. A worker crash fails only its owned Run, and a duplicate
caller-provided Run id is rejected before normalization or provider work.

```elixir
{:ok, turn} = Spectre.turn(instance, "prepare the report")

case turn.observable do
  {:reply, output, ref} ->
    deliver_once(output, Spectre.Run.Ref.token(ref))

  {:awaiting, ref} ->
    Spectre.resume(instance, ref, {:execute, ref})

  {:needs, _request} ->
    Spectre.Turn.resolve_policy(turn, {:accept, :approved})
end
```

The public Turn contains only the boundary projection. The Instance keeps the
Run and verifies the supplied revision-fenced ref before resuming it. Use
`Spectre.Instance.info/1` and `run/2` for privacy-safe operational projections;
they do not return provider payloads or the internal continuation.

Effect work runs outside the Instance mailbox. Its internal receipt is fenced
by Instance generation, Run id and revision, Invocation id, and dispatch id.
Late, duplicate, foreign, and stale receipts are ignored. The Instance remains
responsive while the capability is in flight.

Each Effect and policy Awaitable staged by an Instance carries its owning Run
id. Several Runs can therefore wait independently at policy or Effect
boundaries while sharing the Subject's ordered State. Ordinary input is
matched to an open policy Run by its channel conversation origin. If no origin
is available, the legacy shortcut is safe only when exactly one policy is
open; several possible owners return `{:ambiguous_instance_policy, run_ids}`.
An Effect boundary is always resumed explicitly with its Invocation ref.

The Instance still applies one state-changing Move at a time. Before a
retained Run advances, it is rebased onto the latest committed shared State,
including lifecycle entries owned by other Runs. Capability Invocations use a
separate state lock: calls arriving while one is in flight stay queued and
continue after its terminal state has been committed.

Stateless Runtime calls and conversation-scoped Sessions do not opt into
per-Run lifecycle ownership and retain the single pending Effect contract.

## Operational loops on the same Instance

In 0.2.0 the same Instance also owns the canonical state of Work, Vigil, and
authorized external controllers. Conversational Runs and operational loops
remain separate domains, but all committed changes are serialized by this one
Subject-scoped owner.

```elixir
{:ok, work_ref, _view} =
  Spectre.start_work(instance, MyApp.ExportReport, %{report_id: report_id})

{:ok, vigil_ref, _view} =
  Spectre.register_vigil(instance, MyApp.AccountVigil, %{account_id: account_id})

{:ok, work} = Spectre.loop(instance, work_ref)
{:ok, vigil} = Spectre.loop(instance, vigil_ref)
```

The Instance has a bounded operational Runner pool, configured with
`:max_operation_runners`. Each Runner receives a revision-fenced snapshot,
executes one registered operation attempt outside the Instance mailbox, sends
one correlated Result, and terminates. A waiting or paused loop retains no
Runner. Retry, recovery, control, and canonical commit decisions remain with
the Instance.

Use `loops/2` for visible projections and `resolve_loop/3` when a natural
command may identify a loop by kind, Definition, status, or origin. Multiple
matches return an explicit ambiguity error. Pause, update, resume, renew,
trigger, and stop are durable commands; stop is terminal while pause is
reversible.

The complete canonical graph can be persisted through
`Spectre.Instance.CheckpointStore`. Configure `:checkpoint_store` on Instance
startup and use `flush_checkpoint/2`, `checkpoint_status/1`, and
`reconcile_checkpoint/2` at the host boundary. An ambiguous compare-and-swap
write erects a persistence fence and is never retried automatically.

Current schema-4 checkpoints retain the Activation, every retained Run,
Definition lifecycle and event records, and the complete private Skill-state
branch graph. Readers still accept schemas 1 through 3 and supply missing
sections during restore. When a legacy Instance key is found, the adapter's
`migrate_instance_key/5` callback must atomically expose the migrated bytes
under the stable Ref. Divergent histories under old and new keys are rejected.

See [Work, Vigil, and the operational runtime](OPERATIONS.md) for controller,
operation, recovery, event, and delivery contracts.

### Conversational Move scheduling

The GenServer mailbox never executes input plugs, routing, model calls, memory
callbacks, renderers, or Actions directly. An ordinary Move runs those bounded
callbacks in its worker, so operational calls such as `info/1` remain
responsive. However, Prism inference and other ordinary provider calls still
execute synchronously *within that one active Move worker*. Ready Runs wait for
that Move to finish or hit its configured provider timeout.

The explicit in-flight `Invocation + Receipt` path in this release covers
staged Effect/Action execution, including Lens when it is mounted as an
Action. A generic provider Invocation requires a serializable mid-turn
continuation and typed provider receipt; it is intentionally not simulated by
renaming the whole Move or running stale-State workers concurrently.

This conversational one-Move limit is independent from the bounded
operational Runner pool described above.

## External identities and explicit linking

Channel adapters authenticate a provider principal first, then construct an
opaque `Spectre.ExternalIdentity`:

```elixir
identity =
  Spectre.ExternalIdentity.new(
    provider: :beam,
    channel: :telegram,
    endpoint: :support_bot,
    principal_id: verified_sender_id,
    authenticated_at: System.system_time(:millisecond),
    proof_ref: authentication_receipt_id
  )
```

The raw principal is hashed at construction. Authentication is a channel
responsibility; the core does not infer it from populated source fields.

An already verified bootstrap can bind an identity with explicit proof:

```elixir
{:ok, link} =
  Spectre.Subject.Registry.bind(
    MyApp.SupportAgent,
    subject,
    identity,
    proof: authentication_receipt
  )
```

Afterward, ingress resolves the exact Agent-scoped identity before looking up
the Instance:

```elixir
{:ok, subject, _link} =
  Spectre.Subject.Registry.resolve(MyApp.SupportAgent, identity)

{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.SupportAgent, subject)
```

Adding another channel uses a one-time destination challenge:

```elixir
{:ok, intent, challenge} =
  Spectre.Subject.Registry.open_link(
    MyApp.SupportAgent,
    subject,
    existing_identity,
    destination_identity,
    ttl: :timer.minutes(5),
    attempts: 3
  )

# Deliver `challenge` only through the authenticated destination channel.
{:ok, destination_link} =
  Spectre.Subject.Registry.confirm_link(
    intent.id,
    destination_identity,
    received_challenge
  )
```

Only the challenge digest is retained. Challenges expire, have bounded
attempts, and are one-time. A policy can require
`source_confirmation?: true`, in which case `confirm_source/3` must also be
called from the already linked identity. Binding an identity already owned by
another Subject returns a conflict; no name, address-book, number-similarity,
message-text, or model-based merge exists.

`revoke/2` removes future resolution through a link without deleting the
Subject or Instance State. Successful commits and revocations pass through the
privacy-safe Journal boundary before becoming visible.

The bundled Subject Registry and active-Run registry are local in-memory
coordination for this phase. Applications that require cross-node routing or
durable identity recovery should persist the exposed value objects and
re-establish them through an authenticated host workflow; they must not infer
links after restart.
