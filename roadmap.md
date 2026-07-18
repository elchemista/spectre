# Spectre next-run roadmap

Status: ready for the next hardening pass

Baseline: Skills and scoped prompt injection implemented on
`feature/skills-and-inject`

Verification baseline: 253 tests, warnings-as-errors compilation, strict
Credo, and Dialyzer all pass locally

This file is the short execution plan for the next development run. The
long-term architecture remains documented in `docs/ROADMAP.md`; the completed
Skills and prompt-injection design is recorded in `plan.md`.

## Goal

Make extension callbacks and prompt transport as robust as the existing
effect, policy, provider, and state boundaries without adding more DSL
concepts.

The next run should improve failure containment, preserve typed prompt data at
the adapter boundary, and make Skill ownership harder to lose accidentally.

## P0: unify callback failure boundaries

`run` callbacks now normalize raises and exits, but application extension
points still have different timeout and failure behavior. A hung callback can
still block a Session.

1. Inventory every callback executed in the turn process:
   - `run` handlers;
   - deterministic reply renderers;
   - action lifecycle hooks;
   - prompt conditions and context providers;
   - input pipeline callbacks;
   - memory, state, journal, model, classifier, embedding, and action adapters.
2. Write a callback contract matrix containing:
   - supported arities;
   - return shapes;
   - timeout option and default;
   - exception, exit, throw, crash, and malformed-reply behavior;
   - whether failure aborts, degrades, or becomes a terminal effect.
3. Introduce one reusable execution boundary, or deliberately extend
   `Spectre.Provider.Call`, instead of adding local `try/rescue` blocks.
4. Add bounded options such as `run_timeout`, `renderer_timeout`, and
   `hook_timeout`, with `:infinity` available only as an explicit override.
5. Keep normalized failures privacy-safe: no prompt content, callback result,
   secret arguments, stack trace, or arbitrary exception message in journals
   and logs.

Required tests:

- success and every supported callback arity;
- declared `{:error, reason}`;
- raise, exit, throw, hard crash, timeout, and malformed reply;
- timed-out worker termination;
- caller-death cancellation;
- Session remains alive and handles a later healthy turn;
- no callback is retried implicitly.

## P0: preserve prompt structure at the model boundary

`Spectre.Prompt.Plan` keeps instructions, context, and task fragments typed,
but the current LLM contract flattens them into one string. Structural trust is
therefore enforceable inside Spectre but only advisory once text reaches a
model.

1. Define an adapter capability for structured messages or typed prompt plans.
2. Keep the existing string adapter fully backward compatible.
3. Serialize untrusted context with an explicit data boundary when using the
   legacy string adapter.
4. Keep policy request prompts immutable against application task replacement.
5. Never expose injected instructions or dynamic context through deterministic
   replies, monitor fallbacks, metadata, logs, or journals.
6. Document the exact guarantee: Spectre prevents privilege promotion and
   policy bypass; it does not claim that a model is immune to semantic
   jailbreaks.

Required tests:

- no-injection string output remains byte-for-byte compatible;
- structured adapters receive separate instruction, context, and task data;
- hostile provider text remains context data;
- forged runtime operations cannot alter trust or destination;
- policy prompts survive replacement at every scope;
- prompt hashes and redacted metadata are stable across adapter forms;
- deterministic reply and fallback paths never call a model.

## P1: make ownership and scope first-class

Effect scope currently lives in the payload for compatibility. This works, but
it is easy for a new staging path to omit it.

1. Decide whether `owner` and `scope` belong as first-class `Effect` fields.
2. If they move, add an explicit state schema migration and retain decoding of
   existing payload-scoped effects.
3. Centralize effect creation so DSL and model-planned actions cannot diverge.
4. Verify scope through routing, result, state codec, policy resolution,
   execution, hooks, journal records, and semantic learning.
5. Reject ambiguous label-only Skill classification with an observable reason,
   not just an empty candidate set.

Required tests:

- two Skills bind the same concrete action and retain independent policy,
  mode, hook, owner, and scope;
- Agent-owned actions cannot inherit Skill protections;
- scope survives encode/decode and Session restart;
- legacy effects without scope fail conservatively;
- classifier, cache, and LLM results cannot guess between scoped duplicates.

## P1: reference Agent and public documentation

Build one small but complete reference application demonstrating:

- an Agent composed from two Skills;
- `ask`, `reply`, both `run` arities, and actions;
- Agent, Skill, Flow, handler, and runtime injections;
- a protected write action with acceptance and rejection;
- provider, model, callback, and action failures;
- Session recovery and state restoration;
- privacy-safe prompt-plan and routing metadata.

Update `README.md`, `docs/GETTING_STARTED.md`, `docs/DSL.md`,
`docs/ACTIONS.md`, and `docs/PROVIDERS.md` from that example. Public examples
must use only supported Skill v1 behavior.

## P1: continuous verification

1. Add CI for the supported Elixir and OTP matrix.
2. Run formatting, warnings-as-errors compilation, all tests, strict Credo,
   and Dialyzer in CI.
3. Add deterministic routing evaluation fixtures to CI.
4. Add concurrent Session stress tests covering provider timeouts, policy
   resolution, state CAS, and action completion.
5. Record test duration and identify the slowest integration groups before
   introducing broader load benchmarks.

## P2: deferred design work

Do not begin these items until the P0 boundaries are complete:

- hierarchical or local Skill routers;
- per-Skill classifier configuration;
- per-Skill memory namespaces or adapters;
- nested Skills;
- package extraction and reusable external Skill packages;
- automatic retries, circuit breakers, or rate-limit policy in core;
- pricing, token accounting, or a metrics exporter.

## Non-goals

The next run must not add:

- a fifth handler type;
- autonomous loops, missions, steps, or workflow orchestration;
- direct action execution from prompts or Skills;
- unscoped prompt replacement;
- model-based policy approval;
- silent fallback from an invalid scoped route to the first matching label.

## Suggested execution order

1. Re-run the 253-test baseline and inspect the current diff/branch state.
2. Build the callback contract matrix and add failing Session-level tests.
3. Implement the common callback boundary and make those tests pass.
4. Freeze the structured prompt-adapter contract with compatibility tests.
5. Implement one structured adapter path and harden legacy serialization.
6. Decide and document the first-class scope migration before changing state
   schema.
7. Build the reference Agent and update public documentation.
8. Add CI and concurrent Session coverage.
9. Run every local gate and update this roadmap with results and remaining
   risks.

## Definition of done for the next run

- Every in-process application callback has a documented, tested failure and
  timeout contract.
- A hung or crashing callback cannot kill or indefinitely block a Session.
- Structured model adapters receive typed prompt sections without flattening.
- Legacy string adapters and Agents without injections remain compatible.
- Skill owner and scope survive every runtime and persistence boundary.
- The reference Agent demonstrates both healthy and failing end-to-end paths.
- CI runs the supported version matrix and every required quality gate.
- Format, warnings-as-errors compilation, full tests, strict Credo, and
  Dialyzer pass with zero ignored findings.
