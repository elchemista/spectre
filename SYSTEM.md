# The Spectre System

Spectre `0.3.3` is an OTP-native kernel for building conversational and
operational agents in Elixir. It is deliberately not a package that owns every
model, tool, memory store, browser, transport, and workflow. Those capabilities
live in focused libraries that integrate through explicit, versioned contracts.

This document explains the concepts shared by the ecosystem, what each library
is for, how the libraries compose, and why Spectre is designed as a small core
with optional packages instead of a monolithic framework.

## The Shape Of The System

```text
human channels                                      other agents
      │                                                   │
      ▼                                                   ▼
 Spectre Beam                                        Spectre Pulse
      │                                                   │
      └──────────────────────┬────────────────────────────┘
                             ▼
                  ┌─────────────────────┐
                  │    Spectre core     │
                  │                     │
                  │ Flow / Turn / Run   │
                  │ Instance / State    │
                  │ Work / Vigil        │
                  │ policy / lifecycle  │
                  └─────────────────────┘
                    │       │        │
       model choice │       │        │ memory context
                    ▼       │        ▼
             Spectre Prism  │  Spectre Mnemonic
                            │
               action plan │ mission continuity
                            ▼        ▼
                    Spectre Kinetic  Spectre Directive
                            │
                            ▼
                    providers such as
                      Spectre Lens

The host application surrounds every layer with credentials, provider clients,
authorization, durable stores, supervision, and real side-effect boundaries.
```

The dependency direction is one way: every ecosystem package depends on
Spectre, while Spectre core does not depend on any ecosystem package. Satellite
packages do not need one another at runtime. The complete set is loaded together
only by ecosystem conformance tests.

## The Core Concepts

Spectre keeps different kinds of state and work separate. That separation is
what lets optional libraries compose without competing for ownership.

| Concept | Meaning | Owner |
| --- | --- | --- |
| `Spectre.Stack` | Immutable, validated package configuration for an Agent | application definition |
| `Spectre.Agent` | Versioned behavior: routing, Flows, policies, operations, and package bindings | application code |
| `Spectre.Definition.Ref` | Content identity of one portable canonical behavior envelope | Spectre core |
| `Spectre.Definition.Manifest` | Sealed effective authority and execution closure for one Definition Ref | Spectre core + host ceiling |
| `Spectre.Definition.Store` | Immutable publication and durable adapter boundary | host adapter |
| `Spectre.Definition.Resolver` | Verified Definition, Manifest, receipt, contract, and drift resolution | Spectre core |
| `Spectre.Definition.Candidate` | Immutable bootstrap proposal for one published Definition | trusted host + Spectre core |
| `Spectre.Instance.Activation` | Generation-fenced current Definition snapshot | Spectre Instance sequencer |
| `Spectre.Event.Envelope` | Ownership-fenced input, continuation, operation, and global event | Spectre Instance sequencer |
| `Spectre.Instance.Lifecycle` | Independent admission, authority, retention, and activation axes | Spectre Instance sequencer |
| `Spectre.Skill.StateBinding` | Generation- and branch-fenced private Skill state | Spectre Instance sequencer |
| `Spectre.Foundation.Conformance` | Executable durable-format and Definition compatibility gate | Spectre core |
| `Spectre.Stack.Conformance` | Whole-ecosystem package compatibility and collision gate | Spectre core + package tests |
| `Spectre.Instance.CheckpointStore.Conformance` | Adapter-neutral canonical checkpoint CAS and restart gate | Spectre core + adapter tests |
| `Spectre.Instance.Owner.Conformance` | Local or distributed ownership, fencing, and concurrency gate | Spectre core + adapter tests |
| `Spectre.Instance.CheckpointStore.ErasureConformance` | Atomic checkpoint erasure and anti-resurrection gate | Spectre core + adapter tests |
| `Spectre.Instance.Erasure.Proof` | Privacy-safe proof scoped to stable and legacy canonical checkpoint keys | Spectre core |
| `Spectre.Doctor` | Read-only runtime, Foundation, Agent, Stack, package, and adapter-shape diagnostics | Spectre core |
| `Spectre.Projection.Audit` | Exact deterministic view of a canonical Definition | Spectre core |
| `Spectre.Experience` | Opt-in redacted observational evidence, separate from canonical Instance state | trusted host + Spectre core |
| `Spectre.Reflection` | Policy-gated deterministic projection of declared, effective, and observed facts | trusted host + Spectre core |
| `Spectre.Forge` | Inert, evidence-bound proposals that cannot publish, approve, or activate | trusted host + compiled critics |
| `Spectre.Morph` | Host-facing facade over the existing governed Definition-change path | trusted host + Spectre core |
| `Spectre.Subject` | Canonical application identity, independent of a channel identity | host application |
| `Spectre.Instance` | Local canonical owner for one `AgentRef + Subject` | Spectre core |
| `Spectre.Turn` | Public projection of the next observable conversational boundary | Spectre core |
| `Spectre.Run` | Recoverable continuation for one conversational unit | Spectre core |
| `Spectre.Action` | Closed proposal to call a declared capability | planner or deterministic Flow |
| `Spectre.Effect` | Staged side effect with policy and lifecycle state | Spectre core |
| `Spectre.Invocation` | Revision-fenced request to cross an external boundary | Spectre core |
| `Spectre.Inference.Stream` | Ephemeral one-consumer handle for a fenced stream attempt | Spectre core |
| `Spectre.Receipt.Envelope` | Portable evidence for a nondeterministic/canonical boundary | Spectre core + host sink |
| `Spectre.Work` | Durable, bounded, multi-step operational procedure | Spectre core |
| `Spectre.Vigil` | Durable recurring observation triggered by timers or events | Spectre core |
| Journal/checkpoint | Observable decisions and portable canonical recovery data | Spectre core plus host adapters |

