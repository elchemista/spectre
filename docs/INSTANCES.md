# Agent Instances and Subjects

Spectre 0.1.4 adds a long-lived owner for the ordered state of one logical
Agent and one canonical Subject:

```text
Spectre.AgentRef + Spectre.Subject -> one local Spectre.Instance
```

An Instance is not addressed by a PID, chat id, sender name, phone number, or
conversation id. Those values can change across restarts and channels. The
logical pair is portable; `Spectre.Instance.Registry` maps it to the current
local process.

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

When a Run owns a policy boundary, ordinary input such as
`Spectre.turn(instance, "yes")` resumes that exact Run, preserving the legacy
conversation contract and Run revision fence. An Effect boundary must instead
be resumed explicitly with its Invocation ref.

The 0.1.4 lifecycle still stores the single active Effect in
`Spectre.State`. While a Run owns that Effect boundary, a second
lifecycle-changing turn returns `{:instance_lifecycle_locked, run_id}`. A
caller queued before another Run opens the global lifecycle boundary is
released with the same error rather than being suspended indefinitely. Moving
the lifecycle constraint onto each Run belongs to the next phase.

### Provider scheduling limit in 0.1.4

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
