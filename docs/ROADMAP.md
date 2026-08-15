# Roadmap

Spectre remains a focused OTP-native runtime rather than a framework that owns
application business logic. The core keeps one canonical Definition and one
Instance owner for conversational and operational state; adapters and
distributed integration do not introduce a second runtime owner.

## Unreleased: inference Invocations and boundary receipts

Inference now crosses the same portable, revision-fenced Invocation boundary
as Effects. Run v3 retains start and inference continuations, while canonical
Instance checkpoint v3 adds inference control/progress and a required-receipt
outbox. The current compatibility matrix is State `5 / [2, 3, 4, 5]`, Run
`3 / [1, 2, 3]`, and tagged Instance `3 / [2, 3]`.

The first streaming slice is an Instance-owned, text-only, pull-driven
Enumerable backed by a supervised `:gen_statem`. Raw deltas stay in a bounded
authoritative data lane; committed text-free progress uses the existing event
lane. Cancellation, restart-based steering, budgets, liveness, recovery and
terminal post-processing remain core-owned. Provider transports stay in
adapter packages.

Ledger v2 support is a narrow optional `Spectre.Receipt.Sink`, not a generic
History subsystem. Core records admitted nondeterministic boundaries and
canonical state roots; `:required` delivery uses the existing checkpoint seam
and a bounded outbox. Receipt capture does not turn provider work into
deterministic replay.

The implemented runtime contract is documented in
[Streaming inference](STREAMING_INFERENCE.md) and
[Boundary receipts](RECEIPTS.md). Concrete Prism and Ledger adapters remain
work for their own repositories.

## 0.3.1 foundation, diagnostics, and satellite boundaries

The patch release keeps State writer/readers `5 / [2, 3, 4, 5]`, Run
`2 / [1, 2]`, and the format-tagged Instance checkpoint `2 / [2]`. It freezes
a real 0.3.0 Instance fixture, centralizes activation through the existing
Instance commit seam, adds adapter-neutral CheckpointStore conformance,
read-only Doctor diagnostics, privacy-safe telemetry hardening, and generators
only for stable core boundaries.

`spectre_ledger` is intended to integrate as a Checkpoint Store/Stack package,
and `spectre_lab` is intended to consume verified core artifacts. Neither adds
a second owner or a speculative History model to the core.

## 0.3.0 reflective runtime — complete in core

Opt-in Experience, mechanical Declared/Effective/Observed Reflection,
policy-gated introspection, compiled Prism-compatible critics, independent
oracle approval, inert Forge Proposals, explicit rebase and stale external
evidence checks now compose over the complete 0.2 foundation. Forge cannot
publish, approve or activate and has no vocabulary for code, authority,
kernel policy, evaluators or projection generators.

The permanent reflective fixture and executable conformance helpers pin the
new identities. The released 0.3.0 code emits and reads only its format-tagged
Instance schema 2. Retired untagged Instance fixtures remain historical
evidence but are not inputs to that reader.

Concrete sibling-package adoption remains in those repositories and is not a
second core runtime gate.

## 0.2.9 governed Definition changes — complete

Closed ChangeSets now derive immutable Candidate Definitions through a trusted
host Composer and registered operation vocabulary. Exact gate receipts,
protected-corpus evaluation deltas, deterministic human reports, risk-based
approval, activation re-verification, ancestor rollback, and conservative GC
all compose over existing Store, Manifest, closure, owner-fence, and CAS
contracts. Runtime data still cannot introduce code, authority, or activation.

State remains writer v5, Run remains writer v2, and canonical Instance
checkpoints remain schema 4. The 0.3 Reflection and Forge planes compose over
these governed identities without bypassing approval or activation.

## 0.2.8 data-driven execution — complete

Compiled and runtime-authored precise Work now share one portable Program IR
and the existing operational executor. The gate includes exact Execution
materialization/projections, prompt receipts, bounded amendments, typed
Flow/Work handoffs, registered pure state migrations, and deterministic
no-Effect rehearsal. Runtime data cannot introduce code or authority.

State remains writer v5, Run remains writer v2, and canonical Instance
checkpoints remain schema 4. Governance composes over these identities and host
boundaries rather than adding another executor.

## 0.2.0 vNext core — complete