There are two execution planes:

- The conversational plane uses Flow, Turn, and Run. It handles input, routing,
  replies, policy boundaries, staged Effects, and inference Invocations.
- The operational plane uses Work and Vigil. It handles long procedures,
  retries, progress, pause/update/resume, timers, events, and restart recovery.

A Work is not a renamed Run, and a Directive mission is not a second Instance.
Each abstraction has one job and one owner.

## Which Library To Use

| Package | Use it when you need | It deliberately does not own |
| --- | --- | --- |
| `spectre` | Agent definitions, routing, policy, state, Runs, Instances, Work, Vigil, inference/Effect lifecycle, streaming fences, receipts, checkpoints | provider SDKs, credentials, business authorization, application side effects |
| `spectre_prism` | Constraint-aware model/profile selection by purpose, modality, privacy, cost, latency, and capability, with optional bundled provider adapters | credentials, live provider sessions, provider scheduling, Run or Instance lifecycle |
| `spectre_kinetic` | Tool retrieval and validated Action planning from Action Language | authorization or execution of the selected Action |
| `spectre_mnemonic` | Active and durable memory, recall, search, consolidation, provenance, and subject-scoped context | canonical Agent state or the application database |
| `spectre_directive` | A resumable mission and evolving-plan loop with correlated questions, invocations, and outcomes | general memory, tool discovery, core Work scheduling, or Instance ownership |
| `spectre_lens` | Browser perception and browser Actions through backend-neutral protocols | browser authorization, core Effect lifecycle, or canonical process persistence |
| `spectre_beam` | Human/external channel normalization and delivery, including Telegram and WhatsApp adapters | identity inference, application consent, policy, or automatic Effect execution |
| `spectre_pulse` | Transport-independent Agent-to-Agent envelopes, discovery, routing, and delivery receipts | shared workflow state, global presence truth, or agent coordination policy |

The short distinctions are useful:

- Prism chooses **which cognitive capability** may answer.
- Kinetic chooses **which declared action** may be proposed.
- Lens supplies **browser capabilities** that a Flow or Kinetic may select.
- Mnemonic supplies **recalled context**, not canonical state.
- Directive advances **one mission and its living plan**.
- Work advances **one durable operational controller**.
- Beam crosses **human or provider channel boundaries**.
- Pulse crosses **Agent-to-Agent protocol boundaries**.

## The Names

Ecosystem packages carry evocative names rather than descriptive ones, on
purpose: a descriptive name such as "model-selection-middleware" goes stale
the moment a package grows, while a metaphor stays stable. Learn them once —
each name encodes the package's one job:

- **Prism** splits light into its components. Spectre Prism splits "call the
  model" into declared inference profiles and selects the one whose
  constraints — privacy, modality, cost, latency, depth — all hold.
