# Automatic GAM and application responsibilities

AgentServer manages GAM automatically in every environment. A returned command
enters the durable outbox before a worker proposes its consequence. Spectre owns
the Domain, Scope, standard ingress, Candidate/Presentation construction,
registered execution and command journal. There is no application Host or
separate manual Server integration.
The governing semantics remain those of the
[GAM manifesto](https://spectre.guide/en/governed-act-model).

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

Installing an action makes it available; the trusted application's `operations`
configuration declares which effects this Agent may propose. The application
supplies the user's identity from its authenticated transport. A configured
`subject` identifies the human principal; otherwise the boundary records a service
identity without claiming a human authenticated. Spectre records the application
as accountable and retains the Agent and Skill's computational provenance. A model output cannot supply identity or grant
itself additional operations.

Starting without `gam:` still creates the automatic boundary, with an empty
operation allowlist. Such an Agent can route, generate and reply; proposing an
undeclared effect fails closed. With ephemeral storage, an omitted identity gets
a fresh conversation service identity. Disk storage requires an explicit nonempty
identity so restarts cannot silently create a new authority owner. `authority:`
selectors and replacement bridge modules/tuples are rejected. Unknown GAM
configuration keys also fail startup rather than silently ignoring a policy typo.
Identity has a closed shape: only `subject`, `conversation`, `task`, `tenant`,
`org` and `organization` are accepted. Atom and string spellings normalize to the
same canonical keys; conflicting values are rejected. Unknown fields, including
credentials, fail startup. Values must be portable data, not structs, PIDs or
functions; pass an account ID as `subject`, not a `Spectre.Subject` struct.
Spectre freezes the entire accepted identity, including
tenant/organization, into the Candidate so execution cannot switch partitions.
Keep business data in application state and provider secrets in their configured
runtime resources, never in identity or model-visible assigns.

## Fixed and configurable responsibilities

| Area | Application chooses | Spectre and GAM enforce |
| --- | --- | --- |
| Identity | Authenticated user/session and trusted consumer | Frozen execution identity and consumer-bound consent |
| Effects | Registered adapters and allowed operations | Schema/catalog validation and admission before capability release |
| Business policy | Reject a request, require confirmation, freeze relevant context | A callback cannot expand authority or remove required confirmation |
| Conversation | Routes, result handling, pending behavior and timers | Correlated continuation, recorded lifecycle and stale/replayed decision rejection |
| Presentation | Business wording and reviewed context | Exact frozen material, actual show acknowledgement and separate user choice |
| Persistence | Storage location and compatible application stores | Coherent authority history, journal/checkpoint recovery and configuration-drift rejection |
| Execution outcome | Adapter reports what the service actually observed | Admission is distinct from success; uncertainty is preserved and not blindly retried |
| Parallel Skills | Mounts, local state and allowed operations | One shared Domain, invocation attribution and mount restrictions |
| Unresolved Duties | Independent review identity and real reconciliation information | Separate review authority, kernel-checked disposition and retained history |

The runtime supplies a coherent default checkpoint alongside its journal. Use
`storage: {:disk, path}` for restart recovery. `:ephemeral` is an explicit storage
choice and rejects externally supplied durable state to avoid mixing recovery
histories. It does not select a different governance protocol. For a time-limited
application authorization, set `gam: [expires_at: absolute_utc_milliseconds, ...]`.
The default has no application-selected expiry before the supported year-9999
upper bound. Restart does not extend an explicit deadline, and changing it on
an existing disk history is rejected as an authority-configuration change.
This deadline is distinct from per-presentation `expires_in`, consent expiry and
the independent reviewer's authorization deadline.

The declared boundary is mediated within the BEAM, not a sandbox for arbitrary
Elixir code. Keep consequential I/O in registered effect adapters. A direct HTTP
request inside a callback has already happened before its return and cannot be
retroactively governed by logging it. Real-world authentication and access to
external resources remain responsibilities of the hosting application.

## One runtime, distinct authority responsibilities

```text
Trusted application
  ├─ identity + allowed operations + storage
  │       ↓
  │  AgentServer ── Skill Servers
  │       │ returned proposal / external GAM.submit
  │       ↓
  │  automatic GAM boundary → kernel admission → committed Act → adapter
  │       ↑                                                     ↓
  │       └──────────────── observed Outcome / unresolved Duty ──┘
  │
  └─ independent reviewer, when configured
          ↓ review and reconciliation
      separate authenticated Scope → same kernel → recorded Duty disposition
```

Conversation and operation policy remain application behavior. Admission,
commitment, capability release and the meaning of Evidence, Outcome and Duty
remain kernel responsibilities. The automatic runtime assembles and correlates
those records; it cannot change their laws.

## Mounted Skills use this same GAM

The root AgentServer starts the automatic GAM integration and its separate
Domain process. A mounted Skill with `server:` receives that existing connection,
not another bootstrap or a copy of its ledger. Configure identity, storage and
`gam:` operations on the root; Spectre passes the fixed boundary to the children.
`skill_options` cannot replace it or grant extra authority.

Each Skill owns a GenServer, assigns, workers, streams, pending intentions and
checkpoint key. Agent and Skill work may proceed concurrently; admission is
ordered by the shared kernel and every proposal retains its Skill invocation
Evidence. The mount's `governed:` list further restricts which configured
operations it may propose. Neither a mount nor a Stack installation grants a
new mandate.

Consent remains local to the exact pending intention and presentation. A
confirmation for Research's email cannot authorize Knowledge's memory write.
Presentation events and decisions pass through the same root consumer boundary;
`Server.decide(root, mount, presentation_ref, decision)` identifies the origin.
Expiry and timer closure enter the same recorded lifecycle and never erase
Acts, uncertain Outcomes or Duties. See [Skills](SKILLS.md) for the process tree,
shared/local state table and a two-Skill confirmation example.

A missing or ambiguous external receipt leaves a Duty open. The Agent's proposing
role is not automatically an independent reviewer of its own effect. Closing a
chat, expiring a confirmation or revoking its mandate does not resolve that Duty.
Without a configured independent review path, the history retains the unresolved
obligation instead of inventing a successful resolution.

## Transport and consent

The configured consumer receives
`{Spectre.Server.GAM.Managed, owner, {:presentation, material}}`. Render the frozen
material with its controls, acknowledge rendering using
`Spectre.Server.presented(server, presentation_ref)`, and submit the user's
separate choice with `Spectre.Server.decide(server, skill_or_nil,
presentation_ref, :confirm | :reject)`.

Only the configured consumer can acknowledge or decide through the root Server.
The runtime validates the pending target before binding a private, one-use
decision proof to the presentation and stance. Calls to a restarting Skill
return a bounded error while the root remains responsive. An ack is not consent. A model label, an
ordinary process sending "confirm", or a stale card cannot create approval.
Scope handles and ingress credentials never enter the tool/model context.
`Spectre.Server.gam_view/1` is available only to the configured consumer or
independent reviewer; arbitrary processes cannot inspect the governance record.
The application must authenticate the human at its consumer boundary; a local
BEAM process identity alone does not establish a real-world human identity.

## Override only the behavior you need

The optional `handle_action/2` callback runs in the Server once during command
acquisition. Its portable result is frozen in the outbox, rather than evaluated
against new assigns on recovery:

```elixir
def handle_action(%{operation: operation, args: %{"to" => to}}, ctx)
    when operation == {:kinetic, :send_email} do
  if to == ctx.assigns[:observed_email],
    do: {:confirm, %{message: "Contact this address?", expires_in: 60_000}},
    else: {:reject, :recipient_not_observed}
end

def handle_action(action, ctx), do: super(action, ctx)
```

`super` retains the configured policy. An override cannot expand a mandate or
remove required confirmation. Extra `bind` material can freeze reviewed business
context for the presentation without allowing it to override normalized action
arguments or authenticated identity. This callback prepares data; it must not
execute the effect directly.

`handle_pending/3` controls conversation, topic changes and resume. Existing
`close_pending_after/4`, `route_current_input/2`, and OTP callbacks remain
available. Native application timers must retain schedule identity/revision.
Closing a pending conversation does not erase an uncertain outcome or Duty.

For a custom response vocabulary, configure a binding `interpreter: {Module,
:function}` and select the appropriate pending command in `handle_pending/3`.
Only a fresh reply from the configured consumer receives an input provenance
receipt; the configured interpreter must still recognize it before an approval
can be recorded. A model label alone supplies no receipt. Input receipts and
structured decisions are bound to their exact presentation. The input proof hashes
the actual text being interpreted: copying an earlier digest cannot authorize
changed text. Transport proofs are excluded from durable checkpoints.

Override callbacks receive capability-free `candidate_template`, or
`presentation_template` and `show_template`, through a sanitized context. Frozen
material and authority fields are checked again; custom wording cannot hide the
actual arguments. Default rendering escapes control/bidi characters and preserves
nested structure so payload text cannot impersonate another field.

## Registered execution

Installable packages may implement `effects/1` alongside `tools/1`. The helper
contract stays compatible: Kinetic prepares consolidated model output, while
governed helpers normalize to proposals. An effect registration explicitly
names its adapter, local operation, material, partition and effect semantics.
The installed registration digest is checked before execution. The framework
does not guess an arbitrary package function named `execute`.

Adapters implement `Spectre.Server.GAM.EffectAdapter` and return observed success
or classified failure/no-effect/ambiguity. The same Act reference supports
correlation, but does not supply exactly-once execution for an external service.
The adapter must truthfully describe whether a receipt proves acceptance,
delivery or some other milestone. Persisted provider errors retain a digest of
the details rather than raw provider payloads or credentials. Uncertain effects
are not blindly retried.

## Submit from another process

A trusted application actor can enter the same AgentServer path without writing
a flow callback:

```elixir
{:ok, server} = Spectre.Server.start_link(
  agent: MyApp.Agent,
  identity: %{subject: authenticated_user.id},
  consumer: ui_owner,
  submitters: [job_worker],
  gam: [
    storage: {:disk, "var/agents/" <> to_string(authenticated_user.id)},
    operations: %{{:kinetic, :send_email} => [confirm: true]}
  ]
)

# Run in the registered job_worker process, using a consolidated, validated draft.
Spectre.GAM.submit(server, {:kinetic, :send_email},
  %{"to" => draft.to, "body" => draft.body},
  on_result: :email_sent, key: "outreach:" <> draft.id)
```

The consumer and explicitly registered `submitters` may submit. The API accepts
only `on_result`, `confirmation` and optional `key` options, targets the root Server, and does
not expose a Scope or allow a caller to supply authority records. It applies the
same normalization, `handle_action/2`, allowlist, outbox, consent and GAM admission
as a callback's `propose` command. Skills receive work through their parent.

`{:ok, command_id}` means acquisition, not permission or successful delivery.
The existing Server receives the eventual result in `handle_result/3` under the
provided tag (default `:submission`). A busy Server returns `{:error, :busy}`
without acquisition; only that rejected attempt is safe to resubmit. An acquired
operation must not be blindly retried without a stable acquisition key.

An optional `key` is a nonempty string of at most 256 bytes. Repeating the same
key and request returns the original command ID; changed arguments or options
return `:submission_key_conflict`. Key and command are checkpointed atomically,
so disk recovery preserves this acquisition deduplication. Each Server retains
up to 4096 keys and refuses additional keyed submissions when full, rather than
evicting a key and silently executing again. This covers acquisition within the
configured storage lifetime, not exactly-once delivery by an external service.
The key namespace belongs to the AgentServer and is shared by its trusted
submitters, so cooperating workers can deduplicate the same job.
`external_submission` provenance is reserved runtime metadata; application
commands cannot inject it.

A submitter cannot approve on behalf of
the user: the configured consumer still renders and calls `presented/2` and
`decide/4` for the actual separate user choice.

## Revoke authority without deleting history

The root Server's configured consumer can call `Spectre.GAM.revoke(server)`.
Spectre submits revocation through the kernel's retained controller path. This
prevents later effects under that application mandate, and disk recovery preserves
the revocation. It does not cancel effects already committed or erase Acts,
Outcomes or unresolved Duties. A background submitter cannot revoke or enlarge
the application's authority.

## Review an unresolved Duty

Configure a separate reviewer only when the application has an authenticated
independent review role. Spectre builds the review Scope and bounded mandate in
the same Domain; the application does not construct these records:

```elixir
{:ok, server} = Spectre.Server.start_link(
  agent: MyApp.Agent,
  identity: %{subject: customer.id},
  consumer: chat_transport,
  gam: [
    storage: {:disk, "var/agents/" <> to_string(customer.id)},
    operations: %{{:kinetic, :send_email} => [confirm: true]},
    reviewer: [
      identity: %{subject: authenticated_reviewer.id},
      consumer: review_transport
    ]
  ]
)

# Called by review_transport after the actual independent review.
Spectre.GAM.resolve_duty(server, duty.ref, :ratify,
  supporting_refs: [cause_act.ref])
```

The reviewer may also specify `expires_at: absolute_utc_milliseconds` in its own
configuration. Its default is the supported year-9999 upper bound, independently
of the operation mandate's deadline. Thus operation authority can expire while an
independently authorized reviewer still disposes of historical Duties. A restart
does not extend either deadline, and changing review authority against an existing
disk history is rejected. The same closed identity schema applies to the reviewer.

The automatic reviewer is scoped to Duties causally attached to this Agent's
configured operation mandate, including its presentations. It does not acquire
authority over unrelated Duties from a separately configured low-level Domain.

Only the configured review consumer may call this API. The normal chat consumer,
Agent, Skills and external submitters do not gain review authority. The reviewer
must represent a different subject (or service task) and use a different consumer;
changing only conversation metadata cannot manufacture independence. The application
must authenticate the real reviewer and enforce organizational independence: a
different identifier or BEAM PID is not proof of that real-world property.

`supporting_refs` is a nonempty list of existing Evidence, Outcome or Act
references. `meter_resolution` defaults to `:none`; explicit supported values
are `:settle` and `:release`. Existing kernel disposition kinds are
`:condition_met`, `:ratify`, `:repudiate`, `:compensate`, `:assign` and
`:accept_loss`. Each request targets the exact current Duty opening and goes
through kernel authority, supporting-record and independence checks. Inspect
the returned Decision: submitting a well-formed request is not proof that the
Duty was closed.

Ratification records an authorized disposition; it does not prove the original
email was sent, overwrite an ambiguous Outcome, or authorize repeating the effect.
Without a reviewer configuration, Duties remain open and `resolve_duty` returns
`:reviewer_not_configured`. They are never silently assigned to the proposing
Agent or removed when its conversation ends.

The standalone `Spectre.GAM` kernel API remains available for integrations that
own a different runtime. It does not introduce a manual mode into AgentServer.
