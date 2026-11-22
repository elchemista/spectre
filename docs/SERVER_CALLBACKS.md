# Server callbacks, dispatch order and contracts

The Agent declares which inputs are recognizable. The Server callback module
decides what work to request. Its Runtime GenServer acquires the returned
Context, starts workers when needed and dispatches their results. Start with the
[runnable mail walkthrough](HANDLER_WALKTHROUGH.md) or the
[background Activity example](AGENT_SERVER.md#run-a-background-activity).

## Where to write the code

Run `mix spectre.gen.agent MyApp.SupportAgent --server` in your project.
`MyApp.SupportAgent` names the generated Agent and `--server` selects the
AgentServer template. Put `flow` and `on` in the Agent module. Its
`server: MyApp.SupportServer` option names the callback module. Put
`handle_flow/3`, `handle_result/3` and other Server callbacks in that module
under `use Spectre.Server`. The generated test sends input to the Server and
observes its asynchronous consumer event.

## When each callback runs

```text
Server startup → init(arg, ctx)

ordinary input → normalize and run the input pipeline
               → check global interrupt
                 ├─ matched → suspend the foreground wait → dispatch that route
                 └─ no interrupt
                    ├─ addressed input wait → resolve for that owner
                    ├─ foreground Root wait → match or handle_pending
                    ├─ matching focused Activity wait → resolve for that Activity
                    └─ pre-route handlers
                       ├─ handled text → handle_result(:pre_route, ...)
                       └─ :cont → Router → handle_flow(key or :unmatched, ...)

returned Context → acquire commands in order
                 ├─ respond → consumer message
                 ├─ generate / call_tool / call_actor → worker → handle_result
                 ├─ start_activity → supervised execution → Activity callbacks
                 └─ propose → handle_action → GAM admission and eventual result
```

A matching interrupt can take priority over an ordinary reply. An explicit GAM
decision uses its presentation reference through `Server.decide/4`, enters the
correct pending revision and reaches that owner's consent handling. It skips
ordinary route selection. A Skill called with an already selected route uses
that route immediately. Input preparation can fail before recognition and call
`handle_result(:input, {:error, reason}, ctx)`. Native OTP messages can arrive
between these steps.

A route key such as `{:mail, :send}` is a pair of **flow and intent**. Inside
that flow, `propose(ctx, :send_email, args, on_result: :sent)` uses
`:send_email` as the **operation**, `args` as the proposed material and
`:sent` as the **continuation tag you chose**. Both a successful outcome and a
rejection reach `handle_result(:sent, result, ctx)`. Pattern match the second
argument to distinguish those outcomes. Renaming the tag changes the
`on_result:` value and its matching result clauses.

## What input and context contain

```elixir
{:ok, interaction_id} =
  Spectre.Server.input(server, %{"text" => "send", "meta" => %{"locale" => "it"}})
```

Here `server` identifies the Root and the map is the input. A string also works.
The return means the input was accepted. In the callback, `input` is a
`%Spectre.Input{}` with `text`, `meta`, `raw` and `source`. The input pipeline
may transform it. `text` is the prepared text, `meta` supplies extra data,
`source` records supplied provenance and `raw` can retain the original input.
A targeted wait's answer clears `raw` before delivering the result.

| Context field | When you use it |
| --- | --- |
| `agent`, `identity`, `session` | Read the Agent module, authenticated host identity and current session. Use the session to correlate durable external callbacks across resets. |
| `interaction`, `input`, `routing`, `memory` | Read correlation, current input, recognition details and supplied memory. Lifecycle events or OTP callbacks can run without an input. |
| `skill`, `activity` | Check the owning Skill mount or the Activity's ref, optional key and revision. Each is present in its runtime. |
| `pending`, `pending_by_id` | Read the foreground wait or inspect other waits with `get_pending(ctx, id)`. |
| `assigns` | Store application data using `assign(ctx, key, value)` or `assign(ctx, map)`. Durable assigns must be portable. |
| `private` | Store live references with `put_private(ctx, key, value)`. Read with `get_private(ctx, key, default)` and remove a key with `delete_private(ctx, key)`. This data stays in the owner process. |

Use the Context supplied to the current callback. Helpers append commands.
For example, `ctx |> assign(:seen, true) |> respond("OK")` keeps both the updated
state and the reply. A foreground conversational callback completes its dispatch
by choosing a command. Use `no_response(ctx)` to choose silence explicitly.
Identity, input, route and pending views reflect runtime state.

## All conversation callbacks

| Signature | Trigger, return and default |
| --- | --- |
| `init(arg, ctx)` | Server startup or reset. The application sets `init_arg:`. Return `{:ok, ctx}` (default), `{:ok, ctx, action}`, `:ignore` or `{:stop, reason}`. Recovered assigns are already in the Context. |
| `handle_flow(key, input, ctx)` | A selected Agent route or `:unmatched`. A reusable Flow gets its local label as the key. Return a Context. The default Server fallback answers with a generic message. Declare a clause for each recognized route you own. |
| `handle_pending(pending, input, ctx)` | New input for a foreground Root or Skill wait or its consent. Return a Context. The default resolves an ordinary `:reply` with `{:ok, input}`. For `:consent`, recognized yes/no words confirm or reject and other text redisplays the presentation. Addressed Flow and Activity reply waits use their result handler. |
| `handle_action(action, ctx)` | Business-policy review before GAM admission. Read the operation, arguments and metadata. Return `:default`, `:confirm`, `{:confirm, policy_map}` or `{:reject, reason}`. The default leaves the host operation policy in force. |
| `handle_result(tag, result, ctx)` | A worker or durable delivery completes. Return a Context. The tag selects a continuation and the second argument is its outcome. See [command results](#from-a-command-to-the-second-argument-of-handle_result). |
| `handle_skill(mount, event, ctx)` | Root receives an application event from a mounted Skill, for example `{:response, id, text, metadata}`. Return a Context. The default is silent. Preview and diagnostics messages follow their own consumer paths. |
| `handle_activity(identity, event, ctx)` | Root receives an Activity lifecycle event. Return a Context. The default leaves the Root state alone. The consumer already receives the event, and the hook can run without a current input. |
| `handle_approval_inbox(event, ctx)` | Root observes external-approval inbox events, including receipt, duplicates, decisions, store errors and a configured tick. Return `:default` or a Context. Human decisions enter via the approval API. [External approvals](EXTERNAL_APPROVALS.md). |

After defining your own `handle_flow/3` clauses in a Server, add
`def handle_flow(key, input, ctx), do: super(key, input, ctx)` as the last
clause to retain the default unmatched reply and the explicit error for
a recognized route whose handler is missing.

When you add only a few cases to a Server callback, end with a clause such as
`def handle_result(tag, result, ctx), do: super(tag, result, ctx)` to retain the
other defaults. An Activity and a module using `Spectre.Flow.Port` automatically
supply a fallback for uncovered result clauses. An explicit catch-all lets your
application choose what happens for every result.

## Activity callbacks and events

`use Spectre.Activity` gives a worker the Server command helpers and these
callbacks. Each callback runs in its own Activity's runtime.

| Signature | Arguments and return |
| --- | --- |
| `handle_start(args, ctx)` | The portable value in `start_activity(ctx, type, args, opts)` is passed as `args`. Implement this callback and return a Context with the first commands. |
| `handle_signal(signal, ctx)` | Receives an application signal or `{:revise, value}` after revision. An admitted effect can later be observed as a runtime `{:effect, result}` signal. The optional default returns the Context. |
| `handle_activity(child_identity, event, ctx)` | Receives terminal events from this Activity's direct children while it is running. The optional default returns the Context. The Root still receives its own lifecycle event. |
| `handle_result(tag, result, ctx)` | Receives this execution's result. An unmatched `{:error, reason}` ends the Activity with that reason. Other unmatched results use the standard Server handler. |
| `complete(ctx, value)` and `fail(ctx, reason)` | Helpers that return a Context with a terminal command. The portable value or reason appears in the resulting lifecycle event. |

The Root consumer receives `{Spectre.Server, root, {:activity, identity, event}}`.
`identity.ref` identifies one execution, `key` is its optional application name,
`parent` identifies a parent execution when present, and `revision` and `status`
describe the execution. Lifecycle messages also include an `event_id` for
deduplication. Read the latest state with `Server.activity(root, ref)`.

| Event | Meaning |
| --- | --- |
| `:started` | Execution has been adopted and activated. |
| `:idle` | The revision has no tracked work or children and remains available to receive signals. The default idle policy emits this once per revision. |
| `{:waiting_input, %{id: id, revision: revision, prompt: prompt, deadline: deadline}}` | A question awaits its exact answer. The deadline is absolute UTC milliseconds or `nil`. |
| `{:pending, presentation_ref}` | A GAM consent is ready for a human decision. Acknowledge the presentation after rendering it and wait for this event before deciding. |
| `{:signalled, request_id, result}` | A signal or cancel result. For host calls, correlate it with the returned request ID. A successful control is separate from any resulting mission outcome. |
| `{:completed, value}`, `{:failed, reason}`, `:cancelled` | Terminal Activity statuses. |
| `{:effect, result}` | The Root can observe a governed result after the Activity revised or ended. |
| `{:superseded, revision, terminal_event}` | A completion or failure report from an older revision. The current revision may still run. |
| `{:output, event}` | An Activity reply, streaming preview or runtime notification. The event goes to the Root's consumer with the execution identity. `handle_activity/3` handles lifecycle events. |

[Start, inspect, revise and cancel an Activity](AGENT_SERVER.md#run-a-background-activity).

For ordinary input that the Root cannot relay to a waiting Activity, the
consumer can receive `{:activity_input_error, interaction_id, error}`. A
delivery timeout may still let the Activity receive the answer, so the Root
avoids also routing the same input as a separate chat request.

## OTP messages and optional contracts

For application messages use the GenServer callbacks with the Context as
state. The runtime owns its own worker and timer messages. In these tuples,
`action` can be `{:continue, value}`, `:hibernate`, `:infinity` or a
nonnegative timeout in milliseconds.

| Signature | Trigger and return |
| --- | --- |
| `handle_call(request, from, ctx)` | Synchronous call. `from` is the reply target. Return `{:reply, reply, ctx}` or `{:noreply, ctx}` for a later `GenServer.reply/2`. Either may include `action` as a final element. The default replies with an unsupported-call error. |
| `handle_cast(message, ctx)` | Asynchronous cast. Return `{:noreply, ctx}` (default) or `{:noreply, ctx, action}`. |
| `handle_info(message, ctx)` | Application message, timer or monitor. Same returns as `handle_cast/2`. |
| `handle_continue(value, ctx)` | Work requested with `{:continue, value}`. Same returns as `handle_cast/2`. |
| `terminate(reason, ctx)` | Shutdown or reset. Release app-owned resources when OTP invokes it. Return value ignored, defaults to `:ok`. |
| `code_change(old_vsn, ctx, extra)` | OTP upgrade, with previous version and supplied upgrade data. Return `{:ok, ctx}` or `{:error, reason}`. The default keeps the Context. |
| `format_status(status)` | OTP inspection. Receives and returns a status map. The default passes the filtered map through. |
| `assigns_schema()` | Optional field/type map for assigns. The default `nil` disables checks. |
| `continuation_contracts()` | Optional map from explicit result tags to allowed shapes. The default `nil` disables checks. [Schemas and validation](SERVER_CONTRACTS.md). |

OTP message callbacks can also return `{:stop, reason, ctx}`. A synchronous
call can return `{:stop, reason, reply, ctx}`.

## Flow, route and Skill options

| Declaration | Effect and reason to use it |
| --- | --- |
| `flow :mail, defaults: [...]` | Groups routes. Defaults descend into routes and nested flows. A more specific setting wins. Extensions can own namespaced flow options. |
| `on :send, regex: ~r/^send$/i` | Names the intent and matches one or more patterns. The key is `{:mail, :send}`. Nested flows produce keys such as `{[:support, :mail], :send}`. |
| `bag:`, `jaro:`, `semantic_examples:` | Example phrases for string similarity (bag/Jaro) or vector similarity (embedding). Enable the corresponding strategy and configure an encoder for embeddings. |
| `match_with:`, `check:`, `checks:` | Restrict eligible strategies or filter by input text/metadata. For example `check: {:language, ["it"]}`. [Routing options](ROUTING.md). |
| `collect_intent:`, `dataset_lookup:` | The first enables collection of eligible examples. The second can exclude a route from dataset recognition. Training runs separately. |
| `protected: true` | The selected route marks its governed proposals as requiring confirmation in Managed GAM. Literal replies and cognitive results continue through their normal paths. The operation's own policy still applies when the route omits this option. |
| `expose :documents` | Makes the single flow of that Stack installation eligible for selection. Use `expose flows: [{:documents, :lookup}]` to select a named scope. The Flow owns its continuations. [Reusable flows](AGENT_SERVER.md#reusable-flows-and-targeted-answers). |
| `use Spectre.Skill, id: ..., server: ...` | Names a reusable Skill. A supplied `server:` gives that mount its own runtime and callbacks. Omitting it leaves route dispatch in the Root. |
| `skill Module, as: ..., bind: ..., governed: [...]` | `as:` chooses a local name (default Skill ID). `bind:` maps logical references. `governed:` restricts the concrete operations available within the Root's grants. |

Mount `BillingSkill` as `:invoices` and declare `flow :billing` with
`on :refund`. A mounted Server receives `{:billing, :refund}` with
`ctx.skill.id == :invoices`. A declarative mount dispatches to the Root as
`{{{:skill, :invoices}, :billing}, :refund}`. Set
`gam: [operations: %{refund: [confirm: true]}]` to require consent for
`:refund` on all routes where that operation is allowed. [Skills](SKILLS.md).

## From a command to the second argument of handle_result

| Helper | Arguments, options and result |
| --- | --- |
| `respond(ctx, content, opts)` | A string emits `{:response, interaction, text, metadata}` to the consumer, inside `{Spectre.Server, pid, event}`. Options on a literal reply are included in metadata. An atom names a reply asset to render, with render errors delivered to `on_result:` (default `:respond`). A successful reply emits the event directly. |
| `no_response(ctx)` | Ends this dispatch without a reply. |
| `generate(ctx, prompt, opts)` | `prompt` identifies the prompt. `input:` supplies an input override, `assigns:` supplies per-call prompt data, `planning:` requests proposals (default `false`), `stream:` opts into streaming (default `false`), and `preview:` is `:auto`, `:off` or `:required`. The standard result is `{:generated, %{text: text, proposals: proposals}}` with optional provider metadata. `timeout:` bounds the work. |
| `classify(ctx, input, opts)` | The configured classifier selects from `choices:`, for example `[:chat, :research]`. `context:` can add a string or public presentation data. `timeout:` bounds the work. Result is `{:classified, label}` or `{:error, reason}`. The callback decides how to use the label. |
| `propose(ctx, operation, args, opts)` | `operation` is the registered operation and `args` is its map of material. `confirmation:` can supply stricter confirmation options, within the configured authority. GAM owns effect deadlines. Results include `{:governed, details}`, `{:consent, status}`, `{:governed_unknown, details}` and `{:error, reason}`. |
| `call_tool(ctx, {installation, operation}, args, opts)` | The pair selects the installed binding and `args` goes to its adapter. Cognitive operations accept `timeout:` and return the projected adapter value. Governed operations accept `confirmation:` and return a GAM result. `on_result:` chooses the tag for either. |
| Generated tool helper | The `tools:` Stack passed to `use Spectre.Server` imports private helpers from the package declarations. A helper's name is the default tag. Its input and result depend on that package. [Installed tools and options](STACK_TOOLS.md). |
| `call_actor(ctx, actor, request, opts)` | Calls an OTP server in a worker. `actor` is the GenServer reference and `request` is forwarded as-is. `timeout:` bounds the call. Result is the actor reply or an error such as `{:error, :timeout}`. |
| `delegate(ctx, mount, input, opts)` | Sends `input` to the named Skill mount with a bounded worker wait. Acceptance returns `{:delegated, %{skill: mount, interaction: id}}`. The Skill's eventual reply arrives separately as a Skill event. |
| `await_input(ctx, id, opts)` | `id` is an application-local pending ID. Use `prompt:` for displayed question text, `accept:` for an anchored regex matching ordinary input, and `timeout:` for the deadline. A targeted answer yields `{:ok, %Spectre.Input{}}` and expiry yields `{:error, :expired}`. [Waits and their refs](AGENT_SERVER.md#reusable-flows-and-targeted-answers). |
| `await_reply(ctx, id, opts)` and `resolve_await(ctx, id, value)` | A background wait and its resolver, for example a worker reply received in `handle_info/2`. `timeout:` defaults to 30 seconds for either kind of wait and accepts `:infinity`. The resolver forwards `value` as the result. |
| `start_activity(ctx, type, args, opts)`, `signal_activity(ctx, target, signal, opts)`, `cancel_activity(ctx, target, opts)` | Activity work and control. An explicit `on_result:` delivers the result to this callback owner. See [Activity scope and results](AGENT_SERVER.md#start-options-and-tool-scope). |

If `on_result:` is omitted, generation, classification, proposals, actor calls
and delegation use their command name. A wait uses its pending ID and
`call_tool/4` uses the operation in the installed binding. Worker timeouts
default to the Server's `worker_timeout:` or 30 seconds on ordinary workers.
Activity lifecycle events use the Activity ref regardless of any tags.

A default Server result returns generated text, continues generated proposals if
present, reports a safe error message for `{:error, reason}`, and reports
verification for an unknown tool/GAM outcome. It stays silent for other results.
A governed result can contain an Outcome with status `:succeeded`, `:failed`,
`:definitive_no_effect` or `:ambiguous`. Inspect that status before claiming
success. Reconcile uncertain effects before taking another consequential step.

## Customizing policy and wait duration

Configure `confirm: true` on an operation to require consent every time. Return
`{:confirm, %{message: "Confirm delivery?", expires_in: 60_000}}` from
`handle_action/2` when the confirmation is request-specific. `message`
accompanies the shown material and `expires_in` is a duration in milliseconds,
bounded by host policy.

Inside `handle_pending/3`, use `confirm_pending(ctx, pending.id)`,
`reject_pending(ctx, pending.id)` or `explain_pending(ctx, pending.id)` for the
current presentation. If the conversation changes topic,
`route_current_input(ctx, suspend: pending.id)` reroutes the current message
while preserving the intention. Call `resume_pending(ctx, pending.id)` to
present it again before asking for a decision.

`close_pending_after(ctx, pending.id, 120_000, reason: :idle, if_revision: pending.revision)`
schedules closure of that revision in milliseconds. `reason:` records why,
`policy_ref:` identifies an application rule, `if_revision:` guards the pending
revision and `if_schedule:` targets a particular closure schedule. The runtime
owns the timer by default. With `timer: :application` the application sends
the wakeup. [Complete pending lifecycle examples](PENDING_LIFECYCLE.md).
