# Spectre refactoring plan: Skills and prompt injection

Status: core implementation complete on `feature/skills-and-inject`  
Scope: production hardening, modular Skills, and structured `inject` support  
Explicitly deferred: CI setup and ExDoc work

Verification: `mix format --check-formatted`, 253 tests, Credo strict (no
warnings/errors), and Dialyzer (zero errors) pass locally. Optional scoped
router/classifier/memory work (Phase 6), package extraction/load profiling
(P2), and the two compatibility-sensitive P1 follow-ups called out below are
not part of this delivery.

## 1. Outcome

Spectre should gain two compositional concepts without becoming a workflow
engine:

1. A **Skill** is a scoped behavior module that keeps the main Agent small. It
   groups existing flows, routes, prompts, handlers, and optional local
   configuration. It does not add a new execution primitive.
2. **`inject`** composes prompt fragments at Agent, Skill, Flow, handler, or
   runtime scope. Prompt fragments have a typed destination and a deterministic
   position: `:start`, `:end`, or scoped `:replace`.

The existing handler vocabulary remains complete:

```text
ask     -> render a prompt and call the model
reply   -> return a deterministic response
run     -> call ordinary Elixir behavior
action  -> stage a side effect through Spectre's effect and policy boundary
```

Skills organize those primitives. They do not introduce `step`, `mission`, an
autonomous loop, direct tool execution, or hidden state.

## 2. Decisions already made

### 2.1 Skill means behavior capsule

A Skill is primarily a code-organization and reuse boundary, similar to a
routing scope or mounted feature module.

A Skill may own:

- flows and routing rules;
- handler functions used by `run`;
- a prompt root and prompt assets;
- prompt injections;
- policies and protections local to its namespace;
- optional router/classifier configuration;
- an optional memory namespace;
- declarations of logical actions required by a reusable Skill.

The outer Agent continues to own:

- the conversation state adapter;
- the action adapter and actual side-effect authority;
- the default model, memory, router, and classifier infrastructure;
- global policies and protections;
- the input pipeline, journal, lifecycle, and session configuration.

There is no new active-Skill state machine in the first implementation. Normal
flows and Spectre state continue to provide conversational continuity.

### 2.2 Existing handlers remain unchanged

Mounted Skill rules still compile to normal `ask`, `reply`, `run`, and `action`
handlers. A Skill is not a fifth public handler type.

The runtime only needs to know which module and scope own the selected rule:

- `run` calls the selected rule's owner module;
- `ask` and `reply` resolve prompt assets from the owner's prompt root;
- `action` is translated through the mount's logical action bindings and then
  uses the outer Agent action adapter;
- policies are resolved in the rule/action scope;
- results and routing receipts retain the owner and scope for observability.

### 2.3 Prebuilt Skills use logical requirements

A reusable Skill must not ship authority to execute application modules. It
declares logical requirements, and the Agent binds them to actual actions:

```elixir
skill SpectreSkills.Research,
  as: :research,
  bind: [
    search: :web_search,
    fetch: :fetch_page,
    publish: :publish_report
  ]
```

The outer Agent remains responsible for protections:

```elixir
protect :publish_report, with: :confirm_publish
```

A Skill may declare that `:publish` is a write or destructive capability, but
it cannot weaken an Agent protection or invoke the binding directly.

### 2.4 Prompt injection is typed composition

`inject` must not be implemented as arbitrary string concatenation. Every
injection has:

- a source;
- an owning scope;
- a destination;
- a position;
- optional conditions;
- required/optional failure behavior;
- observable, redacted metadata.

Supported destinations in the first version:

```elixir
into: :instructions
into: :context
into: :task
```

Supported positions:

```elixir
position: :start
position: :end
position: :replace
```

The default position is `:end`. The destination should be explicit in the
public DSL.

### 2.5 Replacement is scoped

`:replace` replaces the inner content of the selected destination at the
current scope. It never silently deletes protected runtime layers or outer
Agent layers.

Prompt scopes form nested envelopes:

```text
protected runtime layers
  agent.start
    skill.start
      flow.start
        handler.start
          base ask prompt
        handler.end
      flow.end
    skill.end
  agent.end
```

For a destination and scope, resolution is conceptually:

```text
start fragments ++ (active replacement || inner content) ++ end fragments
```

Consequences:

- handler replacement changes the handler's base task;
- flow replacement changes that flow's inner content but preserves Skill and
  Agent envelopes;
- Skill replacement changes the Skill's inner content but preserves the outer
  Agent envelope;
