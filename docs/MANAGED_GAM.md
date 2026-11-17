# Managed GAM

AgentServer automatically owns its GAM integration: Domain, Scope, standard
ingress, frozen Candidates and Presentations, registered execution and recovery.
Application callbacks supply business policy. The kernel verifies authority,
Evidence and admission before releasing an effect's capability.

## Start with identity, operations and storage

```elixir
Spectre.Server.start_link(
  agent: MyApp.Agent,
  identity: %{subject: authenticated_user.id},
  consumer: self(),
  gam: [
    storage: {:disk, "var/agents/" <> to_string(authenticated_user.id)},
    operations: %{{:kinetic, :send_email} => [confirm: true]}
  ]
)
```

The operation must have a registered effect adapter in the selected Stack.
Installing a package makes its capabilities available; the root's operation
allowlist and mount restrictions determine what this Agent can propose.
Starting without `gam:` creates an ephemeral boundary with no allowed effects.

Supply identity from the authenticated application transport. Accepted keys are
`subject`, `conversation`, `task`, `tenant`, `org` and `organization`, using
portable values. Atom/string spellings normalize; conflicting or unknown keys
fail startup. Credentials and process handles do not belong in identity.
The complete accepted identity is frozen into execution context.

Disk storage requires an explicit nonempty identity. A missing human subject
records a service identity rather than claiming human authentication. The
application remains responsible for authenticating the person behind its
trusted consumer; a BEAM PID alone cannot prove that identity.

## Choose persistence

| Configuration | Behavior |
| --- | --- |
| `storage: :ephemeral` | Complete RAM-only operation, without a database. |
| `storage: {:disk, path}` | Durable GAM history and coherent default coordination/checkpoint storage. |
| `storage: :ledger` | Use the configured Ledger Stack resource for coordination, canonical history and its optional Domain projection. |
| `storage: {:ledger, {Adapter, options}}` | Use a compatible application-supplied GAM adapter and coordination `store:`. |