- **Kinetic** is motion held ready. Spectre Kinetic turns declared application
  functions into a registry of candidate Actions and plans which one to
  propose. The energy becomes movement only when the core approves execution.
- **Mnemonic** is a memory aid, not the memory itself. Spectre Mnemonic
  recalls context for a turn; it never becomes canonical state.
- **Directive** is a mission order. Spectre Directive advances one mission and
  its living plan across many inputs.
- **Lens** is how the agent sees. Spectre Lens provides browser perception and
  browser actions, with everything it sees marked untrusted until explicitly
  converted.
- **Beam** carries signal between the agent and humans — and yes, it also runs
  on the BEAM. Spectre Beam normalizes provider channels such as Telegram and
  WhatsApp into Spectre input and delivery.
- **Pulse** is a signal between peers. Spectre Pulse moves versioned envelopes
  between agents over any transport.

The core vocabulary follows the same rule: a **Vigil** keeps watch (a durable
observation loop between triggers); **Work** is exactly what it says (a
bounded, terminating operational procedure); a **Subject** is who the work is
about; an **Instance** is the process that owns both for that Subject.

## Core 0.3.3 and satellite compatibility

The stable Spectre core is distributed through Hex:

```elixir
{:spectre, "~> 0.3.3"}
```

The satellite releases listed below belong to the historical `0.2.x` release
train. They remain owned and versioned by their repositories and must not be
assumed compatible with core `0.3.3` until their manifests and adapter suites
say so. This separation is intentional: installing the new core never silently
upgrades another `spectre_*` package.

| Package | Release | Spectre requirement |
| --- | ---: | ---: |
| `spectre` | `0.3.3` | — |
| `spectre_beam` | `0.2.0` | `~> 0.2.0` |
| `spectre_directive` | `0.2.0` | `~> 0.2.0` |
| `spectre_kinetic` | `0.2.0` | `~> 0.2.0` |
| `spectre_lens` | `0.2.0` | `~> 0.2.0` |
| `spectre_mnemonic` | `0.2.0` | `~> 0.2.0` |
| `spectre_prism` | `0.2.0` | `~> 0.2.0` |
| `spectre_pulse` | `0.2.0` | `~> 0.2.0` |

The core upgrade does not discard the recoverable historical contracts.
Permanent State and Run fixtures continue to prove that existing persisted
values remain readable where the public core contract promises it. Each
satellite owns the equivalent proof for its durable and wire formats.

Applications that intentionally remain on the complete historical `0.2.x`
stack must pin that stack consistently:

```elixir
defp deps do
  [
    {:spectre, github: "elchemista/spectre", tag: "0.2.6"},
    {:spectre_prism, github: "elchemista/spectre_prism", tag: "0.2.0"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic", tag: "0.2.0"},
    {:spectre_mnemonic, github: "elchemista/spectre_mnemonic", tag: "0.2.0"},
    {:spectre_directive, github: "elchemista/spectre_directive", tag: "0.2.0"},
    {:spectre_lens, github: "elchemista/spectre_lens", tag: "0.2.0"},
    {:spectre_beam, github: "elchemista/spectre_beam", tag: "0.2.0"},
    {:spectre_pulse, github: "elchemista/spectre_pulse", tag: "0.2.0"}
  ]
end
```

An application rarely needs all seven satellite packages. Adding one library
does not silently enable the others.

## Compose Packages With A Stack

`Spectre.Stack` is the composition boundary. Each `install` block is parsed by
that package, so package-specific words such as `model`, `isolate_by`,
`backend`, and `channel` do not become global framework macros.