The 0.2.0 implementation was completed in dependency order:

1. canonical Agent state, typed sections, revisioned snapshots,
   conflict-aware merge, transition journal, and portable CAS checkpoints;
2. shared operational runtime, isolated one-attempt Runners, fencing, retry,
   recovery, durable control, budgets, and precise Work;
3. Flow integration, read-only views, visibility, event routing, and
   disambiguation;
4. core Vigil with durable waits, timer generations, significance, and the
   same Runner topology;
5. provider-neutral function, Action, Effect, planner, cognitive, memory, and
   external-controller boundaries;
6. governed consent and delivery receipts, followed by restart, race,
   corruption, and coverage hardening.

The 0.1.6 conversational recovery baseline remains protected. Work and Vigil
are additive domains; Run was not renamed. See
[Migrating to 0.2.0](MIGRATING_TO_0_2.md).

## After 0.2.0

- Keep `0.2.x` changes compatible with the published Work, Vigil, controller,
  checkpoint, control, event, and delivery contracts.
- Move concrete Lens, Kinetic, Prism, Mnemonic, Directive, Beam, and Pulse
  integrations forward in their own repositories against explicit minimum
  Spectre versions.
- Add distributed claims or remote handoff only after preserving the local
  single-owner and fencing invariants.
- Keep Mission, Wayfinder, transport, model clients, credentials, and durable
  application storage in their owning libraries or host applications.

## What Already Works

- Router plugs collect evidence without owning the final decision.
- The arbitrator chooses one route across deterministic and probabilistic
  providers.
- Protected actions stop at a policy boundary.
- Policy approval and side-effect execution are separate operations.
- `State`, `Effect`, `Awaitable`, `Result`, and `Turn` expose lifecycle as data.
- Sessions serialize conversation turns and can restore durable state.
- Ordered turn handlers let an optional external runtime own a normal turn
  without gaining authority over Spectre state, policy, routing, or effects.
- `spectre_kinetic` can own Action Language and tool planning without moving
  side effects into the conversational runtime.

These are the foundations to preserve.

## Ecosystem integration direction

Future packages should compose through one local turn vocabulary and explicit
ownership boundaries rather than a universal plugin system:

- `Spectre.turn/3` remains the canonical local host port for Agent modules and
  Sessions;
- SpectreDirective may claim an active durable mission through a turn handler;
- SpectreMnemonic should adapt to the existing memory port;
- SpectreLens should expose browser work as trusted actions/Skills and safe
  context data;
- SpectrePulse may define agent-to-agent envelopes, addressing, task and
  correlation identifiers, delivery, retries, streaming, and cancellation,
  then adapt a validated payload to and from `Spectre.turn/3`;
- a Pulse exchange should use a turn handler only when an already-active local
  task genuinely owns subsequent input before normal routing.

New libraries can register ordered handlers without creating a core
dependency, but the handler contract will remain deliberately unable to
mutate input, state, routes, effects, or awaitables. Broader needs should first
justify a dedicated narrow port.

## Implementation Journal

### 2026-07-20: Lifecycle, Execution, Journal, And Arbitration Hardening

Phases 1 through 6 are functionally complete for the library scope:

- `Spectre.Lifecycle.apply/2`, `next/1`, and `projection/1` are the canonical
  command and host-decision surface; `State`, `Result`, `Turn.Decision`,
  `Runner`, and `Policy` delegate to it;
- `Spectre.Policy.Matcher` is pure, and user text plus trusted host decisions
  share `Spectre.Policy.Resolution`, including optional structured metadata;
- no-match attempts, exhaustion, rejection, cancellation, and expiration are
  explicit lifecycle commands; global interrupts remain closed by default and
  can be enabled with `policy_global_interrupts?: true`;
- `Spectre.ActionDispatcher` owns capability calls only, while
  `Spectre.Execution` validates effects and applies terminal lifecycle
  commands; `Runtime` and `Session` retain the durable two-commit workflow;
- journal records now cover arbitration, policy, lifecycle, execution, and
  persistence, with redaction callbacks, per-phase sampling, retention
  metadata, schema restoration, and telemetry derived from records;
- arbitration explanations now expose eligibility, configured thresholds,
  rejected alternatives, the winner, and deterministic precedence in receipts
  and journal evidence;
