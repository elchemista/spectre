# Agent, Server and Activities in 0.4.1

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

This example expects a Stack named `MyApp.AI`, an application response model and
the `:pricing` and `:understand` prompt assets under `priv/support/prompts`.
Configure an encoder for `:embedding` and a classifier for the corresponding
router strategies, or select only the configured strategies. `planning: true`
allows the configured planner to prepare proposals from model output.
The fallback passes the original input to that prompt. The host must register
and permit any resulting governed operation. [Configure providers](PROVIDERS.md).

`:pricing` is used as both a prompt name and a chosen result tag in this
example. `:deleted` receives the outcome of the `:delete_my_account` operation.
`:understood` uses the default result handler through `super/3`.
The OTP calls read and update the portable `:price_version` assign.
Start the associated runtime through `Spectre.Server.start_link/1` or
`Spectre.summon/1` with the Agent.

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: account.id,
  identity: %{subject: account.id},
  consumer: self(),
  assigns: %{},
  gam: [
    storage: {:disk, "var/support/" <> to_string(account.id)},
    operations: %{delete_my_account: [confirm: true]}
  ]
)
```

The example takes `account.id` from application authentication. `subject:`
selects the registered owner while `identity:` supplies identity data.
`consumer:` receives chat and lifecycle messages. `storage:` selects the
data directory for this account's durable coordination and GAM history, and
`operations:` configures the operation and its `confirm:` policy.

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

Use `await_reply(ctx, id, on_result: tag)` to wait for background work. Complete
it with `resolve_await(ctx, id, result)`, for example from `handle_info/2`.
Use `await_input` for a human answer. A Flow or Activity can publish a question
for an exact reply while ordinary chat continues. Both helpers default to 30,000
ms and accept `:infinity`. [Reply and consent routing](SERVER_CALLBACKS.md#when-each-callback-runs).

## Run a background Activity

An Activity is one supervised execution with its own callbacks, assigns and
waits. The Root can keep handling input while it runs. Use a Stack-local Activity
for work defined by your application. An installed package can contribute a
type such as `{:directive, :mission}`. Start either type from the Root's
callback or an Activity granted permission to start children.

The following example needs only Spectre. Copy the two Elixir blocks, in order,
into `activity_demo.exs` in an Elixir project's root and run
`mix run activity_demo.exs`. The report asks a question while the Root can still
answer `status`.

```elixir
defmodule ActivityDemo.Report do
  use Spectre.Activity

  @impl true
  def handle_start(%{title: title}, ctx), do: ask_country(ctx, title)

  @impl true
  def handle_signal({:revise, title}, ctx), do: ask_country(ctx, title)
  def handle_signal(signal, ctx), do: super(signal, ctx)

  @impl Spectre.Server
  def handle_result(:country, {:ok, %Spectre.Input{text: country}}, ctx) do
    complete(ctx, %{title: ctx.assigns.title, country: country})
  end

  defp ask_country(ctx, title) do
    ctx
    |> assign(:title, title)
    |> await_input(:report_country,
      prompt: "Which country should the report cover?",
      on_result: :country
    )
  end
end

defmodule ActivityDemo.Stack do
  use Spectre.Stack
  activity(:report, ActivityDemo.Report, tools: [])
end

defmodule ActivityDemo.Server do
  use Spectre.Server

  @impl true
  def handle_flow({:work, :report}, _input, ctx) do
    start_activity(ctx, :report, %{title: "Quarterly report"}, as: :quarterly)
  end

  def handle_flow({:work, :status}, _input, ctx), do: respond(ctx, "Chat is available.")
  def handle_flow(key, input, ctx), do: super(key, input, ctx)
end

defmodule ActivityDemo.Agent do
  use Spectre.Agent, stack: ActivityDemo.Stack, server: ActivityDemo.Server

  router(strategies: [:regex])

  flow :work do
    on(:report, regex: ~r/^report$/)
    on(:status, regex: ~r/^status$/)
  end
end
```

```elixir
alias Spectre.Server

{:ok, root} = Server.start_link(agent: ActivityDemo.Agent, consumer: self())
{:ok, _interaction} = Server.input(root, "report")

{ref, id, revision} =
  receive do
    {Server, ^root,
     {:activity, %{ref: ref}, {:waiting_input, %{id: id, revision: revision, prompt: text}}}} ->
      IO.puts(text)
      {ref, id, revision}
  after
    5_000 -> raise "The report did not ask for a country"
  end

{:ok, status_id} = Server.input(root, "status")

