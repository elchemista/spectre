# Memory

For a single long-lived session:

```elixir
children = [
  {Spectre.Session,
   agent: MyApp.SupportAgent,
   name: MyApp.SupportSession,
   shutdown: :timer.minutes(10)}
]
```

For many conversation-scoped sessions:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]

{:ok, pid} =
  Spectre.summon(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    conversation_id: conversation.id,
    idle: :timer.minutes(10)
  )
```

State adapter:

```elixir
defmodule MyApp.AgentStateStore do
  def load(_input, _agent, opts) do
    MyApp.Conversations.load_spectre_state(Keyword.fetch!(opts, :conversation_id))
  end

  def persist(state, _input, _agent, _opts) do
    MyApp.Conversations.save_spectre_state(state.conversation_id, state)
  end
end
```

Memory adapter:

```elixir
defmodule MyApp.AgentMemory do
  def recall(cue, opts) do
    SpectreMnemonic.recall(cue, scope: {:conversation, opts[:state].conversation_id})
  end

  def remember(turn, opts) do
    SpectreMnemonic.remember(turn,
      scope: {:conversation, opts[:state].conversation_id},
      persist?: true
    )
  end
end
```

Every successful turn records a compact chat entry in
`state.data[:chat_history]` before persistence. Use `history false` in the DSL
or pass `chat_history_limit: false` to disable it.

State is the authoritative machine record; recalled memory is a contextual
projection. Spectre therefore persists state first. If the memory adapter then
fails, the turn still returns the persisted state and adds a
`:memory_persist_failed` event plus a `:persistence_warnings` metadata entry.
This prevents a session from retaining an older in-memory state and replaying a
machine transition.

Hosts that require both writes to report success can opt into strict failure:

```elixir
Spectre.ask(MyApp.SupportAgent, input,
  memory_persist_failure: :error
)
```

Strict mode reports
`{:error, {:memory_persist_failed, reason, committed_result}}`. The state write
has already succeeded, and supervised sessions retain
`committed_result.state` before returning the error. Stateless hosts should do
the same. True cross-store atomicity still requires the host to place both
records in the same database transaction.
