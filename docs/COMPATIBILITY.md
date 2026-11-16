# Retained Instance/Run compatibility

Spectre 0.4 retains the Instance/Run runtime and its documented APIs for existing
applications. New AgentServer applications use a different owner, checkpoint and
GAM execution loop. Installing 0.4 does not automatically migrate an old effect
or convert a persisted checkpoint. Start with [Migration](MIGRATING_TO_0_4.md).

The compatibility guides remain in the repository under `docs/legacy/`. They are
kept out of the primary 0.4 guide navigation and package documentation.

## Find the contract for an existing application

| Concern | Retained guide |
| --- | --- |
| Earlier tutorial and ownership model | [0.3 tutorial](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/GETTING_STARTED_0_3.md), [architecture](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/ARCHITECTURE_0_3.md) |
| Instances, Runs and Work/Vigil | [Instances](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/INSTANCES.md), [Runs](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/RUNS.md), [Operations](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/OPERATIONS.md) |
| Canonical Definitions and activation | [Definitions](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/CANONICAL_DEFINITIONS.md), [Store](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/DEFINITION_STORE.md), [Identity](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/IDENTITY_ACTIVATION.md) |
| Governed definition changes and Skill state | [Governance](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/GOVERNANCE.md), [Skill state](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/SKILL_STATE.md), [Runtime Skills](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/RUNTIME_SKILLS.md) |
| Required receipts and legacy journal | [Receipts](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/RECEIPTS.md), [Journal](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/JOURNAL.md) |
| Deployment, ownership and offline erasure | [Production](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/PRODUCTION_0_3.md), [Data lifecycle](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/DATA_LIFECYCLE.md), [Erasure](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/ERASURE.md) |
| Adapter conformance and immutable formats | [Foundation](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/FOUNDATION_CONFORMANCE.md), [Testing](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/TESTING_0_3.md) |

[The archive index](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/README.md)
links earlier authoring guides and version-specific migrations. Apply historical
upgrade steps only to their stated source format. Keep immutable compatibility
fixtures unchanged and rehearse recovery with the same adapter contracts.

For current Server callbacks, storage, consent and diagnostics, use
[Server](AGENT_SERVER.md), [Managed GAM](MANAGED_GAM.md),
[Domain storage](DOMAIN_STORAGE.md) and [Production](PRODUCTION.md).