receive do
  {Server, ^root, {:response, ^status_id, text, _metadata}} -> IO.puts(text)
after
  5_000 -> raise "The Root did not answer"
end

{:ok, _answer_id} = Server.input(root, "Italy", activity: ref, pending: {id, revision})

receive do
  {Server, ^root, {:activity, %{ref: ^ref}, {:completed, result}}} -> IO.inspect(result)
after
  5_000 -> raise "The report did not complete"
end

GenServer.stop(root)
```

`agent:` selects the compiled Agent and `consumer:` is the process receiving
the messages. `{:work, :report}` comes from `flow :work` and `on :report`.
The local Activity type `:report` comes from the Stack registration.
`%{title: "Quarterly report"}` becomes the first argument to `handle_start/2`.
`:quarterly` is an optional name for this execution. The wait uses
`:report_country` as an application-local pending ID and `:country` as its result
tag. The consumer answers with the separate wait ID and revision received in
the event. Each five-second `receive` timeout belongs to this example client.
The question itself has the default 30-second timeout. [Callback arguments and defaults](SERVER_CALLBACKS.md).

### Start options and tool scope

| Setting | Where it goes | Effect |
| --- | --- | --- |
| `as: :quarterly` | `start_activity(ctx, type, args, opts)` | Assigns a unique live name within the Root. Each unnamed start receives its own execution reference. A name becomes reusable after an execution ends. |
| `scope: [{:documents, :read}]` | Start options | Narrows tool access for this execution. `:all` (the default) adds no further restriction. An empty list permits no tools. |
| `on_result: :report_started` | Start options | Calls `handle_result(:report_started, {:ok, %{ref: ref, key: key}}, ctx)` when the execution is ready. A denied or failed start delivers `{:error, reason}`. Without a tag, the consumer still receives lifecycle events and a rejected command is reported as `{:activity_command_failed, interaction, :start_activity, error}`. |
| `tools:` and `requires:` | Stack `activity/3` or package `Spectre.Integration.activity/4` | `tools:` narrows the type's scope. `requires:` lists bindings that must exist and remain within the effective scope at startup. Defaults are `:all` and `[]` respectively. |
| `allow_children:` | Type declaration | `true` permits child starts, or pass a list of allowed types. The default is `false`. Child executions inherit the parent's upper bound and cannot launch another level of children. |
| `activities:` and `activity_tools:` | `Server.start_link/1` | `activities:` optionally allowlists types for this Root. `activity_tools:` sets the upper bound for tool access (default `:all`). |
| `max_activities:` | `Server.start_link/1` | Optional non-negative limit on reserved, starting and running executions for this Root, including children. `:infinity` is the default. A full Root rejects new work with `{:error, :activity_limit}`. `0` disables starts for the Root. |
| `max_steps:` | `Server.start_link/1` or `use Spectre.Activity` | Positive number of conversational callbacks per Activity revision, including `handle_start`, signals and asynchronous results. The default is `32`. Exceeding the budget fails the Activity with `:step_limit`. A new revision gets a fresh budget. |
| `activity_idle:` | `Server.start_link/1` or `use Spectre.Activity` | `:notify` (default) emits `:idle` once per revision and leaves the Activity available for signals. `:fail` ends it with `:activity_idle`. `:keep` skips idle notifications. |

For step and idle settings, an explicit option on the Root takes precedence over
the Activity module option. An Activity is idle when its callbacks leave no
tracked commands, workers or waits and it has no outstanding children. An
explicit `await_input` or `await_reply` keeps it active while awaiting a response.
An Activity waiting for an application message through `handle_info/2` can use
`:keep` or the default notification policy. A parent can handle each direct
child's `{:completed, value}`, `{:failed, reason}` or `:cancelled` in its
own `handle_activity/3` while it is running. Child events in that callback use a
bounded, best-effort queue.

A launch that loses its local supervisor or registry before adoption releases
its slot and name. A bounded number of these unadopted references can still
be retried by the original start command. Retrying requires an available slot
and name.

A custom Activity can declare `use Spectre.Activity, prompt_root: "priv/reports"`
for its prompt assets. Otherwise, lookup uses the Agent's configured prompt
root. A `prompt_root:` option on the Root Server applies to the Root's callbacks.

Both the type's declared scope and each launch's scope intersect with the
Root's configured scope. Activity arguments, signal payloads, terminal values and
failure reasons must be portable values allowed by the checkpoint format.
Registering or starting a type does not grant authority for a consequential
operation. A governed tool runs through the same Root's GAM admission boundary.
[Stack integrations](STACK.md) · [Managed GAM](MANAGED_GAM.md).

### Inspect, revise or cancel from the host

```elixir
{:ok, %{ref: ^ref, revision: activity_revision}} = Server.activity(root, :quarterly)