```elixir
defmodule MyApp.AI do
  use Spectre.Stack, id: :my_app

  install Spectre.Prism, max_attempts: 2 do
    provider(:openrouter, MyApp.OpenRouter)
    model(:fast, id: "small-model")
    model(:deep, id: "reasoning-model")
    purpose(:route_classification, prefer: :fast)
    default(:deep)
  end

  install Spectre.Kinetic,
    mode: :closed_moves,
    actions: MyApp.Actions,
    modes: [create_report: :write]

  install Spectre.Mnemonic, namespace: :my_app do
    isolate_by([:agent, :subject, :conversation])
  end

  install(Spectre.Directive, turn_handler: true)

  install Spectre.Lens, planner_exposure: [:look, :discover] do
    backend(SpectreLens.Browsers.Lightpanda,
      instances: 2,
      protocol: SpectreLens.Protocol.Lightpanda
    )
  end

  install Spectre.Beam do
    channel(:telegram,
      type: :telegram,
      adapter: Spectre.Beam.Adapters.ExGram,
      before_decode: [MyApp.VerifyTelegramSignature]
    )
  end

  install Spectre.Pulse do
    transport(:local, Spectre.Pulse.Transports.Local)
    directory(MyApp.AgentDirectory)
  end
end
```

Bind the Stack once:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI

  router(via: [:regex, :classifier])

  flow :analysis, prism: [minimum: :deep] do
    on :EXPLAIN, regex: ~r/^explain\b/i do
      reason(:explain)
    end
  end

  flow :browser do
    on :INSPECT, regex: ~r/^inspect\b/i do
      action({:lens, :look},
        args: %{
          url: "https://example.com",
          opts: [include: [:markdown, :links]]
        },
        mode: :read
      )
    end
  end

  flow :notify_human do
    on :NOTIFY_HUMAN, regex: ~r/^notify human$/i do
      beam(:owner, via: :telegram, text: "The report is ready")
    end
  end

  flow :notify_agent do
    on :NOTIFY_AGENT, regex: ~r/^notify agent$/i do
      pulse(:researcher,
        act: :inform,
        type: "report.ready",
        data: %{report_id: "report-42"}
      )
    end
  end
end
```

Selecting a Stack activates package adapters, but activation is not
authorization. It does not make every action planner-visible, approve a
protected Effect, authenticate a channel identity, or start every runtime
resource.

## Run The Boundaries Explicitly

Live processes and secrets enter at runtime, not in the compiled Stack:

```elixir
{:ok, stack_runtime} =
  Spectre.Stack.start_link(MyApp.AI,
    packages: [lens: [binary: "/opt/lightpanda"]]
  )

{:ok, instance} =
  Spectre.instance(MyApp.SpectreSupervisor, MyApp.Agent, account_id)

{:ok, turn} =
  Spectre.turn(instance, "inspect the release page",
    stack_runtime: stack_runtime
  )

case turn.decision do
  {:awaiting, awaitable, result} ->
    MyApp.UI.present_approval(awaitable, result)

  {:needs, _effect, result} ->
    Spectre.execute(instance, result, stack_runtime: stack_runtime)

  {:reply, result} ->
    MyApp.Delivery.reply(result.reply_text)

  {:completed, outcome, _result} ->
    MyApp.Operations.record(outcome)

  {:no_response, _result} ->
    :ok
end
```

The host decides whether and where to execute. Spectre owns the deterministic
lifecycle around that decision; the package owns only its capability boundary.

## Spectre Core

Use the core alone when routing, state, policy, actions, or operational loops
are sufficient.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent

  actions(MyApp.SupportActions)

  policy :confirm_delete do
    request(:confirm_delete)
    accept(:confirmed, regex: ~r/^yes$/i)
    reject(:cancelled, regex: ~r/^no$/i)
  end

  protect(:delete_account, with: :confirm_delete)

  flow :support do
    on :HELP, regex: ~r/^help$/i do
      reply("How can I help?")
    end

    on :DELETE_ACCOUNT, regex: ~r/^delete my account$/i do
      action(:delete_account)
    end
  end
end
```

Use `reason` for inference that must not plan actions, `act` when action
planning is intentional, and an explicit `action` when the Flow already knows
the capability. Use Work for a bounded procedure that must survive beyond a
Turn:

```elixir
{:ok, work_ref, _view} =
  Spectre.start_work(instance, MyApp.ExportReport, %{report_id: "report-42"})

{:ok, view} = Spectre.loop(instance, work_ref)
{:ok, paused} = Spectre.pause_loop(instance, work_ref)
{:ok, resumed} = Spectre.resume_loop(instance, work_ref)
```

## Spectre Prism: Select The Cognitive Capability

Prism turns a set of model declarations into inference profiles and selects a
profile only when every requested constraint is satisfied.