- operational telemetry covers provider calls, policy retries, execution,
  restore, persistence conflicts, stale session commands, journal records, and
  idle shutdown without requiring `:telemetry` as a dependency;
- the strategy matrix contains 800 generated cases across ten differently
  configured agents, backed by local FastEmbed-compatible fixtures; the full
  suite exceeds 1,000 tests.

Current verification is 1,177 passing tests and 90.08% line coverage, together
with warnings-as-errors compilation, strict Credo, Dialyzer,
formatting, and diff checks. The default 90% coverage threshold remains
enforced.

Project decisions for this cycle:

- the `freelance.fast` integration fixture from Phase 0 is waived because it
  belongs in the consuming application, not this library repository;
- Vettore remains a required dependency by design, including regex-only
  deployments;
- Phase 8 release/editorial stabilization is complete for the `0.1.0` public
  preview: package metadata, changelog, public guides, API documentation,
  production checklist, testing guide, security policy, and contribution
  policy are versioned with the source.

### 2026-07-17: Canonical Provider Facts And Reply Validation

This hardening pass closed the remaining gap between route traces and the
shared provider boundary:

- evaluation receipts now record privacy-safe provider outcome and duration
  facts emitted directly by `Spectre.Provider.Call`;
- LLM-use policies reflect an actual adapter-worker invocation, so a failure
  while constructing the classifier prompt is not misreported as model usage;
- local-classifier and semantic-cache route maps now validate labels,
  acceptance, numeric scores, strategy, metadata, and score maps before they
  reach arbitration;
- embedding and LLM shape validation now happens inside the same observed call
  boundary, keeping normalized outcomes consistent;
- receipt route, candidate, attempt, and provider-call fields are independently
  sanitized, including values supplied by custom pipelines;
- a valid non-accepted semantic-cache reply degrades as a miss instead of
  crashing a router plug;
- rejected candidates cannot become eligible merely because a rule assigned
  hard evidence strength;
- the dynamically detected `ex_fastembed` integration is no longer declared as
  a transitive Git dependency, so the local release package can be built while
  host applications can still opt into the adapter explicitly.

These facts remain local receipt data. No exporter, pricing layer, automatic
retry, or circuit breaker was added.

### 2026-07-16: Provider Execution Resilience

This iteration added a small operational boundary instead of embedding
provider-specific policy throughout the router:

- `Spectre.Provider.Call` isolates main LLM, LLM-classifier, local-classifier,
  embedding, and semantic-cache lookup calls from the requesting process;
- provider-specific deadlines have conservative defaults, application-level
  configuration, per-agent/per-call overrides, and an explicit `:infinity`
  escape hatch;
- a timed-out call or dead caller terminates the local adapter worker, while
  documenting that remote cancellation still depends on the adapter client;
- `Spectre.Provider.Failure` normalizes infrastructure failures without
  retaining prompts, input, raw output, exception messages, or stack traces;
- deliberate adapter `{:error, reason}` results remain compatible and are not
  assigned a speculative retry policy;
- main-model fallback remains available after timeout and receives the
  normalized primary failure;
- local classifier, embedding, and semantic-cache failures remain optional
  evidence so routing can continue to LLM arbitration or clarification;
- contract tests cover success, declared error, timeout, exception, exit,
  throw, hard crash, malformed reply, caller-death cancellation, fallback, and
  routing degradation.

No automatic retry, circuit breaker, token pricing, or metrics exporter was
added to core. Provider-specific retry/rate-limit policy remains an adapter or
optional middleware responsibility. Provider duration and normalized outcome
were added to the routing receipt in the 2026-07-17 pass; minimal telemetry can
later be derived from that canonical fact.

### 2026-07-16: Routing Evaluation Harness

This iteration made routing quality and LLM use measurable without expanding
the normal turn runtime:

- `Spectre.Router.evaluate/3` now runs the real input and routing pipelines but
  never loads state/memory adapters or executes the selected handler;
- evaluation forces journal delivery and online semantic learning off;
- `Spectre.Router.Receipt` captures the winning outcome, strategy, sanitized
  provider evidence, duration, and LLM arbitration intent while excluding
  inputs, prompts, model outputs, matches, and handlers;
