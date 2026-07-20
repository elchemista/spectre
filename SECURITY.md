# Security Policy

Spectre is a runtime boundary, not an authorization system. Applications must
still authenticate users, authorize business operations, protect credentials,
and validate data inside their action and provider adapters.

## Supported versions

During the public-preview period, security fixes are released for the latest
`0.x` minor version. Users should upgrade to the newest patch before reporting
a problem already addressed in the changelog.

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

See [Architecture](docs/ARCHITECTURE.md), [Provider Resilience](docs/PROVIDERS.md),
and [Production Operations](docs/PRODUCTION.md) for the complete trust model.

