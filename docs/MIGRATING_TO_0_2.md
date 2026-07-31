# Migrating from 0.1.x to 0.2.0

Spectre 0.2.0 introduces the vNext operational runtime while keeping the
recoverable 0.1.6 conversational contracts recognizable. Migration can be
incremental: existing Flow, Run, Effect, Invocation, Session, and Turn code
does not need to be renamed to adopt Work or Vigil.

## Dependency and toolchain

Update the dependency to 0.2:

```elixir
def deps do
  [
    {:spectre, "~> 0.2.0"}
  ]
end
```

Spectre continues to require Elixir 1.19 or later. Regenerate documentation
and run compilation with warnings as errors before deploying an upgraded
Agent Definition.

## What remains compatible

- `Spectre.Run` is still the continuation for one conversational unit; it was
  not renamed to Work.
- `flow/on`, routing, policies, Effects, Invocations, and the public Turn
  projection retain their roles.
- `Spectre.State` remains conversational state and retains its versioned codec.
- Calls without a Subject can continue to use the legacy supervised
  `Spectre.Session` adapter.
- Subject-scoped `Spectre.Instance` remains the recommended long-lived owner.

The permanent 0.1.6 State v5 and Run v1 fixtures remain recovery tests. New
operational state is stored in the Instance's canonical checkpoint, not inside
a conversational Run checkpoint.

## Opt in to canonical Instance checkpoints

0.1.x state adapters persist conversational `Spectre.State`. The new
`Spectre.Instance.CheckpointStore` persists the complete canonical Agent
checkpoint with compare-and-swap revision fencing.

Implement both callbacks:

```elixir
@behaviour Spectre.Instance.CheckpointStore

@impl true
def load(instance_ref, opts)

@impl true
def compare_and_swap(instance_ref, json, expected_revision, new_revision, opts)
```

Then configure the Instance:

```elixir
Spectre.instance(supervisor, MyApp.Agent, subject,
  checkpoint_store: {MyApp.CheckpointStore, tenant: tenant_id},
  checkpoint_mode: :async
)
```

Use `:manual` when the host decides when to call `flush_checkpoint/2`.

Do not map an uncertain store timeout to an ordinary error. Return
`{:error, {:ambiguous, reason}}` whenever the adapter cannot determine whether
the write committed. Spectre stops automatic persistence until
`reconcile_checkpoint/2` validates the stored revision.

Canonical checkpoint schema version 1 is strict. Unknown keys, unknown atoms,
non-portable values, mismatched Subject ownership, incompatible controller
versions, and invalid loop/control/event relationships are rejected. Keep the
old application version available while planning a controller Definition
upgrade, or implement `checkpoint_compatible?/2` deliberately.

## Move long procedures out of conversational Runs

Use a Work when an activity:

- consists of several operations or attempts;
- must remain inspectable after the initiating Turn returns;
- needs pause, update, resume, retry, budget, or restart semantics;
- should publish progress or artifacts without rewriting the original Turn.

Keep ordinary request/response handlers in Flow. A Work is not a renamed Run
and should not contain an open-ended goal. Define a versioned controller,
register or explicitly import its operations, then start it on the Instance:

```elixir
{:ok, work_ref, view} =
  Spectre.start_work(instance, MyApp.ExportReport, %{report_id: report_id})
```

Replace process polling with `Spectre.loop/3`, `loops/2`, or committed event
subscriptions. Treat the returned `Spectre.Operation.View` as a redacted
projection, not mutable state.

## Replace recurring worker processes with Vigil

Use a Vigil for an observation that waits between timer or event triggers.
The Vigil state is durable while each observation still gets a fresh,
temporary Runner. Register it with `Spectre.register_vigil/4`; use
`renew_loop/4` for expiry and the same pause/resume/stop APIs as Work.

Timer and trigger generations are fenced. Hosts must not replay raw timer
messages themselves after updating a Vigil.

## Register operations explicitly

An Agent operation declaration creates an immutable application catalog:

```elixir
operation :lookup, {MyApp.Lookup, :execute}, input: :map, output: :map
```

A Work or Vigil imports it with `uses_operation(:lookup)`, or declares a local
operation with `operation/3`. The entire Agent catalog is no longer implicitly
available to every controller. This is intentional capability scoping.

Choose the correct operation kind and side-effect declaration. In particular,
do not mark a non-idempotent external call as retryable merely to preserve old
worker behavior. Supply a reconciliation callback when the external system
supports receipts or status lookup.

## Adopt durable control commands

Replace ad hoc worker messages with:

```elixir
Spectre.pause_loop(instance, ref)
Spectre.update_loop(instance, ref, payload)
Spectre.update_and_resume_loop(instance, ref, payload)
Spectre.resume_loop(instance, ref)
Spectre.renew_loop(instance, ref, expires_at)
Spectre.stop_loop(instance, ref, reason)
```

For retries from an HTTP or chat adapter, reuse a stable `command_id` and
correlation id. Declare `update_fields` and implement `apply_update/4`; fields
outside that contract are rejected. A stop is terminal and is not equivalent
to pause.

Immediate pause is opt-in at two levels: the Work/Vigil Definition must permit
it and the caller must provide explicit authorization. It fences execution but
cannot prove that an external side effect was cancelled.

## Route committed events deliberately

Operational completion does not mutate a Turn that has already returned.
Applications can read or subscribe to events, or opt selected event types back
into the normal Flow router:

```elixir
route_operation_events([:completed, :observation_significant])
```

Do not create a second application-level matcher for these events. Flow is the
single conversational routing boundary.

Event significance and delivery authorization are separate. To send a
proactive message, store Subject consent, authorize a destination and policy,
perform transport outside Spectre, then record the delivery receipt.

## Action and Effect providers

Action and extension Effect operations use the existing provider-neutral
mounts. Explicit operation idempotency keys now survive the Action/Effect
dispatcher boundary; direct dispatch without an explicit key still derives
one from the Effect.

Provider discovery and planner catalogs remain closed. A schema hash supplied
by a planner is verified against the currently mounted provider before
execution.

## Portable values and atoms

Do not place PIDs, ports, references, functions, clients, or secrets in Work,
Vigil, event, receipt, or canonical checkpoint data.

`Atom.to_string/1` is the correct serializer for a known atom. Never use
`String.to_atom/1`, `:erlang.binary_to_atom/1`, or `:erlang.list_to_atom/1` on
runtime input. Where a closed codec must decode an atom, use
`String.to_existing_atom/1`, reject unknown values, and prefer explicit maps
for finite external vocabularies.

## Deployment sequence

1. Upgrade code while leaving existing Flow and Session paths unchanged.
2. Add a canonical checkpoint store and verify load/CAS/reconciliation in a
   staging environment.
3. Introduce one precise Work with a closed function operation.
4. Exercise crash, timeout, retry, pause/update/resume, and restart paths.
5. Add event routing and proactive delivery only after visibility and consent
   policies are explicit.
6. Convert recurring observers to Vigil.
7. Upgrade external Directive, Lens, Kinetic, Prism, Mnemonic, Beam, or Pulse
   adapters against the 0.2.0 provider-neutral contracts independently.

See [Work, Vigil, and the operational runtime](OPERATIONS.md) for complete
examples and invariants.