```elixir
install Spectre.Prism, max_attempts: 2 do
  provider(:openrouter, MyApp.OpenRouter)
  model(:fast, id: "small-model")
  model(:deep, id: "reasoning-model")
  purpose(:route_classification, prefer: :fast)
  default(:deep)
  selector(Spectre.Prism.Selector.Adaptive)
end
```

Use Prism when several inference capabilities differ in privacy, modality,
context window, latency, cost, or depth. Prism ships optional adapters for
OpenAI, OpenRouter, Ollama, and Gemini behind an injectable HTTP transport;
credentials are resolved only at runtime, and live provider sessions remain
outside the compiled Stack. Prism selects and may implement provider
transports; Spectre owns the inference Invocation, Run, budget, control and
terminal commit.

## Spectre Kinetic: Plan Closed Actions

Kinetic extracts a registry of declared application functions, retrieves a
small candidate set, maps typed slots, and returns a provider-neutral Action.

```elixir
defmodule MyApp.Actions do
  use SpectreKinetic

  @al ~s(CREATE REPORT WITH: ACCOUNT="acme")
  @doc "Creates a report for an account."
  @spec create_report(String.t()) :: {:ok, map()} | {:error, term()}
  def create_report(account), do: MyApp.Reports.create(account)
end

defmodule MyApp.ReportingAgent do
  use Spectre.Agent
  use Spectre.Kinetic, actions: MyApp.Actions, modes: [create_report: :write]

  flow :reports do
    on :CREATE_REPORT, regex: ~r/^create report/i do
      act(:create_report)
    end
  end
end
```

Kinetic does not call `create_report/1` while planning. Spectre stages the
Action as an Effect, applies policy, persists lifecycle state, and crosses the
provider boundary only after explicit execution.

## Spectre Mnemonic: Recall Context Without Replacing State

Mnemonic provides hot memory, durable stores, hybrid search, graph
associations, consolidation, freshness, contradictions, and provenance.

```elixir
install Spectre.Mnemonic, namespace: :support do
  isolate_by([:agent, :subject, :conversation])
end
```

With the Stack bound, Spectre's normal memory hooks recall context before a
Run advances and remember a compact projection after commit. Standalone APIs
remain useful too:

```elixir
{:ok, _packet} =
  SpectreMnemonic.remember("Acme prefers weekly PDF reports",
    scope: {:account, "acme"},
    persist?: true
  )

{:ok, recalled} =
  SpectreMnemonic.recall("report preferences", scope: {:account, "acme"})
```

Memory can be stale, ranked, compacted, or forgotten. Canonical Agent state is
revisioned and authoritative. Keeping those concepts separate prevents a
retrieval result from silently becoming system truth.

## Spectre Directive: Advance A Mission And Living Plan

Directive is useful when a mission can ask for information, request an
invocation, revise a guided plan, and continue across several inputs.

```elixir
alias SpectreDirective.Request

{:ok, directive} =
  Spectre.Directive.new(
    mission: "Research Acme",
    success: "Return a sourced summary",
    mode: :autonomous
  )

{:request, %Request{kind: :reason} = request, directive} =
  Spectre.Directive.next(directive)

{:request, next_request, directive} =
  Spectre.Directive.respond(
    directive,
    request.id,
    {:propose_plan, [%{id: "research", title: "Research Acme"}]}
  )
```

The pure API performs no model call or side effect. The host resolves each
correlated request. Directive also offers an optional supervised runtime and
an opt-in Spectre turn handler.

Choose Directive for a mission whose plan is part of the domain. Choose core
Work for a bounded operational controller with attempts, budgets, retries,
pause/update/resume, progress, and canonical recovery. A Directive may start
or supervise application work through explicit boundaries, but it does not
replace Work or the Instance.

## Spectre Lens: Perceive And Act In A Browser

Lens separates browser lifecycle from agent-readable page semantics. It can
start Lightpanda, connect to a remote CDP endpoint, produce untrusted views,
discover goal-relevant regions, perform browser actions, and export artifacts.

```elixir
{:ok, lens} = SpectreLens.open(instances: 2)
{:ok, tab} = SpectreLens.new_tab(lens, url: "https://example.com")

{:ok, view} =
  SpectreLens.look(tab,
    include: [:markdown, :semantic_tree, :interactive, :forms, :links]
  )

{:ok, safe_context} = SpectreLens.agent_context(view)
:ok = SpectreLens.act(tab, {:click, ref: "button[type=submit]"})
:ok = SpectreLens.close(lens)
```

