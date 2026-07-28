# Architecture

Spectre separates conversational decisions from application authority. An
agent may classify input and propose work, but only deterministic lifecycle and
policy code can make that work executable. The host application remains the
owner of storage, credentials, authorization, model clients, and side effects.

## One turn

```text
host input
  │
  ▼
Input pipeline ──► normalized Spectre.Input
  │
  ▼
Runtime restore ──► Spectre.State + recalled memory
  │
  ├─ open policy ──► deterministic Policy.Matcher
  │
  └─ normal turn ──► ordered turn handlers
                       │
                       ├─ claimed ──► typed integration reply
                       │
                       └─ continue ──► router plugs ──► candidates ──► arbitrator
                                              │
                                              ▼
                                         Spectre.Route
                                              │
                                              ▼
                                            Runner
                   ┌──────────────┬────────────┼──────────────┐
                   ▼              ▼            ▼              ▼
                 reply           run          ask           action
                                                │              │
                                                ▼              ▼
                                          Prompt.Plan      staged Effect
                                                │              │
                                                ▼              ▼
                                               LLM       policy/lifecycle
                   └──────────────┴────────────┬──────────────┘
                                              ▼
                                        Spectre.Result
                                              │
                                    persist state, then memory
```

`Spectre.turn/3` wraps the result in a `Spectre.Turn` and reduces authoritative
state to one host decision. It does not execute a staged effect.

## One vocabulary, separate execution models

The common semantic boundary is `input -> result -> turn decision`. It is not
a requirement that every participant use the same callback or own the same
state:

| Participant | Role in a turn |
| --- | --- |
| Agent module | evaluates one stateless/local call through `Spectre.turn/3` |
| `Spectre.Session` | serializes calls and retains the latest Spectre state |
| `GenServer` or `gen_statem` | calls or adapts the local turn API while retaining its native OTP protocol |
| `Spectre.Turn.Handler` | optionally claims an already-active dialogue before routing |
| SpectreDirective | owns and snapshots a durable mission/plan across turns |
| SpectrePulse | owns remote envelopes, correlation, task state, and delivery |

This distinction matters under failure. A local handler timeout, an OTP process
restart, a stale durable snapshot, and an ambiguous network delivery require
different recovery rules even though they eventually produce or consume the
same turn decisions.

## Ownership

| Concern | Owner |
| --- | --- |
| Agent declarations | `Spectre.Agent`, `Spectre.Skill`, `Spectre.Definition` |
| Input normalization | `Spectre.Input.Pipeline` |
| Evidence collection | router plugs |
| Final route choice | `Spectre.Router.Arbitrator` |
| State transitions | `Spectre.Lifecycle` |
| Policy text/label matching | `Spectre.Policy.Matcher` |
| Prompt trust and composition | `Spectre.Prompt.Plan` |
| Provider isolation and deadlines | `Spectre.Provider.Call` |
| Optional ownership of a complete normal turn | `Spectre.Turn.Handler` |
| Action capability invocation | `Spectre.ActionDispatcher` |
| Extension-owned effect invocation | `Spectre.Effect.Executor` |
| Effect terminal transition | `Spectre.Execution` |
| Durable storage and authorization | host application |

No model adapter, classifier, router plug, or action module should mutate
Spectre state directly.

## State and transition model

`Spectre.State` is the authoritative snapshot. `Spectre.Result` is a receipt
for one runtime operation; arrays inside a result do not override newer state.
`Spectre.Transition` records one accepted lifecycle command.

The protected-action path is:

```text
pending
  └─ policy required ─► waiting_policy
                          ├─ accept ─► approved ─► completed | failed
                          ├─ reject ─► cancelled
                          ├─ attempts exhausted ─► cancelled
                          └─ expire/cancel ─► cancelled
```

Approval and execution are separate commits. With a compare-and-set state
adapter, Spectre persists `:approved`, invokes the capability once, and then
persists its terminal result. An uncertain second commit is returned as
ambiguous data; the runtime does not guess whether an external side effect
should be retried.

## Trust boundaries

### Untrusted or probabilistic

- user text and metadata supplied by an external host;
- classifier, embedding, semantic-cache, and LLM replies;
- prompt context returned by a dynamic provider;
- persisted payloads before codec validation.

### Deterministic runtime authority

- compiled rule and policy definitions;
- policy resolution labels declared in those definitions;
- lifecycle commands and state revisions;
- registered action names and Skill bindings;
- prompt operation target/trust rules.

### Host authority

- authentication and authorization;
- durable state and idempotency records;
- secrets and provider clients;
- actual business effects;
- delivery of replies, fallbacks, and completion receipts.

## Prompt trust

Static instruction and task assets remain instruction fragments. Dynamic
providers can target only `:context`, which is trusted as data. Structured
adapters receive a `Spectre.Prompt.Plan`; legacy adapters receive one string
with context enclosed by explicit data markers.

This prevents a dynamic provider from being promoted to an instruction by the
Spectre API. It is not a guarantee about how a downstream model interprets
natural language.

## Extension points

Spectre uses small host-owned callbacks instead of owning application
infrastructure:

- `Spectre.State.Store` for durable state;
- memory callbacks documented in [Memory](MEMORY.md);
- `Spectre.Journal.Store` for append-only records;
- `Spectre.Classifier.Embedding` and classifier callbacks;
- model functions or modules through `Spectre.LLM`;
- semantic-cache adapters through `Spectre.Router.SemanticCache`;
- external conversation owners through ordered `Spectre.Turn.Handler`
  adapters;
- action registries and optional SpectreKinetic planning;
- package-scoped effect executors through `Spectre.Extension`.

All provider-style callbacks execute behind documented failure and timeout
boundaries. See [Provider Resilience](PROVIDERS.md).

The handler is not a universal plugin or a wire protocol. The canonical local
host result is `%Spectre.Turn{}` from `Spectre.turn/3`. Input transformation,
memory, Skills, actions, telemetry, journaling, and transport retain their
dedicated boundaries. See
[Turn semantics and integration boundaries](INTEGRATIONS.md).
