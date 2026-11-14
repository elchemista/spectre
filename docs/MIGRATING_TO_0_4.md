# Migrating from 0.3 to 0.4 AgentServer

AgentServer manages GAM automatically. For startup, application callbacks and
the boundary between application policy and kernel invariants, see
[Automatic GAM](MANAGED_GAM.md).

0.4.0 is an unreleased development line with changes to the authoring DSL,
runtime ownership and installed-tool integration. Use core branch
`feature/agent-server-gam` and satellite branches `feature/stack-tools-0.4`.
The [installation guide](INSTALLATION.md) covers dependency pins.

The goal is to keep 0.3's useful recognition, training and Stack capabilities
while making execution explicit: **Stack → Agent → Server, with GAM governing
the host's declared consequences**. The kernel follows the
[GAM manifesto](https://spectre.guide/en/governed-act-model).

## What changes

| 0.3 application pattern | 0.4 AgentServer pattern |
| --- | --- |
| Agent DSL mixes route selection and route-body execution | Agent declares routes; Server implements `handle_flow({flow, intent}, input, ctx)` |
| `Instance` owns the legacy conversational lifecycle | `Spectre.Server.Runtime` owns Server context, workers, continuations and pending intentions |
| Application orchestrates `turn` / `execute` | Return command-bearing contexts; the Server acquires commands and delivers results |
| `act`, `reason`, `reply` inside routing blocks | Ordinary Server callbacks using `generate`, `respond`, `propose` and installed helpers |
| Policy DSL around protected actions | Automatic GAM, registered effects, `handle_action` business checks and `handle_pending` conversation |
| `learn: true` | `collect_intent: true`: explicitly collect intent examples |
| `embedding:` examples on a rule | `semantic_examples:` describes the intent examples more clearly |
| `via:` routing pipeline and `:classifier` / `:semantic_cache` names | `strategies:` with `:local_classifier` / `:intent_dataset`; older spellings remain aliases |
| Direct package/legacy planner integration | Optional `Stack.Installable.tools/1` descriptors generate Server helpers from the selected Stack |
| Instance checkpoint/Run continuation | Server checkpoint + command outbox and GAM journal; no automatic format conversion |

These are authoring changes, not a claim that all older modules were removed.
Existing Instance/Run APIs remain for compatibility. An application still using
them has not automatically moved to the Server/GAM loop.

## What remains

Stack installation, custom models/classifiers, regex, embedding similarity,
local and LLM classifiers, custom router adapters, fallbacks, intent examples,
training and evaluation are retained. The classifier does not need to be the
response model. Online example collection is still useful even before a text
has an embedding: the dataset holds labelled text; vector indexes contain only
valid compatible vectors. `collect_intent` does not automatically retrain or
make a protected route safe to learn. See [Training](TRAINING.md).

Streaming remains available, with provisional previews separated from final
consolidated results. Standalone satellite APIs remain available too; their
existence does not make arbitrary direct calls governed or durable.

## 1. Split the application modules

Keep `MyApp.AI` as the Stack. Read the Agent's declarations before the Server's
implementation. The `server:` binding names the callback module; it does not
require that module to appear before the Agent in a single-file example:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  router strategies: [:regex]

  flow :support do
    on :pricing, regex: ~r/^pricing$/i
  end
end

defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx),
    do: respond(ctx, "Plans start at EUR 20.")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Do you mean pricing or account deletion?")
