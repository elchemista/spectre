# Agent and Server in 0.4

This branch evolves the 0.3 runtime while retaining its core Stack,
classifiers, intent examples, training and routing pipeline.
New applications separate declarative recognition from application behaviour.
The governed kernel is imported from commit `6906258` under `Spectre.GAM`.
This guide describes the implemented core, not a completed migration of every
application or external package.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  router strategies: [:regex, :intent_dataset, :embedding,
                      :local_classifier, :llm_classifier]

  flow :support, defaults: [collect_intent: true] do
    on :pricing, semantic_examples: ["How much does it cost?"]
    on :delete_account, regex: ~r/^delete my account$/i,
      collect_intent: false, protected: true
  end
end

defmodule MyApp.SupportServer do
  use Spectre.Server, prompt_root: "priv/support/prompts"

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx) do
    generate(ctx, :pricing, on_result: :pricing)
  end

  def handle_flow({:support, :delete_account}, _input, ctx) do
    propose(ctx, :delete_my_account,
      %{account_id: ctx.identity.account_id}, on_result: :deleted)
  end

  def handle_flow(:unmatched, input, ctx) do
    case ctx.routing.reason do
      :ambiguous -> respond(ctx, "Which operation do you mean?")
      :no_match -> generate(ctx, :understand, input: input,
        planning: true, on_result: :understood)
      _failure -> respond(ctx, "Recognition is unavailable. Please try again.")
    end
  end

  @impl true
  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    case String.downcase(String.trim(input.text)) do
      "yes" -> confirm_pending(ctx, pending.id)
      "no" -> reject_pending(ctx, pending.id)
      _ -> explain_pending(ctx, pending.id)
    end
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  @impl true
  def handle_result(:pricing, {:generated, response}, ctx),
    do: respond(ctx, response.text)

  def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Account deleted.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  @impl true
  def handle_call(:price_version, _from, ctx) do
    {:reply, ctx.assigns[:price_version], ctx}
  end

  def handle_call(request, from, ctx), do: super(request, from, ctx)

  @impl true
  def handle_info({:price_version, version}, ctx) do
    {:noreply, assign(ctx, :price_version, version)}
  end

  def handle_info(message, ctx), do: super(message, ctx)
end
```

The example assumes the referenced Stack, prompts, model services and host GAM
bindings exist. Start the actual owner through `Spectre.Server.start_link/1` or
`Spectre.summon/1` with the Agent. The callback module is not a second process.

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: account.id,
  identity: %{account_id: account.id},
  assigns: %{},
  gam: {Spectre.Server.GAM, host_gam_config}
)
```

For an Agent with a `server:` binding, repeated or concurrent summons of the
same Agent and canonical Subject return one supervised local owner.
`Spectre.Server.Registry.lookup/2` finds it without starting a conversation.
Direct `Spectre.Server.start_link/1` with a Subject uses the same registry name
and can return `{:error, {:already_started, pid}}`. Without a Subject, each
start creates a new process. This is ownership within one BEAM node, not a
distributed lock or authentication of that Subject. The host supplies the
authenticated identity and Scope.

## Ownership and callbacks

`Spectre.Server.Runtime` is the actual GenServer. It consumes messages for its
own tasks, stream sessions and timers before delegating application callbacks
to the configured Server in the same process. An application catch-all cannot
accidentally consume a framework continuation. Application task and monitor
messages remain application messages.

Conversational callbacks return the updated `Spectre.Server.Context`. Helpers
such as `generate`, `respond`, `propose`, `classify`, `call_actor` and
`route_current_input` append commands. The runtime validates commands before
acquiring them. OTP callbacks return native tuples with that context in place
of ordinary GenServer state. They execute inside the owner and should return
quickly; slow work belongs in service workers. A synchronous application call
to another actor still has ordinary OTP blocking semantics.

