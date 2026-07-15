# Public API

- `Spectre.ask/3` sends a low-level turn to an agent module or session and returns a `%Spectre.Result{}`.
- `Spectre.turn/3` sends a high-level turn and returns a `%Spectre.Turn{}` with a lifecycle decision.
- `Spectre.resolve_policy/4` persists a trusted host accept/reject decision without synthetic user text.
- `Spectre.execute/3` executes one unprotected `:pending` or policy-approved action effect.
- `Spectre.after_action/5` runs configured lifecycle hooks for completed action effects.
- `Spectre.cancel/2` cancels the active policy/effect boundary.
- `Spectre.summon/1` starts one session directly.
- `Spectre.summon/3` starts one session under `Spectre.Supervisor`.
- `Spectre.dismiss/2` stops a supervised session.
- `Spectre.state/1` reads session state.
- `Spectre.reset/2` replaces session state.

`ask/3` is the raw runtime boundary. It returns visible text, effects,
awaitables, state, route, and audit events.

```elixir
{:ok, result} = Spectre.ask(MyApp.Agent, "create a project")

[%Spectre.Effect{kind: :action, status: :waiting_policy}] = result.effects
[%Spectre.Awaitable{kind: :policy, status: :open}] = result.awaitables
```

After the user accepts the policy, the turn returns the same effect in
`:approved` state. Execution remains explicit:

```elixir
{:ok, approved} = Spectre.ask(MyApp.Agent, "yes", state: result.state)
[%Spectre.Effect{status: :approved}] = approved.effects

{:ok, completed} =
  Spectre.execute(approved.state, %{agent: MyApp.Agent})
```

When the host already has durable proof that the policy is satisfied, resolve
the declared policy label directly. Spectre persists this transition before
returning; it does not route a fake `"yes"` message or append chat history:

```elixir
{:ok, approved} =
  Spectre.resolve_policy(
    MyApp.Agent,
    awaiting_result,
    {:accept, :terms_accepted},
    conversation_id: conversation.id,
    assigns: %{user: user}
  )
```

For an existing `%Spectre.Turn{}`, the same transition is available through
`Spectre.Turn.resolve_policy/3`. Live sessions also update their in-memory
state.

`Spectre.Result.lifecycle/1`, `pending_effect/1`,
`open_awaitable/1`, `latest_completion/1`, and `action_outcome/1`
provide a normalized host view. `Spectre.Effect.outcome/1` flattens completed,
failed, and cancelled effects so applications do not need their own lifecycle
pattern matcher.

`turn/3` wraps `ask/3` and reduces the result into what the host should do next:

```elixir
{:ok, turn} = Spectre.turn(MyApp.Agent, "create a project")

case turn.decision do
  {:awaiting, awaitable, result} -> present_policy(awaitable, result)
  {:needs, effect, result} -> run_effect(effect, result)
  {:completed, completion, result} -> deliver_completion(completion, result)
  {:reply, result} -> deliver(result.reply_text)
  {:no_response, result} -> :ok
end
```
