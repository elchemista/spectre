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
