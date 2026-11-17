# AgentServer and GAM diagnostics

The runtime owns coordination and automatic GAM integration. GAM remains the
authority for admission, Acts, Outcomes and Duties; storage adapters persist
their records. Lab reads and presents these sources. It creates no second
ledger, permission system or workflow engine.

## Compiled contracts and routing destinations

```sh
mix spectre.doctor --agent MyApp.SupportAgent --strict
mix spectre.routes MyApp.SupportAgent --json
```

Doctor checks the required callbacks of the declared root and mounted Skill
Servers without starting them or invoking their callbacks. The routing JSON names
each Skill's bound Server, falling back to the root when the Skill inherits it.
These checks inspect compiled contracts; live GAM state and backend availability
use the authorized runtime inspector below and application integration tests.

## Application inspector

Call these APIs from the process configured as the root Server's `consumer:`:

```elixir
:ok = Spectre.Server.subscribe(server)
{:ok, root} = Spectre.Server.inspect(server, limit: 50)
{:ok, research} = Spectre.Server.inspect(server, skill: :research, limit: 50)
{:ok, page} = Spectre.Server.gam_inspect(server, limit: 50)
{:ok, trace} = Spectre.Server.trace(server, interaction_id, skill: :research)

# Read additional records from the same revision.
{:ok, next} = Spectre.Server.gam_inspect(server, cursor: page.next_cursor)
```

Read the next page only when `next_cursor` is non-nil. A cursor belongs to one
Scope, revision and interaction filter. `{:error, :stale_cursor}` means the
Domain advanced: clear accumulated pages and restart. Other cursor/filter
mismatches return `:invalid_cursor`. Lists default to 50 entries, maximum 100.
GAM pages report total counts and stable record references; action arguments,
prompts, credential handles, rendered consent and raw Evidence are excluded.
Operational snapshots exclude inputs, assigns and result/error payloads. Logical
names and correlation references are visible: applications must not use secrets
as identifiers. These views are developer diagnostics, not public web responses.

The root forwards a mounted Skill checkpoint read through the parent/child
consumer boundary. A direct call from an unrelated process fails with
`:untrusted_audit_transport`. A Skill has no access to the root's detailed GAM
view. These are trusted OTP process boundaries, not a sandbox against arbitrary
code running inside the BEAM.

After authenticating the caller, the managed integration performs GAM inspection
and the retained `gam_view/1` API in monitored read workers. At most four reads
run concurrently per managed integration. Each Domain query has a 3.5-second
timeout and an independent 4-second worker deadline, shorter than the public
call timeout. A slow or unavailable Domain returns
`{:error, :diagnostic_source_unavailable}`; it does not terminate Managed or
occupy its mailbox while governed workers check out. Read workers never enter
the governed-work drain and are stopped when their owner terminates. The
authenticated Scope remains private to framework code.

## Incremental refresh

After subscribing, the consumer receives invalidations:

```elixir
{Spectre.Server, server,
 {:diagnostics_changed, %{source: :gam, revision: revision}}}

{Spectre.Server, server,
 {:skill, :research,
  {:diagnostics_changed, %{source: :checkpoint, revision: revision}}}}
```

Checkpoint notifications follow a successful store commit. GAM notifications
follow verified durable append, including batches committed before a subsequent
recovery-repair error. These are commit hints, not successful command completion.
The ephemeral Domain
notification process group holds no records or authority; subscriber failure cannot
change admission or commit. The automatic integration coalesces GAM revision
hints over 50ms. Consumers should also coalesce checkpoint/Skill hints before
refreshing, subscribe before the initial read, and resubscribe after a Server
restart. Notifications are not a durable event stream. Always recover current
state by reading; a revision hint is not evidence of an action's success.

`subscribe/1` acknowledges an accepted subscription intent even if the disposable
notification process is temporarily absent. Checkpoint notifications stay
enabled while the managed integration retries joining the process group with
one 100ms retry timer. Once joined, it refreshes the current revision. GAM hints
are coalesced monotonically. Skill subscriptions use a private authenticated
parent message, processed after initialization; slow or restarting Skill
initialization does not block the root or lose its subscription. These messages
are handled by the runtime and never routed to application callbacks.

## Lab: tool versus developer facade

The existing helper stays compatible:

```elixir
lab(ctx, {:inspect, :checkpoint}, on_result: :summary)
lab(ctx, {:inspect, :checkpoint, :operational}, on_result: :diagnostics)
lab(ctx, {:inspect, :interaction, interaction_id}, on_result: :trace)
```

The helper sees only its runtime-owned checkpoint reference. The operational
view includes bounded pending/command summaries, counts and recovery metadata.
It does not expose another Skill, the GAM Scope or a full audit trail.

For a developer inspector, `Spectre.Lab.inspect(server, :operational, opts)` and
`Spectre.Lab.trace(server, interaction_id, opts)` forward to the Server in the
same caller process, preserving authorization. There is no identity-escalating
worker or automatic publication of these records to a model.

## Trace coverage and cost

Every trace explicitly reports its source, truncation and missing coverage.
Checkpoint facts are retained command/outbox/inbox/dead-letter state, not an
append-only timeline. GAM correlation follows recorded invocation Evidence,
command IDs and references between Decisions, Acts, presentations, attempts and
Outcomes. Lifecycle summaries show registered transitions and atom reason codes.
No chronology is invented for missing or pruned commands. A route's strategy is
unknown when it was not retained. An empty trace does not prove nothing happened.

Public AgentServers always use managed GAM. Internal/custom-adapter runtimes can
still expose a retained checkpoint trace: `gam` is `nil` and
`coverage.gam` is `%{available: false, reason: :managed_gam_not_configured}`.
This does not imply the custom adapter has no governed history; that history is
outside this diagnostic source. A configured managed source that fails still
returns an explicit diagnostic error. Operational checkpoint inspection rejects
`:cursor`; cursors paginate GAM pages only.

Checkpoint and GAM reads are separate snapshots and carry separate revisions;
they are not a cross-store atomic snapshot. GAM output is bounded, but projection
and correlation still scan retained Scope history inside the Domain. This release
does not claim indexed constant-time history queries, complete historical
routing, reasoning visibility, or a new retention guarantee. Existing Scope
visibility and erasure rules apply before redaction and pagination.
