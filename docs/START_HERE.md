# Start here: Spectre 0.4

This checkout documents the unreleased `0.4.0` AgentServer development line.
Its primary path is **Stack → Agent → Server → GAM for governed consequences**.
For an existing 0.3 application, begin with [Migration](MIGRATING_TO_0_4.md).

## Learn in this order

1. [Installation](INSTALLATION.md): compatible development branches, requirements
   and application supervision.
2. [Getting started](GETTING_STARTED.md): a runnable agent, callback results and
   the path to models and tools.
3. [Architecture](ARCHITECTURE.md): ownership, command execution, streaming and
   the boundary between recognition and authority.
4. [GAM](GAM.md): the imported kernel, consent, outcomes and host responsibilities,
   with the [manifesto](https://spectre.guide/en/governed-act-model).
5. [Agent and Server](AGENT_SERVER.md): callbacks, services, context and recovery.
6. [Stack tools](STACK_TOOLS.md): generated helpers and package-author contracts.

## Find a specific answer

| Task | Guide |
| --- | --- |
| Recognize intent and handle unmatched input | [Routing](ROUTING.md) |
| Collect intent examples and train a classifier | [Training](TRAINING.md) |
| Generate text and turn consolidated AL into proposals | [Actions](ACTIONS.md) |
| Suspend, resume or expire an open consent | [Pending lifecycle](PENDING_LIFECYCLE.md) |
| Browse, contact people and remember results | [Examples](EXAMPLES.md) and [nine-package test application](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md) |
| Inspect callback and helper APIs | [API](API.md), [DSL](DSL.md), `Spectre.Server` |
| Give an AI coding assistant the correct contracts | [LLMS](../LLMS.md) |
| Understand what changed | [0.4 migration](MIGRATING_TO_0_4.md), [Changelog](../CHANGELOG.md) |

## Compatibility documentation

The repository still contains APIs for the earlier Instance/Run architecture.
They remain useful for existing applications and do not describe an automatic
GAM migration. The [0.3 tutorial](GETTING_STARTED_0_3.md) and
[0.3 architecture](ARCHITECTURE_0_3.md) preserve that context. Guides specifically
about Instances, Runs and their checkpoint formats apply to that runtime; use
[Agent and Server](AGENT_SERVER.md) for Server checkpoints and execution.
