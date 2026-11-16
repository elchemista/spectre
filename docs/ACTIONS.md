# Proposals, consent and execution in 0.4

A Server proposes an operation; the host makes it concrete; GAM decides whether
its declared consequence is admissible. An executor receives capability only
after an Act is recorded. A model response, classifier intent or route match
cannot itself execute that consequence.

The [GAM manifesto](https://spectre.guide/en/governed-act-model) defines the
boundary. [GAM in Spectre](GAM.md) maps Mandate, Evidence, Act and Duty to the
implementation and explains the automatic Domain/Scope boundary.

## Deterministic proposal

```elixir
def handle_flow({:account, :delete_account}, _input, ctx) do
  propose(ctx, :delete_my_account,
    %{account_id: ctx.identity.subject},
    on_result: :deleted)
end

def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
  do: respond(ctx, "Account deleted.")

def handle_result(:deleted, {:governed_unknown, _details}, ctx),
  do: respond(ctx, "Deletion is still being verified.")

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

Register an effect adapter for `:delete_my_account`, then permit the operation
with `gam: [operations: %{delete_my_account: [confirm: true]}]`. AgentServer
freezes authenticated identity, purpose, arguments, scope and authority into the
Candidate and owns ingress, presentation and execution. Business validation
belongs in `handle_action/2`; it may restrict a proposal but cannot bypass GAM.

The same proposal path applies inside a mounted Skill Server. The child has
independent state and pending intentions but automatically uses the root's
existing GAM Domain and authority ledger. The effect must also be permitted by
the mount's `governed:` references. Skill provenance is recorded, and consent is
bound to that mount and exact presentation; another Skill's approval cannot
authorize it. See [Skills](SKILLS.md) for concurrency and the shared/local table.

`protected: true` on an Agent route marks sensitive recognition/collection and
requests the standard bridge's confirmation path. It is not a replacement for
the operation policy, a governed class, or a mandate.

## Model-produced action language

Install Kinetic in the Stack and select that Stack's helpers in the Server:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack
  install Spectre.Kinetic, mode: :closed_moves, actions: MyApp.Actions
end

defmodule MyApp.MailServer do
  use Spectre.Server, tools: MyApp.AI, prompt_root: "priv/mail/prompts"

  def handle_flow({:mail, :compose}, _input, ctx),
    do: generate(ctx, :compose, on_result: :composed)

  def handle_result(:composed, {:generated, response}, ctx),
    do: kinetic(ctx, response, on_result: :prepared)

  def handle_result(:prepared, {:prepared, %{actions: [proposal]}}, ctx) do
    propose(ctx, proposal.operation, proposal.args,
      proposal_metadata: proposal.metadata, on_result: :sent)
  end

  def handle_result(:prepared, {:prepared, _}, ctx),
    do: respond(ctx, "Please choose one concrete message to send.")

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "The provider confirmed the send.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

The action module, model, prompt and host bindings are application dependencies;
see [the complete executable example](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md).
Kinetic receives the consolidated generation, including its private model
output, and prepares portable action data. It does not send email. Preserve
`proposal.metadata` when proposing the prepared operation.

`generate(..., planning: true)` selects the alternative automatic planning path.
The default generated-result handler processes its proposals. Choose either
that path or the explicit `kinetic` continuation; do not parse/submit both.
Partial streaming text is never an executable plan. A public preview may be
shown while supported generation is in progress, but no action is released
before consolidation and admission.

## Consent belongs to the open intention

```elixir
def handle_pending(%{kind: :consent} = pending, input, ctx) do
  case String.downcase(String.trim(input.text)) do
    "yes" -> confirm_pending(ctx, pending.id)
    "no" -> reject_pending(ctx, pending.id)
    _ -> explain_pending(ctx, pending.id)
  end
end

def handle_pending(pending, input, ctx), do: super(pending, input, ctx)
```

This handler chooses a transition. The bridge still binds the original input
to the shown Presentation through the authenticated ingress. A classifier can
help recognize responses; its output cannot stand in for approval Evidence.
Consent is specific to what was shown, including materially relevant data,
recipient, cost and purpose. A changed proposal needs the appropriate new
presentation; resuming a suspended intention does not reuse an old generic yes.

For new topics, use `route_current_input(..., suspend: pending.id)` and optionally
schedule closure. [Pending lifecycle](PENDING_LIFECYCLE.md) explains native timers,
revision guards and GAM observations. Intention closure is not effect cancellation
or Duty disposition.

## Result semantics and recovery

| Result/fact | What it establishes |
| --- | --- |
| Candidate / prepared action | A proposal, without execution authority. |
| Admission Decision | Whether that concrete proposal was admitted, refused, undecidable or unknown to the surface. |
| Act | Recorded authorized consequence before capability release. |
| Attempt | The concrete attempt under that Act. |
| Outcome `:succeeded` | Observed success supported by the executor/observer contract. |
| Outcome `:failed` or `:definitive_no_effect` | The corresponding observed conclusion, not an inference from timeout. |
| Outcome `:ambiguous`, governed/tool unknown | Uncertainty to preserve and reconcile. |

The host executor must distinguish known failure from unknown external effect.
A network timeout after submission may be ambiguous. Do not convert every
provider error into definitive failure and retry. Persisted journal identities
and GAM facts allow recovery without inventing a new consequence.

Ordinary classification and planning do not require consent simply because a
model runs. If the host declares protected access, disclosure or consumption
as governed, the corresponding path must use that boundary too. Native Server
callbacks are ordinary trusted Elixir: calling an email client directly bypasses
this protocol. Installing a package is not isolation against such code.

## Existing 0.3 action workflows

`Spectre.Effect`, the `policy`/`protect` DSL, ActionDispatcher/ActionExecutor and
Instance/Run policy continuations remain available. They have their own state
and execution contracts; they are not automatically new GAM Acts.
The [retained action reference](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/ACTIONS_0_3.md) explains those APIs.
Inventory direct effects, providers and before/after hooks when following the
[migration guide](MIGRATING_TO_0_4.md).
