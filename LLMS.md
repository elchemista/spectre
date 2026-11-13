# Spectre 0.4 guide for LLMs and coding agents

Use this guide when generating Spectre applications. The application architecture
is **Stack → declarative Agent → OTP Server**, with GAM mediating the host's
declared governed consequences. The model is a cognitive dependency, not the
owner of authority or application state.

Read [Getting started](docs/GETTING_STARTED.md), [Agent and Server](docs/AGENT_SERVER.md),
[installed tools](docs/STACK_TOOLS.md), [GAM](docs/GAM.md) and
[migration from 0.3](docs/MIGRATING_TO_0_4.md). The
[GAM manifesto](https://spectre.guide/en/governed-act-model) defines the model;
the implementation guide maps its concepts to Elixir modules.

## Generate this shape

```elixir
defmodule MyApp.AI do
  use Spectre.Stack
end

defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI

  def handle_flow({:support, :pricing}, _input, ctx),
    do: respond(ctx, "The starter plan costs €20 per month.")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "What would you like to know?")
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer
  router strategies: [:regex]

  flow :support do
    on :pricing, regex: ~r/price|cost/i
  end
end

{:ok, pid} = Spectre.summon(agent: MyApp.SupportAgent, subject: "customer-42")
{:ok, interaction_id} = Spectre.Server.input(pid, "What does it cost?")
```

`input/3` accepts the input and returns its interaction id. Replies and previews
are asynchronous consumer events; it does not return a completed legacy Turn.
The host supplies authentication, identity, model services, resources and
persistence when those features are used. `subject:` identifies the local
owner; it does not authenticate the caller.

## Keep the ownership boundaries

| Layer | Responsibility |
| --- | --- |
| `Spectre.Stack` | Install packages, configure capabilities and supervise named runtime resources. |
| `Spectre.Agent` | Declare routes, independent classifiers, examples and recognition settings. |
| `Spectre.Server` | Implement application callbacks and build commands on a Context. |
| `Spectre.Server.Runtime` | Own the GenServer, inbox/outbox, pending intentions, workers, streams and recovery. |
| `Spectre.GAM` and host | Evaluate concrete Candidates under Mandate/Evidence, record Acts, execute admitted Attempts, observe Outcomes and preserve Duties. |

The application Server callback module runs inside the Runtime's GenServer;
do not start a second application GenServer to wrap it. `handle_call`,
`handle_cast`, `handle_info`, `handle_continue` and `code_change` are supported.
Native callbacks return ordinary OTP tuples with `ctx` as their state.
Conversational callbacks return an updated Context, usually through a helper.

`ctx.assigns` contains portable application data. `ctx.private` holds process-local
references and actor handles and is not checkpointed. Identity, input, routing,
pending records and Agent are views. Mutating a view does not change the
Runtime's authoritative value. Do not put initialized Kinetic, browser, model
or memory runtimes in assigns.

## Helpers are commands, not synchronous service calls

Core helpers include `respond`, `generate`, `classify`, `propose`, `call_actor`,
`await_input`, `await_reply`, `resolve_await`, `route_current_input`,
`confirm_pending`, `reject_pending`, `explain_pending`, `resume_pending`,
`close_pending`, `close_pending_after`, `cancel_pending_close` and `no_response`.
Return the Context containing the commands. `on_result:` identifies the
continuation delivered to `handle_result/3`.

Installed packages declare `c:Spectre.Stack.Installable.tools/1`.
`use Spectre.Server, tools: MyApp.AI` generates private helpers from those
descriptors. Do **not** invent imports such as
`import Spectre.Kinetic, only: [kinetic: 3]`.

```elixir
def handle_result(:composed, {:generated, response}, ctx),
  do: kinetic(ctx, response, on_result: :prepared)

def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
  propose(ctx, proposal.operation, proposal.args,
    proposal_metadata: proposal.metadata, on_result: :sent)
end
```

This fragment requires a Stack with Kinetic, a closed action registry, a model
and host GAM bindings. The model produces AL; Kinetic prepares candidates from
its consolidated output. Do not execute raw AL or partial streaming tokens.
If `generate(..., planning: true)` already prepared proposals, do not parse them
again with the explicit helper. See [Actions](docs/ACTIONS.md).

## Preserve recognition and fallback

Prefer `strategies:`, `:intent_dataset`, `:local_classifier`,
`semantic_examples:`, `collect_intent:` and `dataset_lookup:` in new examples.
Legacy aliases are still accepted; conflicting aliases are errors.
The classifier may use a different model from response generation, or a host
adapter. Regex, dataset lookup, embedding, local classifiers, LLM arbitration,
custom router adapters and failure paths remain available.

No match and unresolved ambiguity reach `handle_flow(:unmatched, input, ctx)`.
Inspect `ctx.routing.reason`; do not hide infrastructure failure as a confident
intent. An `:understand` prompt is an application choice, not a magical callback.
Foreground pending input goes to `handle_pending` before ordinary routing.
Use `route_current_input(ctx, suspend: pending.id)` for a new topic; add
`close_pending_after` when the old intention should expire. Follow
[the pending lifecycle guide](docs/PENDING_LIFECYCLE.md) to record the policy
transition through the configured GAM ingress.

IntentDataset stores labeled examples, including useful text-only rows.
Only compatible stored embeddings participate in vector search. An exact hit
needs no query embedding. Online collection is not automatic training and does
not make an example verified ground truth. Keep export, review, embedding and
classifier training distinct. See [Training](docs/TRAINING.md).

## Do not invent authority

Installing a model or classifying an input does not automatically ask the end
user for consent. GAM applies to the host's declared governed surface, which
may also include protected reads, disclosures or resource consumption. A route,
`protected: true`, classifier label or package `bind:` never grants a mandate.

A candidate builder freezes the concrete operation and authenticated context.
Consent, when required, binds the original response to a successfully shown
Presentation. A committed Act precedes the executor's capability. An Outcome
reports what was observed; absence of an Outcome is not proof of failure or a
license to retry. A timer closes an intention, not an unresolved Duty.

Do not report deletion or email delivery because admission succeeded. Match an
observed `{:governed, %{outcome: %{status: :succeeded}}}` result. Preserve
`:ambiguous`, `{:governed_unknown, ...}` and `{:tool_unknown, ...}` as uncertainty.
Native OTP callbacks are not a sandbox: a direct HTTP call can bypass the host
boundary. Consequential work must remain a governed command.

## Persistence and compatibility

Server checkpoints support `{disk_store, key}` and `{StoreModule, store_ref, key}`.
Use separate keys for conversations and a durable GAM command journal. Assigns,
commands and projected results must fit the portable codec and shared budget.
Safe cognitive commands may repeat after restart. Nonrepeatable commands are
marked before invocation and become uncertain after interruption.

Definition/adapter/config drift requires an explicit checkpoint migrator.
It cannot rewrite inbox/outbox/pending facts to turn old approval into new
permission. Started governed requests reconcile the original GAM journal.

`docs/PUBLIC_API.md` is the checked callable manifest. It lists Server and GAM
alongside retained APIs, but does not yet enumerate the complete new Stack tool
adapter contract; use [Stack tools](docs/STACK_TOOLS.md) and its source contract
for that documented addition. Do not claim that the machine manifest tests it.

The old `ask`/`turn`, Instance, Run, Effect, policy DSL, Work/Vigil and reflection
surfaces remain compatibility APIs. They are not automatically governed by the
new Server/GAM loop. Never mix their state or continuation protocols into new
Server examples. The archived [0.3 guide](docs/legacy/LLMS_0_3.md) is for maintaining
those applications, not for scaffolding a new one.
