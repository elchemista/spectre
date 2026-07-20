# Changelog

All notable changes to Spectre are documented in this file. The project follows
[Semantic Versioning](https://semver.org/); while the version is below `1.0`, a
minor release may contain documented breaking API changes.

## Unreleased

No unreleased changes.

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

