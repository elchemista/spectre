# The Spectre system

Spectre separates recognition, application coordination and authority:

```text
Stack → Agent routing → Server callbacks → worker commands → results
                              ├─ start → Activity callbacks → worker commands
                              └─ proposal → shared GAM → effect adapter → Outcome
```

| Component | Responsibility |
| --- | --- |
| Stack | Installed packages, provider bindings and supervised runtime resources. |
| Agent | Routes, recognition examples, classifiers and router configuration. |
| Server callback module | Business behavior, continuations and native OTP callbacks. |
| Server Runtime | Conversation GenServer, commands, pending work, streams and checkpoints. |
| Skill Server | Independent mounted runtime sharing the root GAM boundary. |
| Activity | On-demand supervised work with its own state, execution reference and revision. |
| GAM Domain | Canonical governed facts, authority verification and ordered admission. |
| Host adapters | Authentication, concrete effects, storage and provider reconciliation. |

The Runtime and Domain are different owners. Server coordination records and
canonical GAM history have different purposes even when stored in one Repo.
Models propose; authenticated principals hold authority. Admission precedes
capability release, while external observations determine Outcomes and Duties.

The Root keeps serving chat while Activities wait or run. A consumer targets
an Activity by execution reference, can send a revision or cancel it, and
receives lifecycle events for its decisions. A question uses a wait identity.
A human decision uses the exact GAM presentation identity.

[Architecture](docs/ARCHITECTURE.md) explains the process tree and execution loop.
[Managed GAM](docs/MANAGED_GAM.md) covers application configuration;
[Stack tools](docs/STACK_TOOLS.md) covers package integration.
[Domain storage](docs/DOMAIN_STORAGE.md) and [Payload storage](docs/PAYLOAD_STORAGE.md)
cover persistence without imposing a content backend.

Start new applications with [Getting started](docs/GETTING_STARTED.md). Existing
Instance/Run applications use [Migration](docs/MIGRATING_TO_0_4.md) and the
[compatibility reference](docs/COMPATIBILITY.md).