- `Spectre.Eval` loads version-controlled JSONL cases and checks expected
  routes/outcomes together with `forbidden`, `allowed`, or `required` LLM use;
- aggregate reports include pass rate, route accuracy, strategy and outcome
  distribution, LLM-policy violations, duration percentiles, confusion data,
  and per-tag results;
- `mix spectre.eval` provides strict-by-default CI thresholds and optional JSON
  artifacts;
- a representative fixture and end-to-end tests cover deterministic, local,
  LLM, privacy, state/history, no-handler, no-journal, and no-semantic-write
  behavior.

The initial receipt normalized evidence emitted by router traces and candidates.
Provider execution resilience and direct per-provider duration/outcome facts
landed in the following passes. Eligibility thresholds and winning precedence
still need to become canonical receipt data instead of being inferred by later
consumers.

### 2026-07-16: Routing Intelligence And Journal Foundation

This iteration hardened the classifier/LLM boundary and implemented the first
observability slice without moving lifecycle ownership:

- hard, runnable evidence now skips later semantic-cache, embedding, and local
  classifier work that cannot change the default winner;
- the default arbitrator asks an enabled and available LLM classifier when no
  cheaper candidate clears its threshold, not only when candidates conflict;
- confident local evidence still wins without an LLM call;
- route-level `via:` restrictions are preserved during LLM arbitration, and an
  empty visible label set never reaches a model;
- classifier prompts now receive canonical labels, structured evidence, and
  bounded recent chat from state, while caller overrides remain explicit;
- LLM output must resolve to exactly one known label; unknown, explanatory, or
  multi-label output degrades safely instead of causing recursive arbitration;
- `Spectre.Journal.Record`, `Spectre.Journal.Store`,
  `Spectre.Journal.Recorder`, and a bounded supervised async buffer now exist;
- the `journal/2` DSL, application default, per-turn override, stable turn and
  record identities, deterministic sampling, privacy defaults, and explicit
  failure policies are implemented;
- completed routing contexts emit one structured `:arbitration` record with
  decision, reason code, evidence, and thresholds but no conversation content
  by default.

This is deliberately not the completion of Phase 5. Policy, lifecycle,
execution, and persistence records still depend on the canonical transition
work in Phases 1 through 4. The current recorder observes the existing
`Arbitration` boundary only; it does not invent lifecycle transitions.

The next routing work is to make threshold eligibility and winning precedence
canonical data on the arbitration receipt, then have the journal consume that
receipt instead of reconstructing any explanation. The next journal work is to
add redaction callbacks, retention metadata, buffer telemetry/stress coverage,
and telemetry sourced from the same record.

## The Main Architectural Problem

Lifecycle responsibility is currently distributed across several modules:

| Concern | Current owners | Risk |
| --- | --- | --- |
| Stage an effect | `Runner`, `State` | Transition rules can diverge by handler path |
| Policy resolution | `Policy`, `State` | Matching, mutation, events, and results are coupled |
| Effect completion | `ActionExecutor`, `State` | Capability I/O and transitions share one module |
| Determine current work | `State`, `Result` | Two views require precedence rules |
| Choose the host step | `Result`, `Turn.Decision` | Terminal and pending precedence is repeated |
| Persist progress | `Runtime`, `Session`, host | Approval and execution have different owners |
| Agent journal | runtime traces, host logs | No durable, structured explanation stream |

The types themselves are useful. The problem is that too many modules are
allowed to decide how those types transition.

## Lifecycle Invariants

Before moving code, freeze these rules as executable contract tests:

1. `State` is the only authoritative machine snapshot.
2. At most one executable or policy-gated effect is active per conversation.
3. At most one open policy awaitable gates that active effect.
4. A protected effect moves through
   `pending -> waiting_policy -> approved -> completed | failed`.
5. A rejected, expired, or exhausted policy moves the effect to `cancelled`.
6. `waiting_policy` is never executable.
7. Approval never calls the action module.
8. The approved state is committed before capability execution.
9. Every completed, failed, or cancelled transition is idempotently recorded.
10. A terminal effect cannot return to a pending state.
11. An invalid host resolution cannot mutate state.
12. A policy reply bypasses normal routing while its awaitable is open.
13. A live session never replaces committed state with an older result.
14. Host decisions are derived from authoritative state plus the current
    transition, never from stale local arrays alone.