Top-level projections are marked `trust: :untrusted`; convert them with
`agent_context/2` before inserting browser content into a model prompt. In a
Stack, browser PIDs remain inside an explicitly started runtime and only
portable `TabRef` values may cross a Spectre checkpoint.

## Spectre Beam: Connect Human And Provider Channels

Beam normalizes provider events into Spectre input and delivers replies through
the same endpoint. It preserves conversation affinity and exposes plug stages
for authentication, enrichment, filtering, redaction, and telemetry.

```elixir
install Spectre.Beam do
  channel(:telegram,
    type: :telegram,
    adapter: Spectre.Beam.Adapters.ExGram,
    before_decode: [MyApp.VerifyTelegramSignature],
    inbound_pipeline: [MyApp.EnrichSender]
  )
end

{:ok, exchange} =
  Spectre.Beam.handle(MyApp.Agent, :telegram, raw_update,
    adapter_opts: [client: telegram_client]
  )
```

For subject-scoped continuity, the host authenticates the provider principal,
binds its `Spectre.ExternalIdentity` to a canonical Subject, then calls
`handle_instance/5`. Beam never guesses identity from a name, phone number,
conversation id, message, or model result.

Reactive delivery and proactive delivery are different boundaries. A
proactive `beam(...)` handler stages an Effect; it does not send automatically.

## Spectre Pulse: Communicate Between Agents

Pulse gives agents a versioned envelope whose meaning is independent of local
mailboxes, PubSub, WebSocket, REST, distributed Erlang, or a custom transport.

```elixir
defmodule MyApp.Researcher do
  use Spectre.Agent
  use Spectre.Pulse

  pulsing do
    identity("spectre://acme/researcher")
    advertise(capabilities: [:research])
  end

  flow :remote_requests do
    on :RESEARCH, pulse: "research.perform" do
      run(:research)
    end
  end

  def research(input, _context), do: "accepted: #{input.text}"
end
```

A sender names a logical contact and stages the protocol Effect:

```elixir
pulse(:researcher,
  act: :request,
  type: "research.perform",
  data: %{topic: "nautical market"},
  expect: "research.completed"
)
```

Pulse owns envelope validation, address resolution, route selection, and a
technical receipt. It does not promise exactly-once delivery, share Agent
state, or decide whether the recipient should accept the request.

## Common Compositions

| Application need | Suggested packages |
| --- | --- |
| Deterministic conversational service | core only |
| Provider-aware assistant with long-term context | core + Prism + Mnemonic |
| Safe tool-using agent | core + Kinetic; add Prism for model selection |
| Browser research agent | core + Lens + Kinetic + Prism; add Mnemonic for recall |
| Resumable guided mission | core + Directive; add Mnemonic for recalled context |
| Telegram or WhatsApp assistant | core + Beam; add Prism/Mnemonic as needed |
| Cooperative agents across transports | core + Pulse |
| Long-running monitored automation | core Work/Vigil plus only the capability packages its operations need |

Start with the core and one concrete need. Add a package when its boundary is
clear; do not install the entire ecosystem as a default preset.

## Why Spectre Was Built This Way

Agent systems combine several hard problems: conversation, durable operations,
inference, memory, planning, tools, browsers, human channels, agent protocols,
identity, and authorization. Putting all of them in one framework object makes
the first demo short, but it also tends to make ownership and failure behavior
implicit.

Spectre chooses a different tradeoff for five reasons.

### One canonical owner

The Instance owns canonical state and lifecycle. A memory package cannot
quietly become state, a transport cannot become a scheduler, and a planner
cannot become an executor. Crash recovery and concurrency are tractable because
there is one place where a transition becomes authoritative.

### Capabilities are explicit and replaceable

A Stack says exactly which packages exist. Logical refs and package-local DSLs
avoid a global registry where unrelated libraries can overwrite one another.
Applications can replace Prism, Kinetic, Lens, memory, or transport adapters
without rewriting the core Agent model.

### Proposal is separate from authority

Models and planners may propose an Action. Policy and deterministic lifecycle
code decide whether it becomes executable. The host still controls credentials
and the final side-effect boundary. This avoids the common shortcut where
generating a tool call also grants permission to run it.

