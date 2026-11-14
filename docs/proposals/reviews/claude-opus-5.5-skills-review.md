# Claude Opus 5.5 — Skill review

Read-only review of the 0.4 working tree. Findings describe the revision reviewed,
not necessarily the final implementation; see `skills-implementation-resolution.md`.

I made no edits. I found no P0: no authority escape and no double effect. There are two P1 bugs and one P1 mismatch between the code and the design you stated, plus several P2s. Each has an exact fix below.

## P1

**1. Every Server now silently drops `{Spectre.Server, pid, event}` messages it didn't send itself.**
- `runtime.ex:298-307` returns `{:noreply, state}` when `Skills.identify` gives `:error`.
- This applies to all runtimes, including agents without skills and the skill children themselves (their supervisor is nil, so `identify(nil, _)` is `:error`).
- Before this change, those messages reached the app's `handle_info`. An app whose Server consumes another Server's events loses them with no error.
- **Fix:** change the fallback to `:error -> delegate_otp(:handle_info, [message], state)`. Item 3 covers why dead-child messages must be caught before this fallback.

**2. The "started delegation returns `skill_unknown`" branch can never run.**
- `mark_execution_started` (`runtime.ex:2132-2140`) only marks governed commands and `Tool.never?` tool calls. `:delegate` and `:delegate_route` entries keep `execution_started: false`.
- So during recovery, `replayable_entry?` (`:2547`) matches first and replays the entry. The `:delegate` clause at `:2475-2483` is unreachable.
- What actually happens is replay plus child dedup on `"skill:" <> id`. That's safe today, but it depends only on the bounded `seen_events` window (`max_seen_events`, which the child inherits from the root).
- **Fix (matches your design):** add `or entry.command.kind in [:delegate, :delegate_route]` to the `mark_execution_started` condition. If you decide replay is what you want, delete the dead clause and document replay instead. Either way, no test covers this path.

**3. The root writes a checkpoint and runs `handle_skill` for every streaming chunk, and a crashed skill's stream never closes.**
- `Stream` (`stream.ex:206`) and `TransportGuard` (`transport_guard.ex:38-41`) send `{Spectre.Server, child_runtime_pid, {:preview…}}` to the child's consumer, which is the root.
- For each chunk the root:
  - makes a synchronous `Supervisor.which_children` call;
  - runs the full `conversation(:handle_skill, …, nil)`;
  - writes a checkpoint through `commit_acquisition` → `Checkpoint.save`.
- `TransportGuard` sends `:preview_end` *after* the child is DOWN. `identify` can't find the dead pid, so that message is always dropped and the consumer's stream stays open.
- **Fix:**
  - Relay `{:preview, …}` and `{:preview_end, …}` with `notify` only, skipping `handle_skill`.
  - Resolve senders from a root-owned `skill_pids` map (pid → mount id). Fill it from `which_children` when an unknown pid appears, keep dead pids in a bounded map rather than deleting them, and stop calling the supervisor on every message.

## P2

