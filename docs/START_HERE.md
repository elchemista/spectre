# Spectre 0.4.2 documentation

The application model is **Stack → Agent → Server**. GAM governs the operations
the host declares consequential. Existing 0.3 applications start with
[Migration](MIGRATING_TO_0_4.md).

## First steps

1. [Installation](INSTALLATION.md): dependencies, source pins and supervision.
2. [Getting started](GETTING_STARTED.md): generate an Agent/Server and receive a reply.
3. [Follow a complete input](HANDLER_WALKTHROUGH.md) from route to consumer and try both consent choices.
4. [Look up a Server callback](SERVER_CALLBACKS.md) by event, input and return.
5. [Architecture](ARCHITECTURE.md): process ownership, commands and authority.
6. [Routing](ROUTING.md): choose and combine recognition strategies.
7. [Managed GAM](MANAGED_GAM.md): configure effects, identity and human consent.

## Build your application

| Task | Guide |
| --- | --- |
| Recognize input and train classifiers | [Routing](ROUTING.md), [Training](TRAINING.md), [Evaluation](EVALUATION.md) |
| Implement custom providers and adapters | [Behaviours and adapters](BEHAVIOURS.md) |
| Implement callbacks and asynchronous work | [Callback reference](SERVER_CALLBACKS.md), [Server](AGENT_SERVER.md), [API](API.md), [DSL](DSL.md) |
| Combine open chat with supervised work | [Chat and Directive](../README.md#open-chat-with-directive-missions), [Activities](AGENT_SERVER.md#run-a-background-activity), [Runnable examples](EXAMPLES.md) |
| Add your billing client | [Read a draft and issue it after approval](CUSTOM_STACK_TOOLS.md) |
| Author a reusable library or install a package | [Integration API](STACK.md#typed-package-integrations), [Stack tools](STACK_TOOLS.md), [Integration boundaries](INTEGRATIONS.md) |
| Run reusable Skill servers | [Skills](SKILLS.md) |
| Prepare and confirm operations | [Actions](ACTIONS.md), [Pending lifecycle](PENDING_LIFECYCLE.md) |
| Ask a human through another agent | [External approval](EXTERNAL_APPROVALS.md) |
| Store history and application content | [Domain storage](DOMAIN_STORAGE.md), [Payload storage](PAYLOAD_STORAGE.md), [Memory](MEMORY.md) |
| Stream model output and configure providers | [Streaming](STREAMING_INFERENCE.md), [Providers](PROVIDERS.md) |
| Integrate a UI or another process | [Integrations](INTEGRATIONS.md), [Examples](EXAMPLES.md), [Demo](DEMO.md) |
| Inspect runtime behavior | [Diagnostics](DIAGNOSTICS.md), [Server contracts](SERVER_CONTRACTS.md) |
| Test and deploy | [Testing](TESTING.md), [Production](PRODUCTION.md), [Profiling](OTP_PROFILE_0_4.md) |

## Mix tasks

Run these inside your Mix project after adding Spectre. Replace `MyApp.Agent`
or `MyApp.Documents` with a module in your application. Use
`mix help TASK` for each command's flags.

| Task | Inputs and what it does |
| --- | --- |
| `mix spectre.gen.agent MyApp.Agent --server` | Generates Agent and Server modules and a test. `--server` selects the AgentServer architecture. Preview file paths with `--dry-run`. |
| `mix spectre.gen.installable MyApp.Documents` | Creates a Stack-installable module and a test that compiles its bindings in a Stack. |
| `mix spectre.doctor --agent MyApp.Agent --strict` | Validates the compiled Agent, Server and Stack contracts. Strict mode fails on warnings. Use `--format json` for automation. [Diagnostics](DIAGNOSTICS.md). |
| `mix spectre.routes MyApp.Agent --json` | Lists declared routes, eligible scopes and handler destinations. `--json` switches from terminal text to machine-readable output. |
| `mix spectre.eval MyApp.Agent test/fixtures/routes.jsonl` | Runs a labeled routing fixture. The result checks the expected route and classifier policy. [Evaluation](EVALUATION.md). |
| `mix spectre.intent_dataset.export MyApp.Agent priv/intents.jsonl` | Writes reviewed examples to JSONL. Use `--source all` to include declared or offline examples and `--include-unverified` to include unreviewed rows. |
| `mix spectre.intent_dataset.embed MyApp.Agent input.jsonl vectors.jsonl` | Uses the Agent's configured embedder to create an offline vector dataset from labeled rows. |
| `mix spectre.classifier.dataset MyApp.Agent training/dataset.json` | Exports labeled inputs for the local classifier. Add `--source FILE` for extra rows. |
| `mix spectre.classifier.train training/dataset.json artifacts/spectre` | Trains local classifier artifacts from the prepared dataset. `mix spectre.classifier.download_model` prepares the configured model. [Training](TRAINING.md). |

The retained Instance runtime also has `mix spectre.gen.checkpoint_store` and
`mix spectre.profile`. For AgentServer persistence, implement
`Spectre.Server.Store`. For measuring AgentServer workloads, use the Activity
and Domain probes. [Storage](DOMAIN_STORAGE.md), [Profiling](OTP_PROFILE_0_4.md).

[GAM](GAM.md) explains the authority model. [Public API](PUBLIC_API.md) lists the
supported surface; [Changelog](../CHANGELOG.md) records version changes.
[Compatibility](COMPATIBILITY.md) indexes the retained Instance/Run runtime and
historical migrations. [Application authoring reference](../LLMS.md) summarizes
the contracts for code generation.
