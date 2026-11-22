# Agent and Server in 0.4

AgentServer manages GAM automatically. For startup, application callbacks and
the boundary between application policy and kernel invariants, see
[Automatic GAM](MANAGED_GAM.md).

Spectre 0.4 separates declarations from application behavior:
**Stack → Agent → Server**, with the Runtime owning the GenServer and GAM owning
admission of the host's declared governed consequences. The existing router,
classifiers, labeled examples, semantic lookup and training remain available.

Read [the migration guide](MIGRATING_TO_0_4.md) for the change from 0.3,
[GAM](GAM.md) for the host/kernel contract, and the
[GAM manifesto](https://spectre.guide/en/governed-act-model) for its foundations.
[Installed tools](STACK_TOOLS.md) explains generated helpers and the companion
satellite adapters. Existing application effects still require an explicit audit.

For your first Server, [run the mail walkthrough](HANDLER_WALKTHROUGH.md). For an existing Server, [look up the event that calls your handler](SERVER_CALLBACKS.md). A direct reply reaches the consumer. An asynchronous command can resume in `handle_result/3`. A foreground wait declared by the Server can take the next input in `handle_pending/3`.

## Skill Servers share the root's automatic GAM

`Spectre.Skill, server: MyApp.SkillServer` gives a mount its own GenServer and
ordinary Server callbacks. It keeps local state, workers, streams, pending
intentions and a separate checkpoint key. The root automatically supplies its
existing GAM connection, identity and shared authority ledger; the Skill does
not start another Domain or implement a Host.

Skills can run concurrently while the shared kernel orders admission. Effects
must satisfy both the root's configured operations and the mount's `governed:`
allowlist. Proposal provenance identifies the Skill. Consent targets that mount
and its exact presentation; expiry records lifecycle facts without erasing a
Duty. See [Skills](SKILLS.md) for the complete shared/local ownership table and
confirmation example.

## Root Server example

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server, prompt_root: "priv/support/prompts"

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx) do
    generate(ctx, :pricing, on_result: :pricing)
  end

  def handle_flow({:support, :delete_account}, _input, ctx) do
    propose(ctx, :delete_my_account,
      %{account_id: ctx.identity.subject}, on_result: :deleted)
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
```

The example assumes the referenced Stack, prompts, model services and registered
application effect adapters exist. Start the actual owner through `Spectre.Server.start_link/1` or
`Spectre.summon/1` with the Agent. The callback module is not a second process.

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: account.id,
  identity: %{subject: account.id},
  assigns: %{},
  gam: [
    storage: {:disk, "var/support/" <> to_string(account.id)},
    operations: %{delete_my_account: [confirm: true]}
  ]
)
```

For an Agent with a `server:` binding, repeated or concurrent summons of the
same Agent and canonical Subject return one supervised local owner.
`Spectre.Server.Registry.lookup/2` finds it without starting a conversation.
Direct `Spectre.Server.start_link/1` with a Subject uses the same registry name
and can return `{:error, {:already_started, pid}}`. Without a Subject, each
start creates a new process. This is ownership within one BEAM node, not a
distributed lock or authentication of that Subject. The host supplies the
authenticated identity; the runtime creates the Scope.

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

`assigns` is portable application state. `private` holds process-local references
and actor handles; it is not checkpointed or sent to cognitive services. Live
model, browser and memory resources stay in the named Stack runtime, not in
assigns. Identity, Agent, input, routing and pending data are views. Returning a modified identity does not change the runtime's original
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

## Run a background Activity

An Activity runs its own callbacks under the AgentServer's supervision. Start
one from a Server callback when a job needs to continue while the Root handles
other messages. Both use the Agent's installed tools and Managed GAM Domain.

```elixir
defmodule MyApp.Research do
  use Spectre.Activity

  def handle_start(%{id: id}, ctx) do
    call_tool(ctx, {:documents, :read}, %{id: id}, on_result: :document)
  end

  def handle_result(:document, {:ok, doc}, ctx), do: complete(ctx, doc)
  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.Stack do
  use Spectre.Stack

  install MyApp.Documents
  activity :research, MyApp.Research, tools: [{:documents, :read}]
end

# In the Agent's Server
def handle_flow({:work, :research}, _input, ctx) do
  start_activity(ctx, :research, %{id: "D12"}, as: :report)
end

def handle_activity(%{key: :report}, {:completed, doc}, ctx) do
  respond(ctx, doc.summary)
end
```

Use an atom for a local Activity type or `{installation, type}` for an
installed library type. An unnamed start receives a fresh execution reference.
A name identifies one active execution at a time. Lifecycle events and
`handle_activity/3` include the execution `ref` and optional `key` so callers can
tell two uses of the same name apart. The configured consumer receives
`{Spectre.Server, root, {:activity, identity, event}}`. The identity includes an
`event_id` for deduplication. The live coordinator keeps the most recent 256
unacknowledged events and replays them to a replacement Root. The checkpoint
records which events the Root has acquired.