- Agent replacement may replace application-owned content but not protected
  Spectre/runtime layers;
- there is no unscoped `replace_all` operation.

Only one replacement may be active for a destination within one scope. An
unconditional duplicate is a compile-time error. If multiple conditional
replacements match at runtime, prompt resolution returns an explicit error.

### 2.6 Instructions and data remain separate

Developer-authored prompt assets may enter `:instructions` or `:task`.

User input, recalled memory, external documents, and tool results are
untrusted data and enter `:context`. They cannot be promoted to instructions by
a Skill or provider response. This prevents the `inject` feature from becoming
literal prompt-injection infrastructure.

Action protections remain enforced outside the prompt, so no prompt operation
can bypass a policy gate.

## 3. Proposed public DSL

### 3.1 Local application Skill

```elixir
defmodule MyApp.Skills.Projects do
  use Spectre.Skill,
    id: :projects,
    version: 1,
    prompt_root: "priv/skills/projects/prompts"

  inject :project_instructions,
    into: :instructions,
    position: :start

  inject :project_response_rules,
    into: :instructions,
    position: :end

  flow :projects do
    on :create_project, regex: ~r/create.*project/i do
      ask :create_project
    end

    on :project_status do
      run :project_status
    end

    on :delete_project do
      action :delete_project
    end
  end

  policy :confirm_delete do
    request :confirm_delete_project
    accept :delete_confirmed, regex: ~r/^yes$/i
    reject :delete_rejected, regex: ~r/^no$/i
    otherwise ask: :confirm_delete_project_retry
    attempts 3, then: :cancel_pending
  end

  protect :delete_project, with: :confirm_delete

  def project_status(input, ctx) do
    MyApp.Projects.status(input, ctx)
  end
end
```

### 3.2 Small composition-root Agent

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent,
    prompt_root: "priv/agents/main/prompts"

  model MyApp.LLM
  actions MyApp.Actions
  state MyApp.StateStore
  memory MyApp.Memory

  inject :company_identity,
    into: :instructions,
    position: :start

  inject :compliance_footer,
    into: :instructions,
    position: :end

  skill MyApp.Skills.Projects
  skill MyApp.Skills.Billing, as: :billing
  skill MyApp.Skills.Support, as: :support

  interrupt :cancel, regex: ~r/^cancel$/i do
    run :cancel_current
  end
end
```

### 3.3 Handler-level replacement

```elixir
on :emergency_request do
  ask :normal_answer,
    inject: [
      [
        prompt: :emergency_answer,
        into: :task,
        position: :replace
      ]
    ]
end
```

This replaces `:normal_answer` for this handler while preserving Agent, Skill,
and protected outer layers.

### 3.4 Dynamic context provider

```elixir
inject :current_account,
  from: {MyApp.PromptContext, :current_account},
  into: :context,
  position: :end,
  required: true
```

Provider callbacks must have a documented behavior, a timeout, normalized
return values, and exception/exit isolation. Dynamic content remains typed as
context even when returned by trusted application code.

### 3.5 Conditional injection

```elixir
inject :enterprise_rules,
  into: :instructions,
  position: :end,
  when: {MyApp.Accounts, :enterprise?}