`assigns` is application state. Identity, input, routing and pending data are
views. Returning a modified identity does not change the runtime's original
identity, and returning an old dispatch context is an error. This prevents
composition mistakes; it is not a sandbox against arbitrary code in the BEAM.

`await_reply(ctx, id, on_result: tag)` registers a **background** actor wait.
Complete it with `resolve_await(ctx, id, result)`, for example from
`handle_info/2`. It does not consume the next user message or replace an open
consent. `await_input(ctx, id, on_result: tag)` explicitly requests a
**foreground** user answer; the default `handle_pending/3` resolves that wait
with `{:ok, input}`. Both use a 30,000 ms timeout unless overridden, and accept
`:infinity`. Only one foreground wait can own the input. `call_actor/4` is the
worker-based request/reply helper when an ordinary GenServer call is sufficient.

## Where GAM intervenes

Ordinary classification, lookup, embedding and generation use Stack services
without an admission ceremony. Governed consequences use the host GAM bridge.
A HostProfile must still declare its boundary, including any governed
disclosures or consumption. No callback name exempts a governed effect.

Configure `gam: {Spectre.Server.GAM, config}` with an authenticated Scope or a
scope resolver and a closed map of operation bindings. Each binding provides a
candidate builder. Confirming operations also provide a presentation builder
and an interpreter of the original user response. These are ordinary Elixir
functions supplied by the host. See `Spectre.Server.GAM` for their signatures.

```text
input -> Router -> handle_flow -> concrete proposal
  -> authenticated Evidence and Candidate
  -> Presentation -> admitted show Act -> successful show Outcome
  -> foreground pending -> handle_pending -> original user response
  -> fixed Ingress response Evidence -> kernel admission
  -> committed Act -> Attempt -> executor -> Outcome -> handle_result
```

The Domain's fixed ingress authenticates observations and constructs approval
Evidence. A classifier label alone cannot supply consent. A route's
`protected: true` does not grant authority or identify the governed class.
Binding requirements also apply when the same operation originates in
`understand` or a planner. An actor message does not itself create an
authenticated user observation; a background effect needs a valid host basis.

`Decision.outcome` is admission (`admitted`, `refused`, `undecidable`,
`unknown_class`). `Outcome.status` describes the observed operation
(`succeeded`, `failed`, `definitive_no_effect`, `ambiguous`). Missing Outcome
does not establish failure or permission to retry.

## Pending input and fallback

Foreground pending input is handled before normal routing. A Server can use a
classifier or its own functions to distinguish confirmation, rejection,
questions and a new topic. `route_current_input(ctx, suspend: pending.id)`
suspends that pending operation and routes the same input. `resume_pending`
brings it back through the presentation contract. A generic yes after a topic
change does not approve a suspended operation.

See [Pending lifecycle](PENDING_LIFECYCLE.md) for durable intention closure,
sixty-second topic-change timers, native OTP timers with `Context.private`, and
host lifecycle observations through GAM. This API is being validated in the
core; its checkpoint and authenticated-ingress requirements are explicit.

In the GAM bridge, `consent_ttl_ms` defaults to **300,000 ms**. Use a positive
integer or explicitly choose `:infinity`. A fresh presentation receives a new
absolute deadline; journal recovery preserves the original deadline and
restores consent as suspended. Confirmation rechecks expiry after interpretation
and before submission. Expiry reaches `handle_result/3` as
`{:consent, :expired}`. The ingress receives `received_at`, `event_sequence`
and `expires_at`. A confirmation tied to an older show returns
`{:consent, :stale_input}` to the original result continuation; handle it as a
request for a current confirmation, never as approval. With a UTC millisecond
GAM clock, bind Evidence validity to
that deadline so a queued admission cannot outlive the consent.

No match and unresolved ambiguity reach `handle_flow(:unmatched, ...)` with a
reason in `ctx.routing`. A declared legacy `UNKNOWN` remains a route, separate
from a technical failure. Recognition outages retain their cause as
`{:classifier_error, reason}` when no working recognition path remains; a
normal dataset miss does not block a working classifier or LLM fallback.

