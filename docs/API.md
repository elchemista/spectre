# Public API

- `Spectre.ask/3` sends a low-level turn to an agent module or session and returns a `%Spectre.Result{}`.
- `Spectre.turn/3` sends a high-level turn and returns a `%Spectre.Turn{}` with a lifecycle decision.
- `Spectre.execute/3` executes the single pending action effect in a state.
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
