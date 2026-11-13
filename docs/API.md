# Spectre 0.4 API guide

New applications use a declarative `Spectre.Agent` and an application
`Spectre.Server`, backed by `Spectre.Stack`. This page maps the actual API to
that architecture. [PUBLIC_API.md](PUBLIC_API.md) lists checked callable
contracts; [Stack tools](STACK_TOOLS.md) documents the additional tool-descriptor
contract whose full surface is not yet in that machine-checked list.

## Start and address an owner

```elixir
{:ok, pid} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: "account-42",
  identity: %{account_id: "account-42"},
  consumer: self()
)

{:ok, interaction_id} = Spectre.Server.input(pid, "What does it cost?")
status = Spectre.Server.status(pid)
```

The Agent must bind `server: MyApp.SupportServer`. Repeated summons for the same
Agent and canonical Subject share one supervised local owner. Direct
`Spectre.Server.start_link/1` also supports OTP supervision through `child_spec/1`.
Without a Subject, each start creates a separate process. Subject naming is not
authentication and does not establish a GAM Scope.

Input returns an acceptance/id, not the completed answer. Configure a consumer
for response and preview events; see [AgentServer](AGENT_SERVER.md). Do not mix
this asynchronous protocol with a legacy `Spectre.Turn` result.

## Implement callbacks

| Callback | Return |
| --- | --- |
| `init(arg, ctx)` | `{:ok, ctx}`, optionally an OTP action; `:ignore` or `{:stop, reason}` |
| `handle_flow(route, input, ctx)` | Updated Context containing next-step commands |
| `handle_pending(pending, input, ctx)` | Updated Context |
| `handle_result(tag, result, ctx)` | Updated Context |
| `handle_call(request, from, ctx)` | Ordinary OTP reply/noreply/stop tuple using Context |
| `handle_cast`, `handle_info`, `handle_continue` | Ordinary OTP tuple using Context |
| `terminate`, `code_change`, `format_status` | Declared Server callback contract |

`use Spectre.Server` supplies overridable defaults. Delegate unmatched result
clauses with `super(tag, result, ctx)` when appropriate. Keep callbacks short;
workers own slow cognitive services and `call_actor` requests. Native direct
calls still have ordinary OTP blocking semantics.

`assign/2,3` changes portable application data. `put_private/2,3`,
`get_private/2,3` and `delete_private/2` manage process-local values excluded from
checkpoints. Identity, Agent, input, routing and pending are read-only views.
`get_pending(ctx, id)` looks up an existing foreground or suspended intention.

## Return commands

| Helper | Meaning |
| --- | --- |
| `respond(ctx, content, opts \\ [])` | Produce text or render a named reply prompt. |
| `generate(ctx, prompt, opts \\ [])` | Ask the configured response model; result is `{:generated, response}`. |
| `classify(ctx, input, opts \\ [])` | Classify using the configured classifier/service and declared choices. |
| `propose(ctx, operation, args, opts \\ [])` | Submit a concrete operation through the host GAM bridge. |
| `call_actor(ctx, actor, request, opts \\ [])` | Run a GenServer request in a worker. |
| `await_reply(ctx, id, opts \\ [])` | Register a background actor wait. |
| `await_input(ctx, id, opts \\ [])` | Register a foreground user-answer wait. |
| `resolve_await(ctx, id, result)` | Complete a registered wait. |
| `route_current_input(ctx, opts \\ [])` | Route the same input, optionally suspending a pending intention. |
| `no_response(ctx)` | Explicitly finish without sending an answer. |

Helpers append commands and return Context. They do not synchronously return a
model answer, initialized library runtime or execution receipt. `on_result:`
selects a continuation tag. Conversation callbacks must choose a next step.
Installed helpers follow the same acquisition protocol in every callback path.