## IntentDataset and training

`Spectre.IntentDataset` names labeled examples rather than cached responses.
It uses the existing supervised store and training artifacts. Management
operations include examples, update, relabel, verify, delete, snapshot and
restore. `collect_intent` replaces `learn` in new route declarations.

Text-only examples remain useful for exact lookup and training. The vector
index contains only valid compatible stored embeddings. Exact lookup does not
embed its query. Online collected examples remain unverified and excluded
from lookup by default until the configured verification/inclusion policy
permits them. Collection does not implicitly train a classifier.

Vettore quantized search is optional; Hamming chooses candidates and the full
metric reranks them. A new semantic query still requires an embedding. The
existing classifier dataset, train and eval commands remain available.

`dataset_lookup: false` explicitly excludes a route from dataset recognition.
The legacy `cache: false` still excludes built-in examples while allowing a
custom adapter to return that route. `lookup: [exact: false, semantic: true]`
selects semantic lookup without an earlier exact hit.

`mix spectre.intent_dataset.export MyApp.SupportAgent examples.jsonl` exports
verified examples by default; `--include-unverified` is explicit.
`mix spectre.intent_dataset.embed MyApp.SupportAgent source.jsonl out.jsonl`
validates labels and profiles, keeps compatible stored vectors, and embeds only
rows missing vectors with the configured Agent/Stack encoder. It does not train
a classifier or choose a remote model. Output replaces the target only after
the whole batch succeeds; incompatible or unidentified stored vectors fail
instead of being silently attributed to the current encoder.

## Streaming and persistence

The streaming worker collects output through the existing StreamAdapter
contract, validates terminal events and consolidates the plan before proposing
effects. Public previews are provisional and distinct from completion. Mixed
planner output remains buffered when an incremental public projection is
unavailable; `preview: :required` rejects that unsupported combination.

The consumer receives correlated envelopes:

```elixir
{Spectre.Server, runtime_pid, {:preview, interaction_id, generation_id, text}}
{Spectre.Server, runtime_pid, {:preview_end, interaction_id, generation_id, status}}
```

`status` is `:completed` or `{:error, reason}`. A monitored transport guard
closes the preview and requests cancellation if the worker is interrupted.
Keep both ids when updating the UI. Stream completion means the generation
ended; it is not confirmation that a proposed effect succeeded. Remote
cancellation is a request to the adapter, not proof of cancellation of an
already committed effect.

## Checkpoints and reconciliation

`Spectre.Server.Store` and its disk adapter provide versioned portable snapshots
with compare-and-swap. Configure `checkpoint: {store_process, subject_key}` on
the Server, and `store: store_process` in the GAM bridge configuration for its
command journal. Use distinct keys per conversation. The disk adapter is
intended for conversations or small groups; capacity and compaction are
operational concerns, not evidence of large-scale throughput.

A changed definition fingerprint is rejected unless the host supplies
`checkpoint_migrator: {MyApp.CheckpointMigration, :migrate}`. The callback
receives `(saved_projection, metadata)` and returns `{:ok, migrated_projection}`
or `{:error, reason}`. Metadata includes `agent`, `server`, `schema_version`,
`from` and `to`. It may adapt application data such as assigns and the active
flow/scope, but must preserve identity, active/queued input events, inbox, outbox,
pending proofs, seen events, operations and dead letters.
It cannot turn an old approval into authority for changed code. Restored
consents remain suspended and require a fresh presentation before confirmation.

For a renamed or moved route, return an explicit dispatch-key mapping as a third
element. No new DSL is required:

```elixir
def migrate(saved, _metadata) do
  migrated = %{saved | current_flow: :billing, current_scope: :agent}
  routes = %{{:support, :pricing} => {[:support, :billing], :quote}}
  {:ok, migrated, routes}
end
```