{:ok, request_id} =
  Server.signal_activity(root, ref, {:revise, "Annual report"},
    if_revision: activity_revision
  )

receive do
  {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^request_id, result}}} ->
    IO.inspect(result)
after
  5_000 -> raise "No revision outcome"
end
```

Use this host snippet while the report waits for its first answer. To add it
to the script above, place it before the call that answers `"Italy"`. Read a new
`:waiting_input` event for this ref after revision and answer with its ID and
revision. The earlier wait ID is stale.
`Server.activities(root)` lists owned executions and `Server.activity(root, ref)`
gets one. The consumer or a PID registered in the Root's `submitters:` can
inspect and control them. Call `Server.cancel_activity(root, ref)` to request
cancellation instead. For each control call, `{:ok, request_id}` means accepted
for handling. The matching `:signalled` event carries the result, usually
`{:ok, identity}` or `{:error, reason}`. Keep the execution ref if a name may be
reused. `if_revision:` rejects a command for an older revision with
`{:error, :superseded}` in the control result. By default the runtime captures
the current revision when it accepts a control. This revision belongs to the
execution. Keep the separate revision from the wait event when sending an
answer. Inside a Server callback, pass
`ctx` as the first argument and add `on_result:` to receive the result in that
callback module. A child can control its own children only where its binding
permits starts. [Lifecycle event shapes](SERVER_CALLBACKS.md#activity-callbacks-and-events).

Use the Context form even when the callback runs in the Root. Passing
`self()` selects the synchronous host form, which would call the same process.
Call the qualified host API from an application process that owns the UI
or transport.

An unknown key or ref produces `{:error, :unknown_activity}`. If a known
execution has already ended, its control result is `{:error, :inactive_activity}`.
Malformed host options produce `:invalid_activity_options` or
`:invalid_activity_revision`. A Root reset produces `:reset_busy`.

A start callback can receive `{:error, :activity_start_outcome_unknown}`
when its worker deadline elapses. The launch can still complete and emit
`:started`. A callback signal or cancellation similarly uses
`:activity_control_outcome_unknown` when its worker stops waiting. Observe
the lifecycle or query the execution before retrying. Giving a start a
logical key with `as:` lets you check whether it eventually started.

`{:revise, new_title}` retires the old wait and pending consent, increments the
revision and calls the Activity's `handle_signal/2`. The example then asks the
question again. Save the new wait ID and revision. Ordinary application signals
also reach `handle_signal/2` and keep the revision. The `{:effect, result}` signal
belongs to the runtime. An already admitted effect retains its original
identity, and the live Activity can receive the late outcome after revision.
A completion from the old revision can arrive as
`{:superseded, old_revision, {:completed, value}}`; the current revision stays
active.

### Deliver Activity output to the UI

An Activity can call `respond(ctx, "The draft is ready")`. Its Root consumer
receives the same execution ref used for inspect, signal and cancel.

```elixir
{Spectre.Server, root,
 {:activity, %{ref: ref, event_id: event_id},
  {:output, {:response, interaction_id, text, metadata}}}}
