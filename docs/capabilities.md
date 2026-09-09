# What Spectre provides—and what you provide

Spectre is a library for building governed agents. It is not a hosted agent
service, a model provider or a complete application.

This page separates three things:

1. features implemented in this checkout;
2. responsibilities deliberately left to your application;
3. limitations of the current library implementation.

Those are not the same kind of “missing feature.”

## Available now

### Write an agent

You can write an Agent with ordinary callbacks and add only the pieces you need:

- **Flows and routing:** regex, string-bag, Jaro and custom methods.
- **Prompts:** inline text or compiled EEx files, with named injections.
- **Skills:** reusable behavior and local substate inside an Instance.
- **Stacks:** reusable declarations and adapter choices.
- **Workers and Vigils:** reusable handlers with explicit governed work/watch
  openings. The host chooses when to start and trigger them.
- **Morph:** prepare, compare and roll back Definition data through a new
  forward revision. Activation is a separate governed action.

[Start with one Agent](agents-and-dsl.md), or
[choose a recipe](agent-recipes.md) for your kind of input.

### Connect services

Spectre provides adapter contracts for authentication, input normalization,
request preparation, execution, credentials, History, Memory and storage.

Optional packages can contribute configuration and ports through
`Spectre.Extension`. `install` does not install a Mix dependency or start a
service.

The semantic cache is an ordinary Router method. Exact search is available
without an encoder. The Vettore adapter is included, but the host adds its
optional native dependency and supplies previously obtained embeddings.

History and Memory return bounded, source-linked context. They are not a
bundled chat database or an unrestricted replacement for the authority ledger.

See [adapter configuration](configuration.md#connecting-adapters).

### Govern the operation

The implemented kernel/runtime covers:

| Capability | What it protects |
| --- | --- |
| Candidate → Decision → Act | A suggestion is checked before being recorded as authorized |
| Mandates and delegation | Authority can narrow, not multiply |
| Attempt, broker and executor | Execution capability is released after the durable boundary |
| Outcome and late observations | Timeout is not silently converted into no effect |
| Meter accounting | Reserved, settled, released and suspended resources remain distinct |
| Duties and independent disposition | An unresolved obligation does not close itself |
| Presentation and consent | Approval belongs to particular material and an occurrence |
| Labels, declassification and erasure | Information use and deletion retain their causal record |

Surface, HostProfile and Definition revisions use governed actions.
The Constitution is fixed for the Domain's lifetime in this implementation.

See [the architecture walkthrough](architecture.md) for how these parts
work together.

### Run, inspect and recover

An Instance has responsive reads, serialized mutations and a bounded waiting
queue. It can save local checkpoints and return a pending operation reference
without resubmitting an effect.

Ledger adapters include ETS, Disk, Mnesia, PostgreSQL using the host Repo, and
a fault-injection Mock. Batch paging, suffix reads and optional lossless
compression are available.

Recovery verification, clock checks, incident hooks and offline audit support
operation of the Domain. Observer spans report payload-free operational
metadata; they are not an independent durable audit log.

### Develop and test

The shipped tools include:

- `mix spectre.gen.agent`: Agent, Router, prompt and local contract tests;
- `mix spectre.gen.host`: host/executor skeletons and a first governed-effect
  test, with explicit setup still required;
- `mix spectre.routes`: inspect routing and declared ports;
- `mix spectre.eval`: compare routing behavior against example inputs;
- `mix spectre.doctor`: check declared boundaries and supplied wiring;
- audit and PostgreSQL migration-generation tasks.

The source suite exercises whole agents, failure cases, replay, real embeddings
and native cache integration. Those tests do not replace tests of your own
provider, database and deployment.

## Deliberately supplied by the application

These responsibilities are part of the integration contract, not unfinished
built-in services:

### Identity and access to the outside world

You verify users, webhooks and receipts, protect credentials, choose external
witnesses where needed, and enforce the deployment's actual isolation.

Your application defines the business classes, Conditions and trustworthy
sources of Evidence. Spectre does not infer those policies from a route name.

### Models, channels and control

You choose providers, model IDs, network transports, voice/TTS/VoIP codecs and
sessions. You also choose stream buffering, meaningful delivery units and how
the user asks to steer or stop work.

Spectre need not grow a codec or stream server to support those integrations.
See [input and streaming](integration-and-streaming.md).

### Storage and scheduling

You choose databases, supervise processes, manage backups, and implement
payload ingestion/deletion and retention policy across your systems.

You also schedule agent turns, Workers and Vigils. A declaration is not an
automatic timer, process supervisor or credential grant.

## Still missing or requiring consolidation

The following are actual implementation limits, not responsibilities that an
existing adapter can automatically take over:

| Area | Current limit |
| --- | --- |
| Internal memory | The sequencer's verified projection retains historical records and indexes |
| Durable projection checkpoints | Paging exists; a trusted persistent projection checkpoint does not |
| Query/control load | No general revision-fenced pagination or uniform queue/timeout bound across all APIs |
| Incremental execution receipts | Executors return a final result; there is no public stream-session receipt API |
| Partial stream accounting | No generic “reserve 100, bill 20, refund 80” settlement from a stream counter |

Changing the ledger backend alone does not remove the internal projection's
memory cost. A bounded chat or Mind window limits context, not all runtime state.

Other boundaries are deliberate: no automatic 0.3 checkpoint import, no hidden
Skill applicability policy, no automatic hot code/state migration, and no
training or Forge service. The Governed Holon Model is research and inspiration,
not an implemented 0.4 feature.

## What an honest readiness claim needs

Publishing a library does not require implementing every host's backend,
retention strategy or integration package.

It does require being clear about the implemented contract and its limits.
This checkout is unreleased; deployment-specific qualification remains separate.

Recent indexing and commit changes reduce repeated history work. They do not
prove bounded RAM, particular throughput, or months of unattended operation for
an arbitrary workload. Historical benchmark results describe their measured
revisions, not today's performance.

Before relying on a deployment, test the actual store, provider and workload,
including faults and later receipts. Use
[the testing guide](testing-and-release.md) for a starting checklist and
[the governed surface](../GOVERNED_SURFACE.md) for the precise trust assumptions.
