# AgentServer and GAM diagnostics

The runtime owns coordination and automatic GAM integration. GAM remains the
authority for admission, Acts, Outcomes and Duties; storage adapters persist
their records. Lab reads and presents these sources. It creates no second
ledger, permission system or workflow engine.

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
follow verified durable append and recovery repair. The ephemeral Domain
notification process group holds no records or authority; subscriber failure cannot
change admission or commit. The automatic integration coalesces GAM revision
hints over 50ms. Consumers should also coalesce checkpoint/Skill hints before
refreshing, subscribe before the initial read, and resubscribe after a Server
restart. Notifications are not a durable event stream. Always recover current
state by reading; a revision hint is not evidence of an action's success.

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

Checkpoint and GAM reads are separate snapshots and carry separate revisions;
they are not a cross-store atomic snapshot. GAM output is bounded, but projection
and correlation still scan retained Scope history inside the Domain. This release
does not claim indexed constant-time history queries, complete historical
routing, reasoning visibility, or a new retention guarantee. Existing Scope
visibility and erasure rules apply before redaction and pagination.