15. Journal recording is observational by default and cannot change routing,
    policy, lifecycle, or execution outcomes.
16. Every journal record carries stable correlation identifiers and a
    versioned schema.
17. Record identifiers and per-turn sequence numbers make appends idempotent
    and timelines reconstructable.

The first deliverable should be a transition matrix containing every legal
source state, command, target state, emitted event, and expected host decision.

## Target Ownership

Introduce one pure lifecycle kernel. The final name can change, but
`Spectre.Lifecycle` is used here for clarity.

| Module | Target responsibility |
| --- | --- |
| `Spectre.State` | Data structure, serialization, migration, and read-only queries |
| `Spectre.Effect` | Effect value object, constructors, predicates, and outcome formatting |
| `Spectre.Awaitable` | Awaitable value object, constructors, and predicates |
| `Spectre.Lifecycle` | The only module allowed to apply lifecycle commands to state |
| `Spectre.Transition` | Immutable receipt returned by the lifecycle kernel |
| `Spectre.Policy.Matcher` | Pure text or trusted-label matching; no state mutation |
| `Spectre.Runtime` | Input, routing, transition orchestration, and persistence workflow |
| `Spectre.Execution` | Persist-before-execute workflow and terminal-result persistence |
| `Spectre.ActionDispatcher` | Calls the registered application capability; no state mutation |
| `Spectre.Result` | Public receipt/read model built from a transition |
| `Spectre.Turn` | Public host wrapper; delegates next-step calculation to the lifecycle kernel |
| `Spectre.Session` | Serializes commands and retains only committed state |
| `Spectre.Journal.Record` | Versioned, privacy-aware explanation record |
| `Spectre.Journal.Recorder` | Filters, redacts, samples, and delivers journal records |
| `Spectre.Journal.Store` | Minimal append behaviour implemented by host storage adapters |

The desired pure API is approximately:

```elixir
@spec apply(State.t(), command()) ::
        {:ok, Transition.t()} | {:error, transition_error()}

Lifecycle.apply(state, {:stage_effect, effect, policy})
Lifecycle.apply(state, {:resolve_policy, {:accept, label}})
Lifecycle.apply(state, {:policy_no_match, input})
Lifecycle.apply(state, {:complete_effect, effect_id, value})
Lifecycle.apply(state, {:fail_effect, effect_id, reason})
Lifecycle.apply(state, {:cancel_effect, effect_id, reason})
```

A transition contains all emitted data once:

```elixir
%Spectre.Transition{
  previous_revision: 12,
  state: next_state,
  effects: [changed_effect],
  awaitables: [changed_awaitable],
  events: [domain_event],
  reply_text: "",
  next: {:needs, changed_effect}
}
```

`Result` and `Turn` should project this receipt instead of independently
reconstructing lifecycle precedence. This does not require full event sourcing;
commands and emitted events can remain an internal consistency mechanism.

## Journal And Agent Observability

Chat history, the journal, and telemetry solve different problems:

- chat history is conversational context that may influence a later turn;
- the journal explains why the runtime selected and changed something;
- telemetry aggregates counters, timings, and health without being the durable
  source of an individual decision.

The new feature should be named `journal`, not `history`, because
`history/1` already controls conversational transcript retention.

A proposed agent DSL is:

```elixir
journal MyApp.SpectreJournalStore,
  events: [:routing, :arbitration, :policy, :lifecycle, :execution],
  include_input: false,
  include_reply: false,
  include_effect_payload: false,
  state: :revision,
  mode: :async,
  on_error: :warn,
  sample_rate: 1.0
```

Without a `journal` declaration, the runtime emits nothing. `journal(false)`
can explicitly disable an inherited application default for one agent.

The store implements a deliberately small write contract:

```elixir
defmodule MyApp.SpectreJournalStore do
  @behaviour Spectre.Journal.Store

  @impl true
  def append(%Spectre.Journal.Record{} = record, opts) do
    MyApp.AgentJournal.insert(record, opts)
  end
end
```

