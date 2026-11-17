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
  identity: %{subject: "account-42"},
  consumer: self()
)

{:ok, interaction_id} = Spectre.Server.input(pid, "What does it cost?")
status = Spectre.Server.status(pid)
```

The Agent must bind `server: MyApp.SupportServer`. Repeated summons for the same
Agent and canonical Subject share one supervised local owner. Direct
`Spectre.Server.start_link/1` also supports OTP supervision through `child_spec/1`.
Without a Subject, each start creates a separate process. Subject naming is not
authentication and does not establish a GAM Scope. `identity` accepts only
`subject`, `conversation`, `task`, `tenant`, `org` and `organization`, with equivalent
atom/string keys. Unknown fields and conflicting aliases are rejected; business
metadata and provider credentials are not identity fields.

Input returns an acceptance/id, not the completed answer. Configure a consumer
for response and preview events; see [AgentServer](AGENT_SERVER.md). Do not mix
this asynchronous protocol with a legacy `Spectre.Turn` result.

## Address Skill Servers under the same GAM

Mount `Spectre.Skill, server: MyApp.SkillServer` on the Agent, then resolve the
child with `Spectre.Server.skill_server(agent, mount)`. Each mount has independent
callbacks, state, pending intentions and checkpoint, but automatically uses the
root's GAM Domain and authority ledger. There is no second `gam:` startup or
manual ingress for the child; its `governed:` allowlist can only restrict the
configured operation authority.

Use `Server.input(agent, text, skill: mount)` for targeted chat input and
`Server.decide(agent, mount, presentation_ref, :confirm)` for an explicit UI
decision after rendering acknowledgement. Consent is bound to the exact mount
and presentation. `Server.gam_view(agent)` returns the shared authority projection
to an authorized consumer, including Skill proposal provenance. Separate local
checkpoints do not split this ledger. See [Skills](SKILLS.md) for concurrency,
timers, recovery and rejection handling.

## External human consent

`Spectre.Server.receive_approval(server, message)` is the host ingress for the
transport-independent approval protocol. The transport host authenticates the
requester; Managed GAM verifies signed responses against configured human trust.
The personal Server's authenticated consumer calls `approval_presented/2` after
rendering, then `approval_decide/3` for the human's exact request and choice.
These APIs do not grant the model approval authority. See
[External approval](EXTERNAL_APPROVALS.md) for configuration, recovery, the
optional Pulse adapter and an executable example without it.

## Implement callbacks

For custom routing, model transports, storage and other extension points, see
[Behaviours and adapters](BEHAVIOURS.md). It lists the implementable contracts,
their wiring and examples; module API documentation specifies the exact types.

| Callback | Return |
| --- | --- |
| `init(arg, ctx)` | `{:ok, ctx}`, optionally an OTP action; `:ignore` or `{:stop, reason}` |
| `handle_flow(route, input, ctx)` | Updated Context containing next-step commands |
| `handle_pending(pending, input, ctx)` | Updated Context |
| `handle_result(tag, result, ctx)` | Updated Context |
| `handle_skill(skill, result, ctx)` | Updated Context after a mounted Skill result |
| `handle_action(request, ctx)` | `:default`, `:confirm`, `{:confirm, policy_context}` or `{:reject, reason}` |
| `handle_approval_inbox(event, ctx)` | `:default` or an updated Context |
| `handle_call(request, from, ctx)` | Ordinary OTP reply/noreply/stop tuple using Context |
| `handle_cast`, `handle_info`, `handle_continue` | Ordinary OTP tuple using Context |
| `terminate`, `code_change`, `format_status` | Declared Server callback contract |
| `assigns_schema/0`, `continuation_contracts/0` | Optional schemas for portable state and continuation results |

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

Configure `gam: [operations: allowed_operations, storage: {:disk, path}]` and
pass the trusted identity and consumer. AgentServer constructs its Scope, Candidate,
presentation, ingress and journal automatically. Optional `handle_action/2`
restricts business requests; `handle_pending/3` controls their conversation.
Neither callback can replace kernel admission or fabricate consent.

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

For one provider owning Server coordination, GAM history and optional historical
projections, configure `gam: [storage: {MyApp.Storage, reference}]`. Implement
the callback groups in `Spectre.Server.Store`; Spectre adapts them to the GAM
storage ports. [Domain storage](DOMAIN_STORAGE.md#custom-storage) describes the
required groups, compatibility bindings and RAM-only operation.

Use `checkpoint: {disk_store, key}` or `{StoreModule, store_ref, key}`.
Store callbacks are `fetch/2`, `put_new/3`, `compare_and_swap/4` and `delete/3`.
The Server's checkpoint and GAM command journal have separate identities and
responsibilities. Use a distinct conversation key.

`Spectre.Server.deliver/4,5` durably acquires externally recovered results.
Governed delivery resolves a kernel reference rather than trusting arbitrary
invented Outcome data. `Spectre.Server.OutcomeDispatcher` requires explicit
host tracking and a recovery/delivery adapter; installation alone does not wire
all continuations. Delivery is at least once, with a bounded deduplication window.

A `checkpoint_migrator` may change application data and explicitly map route
keys, while preserving reconciliation facts. Adapter/config drift does not
permit rerunning an old tool command under the new implementation. See
[AgentServer recovery](AGENT_SERVER.md#checkpoints-and-reconciliation).

`Spectre.Server.reset/1,2` starts a new agent session, including mounted Skills,
without replacing the root PID. `recover_storage/2` only changes the GAM storage
boundary. See [session reset](AGENT_SERVER.md#resetting-an-agent-session) for
caller authorization, pending-work guards and the explicit `storage: :ephemeral`
option.

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

The complete [0.3 API guide](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/API_0_3.md) is retained for those applications.
Use [migration](MIGRATING_TO_0_4.md) before changing ownership or effect execution.

## Submit from an application actor

`Spectre.GAM.submit(server, operation, arguments, on_result: tag)` acquires a
proposal through the root AgentServer's existing policy, outbox and GAM loop.
Only its consumer or startup `submitters: [pid]` may call it. `{:ok, command_id}`
is acquisition; the eventual result reaches `handle_result/3`. A busy runtime
returns `{:error, :busy}` without acquiring the command. Optional `key: "stable-id"` deduplicates the same
request across checkpoint recovery and rejects conflicting reuse; it does not
promise external exactly-once delivery. Submission does not supply user consent. See [Automatic GAM](MANAGED_GAM.md#submit-from-a-trusted-actor).

`Spectre.GAM.revoke(server)` lets only the root consumer revoke its application
mandate through the kernel. Existing Acts, Outcomes and Duties remain recorded,
and restart does not restore that authority.

`Spectre.GAM.resolve_duty(server, duty_ref, kind, supporting_refs: refs)` uses the
optional independent `gam: [reviewer: [identity: ..., consumer: pid]]` boundary.
Only that reviewer process may submit a disposition; the kernel checks the exact
opening, authority and existing supporting records. No reviewer means the Duty
remains open. Disposition does not rewrite the original Outcome or prove success.

The reviewer may specify its own absolute `expires_at`; its default year-9999
upper bound is independent of the operation authorization deadline. Expired
operation authority therefore does not automatically remove the ability of a
still-authorized independent reviewer to settle historical Duties.