```

Conditions are developer-declared callbacks. They are evaluated once per turn
and their outcome is recorded in prompt-plan metadata.

## 4. Internal model

### 4.1 One compiled definition shape

Refactor Agent metadata into one internal definition while retaining existing
generated functions for compatibility:

```elixir
%Spectre.Definition{
  kind: :agent | :skill,
  id: term(),
  version: pos_integer(),
  owner: module(),
  prompt_root: String.t(),
  config: keyword(),
  router: keyword(),
  rules: [Spectre.Rule.t()],
  policies: map(),
  protections: list(),
  after_actions: list(),
  injections: [Spectre.Prompt.Operation.t()],
  skills: [Spectre.Skill.Mount.t()]
}
```

`use Spectre.Agent` and `use Spectre.Skill` compile into this same behavioral
description. The Agent definition also contains mounted Skill definitions.

Compatibility functions such as `__spectre_rules__/0` and
`__spectre_config__/0` should delegate to `__spectre_definition__/0` during the
migration period.

### 4.2 Skill mount

```elixir
%Spectre.Skill.Mount{
  id: :projects,
  module: MyApp.Skills.Projects,
  definition_id: :projects,
  definition_version: 1,
  bindings: %{},
  opts: []
}
```

Mount identifiers are unique within an Agent. Runtime and persisted references
use stable identifiers, never dynamically generated atoms derived from user
input.

### 4.3 Scope and ownership

Rules, routes, candidates, and receipts need explicit ownership:

```elixir
scope: :agent | {:skill, mount_id}
owner: module()
```

Add these fields with backwards-compatible defaults:

```elixir
scope: :agent
owner: agent_module
```

Flow names, route labels, policy names, injections, and local prompt assets are
unique within their scope. Two mounted Skills may use the same internal label
or flow name without collision.

If conversational flow affinity is persisted, add `current_scope` alongside
the existing `current_flow` rather than overloading `current_flow` with several
incompatible shapes.

### 4.4 Prompt operations

```elixir
%Spectre.Prompt.Operation{
  id: term(),
  source: {:prompt, atom()} | {:provider, module(), atom()} | term(),
  scope: term(),
  target: :instructions | :context | :task,
  position: :start | :end | :replace,
  condition: nil | {module(), atom()},
  required?: boolean(),
  trust: :instruction | :data,
  opts: keyword()
}
```

The public DSL should not permit contradictory combinations, for example an
external-memory source with `trust: :instruction`.

### 4.5 Prompt plan

`Spectre.Prompt.render/4` should first build and resolve a plan:

```elixir
%Spectre.Prompt.Plan{
  protected: [],
  instructions: [],
  context: [],
  examples: [],
  task: nil,
  operations: [],
  metadata: %{}
}
```

Rendering becomes two explicit stages:

1. Build and resolve the scoped plan.
2. Render the resolved plan for the configured LLM adapter.

The first implementation may still serialize the plan to one string for
existing adapters. Internally it must preserve typed sections so a later
message-based adapter does not require another DSL redesign.

### 4.6 Prompt observability

Every model-backed result should expose safe prompt-plan metadata:

- operation identifiers and versions;
- owner and scope;
- applied/skipped status;
- target and position;
- provider duration and byte count;
- final plan hash;
- errors and optional fallbacks.

Do not record full sensitive fragment contents by default. Journal and logs use
identifiers, hashes, sizes, and redacted summaries.

## 5. Skill routing, classifier, and memory behavior

### 5.1 Default routing behavior

By default, a mounted Skill inherits the Agent router. Its scoped rules join the
Agent rule set and use the same evidence pipeline and arbitrator.

This is the first implementation because it preserves current routing behavior
and requires no new control flow.

### 5.2 Optional local classifier

A later Skill version may declare a local router/classifier:

```elixir
router mode: :local,
  via: [:regex, :classifier, :embedding]

