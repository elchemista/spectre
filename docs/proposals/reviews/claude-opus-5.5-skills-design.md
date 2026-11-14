# Claude Opus 5.5 — Skill design

Read-only review of the 0.4 working tree. Findings describe the revision reviewed,
not necessarily the final implementation; see `skills-implementation-resolution.md`.

I made no edits. Bottom line: the plan holds up, but **three things must exist before skills can run in parallel**:

- **Narrowed authority.** Each skill child gets a host config containing only its own GAM bindings.
- **Idempotent dispatch.** The child must recognise an interaction the root already sent, so a re-send after a root restart is ignored.
- **The child never routes on its own.** It receives routing the root already did.

Everything else reuses `Runtime` as you proposed.

## P0: must fix in the design

**1. "No extra authority" isn't enforced today.**
- The bridge looks up a binding by operation name only (`lib/spectre/server/gam.ex:505`).
- `Catalog.validate` returns `:ok` when a proposal has no metadata (`lib/spectre/server/catalog.ex:39`), and a handler calling `propose(ctx, :op, args)` sends none.
- So a child holding the host's `gam:` config can propose any root operation.

**Fix:** when the root starts a child, give it `{Spectre.Server.GAM, Keyword.update!(cfg, :bindings, &Map.take(&1, allowed))}`. `allowed` comes from the mount's `bind:` map and requirements. `scope`, `store`, `lifecycle` and `consent_ttl_ms` stay the same, so it's the same Domain. `Tool.validate_governed_bindings!` (`tool.ex:332`) then refuses at startup any skill tool that names an operation the child wasn't given. That's the behaviour you want.

**2. Re-sending to a child replays effects.**
- `accept_input` creates a fresh UUID every time (`runtime.ex:386`).
- If the root crashes after the child accepted an interaction but before the root saved its checkpoint, the root sends it again. The child treats it as new: new Turn, new Candidate, new command id.
- Kernel deduplication by candidate identity won't catch this, because the evidence differs.

**Fix:** dispatch with an interaction id chosen by the root. The child rejects it if that id is already in `seen_events`, `current`, `queue` or `history`. On the root side the dispatch should be an outbox entry, like other commands.

**3. There is no "routing limited to a mount".**
- `Router.candidate_rules` loads every rule (`router/router.ex:145`). `current_scope` only changes the order (`:153`).
- `PreRoute.interrupt` also sees every global rule (`pre_route.ex:6`).
- A child routing by itself would pick root flows and hit the default `handle_flow`, which raises (`server.ex:52`). That gets quarantined.

**Fix:** the root routes once. Its existing route-result handler (`runtime.ex:563-580`) already covers normal routes, interrupts (`dispatch_interrupt`) and `route_current_input`. When `routing.route.scope == {:skill, id}` and that mount has a `server:`, the root enqueues a dispatch and finishes instead of calling its own `handle_flow`. The child enters at the same handler with the routing already done.

For follow-up input sent with `skill:`, the child only needs its pending path (`after_interrupt`, `runtime.ex:446`). Its no-pending fallback should use a mount-filtered router passed through `services: [router: …]` (`runtime.ex:472`). That avoids changing the core router.

## P1: identity, checkpoint, ordering

**4. The child must keep `agent: Host`, not the Skill module.**
- Checkpoint validation requires `agent`, `server` and `identity` to match (`checkpoint.ex:668-674`).
- Route restore matches dispatch keys against `Definition.rules(state.agent)`, and the scoped keys `{{{:skill,id},flow},label}` exist only in the host's rules (`checkpoint.ex:351`). With `agent: Skill`, restore fails.
- `Catalog.origin` compares `route.owner` and `route.scope` (`catalog.ex:52`), so it would also break.
- Reusable skills shouldn't hard-code the `as:` mount id. Strip the mount prefix only when calling `handle_flow`/`handle_result`, and keep the full routing in the event.

**5. Identity and naming.**
- Keep `identity` identical to the host's. The host's `scope:` resolver receives it, and adding fields may change which scope it resolves.
- Pass the mount through a new `mount:` field in `service_context` instead.
- Don't pass `subject:` to a child. `start_subject_owner` would collide on the same Registry key (`server.ex:112`).
- Checkpoint key: `host_key <> ":skill:" <> mount_id`, with one long-lived child per mount, not per request. Per-request children leave orphaned outboxes waiting for reconciliation.

