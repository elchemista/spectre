# Spectre 0.4.1 implementation plan

**Implementation sequence and proposed APIs.** Build on Spectre
0.4.0's **Stack → Agent → Server** architecture, with one GAM Domain for each
governed agent. The Elixir examples show proposed APIs.

**Application code declares capabilities and behaviour. Spectre owns process
startup, supervision, coordination, recovery and the connection to GAM.**
This applies to every satellite. A greeting, a model selection and an ordinary
tool call can all complete with zero Activities.

| Public API | What developers write |
| --- | --- |
| `Spectre.Stack` | Install the libraries the agent needs. Declare a local Activity here when the application defines one. |
| `Spectre.Agent` | Choose routing, visible capabilities and policy. |
| `Spectre.Server` | Write flow handlers that use normal Server commands. Customize results when the application needs to react. |
| `Spectre.Activity` | Write the logic of an autonomous job using the Server's Context and commands. |
| `Spectre.Stack.Installable` and `Spectre.Integration` | Declare a library's tools, services, flows or Activity types once. |

The application chooses policy, such as who can publish a document or how many
missions can run. [The OTP and GAM internals](#4-internal-otp-ownership-and-recovery)
are for Spectre maintainers and the implementation spike.

- [Library API and compatibility](#1-library-api)
- [Routing and conversation ownership](#2-routing-and-conversation-ownership)
- [Server commands and an on-demand mission](#3-server-commands-and-an-on-demand-mission)
- [Internal OTP ownership and recovery](#4-internal-otp-ownership-and-recovery)
- [GAM and trust boundaries](#5-gam-and-trust-boundaries)
- [Adopting the API across packages](#6-adopting-the-api-across-packages)
- [Implementation sequence and acceptance tests](#7-implementation-sequence-and-acceptance-tests)

## 1. Library API

Add one optional callback, `integration(compiled_config)`, to
`Spectre.Stack.Installable`. The result is immutable Elixir data. Names are scoped
to the installation. Each port has its own input, result and execution contract.
The initial public builder covers `service`, `tool`, `flow` and `activity`.
Use `child_specs/2` for resources, `subscribe/1` for observation and the
existing authenticated adapters for ingress. Design and promote those
additional ports once Lens, Lab, Pulse and Beam have demonstrated their
contracts.

| Port | What the runtime calls, and when | Ownership and result |
| --- | --- | --- |
| `service` | A provider keyed by the behaviour at a specific call site, such as inference selection, action planning or storage recovery | Bind the sole eligible provider automatically. When several qualify, the Agent selects one explicitly. A custom service needs a consumer that asks for its behaviour. |
| `tool` | A named operation called by a flow, Server or Activity | The compiled binding validates arguments and selects the cognitive or governed path. A result returns to the initiating command. |
| `flow` | Scoped routes at Agent compilation, then `handle_flow/3` and `handle_result/3` | The router selects visible routes. The Server owns input order and command acquisition. Ordinary flows need no process of their own. |
| `ingress` (later) | An adapter for an external message or event | The adapter authenticates the source. The runtime checks the target owner and delivers a normalized input, signal or decision through the appropriate existing path. |
| `activity` | A declared type of autonomous work on an explicit start command | A supervised runtime instance owns its local mission state and has a stable logical reference. Starting, revising and cancelling have separate outcomes. |
| `observe` (later) | A subscription to selected diagnostic or lifecycle events | The observer receives a redacted projection asynchronously. |
| `resource` (later) | A child specification realized at the declared resource lifetime | The Stack runtime can own a shared browser pool or storage connection. The borrower releases its own tab or handle. The owner stops the shared process. |

A package only declares the ports it uses. For example, Documents contributes
two tools and a conversational flow. Prism supplies a service and Directive
declares an on-demand process type.

```elixir
defmodule MyApp.Documents do
  use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:read, MyApp.Documents.Read,
      args: [id: :string], access: :subject_scoped)
    |> Spectre.Integration.tool(:publish, MyApp.Documents.Publish,
      args: [title: :string, content: :string], governed: :publish_document)
    |> Spectre.Integration.flow(:documents, MyApp.Documents.Flow)
  end
end

# In Prism's Installable:
def integration(_config),
  do:
    Spectre.Integration.new()
    |> Spectre.Integration.service(Spectre.Inference.Selector, Prism.Selector)

# In Directive's Installable:
def integration(_config),
  do: Spectre.Integration.new() |> Spectre.Integration.activity(:mission, Spectre.Directive.Activity)
```

The examples use qualified builder functions. `use Spectre.Stack.Installable`
supplies the existing manifest contract. Authors can use the builder directly
without additional imports. Spectre owns resource startup and shutdown via
the declared resource lifecycle.
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

**Separate model exposure.** Generate public descriptions and argument schemas
from declared types for operations the host exposes. Validate and digest that
projection against the compiled binding. Keep executable V1 descriptor digests
unchanged for metadata-only additions. Binding a
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
`expose :documents` resolves the only flow scope in the Documents installation.
When there are several scopes, the Agent selects one with
`expose flows: [{:documents, :selected_scope}]`. Diagnose a missing or
ambiguous scope at compile or binding time.
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
Put validated routing parameters in `ctx.routing[:params]`, including named
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

Use the existing Server Context, commands, result tags and checkpoint path.
The initial operational surface adds tool and Activity commands to that path.

| Command | Contract |
| --- | --- |
| `generate(ctx, prompt)` | Existing Server command. The current default `handle_result/3` already sends a generated response. |
| `call_tool(ctx, {installation, operation}, args, opts)` | Use the compiled Stack binding and the same `Spectre.Server.Tool` path as a generated helper. |
| `start_activity(ctx, type, args, opts)` | Stage an on-demand start. By default Spectre assigns a unique execution ref. Pass `as:` when a logical name is useful. |
| `signal_activity(ctx, target, signal, opts)` | Resolve an authorized ref or logical key once. Apply the signal to that instance. |
| `cancel_activity(ctx, target)` | Cancel the resolved instance, close its waits and reconcile outstanding effects. A replay keeps the same target. |
| `complete(ctx, value)` and `fail(ctx, reason)` | End an Activity through the ordinary command and checkpoint path. |

### Run the smallest application

A Stack installs Directive and Documents. The Agent recognizes research
requests. The Server uses one command to start the work.

```elixir
defmodule MyApp.Stack do
  use Spectre.Stack

  install Spectre.Directive
  install MyApp.Documents
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.Stack, server: MyApp.Server

  classifier :llm, MyApp.IntentClassifier
  router strategies: [:regex, :llm_classifier]

  flow :work do
    on :research, semantic_examples: [
      "Analizza i documenti D1–D5",
      "Confronta i documenti e prepara un PDF"
    ]
  end
end

defmodule MyApp.Server do
  use Spectre.Server, prompt_root: "priv/prompts", chat_fallback: :chat

  def handle_flow({:work, :research}, input, ctx),
    do: start_activity(ctx, {:directive, :mission}, %{goal: input.text})
end
```

`chat_fallback: :chat` is a proposed opt-in to the usual `generate(ctx, :chat)`
command when the router returns a genuine miss. Ambiguity and provider errors
retain the existing unmatched handling. Apps can keep their own flow
handlers. The selected prompt still uses the existing `prompt_root` and
generation result handler. “Ciao” can be answered without an Activity or a
second classifier call.

Document starting the host, supplying classifier and generation providers,
configuring credentials and writing the `:chat` prompt once. The example
applications share this setup. To enable direct document lookup, add
`expose :documents` to the Agent. The installation already makes its tools
available within the caller's scope. To use Prism, install it as a service.
If several selectors qualify, choose one with
`provide Spectre.Inference.Selector, from: :prism`.

### Optional names, result handlers and lifecycle hooks

Spectre assigns a different `ref` to each new execution. Two starts with
no `as:` can run concurrently within the host's limits. Replay keeps its
original ref. A name such as `as: :monthly_report` gives the app an optional
key scoped to its agent and session. A competing start for an occupied key
returns `:already_running` for that request. Once a key is reused, queued
commands still target the exact ref resolved at acquisition.
Use an atom such as `:research` for a local type and
`{installation, type}` for an installed package type.

The lifecycle callback and subscriber events carry the execution identity
as `%{ref: ref, key: key}`. The key is `nil` for an unnamed Activity. Each
event retains the original ref after key reuse. When a handler needs to
update a particular active job, it matches its ref. An app can use a key to
accept events from any execution of a named job.

```elixir
# Optional named start and result customization in Server callbacks.
start_activity(ctx, {:directive, :mission}, %{goal: goal}, as: :monthly_report)

def handle_activity(%{ref: ref, key: :monthly_report}, {:completed, report}, ctx) do
  ctx
  |> assign(:last_completed_report, %{activity_ref: ref, report: report})
  |> respond(report.summary)
end
```

By default `handle_activity(_identity, _event, ctx)` returns `ctx`. Spectre
records start, completion, failure and cancellation and exposes them to
subscribers whether a handler is defined or not. Readiness and terminal
outcomes remain distinct. A failed start reports the failure of its request
and leaves an already running instance intact. A custom handler can present
an outcome or link follow-up work to its ref.

`on_result:` is optional when the default already handles the result.
Generation follows the current Server result path. A generic tool uses its
registered operation as the default tag and accepts an explicit tag for
application work. Existing generated helpers keep their tags. An Activity
start can be followed through lifecycle events. With an explicit
`on_result:`, readiness returns `{:ok, %{ref: ref, key: key}}` and a rejected
start returns `{:error, reason}`.
A signal with `on_result:` returns the applied or rejected outcome within the
turn budget, or `{:pending, signal_id}` followed by the final outcome through
the existing subscription. An unhandled failed command emits a controlled
error for a normal turn and records a failure for an Activity. A governed
effect with an unknown outcome retains its reference for reconciliation.

An authorized host uses the external Server API. It can discover a ref with
`Spectre.Server.activities(root, opts)`, inspect it with
`Spectre.Server.activity(root, target, opts)` and submit control requests with
`Spectre.Server.signal_activity(root, target, signal, opts)` and
`Spectre.Server.cancel_activity(root, target, opts)`. Authorization comes
from the existing trusted caller boundary. The runtime resolves and records
the target once for both external calls and commands staged on a Context.
External calls report acceptance or rejection. Lifecycle results arrive
asynchronously. A trusted callback may start an installed type within Agent
policy. Hosts can narrow its tool scope, lifetime and concurrency. Starting
subactivities requires an explicit grant.

### Write a custom Activity

Declare `activity :research, MyApp.Research` once in the Stack. This local
shortcut compiles to the same Activity binding as a package declaration.
Start it with `start_activity(ctx, :research, %{id: "D12"})`.

```elixir
defmodule MyApp.Research do
  use Spectre.Activity

  def handle_start(args, ctx),
    do: call_tool(ctx, {:documents, :read}, args, on_result: :loaded)

  def handle_result(:loaded, {:ok, doc}, ctx),
    do: complete(ctx, %{document: doc.id})
end
```

`Spectre.Activity` runs those callbacks through `Spectre.Server.Runtime` with
the existing command, checkpoint and result shapes. Spectre calls
`handle_start/2` after adoption and activation. An Activity can add
`handle_signal(signal, ctx)` for verified signals and handle expected errors
with its own domain logic. Without a custom error clause a failed command
ends the job. Application callbacks return the normal Context with commands.

The Agent's compiled Stack supplies generic tool bindings to the Root,
Skills and Activities. Resolve `{:documents, :read}` from that Stack, apply
the caller's scope and delegate to `Spectre.Server.Tool` for preparation,
execution and projection. Explicit `tools:` keeps the compiled helpers
working. An Activity can declare required operations and a scope ceiling,
with binding validation and policy checks at execution.

The core correlates commands with their generation, Activity ref, revision
and request ID. Earlier results cannot complete a newer revision. A
previously admitted effect retains its identity and remains observable to the
current Activity and Root. Close or reissue old waits after a revision.

### Walk through a governed publication

Directive's driver runs the reducer through the same Activity callbacks.
It requests reasoning through model services, user answers through owned waits
and document reads through the installed binding. It matches results to
reducer request IDs. The standalone reducer keeps its existing interfaces.
[Directive reducer integration](https://github.com/elchemista/spectre_directive/blob/e9f206592a9a8c63b2d59595a33f07dc50803c39/docs/SPECTRE_0_4.md)

“Analizza i documenti D1–D5” starts a mission. The Root remains available.
An authorized host uses
`Spectre.Server.signal_activity(root, ref, {:revise, "Solo Italia"}, opts)`
to revise the selected execution. The same revision from a Server callback
uses `signal_activity(ctx, ref, {:revise, "Solo Italia"})`.
When the report is ready, the Activity
requests publication through the Documents binding. With
`gam: [operations: %{publish_document: [confirm: true]}]`, the user sees the
actual publication proposal. GAM determines admission. A refusal leaves the
draft available under host policy. An uncertain outcome awaits reconciliation.
On success the execution's terminal event carries its report.

## 4. Internal OTP ownership and recovery

Pilot this internal topology with real OTP processes. The Agent supervisor
owns the Root, coordination and Activity infrastructure. Package authors
declare the lifecycle they need through their port.

```text
Stack runtime ── shared browser pool / storage connection
Application supervisor
  ├─ Agent A supervisor (:one_for_one)
  │    ├─ coordination store and managed GAM Domain A
  │    ├─ Activity branch (:rest_for_one)
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

Start the Activity branch on first use. Inside it, start the Registry before
the DynamicSupervisor. Loss of the Registry restarts the DynamicSupervisor
and its children within the Activity branch.

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
fence with the canonical Domain commit of admission using the Activity's
identity and expected revision. Exercise that boundary in RAM and durable
storage. GenServer mailbox order alone cannot order background transitions
that commit asynchronously.
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

## 7. Implementation sequence and acceptance tests

Land one small change at a time and pass its tests before changing the next
layer. File names below are relative to `lib/spectre/` unless noted. New file
names are proposed.

| Phase | Main files | Gate |
| --- | --- | --- |
| 0. Internal OTP | New `server/activities/*`, `server/runtime.ex` | Two fixture Activities run independently. Fault injection around startup produces one execution per command ID. Both existing startup paths return a live Root PID. |
| 1. Managed GAM rebind | `server/gam/managed.ex`, `server/runtime.ex` | The Root restarts, attaches to the same Domain and session, and continues its pending consent. Old Root control traffic is rejected. |
| 2. Revision and admission | `server/activities/*`, `server/gam/managed.ex` and its admission path | Force both orders at the real GAM commit boundary. Reject admission after the fence. Preserve an effect admitted before the fence and observe its outcome once. |
| 3. Activity API | New `activity.ex`, `server.ex`, `server/command.ex`, `server/runtime.ex` | Start, signal, cancel and complete through the existing runtime. Two unnamed starts receive distinct refs. Optional lifecycle hooks and defaults produce the expected results. |
| 4. Integration API | New `integration.ex`, `stack/installable.ex`, `stack/definition.ex`, `server/tool.ex` | A library registers each binding once. Activities resolve the Agent's compiled Stack. The generic tool call and a generated helper use the same command and GAM path. |
| 5. Flow and Directive | New `flow/port.ex`, `agent.ex`, `server/router.ex`, `server/runtime.ex`, `spectre_directive` | An exposed flow can call a tool and own its reply. Simple turns leave the Activity count at zero. Directive runs, resumes and revises a mission through the public API. |
| 6. Compatibility and docs | Core tests, guides, satellite tests and `spectre_ecosystem` | The three developer fixtures below compile and execute. Old helpers and checkpoints still work. Prism, Documents and Directive pass end-to-end tests. |

### First change · OTP only

The first commit contains the internal startup protocol and a small test
fixture. The fixture receives a message, updates its state and completes.
Create its Activity branch on first use. Exercise the current Root through
direct start and supervised summon with 0.4.0's Root lifetime and Managed
GAM ownership. Fixture Activities use fixture coordination for fault
injection. The Activity macro, Integration builder and real Managed GAM
rebind belong to later increments.

```text
reserve(command_id, activity_type) → {:ok, ref}
spawn_waiting(ref)                   → {:ok, pid}
adopt(ref, pid)                      → :ok
activate(ref)                        → :ok
```

The first fixture asserts that scoped failures and replay preserve the
original work.

```elixir
# Core test pseudocode. These helpers belong to the test fixture.
{:ok, root} = start_agent_fixture()
command_id = "fixture-1"
{:ok, first} = start_activity_fixture(root, command_id)
{:ok, second} = start_activity_fixture(root, "fixture-2")

crash_fixture(first)

assert fixture_status(first) == :failed
assert fixture_status(second) == :running
assert root_responds?(root)
assert replay_start(root, command_id) == {:ok, first}
```

Crash the Root before and after each startup step. A waiting child stays
inert until adopted and activated. Assert one ref, one live instance and
one start outcome for each admitted command. Crash the Activity supervisor
separately and confirm the Root still answers simple turns. Assert monitoring
and terminal state for the affected children.

Exercise `Spectre.Server.start_link/1` and `Spectre.Supervisor.summon` with
a bound Agent. Each must still return the live Root PID accepted by
`Spectre.Server.input/2`. Preserve direct start linking and supervised
ownership, including existing subject-based summon behaviour. Verify
restart through the applicable startup path. A replaced Root gets a fresh
PID. [Server startup](../lib/spectre/server.ex),
[supervised summon](../lib/spectre/otp/supervisor.ex)

### Gates before phase 3

1. **Isolation and replay.** A failed mission leaves the Root and its
   siblings available. A retried start adopts the same execution.
2. **Recovery and GAM.** Kill the Root with consent pending. Recover the
   same Domain, session, outstanding request and effect identities. The
   replacement Root can continue the consent and stale control traffic
   is rejected. Also hold an authenticated approval in flight at the
   canonical commit boundary, restart and reattach the Root, then release
   the approval. Assert one consumption of the original consent, one effect
   ref, one observed logical outcome at the replacement Root and the recorded
   result on replay. Reject a new decision from the old attachment without
   consuming the consent. Exercise a surviving Activity from the stable
   owner's binding. Run these cases in RAM and with durable storage.
3. **Revision and admission.** At the canonical GAM commit boundary, force
   the fence to win and assert that execution never starts. Force admission
   to win and assert one effect with an outcome the new revision can observe.
   Include a crash between the fence and the Activity commit.

### Developer experience gate

Use three fixture applications with shared setup for the host, model and
prompt configuration. Each example is copyable and compiles with ordinary
application code. Run end to end with deterministic providers.

| Application | Minimum demonstration |
| --- | --- |
| Hello Agent | Share a configured provider and a `:chat` prompt. Send a plain input through the existing generation and default reply path. Check zero Activity starts and controlled provider errors. |
| Agent with tool | Install Documents, select its flow with `expose :documents`, resolve a tool by its Stack binding and observe its result. Exercise a tool error without a custom error handler. |
| Agent with autonomous work | Use the three-module Directive example. Start two unnamed missions and revise one by its discovered ref through the host API. Read completion from lifecycle events and verify default failure reporting. Then reuse a named key and check that a delayed event still identifies its original instance. |

Use the existing `child_specs/2`, diagnostics subscriptions and ingress
adapters in the first compatibility pass. Show Lens, Lab and Pulse/Beam
working on those paths before deciding whether to promote `resource`,
`observe` and `ingress` to public builder functions.

**Decisive failure test.** Two agents share a Stack. Agent A starts two
missions, then crashes one after an external write. The other mission
completes, Root A answers another turn and agent B continues using the shared
resource. Reconcile the write by effect ID. The idempotent fixture observes
one external effect. With an unverifiable provider, assert `unknown` and zero
automatic resends. Agent B cannot read, signal or stop A's mission. Cover reset
and storage outage while consent is pending.

| Focused scenario | Pass condition |
| --- | --- |
| Copy the custom Activity into the fixture Stack | The local declaration binds once. Its two callbacks can complete or fail using compiled Agent Stack tools. |
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