4. **The allowlist is only checked when a command is created.**
   - `Skills.authorize` runs in `prepare_acquisition_commands`. Recovered outbox `:propose` entries with `execution_started: false` replay through `run_command(:propose)` without a fresh check, so narrowing `governed:` in a deploy doesn't stop proposals already queued.
   - **Fix:** also enforce in `Spectre.Server.GAM.propose`, using `context.skill` (built from `state.opts`, not from the user's ctx): `operation in context.skill.governed or {:error, {:skill_operation_not_allowed, op}}`.
   - The mount's `governed:` option is never validated at compile time. A misspelled key falls back to the `bind:` values without any warning, and a non-list raises inside `Skills.init`. Validate it in `validate_mounts`.

5. **A targeted input blocks the root.**
   - `handle_call({:input, v, [skill: id]})` (`runtime.ex:155`) makes a 5s `GenServer.call` to the child from inside the root.
   - If the child is busy in a callback (your crash test's `handle_result` does `receive :release`), the root stops responding for up to 5s.
   - **Fix:** have the root reply `{:ok, pid}` from the lookup and send the input from the caller in `Server.input/3`, or reply asynchronously with `GenServer.reply` from a task.

6. **The 5s call in `Skills.dispatch` gives false `skill_unknown` results.**
   - The child runs `handle_flow` synchronously inside the `:skill_input` call. If that takes longer than the default 5s, the root reports `skill_unknown` even though the child accepted the input.
   - **Fix:** use `:infinity` for the call and let the worker timer (`opts[:timeout]` / `worker_timeout`) decide.

7. **The root agent's turn handlers run inside skills.**
   - `prepared_input(%{delegated: true})` → `route` → `PreRoute.handle` applies the agent config's `turn_handlers` in the child.
   - Interrupts are filtered by `runtime_scope`; turn handlers are not. A root canned reply can therefore answer delegated or targeted skill input before the skill's flows see it.
   - **Fix:** skip `PreRoute.handle` when `opts[:skill]` is set.

8. **Skill startup failures crash the root without a clear reason.**
   - `{:ok, gam} = pin_domain(...)` and `{:ok, sup} = Skills.start_link(...)` (`runtime.ex:46-48`) raise a MatchError. A scope resolver that needs input, or a corrupt skill checkpoint, stops the root from starting at all.
   - At runtime, a crash-looping child exceeds the supervisor's restart limit. The supervisor exits `:shutdown`, and the root, which doesn't trap exits, dies without running `terminate` and without notifying the consumer. A `:transient` root won't be restarted.
   - **Fix:** return `{:stop, {:skills_start_failed, reason}}`. Also document or configure the restart limit (`max_restarts`) in `Supervisor.init`.

9. **A non-portable `delegate` input crashes the root.** `validate_args(:delegate, …)` (`command.ex:79`) doesn't check that the input can be checkpointed. `Checkpoint.save` in `commit_acquisition` then raises outside `Failure.capture`. **Fix:** call `Skills.validate_input/1` in `validate_args`.

10. **The root's `on_callback_error` handler fires only for the first `handle_skill` failure.** `handle_skill` failures are quarantined with interaction `nil`. `callback_error_handler` counts dead letters by interaction, so every failure after the first finds more than one attempt and skips the handler. **Fix:** count by `failure.id` when the interaction is nil.

11. **Smaller items:**
    - `Server.cancel(root)` kills the delegate worker and deletes its outbox entry, but the child keeps going. Its output still arrives through `handle_skill`. Document this.
    - In `terminate`, `Process.alive?` followed by `Supervisor.stop` is a race; wrap the stop in `catch :exit`.
    - Routed (`skill_dispatch`) events skip memory recall in the child, while helper and targeted inputs get it.
    - `recover_command` doesn't compare the journaled `saved.skill` with `context.skill`. Command ids are unique, so this is defence in depth only.

## Checked and correct
- The Domain is pinned once, and narrower scopes in the same domain pass the check (`gam.ex:550`).
- Invocation Evidence goes through the fixed ingress and is checked against domain, scope and principal; the candidate must cite it (`invocation_basis`).
- Delegated input can't confirm a consent (`confirmation_event?`), and an untargeted "yes" stays with the root.
- Checkpoint keys are separate per mount, scoped routes restore through the host agent's rules, and `local_key` gives skills their local callback keys.
- Child dedup is persisted before the child replies, and before any side effect, because `commit_acquisition` saves first.
- Killing the root ends the subtree.

## Tests to add
- Another Server sending `{Spectre.Server, pid, ev}` to a root reaches `handle_info`.
- Root crash between saving the `delegate_route` entry and getting its result. This pins whichever recovery behaviour you choose in item 2.
- A skill that streams: the root does no checkpoint write per chunk, and killing the child mid-stream still delivers `{:skill, id, {:preview_end, …}}`.
- A recovered queued `:propose` after narrowing `governed:` is rejected.
- A child blocked in a callback doesn't block `Server.status(root)` or a targeted input to a sibling skill.
- A root `turn_handlers` reply never answers delegated skill input.
