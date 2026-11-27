# Pending intentions, timers and GAM observations

This guide describes the implemented 0.4 pending lifecycle API. It complements
[AgentServer](AGENT_SERVER.md), [GAM](GAM.md) and the
[migration guide](MIGRATING_TO_0_4.md). Application callbacks implement policy;
Runtime coordinates durable transitions; GAM records the authenticated lifecycle
observations. The [GAM manifesto](https://spectre.guide/en/governed-act-model)
explains why a timeout cannot silently extinguish an unresolved Duty.

A pending intention is unfinished work, such as a deletion waiting for consent
or a report waiting for a country. The Runtime correlates each wait with its
owner and continuation. The Server can suspend an intention, schedule closure
or close it. GAM can record the lifecycle of a consequential intention while
the Act and any Duty keep their own lifetimes.

## Select the reply mechanism

| You are waiting for | Server command | What the host sends |
| --- | --- | --- |
| A background result from application code | `await_reply(ctx, id, on_result: tag)` | `resolve_await(ctx, id, result)` in a callback, often `handle_info/2`. Ordinary user input continues. |
| An ordinary user answer in a Flow or Activity | `await_input(ctx, id, prompt: question, on_result: tag)` | `Server.input(root, text, pending: {wait.id, wait.revision})`. Add `activity: execution_ref` when the question belongs to an Activity. |
| Human approval for a governed operation | `propose(ctx, operation, args, on_result: tag)` or a governed tool | Render the GAM presentation, call `Server.presented(root, presentation_ref)`, then `Server.decide(root, mount, presentation_ref, decision)` when the wait is ready. Use `nil` for the Root or one of its Activities, or the mount name for a Skill. `decision` is `:confirm` or `:reject`. |

`id` is the application-local identifier supplied when creating a wait.
`wait.id` and `wait.revision` come from the `:waiting_input` event. Save those
with the question when sending an exact answer. A hosted Activity can use
`accept:` with a narrow anchored regex to claim matching ordinary input.
Omit `accept:` to require an addressed answer while the Root handles unrelated
chat. An expired or revised wait can return `{:error, :stale_pending}` to the host.
For consent the UI keeps the separate presentation reference from the
Managed GAM event. [Wait correlation](AGENT_SERVER.md#reusable-flows-and-targeted-answers).

## Pending intentions inside Skills

Each mounted Skill Server owns its pending intentions and timers. It shares the
root AgentServer's automatically configured GAM Domain, ledger and lifecycle
ingress. No Skill-specific Host or Domain is needed. Closure and expiry are
therefore visible beside the Agent's other facts, with Skill provenance, while
the Skill's own checkpoint retains its local continuation.

If two Skills are waiting at once, a decision addresses the originating mount
and exact presentation; it cannot approve a different Skill's request. Expiring
or stopping a Skill does not erase Acts, ambiguous Outcomes or Duties in the
shared Domain. See [Skills](SKILLS.md) for the confirmation and lifetime contract.

## Connect the durable lifecycle

AgentServer creates its lifecycle ingress and coherent checkpoint/journal
automatically. Select disk storage when schedules must survive restart:

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.SupportAgent,
  subject: account.id,
  identity: %{subject: account.id},
  consumer: self(),
  gam: [
    storage: {:disk, "var/support/" <> to_string(account.id)},
    operations: %{delete_my_account: [confirm: true]}
  ]
)
```

The runtime authenticates lifecycle observations through its fixed ingress and
retains their Domain, Scope and principal bindings. The application does not
implement an ingress clause or enable a separate lifecycle mode. A fabricated
map or actor message cannot become a trusted lifecycle observation.

## Change topic, keep the intention for sixty seconds

The Agent declares recognition. The Server decides how an open deletion
intention responds to a new topic:

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server

  @impl true
  def handle_flow({:support, :delete_account}, _input, ctx) do
    propose(ctx, :delete_my_account,
      %{account_id: ctx.identity.subject},
      on_result: :deleted
    )
  end

  def handle_flow({:support, :pricing}, _input, ctx) do
    respond(ctx, "Here are the subscription options.")
  end

  @impl true
  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    case String.downcase(String.trim(input.text)) do
      answer when answer in ["yes", "confirm", "confermo", "si", "sì"] ->
        confirm_pending(ctx, pending.id)

      answer when answer in ["no", "cancel", "annulla"] ->
        reject_pending(ctx, pending.id)

      "how much does it cost?" ->
        ctx
        |> close_pending_after(pending.id, 60_000,
          reason: :topic_changed,
          policy_ref: "policy:delete-intention-idle:v1"
        )
        |> route_current_input(suspend: pending.id)

      _ ->
        explain_pending(ctx, pending.id)
    end
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  @impl true
  def handle_result(:deleted, {:governed, %{outcome: %{status: :succeeded}}}, ctx) do
    respond(ctx, "Account deleted.")
  end

  def handle_result(
        :pending_lifecycle,
        {:pending_lifecycle, %{kind: :close, status: :applied}},
        ctx
      ) do
    respond(ctx, "The pending deletion request has been closed.")
  end

  def handle_result(:pending_lifecycle, {:pending_lifecycle, _report}, ctx) do
    no_response(ctx)
  end

  def handle_result(:pending_lifecycle, {:error, {:pending_lifecycle, reason}}, ctx) do
    ctx |> assign(:pending_lifecycle_error, reason) |> no_response()
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  flow :support do
    on :delete_account, regex: ~r/^delete my account$/i, protected: true
    on :pricing, regex: ~r/^how much does it cost\?$/i
  end
end
```

The Stack supplies the registered deletion effect.
`on :delete_account` supplies the route label, `:delete_my_account` is the
governed operation and `:deleted` correlates the result. `protected: true`
requires confirmation for a governed proposal made through the deletion
route. The custom handler handles the ordinary yes/no words, including
`"confermo"` and `"annulla"` delivered by `Server.decide/4`.
`policy_ref:` records the application rule and `reason:` records why the
topic-change branch scheduled closure. [Flow and result arguments](SERVER_CALLBACKS.md).

The returned commands execute in order. The runtime records the scheduled
closure, then records suspension, then routes the same pricing input. The
deletion intention remains identified by its own pending id. When its deadline
arrives, the runtime requests closure of that intention through the same audited
path. A later generic “yes” does not approve a suspended deletion. Explicit
`resume_pending(ctx, id)` goes through a fresh presentation before confirmation.

The closure callback may run without a current user input. Use the report's
`pending_id` to identify the intention; do not infer a new user message from
`ctx.input`.

## Ordinary functions and read-only views

| Function | Purpose |
| --- | --- |
| `close_pending(ctx, id)` / `close_pending(ctx, id, opts)` | Request closure of one intention now. |
| `close_pending_after(ctx, id, delay_ms)` / `close_pending_after(ctx, id, delay_ms, opts)` | Schedule closure with an absolute durable deadline and the current pending revision. |
| `cancel_pending_close(ctx, id)` / `cancel_pending_close(ctx, id, opts)` | Cancel that intention's scheduled closure. Its GAM consent deadline is unchanged. |
| `get_pending(ctx, id)` | Read a pending intention by id, including one that is not in the foreground; returns `nil` when absent. |

Options include `reason`, `policy_ref`, `if_revision` and `on_result`.
`reason` is an atom or string; `policy_ref` is an optional nonempty host policy
reference. `if_revision` is a positive integer that limits the command to that
presentation revision. Scheduling uses the current revision when omitted.
The delay is a nonnegative integer number of milliseconds, not `:infinity`.
The default reason is `:idle_timeout` for scheduling and `:policy` for direct
closure or schedule cancellation.

Scheduling also accepts `timer: :runtime` (the default) or
`timer: :application`. Both record the logical schedule and absolute deadline;
the latter lets application OTP code own the wakeup. A timer-driven
`close_pending` can supply `if_schedule: schedule.command_id` as well as
`if_revision` to identify the exact schedule it is fulfilling.

For example, the application can inspect a stored id before cancelling its
scheduled closure:

```elixir
case get_pending(ctx, pending_id) do
  nil ->
    no_response(ctx)

  pending ->
    cancel_pending_close(ctx, pending.id,
      if_revision: pending.revision,
      reason: :conversation_continues
    )
end
```

These helpers append commands and return a context. They do not synchronously
close or mutate the read-only pending view inside the callback. Do not edit
`ctx.pending` or `ctx.pending_by_id` to implement a transition.

## Native OTP timers and private process state

The Server remains an OTP owner. Application code can use `Process.send_after/3`
and `handle_info/2` directly. Store timer references and generation tokens in
`Context.private`, using `put_private/2`, `put_private/3`, `get_private/2`,
`get_private/3` and `delete_private/2`. This map is process-local: it is neither
checkpointed nor sent to cognitive services. Keep portable application data in
`assigns`.

For application-owned timers, replace the topic-change branch above with:

```elixir
ctx
|> close_pending_after(pending.id, 60_000,
  timer: :application,
  reason: :topic_changed
)
|> route_current_input(suspend: pending.id)
```

The runtime still records scheduling before suspension and routing. Arm the
native timer only after the applied scheduling callback. Place these specific
callback clauses before the generic `handle_result/3` fallback in the Server:

```elixir
@impl true
def handle_result(
      :pending_lifecycle,
      {:pending_lifecycle, %{kind: :schedule_close, status: :applied, pending_id: id}},
      ctx
    ) do
  case get_pending(ctx, id) do
    %{close_schedule: %{timer_owner: :application} = schedule} ->
      ctx |> arm_local_close(id, schedule) |> no_response()

    _absent_or_runtime_timer ->
      no_response(ctx)
  end
end

def handle_result(
      :pending_lifecycle,
      {:pending_lifecycle, %{kind: :cancel_close, status: :applied, pending_id: id}},
      ctx
    ) do
  ctx |> cancel_local_timer(id) |> no_response()
end

defp arm_local_close(ctx, id, schedule) do
  ctx = cancel_local_timer(ctx, id)
  token = make_ref()
  delay = max(0, schedule.deadline - System.system_time(:millisecond))

  timer_ref = Process.send_after(
    self(),
    {:close_idle_intention, id, schedule.revision, schedule.command_id, token},
    delay
  )

  put_private(ctx, {:idle_close, id}, %{timer_ref: timer_ref, token: token})
end

defp cancel_local_timer(ctx, pending_id) do
  case get_private(ctx, {:idle_close, pending_id}) do
    %{timer_ref: timer_ref} -> Process.cancel_timer(timer_ref)
    nil -> :ok
  end

  delete_private(ctx, {:idle_close, pending_id})
end

@impl true
def handle_info({:close_idle_intention, id, revision, schedule_id, token}, ctx) do
  case get_private(ctx, {:idle_close, id}) do
    %{token: ^token} ->
      ctx =
        ctx
        |> delete_private({:idle_close, id})
        |> close_pending(id,
          if_revision: revision,
          if_schedule: schedule_id,
          reason: :idle_timeout
        )

      {:noreply, ctx}

    _cancelled_or_replaced ->
      {:noreply, ctx}
  end
end

def handle_info(message, ctx), do: super(message, ctx)
```

The token rejects an old message even if `Process.cancel_timer/1` lost a race
with delivery. The revision and schedule guards prevent an old timer from
closing a newer presentation or a replacement schedule. To cancel, return
`cancel_pending_close(ctx, id)`; cancel the native reference only after its
applied callback, as above. The native timer is transport for an already recorded
logical deadline, so scheduling, cancellation and closure all retain the GAM
lifecycle trail.

The native reference disappears when the process stops. The logical schedule
does not. An application that owns wakeups can rearm them from the restored
pending view in `init/2`, using the existing deadline:

```elixir
@impl true
def init(_arg, ctx) do
  ctx =
    Enum.reduce(ctx.pending_by_id, ctx, fn
      {id, %{close_schedule: %{timer_owner: :application} = schedule}}, acc ->
        arm_local_close(acc, id, schedule)

      _other, acc ->
        acc
    end)

  {:ok, ctx}
end
```

This does not schedule another sixty seconds or create another schedule event.
The runtime-owned mode rearms its own timers. Pick one wakeup owner per schedule;
do not additionally arm an application timer for `timer: :runtime`.

## What GAM records

The runtime uses distinct immutable event ids for three phases:

| Phase | Recorded fact |
| --- | --- |
| `:requested` | The host instructed the Server to schedule, cancel, close, suspend or resume an intention. |
| `:applied` | The local transition and its report outbox have already been durably acquired. |
| `:ignored` | The instruction did not change the intention, for example because its revision or schedule was stale. |

The event carries the pending id and revision, command id, reason, optional
policy/deadline, original interaction references and available Candidate/show
references. A timer includes the schedule identity that caused it. Evidence
binds the exact event id and `ExGAM.Canonical.Value.digest!(event)` to the
authenticated Scope/principal. The bridge's receipt identifies the event digest
and the real `evidence_refs`; an ordinary user Evidence or an unverified map is
insufficient.

The runtime acquires and records `:requested` before applying the transition.
It then acquires the resulting state together with the report outbox, and
records `:applied` or `:ignored`. The stable phase id and digest support recovery
without inventing another observation or reapplying a different instruction.
Missing configuration, a missing checkpoint or failure to obtain a valid ingress
receipt yields a typed error before the requested transition can proceed. If
recording the final report fails after acquisition, the report remains in the
durable outbox for reconciliation; the acquired transition is not rolled back.

Results use the normal Server callback:

```elixir
handle_result(tag, {:pending_lifecycle, report}, ctx)
handle_result(tag, {:error, {:pending_lifecycle, reason}}, ctx)
```

The default tag is `:pending_lifecycle`; `on_result` overrides it for an explicit
command. A report contains `status: :applied | :ignored`, `kind`, `pending_id`,
`revision` and `outcome_reason`. Handle the eventual scheduled closure with the
default lifecycle callback as in the example. A request is not a successful
transition merely because its helper returned a context.

An applied scheduling report also exposes `deadline` and `schedule_id` (the
schedule's `command_id`); the pending view holds the same values in
`close_schedule`, including its `timer_owner`.

## Deadlines, recovery and governed obligations

The durable schedule stores an absolute deadline, pending revision and schedule
identity. Restart preserves the deadline instead of starting another sixty
seconds. Cancellation, replacement and a fresh presentation invalidate obsolete
timer generations. Stale timer messages cannot close the new intention.
A fresh presentation replaces the previous closure schedule only after its
successful result has been acquired. A failed resume or explanation preserves
the original schedule and deadline, including across restart.

Recovery distinguishes continuations that were durably acquired but have not
started from governed commands that may already have started. The former follow
the normal deadline checks before execution; the latter are reconciled against
the GAM journal. A local actor-wait resume remains local. Replaying a lifecycle
completion cannot launch another worker for a command already active in that
Server, and receipts from an earlier phase cannot complete a later phase.

The application closure deadline is separate from the GAM consent TTL. Cancelling
the former does not extend consent validity. Resuming or explaining a consent
still follows the presentation contract; no timer can approve it.
Even with an application-owned wakeup, a confirmation or resume after the
logical closure deadline cannot revive that intention: the runtime first
follows the audited closure path.

An intention in `:resolving` or `:uncertain`, or one with an outstanding governed
obligation, is retained. Closure reports `:ignored` with
`:governed_operation_pending` rather than discarding the original continuation.
Other topic changes and application messages can continue while that governed
operation is being reconciled.
If the wakeup was already recorded while the intention was busy, it is not
repeated in a timer loop. When a resume or explanation then returns a definite
error and the intention becomes available again, the Server follows the
recorded, elapsed schedule with an audited closure. This also applies when the
original wakeup belonged to the application. An effect whose result remains
uncertain continues to preserve the governed obligation.
The automatic closure survives an earlier ignored lifecycle report or a
quarantined application callback. Ordinary commands that depended on that
callback remain aborted; this exception belongs to the runtime's timer work.

Suspension removes foreground ownership. Closure removes the pending intention
from the Server's live view while preserving recorded history and any governed
obligations. Neither transition means `UserReject`, cancellation of an Act or
disposal of a Duty. Those are separate facts and require the corresponding host
and kernel mechanisms. The kernel's admission, authority and world-observation
rules remain unchanged.
