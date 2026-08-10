# Event Ownership and Definition Lifecycle

Spectre 0.2.4 admits external events through the canonical Instance sequencer.
The same mailbox owns activation, Runs, operations, lifecycle transitions, and
checkpoint commits, so admission cannot race those decisions outside the
revision boundary.

## Event Envelope

`Spectre.Event.Envelope` is a portable schema-1 value. It carries a stable event
id and class, causation and correlation ids, an optional Run or operation
continuation, origin evidence, payload schema and payload, authenticity and
provenance evidence, and emission time. Admission adds:

- the selected owner Definition Ref;
- the activation generation observed by the sequencer;
- the owner's current authority epoch and Instance fencing token;
- the canonical admission revision and time;
- an `:admitted` or `:quarantined` status and deterministic receipt.

Supported classes are `:input`, `:reply`, `:policy_answer`, Flow progress and
completion, Work progress and completion, Vigil progress and completion, and
`:global`.

Origins never select behavior. Reply, policy, Flow, Work, and Vigil events are
owned by the Definition pinned to their exact continuation. Input without a
continuation is owned by the active Definition. A global event is admitted to
the active Definition only after the caller supplies compatible schema
evidence.

```elixir
{:ok, event} =
  Spectre.admit_event(instance,
    id: provider_event_id,
    event_class: :policy_answer,
    continuation_ref: run_ref,
    correlation_id: correlation_id,
    origin_definition_ref: observed_origin,
    payload_schema_ref: "my_app/policy-answer/1",
    payload: %{"answer" => "yes"},
    authenticity: %{"principal" => principal_ref}
  )
```

Repeating the same event id and intent is idempotent. Reusing the id for a
different intent returns a conflict. Missing, expired, wrong-kind, mismatched,
or ambiguous continuations and incompatible global schemas are durably
quarantined. They are never rebound to whichever Definition happens to be
active.

`Spectre.admitted_events/2` and `Spectre.quarantined_events/2` return newest
first and accept a bounded `:limit`.

## Independent lifecycle axes

Every known Definition has a `Spectre.Instance.Lifecycle` record:

| Axis | States | Meaning |
| --- | --- | --- |
| admission | `accepting`, `draining`, `closed` | whether new work or existing continuations may enter |
| authority | `granted`, `restricted`, `revoked` | current permission to continue or cross a side-effect boundary |
| retention | `retained`, `gc_eligible`, `purged` | whether referenced state and artifacts must remain |
| activation | `active`, `inactive` | whether unowned input selects this Definition |

Transitions use `expected_revision:` CAS. Admission, authority, and retention
move monotonically unless an explicitly authorized activation reopens a
non-revoked retained Definition. Activation changes the active record and
drains the previous one atomically.

```elixir
{:ok, lifecycle} = Spectre.definition_lifecycle(instance)

{:ok, draining} =
  Spectre.drain_definition(instance, :active,
    expected_revision: lifecycle.revision,
    reason: :deployment
  )

{:ok, revoked} =
  Spectre.revoke_definition(instance, draining.definition_ref,
    expected_revision: draining.revision,
    reason: :security_response
  )
```

Drain blocks new Turns, Work, Vigil, and controller admission while allowing
already-owned continuations. Closed admission blocks those continuations too.
Revocation advances the Definition's authority epoch and blocks admission,
continuation, canonical commit, retries, and Effect or operation dispatch.

The authority epoch stored on a Run or operation records its lineage only. It
does not preserve authority: every current-time boundary consults the current
lifecycle record and current Instance owner fence.

## Checkpoint compatibility

Spectre 0.2.4 introduced checkpoint and state schema 3 with `lifecycles`,
`event_admissions`, and `event_quarantine` sections. Readers still accept
schemas 1, 2, and 3. When schema 2 contains an Activation, the reader derives
the matching active lifecycle in memory. Current 0.2.5 writers emit schema 4;
see [Migrating to 0.2.5](MIGRATING_TO_0_2_5.md).

See [Migrating to 0.2.4](MIGRATING_TO_0_2_4.md) for deployment sequencing.
