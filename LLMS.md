# Spectre 0.4.1 guide for application authors

Use **Stack → Agent → Server** for new applications. The Stack installs packages;
the Agent declares recognition; the Server implements callbacks inside the
Runtime's GenServer. An Agent can omit the Stack when using only application
callbacks or a directly configured provider. GAM verifies declared effects. Start with
[Getting started](docs/GETTING_STARTED.md) and [Server](docs/AGENT_SERVER.md).

## Generate and extend the supported shape

```sh
mix spectre.gen.agent MyApp.SupportAgent --server
```

Put routes and recognition examples in the Agent, behavior in `handle_flow/3`,
continuations in `handle_result/3` and conversation policy in `handle_pending/3`.
Use ordinary OTP tuples for native callbacks, with Context as state. The callback
module does not need a second application GenServer.

`Spectre.Server.input/3` returns an interaction ID. Replies and previews arrive
as asynchronous consumer events. `Spectre.summon/1` selects Server ownership
when the Agent has a `server:` binding. The host supplies authenticated identity;
a subject ID alone is not authentication.

## Context and commands

- `ctx.assigns`: portable application state, included in checkpoints.
- `ctx.private`: volatile process references, excluded from checkpoints.
- Identity, routing, pending and Agent fields: runtime views, not mutable authority.

Return the Context produced by helpers such as `respond`, `generate`, `classify`,
`propose`, `await_input` and `call_actor`. `on_result:` names an application
continuation tag. A flow key comes from the Agent declaration, a tool reference
from the Stack and a result tag from the command. `call_tool` takes the
installation and operation pair. Select `tools: MyApp.AI` to generate helpers
such as `kinetic` from installed package declarations. Keep live provider clients
in runtime resources. [Command signatures and defaults](docs/SERVER_CALLBACKS.md).

```elixir
def handle_result(:drafted, {:generated, response}, ctx),
  do: kinetic(ctx, response, on_result: :prepared)

def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
  propose(ctx, proposal.operation, proposal.args,
    proposal_metadata: proposal.metadata, on_result: :sent)
end
```

This fragment requires configured model/Kinetic adapters, prompts and allowed
registered effects. Parse consolidated output once; partial streaming tokens are
not executable proposals. See [Stack tools](docs/STACK_TOOLS.md) and
[Actions](docs/ACTIONS.md).

## Recognition and pending input

Prefer `strategies:`, `:intent_dataset`, `:local_classifier`, `semantic_examples:`,
`collect_intent:` and `dataset_lookup:`. Classifiers and response models can differ.
Handle no match and ambiguity through `handle_flow(:unmatched, input, ctx)` using
`ctx.routing.reason`. An `:understand` prompt is application-defined.

Explicit replies use the target wait ID and revision. Generic input can match
an owned wait, reach the foreground pending handler or continue to routing.
GAM decisions address an exact Presentation. Use the documented
suspend/resume/expiry helpers for topic changes. Collection, review, embeddings
and classifier training are separate steps; collected examples are not verified
truth. See [Routing](docs/ROUTING.md), [Training](docs/TRAINING.md) and
[Pending lifecycle](docs/PENDING_LIFECYCLE.md).

## Open chat, Activities and package authoring

For open chat, route plain conversation to `generate(ctx, :chat)` and handle
`:unmatched` with the same generation path. To keep conversational context,
pass selected previous turns as prompt assigns and render them as data. Recognize
work using a declared route or a classifier. Start a mission with
`start_activity(ctx, {:directive, :mission}, %{goal: input.text})`.
Use the resulting execution reference to inspect, revise, answer or cancel it.
Activity callbacks use the same Context and command API. Directive can continue
its reducer or hand off a result through its optional `handle_invocation/3`.
[Open-chat example](README.md#open-chat-with-directive-missions),
[Activities](docs/AGENT_SERVER.md#run-a-background-activity).

Package authors implement `Spectre.Stack.Installable` and can declare services,
tools, flows and Activity types in `integration/1`. The Agent exposes selected
flow scopes. Use the package callback `child_specs/2` for shared resources
owned by the Stack runtime. Register governed effects via `effects/1`.
[Integration contract](docs/STACK.md#typed-package-integrations).

## Authority and persistence

Configure identity, allowed operations and storage on the root Server. Installations,
routes, models and `protected: true` do not grant execution authority. Freeze
concrete arguments, obtain actual presentation acknowledgement and a separate
human choice, then let GAM verify admission. An observed Outcome is separate from
admission; uncertain effects require reconciliation.

Skills with `server:` have independent GenServers and state while sharing the
root Domain. Mount `governed:` references restrict existing authority. External
approval uses the same requesting Domain; the receiving agent mediates the human
choice. Pulse delivery acceptance never implies consent.

RAM-only operation remains valid. Ledger can persist canonical history,
coordination and per-record Domain projections. A fresh RAM recovery Domain cannot
reuse previous grants or consent. `payload_store` lets the application choose
content retention, references, encryption and backend through two callbacks.

Read [Managed GAM](docs/MANAGED_GAM.md), [Skills](docs/SKILLS.md),
[External approval](docs/EXTERNAL_APPROVALS.md), [Domain storage](docs/DOMAIN_STORAGE.md)
and [Payload storage](docs/PAYLOAD_STORAGE.md) for these contracts.

## Examples and retained APIs

[Examples](docs/EXAMPLES.md) links executable workflows; [Demo](docs/DEMO.md)
describes the LiveView application. Existing Instance/Run APIs are indexed in
[Compatibility](docs/COMPATIBILITY.md). Their checkpoint/Effect lifecycle must
be migrated explicitly before using the Server/GAM execution loop. Use
[Migration](docs/MIGRATING_TO_0_4.md) and [Public API](docs/PUBLIC_API.md).
