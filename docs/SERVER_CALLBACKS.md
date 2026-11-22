# Server callbacks, dispatch order and contracts

Choose a callback by the event you need to handle. Look up who calls it, what it receives, what to return, and which options connect a route to the next piece of work.

## Where to write the code

Running `mix spectre.gen.agent MyApp.SupportAgent --server` creates two modules and a test. Write `flow` and `on` in `lib/my_app/support_agent.ex`. Write the `handle_*` functions inside `use Spectre.Server` in `lib/my_app/support_server.ex`. The Agent’s `server: MyApp.SupportServer` connects them. In `test/my_app/support_agent_test.exs` send input to the process and observe the consumer message.

An immediate reply takes one `handle_flow/3` clause. Add `handle_result/3` to customize an asynchronous result. Work can also start at initialization or from an OTP message. For a first run, [try the complete mail example](HANDLER_WALKTHROUGH.md).

## When each callback runs

```text
startup → init(arg, ctx)
input → normalization and input pipeline
      ├─ global interrupt matches → suspend foreground wait → handle_flow
      ├─ owned wait addressed or matched → the owner's handle_result
      ├─ foreground wait → handle_pending
      └─ otherwise → optional root turn handlers
                     ├─ early reply → handle_result(:pre_route, ...)
                     └─ continue → router → handle_flow(key or :unmatched, ...)
returned context → acquire queued commands in order
      ├─ respond → consumer message
      ├─ generate / classify / call_actor → worker → handle_result
      └─ propose → handle_action → GAM → consent if required → outcome → handle_result
```

This traces ordinary user input. A decision addressed to a presentation goes directly to the targeted wait and revision. A Skill receiving a route already selected by the root skips a second recognition pass. Input preparation failure can go directly to `handle_result(:input, {:error, reason}, ctx)`. OTP messages may arrive between these events. Clauses of the **same** function follow ordinary Elixir pattern matching: put the specific cases before the catch-all.

## What input and context contain

With `Server.input(server, %{"text" => "send", "meta" => %{"locale" => "it"}})` the caller receives `{:ok, interaction_id}` if input is accepted. The callback receives a struct:

```elixir
%Spectre.Input{text: "send", meta: %{"locale" => "it"},
               raw: %{"text" => "send", "meta" => %{"locale" => "it"}}, source: nil}
```

This is normalization before any input transformations. `text` is the text to recognize, `meta` carries auxiliary data, `raw` retains the original input, and `source` describes provenance when supplied. A plain string works too. The application supplies the authenticated identity.

`%Spectre.Server.Context{}` is the callback’s view. Read `ctx.identity`, `ctx.session`, `ctx.skill`, `ctx.interaction`, `ctx.input`, `ctx.routing`, `ctx.memory` and `ctx.pending` when present. `get_pending(ctx, id)` also finds suspended waits. Store portable application state with `assign(ctx, key, value)` and local timer or monitor references with `put_private/3`. Return the context for **this** call: a pipeline such as `ctx |> assign(:seen, true) |> respond("OK")` preserves both the state and the command.

## All conversation callbacks

