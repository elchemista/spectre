# SkillServer implementation and review resolution

Scope: Spectre 0.4 on `feature/agent-server-gam`. The cancelled Phoenix demo was
not resumed. The GAM kernel's laws and admission machinery were not redesigned.

Claude Opus 5.5 reviewed both the design and implementation using read-only file
tools. The original reports are [design](claude-opus-5.5-skills-design.md) and
[implementation](claude-opus-5.5-skills-review.md). They refer to intermediate
revisions; the following records their disposition.

| Finding | Resolution |
| --- | --- |
| Root-only bindings reachable from Skill callbacks | Mount `governed:` allowlist, logical `bind:` resolution, runtime acquisition check and bridge admission check; missing permission returns an error before an Act. |
| Delegation replay after owner loss | Durable parent outbox, stable child invocation identity, bounded child dedup; mark dispatch started before sending and report uncertainty on recovery. |
| Router inbox could recreate a dispatch | Additional root-loss test exposed this crash window; routing-result acquisition and delegate outbox creation are now saved together. |
| Child could select another scope | Filter candidate rules by runtime scope, preserve root routing decisions and skip root pre-route turn handlers in children. |
| Unrelated Server messages swallowed | Unrecognized senders still reach application `handle_info`. |
| Streaming wrote root checkpoints and lost dead-child closure | Runtime-owned child registration/cache retains bounded sender history. Preview/end go directly to the consumer. Transport guard monitors the runtime and worker. |
| Targeted input blocked the root | The public caller resolves the Skill and calls it; the root only supplies its cached child reference. |
| Child dispatch timed out after five seconds | Internal admission call uses infinity; the parent worker deadline governs uncertainty. |
| Nil-event callbacks lost Skill origin | `ctx.skill`, service context and synthetic route carry mount identity even in native OTP callbacks. |
| Shared Domain drift | Standard bridge pins Domain at startup and checks every resolved scope against it. |
| Missing causal attribution in the ledger | Authenticated Skill invocation Evidence must be included in the Candidate; arbitrary user Evidence cannot substitute for it. |
| Nonportable delegation could crash checkpoint acquisition | Validate input before accepting callback commands. |
| Startup and termination errors | Structured `skills_start_failed` startup result; supervisor-stop races handled. |
| Repeated background error handlers suppressed | Failures without interaction ids are counted by their own failure identity. |
| Recovery could use another mount's journal | Journal recovery checks mount id and module in addition to authenticated Domain/scope/principal. |
| Routed Skill context lost recalled memory | Preserve memory and original reception time during root-to-Skill handoff. |

Confirmation controls can additionally pin `{pending_id, presentation_revision}`;
stale or cross-Skill targets cannot resolve a different proposal.

Tests cover concurrent Skill workers, root responsiveness, exact mounted routing,
GAM consent isolation, delegated input not being user approval, host-only
attribution, allowed operations in native callbacks, timer closure, child crash
after an effect, parent loss during unacknowledged dispatch, live stream teardown,
unrelated actor messages and portability rejection. The existing nine-package
integration now also executes the full outreach workflow inside a Skill.

Explicit contracts retained: live output is not an exactly-once durable delivery
channel; cancellation of the root does not cancel child work or reverse admitted
effects; the host owns Domain lifetime and authentication; legacy Instance Skill
snapshots and dynamic definition activation are not automatically migrated.

## Final validation

Validated locally on 2026-11-13:

- `mix test --max-cases 8`: 4,397 passed (1 doctest, 25 properties and 4,371 tests),
  1 excluded by the suite configuration, no failures.
- Focused Skill and tool runtime/compiler tests: 54 passed, including 19 new
  Skill runtime and shared-GAM tests.
- `integration/stack_tools` suite: 4 passed using the nine installed libraries,
  including the outreach workflow inside a Skill with governed confirmation.
- `mix compile --warnings-as-errors`, `mix format --check-formatted` and
  `git diff --check`: passed.
- `mix credo`: no issues. `mix dialyzer`: zero errors.
- `mix docs`: HTML, Markdown and EPUB generated successfully.

Two unrelated timing hazards exposed during the full run were stabilized: the
compiler-warning capture test runs synchronously to avoid capturing another
test's stderr, and the tool callback assertion allows normal scheduler delay.
The registry lifecycle test now synchronizes with the restarted owner's state
before inspecting its ETS table. These changes retain the original assertions.

## Review availability

A third, focused Opus 5.5 pass was attempted after applying the fixes. It did not
deliver a review: the CLI reported its five-hour usage limit, resetting at 22:30
Europe/Rome. No post-fix Opus approval is claimed. The two complete reports above
remain available; post-fix validation is by executable tests and static checks.