**6. Sequence numbers clash between runtimes.**
- `event_sequence` comes from each runtime's own counter (`runtime.ex:394`) and is sent to GAM ingress (`gam.ex:485`).
- Consent freshness checks `sequence > shown_at_sequence` (`runtime.ex:1120`).
- The child should take the root's `received_at` and root-assigned sequence, and move its own counter forward to match. It should not mint a sequence for forwarded input.

**7. Scope when there is no event.**
- In `handle_info`, `init` and `handle_cast`, `context(state, nil)` gives empty routing (`runtime.ex:888`), so `Tool.prepare` (`tool.ex:219`) and `Catalog.origin` treat the call as `:agent` scope.
- That is harmless once item 1 narrows the bindings. Still, `Catalog.origin` should fall back to the child's mount for `scope` and `owner` when the route is nil. Otherwise scoped metadata from a timer fails with `:proposal_origin_mismatch`.

**8. Untargeted "yes" with more than one waiting consent.**
- `validate_input_options` currently rejects every option (`runtime.ex:423`), so `skill:` has to be allowed there.
- Rule for untargeted input: forward it to a child only if exactly one foreground pending exists across the whole tree. If the root has one, keep the current behaviour. If there are several, the root asks the user which one.
- Never send it to a child "by default".

## P2: supervision and relaying results

**9. Use a per-session Supervisor, not links from inside `Runtime.init`.**
- With a plain link, a crash-looping child takes the root down.
- Instead, use one Supervisor per session containing `[root, skill…]`, with `:one_for_one` and named via a Registry key `{agent, subject, mount}`. Stopping the supervisor ends the whole tree.
- Background tasks run under the global `Spectre.Server.TaskSupervisor` (`runtime.ex:1414`), and governed workers are deliberately not killed (`runtime.ex:276`). A restarted child therefore relies on outbox recovery. That calls `recover_command`, which re-submits the saved effect (`gam.ex:236`) and shows the presentation again (`gam.ex:240`).
- So "a restart doesn't resend effects" depends on the kernel deduplicating by candidate identity. That's existing behaviour, but it needs a test with a child.

**10. Relaying results to the root.**
- `notify` sends `{Spectre.Server, self(), event}` to `consumer` (`runtime.ex:2703`). A raw child pid can't be mapped back to a mount.
- Option: set the child's `consumer` to the root, and add a reserved `handle_info` clause in Runtime ahead of the app fallthrough (`runtime.ex:268`). The root tags each event with `{mount, interaction}` and passes it to the chat.
- Results a root helper waits for should arrive through `Server.deliver` with id `"skill:#{mount}:#{child_command_id}"`. `deliver` is idempotent through `seen_events` and requires a checkpoint (`runtime.ex:153-157`). A plain message is lost if the root restarts.
- Skill replies won't appear in the root's history or memory unless the root adds them to its turn.

**11. Docs:** `skill.ex:5-8` says skills "do not create sessions", which this change makes untrue.

## Tests to add
1. A child proposing a root-only operation gets `{:unbound_governed_operation, op}`, including from `handle_info`.
2. Same root interaction id sent twice, including across a root restart → one child interaction, one proposal.
3. Root and child each propose at the same time in one Domain → both get admitted Acts, Domain order is recorded, and each pending stays in its own runtime.
4. Two foreground consents and an untargeted "yes" → disambiguation and no confirm. With `skill: :research` → only that pending is confirmed.
5. A child consent expires while the root is busy → the lifecycle close is recorded in the child, and the root is unaffected.
6. Kill a child after `execution_started: true` → it restarts, there is a single Act, and the outbox is reconciled.
7. Child checkpoint round trip with a scoped route key (restore through the host's rules).
8. Stopping the session supervisor terminates every child. A child crash loop doesn't restart the root.
9. A skill-scoped route never calls the root's `handle_flow`, including through interrupt and `route_current_input(suspend:)`.
10. A child with a mount-filtered router never selects a root rule.

Not verified: whether `ToolCompiler.snapshot!` resolves Stack installations for a skill's server module the way it does for an agent's. Check that before relying on skill tools.
