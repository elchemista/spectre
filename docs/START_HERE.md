# Spectre 0.4 documentation

The application model is **Stack → Agent → Server**. GAM governs the operations
the host declares consequential. Existing 0.3 applications start with
[Migration](MIGRATING_TO_0_4.md).

## First steps

1. [Installation](INSTALLATION.md): dependencies, source pins and supervision.
2. [Getting started](GETTING_STARTED.md): generate an Agent/Server and receive a reply.
3. [Architecture](ARCHITECTURE.md): process ownership, commands and authority.
4. [Routing](ROUTING.md): choose and combine recognition strategies.
5. [Managed GAM](MANAGED_GAM.md): configure effects, identity and human consent.

## Build your application

| Task | Guide |
| --- | --- |
| Recognize input and train classifiers | [Routing](ROUTING.md), [Training](TRAINING.md), [Evaluation](EVALUATION.md) |
| Implement custom providers and adapters | [Behaviours and adapters](BEHAVIOURS.md) |
| Implement callbacks and asynchronous work | [Server](AGENT_SERVER.md), [API](API.md), [DSL](DSL.md) |
| Install package helpers and effects | [Stack tools](STACK_TOOLS.md), [Stack](STACK.md) |
| Run reusable Skill servers | [Skills](SKILLS.md) |
| Prepare and confirm operations | [Actions](ACTIONS.md), [Pending lifecycle](PENDING_LIFECYCLE.md) |
| Ask a human through another agent | [External approval](EXTERNAL_APPROVALS.md) |
| Store history and application content | [Domain storage](DOMAIN_STORAGE.md), [Payload storage](PAYLOAD_STORAGE.md), [Memory](MEMORY.md) |
| Stream model output and configure providers | [Streaming](STREAMING_INFERENCE.md), [Providers](PROVIDERS.md) |
| Integrate a UI or another process | [Integrations](INTEGRATIONS.md), [Examples](EXAMPLES.md), [Demo](DEMO.md) |
| Inspect runtime behavior | [Diagnostics](DIAGNOSTICS.md), [Server contracts](SERVER_CONTRACTS.md) |
| Test and deploy | [Testing](TESTING.md), [Production](PRODUCTION.md), [Profiling](OTP_PROFILE_0_4.md) |

[GAM](GAM.md) explains the authority model. [Public API](PUBLIC_API.md) lists the
supported surface; [Changelog](../CHANGELOG.md) records version changes.
[Compatibility](COMPATIBILITY.md) indexes the retained Instance/Run runtime and
historical migrations. [Application authoring reference](../LLMS.md) summarizes
the contracts for code generation.