classifier MyApp.ProjectClassifier
```

Use hierarchical routing rather than comparing raw confidence from unrelated
classifiers:

1. Agent routing selects the Skill scope through entry evidence.
2. The selected Skill router classifies among its own local labels.
3. The resulting normal handler is passed to `Spectre.Runner`.

Independent classifiers often have uncalibrated scores, so Spectre must not run
all Skill classifiers and select the largest raw number.

Routing receipts must show both decisions and their thresholds.

### 5.3 Memory

The default is inherited Agent memory. A Skill may request namespaced recall:

```elixir
memory namespace: :projects
```

The adapter receives the Agent, mount identifier, Skill identifier, and
conversation identifier. Recalled memory is contextual evidence, never
authoritative routing or lifecycle state.

A separate per-Skill adapter can be added after the memory behavior and adapter
failure contract are formalized. It is not required for Skill v1.

## 6. Compile-time validation

Adding composition without validation would move failures into runtime. The
definition compiler must reject:

- duplicate mount identifiers;
- duplicate labels, flows, policies, or injections within one scope;
- missing logical action bindings;
- invalid action binding targets;
- a Skill attempting to replace Agent infrastructure such as state or the
  action adapter;
- a protection referring to an unknown action or policy;
- unsupported router `via` entries;
- invalid prompt roots or prompt paths outside the configured root;
- invalid injection sources, destinations, or positions;
- multiple unconditional replacements for the same scope and destination;
- instruction injections sourced from user, memory, document, or tool data;
- local classifier configuration without entry-routing metadata;
- unsupported Skill definition versions.

Errors should include the Agent, Skill mount, scope, declaration, and source
line when available.

## 7. Refactoring and implementation sequence

### Phase 0: Protect existing behavior

Goal: make internal refactoring safe before adding DSL surface.

- [x] Add characterization tests for the current Agent metadata.
- [x] Add exact prompt-rendering fixtures for Agents with no injections.
- [x] Add routing fixtures for flow, interrupt, policy, and all four handlers.
- [x] Add action/protection fixtures proving the current effect boundary.
- [x] Capture router receipt shapes used by public consumers.
- [x] Run `mix format --check-formatted`, `mix test`, `mix credo --strict`, and
      `mix dialyzer` as the local baseline.

Acceptance criteria:

- Existing applications compile without DSL changes.
- An Agent with no mounted Skills and no injections has unchanged behavior.

### Phase 1: Introduce `Spectre.Definition`

Goal: stop runtime subsystems from depending on several unrelated generated
Agent callbacks.

- [x] Add `Spectre.Definition`.
- [x] Make `Spectre.Agent` compile one definition.
- [x] Add `__spectre_definition__/0`.
- [x] Keep existing `__spectre_*__/0` functions as compatibility wrappers.
- [x] Add a definition validator with contextual, readable errors.
- [x] Route Agent configuration access through a small definition resolver.

Likely files:

- `lib/spectre/agent.ex`
- `lib/spectre/definition.ex`
- `lib/spectre/definition/validator.ex`
- `lib/spectre/runtime/runtime.ex`
- `lib/spectre/router/router.ex`

Acceptance criteria:

- All existing tests remain green.
- Runtime behavior is unchanged.
- Invalid current DSL references fail during compilation where practical.

### Phase 2: Add ownership and scopes

Goal: allow rules from different modules without flattening away their origin.

- [x] Add `scope` and `owner` to Rule, Route, Candidate, and Receipt.
- [x] Default legacy rules to the Agent scope and module.
- [x] Make `Runner.run_function/3` call the route owner.
- [x] Resolve prompt roots from the route owner/definition.
- [x] Resolve policies and hooks using scoped references.
- [x] Add `current_scope` so flow affinity survives turns.
- [x] Ensure journal records contain stable scope identifiers.

Likely files:

- `lib/spectre/types/rule.ex`
- `lib/spectre/types/route.ex`
- `lib/spectre/router/candidate.ex`
- `lib/spectre/router/receipt.ex`
- `lib/spectre/runtime/runner.ex`
- `lib/spectre/runtime/policy.ex`
- `lib/spectre/runtime/prompt.ex`
- `lib/spectre/types/state.ex`

Acceptance criteria:

- Two scoped rules may have the same local label.
- A scoped `run` handler calls its owner module.
- A scoped prompt uses its owner prompt root.
- Results and receipts identify both Agent and selected scope.

### Phase 3: Implement organizational Skill v1

Goal: make the Agent a small composition root without adding workflow
semantics.

- [x] Add `use Spectre.Skill` with the supported subset of Agent DSL.
- [x] Add the Agent-level `skill/2` mount macro.
- [x] Add `Spectre.Skill.Mount`.
- [x] Load and validate mounted definitions at Agent compile time.
- [x] Preserve Skill rules as scoped definitions.
- [x] Implement inheritance for model, router, memory, and runtime defaults.
- [x] Implement logical action declaration and binding.
- [x] Apply outer Agent protections after action binding.
- [x] Reject mount and namespace conflicts at compile time.
- [x] Add introspection returning mounted Skill definitions.

Skill v1 intentionally excludes:

- `step` or workflow macros;
- active Skill frames;
- nested Skill execution;
- parallel tools;
- direct tool module invocation;
- per-Skill state adapters;
- dynamic installation from untrusted runtime input.

Acceptance criteria:

- Moving an existing flow and its handlers into a Skill requires no semantic
  rewrite.
- The Agent module can mount multiple Skills with overlapping local names.
- Protected bound actions still require the outer Agent policy.
- Removing a Skill mount removes all of its behavior cleanly.

### Phase 4: Refactor prompt rendering into `Prompt.Plan`

Goal: establish typed prompt composition before exposing `inject`.

- [x] Add `Spectre.Prompt.Plan` and fragment/operation types.
- [x] Represent the current `ask` prompt as the `:task` section.
- [x] Keep instructions, context, examples, and task separate internally.
- [x] Enforce prompt-root containment.
- [x] Normalize prompt/provider failures into structured errors.
- [x] Add provider deadlines and size limits.
- [x] Render the plan through the current string-based LLM interface.
- [x] Add redacted plan metadata to model-backed results.

Acceptance criteria:

- With no operations, rendered prompt text matches the current output exactly.
- Prompt paths cannot escape their configured root.
- Invalid templates and providers return errors rather than crashing Sessions.

### Phase 5: Implement `inject` v1

Goal: support deterministic scoped prompt composition.

- [x] Add top-level Agent injections.
- [x] Add top-level Skill injections.
- [x] Add Flow-level injections.
- [x] Add handler/`ask` injections.
- [x] Add trusted runtime injections through explicit options.
- [x] Implement `into: :instructions | :context | :task`.
- [x] Implement `position: :start | :end | :replace`.
- [x] Resolve scopes as nested envelopes.
- [x] Preserve declaration order for multiple start/end fragments.
- [x] Enforce one active replacement per scope and destination.
- [x] Support conditional injections.
- [x] Support required and optional dynamic providers.
- [x] Mark data-derived sources as context-only.
- [x] Record applied, skipped, replaced, and failed operations.

Acceptance criteria:

- Start/end ordering is deterministic across all scopes.
- Handler replacement preserves Flow, Skill, Agent, and protected outer layers.
- Skill replacement cannot erase outer Agent instructions.
- Duplicate replacements produce explicit errors.
- Context content cannot be promoted into instructions.
- Prompt metadata explains the final composition without logging secrets.

### Phase 6: Optional scoped router, classifier, and memory

Goal: let complex Skills specialize infrastructure without complicating Skill
v1.

Status: explicitly deferred; Skill v1 inherits Agent infrastructure.

- [ ] Add explicit inherited/local router modes.
- [ ] Add Skill entry evidence for hierarchical routing.
- [ ] Add local classifier artifact validation and warm process naming by
      Agent/mount/version.
- [ ] Return a two-stage routing receipt for hierarchical decisions.
- [ ] Add memory namespaces to recall and persistence callbacks.
- [ ] Add optional scoped memory adapters only after defining a formal behavior.
- [ ] Benchmark hierarchical routing before enabling it broadly.

Acceptance criteria:

- Local classifier scores are never compared directly across unrelated
  classifiers.
- Routing remains deterministic under candidate/input-order permutations.
- Memory failures do not corrupt authoritative state or Skill selection.

### Phase 7: Package and reference-Skill validation

Goal: prove that the abstraction is genuinely reusable rather than just code
movement.

- [x] Move representative application flows into local test Skills.
- [x] Build a reusable reference Skill with logical action bindings.
- [ ] Exercise prompts, `run`, read actions, a protected write action, memory,
      classifier routing, and injection layers.
- [x] Verify mount behavior, overlapping local names, and definition introspection.
- [x] Define Skill version compatibility rules (Skill v1 only).
- [ ] Keep reusable Skills in optional packages so core Spectre remains small.

A useful reference is a research Skill that routes research requests, recalls
context, calls bound search/fetch actions, drafts through `ask`, and stages a
protected publish action. It remains a collection of ordinary Spectre routes,
not a hidden autonomous loop.

## 8. Production-readiness track

The Skill and prompt-plan refactors can begin independently, but Spectre should
not be called production-ready until the following core work is complete.

### P0: correctness and recovery

- [x] Add an explicit versioned `Spectre.State.Codec` that round-trips JSON and
      database maps with string keys, validates enums, and rejects malformed
      state instead of silently losing fields.
- [x] Add a monotonic state revision and a compare-and-swap persistence
      contract to prevent concurrent turns from overwriting each other.
- [x] Centralize effect, policy, awaitable, and terminal transitions in a pure
      lifecycle module with an immutable Transition result.
- [x] Define the persist-before-execute and persist-terminal-result workflow.
- [x] Make action execution idempotency explicit and durable at the capability
      boundary.
- [x] Add Session-aware execution and stale/repeated completion handling.
- [x] Fix Session idle-timer generation races and use restart semantics that
      allow abnormal crash recovery.
- [x] Isolate state, memory, action, prompt, model, and journal adapters and add deadlines.
- [x] Represent ambiguous persistence/action outcomes rather than retrying blindly.
- [x] Enforce prompt-root containment and normalize prompt rendering failures.
- [x] Bound state trace/history growth and disable or redact raw-input
      classifier logging by default.

### P1: deterministic behavior and observability

Status: complete except explicit unknown-route fallback semantics (kept
backward-compatible with existing no-response behavior) and scoped warm
classifier supervision, which belongs with optional Phase 6.

- [ ] Add a required or explicit fallback/clarification response so unknown
      routes do not silently return no response.
- [x] Make arbitration deterministic when multiple labels have agreement.
- [x] Add permutation-invariance and deterministic tie-breaking tests.
- [x] Add journal delivery timeouts, partition/isolation strategy, queue depth,
      drops, and latency metrics.
- [x] Validate classifier artifact kind, version, labels, and dimensions; use
      safe decoding and atomic publication.
- [ ] Supervise warm classifier instances by definition/mount/artifact rather
      than relying on one global process.
- [x] Make semantic-cache revisions and inserts atomic and snapshot publication
      crash-safe.
- [x] Add input, prompt, history, action/tool, model-call, artifact, state, and
      memory-payload limits.

### P2: performance and package boundaries

Status: deferred until production workload measurements exist.

- [ ] Profile semantic cache lookup, local classifier loading, journal delivery,
      prompt providers, and hierarchical routing under concurrent Sessions.
- [ ] Consider moving native Vettore/classifier functionality behind an
      optional adapter or companion package so deterministic-only applications
      do not pay the native dependency cost.
- [ ] Add load and crash-point tests based on measured production workloads.

CI configuration and ExDoc work are intentionally outside this plan for now.

## 9. Test matrix

### 9.1 Definition and compatibility

- Existing Agent metadata and behavior remain unchanged.
- Existing public generated callbacks still work.
- Invalid definitions fail with actionable compile errors.
- Definition ordering is deterministic across compilations.

### 9.2 Skills

- Mounted Agent and Skill rules both route correctly.
- Two Skills may reuse internal labels, flows, prompts, and policy names.
- `run` invokes the owner module and supports existing callback arities.
- `ask` and `reply` use the owner prompt root.
- Logical actions bind correctly and missing bindings fail compilation.
- Agent protection applies after binding.
- Skill configuration inherits Agent defaults unless explicitly allowed to
  override them.
- Receipts, results, and journal records preserve scope.

### 9.3 Injection ordering

- Start fragments retain declaration order.
- End fragments retain declaration order.
- Agent, Skill, Flow, handler, and runtime scopes nest deterministically.
- Replacement affects only the selected scope and destination.
- Outer layers survive inner replacement.
- Protected layers survive all replacement.
- Duplicate unconditional replacement fails compilation.
- Overlapping conditional replacements return a structured runtime error.
- A false condition leaves the inner content unchanged.

### 9.4 Injection safety and failure

- User, memory, document, and tool content remain context data.
- Prompt-root traversal and absolute-path escape are rejected.
- Required provider failure fails the turn predictably.
- Optional provider failure produces a warning and continues.
- Provider exception, exit, timeout, oversized output, and invalid reply are
  normalized.
- Metadata is useful but contains no raw sensitive fragment content by default.

### 9.5 Production recovery

- State codec round-trips every state field and nested effect/awaitable.
- Every forbidden lifecycle transition is rejected.
- State CAS rejects stale turns.
- Crash after approval but before execution is recoverable.
- Crash after external success but before terminal persistence is idempotently
  recoverable.
- Duplicate effect completion returns the stored terminal result.
- Session ignores stale idle messages.
- A hung journal store does not block unrelated stores indefinitely.
- Corrupt classifier artifacts fail safely.

## 10. Suggested delivery slices

Keep changes reviewable and behavior-preserving:

1. Definition and compatibility wrappers.
2. Scope/owner metadata through Router, Runner, Result, and receipts.
3. `Spectre.Skill` plus mounting and compile validation.
4. Logical action bindings and scoped policy resolution.
5. Prompt Plan with no public `inject` DSL yet.
6. Agent and handler injection with start/end.
7. Skill and Flow injection plus scoped replacement.
8. Dynamic context providers, conditions, limits, and observability.
9. Optional hierarchical classifier and memory namespaces.
10. Reference Skill and production recovery gates.

Each slice should run the complete local verification suite. No slice should
mix lifecycle hardening with large DSL changes unless the change cannot be
separated safely.

## 11. Definition of done

The work is complete when:

- the main Agent can be a short composition module;
- existing flows can move into Skills without changing their handler semantics;
- reusable Skills declare requirements without gaining execution authority;
- every selected route retains its owner and scope;
- `inject` composes typed prompt sections at all declared scopes;
- `:start`, `:end`, and scoped `:replace` have deterministic, tested behavior;
- no Skill or injected fragment can erase protected outer layers or bypass an
  action policy;
- prompt composition is observable without leaking raw sensitive content;
- existing Agents without Skills/injections remain backward compatible;
- the P0 production correctness and recovery items are complete;
- the local format, test, Credo, and Dialyzer checks pass.
