# Skills in 0.4

A Skill packages reusable routes and binds an ordinary `Spectre.Server` callback
module. Mounting it creates a supervised GenServer with its own assigns, private
state, workers, pending intentions and checkpoint. Its governed actions enter
**the same GAM Domain as its Agent**, through `Spectre.Server.GAM`.

This process belongs to a mount that specifies `server:`. A declarative Skill can omit that binding and leave dispatch to the root Server. [See both callback keys and the options for flow, route and mount](SERVER_CALLBACKS.md#flow-route-and-skill-options).

This is the 0.4 AgentServer path. The [0.3 Skill guide](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/SKILLS_0_3.md),
[generational Skill state](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/SKILL_STATE.md) and [data-defined runtime Skills](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/RUNTIME_SKILLS.md)
describe compatibility APIs; their Instance snapshots are not converted into
Server checkpoints.

## Declare routes, then implement behavior

```elixir
# Reusable declaration: the mount name is chosen by each Agent.
defmodule MyApp.BillingSkill do
  use Spectre.Skill,
    id: :billing,
    server: MyApp.BillingServer,
    prompt_root: "priv/billing/prompts"

  flow :billing do
    # Regex is one strategy; the mounting Agent still owns classifiers,
    # embedding, intent dataset, thresholds and routing fallbacks.
    on :refund,
      regex: ~r/^refund$/i,
      semantic_examples: ["I would like my money back"],
      protected: true

    # A different topic can be handled while a refund awaits confirmation.
    on :status, regex: ~r/^billing status$/i
  end
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer
  router strategies: [:regex, :intent_dataset, :embedding, :llm_classifier]

  # This mount may propose only this host operation. It does not grant GAM
  # authority or bypass the operation's existing confirmation requirements.
  skill MyApp.BillingSkill, as: :billing, governed: [:refund]
end

defmodule MyApp.BillingServer do
  use Spectre.Server, tools: MyApp.AI

  @impl true
  def handle_flow({:billing, :refund}, _input, ctx) do
    # The runtime constructs the Candidate and its consequence presentation.
    propose(ctx, :refund, %{invoice_id: ctx.assigns.invoice_id}, on_result: :refunded)
  end

  def handle_flow({:billing, :status}, _input, ctx), do: respond(ctx, "Checking billing.")
  def handle_flow(:unmatched, _input, ctx), do: respond(ctx, "Which invoice do you mean?")

  @impl true
  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    case String.downcase(String.trim(input.text)) do
      "yes" -> confirm_pending(ctx, pending.id)
      "no" -> reject_pending(ctx, pending.id)
      _ ->
        ctx
        |> close_pending_after(pending.id, 120_000, reason: :topic_changed)
        |> route_current_input(suspend: pending.id)
    end
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  @impl true
  def handle_result(:refunded, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Refund completed.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  # Native OTP callbacks are available too. These callbacks run in this
  # Skill's process, with the same command acquisition and GAM boundaries.
  @impl true
  def handle_info({:invoice_changed, invoice_id}, ctx),
    do: {:noreply, assign(ctx, :invoice_id, invoice_id)}

  def handle_info(message, ctx), do: super(message, ctx)
end
```

Trace the refund: `on :refund` inside `flow :billing` selects the local key `{:billing, :refund}`. The mount name is chosen independently by `as:`. Here `protected: true` asks Managed GAM to require confirmation when the callback proposes an operation. The mount allowlist and root policy decide what can be proposed. `on_result: :refunded` is the tag returned with the outcome, including rejection. The status route can reply immediately.

`handle_flow` receives local `{flow, intent}` keys. `ctx.routing` retains the
mounted route, including `owner: MyApp.BillingSkill` and `scope: {:skill, :billing}`.
`ctx.skill` identifies the mount even in `init`, `handle_info` and `handle_cast`.
The host identity is unchanged. Root assigns are copied at startup; subsequent
updates are private to each runtime. `private` is never copied or checkpointed.

The Agent keeps all its recognition strategies, online intent collection,
semantic cache and training. Root routing runs once and hands the selected
route to the Skill. Targeted input and a Skill's own `route_current_input`
consider only that mount's routes, including its interrupts and fallbacks.
Root pre-route turn handlers are not run again inside the Skill.

## One Domain, independent runtimes

```text
Application supervision
└── AgentServer
    ├── Automatic GAM boundary / Domain / Sequencer + ledger
    └── Skill supervisor (one_for_one)
        ├── Billing Server.Runtime
        └── Research Server.Runtime

Agent and Skill commands → Server.GAM → same Domain → Act → executor → Outcome
```

The Domain runs separately and is created automatically by the root AgentServer.
Spectre does not create a new Domain or grant when mounting a Skill. The child
receives the same pinned boundary and its mount restrictions; application
`skill_options` cannot replace either.

**A separate Skill process is not a separate GAM.** The child reuses the root's
automatic integration; the application configures `gam:` once when starting the
root AgentServer. Do not start another Domain, copy its ledger, construct a
Skill-specific Host or install another consent ingress for each mount.

| Shared by Agent and mounted Skill Servers | Owned by each Server |
| --- | --- |
| GAM Domain, authority ledger and automatic execution boundary | GenServer mailbox and application callbacks |
| Root identity, configured operation authority and standard ingress | Assigns, workers, result continuations and streams |
| Recorded Evidence, Decisions, Acts, Outcomes and Duties | Pending intentions and their presentation correlation |
| Stack installation and selected supervised runtime resources | Checkpoint under the mount's own key |

The shared ledger retains the originating mount, module, interaction and command
for each Skill proposal. Separate checkpoints preserve local continuations;
they do not create copies of the authority history or independent permission.

Cognition and workers can run concurrently. The kernel orders admission in the
shared ledger; an admitted execution does not hold the Agent mailbox. Existing
GAM rules still determine whether effects can proceed together. The contract
follows the [GAM manifesto](https://spectre.guide/en/governed-act-model).

`governed:` lists the host operation references a mount may propose. With no
explicit list, it defaults to the targets of the existing `bind:` mapping;
with neither, the list is empty. Direct logical `propose` names are resolved
through that mapping. A scoped Kinetic operation must retain its full reference,
for example `{{:skill, :research}, :kinetic, :send_email}` and have a matching
allowed operation entry. Stack registration alone does not authorize a Skill to act.

### Record which Skill proposed an action

The runtime records authenticated invocation Evidence automatically. The record
contains mount, module, interaction, command, operation and Domain/Scope/principal
references. It attributes the proposal; it does not grant authority or constitute
consent. Every Candidate retains this evidence.

The normal presentation/approval path remains unchanged. Timer closure uses the
same lifecycle ingress and coherent checkpoint/journal as the Agent. Closing an
intention does not erase a GAM Duty or imply that an uncertain effect was cancelled.

### Two Skills waiting for consent

Research can prepare an email while Knowledge prepares a memory write. Both
proposals enter the same Domain, but produce separate pending intentions and
Presentations. The UI first acknowledges rendering each exact presentation;
its subsequent decision identifies the originating mount:

```elixir
# Called by the configured consumer after rendering the relevant presentation.
# These references come from the actual presentation events, not from model text.
Spectre.Server.presented(agent, email_presentation_ref)
Spectre.Server.decide(agent, :research, email_presentation_ref, :confirm)

Spectre.Server.presented(agent, memory_presentation_ref)
Spectre.Server.decide(agent, :knowledge, memory_presentation_ref, :reject)
```

Rendering acknowledgement is not consent. The email decision does not approve
the memory write, and swapping a mount or reusing a stale presentation is
rejected. Both histories remain visible through `Spectre.Server.gam_view(agent)`
to an authorized consumer. Only an observed successful Outcome establishes
execution success. The [LiveView showcase](DEMO.md) exercises parallel requests,
isolated confirmations and native Skill messages against this shared Domain.

## Calling and answering Skills

Normal Agent input automatically reaches the Skill whose route matched:

```elixir
{:ok, interaction} = Spectre.Server.input(agent, "refund")
```

A Server callback can delegate work explicitly:

```elixir
def handle_flow({:support, :investigate}, input, ctx) do
  delegate(ctx, :research, input, on_result: :research_started)
end

def handle_result(:research_started, {:delegated, %{skill: :research, interaction: id}}, ctx) do
  assign(ctx, :research_interaction, id) |> respond("Research started.")
end

# The Agent receives correlated output while remaining available for input.
def handle_skill(:research, {:response, interaction, text, _metadata}, ctx) do
  assign(ctx, :last_research, %{interaction: interaction, text: text})
  |> no_response()
end
```

The consumer receives `{Spectre.Server, agent_pid, {:skill, mount, event}}`.
`preview` and `preview_end` are relayed directly to that consumer; they do not
run `handle_skill/3` or write the Agent checkpoint for every token. A bounded
history of child process identities preserves stream closure after a Skill
restart. Losing the stream owner cancels its cognitive transport.
Responses and streams retain their child interaction id. Automatic routing also
emits `{:delegated, parent_interaction, %{skill: mount, interaction: child_id}}`
to correlate the original input with the child invocation. A pending notification
is `{:pending, interaction, pending_id}`; inspect `Server.status(skill_pid)` for
its revision, status and full wait information.

In a chat, bind the confirmation controls to the originating Skill:

```elixir
Spectre.Server.input(agent, "yes", skill: :billing)
```

For confirmation buttons, bind the exact pending identity and presentation
revision obtained from the Skill status, so an old button cannot approve a newer
question in the same Skill:

```elixir
Spectre.Server.input(agent, "yes",
  skill: :billing, pending: {pending.id, pending.revision})
```

A missing, resolved or changed wait returns `{:error, :stale_pending}`. The runtime
checks the target again when queued input reaches the callback.

Untargeted input stays with the Agent. It never guesses which Skill an ambiguous
“yes” refers to. `delegate` starts work and cannot manufacture a user-confirmation
turn. Neither acceptance nor a Skill reply is proof that an effect succeeded;
use the governed Outcome.

`handle_skill/3` and consumer notifications use the existing live notification
contract, not durable exactly-once delivery. Root history and memory are not
silently merged with each Skill's conversation. Store or project selected results
explicitly; use `Server.deliver/4` and a host delivery outbox when a downstream
continuation must survive loss of the consumer.

## Lifecycle and recovery

```elixir
{:ok, agent} = Spectre.Server.start_link(
  agent: MyApp.SupportAgent,
  consumer: self(),
  identity: %{subject: "customer-42"},
  gam: [
    storage: {:disk, "var/support/customer-42"},
    operations: %{refund: [confirm: true]}
  ],
  skill_options: %{billing: [init_arg: :billing_session, assigns: %{invoice_id: 42}]}
)

{:ok, billing} = Spectre.Server.skill_server(agent, :billing)
GenServer.cast(billing, :refresh)
```

`skill_options` supplies per-mount `init_arg` and initial `assigns`; it cannot
replace the Domain, identity, consumer or checkpoint. Each Skill has a checkpoint
key `{:spectre_skill, agent_checkpoint_key, mount_id}` in the same coordination
store. It retains scoped routing, pending revisions, inbox and outbox. Its prompt
root and handler module remain independent of the Agent's Server.

Delegation is acquired in the parent's outbox. The command id identifies the
child invocation, with deduplication in the existing bounded inbox window.
A possibly started delegation is not blindly repeated after a parent crash:
its continuation receives `{:skill_unknown, details}` for reconciliation.
Already-started governed effects use the existing GAM journal recovery.
Restored consent remains suspended and requires a fresh presentation.

`Server.cancel(agent)` cancels the Agent's current work; it does not implicitly
cancel delegated Skill work. Resolve its runtime with `skill_server/2` and call
`Server.cancel(skill_pid)` when that is intended. Neither call rolls back an
admitted effect or closes a pending intention; use the pending lifecycle for that.

A child crash restarts that child. Stopping or killing the Agent terminates the
Skill subtree. If the Skill supervisor exceeds its restart intensity, failure
escalates to the Agent's supervisor. Governed workers already released to GAM
retain the existing reconciliation semantics; killing an owner is not effect
cancellation. The root runtime drains its governed workers before closing the
automatic Domain; application-owned stores must outlive that drain.

Mounts without `server:` remain declarative and dispatch their scoped key to the
Agent Server. Existing 0.3 workflow bodies and generational private state are not
silently executed or migrated by the 0.4 owner.

See the [nine-package integration](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md) and its
Skill scenario for Lens, Kinetic, Mnemonic, Prism, Beam, Directive, Pulse, Ledger
and Lab running through the same callback/runtime/GAM path.

## Try the process tree interactively

The [LiveView showcase](DEMO.md) mounts Research and Knowledge Skills using all
nine installed packages. It shows actual pending identities, stream previews,
local email receipts and the shared GAM projection. Spectre automatically creates
the Domain and stores its authority history on local disk. Each browser connection
uses a new identity; reconnect does not silently restore an earlier session.

## Prompt roots in Skill Servers

`use Spectre.Server, prompt_root: "priv/billing/prompts"` works on a mounted
Skill Server as well as the root Server. The override is bound to that Server's
runtime scope; the root Agent's Server cannot replace another Skill's assets.
Without a Server override, prompts resolve from the Skill declaration as before.
The normal path/symlink containment checks still apply.