An optional query callback may support the built-in inspection API later, but
the runtime should depend only on `append/2`. Applications remain free to use
PostgreSQL, ClickHouse, OpenSearch, an event stream, or an in-memory store.

A versioned record should contain structured explanation data:

```elixir
%Spectre.Journal.Record{
  schema_version: 1,
  id: record_id,
  agent: MyApp.SupportAgent,
  agent_version: agent_version,
  conversation_id: conversation_id,
  turn_id: turn_id,
  sequence: 3,
  trace_id: trace_id,
  state_revision: revision,
  phase: :arbitration,
  decision: %{kind: :route_selected, label: :BILLING},
  reason: %{rule: :provider_agreement, providers: [:bag, :semantic_cache]},
  evidence: [
    %{provider: :bag, label: :BILLING, score: 0.82, accepted?: true},
    %{provider: :semantic_cache, label: :BILLING, score: 0.87, accepted?: true}
  ],
  transition: nil,
  policy: nil,
  effect: nil,
  duration_native: duration,
  metadata: %{router_version: router_version},
  occurred_at: DateTime.utc_now()
}
```

The journal should record decisions at stable boundaries:

1. routing evidence summary, including provider, label, score, margin, threshold,
   and whether the candidate was accepted;
2. arbitration winner, tie-break or fallback reason, and alternatives rejected;
3. policy accept, reject, no-match, attempt count, cancellation, and whether the
   source was user input or a trusted host;
4. lifecycle command, previous status, next status, and emitted events;
5. execution dispatch, idempotency identity, completion class, and duration;
6. persistence success, warning, conflict, or stale-revision rejection.

Input text, reply text, complete state, effect arguments, and action results must
be excluded by default. They can contain personal data, credentials, or business
secrets. An application may opt in per field with a redaction callback and
retention policy.

Delivery semantics must be explicit:

- `mode: :async, on_error: :warn` is the monitoring default; recording cannot
  change the agent decision and a supervised buffer protects turn latency;
- `mode: :sync, on_error: :error` is available when the record is a required
  audit artifact;
- strict atomic audit requirements should use a host outbox in the same
  transaction as state persistence;
- policy and execution records should not be sampled by default;
- all records need schema versioning, retention controls, and deterministic
  correlation IDs.

This feature makes it possible to answer:

- why an agent selected one route instead of another;
- which classifier or cache disagreed with the final decision;
- how often an agent falls back, clarifies, rejects, or exhausts a policy;
- which effects fail, are retried, or are rejected before execution;
- whether a model, classifier, threshold, or cache revision changed behaviour;
- how one agent version compares with another in `freelance.fast`;
- which real decisions should become regression fixtures.

The journal must consume canonical `Arbitration` and `Transition` data rather
than adding new decision logic. That keeps observability useful without creating
another owner of lifecycle semantics.

## Work Plan

### Phase 0: Freeze Current Behaviour

Status: complete for the Spectre repository. The external `freelance.fast`
fixture is explicitly out of scope; its application suite remains a downstream
integration test.

Goal: prevent an architectural refactor from changing externally visible
semantics accidentally.

- Keep focused tests for routing, arbitration, turns, policy rejection,
  attempts exhaustion, host resolution, sessions, persistence failures, and
  idempotency.
- Add a table-driven lifecycle contract suite covering every invariant above.
- Validate `freelance.fast` in its own consuming repository when desired.
- Document `ask/3`, `turn/3`, `resolve_policy/4`, and `execute/3` as the current
  compatibility surface.
- Record the current serialized `State` version and migration fixtures.

Exit criteria:

- every legal transition and every forbidden transition has a test;
- downstream consumers can use only public Spectre APIs;
- no test needs to inspect private runtime functions.

### Phase 1: Extract The Pure Lifecycle Kernel

Status: complete.

Goal: centralize state transitions without changing public APIs.

- Add `Spectre.Transition`.
- Add `Spectre.Lifecycle.apply/2` and `next/1`.
- Move staging, approval, rejection, cancellation, completion, and failure
  rules out of `State`.
- Keep temporary delegating functions in `State` to preserve compatibility.
- Make `Policy` produce matcher decisions and lifecycle commands.
- Make `Runner` request `{:stage_effect, effect, policy}` instead of mutating
  state directly.
