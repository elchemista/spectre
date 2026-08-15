# Security Policy

Spectre is a runtime boundary, not an authorization system. Applications must
still authenticate users, authorize business operations, protect credentials,
and validate data inside their action and provider adapters.

## Supported versions

Security fixes are released for the latest supported `0.x` minor version.
Users should upgrade to the newest patch before reporting a problem already
addressed in the changelog.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories for
`elchemista/spectre`. Include:

- the affected Spectre version and Elixir/OTP versions;
- a minimal reproduction;
- the expected and observed security boundary;
- whether untrusted input, a model/provider reply, or persisted state is
  required to trigger it;
- any known mitigation.

Do not include real prompts, user conversations, credentials, or production
state in a report.

## Boundary model

Spectre enforces deterministic lifecycle and policy transitions, isolates
provider callbacks, validates persisted state, and keeps side-effect execution
explicit. It does not claim that an LLM is immune to prompt injection. Dynamic
content is marked as data at the prompt-plan boundary, but downstream model
behavior remains probabilistic.

### Prompt assets and untrusted data

Canonical prompt fragments use a closed placeholder grammar and typed renderer
references; runtime data cannot select executable code. Legacy `.text.heex`
assets remain compiled application code. Interpolate `@input`, `@recent_chat`
and `@memory` only through `Spectre.Prompt.data/1`, and treat an unsafe finding
from `mix spectre.doctor --strict` as a release blocker. The audit is a bounded
static check, not proof that arbitrary EEx is safe.

Completed Action and Effect outputs are untrusted prompt data even when their
transport was authenticated. Preserve their origin across assigns or memory
with `Spectre.Effect.prompt_result/1`; canonical materialization unwraps the
value for rendering and retains its trust, provenance and authenticity on the
typed fragment. Passing only `effect.result` intentionally loses that lineage
and never upgrades the value to instruction trust.

### Model-selected Action arguments

When an Action schema declares a JSON-Schema validation keyword, Spectre
validates the schema and arguments at both planning and provider execution.
Unsupported constraints fail closed instead of being ignored. The supported
subset is deliberately bounded by depth, schema size, property/branch count
and regular-expression limits. Application adapters must still authorize
business objects and enforce tenant ownership; schema validity is not
authorization. JSON Schema intentionally permits undeclared keys when
`additionalProperties` is omitted; `mix spectre.doctor --strict` warns when a
planner-visible action is unconstrained or does not explicitly close that
surface with `additionalProperties: false`.

### Streaming capabilities

An inference stream handle is a live bearer capability. Its custom inspection
hides the consumer token, but applications must not serialize, persist, log,
publish or return the handle to an untrusted client. Raw deltas are provisional
and may precede complete-response policy and sanitization. Only the terminal
`:result` event is a committed Agent result.

The data lane is single-consumer and revision/epoch fenced. Push adapters must
bound their transport before the session mailbox. Provider request ids, resume
cursors, raw failures and credentials stay in confidential runtime/recovery
state and must not enter observer events or public receipt payloads.

### Boundary receipts

Receipt envelopes are validated portable evidence, not automatically safe log
records. Confidential payloads require encryption, tenant isolation, access
control and retention enforcement in the configured sink. Required receipt
mode also depends on a durable checkpoint store and idempotent payload-capable
sink; the in-memory adapters are for tests and development only.

See [Architecture](docs/ARCHITECTURE.md), [Provider Resilience](docs/PROVIDERS.md),
[Streaming inference](docs/STREAMING_INFERENCE.md),
[Boundary receipts](docs/RECEIPTS.md), and
[Production Operations](docs/PRODUCTION.md) for the complete trust model.
