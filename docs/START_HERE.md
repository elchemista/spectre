# Start Here

Spectre is an OTP-native runtime for agents whose routing, state, policies,
durability, and side effects remain explicit. This page is the shortest path
from a new Mix project to a correct mental model of the runtime.

## Your first path

Read these four pages in order:

1. [Overview](../README.md) explains what Spectre is, when it fits, and the
   safety boundary it preserves.
2. [Installation](INSTALLATION.md) adds the stable package, formatter metadata,
   and read-only diagnostics.
3. [Getting Started](GETTING_STARTED.md) builds an Agent and follows one turn
   through routing, policy approval, and explicit host execution.
4. [Architecture](ARCHITECTURE.md) establishes ownership, trust boundaries,
   Runs, Instances, and the separation between conversational and operational
   work.

Do not start with every extension or durable subsystem. A deterministic local
turn is enough to learn the public boundary; add persistence and integrations
only when the application needs them.

## Continue by goal

| Goal | Continue with |
| --- | --- |
| See complete applications | [Two Realistic Agents](EXAMPLES.md) |
| Choose routes and stage side effects | [Routing](ROUTING.md) and [Actions](ACTIONS.md) |
| Own durable subject state | [Agent Instances and Subjects](INSTANCES.md), then [Resumable Runs](RUNS.md) |
| Run long or recurring procedures | [Work, Vigil, and the Operational Runtime](OPERATIONS.md) |
| Deploy and verify a release | [Production Operations](PRODUCTION.md) and [Testing](TESTING.md) |
| Integrate another package or host runtime | [Integration Boundaries](INTEGRATIONS.md) and [Stack](STACK.md) |
| Look up functions and compatibility | [Public API](API.md) and the [Public API Manifest](PUBLIC_API.md) |
| Upgrade an existing application | Read the [current release notes](../CHANGELOG.md), then the relevant [migration guide](MIGRATING_TO_0_3.md) |

The [guide for LLMs and coding agents](../LLMS.md) is a separate,
machine-oriented contract. Human readers should follow the path above first.