- Make `Result.lifecycle/1` and `Turn.Decision` delegate to one canonical
  projection.

Exit criteria:

- `State` contains no business transition branches;
- all lifecycle mutations pass through `Spectre.Lifecycle`;
- existing public return values remain compatible.

### Phase 2: Separate Policy Matching From Policy Transitions

Status: complete.

Goal: make policy behavior deterministic and independently testable.

- Extract `Spectre.Policy.Matcher`.
- Give user text and trusted host labels the same validated resolution type.
- Keep normalization before policy matching.
- Model no-match, maximum attempts, expiration, cancellation, and rejection as
  explicit commands.
- Add optional structured rejection metadata for UI and audit consumers.
- Define whether global interrupts may run while a policy is open; keep the
  default closed unless explicitly configured.

Exit criteria:

- policy matching is a pure function;
- invalid labels and repeated resolutions cannot mutate state;
- user and host rejection produce the same lifecycle outcome shape.

### Phase 3: Unify Execution And Persistence

Status: complete. `Runtime` owns durable commits, `Execution` owns validated
dispatch-to-transition orchestration, and `ActionDispatcher` owns the module
call only.

Goal: remove ambiguity around who stores terminal execution state.

- Split capability invocation from lifecycle mutation.
- Rename or introduce `Spectre.ActionDispatcher` for the module call only.
- Add a `Spectre.Execution` workflow that:
  1. validates the executable effect;
  2. confirms the approved state is committed;
  3. invokes the action with its idempotency key;
  4. applies a completion or failure command;
  5. persists the terminal state;
  6. returns a `Result` or `Turn`.
- Add a session-aware execution API so hosts do not need a manual
  `Spectre.reset/2` after every action.
- Require durable idempotency at the application capability boundary.

Potential public shape:

```elixir
Spectre.execute(agent, approved_result, opts)
Spectre.execute(session, approved_turn, opts)
```

Keep `Spectre.execute(state, ctx, opts)` during a deprecation window.

Exit criteria:

- approval and terminal execution state have one documented commit workflow;
- sessions cannot retain an approved effect after it completed;
- stale or repeated execution returns the recorded terminal outcome.

### Phase 4: Harden Sessions And Recovery

Status: complete for the implemented state-adapter and Session contracts.

Goal: make one conversation safe across crashes and concurrent hosts.

- Add a monotonic `revision` separate from the serialized schema version.
- Support optimistic compare-and-swap in state adapters.
- Reject stale results and stale policy resolutions explicitly.
- Restore open awaitables and pending effects without replaying side effects.
- Define crash points before execution, during execution, and after execution.
- Add session execution serialization and recovery tests.
- Add telemetry for restore, conflict, retry, stale command, and idle shutdown.

Exit criteria:

- every crash point has a documented recovery path;
- two hosts cannot both advance the same state revision silently;
- session and stateless adapter behavior share the same transition contract.

### Phase 5: Add The Journal

Goal: make every important agent decision inspectable without storing sensitive
conversation content by default.

Status: complete for schema v1. Arbitration, policy, lifecycle, execution, and
persistence records, privacy defaults, redaction, retention metadata,
per-phase sampling, telemetry, strict mode, and bounded asynchronous delivery
are implemented.

- Add `Spectre.Journal.Record` with a versioned schema.
- Add `Spectre.Journal.Recorder` as the filtering and delivery boundary.
- Add the `Spectre.Journal.Store` behaviour with `append/2`.
- Add a `journal/2` DSL macro and equivalent application configuration.
- Emit records from canonical arbitration, lifecycle, policy, execution, and
  persistence boundaries.
- Record reason codes and structured evidence, not preformatted log strings.
- Add filtering, redaction, per-event sampling, and retention metadata.
- Add supervised asynchronous delivery with bounded buffering, explicit
  overflow policy, and backpressure.
- Define synchronous failure and transactional-outbox guidance for audit use.
- Add telemetry derived from the same records without making telemetry the
  durable source.
- Provide query examples for per-agent timelines and aggregate dashboards.

Exit criteria:

- one turn can be reconstructed as a decision timeline using correlation IDs
  and sequence numbers;
- route and policy outcomes can be explained without storing input or reply
  text;
