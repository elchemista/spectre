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

## Compatibility and future changes

Instance/Run remains a supported compatibility runtime. Any future removal or
persisted-format change needs an explicit migration and versioned contract.
See [Compatibility](COMPATIBILITY.md).

Production adapters, remote services and application retention policies remain
host choices. Further work should follow measured workloads and concrete
integration requirements. Historical milestones are in [Changelog](../CHANGELOG.md).