end
```

Add the full recognition pipeline only after connecting its adapters. Put
unmatched/ambiguous handling in `handle_flow(:unmatched, ...)`, examining
`ctx.routing.reason`. Use `classify` for a classification command or `generate`
with an application `:understand` prompt when richer model reasoning is needed.
Do not invent a new route outside the declared Agent catalog from model text.

## 2. Move continuations and OTP work to the Server

`generate(ctx, prompt, on_result: tag)` returns a context; the successful callback
is `handle_result(tag, {:generated, response}, ctx)`. Use `respond` for output.
Use `propose` for a bound governed operation. Result tags are application names,
not implicit new route declarations.

Native `handle_call`, `handle_cast`, `handle_info` and other OTP callbacks are
supported in the same owner. Keep their normal tuple return shape with `ctx` as
state. Framework messages are handled before application catch-alls. Use
`assigns` for portable application state and `private` for volatile handles.
Slow work belongs in workers, not a blocking callback.

`await_input` owns a foreground user reply. `await_reply` waits for an actor in
the background. Neither should be confused with an active GAM consent. See
[Agent and Server](AGENT_SERVER.md) for exact helper contracts.

## 3. Reconnect consequences through GAM

The earlier 0.4 preview used `authority: :development` or a manually constructed
`gam: {module, config}`. Both are replaced by automatic AgentServer integration.
`identity` is now closed to `subject`, `conversation`, `task`, `tenant`, `org` and
`organization`. Remove extra business/credential fields; use `subject` for the
represented account and application state for other business data. Conflicting
atom/string aliases fail startup.

Remove the authority selector and replace the tuple with operation/storage options;
remove application Host, Scope and ingress construction. Existing persisted
preview authority histories are not silently rewritten or assigned new authority.
Keep the old record and handle any pending work before starting a new configuration.


Inventory the effects your application governs. Register their adapters and
configure allowed operation names in `gam: [operations: ...]`, with `confirm: true`
where consent is required. Pass the authenticated identity and configure storage.
AgentServer builds the Domain, Scope, records and standard consent protocol;
there is no application Host or environment-specific integration.

Move business checks into `handle_action/2` and conversation into `handle_pending/3`.
A route's `protected: true` cannot grant permission. A model-generated action and a
deterministic route reach the same admission path. Preserve proposal metadata
from Kinetic so catalog/schema validation remains meaningful. Installing a
classifier/tool does not authorize the consequences it suggests. See
[Automatic GAM](MANAGED_GAM.md) for the configurable and fixed responsibilities.

Replace “request accepted, therefore done” handling with observed results:
`{:governed, %{outcome: %{status: :succeeded}}}` means observed success;
`{:governed_unknown, details}` requires reconciliation. Refusal and uncertainty
must not become unbounded retries.

## 4. Register and call installed tools

Use `use Spectre.Server, tools: MyApp.AI`. Packages implementing `tools/1`
register operations whose names generate private helpers such as `kinetic`,
`mnemonic` and `lens`. Do not import those functions from package modules.

The Stack descriptor selects the adapter and resource contracts. The runtime
resolves named resources and normalizes governed operations to proposals before
persistence. Your context is not a package client struct. Set `stack_runtime:`
to the supervised runtime name when installed operations require resources.

For explicit model AL interpretation, call `kinetic(ctx, response, ...)` from
`handle_result` after generation. Alternatively use `planning: true` and its
planner continuation; do not run both paths for the same response. See
[Stack tools](STACK_TOOLS.md) and each satellite's 0.4 migration guide.

## 5. Migrate consent and recovery deliberately

Move conversational confirmation decisions into `handle_pending`. A topic
change can suspend a pending intention, route the new input, and schedule
closure. Enable authenticated GAM lifecycle observations and durable checkpoints
before using durable closure helpers. Reopening an intention requires a fresh
presentation; a restored old “yes” is not fresh consent.

Do not load an Instance checkpoint into a Server store. There is no general
converter that can infer missing authority, presentations or external outcomes.
Choose a host-owned migration boundary, preserve old audit/history, reconcile
in-flight external effects, and start the Server with deliberately translated
application state. Never translate an old pending policy into approved GAM
Evidence simply because the UI once showed a confirmation.

Server snapshots pin application/tool compatibility fingerprints. Updating a
Stack descriptor or adapter can require an explicit checkpoint migrator; do not
remove fingerprints to force replay. Unsafe/nonrepeatable work with unknown
results stays unknown until reconciled. For Ledger format/recovery constraints,
read the companion branch's ServerStore documentation.

## 6. Verify the application, not just compilation

Exercise matched, ambiguous, unmatched and provider-failure paths. Check separate
classifier/generation models, text-only dataset collection and vector admission,
stream consolidation, every installed helper, consent rejection/topic change/
expiry, and restart during an external operation. Assert that effects are not
repeated and that reported success comes from actual Outcomes.

The [nine-package integration](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/integration/stack_tools/README.md) provides a
runnable reference with fake external transports and real package/GAM/persistence
contracts. It complements your application's tests; it does not validate live
credentials or the host's production authorization policy.

The [old tutorial](GETTING_STARTED_0_3.md) and
[old architecture](ARCHITECTURE_0_3.md) remain available for comparison.

## Skills

Add `server:` to reusable Skill declarations and move route bodies into that
Server's `handle_flow` callbacks. Mount with `governed:` operation references
(or existing logical `bind:` targets). Configure the root AgentServer's allowed
GAM operations once; Spectre automatically passes its existing Domain and
execution boundary to every Skill and records invocation provenance. Do not
create another Domain, copy the authority ledger or extend ingress manually.

Each child has its own GenServer, assigns, workers, streams, pending intentions
and checkpoint key. They can work concurrently under the same GAM laws. Address
text replies with `skill:`; UI decisions use the originating mount and exact
presentation through `Server.decide/4`. Approval in one Skill does not authorize
another. Timers record lifecycle changes in the shared ledger without erasing
Duties. Legacy Instance Skill snapshots are not automatically converted. See
[the full Skill example and ownership table](SKILLS.md).

## Recognition precedence in the new Server

`Spectre.Server.Router` treats an explicit regex match as hard evidence by
default. This prevents an approximate cache/classifier hit from replacing a
command such as “mappa memoria”. Route `strength:`/`regex_strength:` declarations
can explicitly weaken a rule; `router regex_strength: :weak` keeps the old
normal-rule precedence for the new Server. The legacy 0.3 routing entry point
keeps its previous defaults.