- disabling or losing the default recorder cannot change runtime behaviour;
- strict recorder failures follow the explicitly configured policy;
- sensitive fields are absent unless the application opts in;
- the record schema has compatibility and migration tests.

### Phase 6: Clarify Routing And Arbitration Ownership

Goal: keep probabilistic evidence outside machine-state decisions.

Status: complete. Canonical threshold and precedence explanations are carried
by routing contexts and receipts; deterministic permutation tests and the
generated multi-strategy matrix cover ordering and precedence.

- Keep router plugs limited to evidence collection.
- Keep `Candidate` as an immutable evidence value.
- Make provider thresholds and agreement rules observable in arbitration traces.
- Define deterministic tie-breaking for equal candidates.
- Version semantic-cache entries and classifier artifacts.
- Keep unverified online examples quarantined until explicit review.
- Add property tests for candidate ordering and precedence.

Exit criteria:

- a router provider cannot mutate conversation state;
- every selected route explains its provider, score, threshold, and winning
  precedence;
- the same evidence set always produces the same decision.

### Phase 7: Reduce Optional Dependency Weight

Status: superseded by project decision. Vettore intentionally remains a small,
required dependency of Spectre.

Goal: let applications use the runtime without paying for every classifier
implementation.

- Keep core runtime, routing contracts, policies, and OTP sessions lightweight.
- Keep Vettore mandatory and keep external embedding engines such as
  `ex_fastembed` adapter-driven.
- Fail with clear configuration errors when an optional adapter is unavailable.
- Add minimal, classifier, and full-feature dependency profiles to CI.

Exit criteria:

- regex-only applications retain the same Vettore-backed runtime contract;
- external optional adapters have explicit compatibility versions.

### Phase 8: Stabilize The Public API

Status: complete for the `0.1.0` public preview. Compatibility remains governed
by Semantic Versioning's `0.x` rules and the documented public/internal module
boundary.

Goal: prepare a versioned release rather than exposing internal refactors.

- Publish lifecycle invariants and adapter behaviours.
- Add `@since` or changelog entries for public functions.
- Deprecate old APIs with migration examples before removal.
- Add upgrade fixtures for serialized state.
- Document supported Elixir, OTP, NIF, and adapter versions.
- Validate the package from consuming products such as `freelance.fast`; those
  product-specific fixtures remain in their own repositories.

Exit criteria:

- one canonical host integration path is documented in Getting Started;
- serialized state upgrades are tested through schema-v5 fixtures;
- release notes and a changelog policy are present;

## Recommended Implementation Order

The next concrete tickets should be:

1. Write the legal transition matrix.
2. Add forbidden-transition tests.
3. Introduce `Spectre.Transition` without changing callers.
4. Introduce `Spectre.Lifecycle.next/1` and delegate `Turn.Decision` to it.
5. Move policy accept, reject, and attempt exhaustion into lifecycle commands.
6. Move effect stage, complete, fail, and cancel into lifecycle commands.
7. Reduce `State` to data, migrations, and queries.
8. Split action invocation from completion mutation.
9. Design and implement session-aware execution persistence.
10. Add state revisions and stale-write protection.
11. Freeze `Spectre.Journal.Record` fields, privacy defaults, and reason codes.
12. Add the `Spectre.Journal.Store` behaviour and `journal/2` DSL.
13. Emit journal records from `Arbitration`, `Lifecycle`, and `Execution`.
14. Add asynchronous buffering, strict mode, and outbox documentation.
15. Run the `freelance.fast` compatibility fixture with journal monitoring.
16. Only then simplify or deprecate public APIs.

This order keeps each change reviewable and preserves the current host contract
while responsibility moves inward.

## Package Direction

Spectre should continue to sit in a small family of focused packages:

- `spectre_kinetic` owns Action Language extraction, tool registration, slot
  mapping, and planning.
- `spectre_lens` can provide browsing and retrieval capabilities through normal
  action adapters.
- `spectre_mnemonic` can provide recall and durable memory through the memory
  behaviour.
- `spectre_directive` can orchestrate multi-step goals above Spectre without
  turning one conversation turn into a workflow engine.

Spectre itself should own one thing well: a deterministic, inspectable, and
recoverable lifecycle for one agent conversation.