### Portable data is separate from live infrastructure

Definitions, Runs, and checkpoints contain portable values. PIDs, sockets,
browser sessions, provider clients, and secrets stay in supervised runtime
resources supplied by the host. A restart therefore restores intent and
lifecycle without pretending that a dead connection was durable.

### Applications pay only for what they use

The core does not force browser, model-provider, vector-search, transport, or
channel SDKs into every deployment. Each library can evolve and test its own
public surface while the core remains focused on the contracts that require a
single authority.

This is not separation for its own sake. The Stack still gives applications one
place to compose capabilities, and Agent extensions remove repetitive glue.
The difference is that composition stays visible, versioned, and reversible.

### The compass: OTP and the actor model

Spectre's design questions are answered by one compass: what is the OTP shape
of this problem? The mapping is already direct, and future concepts will keep
converging on it rather than drifting toward framework-specific abstractions:

| Spectre concept | Actor-model ancestor |
| --- | --- |
| Instance | a process that owns its state and serializes writes through its mailbox |
| Runner | a supervised one-shot task: one attempt, isolated crash, no shared state |
| Stream session | a supervised `:gen_statem`: explicit demand, state timeouts, cancellation and one terminal receipt |
| Vigil | a timer- and event-driven loop that holds no live process while waiting |
| Effect / Invocation | an explicit message across a boundary, never a hidden call |
| Checkpoint | what a restart restores: intent and lifecycle, not dead connections |
| Pulse envelope | location-transparent message passing without shared state |

A new capability enters the ecosystem the same way every time: find the single
owner, make every boundary a message, make recovery a restart. If a proposed
feature has no clean actor-model shape — shared mutable state, ambient
authority, a hidden synchronous call — that is evidence against the feature,
not against the model.

## Rules For Ecosystem Packages

An ecosystem package should preserve these boundaries:

1. Depend on Spectre; never make Spectre core depend on the package.
2. Publish a `Spectre.Stack.Installable` manifest with a precise Spectre
   requirement and portable metadata.
3. Keep package DSL names inside the package's `install` block.
4. Put runtime clients, processes, credentials, and secrets behind explicit
   host-owned runtime options or supervised resources.
5. Stage Effects and Actions; do not bypass core policy or lifecycle.
6. Re-resolve live adapters after restore instead of serializing their handles.
7. Fail closed on unknown identities, capabilities, schemas, or ambiguous
   side-effect outcomes.
8. Maintain a normative public API manifest and permanent compatibility
   fixtures for persisted or wire formats.

These rules are what make a collection of libraries an ecosystem rather than
a bundle of unrelated integrations.

## Validate The Historical 0.2.x Sibling Repositories

The following command documents the historical `0.2.x` satellite train. It
requires a Spectre core checkout from that same train; do not point these
packages at the `0.3.3` core and treat a compile as proof of compatibility.
Each historical package accepts `SPECTRE_PATH` for local compatibility testing.
Pulse also accepts paths for all satellite packages and runs the complete
seven-package Stack conformance test:

```bash
SPECTRE_PATH=../spectre \
SPECTRE_BEAM_PATH=../spectre_beam \
SPECTRE_DIRECTIVE_PATH=../spectre_directive \
SPECTRE_KINETIC_PATH=../spectre_kinetic \
SPECTRE_LENS_PATH=../spectre_lens \
SPECTRE_MNEMONIC_PATH=../spectre_mnemonic \
SPECTRE_PRISM_PATH=../spectre_prism \
mix test
```

Run that command from `spectre_pulse` with a core checkout reporting `0.2.0`.
Run `SPECTRE_PATH=../spectre mix test` from every other historical sibling
repository under the same constraint. New satellites targeting core `0.3.3`
must instead declare that requirement in their Installable manifest and test
against the local `0.3.3` checkout plus the published package independently.

## Further Reading

- [Getting Started](docs/GETTING_STARTED.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Stack](docs/STACK.md)
- [Integration Boundaries](docs/INTEGRATIONS.md)
- [Work, Vigil, and the Operational Runtime](docs/OPERATIONS.md)
- [Migrating to 0.2.0](docs/MIGRATING_TO_0_2.md)
