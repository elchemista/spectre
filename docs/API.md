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
- `Spectre.Router.evaluate/3` runs input normalization and routing without
  loading state/memory adapters or executing a selected handler.
- `Spectre.Eval.run/3` evaluates an agent against JSONL or in-memory routing
  expectations and returns a `%Spectre.Eval.Report{}`.

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

## Journal Contracts

`Spectre.Journal.Store` is the append-only adapter behaviour for structured
decision records. `Spectre.Journal.Record` is the versioned value passed to the
store. Journaling is configured through `Spectre.Agent.journal/2`, application
configuration, or the per-call `:journal` option; it is disabled by default.

The current implementation emits `:arbitration` records from completed router
contexts. Records use stable IDs derived from `turn_id`, phase, sequence, and
agent, and omit conversation content unless `include_input: true` is explicit.
See [Journal](JOURNAL.md) for configuration and delivery semantics.

## Routing Evaluation Contracts

`Spectre.Router.Receipt` is the privacy-safe result of one route-only
evaluation. It records outcome, label, strategy, sanitized attempts and
candidates, total duration, per-provider normalized outcomes/durations, and
whether an LLM adapter worker was actually invoked. It does not contain input
text, prompts, model output, matches, raw provider errors, or handlers.

`Spectre.Eval.Case` describes expected route/outcome and whether an LLM call is
forbidden, allowed, or required. `Spectre.Eval.Result` contains structured
violations for one case. `Spectre.Eval.Report` aggregates accuracy, provider
usage, LLM violations, duration percentiles, confusion data, and tag results.

See [Routing Evaluation](EVALUATION.md) for the JSONL schema and
`mix spectre.eval` CI workflow.

## Provider Contracts

`Spectre.Provider.Call.run/3` is the shared isolation and timeout boundary used
by routing-critical adapters. `Spectre.Provider.Failure` represents sanitized
timeouts, exceptions, exits, throws, crashes, malformed replies, and invalid
deadline configuration. Adapter-declared `{:error, reason}` replies remain
unchanged.

See [Provider Resilience](PROVIDERS.md) for timeout precedence, defaults,
cancellation semantics, and the boundary between core behavior and
provider-specific retries.