The consumer and configured submitters can use `Spectre.Server.activities/2`
and `Spectre.Server.activity/3` to inspect work. `signal_activity/4` and
`cancel_activity/3` accept a reference or active name and return a request ID.
The outcome arrives in a `{:signalled, request_id, result}` event. Within a
callback, use the same helpers with a Context. Add `on_result:` for a tagged
callback. `if_revision:` lets a caller apply a change to a specific revision.

An Activity handles signals in `handle_signal/2`. Sending `{:revise, value}`
advances its revision and retires its open consent. A late decision for that
presentation returns `{:error, :superseded}`. Effects admitted before the
revision retain their original identity. The current Activity receives a late
admitted outcome as `handle_signal({:effect, result}, ctx)`. A governed
presentation is still acknowledged and decided through the Root. Wait for the
Activity's `{:pending, presentation_ref}` event after acknowledging the card.

Declare a `tools:` scope on the Activity and use `requires:` for bindings that
must be present at startup. At AgentServer startup, `activities:` selects
allowed types and `activity_tools:` narrows the tool scope. `scope:` narrows a
particular start further. Starting subactivities requires explicit
`allow_children:` on the parent's declaration. [Stack integrations](STACK.md)

The pilot is local to one BEAM node. A supervised Root restart can reattach to
running Activities while Managed GAM survives, including while those Activities
have governed work in flight. A failed Activity ends that execution and its
siblings continue. The Root can receive an admitted effect's outcome even after
its Activity ends. The checkpoint remains available while a governed command is
unconfirmed. Storage recovery closes the affected Activities with
`{:failed, :gam_storage_recovered}` and keeps their recent status available.
After recovery the Root can start new Activities. If a completion arrives
after the coordinator advances the revision, it emits
`{:superseded, revision, {:completed, result}}` and the current revision keeps running.

## Reusable flows and targeted answers

A Stack package can register a flow with `Spectre.Integration.flow/3`. The
Agent makes it visible to its router with `expose :documents`, or selects a
specific scope with `expose flows: [{:documents, :lookup}]`. The selected flow
receives its local route label in `handle_flow/3`, named regex captures in
`ctx.routing[:params]` and its command results in `handle_result/3`.
Visible route labels are unique within an Agent.

```elixir
defmodule MyApp.Documents.Flow do
  use Spectre.Flow.Port

  def routes, do: [on(:lookup, regex: ~r/^show document(?: (?<id>D\d+))?$/i)]

  def handle_flow(:lookup, _input, %{routing: %{params: %{"id" => id}}} = ctx)
      when is_binary(id) and id != "",
      do: load(ctx, id)

  def handle_flow(:lookup, _input, ctx) do
    ctx
    |> respond("Which document?")
    |> await_input(:document_id, accept: ~r/^D\d+$/i, on_result: :document_id)
  end

  def handle_result(:document_id, {:ok, input}, ctx), do: load(ctx, input.text)

  def handle_result(:document_id, {:error, :expired}, ctx),
    do: respond(ctx, "The question expired.")

  def handle_result(:read, {:ok, document}, ctx), do: respond(ctx, document.title)
  def handle_result(:read, {:error, _reason}, ctx), do: respond(ctx, "Document unavailable.")

  defp load(ctx, id), do: call_tool(ctx, {:documents, :read}, %{id: id})
end
```

`await_input/3` from a Flow or Activity publishes a wait reference and a
deadline. Use `prompt:` to include the question in the event. An anchored
`accept:` regex lets the focused wait take a matching message. Other input
continues to ordinary routing and the wait remains available for a targeted
reply until its deadline. Free-text questions use targeted replies. Successful
answers arrive as `{:ok, %Spectre.Input{}}` and timeouts as `{:error, :expired}`.

```elixir
# Root or Flow wait event
{Spectre.Server, root, {:waiting_input, %{id: id, revision: revision}}}
Spectre.Server.input(root, "D12", pending: {id, revision})

# Activity wait event
{Spectre.Server, root,
 {:activity, %{ref: ref}, {:waiting_input, %{id: id, revision: revision}}}}
Spectre.Server.input(root, "Italy", activity: ref, pending: {id, revision})
```

The consumer or a configured submitter can answer an Activity wait. Revising
the Activity retires its earlier wait. Use the verified presentation reference
and `Spectre.Server.decide/4` for a GAM decision.

## Where GAM intervenes

Ordinary classification, lookup, embedding and generation use Stack services
without an admission ceremony. Governed consequences use the host GAM bridge.
A HostProfile must still declare its boundary, including any governed
disclosures or consumption. No callback name exempts a governed effect.

Configure allowed `gam: [operations: ...]` and storage. Spectre constructs the
Domain, authenticated Scope, standard Candidate and presentation from registered
effects. Optional `handle_action/2` restricts business requests; `handle_pending/3`
controls conversation. Neither callback can bypass admission, fabricate consent,
or release an effect before its Act is committed. See [Automatic GAM](MANAGED_GAM.md).

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
host lifecycle observations through GAM. Its checkpoint and authenticated-ingress requirements are explicit; application
policy still belongs to ordinary Server callbacks.

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

The default runs entirely in RAM without a database or satellite package.
For durable custom storage, one module can implement `Spectre.Server.Store`
for coordination and its `ledger_*` callbacks for canonical GAM history.
Implement the complete `projection_*` group to persist the disposable read model,
or omit it to retain that projection in RAM:

