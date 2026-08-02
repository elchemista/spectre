# Changelog

All notable changes to Spectre are documented in this file. The project follows
[Semantic Versioning](https://semver.org/); while the version is below `1.0`, a
minor release may contain documented breaking API changes.

## Unreleased

### Added

- `Spectre.Turn.Dispatcher` drives a `%Spectre.Turn{}` decision to a delivered
  outcome so hosts stop hand-writing the decision switch: it delivers replies,
  auto-resolves policies the host can already satisfy
  (`satisfied_resolution/2`), executes pending effects, and falls back to
  `fallback_reply/2`/`no_response/2` for empty outcomes. `deliver_reply/3` is
  the only required callback and the loop is bounded.
- `before_action :action, run: {M, :f}` registers a pre-execution guard on the
  action lifecycle. Guards run after routing, planning, and policy approval,
  and can return `{:suppress, reply_text}` to cancel the pending effect and
  answer with a normal reply (emitting `:effect_suppressed`), or `{:error,
  reason}` to fail closed. `:all` matches every action; Skills cannot declare
  guards; invalid guard replies fail the effect instead of allowing it.
- `history limit, summary: {M, :f}` folds chat-history entries evicted from
  the window into a rolling summary under `state.data.chat_summary` instead
  of dropping them. The default LLM classifier prompt shows the summary as
  "Conversation summary (older turns)" next to the recent chat, and custom
  classifier prompts receive it as the `chat_summary` assign. A crashing
  summarizer keeps the previous summary and never blocks the turn.

- `flow` declarations now nest. A nested flow is a taxonomy grouping: rules
  keep the full path in the new `Spectre.Rule.flow_path` field while `flow`
  stays the innermost name, labels stay globally unique, and `inject`
  declarations plus flow options are inherited by nested flows.
  `state.current_flow` now prioritizes by membership in `flow_path`, so
  setting a parent flow prioritizes its whole subtree. String flows passed to
  `Spectre.Router.evaluate/3` resolve nested flow names as well.
- The default LLM fallback classifier prompt groups visible labels by flow
  taxonomy (indented, one `flow/` header per group) instead of a flat list.
  Each label carries up to two example phrases from its `embedding:`/`bag:`/
  `jaro:` declarations (`classifier ..., label_examples: n` tunes the cap,
  `0` disables). The prompt now also states the routed agent module, an
  optional agent description (`classifier ..., context: "..."`), and the
  active `state.current_flow` rendered as its full nested path. Custom
  classifier prompt functions receive the new `label_tree`, `agent`,
  `agent_context`, and `active_flow` assigns, and the tree rendering is
  exposed as `Spectre.Router.LLMClassifier.label_tree/3`. Agents with no
  flows keep the flat label list.

- Added `SYSTEM.md`, documenting the 0.2.0 package compatibility matrix,
  composition patterns, complete Stack examples, library responsibilities,
  and the architectural rationale for a small core with explicit satellites.
- Directive Definitions can declare `can_start: [:work]` and return stable
  `start_loops` intents from `apply_result/4`; the parent Result, child Work,
  controls, correlations, and events commit atomically at one canonical
  revision. Re-proposing an intent whose Work already exists with the same
  parent and intent provenance is a committed no-op reported as
  `already_started: true`; only an id collision with different provenance
  rejects the transition.
- Definition security can opt into exact external-trigger fencing with
  `trigger_correlation: :required` or the compatible
  `require_trigger_correlation: true` spelling. Public loop views now expose
  `wait_ref`, and committed trigger events distinguish `:exact` from
  compatible `:legacy` correlation.
- Publication policy now controls progress and blocker projection
  independently with `publish_progress` and `publish_blocker`.

### Fixed

- A terminal outcome (failure, crash, completion, budget, expiry) that races a
  pending safe pause/update command now rejects that command with
  `:loop_terminal` inside the same committed transition, instead of leaving
  the loop permanently wedged behind an uncommittable control plane.
- Checkpoints taken between a committed Result and the advancement of a
  pending safe pause/update command are accepted on restart; recovery resumes
  the control sequence instead of stopping the Instance with
  `:operational_recovery_failed`.
- A retry allowed by policy but denied by an exhausted budget or a passed
  expiry now produces the typed `:budget_exhausted`/`:expired` outcome with
  limit and consumption, instead of a generic `:failed` outcome.
- Duplicate control commands re-arm the Instance idle timer like every other
  control reply.

### Changed

- Accepted uncorrelated 0.2.x triggers emit
  `[:spectre, :instance, :uncorrelated_operation_trigger]` telemetry so hosts
  can migrate before correlation becomes strict by default in 0.3.0. The
  telemetry now also covers legacy triggers delivered through durable
  `:trigger` control commands, not only direct trigger calls.
- Documented the fixed replay and retention windows: 512 canonical journal
  transitions, 1,024 applied change ids, 128 completed control commands per
  loop, and 512 committed operational events.
- Cognitive operations must declare a closed `domain` or an `output`
  validator; a spec with neither is rejected as
  `{:unbounded_cognitive_operation, id}`.
- Documented the `reason`, `act` and `work` Flow verbs and the deprecation
  path of the legacy `ask` verb in the DSL and migration guides.

### Safety

- Work starts attempted directly by any operational Runner, including through
  the isolated executor call boundary, are rejected; only Agent-side Directive
  reducer intents can create Work from an operational transition.

## 0.2.0 — 2026-07-31

### Added

- Added versioned `Spectre.Work` and `Spectre.Vigil` Definitions on one shared
  operational runtime, plus support for authorized external controllers.
- Added a closed operation catalog for registered functions, Actions, Effects,
  planners, and finite-domain cognitive operations.
- Added temporary one-attempt Runners under dynamic supervision, with Agent
  ownership, epoch and fencing validation, progress throttling, timeout,
  retry, crash recovery, and side-effect reconciliation.
- Added durable pause, update, update-and-resume, resume, renew, stop, and
  trigger commands with revision, provenance, and idempotency checks.
- Added typed budgets and terminal outcomes for completion, cancellation,
  expiry, failure, budget exhaustion, and ambiguous external outcomes.
- Added read-only loop views, deterministic selectors, visibility checks,
  committed operational events, local subscriptions, and optional routing of
  selected events through normal Flow handling.
- Added selective post-commit operation memory and artifact publication
  policies.
- Added consent, revocation, destination policy, deduplication, rate limits,
  quiet hours, digest decisions, and durable delivery receipts without moving
  transport I/O into core.
- Added typed canonical sections for Flow, Work, Vigil, external controllers,
  loop control, correlations, and committed events.
- Added authorized read/write snapshots, section-fenced change sets,
  monotonic commits, deterministic stale-conflict rejection, idempotent change
  identifiers, and a bounded transition journal.
- Added a strict portable checkpoint codec that preserves canonical and
  per-section revisions, correlations, transition history, and applied-change
  receipts across restart.
- Added a compare-and-swap checkpoint store boundary, asynchronous coalesced
  persistence, flush/status APIs, and explicit reconciliation after an
  ambiguous write outcome.
- Added an executable full-system Agent fixture covering Flow-started Work,
  conversational inspection and update, Vigil registration and control,
  operational-event routing, failure isolation, and joint checkpoint recovery.

### Changed

- `Spectre.Instance` is now the sole local owner of both conversational and
  operational canonical state for one `AgentRef + Subject`.
- Explicit operation idempotency keys now survive Action and Effect dispatcher
  boundaries.
- Generic map input without a `text` field is retained as raw structured input
  with empty text instead of raising through `String.Chars`.
- Agent Definitions can register application operations and opt selected
  committed operation events back into the normal Flow router.
- Agent Definition validation now accepts every public route handler supported
  by the DSL and Runner, including `reason/2`, `act/2`, and `work/2`.

### Safety

- Canonical restore validates loop/control correspondence, Definition
  compatibility, event revisions, Subject ownership, correlations, consent,
  delivery receipts, and portable values before the Instance starts.
- Stale, duplicate, foreign-epoch, wrong-fence, wrong-generation, and
  semantically invalid Runner messages are rejected before commit.
- Unknown non-idempotent side-effect outcomes are never retried automatically.
- Runtime values never create atoms from untrusted strings; closed decoders use
  existing atoms only. Ordinary atom serialization continues to use
  `Atom.to_string/1`.

### Compatibility

- `Spectre.State`, `Spectre.Run`, Flow, Effect, Invocation, Session, and Turn
  keep their 0.1.6 roles. Work is a separate operational domain and does not
  rename Run.
- State v5 and Run v1 recovery fixtures remain permanent compatibility tests.
- See `docs/MIGRATING_TO_0_2.md` for canonical checkpoint adapters and
  incremental operational adoption.

## 0.1.6 — 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and uniform release documentation.
- Added no runtime functionality and made no intentional breaking API change.

## 0.1.5 — 2026-07-30

### Added

- Per-Run lifecycle ownership inside `Spectre.Instance`: staged Effects and
  policy Awaitables now carry their owning `run_id`, allowing several retained
  Runs to wait independently on policy or execution boundaries.
- Conversation-aware policy resumption selects the matching Run from channel
  origin metadata. The legacy no-origin shortcut remains available when
  exactly one policy boundary is open; ambiguous input fails closed.
- State schema v5 persists Run ownership and supports bounded collections of
  independent pending Effects and Awaitables. Schema v2-v4 snapshots remain
  readable and legacy unowned lifecycle is claimed by its first Instance Run.
- `Spectre.Context.lifecycle_run_id/1` and `Spectre.Effect.bind_run/2` give
  extension-owned Effect builders the same per-Run lifecycle contract used by
  core Actions.

### Compatibility

- Stateless calls and conversation-scoped `Spectre.Session` keep their
  single-lifecycle behavior; Run ownership is enabled only by
  `Spectre.Instance`.
- Capability execution remains serialized by the Instance state lock. Calls
  arriving during an Invocation stay queued and continue from the latest
  committed State after the capability returns.
- Prism and ordinary provider callbacks remain synchronous inside one bounded
  Move worker. Generic provider Invocations still require a later serializable
  mid-turn continuation.

### Fixed

- A policy or Effect boundary owned by one Run no longer rejects unrelated
  Runs with `:instance_lifecycle_locked`.
- Resuming a retained Run rebases it onto the latest shared Instance State
  without losing other Runs' pending lifecycle or rolling persistence
  revisions backward.
- Policy acceptance, rejection, retry exhaustion, and Effect execution now
  mutate only the explicitly owned lifecycle entries.

## 0.1.4 — 2026-07-30

### Added

- Subject-scoped `Spectre.Instance` processes keyed by the portable
  `Spectre.AgentRef + Spectre.Subject` pair, with race-safe lookup and
  get-or-start through the application Registry.
- An Instance-owned multi-Run scheduler with a deduplicated FIFO ready queue,
  one mailbox-scheduled Move at a time, retained Run projections, bounded
  terminal tombstones, and first-boundary `Spectre.Turn` replies.
- A stable opaque `AgentRef + Subject` state scope plus privacy-safe tracking
  of multiple channel conversation origins within the same Instance.
- Correlated in-flight Effect/Action Invocation workers and internal
  `Spectre.Invocation.Receipt` fencing across Instance generation, Run
  revision, Invocation id, and dispatch id. Foreign, stale, duplicate, and
  late receipts cannot mutate Instance state.
- `Spectre.ExternalIdentity`, `Spectre.LinkIntent`, `Spectre.SubjectLink`, and
  `Spectre.Subject.Registry` for explicit Agent-scoped identity resolution,
  bounded one-time challenges, optional source confirmation, conflict
  rejection, revocation, and privacy-safe Journal commits.
- Public `Spectre.instance/4`, `lookup_instance/3`, and `resume/4` APIs.
  `Spectre.summon/1,3` select the Instance runtime when an explicit `:subject`
  is supplied.

### Compatibility

- Conversation-scoped `Spectre.Session` remains available unchanged when
  `:subject` is omitted.
- Ordinary user input resumes the exact policy-owning Run. Effect execution
  remains an explicit Invocation boundary.
- The single active Effect constraint remains on global `Spectre.State` in
  this release. Instance serializes that lifecycle boundary; moving it onto
  each Run is the next lifecycle phase.
- Prism and ordinary provider calls remain synchronous inside one bounded Move
  worker. The Instance mailbox stays responsive, but ready Runs wait for that
  Move or its provider timeout; generic provider Invocations require a later
  serializable mid-turn continuation.

### Fixed

- Run start, normalization, and initial scheduling no longer block the
  Instance GenServer or observe stale committed State.
- Duplicate and failed Run starts cannot overwrite retained Runs or exhaust
  bounded capacity; terminal history and tombstones remain bounded.
- Internal reply completion cannot roll shared Instance State back after
  another Run commits.
- Queued callers are released if another Run opens the global lifecycle lock,
  and abnormal workers fail only their fenced Run.
- Portable-value validation rejects improper lists without crashing the
  Subject Registry.

## 0.1.3 — 2026-07-29

### Added

- A serializable `%Spectre.Run{}` continuation and the closed
  `Runtime.start/3 -> advance/2 -> resume/3` protocol.
- Revision-fenced `Spectre.Run.Ref`, `Spectre.Run.Boundary`, and
  `Spectre.Invocation` values, plus transport-safe `Spectre.Run.Request`
  policy projections.
- Versioned, atom-free Run checkpoint/restore with raw-envelope stripping,
  typed logical Route projection, lifecycle validation, encoded-size limits,
  and fail-closed rejection of PID, Port, reference, and function values in
  authoritative data.
- A public `Spectre.Turn` projection with `ref`, `boundary`, and `observable`
  fields using the closed reply/awaiting/needs vocabulary; transport
  idempotency can use `Spectre.Run.Ref.token/1`.
- Privacy-safe Run lifecycle journal events, selectable with `events: [:run]`.
- An ordered, optional `Spectre.Turn.Handler` boundary for external
  conversational runtimes. Open Spectre policies retain precedence; typed
  replies cannot replace state, routes, effects, or awaitables; failures and
  timeouts fail closed.
- Integration guidance that defines `Spectre.turn/3` as the canonical local
  host contract while keeping input decoding, Skills, memory, actions,
  pre-route ownership, telemetry/journaling, durable workflows, and
  agent-protocol transport on separate extension surfaces.

### Fixed

- Semantic-cache collection cleanup now follows Vettore 0.3.2's dedicated
  supervised ETS ownership model.
- Accepted exact semantic-cache hits now skip later vector search, and built-in
  semantic search loads persisted row embeddings instead of issuing one remote
  embedding request per cached row. Classifier training and cache snapshots
  persist the vectors needed for request-time lookup, and online learning
  reuses the query vector instead of embedding the same input twice.
- Semantic-cache index processes now terminate with their cache owner, so an
  owner restart cannot leave orphaned Vettore collections behind.
- Invoked state callbacks that crash, exit, throw, are killed, time out, or
  return malformed results are now treated as ambiguous writes. Sessions retain
  the candidate state until durable reconciliation instead of silently moving
  back to the previous revision.
- Strict persistence-journal failures now carry the already committed result,
  and Sessions retain it so an audit outage after compare-and-set cannot cause
  state rollback or duplicate work on the old revision.
- The application supervisor now tolerates a bounded burst across cache and
  journal children instead of stopping the whole `:spectre` application while
  those independent workers are being restarted.

## 0.1.2 — 2026-07-28

### Added

- `Spectre.Stack` with package-local install DSL, immutable compiled
  definitions, dependency ordering, compatibility/conflict validation, and
  deterministic manifest digests.
- Versioned `Spectre.Stack.Installable` and
  `Spectre.Stack.Contract.V1` contracts for ecosystem packages.
- Logical, version-fenced `Spectre.Stack.Ref` values and caller-owned runtime
  supervision for explicitly declared resources.
- Logical `stack:` references on Agent definitions, resolved only when the
  Stack is used, with compile-time rejection of Skill-owned infrastructure.
- Explicit legacy adapters for `Spectre.Extension.Mount` and
  `Spectre.Action.Provider.Mount`.

### Security and behavior guarantees

- Package manifests and compiled configuration reject PID, port, reference,
  and function values.
- Installed Actions are not automatically exposed to the Agent planner or
  authorized for execution.
- Stack runtimes have no default global name, and stale resource Refs cannot
  resolve against another definition.

## 0.1.0 — 2026-07-20

First public preview.

### Added

- OTP-native Agent and Skill DSL with flows, interrupts, input pipelines,
  prompt injection, actions, policies, mounted skills, state, memory, journal,
  classifier, embedding, and session configuration.
- Evidence-based routing through regex, bag distance, Jaro distance,
  embeddings, local classifiers, exact and vector semantic cache, LLM
  classification, and deterministic arbitration.
- A canonical lifecycle kernel for staging, approving, rejecting, cancelling,
  expiring, completing, failing, and replaying effects and awaitables.
- Explicit two-boundary action execution: policy approval changes state;
  `Spectre.Execution` invokes the host capability only after the approved state
  can be committed.
- Optimistic state revisions, versioned state codecs, stale-session protection,
  idempotent terminal replay, and explicit ambiguous-persistence results.
- Pure policy matching shared by user input and trusted host resolutions.
- Structured prompt plans that preserve instruction, context-data, and task
  trust through capable model adapters, with a marked legacy string format.
- Built-in learned semantic cache backed by Vettore, including online review,
  verification, relabel, deletion, snapshot, restore, bounded index ownership,
  and optional local FastEmbed integration.
- Versioned, privacy-safe journal records for arbitration, policies, lifecycle,
  execution, and persistence, with redaction, sampling, retention metadata,
  synchronous or buffered delivery, and configurable failure policy.
- Privacy-safe provider boundaries with timeouts, worker cancellation,
  normalized failures, fallback models, telemetry, and route-evaluation
  receipts.
- Routing evaluation APIs and Mix tasks for datasets, classifier training,
  model download, and CI evaluation reports.
- Ten-agent strategy matrix covering 800 routing scenarios, including 600
  malformed, unmatched, invalid-flow, invalid-pipeline, and corrupted-state
  cases. The full suite contains 1,177 passing tests and exceeds 90% line
  coverage.

### Security and behavior guarantees

- Policy acceptance cannot be supplied by an ordinary classifier route while a
  policy awaitable is open.
- A `:waiting_policy` effect is never executable.
- Dynamic prompt providers may write only trusted-as-data context fragments.
- Prompt and state deserialization reject unknown or unsafe runtime values.
- Journal, telemetry, evaluation receipts, and provider failures omit raw
  prompts, model output, effect arguments, and stack traces by default.

### Compatibility

- Requires Elixir `~> 1.19`.
- Vettore is a required dependency.
- ExFastembed and SpectreKinetic integrations are optional and detected or
  configured by the host application.
