# Spectre 0.4.1 implementation plan

**Proposed design · revised after the ergonomics review.** Build on Spectre
0.4.0's **Stack → Agent → Server** architecture, with one GAM Domain for each
governed agent. The Elixir examples show proposed APIs.

**Application code declares capabilities and behaviour. Spectre owns process
startup, supervision, coordination, recovery and the connection to GAM.**
This applies to every satellite. A greeting, a model selection and an ordinary
tool call can all complete with zero Activities.

| Public API | What developers write |
| --- | --- |
| `Spectre.Stack.Installable` and `Spectre.Integration` | A package declares the services, tools, flows or activities it offers. An application installs it once. |
| `Spectre.Agent` and `Spectre.Server` | The Agent selects visible flows and capabilities. Server callbacks compose normal commands and handle their outcomes. An application can target work by a logical name. |
| `Spectre.Activity` | An Activity author writes callbacks using the Server's Context and commands. The facade runs them with the existing Server Runtime. |

The application chooses policy, such as who can publish a document or how many
missions can run. [The OTP and GAM internals](#4-internal-otp-ownership-and-recovery)
are for Spectre maintainers and the implementation spike.

- [Library API and compatibility](#1-library-api)
- [Routing and conversation ownership](#2-routing-and-conversation-ownership)
- [Server commands and an on-demand mission](#3-server-commands-and-an-on-demand-mission)
- [Internal OTP ownership and recovery](#4-internal-otp-ownership-and-recovery)
- [GAM and trust boundaries](#5-gam-and-trust-boundaries)
- [Adopting the API across packages](#6-adopting-the-api-across-packages)
- [Delivery order and acceptance tests](#7-delivery-order-and-acceptance-tests)

## 1. Library API

Add one optional callback, `integration(compiled_config)`, to
`Spectre.Stack.Installable`. The result is immutable Elixir data. Names are scoped
to the installation. Each port has its own input, result and execution contract.
Start with `service`, `tool`, `flow` and `activity` in the pilots. Exercise
`resource` and `observe` through `child_specs/2` and `subscribe/1` until Lens and
Lab can prove the public declarations. Pilot `ingress` with Pulse and Beam
after local delivery and ownership work.

| Port | What the runtime calls, and when | Ownership and result |
| --- | --- | --- |
| `service` | A provider keyed by the behaviour at a specific call site, such as inference selection, action planning or storage recovery | Bind the sole eligible provider automatically. When several qualify, the Agent selects one explicitly. A custom service needs a consumer that asks for its behaviour. |
| `tool` | A named operation called by a flow, Server or Activity | The compiled binding validates arguments and selects the cognitive or governed path. A result returns to the initiating command. |
| `flow` | Scoped routes at Agent compilation, then `handle_flow/3` and `handle_result/3` | The router selects visible routes. The Server owns input order and command acquisition. Ordinary flows need no process of their own. |
| `ingress` | An adapter for an external message or event | The adapter authenticates the source. The runtime checks the target owner and delivers a normalized input, signal or decision through the appropriate existing path. |
| `activity` | A declared type of autonomous work on an explicit start command | A supervised runtime instance owns its local mission state and has a stable logical reference. Starting, revising and cancelling have separate outcomes. |
| `observe` | A subscription to selected diagnostic or lifecycle events | The observer receives a redacted projection asynchronously. Its return value cannot change the event or the originating turn. |
| `resource` | A child specification realized at the declared resource lifetime | The Stack runtime can own a shared browser pool or storage connection. The borrower releases its own tab or handle. The owner stops the shared process. |

A package only declares the ports it uses. For example, Documents contributes
two tools and a conversational flow. Prism supplies a service and Directive
declares an on-demand process type.

```elixir
defmodule MyApp.Documents do
  use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

  def integration(_config) do
    Spectre.Integration.new()
    |> tool(:read, MyApp.Documents.Read, args: [id: :string], access: :subject_scoped)
    |> tool(:publish, MyApp.Documents.Publish,
      args: [title: :string, content: :string], governed: :publish_document)
    |> flow(:documents, MyApp.Documents.Flow)
  end
end

# In Prism's Installable:
def integration(_config),
  do:
    Spectre.Integration.new()
    |> service(Spectre.Inference.Selector, Prism.Selector)

# In Directive's Installable:
def integration(_config),
  do: Spectre.Integration.new() |> activity(:mission, Spectre.Directive.Activity)
```

The same builder can declare `resource(:browser_pool, Lens.Pool)` for Lens,
`ingress(:message, Beam.Ingress)` for Beam and
`observe(:activity_event, Lab.Observer)` for Lab. The compiler records the
resource type. It starts only under the owning runtime's configured lifecycle.
For ingress, bind external message IDs to the authenticated source, target
agent and session. Deduplicate within the configured retention window. An
adapter that redelivers after that window needs its own stable idempotency
contract. Observation uses the existing diagnostics stream with bounded
delivery. Spectre owns resource startup and shutdown. Existing
`child_specs/2` remains an advanced declaration for resource adapters.
Using an installed resource requires only its public binding.

**Compile once.** Normalize the new callback and the existing `tools/1`,
`effects/1`, `child_specs/2` and manifest `agent_extensions` into one
installation definition. Keep keys as `{installation, operation}` for new
operations. Existing generated helpers retain their unique names as aliases to
the same bindings and use the same command path. The initial compiler retains
0.4.0's single installation per package per Stack. Multiple named instances
can be designed when there is a concrete lifecycle and configuration use case.
Normalize the legacy `inference_selector/1` slot to the
`Spectre.Inference.Selector` key. Fail duplicate declarations for the same
role or key in one installation, including old and new declarations. Check
behaviour callbacks and types at compile or bind time. Packages can migrate one
contribution at a time.

**Reuse the actual extension points.** `Spectre.Extension` already supplies
`inference_selector`, `action_planner` and `flow_constraints`. Preserve their
existing callers. `Spectre.Stack.Tools` has a closed descriptor shape in 0.4.0.
Keep its execution descriptor and digest for equivalent bindings. Make public
argument/schema metadata a compiled projection. A change to the actual argument
validation or executor changes the execution contract and has to pass the
existing recovery compatibility checks. The normalized ports and compile-time
bindings participate in their versioned integration identity. Runtime credentials,
PIDs and environment-specific endpoints enter through the runtime binding.
Use compatible old projections for checkpoints created in 0.4.0. New dispatch
for flow ownership, ingress, Activities and observation belongs at the specific
runtime boundary that consumes it. A compile-time declaration alone cannot
deliver a signal or resume a wait. [Installable](../lib/spectre/stack/installable.ex),
[Extension](../lib/spectre/extension.ex), [Stack tools](../lib/spectre/stack/tools.ex)

**Separate model exposure.** Generate the public description and argument
schema from declared types only for operations the host exposes. Binding a
service or installing a tool grants no model visibility or authority by itself.
A model can describe a goal, suggest arguments or produce Action Language.
Trusted host code resolves the selected registered action. `prepare` validates
and normalizes arguments, and `project` bounds the data returned by a cognitive
tool. Large documents can return application-owned references. Keep
`prompt_root` and `Spectre.Prompt.Plan`; external tool and ingress results
remain untrusted data throughout generation. [Server tool path](../lib/spectre/server/tool.ex),
[payload storage](PAYLOAD_STORAGE.md)

## 2. Routing and conversation ownership

Let the Agent opt into the installed flow scopes it wants the router to see.
Preserve the order of input preparation and mandatory checks, global interrupts,
targeted or foreground waits, ordinary pre-route handlers, router arbitration,
then selected flow or host fallback. An adapter can supply evidence for visible
rules. The router retains the final selection. Distinguish a genuine miss,
an ambiguous match and a provider failure.

```elixir
defmodule MyApp.Documents.Flow do
  use Spectre.Flow.Port

  def routes, do: [on(:read, regex: ~r/^mostrami il documento(?: (?<id>\S+))?$/i)]

  def handle_flow(:read, _input, ctx) do
    case ctx.routing[:params] do
      %{"id" => id} when is_binary(id) and byte_size(id) > 0 ->
        load_document(ctx, id)

      _ ->
        ctx
        |> respond("Quale documento?")
        |> await_input(:document_id,
          accept: ~r/^D\d+$/i, timeout: 30_000, on_result: :document_id)
    end
  end

  def handle_result(:document_id, {:ok, input}, ctx),
    do: load_document(ctx, input.text)

  def handle_result(:document_id, {:error, :expired}, ctx),
    do: respond(ctx, "La richiesta è scaduta. Chiedimi di nuovo il documento.")

  def handle_result(:document, {:ok, document}, ctx),
    do: respond(ctx, document.title)

  def handle_result(:document, {:error, _reason}, ctx),
    do: respond(ctx, "Documento non disponibile.")

  defp load_document(ctx, id),
    do: call_tool(ctx, {:documents, :read}, %{id: id}, on_result: :document)
end
```

Reuse `handle_flow/3` and `handle_result/3` on a flow port with the Server's
Context return convention. Keep `Spectre.Input` as the normalized input.
Put validated routing parameters in `ctx.routing.params`, including named
regex captures. Use declared parameter names for matches and classifiers.
The values remain untrusted arguments. The document tool still validates the
ID and enforces its subject scope. An application's catch-all callback only
receives results it owns.

The Root owns one index of routable waits, backed by the agent's coordination
state. Each entry identifies the wait, owner (Root, flow or Activity), session,
revision and input kind. A bounded, declared matcher such as `accept:` is
evaluated locally. The Root can dispatch an answer asynchronously while an
Activity is busy. A miss suspends that foreground focus and yields the input
to the router once. Its deadline still applies and expiry returns
`{:error, :expired}` to its owner. Only waits with a bounded,
non-catch-all matcher qualify for automatic focus. A free-text answer needs
an explicit reference from a UI or a local numbered selection before it
reaches its wait. Keep that target scoped to the owner's revision. A GAM
decision continues through the existing verified presentation and decision path.
An unbound “sì” cannot select a consent. A text-only host that supports
consent must explicitly bind the reply to its trusted, rendered presentation.

| Input | Owner and outcome |
| --- | --- |
| “Mostrami il documento” → “D12” | Documents asks for the ID. The Root matches the reply locally and routes it straight to the flow result callback. |
| “Mostrami il documento” → “Apri la guida” | The document wait yields. The guide route runs once. Before expiry, the user can use the original prompt's Reply control to send `D12` with its wait reference. |
| Two activities open reply waits | An explicitly targeted reply goes to that Activity. A generic answer goes to the focused wait if its matcher accepts it. An unaccepted answer follows ordinary routing. |
| `m42` asks a free-text question → “Quanti documenti ho?” | The question remains targetable. The document count request reaches ordinary routing. |
| “Sì” while a document question and publication consent are open | A reply to the question carries no publication authority. Consent follows the verified presentation and decision path. |

If a later pilot needs a stateful `:cont`, scope it to a local foreground flow
callback before routing. Keep Activity routing independent of synchronous
calls to Activity callbacks. [Server callbacks](SERVER_CALLBACKS.md),
[pending lifecycle](PENDING_LIFECYCLE.md)

## 3. Server commands and an on-demand mission

Keep the normal Server Context, command acquisition, result tags and outbox.
Add operational commands that use installed bindings.

| Command | Contract |
| --- | --- |
| `call_tool(ctx, {installation, operation}, args, opts)` | Resolve the compiled binding and use the same validation, GAM path and result projection as its generated helper. |
| `start_activity(ctx, type, args, as: key)` | Stage an authorized start. The runtime acquires one start per command identity and reports readiness and completion as lifecycle events. |
| `signal_activity(ctx, key, signal, opts)` | Resolve the authorized target at acquisition and keep its identity and expected revision for delivery. The optional result tag receives the applied or rejected result within the turn budget, or `{:pending, signal_id}` followed by a correlated lifecycle notification. |
| `cancel_activity(ctx, key)` | Cancel that resolved activity, close its waits and settle outstanding effects. Replayed requests retain their original target and outcome. |
| `complete(ctx, value)` and `fail(ctx, reason)` | End the Activity with a domain result or a logical failure. Spectre commits the terminal outcome and delivers it to the parent. |

### Use an installed Activity

Directive's package declares its mission type. The host wires the route and
chooses how to present the result.

```elixir
defmodule MyApp.Stack do
  use Spectre.Stack
  install Spectre.Prism
  install MyApp.Documents
  install Spectre.Directive
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.Stack, server: MyApp.Server
  expose flows: [{:documents, :documents}]

  classifier :llm, MyApp.IntentClassifier
  router strategies: [:regex, :llm_classifier]

  flow :work do
    on :mission, semantic_examples: ["Confronta i documenti D1–D5 e prepara un PDF"]
    on :revise, semantic_examples: ["Modifica il lavoro in corso per coprire solo l'Italia"]
  end
end

defmodule MyApp.Server do
  use Spectre.Server, prompt_root: "priv/prompts"

  def handle_flow({:work, :mission}, input, ctx),
    do: start_activity(ctx, {:directive, :mission}, %{goal: input.text}, as: :mission)

  def handle_flow({:work, :revise}, input, ctx),
    do: signal_activity(ctx, :mission, {:revise, input.text}, on_result: :revised)

  def handle_flow(:unmatched, input, %{routing: %{reason: :no_match}} = ctx),
    do: generate(ctx, :chat, input: input, on_result: :reply)

  def handle_flow(:unmatched, _input, %{routing: %{reason: :ambiguous}} = ctx),
    do: respond(ctx, "Quale attività intendi?")

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Non riesco a interpretare la richiesta. Riprova.")

  def handle_activity(:mission, :started, ctx),
    do: respond(ctx, "Lavoro avviato.")

  def handle_activity(:mission, {:completed, report}, ctx),
    do: respond(ctx, report.summary)

  def handle_activity(:mission, {:failed, _reason}, ctx),
    do: respond(ctx, "La missione non è riuscita.")

  def handle_activity(_key, _event, ctx), do: ctx

  def handle_result(:reply, {:generated, %{text: text}}, ctx), do: respond(ctx, text)

  def handle_result(:revised, {:applied, _id, _revision}, ctx),
    do: respond(ctx, "Modifica applicata.")

  def handle_result(:revised, {:pending, _id}, ctx),
    do: respond(ctx, "Modifica in attesa.")

  def handle_result(:revised, {:rejected, _id, _reason}, ctx),
    do: respond(ctx, "La modifica non è stata applicata. Verifica lo stato del lavoro.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

The Agent's Stack supplies generic runtime bindings. Existing generated helpers
can still be compiled with explicit `tools:`. A sole inference selector binds
automatically. An Agent can use `provide Spectre.Inference.Selector, from: :prism`
when several installed selectors qualify. The host can set Activity limits and
narrow tool scope per type. A trusted Server callback can explicitly start an
installed type within the Agent's policy. Model suggestions enter through
authorized bindings. Starting subactivities requires an explicit host grant.

The `as:` key is scoped to the owning agent and session. A single active slot
can be called `:mission`. For parallel work, use a portable key such as
`{:mission, request_id}` derived from application data. Treat a repeated
command ID as a replay. Report a new start against an occupied key as
`{:failed, {:start, :already_running}}` on that request. A queued signal or
cancellation stays bound to the instance resolved at acquisition, even when
the application reuses the key later. Trusted clients can use authorized
summaries to choose among concurrent missions.

`handle_activity/3` is optional. Its events are `:started`,
`{:progress, summary}`, `{:completed, value}`, `{:failed, reason}` and
`:cancelled`. The terminal event carries a domain result or logical reason.
Timeouts and unavailable dependencies report errors through the same public
path. An accepted signal that returns pending publishes its final correlated
outcome through the existing subscription. The initiating turn can close
within its budget while the mission continues. The default Server error
clause closes an unhandled failing turn with a redacted diagnostic.

For operational control, authorized callers use `Spectre.Server.activities(root)`,
`activity(root, key)`, `cancel_activity(root, key)` and the existing
`subscribe(root)`. The external cancellation entry point checks the caller
and submits the same lifecycle request as a Server callback. Summaries use
logical names, ownership, state and revisions. Access is scoped to the agent.

“Ciao” reaches `generate` on a genuine router miss, after at most one router
classifier call. “Mostrami il documento D12” uses the installed flow and tool.
Both leave the Activity count at zero.

### Write a custom Activity

Add `activity :research, MyApp.Research` to the Stack above. This local
declaration compiles to the same `activity` port as a package's
`integration/1`. Start it as a local type from a Server callback.

```elixir
defmodule MyApp.Research do
  use Spectre.Activity,
    prompt_root: "priv/research/prompts",
    requires: [{:documents, :read}]

  def handle_start(%{id: id}, ctx),
    do: ctx |> assign(:document_id, id) |> read_document()

  def handle_result(:document, {:ok, document}, ctx) do
    generate(ctx, :summarize,
      assigns: %{document: document, instructions: ctx.assigns[:instructions]},
      on_result: :summary)
  end

  def handle_result(:summary, {:generated, %{text: text}}, ctx),
    do: complete(ctx, %{summary: text})

  def handle_result(_tag, {:error, reason}, ctx), do: fail(ctx, reason)

  def handle_signal({:revise, instructions}, ctx),
    do: ctx |> assign(:instructions, instructions) |> read_document()

  defp read_document(ctx),
    do: call_tool(ctx, {:documents, :read}, %{id: ctx.assigns.document_id},
      on_result: :document)
end

# In a Server callback:
start_activity(ctx, :research, %{id: "D12"}, as: :research)
```

`Spectre.Activity` reuses the Server Runtime and its existing command result
shapes. `handle_start(args, ctx)`, `handle_signal(signal, ctx)` and
`handle_result(tag, result, ctx)` return Context with staged commands.
Spectre verifies signals before calling `handle_signal/2` and calls
`handle_start/2` after adoption and activation. The default Activity command
failure ends the activity. An Activity can handle an expected error as domain
logic. Validate declared requirements at bind time and check the effective
scope again at execution.

The core correlates every command to its generation, Activity revision and
request ID. A late summary from the old revision cannot call `complete/2`
for the new one. A previously admitted effect retains its original
identity and outcome. It reaches the current Activity as a separately tagged
observation and is visible to the Root. The observer can reconcile the outcome
before planning another publication. Close or reissue old waits after a
revision and report a stale wait when an old reply arrives.

### Walk through a published document

The user asks “Confronta i documenti D1–D5 e prepara un PDF”. The documents
describe five companies. The Root starts the installed Directive mission and
stays available for questions. Directive's driver uses the same Activity
callbacks to continue its reducer. It requests reasoning through model
services, user answers through owned waits and document reads through the
installed binding. It correlates each observed result with its reducer
request ID. The standalone reducer and its interfaces stay available.
[Directive reducer integration](https://github.com/elchemista/spectre_directive/blob/e9f206592a9a8c63b2d59595a33f07dc50803c39/docs/SPECTRE_0_4.md)

“Considera solo aziende italiane” sends a revision to `:mission`. When the
report is ready, the Activity requests publication through the host's PDF
binding. The host can configure
`gam: [operations: %{publish_document: [confirm: true]}]` on the agent.
The user sees the actual publication proposal and GAM decides its admission.
A separate plan approval carries no publication authority. A refusal leaves
the draft available under host policy. An uncertain outcome awaits reconciliation.
On success the report reaches `handle_activity/3`.

## 4. Internal OTP ownership and recovery

Pilot this internal topology with real OTP processes. The Agent supervisor
owns the Root, coordination and Activity infrastructure. Package authors
declare the lifecycle they need through their port.

```text
Stack runtime ── shared browser pool / storage connection
Application supervisor
  ├─ Agent A supervisor (:one_for_one)
  │    ├─ coordination store and managed GAM Domain A
  │    ├─ Activity branch
  │    │    ├─ Registry
  │    │    └─ DynamicSupervisor
  │    │         ├─ Activity m42 (:temporary at this boundary)
  │    │         └─ Activity m43 (:temporary at this boundary)
  │    └─ Root A
  └─ Agent B supervisor ── Root B, coordination and GAM Domain B
```

The stable coordination owner and GAM sit outside Root and mission processes.
Monitor and rebind dependencies explicitly. The Root keeps serving simple
turns if the Activity branch goes down. Starts and signals that depend on
that branch report a logical unavailable state until it recovers. If GAM is
unavailable, affected operations pause or fail closed under the host's
existing recovery policy. Restarting an Activity branch leaves Root binding
and authority intact.

In the first pilot a mission crash is terminal. A mission with its own subtree
remains `:temporary` at the shared supervisor boundary, so exhausting its
local restart budget leaves siblings alive. An Activity with automatic
resumption must restore its cursor and outstanding requests from coordination.
Measure the idle cost and the cost of two and 50 active missions. Expensive
model calls, external I/O and diagnostic export run outside Root callbacks.

The 0.4.1 Activity pilot assumes one active instance of each agent on one BEAM
node at a time. The Registry provides uniqueness on that node. Conditional
store writes fence attempts during recovery. Cross-node ownership would
require a separate lease protocol and fencing token.

**Start and adopt.** The runtime reserves `{generation, command_id, ref}`
with state `:starting` before spawning. Start the top-level Activity child
under a unique OTP Registry name keyed by agent, generation and ref. Registration
is part of process startup. A concurrent start of the same name adopts
the registered process. The child starts waiting for activation. The stable
owner adopts it, installs its monitor and commits readiness before granting
activation. Only the adopted process can acquire its first commands. Emit
`:started` after the grant. Use the same command ID and ref on replay. The
live Registry owns PID lookup and the store keeps logical start state.

The coordination owner survives Root loss and records `:DOWN` even while
the Root restarts. During adoption it reconciles records against live names
for the current generation. A `:running` entry with no live owner becomes
failed under the default policy. A failure recorded after the coordination
owner acquires the start remains terminal even if its caller never received
the result. If that handshake never completed, the reservation can be retried
under the same name because the child had no permission to schedule work.

```text
reserve command → start registered child in waiting state → adopt and monitor
                → commit readiness → activate → dispatch handle_start
```

The owner can finish the same handshake after a Root or launch worker crash.
Activation grants are scoped to the claimed child and generation. A replayed
grant cannot run `handle_start/2` again for an already activated attempt.

| Fault location | Recovered observation |
| --- | --- |
| Root dies after storing `:starting`, before spawning | Resume the reserved start with the same reference. |
| Root dies after spawning `m42`, before adoption or activation | Find the one registered child. Finish its handshake and emit a single start event. The child schedules work after activation. |
| Activity supervisor dies with missions in flight | Resolve affected children and their effects. Plain Root turns continue while the branch restarts. |
| `m42` dies after GAM admits a write | Record the mission failure. Reconcile the existing effect reference through GAM. The Root and `m43` continue. |
| Reset happens while an old signal or reply is queued | Advance the generation, settle old waits and shut down their Activities. Fence the old generation from new work. Keep admitted effects under their original identities. |

Project the owned process tree into diagnostics with logical owner, parent,
status and restart information. Mark shared resources separately, bound
snapshots, coalesce progress for slow subscribers and redact payloads.
[Existing diagnostics](DIAGNOSTICS.md)

For example, A's mission and B's mission borrow different tabs from the same
Lens pool. The pool monitors borrowers and releases A's scoped lease on a
crash as well as on cancellation. A delayed cleanup for a previous lease
cannot release a newly borrowed handle. B's tab remains usable.
Supervise the pool under the Stack runtime, independent of the agents.
Tag each lease with the pool incarnation. If the pool dies, invalidate
that incarnation and return a correlated `{:error, :resource_down}` for
interrupted reads. Reconcile a possibly executed governed effect before
reporting its outcome. A replacement pool issues fresh leases.

**Crash and shutdown.** In 0.4.0 the Root explicitly stops on exit of the Skill
supervisor. The Activity pilot gives optional branches their own failure
boundary. When a branch fails, close its waits, release leases and report
degradation to the Root. Loss of required GAM blocks affected governed work.
Agent shutdown ends descendants and records remaining effects. A Root process
crash invokes the adoption path. Reset closes the old generation. Reject stale
signals and results after a generation change or an incompatible restore.
[Existing mounted supervision](../lib/spectre/server/skills.ex),
[Root exit handling](../lib/spectre/server/runtime.ex)

**Recovery.** Pin starts, signals, steps and effect references to command IDs
and revisions. RAM supports Root/Activity crash recovery while the owning
coordination state and GAM survive. Durable coordination can recover across
an agent or VM restart. Restore prior waits and continuations when compatible
with the recorded generation and policy. On DB outage or pruned state, use the
existing storage recovery policy and report the actual durability. A fresh RAM
session has no evidence about a previous external outcome.

For example, `m42` publishes a PDF. If the provider writes it and the worker
dies before returning, query the adapter with the recorded effect identity or
reconcile through an idempotent provider key. With neither capability, record
`unknown` and await reconciliation. A crash, cancellation or newer mission
revision cannot authorize sending that effect again. [Storage recovery](DOMAIN_STORAGE.md)

## 5. GAM and trust boundaries

**Reattach the Root to the same Domain.** In 0.4.0, Managed GAM monitors the
runtime PID and uses that binding to authorize internal requests. On loss
of its runtime owner it begins shutdown. The spike must change both ownership
and authorization. Put lifetime management under the stable agent owner and
let that owner authenticate a replacement Root. Rotate the Root binding epoch
on each attachment and reject traffic from earlier bindings. Preserve the
agent identity, session generation, GAM Domain, pending consent and effect
references. A Root restart and an explicit session reset have separate
effects on these identities. Prove that a replacement Root can continue a
pending consent without issuing a new one, and that an already admitted effect
remains reconcilable. [Managed GAM owner](../lib/spectre/server/gam/managed.ex)

The host authenticates the subject and selects policy. Every Activity shares
its agent's GAM Domain with explicit origin and correlation. The effective
tool and operation scope is the intersection of host policy, Agent policy for
that type, the parent's current scope, and any narrower scope on the start
request. A type may declare an explicit ceiling. Record the effective scope
with the start and recheck current policy at effect admission, including
after PID restart. Host policy also governs who may inspect, signal, cancel
or start work and can bound concurrency, time and cost.

For example, a research subactivity starts with `{:documents, :read}` under
a parent allowed to read and publish. The child cannot publish even if it
receives the name of the executor. The parent can submit a publication for
admission through its own scope.

**Order supersession against admission.** The 0.4 reset protocol suspends the
agent's gates. The pilot needs to demonstrate a boundary scoped to one
Activity using real Managed GAM. Record a revision or cancellation intent and
pause that Activity's old work. At the GAM admission boundary, serialize the
fence with admission using the Activity's identity and expected revision.
After the fence, a late decision returns `:superseded`. If admission wins
first, retain its effect reference and publish its outcome to the new revision.
Other missions continue. Run a revision against a pending approval in both
orders with deterministic barriers, then exercise randomized interleavings.
Apply the same rule when a proposing Activity fails with consent pending.
On a crash between the fence and the coordination commit, recover the same
transition identity and keep that Activity paused until it resolves. Choose
the internal contract after the spike proves these invariants.

An operation's consequences determine its treatment. An in-scope model
selection can be an internal service call. Sending private input to a remote
model can require a separate governed binding. A subject-scoped memory read
gets its subject from the trusted runtime binding. A conformance test verifies
that the provider constrains the query across two subjects. A document write
or message send declared governed resolves to the registered executor and
existing GAM admission path. If browsing needs consent, cover all entries that can navigate,
including Lens `look(url)`. Ledger's persistence of GAM records remains
infrastructure; appending those records must not recursively propose another
Act. A Pulse transport receipt acknowledges delivery and cannot approve an Act.

Host policy may tighten exposure and governance. Fail binding if a governed
path lacks its required executor or would fall back to an ungoverned path.
Carry the exact arguments, principal, origin and decision through GAM. Package
adapters are trusted BEAM code: a macro cannot prevent arbitrary external I/O
by code running in the same VM. Verify registered executor usage in conformance
tests and reviews. Strong isolation of untrusted code needs a distinct execution
boundary. [Managed GAM](MANAGED_GAM.md), [external approval](EXTERNAL_APPROVALS.md)

## 6. Adopting the API across packages

| Package | Ports to exercise first | Concrete proof |
| --- | --- | --- |
| Prism | `service` | A normal `generate` uses the installed inference selector and preserves flow constraints. |
| Kinetic | `service`, `tool` | Existing planner/AL produces proposals. A governed action executes through the registered GAM binding. |
| Mnemonic | `tool`, optional `service` and `resource` | Recall stays within the subject. Governed writes use the configured backend. |
| Lens | `tool`, `resource` | Two agents borrow from one pool; cancellation closes only the owner's tab. |
| Ledger | Storage/recovery `service`, optional `resource` and query `tool` | Recover an agent without exposing storage administration to the model. |
| Lab | `observe`, diagnostic `tool` | Inspect redacted events and process status. An observer crash leaves ongoing turns available. |
| Beam | `ingress`, delivery `tool` | Authenticate inbound messages, correlate replies and govern configured sends. |
| Pulse | `ingress`, messaging `tool` | Preserve peer authentication, technical receipts and independently verified approval evidence. |
| Directive | On-demand `activity` plus existing reducer helpers | One install starts zero missions. Two starts produce independent, controllable missions. |

Keep standalone package usage and current integrations working. Move packages
incrementally as conformance passes. Put package-specific tests with the
package, combined scenarios in `spectre_ecosystem`, and small dependency-free
fixtures in core. The core runtime dispatches by typed port and registered
binding. It requires no branch keyed to a satellite name.

## 7. Delivery order and acceptance tests

| Phase | Deliverable | Evidence before moving on |
| --- | --- | --- |
| 0. OTP spike | Use fixture Activities, stable coordination, registered startup and local wait matching. | Kill the Root between reservation, spawn, adoption and activation. Recover one mission by command ID. Kill one Activity and its supervisor separately. Plain Root turns still work. |
| 1. Managed GAM rebind | Move lifetime ownership and authenticate replacement Root attachments with real Managed GAM. | Kill the Root with consent pending. Verify the same Domain and session, one pending consent and valid continuation. Reject delayed control traffic from the old Root. |
| 2. Revision and admission | Prove per-Activity ordering with the existing GAM path and scoped concurrency. | Force both orderings between approval and revision. Check two competing revisions, stale results, terminal proposer failure and continued work by another mission. |
| 3. Integration and public APIs | Normalize old and new bindings. Pilot Prism, Documents and one custom Activity. Exercise named starts, signals, cancellation and optional lifecycle callbacks. | Use ordinary app callbacks to start and control work. Restore a 0.4.0 checkpoint. Verify helper equivalence and zero Activity starts for greetings and document reads. |
| 4. Directive and remaining port pilots | Run Directive's driver, Lens resources, Pulse/Beam ingress, Ledger recovery and Lab observation. | Run the PDF walkthrough and cross-agent failure test in RAM and durable storage. Exercise both borrower and pool failure, and storage outage with pending consent. |
| 5. Compatibility, performance and docs | Migrate packages incrementally and profile the actual topology. | Run standalone core, satellite conformance and ecosystem integration. Validate the copyable app and package examples before freeze. |

**Decisive failure test.** Two agents share a Stack. Agent A starts two
missions, then crashes one after an external write. The other mission
completes, Root A answers another turn and agent B continues using the shared
resource. Reconcile the write by effect ID. The idempotent fixture observes
one external effect. With an unverifiable provider, assert `unknown` and zero
automatic resends. Agent B cannot read, signal or stop A's mission. Cover reset
and storage outage while consent is pending.

| Focused scenario | Pass condition |
| --- | --- |
| Copy the installed and custom Activity examples into a fixture application | The app installs, starts, signals and cancels by logical key. It observes logical success or failure using the same Server Context and commands. Test the callbacks with the command fixture, then repeat through real OTP. |
| Start request replay or key reused by a new Activity | A replay resolves the first instance. A delayed request targeting it cannot affect the replacement. |
| Wait owner suspended by the test | The unrelated Root turn completes within its budget. An explicitly targeted reply remains correlated. |
| Old plan completes after a revision | Its result does not advance the new plan. A superseded admitted effect is visible as an observation. |
| GAM admission races a revision | If admission wins, the new revision observes the effect. If the fence wins, consent returns superseded and no effect starts. |
| Raw BEAM message imitates an Activity signal | No Activity revision changes. The verified path accepts a legitimate request with its expected revision. |
| Two concurrent revisions expect the same version | One applies. The other is stale. A replay with the successful signal ID gets the recorded result. |
| Tool helper and generic call | Both produce the same validated arguments, GAM admission path and projected result. |
| Two providers for the same behaviour | Agent binding fails with a precise conflict until the app selects its provider. |

**Measure before release.** Compare idle agents with no Activities, one
foreground wait, two active missions, repeated start/cancel/restart and a
long-running mission while the Root serves inputs. Record process counts,
memory, reductions, mailbox depth, turn latency, worker lifetime, checkpoint
size and storage I/O. Verify cleanup reaches a plateau and a slow observer
does not grow the Root mailbox without bound. Exercise RAM and durable storage,
including real Postgres in the owning integration suite. Keep retry, backpressure
and budget choices configurable. Use the [0.4 profiling baseline](OTP_PROFILE_0_4.md).

**Ship the developer contracts.** Document each port's caller, payload, result,
authority, failure and lifetime. Show Stack → Agent → Server examples for
Prism, Documents, Directive and the custom Activity. Keep the OTP fault
injection tests in the maintainer guide. Update the public API, provider/flow guides,
Doctor checks and generators for binding validation, process visibility and
on-demand startup. Run formatting, warnings-as-errors compilation, tests,
coverage, Credo, Dialyzer and documentation checks in the affected repositories.
Freeze public names and persisted formats after the pilots and recovery tests.