The runtime first verifies that the reconciliation facts are unchanged, then
remaps only routing hints in active/queued events, pending origins, outbox/inbox
events, route results and operation continuations. Every target must identify
exactly one currently declared route, including its mount scope when applicable.
The old key remains in `routing.previous_route_keys`; no classifier or LLM runs.
Candidate, Evidence, Act, identity, command ids and result tags are not rewritten.
A missing mapping or a nonexistent/ambiguous target fails closed.

The bridge journals the exact Candidate and presentation before releasing an
effect. Runtime acquisition of the result and its continuation precedes journal
release. Nonterminal Acts remain in checkpointed `operations`, including their
original result tag, even after the short-lived journal is released. A timeout
or worker crash with an uncertain governed effect produces
`{:governed_unknown, details}` and retains reconciliation work; it does not
establish failure or authorize a blind retry. An uncertain consent stays
registered without owning the foreground, so other input can proceed. Its TTL
cannot discard a possible execution or its late result. Reconciliation or the
actual result settles the original continuation; a late show stays suspended
when another wait owns the foreground.

`Spectre.Server.deliver/4` requires a checkpoint for durable delivery. Governed
delivery uses `{:governed_ref, reference}` to resolve real kernel records and
check their Scope and continuation; an invented `{:governed, payload}` is
rejected. `Spectre.Server.OutcomeDispatcher` persists host continuations,
recovers facts and redelivers with stable identities. The host must explicitly
track operations and provide its recovery/delivery adapter; installing a
dispatcher does not connect every application continuation automatically.
Delivery is at least once. Callback code may run again after a crash, and
deduplication has a bounded recent-event window. Unfinished cognitive services
and `call_actor` commands can also be repeated after restart; actor requests
that must be deduplicated need an application idempotency key. Consequential
actor work must use a declared governed operation. Effects must remain commands
through the governed boundary. Callback failures are quarantined as dead
letters instead of causing an endless replay loop.

## Migration boundaries

The existing Instance, Session, Skill, Work/Vigil, Directive, reflection and Morph APIs
remain available for compatibility. Their continued availability is not proof
that every old execution path has been migrated behind the new GAM boundary.
Inventory the actual effects, hooks, checkpoints and package versions used by
an application before replacing its owner. In particular, migrating a nominal
delete action is insufficient when anonymization happens in an after-delivery
hook or another branch.

Skill route scopes and prompt roots are preserved by the new Router. This does
not migrate every Skill workflow, private state, effect or recovery path to the
new owner. The memory bridge likewise provides a history-oriented legacy state
projection; adapters relying on the complete old Instance state need an audit.

External packages have separate migration work:

| Package | Current compatibility boundary |
| --- | --- |
| Kinetic | Declares Spectre `~> 0.3.3` for its test dependency, which excludes 0.4. The incremental public planner projection still needs a package adapter. |
| Mnemonic | Declares Spectre `~> 0.3.3`; the new memory bridge is not proof of complete package compatibility. |
| Beam | Declares Spectre `~> 0.3.3` for its test dependency; 0.4 integration is not verified by that constraint. |
| Directive | Declares Spectre `~> 0.3.3`; its legacy workflow contracts need adaptation and verification. |
| Prism and Pulse | Declare `~> 0.4.0` but use the previous 0.4 authoring APIs, including Agent Collection/Observer/Turn or RequestBuilder. The version constraint does not establish compatibility with the new Agent/Server split. |

Those sibling repositories are not migrated by this core branch. Legacy
Instance checkpoints are not automatically converted into Server checkpoints
or GAM consent Evidence. `freelance` is a reference application only; its
Client/Freelancer flows, production services and alternate anonymization paths
have not been migrated here.

The architecture and full acceptance plan remain in the source checkout at
`docs/proposals/agent-server-gam-from-0.3.it.md`.
The implementation status in `docs/proposals/implementation-status.it.md` separates
core changes from remaining migration and validation work. Production host
isolation and application/package integration require their own verification.