| Signature | Trigger, return and default |
| --- | --- |
| `init(arg, ctx)` | Startup or reset. `arg` comes from `:init_arg`. Return `{:ok, ctx}` (default), `{:ok, ctx, action}`, `:ignore` or `{:stop, reason}`. Initialize assigns with recovered values in mind. |
| `handle_flow(key, input, ctx)` | Selected route or `:unmatched`. Return context. An exposed Flow receives its local label and owns its command continuations. The Server handles its own routes and the fallback. [Reusable flows](AGENT_SERVER.md#reusable-flows-and-targeted-answers) |
| `handle_pending(pending, input, ctx)` | New input for a foreground wait. Return context. The default resolves `%{kind: :reply, id: id}` with `{:ok, input}`. For `:consent` it confirms, rejects or explains the presentation again. |
| `handle_action(action, ctx)` | On a governed proposal, before admission. Receives `%{operation: op, args: args, metadata: meta}`. Return `:default`, `:confirm`, `{:confirm, policy_map}` or `{:reject, reason}`. Use it to narrow policy for this request. |
| `handle_result(tag, result, ctx)` | A command completes, a result is delivered or an error arrives. Return context. The default replies with generated text, continues a plan, handles errors and uncertain outcomes, or stays silent for other results. |
| `handle_skill(mount, event, ctx)` | The root receives a Skill event, e.g. `{:response, id, text, meta}`. Return context. Default is silent. Preview and diagnostics notifications use a separate path. |
| `handle_activity(identity, event, ctx)` | The Root receives a lifecycle event for a supervised Activity. `identity.ref` identifies the execution and `identity.revision` identifies its current revision. Return context. |
| `handle_approval_inbox(event, ctx)` | The external approver inbox reports events such as receipt, duplicate, decision, storage error or a configured tick. Return `:default` or updated context. The human choice enters through the approval API. |

## OTP messages and optional contracts

For application messages use the GenServer callbacks with context as the state. The runtime consumes its internal worker and timer messages. In the tuples below, `action` can be `{:continue, value}`, `:hibernate`, `:infinity` or a nonnegative timeout in milliseconds.

| Signature | Trigger and return |
| --- | --- |
| `handle_call(request, from, ctx)` | Synchronous call. Use `{:reply, reply, ctx}`, optionally with a fourth `action`; use `{:noreply, ctx}` for a later `GenServer.reply/2`. Default replies with an unsupported-call error. |
| `handle_cast(message, ctx)` | Asynchronous cast. Return `{:noreply, ctx}` (default) or `{:noreply, ctx, action}`. |
| `handle_info(message, ctx)` | Application message, timer or monitor. Same returns as `handle_cast/2`. |
| `handle_continue(value, ctx)` | Runs work requested with `{:continue, value}`. Same returns as `handle_cast/2`. |
| `terminate(reason, ctx)` | Shutdown or reset: clean up application resources when OTP invokes this callback. Return value ignored, defaults to `:ok`. |
| `code_change(old_vsn, ctx, extra)` | OTP upgrade: `{:ok, ctx}` or `{:error, reason}`. Default keeps context. |
| `format_status(status)` | OTP inspection. Receives a filtered status map and returns a map. Default passes it through. |
| `assigns_schema()` | Optional assigns schema. A field map or `nil` (default). |
| `continuation_contracts()` | Optional schema for tags and result shapes. When enabled, declare every explicit `on_result:` tag. Defaults to `nil`. |

OTP message callbacks can also stop with `{:stop, reason, ctx}`; a synchronous call can return `{:stop, reason, reply, ctx}`. Conversation callbacks such as `handle_flow/3` return context directly. When customizing only selected cases, finish with a `super(...)` clause to keep the other defaults.

## Flow, route and Skill options

| Declaration | Effect and reason to use it |
| --- | --- |
| `flow :mail, defaults: [...]` | Groups routes. Defaults flow down to routes and nested flows; the more specific setting wins. |
| `on :send, regex: ~r/^send$/i` | Names the intent and matches one or more patterns. The key is `{:mail, :send}`; two nested flows produce e.g. `{[:support, :mail], :send}`. |
| `bag:`, `jaro:`, `semantic_examples:` | Text examples for string similarity (bag/Jaro) or vector similarity (embedding). Enable the corresponding router strategy and configure a vector provider for embeddings. |
| `match_with:`, `check:`, `checks:` | Restrict the strategies eligible for a route or filter it by input text and metadata. For example `check: {:language, ["it"]}`. |
| `collect_intent:`, `dataset_lookup:` | The first enables collection of eligible examples for this route; the second can exclude it from dataset lookup. Training is a separate step. |
| `protected: true` | Marks the route in routing context. A proposal made in that context requires confirmation in Managed GAM. A plain text reply proceeds normally. Omitting it (default `false`) still leaves the operation policy in force. |
| `use Spectre.Skill, id: ..., server: ...` | With `server:` the mount has its own process and callbacks and shares the Domain. Without it the root Server handles the declarative routes. |
| `skill Module, as: ..., bind: ..., governed: [...]` | `as:` chooses a local name (default: Skill ID). `bind:` maps logical references to concrete actions. `governed:` restricts the mount to listed operations within the root’s grants. |

For example, mount `BillingSkill` as `:invoices`. If the Skill declares `flow :billing` and `on :refund`, its Server receives `{:billing, :refund}` with `ctx.skill.id == :invoices`. For a declarative mount without a Server, the root receives `{{{:skill, :invoices}, :billing}, :refund}`. Set `confirm: true` in `gam: [operations: %{refund: [confirm: true]}]` to require consent for that operation even when proposed on other routes.

## From a command to the second argument of handle_result

| Helper | Result and options |
| --- | --- |
| `respond(ctx, text)`, `no_response(ctx)` | The first emits `{:response, interaction, text, metadata}` to the consumer inside `{Spectre.Server, pid, event}`. The second stays silent. A literal reply has no success callback. |
| `generate(ctx, prompt, opts)` | `{:generated, %{text: text, proposals: proposals}}` with the standard service. `input:` and `assigns:` feed the prompt, `planning:` prepares proposals, `stream:` enables streaming, `preview:` accepts `:auto`, `:off` or `:required`. |
| `classify(ctx, input, opts)` | `{:classified, label}` or error. `choices:` supplies alternatives and `context:` adds context. Your callback chooses what to do with the label. |
| `propose(ctx, operation, args, opts)` | GAM outcome, e.g. `{:governed, %{outcome: %{status: :succeeded}}}`, `{:consent, :rejected}`, `{:consent, :expired}`, `{:governed_unknown, details}` or an error. Check status before announcing success. The host owns effect timeouts. |
| `call_actor(ctx, pid, request, opts)` | The reply from `GenServer.call`, or `{:error, reason}`. `timeout:` bounds the worker wait. |
| `delegate(ctx, mount, input, opts)` | `{:delegated, %{skill: mount, interaction: id}}` on handoff. The child’s eventual reply arrives separately as a Skill event. |
| `await_input`, `await_reply`, `resolve_await` | `await_input(ctx, id, opts)` waits for foreground input. The default resolves with `{:ok, input}`. `await_reply` waits in the background; `resolve_await(ctx, id, result)` delivers that result. Default timeout is 30 s; `:infinity` is allowed. |
| Installed helper | A cognitive tool delivers its adapter’s projected value. A governed effect delivers its GAM result. `on_result:` selects the continuation, `timeout:` applies on supported paths and `confirmation:` on governed ones. |

When you omit `on_result:`, the tag for `generate`, `classify`, `propose`, `call_actor` and `delegate` is the command name. For a wait it is the wait ID, and for an installed tool it is the helper name. A tag such as `:sent` can therefore receive success or failure. Reconcile uncertain results before repeating an effect.

To customize a wait, use `confirm_pending`, `reject_pending` or `explain_pending` with `pending.id`. To switch topics, `route_current_input(ctx, suspend: pending.id)` suspends the wait and reroutes the turn; `resume_pending` brings it back. `close_pending`, `close_pending_after` and `cancel_pending_close` manage application closure. Consent has its own expiry. See [router strategies](ROUTING.md), [Skill and tool examples](SKILLS.md) and [external approvals](EXTERNAL_APPROVALS.md).

## Customizing policy and wait duration

For confirmation on every proposal, use `confirm: true` in the operation configuration. When the rule depends on the current request, the Server can return e.g. `{:confirm, %{message: "Confirm delivery?", expires_in: 60_000}}` from `handle_action/2`. The message accompanies the proposal material. Duration is in milliseconds and is bounded by host policy.

If the conversation changes topic, `close_pending_after(ctx, pending.id, 120_000, reason: :idle, if_revision: pending.revision)` schedules closure of that version of the wait. Use `reason:` to explain why, `policy_ref:` to identify an application rule, `if_revision:` to avoid closing a newer version, and `if_schedule:` to target the exact schedule. The runtime owns the timer by default; with `timer: :application` the app owns the OTP wakeup. [Complete pending lifecycle examples](PENDING_LIFECYCLE.md).
