# GAM in Spectre 0.4

AgentServer manages GAM automatically. For startup, application callbacks and
the boundary between application policy and kernel invariants, see
[Automatic GAM](MANAGED_GAM.md).

Spectre 0.4 imports the Governed Act Model kernel under `Spectre.GAM` and
connects it to AgentServer through `Spectre.Server.GAM`. It does not redefine
the model. The source of its principles is the
[GAM manifesto](https://spectre.guide/en/governed-act-model).

This guide explains the integration. An application still has to define its
host boundary and authorization model; installing Spectre does not grant an
agent permission to send email, delete accounts or save personal data.

## What is governed

A classifier can recognize `:delete_account` before any deletion is proposed.
Ordinary routing, embedding, lookup and generation use the configured cognitive
services without automatically asking the user for permission at every step.
Your Server then proposes a concrete consequence with a subject, object and
arguments; that proposal enters the host's GAM binding.

This default is not a universal exemption for model calls or reads. The host
may declare protected-data access, disclosure, resource consumption, model use,
presentation or delegation part of its governed surface. Those transitions
must cross the corresponding boundary. Developer configuration permits the
framework to use a component; it does not authorize all business consequences
that component could suggest.

The manifesto distinguishes four concepts:

| Concept | Practical meaning in an application |
| --- | --- |
| Mandate | Where authority comes from, whom and what it covers, its purpose and limits |
| Evidence | What supports a proposition, with provenance and validity; information alone is not permission |
| Act | The recorded exercise of admitted authority, committed before the executor receives capability |
| Duty | An unresolved obligation to reconcile authority, effects and evidence; silence or restart does not erase it |

A candidate is a proposal. A Decision is the admission result. An Act is an
authorized commitment. An Outcome records the observed execution result. These
are distinct even when an application displays a short message to the user.

## Where GAM enters the loop

```text
input → recognition → handle_flow / handle_result
                         ↓
                  propose(operation, args)
                         ↓
             runtime-owned Scope + frozen Candidate
                         ↓
            optional presentation and consent workflow
                         ↓
                 kernel admission Decision
                         ↓ only if admitted
              committed Act → Attempt → executor
                         ↓
                  observed Outcome → handle_result
```

A deterministic regex route and a model-generated Kinetic proposal use the same
operation binding. `protected: true` is route metadata that requests the
confirmation path; it neither grants authority nor supplies the operation's
class or mandate. A generated tool descriptor also does not grant permission.

The Server command outbox and GAM command journal support recovery. Before a
worker can release a governed consequence, the kernel must record the admitted
Act. If the worker loses contact after execution starts, the Server reconciles
with recorded facts instead of assuming that the effect never happened.

## Configure the automatic boundary

The application supplies an authenticated identity, declares which registered
operations it allows, and selects storage. AgentServer owns the Domain, Scope,
record construction, standard ingress and execution protocol:

```elixir
{:ok, server} = Spectre.Server.start_link(
  agent: MyApp.SupportAgent,
  subject: account.id,
  identity: %{subject: account.id},
  consumer: self(),
  gam: [
    storage: {:disk, "var/support/" <> to_string(account.id)},
    operations: %{delete_account: [confirm: true]}
  ]
)
```

The delete operation must have a registered effect adapter. A `handle_action/2`
callback can reject the proposed account, require confirmation, or freeze business
context. It cannot grant authority or execute deletion itself. The consumer renders
and acknowledges the presentation, then submits the user's separate decision.
See [Automatic GAM](MANAGED_GAM.md) for the transport and persistence contract.

`Spectre.GAM` also exposes the kernel's standalone protocol API for integrations
outside AgentServer. That low-level API is not a second Server startup mode and
is not required to author an Agent or Skill. Its callers must preserve the same
admission, commitment, evidence and execution rules.

## Agent and Skill servers share one Domain

The root AgentServer automatically creates the GAM connection used by its
mounted Skill Servers. Each Skill runs in a separate GenServer with its own
continuations, pending intentions and checkpoint; all governed proposals enter
the **same Domain and authority ledger**. There is no per-Skill Host, duplicate
ledger or additional grant to provision.

The root's operation configuration and each mount's `governed:` restrictions
both apply. The runtime records Skill invocation provenance, and the shared
kernel orders admission even when workers run concurrently. Consent identifies
the originating Skill and exact presentation; approval in one Skill cannot
approve another. Timers use the same lifecycle ingress and cannot erase a Duty.
See [Skills](SKILLS.md) for the process tree and two-Skill example.

## Consent is attached to what was shown

For a confirming operation, the bridge prepares a Presentation and submits its
show through admission. The show Act needs a successful show Outcome before a
response can approve the effect. The original response reaches the Domain's
fixed ingress; a classifier label alone cannot mint approval Evidence.

The presentation binds the candidate and relevant material. A “yes” must approve
that shown consequence, not a later changed recipient, payload, purpose or
cost. `handle_pending` manages the conversation around this protocol:

```elixir
def handle_pending(%{kind: :consent} = pending, input, ctx) do
  case String.downcase(String.trim(input.text)) do
    "yes" -> confirm_pending(ctx, pending.id)
    "no" -> reject_pending(ctx, pending.id)
    "pricing" ->
      ctx
      |> close_pending_after(pending.id, 60_000, reason: :topic_changed)
      |> route_current_input(suspend: pending.id)
    _ -> explain_pending(ctx, pending.id)
  end
end

def handle_pending(pending, input, ctx), do: super(pending, input, ctx)
```

The helper selects the pending intention; the host interpreter and ingress
still validate the original response. An application can use classification to
help choose its conversational branch without treating classification as
consent. The runtime records the timer through its lifecycle ingress; durable storage
preserves the schedule across restart.

Topic changes suspend the intention. A later `resume_pending` creates a fresh
presentation. Recovery does not silently reactivate old consent, and a generic
“yes” on another topic cannot approve it. Default consent expiry is five minutes;
`:infinity` explicitly disables it. Closure and expiry record lifecycle facts. Neither fabricates a rejection or
reverses an already committed Act.

## Handle facts, not optimistic completion

Admission Decision outcomes are `:admitted`, `:refused`, `:undecidable` and
`:unknown_class`. Actual Outcome statuses are `:succeeded`, `:failed`,
`:definitive_no_effect` and `:ambiguous`. They are different vocabularies because
authorization and execution are different questions.

```elixir
def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
  do: respond(ctx, "Account deleted.")

def handle_result(:deleted, {:governed, %{decision: %{outcome: :refused}}}, ctx),
  do: respond(ctx, "This deletion was not permitted.")

def handle_result(:deleted, {:governed_unknown, _details}, ctx),
  do: respond(ctx, "The deletion is still under verification.")

def handle_result(tag, result, ctx), do: super(tag, result, ctx)
```

These clauses illustrate selected results, not exhaustive business handling.
An ambiguous outcome or a lost connection must not be presented as definitive
failure/no effect or used as a reason for blind retry. Reconciliation needs
observations from the actual executor/host; an expired conversation does not
close a Duty created by uncertain execution.

## Boundary limits

Server callbacks are trusted Elixir code. Calling an external API directly from
`handle_info` can bypass the command/GAM path; the framework cannot sandbox it.
The host must route governed effects through its admitted executors and enforce
that boundary at the actual resource. Audit evidence cannot retroactively
authorize a bypass.

The existing `Spectre.Governance` APIs for definition changes and the 0.3 policy
DSL are distinct from the imported `Spectre.GAM` act kernel. Do not treat an old
policy declaration as a migrated mandate. Follow [Migration](MIGRATING_TO_0_4.md)
and retain history when changing runtime ownership.

### Responses from an independent Presentation recipient

A Scope remains bound to its opening context. The fixed authenticated ingress
may nevertheless observe an exact Presentation response from another declared
recipient in that Scope. Only this response Evidence can cross that boundary:
its issuer/context/source must match the declared recipient and approval source,
and the prepared Presentation, show Act and successful Outcome must already
validate. Replay applies the same checks. This grants no query, Mind Turn,
proposal or execution authority to that recipient. Managed GAM uses this narrow
contract for [external human approvals](MANAGED_GAM.md#external-human-approval).
