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

`agent:` selects the Agent's routing and Server callbacks. The authenticated
`consumer:` receives the presentation and later submits the person's decision.
In `gam.operations`, the pair `{:kinetic, :send_email}` names a registered
host operation and `confirm: true` requires consent for every invocation.
The allowlist and each mount's restrictions determine the available
consequences. Starting without `gam:` creates an ephemeral boundary with
an empty effect allowlist.

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
| `storage: {MyApp.Storage, reference}` | Use a custom unified Server Store. The same provider reference reaches the coordination, ledger and optional projection callbacks. |

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

When an OTP supervisor restarts an AgentServer after a crash, the new Root
reattaches to the live Managed GAM owner on the same node. The Domain and
session keep their identity. A checkpointed foreground consent can continue
with its original presentation and deadline while GAM still holds that
presentation. Recovery reconciles any effect GAM already admitted before it
continues the turn. If the original input was checkpointed and its one-use
consent receipt is still live, recovery continues that same input. Resolve
the replacement Root PID through its registered name or your supervisor before
sending input or a consent decision.

Direct `start_link/1` ties Managed GAM to the Root's lifetime. A supervised
shutdown also closes Managed GAM. On a cold restart, durable storage can
recover the Domain and command history, and pending consent requires a fresh
presentation. RAM-only recovery depends on the live owner, which releases its
resources if the Root does not return within the configured shutdown timeout.
An explicit `Spectre.Server.reset/2` starts a new session. A crash before reset
activation leaves the previous authority in force. Once a durable activation
begins, automatic restart needs a record of the selected generation.

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

`propose/4` takes the current callback Context, the host operation, its
concrete arguments and options. Here `:sent` is the local result tag.
The operation and arguments freeze before admission. The later result's
Outcome describes the milestone actually observed. Uncertain execution
requires reconciliation of the original Act.
Keep consequential I/O inside registered effect adapters. Managed GAM mediates
the declared boundary within the BEAM; it cannot retroactively govern direct
HTTP calls made inside application callbacks.

## Present consent through the trusted consumer

The consumer receives:

```elixir
{Spectre.Server.GAM.Managed, owner, {:presentation, material}}
```

`owner` identifies the Managed GAM process that emitted the card. Use the
Root's `server` handle to acknowledge and decide. Render
`material["rendered_payload"]`, retain `material["presentation_ref"]` and
call `Spectre.Server.presented(server, presentation_ref)` after actual
rendering. After the human makes a separate choice, call
`Spectre.Server.decide(server, skill_or_nil, presentation_ref, :confirm | :reject)`.
Pass the mount ID for a Skill and `nil` for Root or Activity consent. Only
the configured consumer can use these root APIs. GAM checks the exact
presentation, pending target and one-use proof during the decision.

Text-based input can use `handle_pending/3` with `confirm_pending`,
`reject_pending` and `explain_pending`. The configured interpreter and original
input provenance still bind the response to the current Presentation. See
[Pending lifecycle](PENDING_LIFECYCLE.md) for suspension, resume and expiry.

## Consent from an Activity

The consumer renders and acknowledges the same `{:presentation, material}`
envelope for an Activity's governed command. After acknowledgement, match
`{Spectre.Server, root, {:activity, identity, {:pending, presentation_ref}}}`
to associate the card with its Activity `identity.ref`. Decide through the
Root with `Spectre.Server.decide(root, nil, presentation_ref, choice)`.
The pending event is readiness to accept the person's choice. The effect
result arrives separately. When a relay to an Activity or Skill times out,
`decide/4` returns `{:error, :decision_outcome_unknown}`. The target can
still process its queued decision. Wait for the pending state or governed
outcome before submitting another decision.

For an ordinary Activity question, handle its `{:waiting_input, wait}`
lifecycle event. Answer with
`Spectre.Server.input(root, text, activity: ref, pending: {wait.id, wait.revision})`.
Here `ref` names the Activity execution and the pending pair selects that
question. Send consent through the Presentation reference instead.

Use `signal_activity(root, ref, {:revise, details}, if_revision: revision)`
to request a specific Activity revision. Once applied, that change invalidates
the old pending presentation. Late Outcomes for already admitted acts can
still arrive as an Activity `{:effect, result}` event, even if the execution
that requested them has ended. [Activity lifecycle](AGENT_SERVER.md#run-a-background-activity).

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

The application supplies `ctx.assigns[:observed_email]` from an earlier step.
`message` explains the decision in the presentation, and `expires_in: 60_000`
requests one minute to decide within the configured consent limit. Other actions
use the default policy through `super`.

An override can reject work or require consent within the existing mandate.
Applicable confirmation requirements remain binding. Managed GAM checks custom
presentation material against frozen arguments and authority. The callback
prepares policy data. The registered executor handles the effect after admission.
[Server contracts](SERVER_CONTRACTS.md) adds optional application schemas and
permission diagnostics.

## Share the boundary with Skills and Activities

Mounted `Spectre.Skill` servers receive their root's existing GAM connection.
They have independent GenServers, state, workers and checkpoints, with one shared
Domain. Configure identity, storage and root operations once. A mount's
`governed:` references further restrict its operations; `skill_options` cannot
replace the boundary or grant authority.

Every proposal retains Skill provenance. Consent addresses its exact mount and
Presentation. Closing a conversation or expiring an intention does not erase an
Act or Duty. See [Skills](SKILLS.md) for routing and the consumer API.

Activities share the same Domain as the Root. The host's allowed Activity
types and scoped tools narrow the operations an Activity can use. A governed
operation still needs host registration, an applicable mandate and admission.

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