With PostgreSQL Ledger, the application starts its Repo and installs migrations
before starting Servers. Startup creates neither databases nor tables. Its
`gam_domain/1` integration supplies canonical history and the disposable
per-record projection; older `gam_ledger/1` history-only providers remain
supported. See [Ledger setup](https://github.com/elchemista/spectre_ledger/blob/0.1.0/docs/SPECTRE_0_4.md).

```elixir
Spectre.Server.start_link(
  agent: MyApp.Agent,
  stack_runtime: stack_runtime,
  identity: %{subject: user.id, conversation: conversation_id},
  consumer: self(),
  gam: [storage: :ledger, operations: allowed_operations]
)
```

Restart verifies the same authority foundation and configuration. A different
identity, operation policy or explicit authority deadline cannot silently reuse
old authority. Selecting Ledger does not migrate an existing disk Domain.

A projection-backed Domain loads the records needed by a command, commits changed
rows and releases historical records. Active Duties and relevant proof groups
can grow; full views can materialize history temporarily. DB latency still
affects serialized commits. [Domain storage](DOMAIN_STORAGE.md) explains the
adapter contract, missing-data behavior and explicit retry/fresh-RAM recovery.

Use top-level `payload_store: {MyApp.Payloads, options}` to externalize
application content through `put/3` and `fetch/3`. The application chooses opaque
references, retention, encryption and backend. Failures do not silently fall
back to inline storage. See [Payload storage](PAYLOAD_STORAGE.md).

## Propose an operation and handle its result

```elixir
def handle_flow({:mail, :send}, _input, ctx) do
  propose(ctx, {:kinetic, :send_email},
    %{"to" => ctx.assigns.recipient, "body" => ctx.assigns.draft},
    on_result: :sent)
end

def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
  do: respond(ctx, "The mail service confirmed the operation.")

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

`propose` returns a command-bearing Context. Admission is distinct from external
success. The effect adapter reports the milestone actually observed; uncertain
outcomes retain an unresolved Duty rather than triggering a blind retry.
Keep consequential I/O inside registered effect adapters. Managed GAM mediates
the declared boundary within the BEAM; it cannot retroactively govern direct
HTTP calls made inside application callbacks.

## Present consent through the trusted consumer

The consumer receives:

```elixir
{Spectre.Server.GAM.Managed, owner, {:presentation, material}}
```

Render the frozen material and its controls, then call
`Spectre.Server.presented(server, presentation_ref)`. After the human makes a
separate choice, call
`Spectre.Server.decide(server, skill_or_nil, presentation_ref, :confirm | :reject)`.
Only the configured consumer can use these root APIs. The exact presentation,
pending target and one-use proof are checked; rendering acknowledgement is not
consent. A model label, unrelated process or stale card cannot approve.

Text-based input can use `handle_pending/3` with `confirm_pending`,
`reject_pending` and `explain_pending`. The configured interpreter and original
input provenance still bind the response to the current Presentation. See
[Pending lifecycle](PENDING_LIFECYCLE.md) for suspension, resume and expiry.

## Customize business policy

`handle_action/2` runs during command acquisition. Its portable policy is frozen
in the outbox and survives recovery:

```elixir
def handle_action(%{operation: {:kinetic, :send_email}, args: %{"to" => to}}, ctx) do
  if to == ctx.assigns[:observed_email],
    do: {:confirm, %{message: "Contact this address?", expires_in: 60_000}},
    else: {:reject, :recipient_not_observed}
end

def handle_action(action, ctx), do: super(action, ctx)
```

An override can reject work or require consent; it cannot expand a mandate or
remove required confirmation. Custom presentation material is checked against
frozen arguments and authority. The callback prepares policy data and performs
no effect itself. [Server contracts](SERVER_CONTRACTS.md) adds optional application
schemas and permission diagnostics.

## Share the boundary with Skills

Mounted `Spectre.Skill` servers receive their root's existing GAM connection.
They have independent GenServers, state, workers and checkpoints, with one shared
Domain. Configure identity, storage and root operations once. A mount's
`governed:` references further restrict its operations; `skill_options` cannot
replace the boundary or grant authority.

Every proposal retains Skill provenance. Consent addresses its exact mount and
Presentation. Closing a conversation or expiring an intention does not erase an
Act or Duty. See [Skills](SKILLS.md) for routing and the consumer API.

## Submit from a trusted actor

The consumer and configured `submitters` can enter the same path from another
process:

```elixir
Spectre.GAM.submit(server, {:kinetic, :send_email}, arguments,
  on_result: :sent, key: "outreach:" <> draft_id)
```

Allowed options are `on_result`, `confirmation` and `key`. Acquisition returns a
command ID; the Server receives the eventual `handle_result/3`. A busy Server
rejects before acquisition. Submitters cannot approve on behalf of the user.

An optional nonempty key of at most 256 bytes deduplicates acquisition. The same
request returns its original ID; changed material returns
`:submission_key_conflict`. Keys are checkpointed atomically, with at most 4,096
retained keys per Server. Exhaustion refuses new keyed submissions rather than
forgetting protection. This is acquisition deduplication within the storage
lifetime, not exactly-once external delivery.

## External human approval

An operation may set `confirm: true, approver: {:external, address}`. Configure
`gam: [approvals: ...]` with the transport, authorized human Principal, public key
and approval mandate. The recipient agent transports and presents the request;
the human remains the approver. The customer's existing execution Mandate still
limits admission.

[External approval](EXTERNAL_APPROVALS.md) defines the signed request/decision,
expiry, replay, inbox and recovery contracts. Its runnable two-agent example
works without Pulse. The [Pulse adapter](https://github.com/elchemista/spectre_pulse/blob/0.1.0/docs/EXTERNAL_APPROVALS.md)
uses the same contract; technical delivery receipts carry no approval authority.

## Revoke authority and review Duties

The configured root consumer can call `Spectre.GAM.revoke(server)` to prevent
later effects under its application mandate. It preserves history and does not
cancel an already committed effect or resolve an existing Duty.

An independently authenticated reviewer can be configured under
`gam: [reviewer: [identity: ..., consumer: ...]]`. It must represent a different
subject or service task and use a different consumer. Its authority is bounded
to this Agent's causally attached Duties. Normal chat consumers, Skills and
submitters gain no review authority.

```elixir
# Called by the configured review consumer after actual independent review.
Spectre.GAM.resolve_duty(server, duty.ref, :ratify,
  supporting_refs: [cause_act.ref])
```

Supporting references must be a nonempty list of existing Evidence, Outcome or
Act records. Supported dispositions are `:condition_met`, `:ratify`, `:repudiate`,
`:compensate`, `:assign` and `:accept_loss`; `meter_resolution` may be `:none`,
`:settle` or `:release`. Inspect the returned Decision: a submitted request is not
proof of closure, and ratification does not prove the original effect succeeded.

Operation and reviewer authorizations may independently set an absolute
`expires_at` deadline. Restart cannot extend it; changing it against existing
history fails configuration verification. Per-presentation expiry is separate.
Without a reviewer configuration, unresolved Duties remain open.