The standard classification service returns `{:classified, label}`; an error
remains `{:error, reason}`. A label is recognition evidence, never consent.
The standard generated response contains public `text` and, when explicit
planning is deferred, private consolidated `model_output`. The latter is for
the planner continuation, not a consumer preview.

## Pending policy and timers

`confirm_pending`, `reject_pending`, `explain_pending` and `resume_pending` act
on the identified pending intention. Confirmation is checked against the
original response, current presentation and scope. A new topic can schedule
closure and suspend the old intention:

```elixir
ctx
|> close_pending_after(pending.id, 60_000, reason: :topic_changed)
|> route_current_input(suspend: pending.id)
```

`close_pending`, `close_pending_after` and `cancel_pending_close` require the
durable lifecycle configuration described in [Pending lifecycle](PENDING_LIFECYCLE.md).
Native application timers are supported with `timer: :application`, a private
OTP timer reference and revision/schedule guards. Closing a conversation does
not fabricate user rejection or dispose of an unresolved GAM Duty.

## Governed results

Configure `gam: {Spectre.Server.GAM, host_config}` with an authenticated scope,
a closed operation-binding map and durable journal. The host's candidate
builder maps application arguments to a concrete Candidate. Presentation and
response interpretation are host functions when consent is required.

Admission is `Decision.outcome`; observed execution is `Outcome.status`.
Use `{:governed, %{outcome: %{status: :succeeded}}}` to report observed success.
`{:governed_unknown, details}` and `{:tool_unknown, details}` are uncertainty.
Do not reinterpret a timeout as definitive failure or blindly reissue an effect.
See [GAM](GAM.md) and [Actions](ACTIONS.md).

## Install and extend tools

`c:Spectre.Stack.Installable.tools/1` returns named descriptors with a closed
operation set. `use Spectre.Server, tools: MyApp.AI` generates local helpers.
Cognitive adapters prepare, invoke and project portable results. Governed
operations normalize to `propose` before outbox acquisition and require a
standard GAM binding. Package `bind:` config selects an operation, not authority.

See [Stack tools](STACK_TOOLS.md) for exact descriptor shape, callbacks,
retry rules, errors, memory isolation and checkpoint inspection.

## Persist and reconcile

Use `checkpoint: {disk_store, key}` or `{StoreModule, store_ref, key}`.
Store callbacks are `fetch/2`, `put_new/3`, `compare_and_swap/4` and `delete/3`.
The Server's checkpoint and GAM command journal have separate identities and
responsibilities. Use a distinct conversation key.

`Spectre.Server.deliver/4` durably acquires externally recovered results.
Governed delivery resolves a kernel reference rather than trusting arbitrary
invented Outcome data. `Spectre.Server.OutcomeDispatcher` requires explicit
host tracking and a recovery/delivery adapter; installation alone does not wire
all continuations. Delivery is at least once, with a bounded deduplication window.

A `checkpoint_migrator` may change application data and explicitly map route
keys, while preserving reconciliation facts. Adapter/config drift does not
permit rerunning an old tool command under the new implementation. See
[AgentServer recovery](AGENT_SERVER.md#checkpoints-and-reconciliation).

## Dataset and classifier APIs

`Spectre.IntentDataset` exposes lookup, put, examples, review, relabel, delete,
snapshot and restore. These store labeled intent examples, not answers or
authority. Text-only rows are useful; the semantic index uses compatible vectors
only. Export, embedding preparation and classifier training remain separate
commands, documented in [Training](TRAINING.md).

## Retained compatibility API

The checked manifest also lists `ask`, `turn`, Instance, State, Run, Effect,
legacy policy/Action execution, Work/Vigil, reflection, Morph and related
interfaces. They remain for existing applications. Their state, checkpoints and
continuations are not interchangeable with Server or GAM, and their continued
availability does not mean all paths now pass through GAM.

The complete [0.3 API guide](legacy/API_0_3.md) is retained for those applications.
Use [migration](MIGRATING_TO_0_4.md) before changing ownership or effect execution.