```

`event_id` lets the consumer deduplicate the notification and `interaction_id`
can be `nil` for background work. `metadata` contains the response options and
can include `message_id` for a checkpointed command. Streaming sends `:preview`
and `:preview_end` in the same `{:output, event}` wrapper. Output goes to the
consumer directly from the delivery handler. Use `handle_activity/3` for
lifecycle, or `handle_result/3` inside the Activity to continue its work.

The coordinator sends one event at a time to the Root and waits for its
acknowledgement before sending the next. Activity output is best effort. An
output event can be dropped when it exceeds 128 KiB, when 32 notifications are
already queued at the coordinator or when a local consumer has 256 messages
waiting. Store important or large results through your application and return
their reference with `complete/2`. GAM outcomes are available through the
Domain's reconciliation path.

### Failure, restart and storage recovery

A failed Activity ends that execution while the Root and sibling Activities
continue. The Root can receive an admitted effect's outcome even after its
Activity ends. Checkpoints remain available while a governed command is
unconfirmed. Cancellation closes waits and pending presentations. Admitted
effects still go through reconciliation.

On one BEAM node, a supervised Root restart can reattach to the existing
Domain and Activities. If a Root dies while its supervisor stays live, Managed
GAM waits up to `gam: [shutdown_timeout: ...]` for reattachment (30 seconds by
default). The live coordinator queues up to 256 events plus one awaiting a
Root acknowledgement. It delivers retained events to the replacement Root.
Use `event_id` when displaying activity history. After storage recovery, the Root
sees affected Activities end with `{:failed, :gam_storage_recovered}` and can
start fresh work.
[Checkpoints and reconciliation](#checkpoints-and-reconciliation).

If the coordinator stops while the Root is alive, the consumer receives
`{:activities_unavailable, :coordinator_stopped}` from the Root. A new start can
open a new coordinator. A Managed GAM or VM loss also ends the live Activity
processes. Activity checkpoints preserve recovery evidence and can remain on
disk for an uncertain governed effect. Restarting the application restores the
Root and Domain; consult GAM for already-admitted effects and start new work
explicitly. If the receipt for an earlier start was lost, recovery resumes its
original command only when the coordinator still knows that command ID.
Otherwise the continuation receives `{:error, :activity_start_outcome_unknown}`.
Transient fence failures retry with exponential backoff up to 30 seconds.

## Reusable flows and targeted answers

A Stack package can register a flow with `Spectre.Integration.flow/3`. The
Agent makes it visible to its router with `expose :documents`, or selects a
specific scope with `expose flows: [{:documents, :lookup}]`. The selected flow
receives its local route label in `handle_flow/3`, named regex captures in
`ctx.routing[:params]` and its command results in `handle_result/3`.
The Flow macro imports the Context helpers. Use the qualified `Spectre.Server`
API in the host process for operations such as `input/3` and `reset/2`.
Visible route labels are unique within an Agent. With `use Spectre.Flow.Port`,
an unmatched result uses the Server's default handler. In an ordinary Server,
delegate from the final result clause with `super(tag, result, ctx)` to retain
those defaults.

This flow expects a tool registered as `{:documents, :read}`. It passes the
document ID to that adapter and expects the projected value
`{:ok, %{title: title}}`. String keys in `ctx.routing[:params]` come from named
regex captures. The flow's own `:read` result tag defaults to the tool's
operation name. `:document_id` is the explicitly chosen result tag for an
answer to the question. [Register a package and run the Documents example](EXAMPLES.md#chat-and-reusable-documents-flow).

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
reply until its deadline. Choose a narrow regex that matches specific answers,
such as document IDs. The matcher source and text to match are limited to
1,024 bytes. Omit the matcher for a free-text question that takes only an
addressed answer. An Activity can hold such a question alongside its focused
question, each with a distinct wait reference. Addressed Activity answers go
straight to their wait without entering the Root's input pipeline, chat history
or memory. If their delivery times out, the host receives
`{:error, :activity_input_outcome_unknown}`. Successful answers arrive as
`{:ok, %Spectre.Input{}}` and
timeouts as `{:error, :expired}`. Set `timeout:` in milliseconds or to
`:infinity`. A Root-only `await_input` without a question or matcher uses
the foreground `handle_pending/3` behavior.

```elixir
# Root or Flow wait event
{Spectre.Server, root, {:waiting_input, %{id: id, revision: revision}}}
Spectre.Server.input(root, "D12", pending: {id, revision})

# Activity wait event
{Spectre.Server, root,
 {:activity, %{ref: ref}, {:waiting_input, %{id: id, revision: revision}}}}
Spectre.Server.input(root, "Italy", activity: ref, pending: {id, revision})
```

`id` and `revision` come from the wait event. For an Activity also pass its
`ref` so the Root can find the correct owner. The consumer or a configured
submitter can answer an Activity wait. Revising the Activity retires its
earlier wait. Use the verified presentation reference and
`Spectre.Server.decide/4` for a GAM decision.

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

Tool descriptors, installation configuration, adapter code and exposed Flow
Port code participate in the fingerprint. Scoped adapters and Flow Ports add at
most one cached 32-byte digest per checkpoint. The digest records code
identity without embedding BEAM code, tool arguments or Flow state.
`checkpoint_version:` defaults to `1`. Increase it when an application
checkpoint contract changes independently of the compiled Agent.
If binding code changes during a live OTP upgrade with outstanding work, the
upgrade returns `:checkpoint_binding_changed`. Drain the work before the
upgrade or use a cold restart with an explicit migration.

After an explicit migration, changed in-flight contracts are
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
