# Roadmap

Spectre 0.4 establishes Stack → Agent → Server as the application model, with
GAM governing declared effects. The current implementation includes:

- Native OTP callbacks, worker commands, streaming and durable continuations.
- Installed-tool helpers and registered effect adapters.
- Parallel Skill servers sharing the root GAM Domain.
- Local and transport-independent external human approval.
- Ledger-backed canonical history, per-record Domain projections and explicit
  recovery policy, while retaining RAM-only operation.
- Application-owned payload storage and authorized diagnostics.

The implemented contracts are described in [Architecture](ARCHITECTURE.md),
[Managed GAM](MANAGED_GAM.md) and [Migration](MIGRATING_TO_0_4.md).
[Release checks](RELEASE_0_4.md) describes how to verify a candidate.

## Planned 0.4.1 work

The [0.4.1 implementation plan](https://github.com/elchemista/spectre/blob/0.4.1/docs/PLAN_0_4_1.md)
covers Stack-installed runtime components, router and conversational continuations, background missions,
Directive's reusable driver, and the AgentServer evolution bridge for
`spectre_morph`. It records the proposed public contracts, remaining design
decisions, compatibility requirements and acceptance tests. These capabilities
are planned work, not features already provided by 0.4.0.

## Compatibility and future changes

Instance/Run remains a supported compatibility runtime. Any future removal or
persisted-format change needs an explicit migration and versioned contract.
See [Compatibility](COMPATIBILITY.md).

Production adapters, remote services and application retention policies remain
host choices. Further work should follow measured workloads and concrete
integration requirements. Historical milestones are in [Changelog](../CHANGELOG.md).