```elixir
gam: [storage: {MyApp.Storage, database_reference}]
```

The same reference reaches every callback. The application owns the provider's
lifecycle, connections and migrations. The existing
`gam: [storage: :ledger, store: {StoreModule, store_ref}]` form and
`gam_domain/1` / `gam_ledger/1` integrations remain supported. A configured Ledger
Stack resource can still be discovered automatically. See
[Domain storage](DOMAIN_STORAGE.md#custom-storage) for callback groups and
durability guarantees.

For an explicit checkpoint, use `checkpoint: {store_process, subject_key}` with
the Disk adapter or `checkpoint: {StoreModule, store_ref, subject_key}` with a
custom Store. Managed storage otherwise provides its default checkpoint binding.
Give logical agents/sessions distinct stable identities, and keep explicit
checkpoint keys distinct per conversation. The disk adapter is intended for
conversations or small groups; capacity and compaction are operational concerns,
not evidence of large-scale throughput.

A changed definition fingerprint is rejected unless the host supplies
`checkpoint_migrator: {MyApp.CheckpointMigration, :migrate}`. The callback
receives `(saved_projection, metadata)` and returns `{:ok, migrated_projection}`
or `{:error, reason}`. Metadata includes `agent`, `server`, `schema_version`,
`from` and `to`. It may adapt application data such as assigns and the active
flow/scope, but must preserve identity, active/queued input events, inbox, outbox,
pending proofs, seen events, operations and dead letters.
It cannot turn an old approval into authority for changed code. Restored
consents remain suspended and require a fresh presentation before confirmation.

Tool descriptors, installation configuration and adapter code participate in
the fingerprint. After an explicit migration, changed in-flight contracts are
marked without rewriting the original command, provenance or execution-start
fact. Cognitive commands complete as contract-changed or uncertain; a known
unstarted governed proposal is rejected, while a started one reconciles its
original GAM journal. Changed adapters never silently run old arguments.

Callback acquisition and result staging share a portable-state budget with
headroom for Store envelopes. Tool projections have bounded per-operation
limits as well. Invalid developer options and nonportable application state
remain programming failures; bounded input/adapter domain rejections go through
the ordinary durable result continuation.

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

`Spectre.Server.deliver/5` requires a checkpoint for durable delivery. Governed
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

## Resetting an agent session

The configured consumer resets the root through `Spectre.Server.reset/2`:

```elixir
:ok = Spectre.Server.reset(server)
%{session: session} = Spectre.Server.status(server)

# Keep this token with external work when that work is requested.
:ok = Spectre.Server.deliver(server, "reply-42", :external_reply, result,
  session: session)
```

The root PID, registered name, identity and configuration remain stable. Reset
clears conversation history, assigns, private state, queued input, pending waits
and old continuations; mounted Skill processes restart, so their PIDs change.
The root runs `terminate(:reset, context)` and initializes again from the original
startup defaults through `init/2`. Release application-owned timers, monitors,
workers and other resources in the termination callback; dropping a private
reference does not cancel its resource. Business data and externally stored
memory are not cleared. An `init/2` callback that reloads external data may bring
that data into the new session again.

Reset keeps the current backend by default. Durable storage receives a new
session generation, and restarting the same configured agent/identity resumes
that generation. Old governance history is retained. Explicit
`Spectre.Server.reset(server, storage: :ephemeral)` selects temporary RAM;
restarting the original durable configuration returns to its last durable
session. Reset does not merge those histories or erase external effects.

The call returns after activation and initialization. `timeout:` bounds reset
work and defaults to 30,000 milliseconds. Unresolved governed work returns
`{:error, :reset_busy}`; reconcile it before resetting. Reset a Skill through its
root. Successful reset emits
`{Spectre.Server, server, {:reset, %{session: token, previous_domain: old, domain: new}}}`.

Use the token from `status/1`, `Context.session` or the service context's `:session`
when starting external work, then return that same token in `deliver/5`.
After reset, arbitrary result tags require it: omission returns
`{:error, :session_required}`, and an earlier token returns
`{:error, :stale_session}`. Command and pending tags retain their original unique
continuation IDs. Fetching the current token only when an old reply arrives
would incorrectly attribute old work to the new session.

For a storage outage, use `recover_storage/2` and the configured recovery policy
instead; those preserve the running application's session state. See
[Domain storage and recovery](DOMAIN_STORAGE.md).

## Migration boundaries

Existing Instance/Run, Session, Work/Vigil and reflection APIs remain supported.
They have different checkpoint and execution contracts. Inventory an application's
effects, hooks and stored continuations before changing its owner; installing
0.4 does not automatically put old direct effects behind GAM.

Use [Migration](MIGRATING_TO_0_4.md) for the Server conversion and
[Compatibility](COMPATIBILITY.md) for the retained runtime's guide archive.
The [Stack integration](https://github.com/elchemista/spectre_ecosystem/tree/main/integration/stack_tools)
exercises the current Server/tool/GAM contracts with deterministic providers.
