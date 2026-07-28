# Changelog

All notable changes to Spectre are documented in this file. The project follows
[Semantic Versioning](https://semver.org/); while the version is below `1.0`, a
minor release may contain documented breaking API changes.

## Unreleased

### Added

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
