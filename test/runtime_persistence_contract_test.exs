defmodule SpectreRuntimePersistenceContractTest.Handler do
  @moduledoc false
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply

  @impl Spectre.Turn.Handler
  def handle_turn(request, _opts) do
    {:reply, Reply.new("handled:#{request.input.text}", metadata: %{handler: true})}
  end
end

defmodule SpectreRuntimePersistenceContractTest.Load2Store do
  @moduledoc false

  def load(input, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:load2, input.text})
    Keyword.fetch!(opts, :load_reply)
  end
end

defmodule SpectreRuntimePersistenceContractTest.Persist5Store do
  @moduledoc false

  alias Spectre.State
  alias Spectre.State.Codec

  def persist(%State{} = state, expected, input, agent, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:persist5, expected, state.revision, input.text, agent}
    )

    opts
    |> Keyword.get(:persist_reply, :ok)
    |> persist_reply(state)
  end

  defp persist_reply(:ok, _state), do: :ok
  defp persist_reply(:state, state), do: {:ok, state}
  defp persist_reply(:map, state), do: Codec.encode(state)
  defp persist_reply(:binary, state), do: Codec.encode_json(state)
  defp persist_reply(:wrong_revision, state), do: {:ok, %{state | revision: state.revision + 1}}
  defp persist_reply(:invalid_map, _state), do: {:ok, %{"state_version" => 999}}
  defp persist_reply(:stale, _state), do: {:error, :stale_state}
  defp persist_reply({:stale, actual}, _state), do: {:error, {:stale_state, actual}}
  defp persist_reply({:ambiguous, reason}, _state), do: {:error, {:ambiguous, reason}}

  defp persist_reply({:persistence_ambiguous, reason}, _state),
    do: {:error, {:persistence_ambiguous, reason}}

  defp persist_reply({:error, reason}, _state), do: {:error, reason}
  defp persist_reply(:invalid, _state), do: :invalid_persist_reply
end

defmodule SpectreRuntimePersistenceContractTest.Legacy4Store do
  @moduledoc false

  def persist(state, input, agent, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:persist4, state.revision, input.text, agent}
    )

    :ok
  end
end

defmodule SpectreRuntimePersistenceContractTest.Legacy2Store do
  @moduledoc false

  def persist(state, input) do
    test_pid = input.meta.test_pid
    send(test_pid, {:persist2, state.revision, input.text})
    :ok
  end
end

defmodule SpectreRuntimePersistenceContractTest.NoCallbackStore do
  @moduledoc false
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRemember4 do
  @moduledoc false

  def remember(input, result, agent, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:memory_callback, :remember, 4, input.text, result.state.revision, agent}
    )

    Keyword.get(opts, :memory_reply, {:ok, :stored})
  end
end

defmodule SpectreRuntimePersistenceContractTest.MemoryPersist4 do
  @moduledoc false

  def persist(input, result, agent, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:memory_callback, :persist, 4, input.text, result.state.revision, agent}
    )

    Keyword.get(opts, :memory_reply, :ok)
  end
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRemember2 do
  @moduledoc false

  def remember(payload, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:memory_callback, :remember, 2, payload.input.text, payload.state.revision, opts[:agent]}
    )

    Keyword.get(opts, :memory_reply, :ok)
  end
end

defmodule SpectreRuntimePersistenceContractTest.MemoryPersist2 do
  @moduledoc false

  def persist(payload, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:memory_callback, :persist, 2, payload.input.text, payload.state.revision, opts[:agent]}
    )

    Keyword.get(opts, :memory_reply, :ok)
  end
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRecall do
  @moduledoc false

  def recall(text, opts) do
    send(opts[:input].meta.test_pid, {:memory_recall, text, opts[:state].revision})
    opts[:input].meta.memory_reply
  end
end

defmodule SpectreRuntimePersistenceContractTest.Actions do
  @moduledoc false

  def perform(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:performed, args, ctx.opts[:idempotency_key]})
    {:ok, args}
  end
end

defmodule SpectreRuntimePersistenceContractTest.BareAgent do
  @moduledoc false
  use Spectre.Agent
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.Load2Agent do
  @moduledoc false
  use Spectre.Agent
  state(SpectreRuntimePersistenceContractTest.Load2Store)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.Persist5Agent do
  @moduledoc false
  use Spectre.Agent
  state(SpectreRuntimePersistenceContractTest.Persist5Store)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.Legacy4Agent do
  @moduledoc false
  use Spectre.Agent
  state(SpectreRuntimePersistenceContractTest.Legacy4Store)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.Legacy2Agent do
  @moduledoc false
  use Spectre.Agent
  state(SpectreRuntimePersistenceContractTest.Legacy2Store)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.NoCallbackAgent do
  @moduledoc false
  use Spectre.Agent
  state(SpectreRuntimePersistenceContractTest.NoCallbackStore)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.NonModuleAdaptersAgent do
  @moduledoc false
  use Spectre.Agent
  state(123)
  memory(456)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRemember4Agent do
  @moduledoc false
  use Spectre.Agent
  memory(SpectreRuntimePersistenceContractTest.MemoryRemember4)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.MemoryPersist4Agent do
  @moduledoc false
  use Spectre.Agent
  memory(SpectreRuntimePersistenceContractTest.MemoryPersist4)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRemember2Agent do
  @moduledoc false
  use Spectre.Agent
  memory(SpectreRuntimePersistenceContractTest.MemoryRemember2)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.MemoryPersist2Agent do
  @moduledoc false
  use Spectre.Agent
  memory(SpectreRuntimePersistenceContractTest.MemoryPersist2)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.MemoryRecallAgent do
  @moduledoc false
  use Spectre.Agent
  memory(SpectreRuntimePersistenceContractTest.MemoryRecall)
  turn_handler(SpectreRuntimePersistenceContractTest.Handler)
end

defmodule SpectreRuntimePersistenceContractTest.ContinuationAgent do
  @moduledoc false
  use Spectre.Agent

  actions(SpectreRuntimePersistenceContractTest.Actions)

  policy :terms do
    accept(:accepted, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
  end
end

defmodule SpectreRuntimePersistenceContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Runtime
  alias Spectre.State
  alias Spectre.State.Codec

  test "state restoration accepts load/2 state, map, and JSON contracts and rejects malformed replies" do
    state = %State{revision: 4, data: %{restored: true}}
    {:ok, encoded} = Codec.encode(state)
    {:ok, json} = Codec.encode_json(state)

    for reply <- [state, {:ok, encoded}, json] do
      assert {:ok, restored} =
               Runtime.restore_state(
                 SpectreRuntimePersistenceContractTest.Load2Agent,
                 test_pid: self(),
                 load_reply: reply,
                 conversation_id: "restored-conversation"
               )

      assert restored.revision == 4
      assert restored.data.restored
      assert restored.conversation_id == "restored-conversation"
      assert_receive {:load2, ""}
    end

    assert {:error, {:invalid_persisted_state, _reason}} =
             Runtime.restore_state(
               SpectreRuntimePersistenceContractTest.Load2Agent,
               test_pid: self(),
               load_reply: %{"state_version" => 999}
             )

    assert_receive {:load2, ""}

    for {reply, shape} <- [
          {nil, nil},
          {:invalid, :atom},
          {[1, 2], :list},
          {{:bad, :tuple}, {:tuple, 2}},
          {fn -> :bad end, :other}
        ] do
      assert {:error, {:invalid_state_reply, ^shape}} =
               Runtime.restore_state(
                 SpectreRuntimePersistenceContractTest.Load2Agent,
                 test_pid: self(),
                 load_reply: reply
               )

      assert_receive {:load2, ""}
    end

    assert {:error, {:invalid_persisted_state, {:invalid_state_payload, {:struct, URI}}}} =
             Runtime.restore_state(
               SpectreRuntimePersistenceContractTest.Load2Agent,
               test_pid: self(),
               load_reply: %URI{}
             )

    assert_receive {:load2, ""}

    assert {:error, :load_failed} =
             Runtime.restore_state(
               SpectreRuntimePersistenceContractTest.Load2Agent,
               test_pid: self(),
               load_reply: {:error, :load_failed}
             )
  end

  test "explicit state and memory bypass adapters and enforce payload limits" do
    input = Input.new("injected")
    supplied = %State{revision: 7, conversation_id: "already-owned"}

    assert {:ok, ctx} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.Load2Agent,
               input,
               state: supplied,
               memory: %{facts: [:one]},
               conversation_id: "must-not-overwrite",
               test_pid: self()
             )

    assert ctx.state == supplied
    assert ctx.memory == %{facts: [:one]}
    refute_receive {:load2, _text}

    assert {:error, {:payload_too_large, :memory_recall, _bytes, 1}} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.BareAgent,
               input,
               state: %State{},
               memory: String.duplicate("x", 100),
               memory_max_bytes: 1
             )

    assert {:ok, default_ctx} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.BareAgent,
               input,
               conversation_id: "new-conversation"
             )

    assert default_ctx.state.conversation_id == "new-conversation"
    assert default_ctx.memory == nil
  end

  test "state persist/5 distinguishes committed, stale, ambiguous, and definite failures" do
    committed_modes = [
      {:ok, :cas},
      {:state, :cas},
      {:map, :cas},
      {:binary, :cas}
    ]

    for {persist_reply, expected_mode} <- committed_modes do
      assert {:ok, result} =
               Spectre.ask(
                 SpectreRuntimePersistenceContractTest.Persist5Agent,
                 "save",
                 state: %State{},
                 test_pid: self(),
                 persist_reply: persist_reply
               )

      assert result.state.revision == 1
      assert result.metadata.state_persistence.status == :committed
      assert result.metadata.state_persistence.mode == expected_mode

      assert_receive {:persist5, 0, 1, "save",
                      SpectreRuntimePersistenceContractTest.Persist5Agent}
    end

    for {persist_reply, expected} <- [
          {:stale, {:stale_state, 0}},
          {{:stale, 9}, {:stale_state, 0, 9}},
          {{:error, :disk_full}, :disk_full}
        ] do
      assert {:error, ^expected} =
               Spectre.ask(
                 SpectreRuntimePersistenceContractTest.Persist5Agent,
                 "save",
                 state: %State{},
                 test_pid: self(),
                 persist_reply: persist_reply
               )

      assert_receive {:persist5, 0, 1, "save",
                      SpectreRuntimePersistenceContractTest.Persist5Agent}
    end

    for {persist_reply, reason_match} <- [
          {{:ambiguous, :connection_lost}, :connection_lost},
          {{:persistence_ambiguous, :unknown_commit}, :unknown_commit},
          {:wrong_revision, {:invalid_persisted_revision, 1, 2}},
          {:invalid_map, {:invalid_persisted_state, :any}},
          {:invalid, {:invalid_persist_reply, :atom}}
        ] do
      assert {:error, {:persistence_ambiguous, reason, ambiguous}} =
               Spectre.ask(
                 SpectreRuntimePersistenceContractTest.Persist5Agent,
                 "save",
                 state: %State{},
                 test_pid: self(),
                 persist_reply: persist_reply
               )

      assert_reason(reason, reason_match)
      assert ambiguous.state.revision == 1
      assert ambiguous.metadata.state_persistence.status == :ambiguous
      assert ambiguous.metadata.state_persistence.mode == :ambiguous

      assert_receive {:persist5, 0, 1, "save",
                      SpectreRuntimePersistenceContractTest.Persist5Agent}
    end
  end

  test "legacy state adapters and absent adapters preserve their declared commit modes" do
    input = %{text: "legacy", meta: %{test_pid: self()}}

    assert {:ok, legacy4} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.Legacy4Agent,
               input,
               state: %State{},
               test_pid: self()
             )

    assert legacy4.metadata.state_persistence.mode == :legacy

    assert_receive {:persist4, 1, "legacy", SpectreRuntimePersistenceContractTest.Legacy4Agent}

    assert {:ok, legacy2} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.Legacy2Agent,
               input,
               state: %State{}
             )

    assert legacy2.metadata.state_persistence.mode == :legacy
    assert_receive {:persist2, 1, "legacy"}

    for agent <- [
          SpectreRuntimePersistenceContractTest.NoCallbackAgent,
          SpectreRuntimePersistenceContractTest.NonModuleAdaptersAgent
        ] do
      assert {:ok, in_memory} = Spectre.ask(agent, "memory only", state: %State{})
      assert in_memory.metadata.state_persistence.mode == :in_memory
      assert in_memory.state.revision == 1
    end
  end

  test "all supported memory persistence callbacks receive the committed turn" do
    agents = [
      {SpectreRuntimePersistenceContractTest.MemoryRemember4Agent, :remember, 4},
      {SpectreRuntimePersistenceContractTest.MemoryPersist4Agent, :persist, 4},
      {SpectreRuntimePersistenceContractTest.MemoryRemember2Agent, :remember, 2},
      {SpectreRuntimePersistenceContractTest.MemoryPersist2Agent, :persist, 2}
    ]

    for {agent, function, arity} <- agents do
      assert {:ok, result} =
               Spectre.ask(agent, "remember", state: %State{}, test_pid: self())

      assert result.state.revision == 1
      assert_receive {:memory_callback, ^function, ^arity, "remember", 1, ^agent}
    end

    assert {:ok, no_memory_callback} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.NonModuleAdaptersAgent,
               "ignored memory",
               state: %State{}
             )

    assert no_memory_callback.state.revision == 1
  end

  test "memory recall and persistence failures remain separate from committed state" do
    input = %{
      text: "recall",
      meta: %{test_pid: self(), memory_reply: {:ok, %{fact: 1}}}
    }

    assert {:ok, recalled} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.MemoryRecallAgent,
               Input.new(input),
               state: %State{}
             )

    assert recalled.memory == %{fact: 1}
    assert_receive {:memory_recall, "recall", 0}

    plain_input = put_in(input, [:meta, :memory_reply], %{plain: true})

    assert {:ok, plain} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.MemoryRecallAgent,
               Input.new(plain_input),
               state: %State{}
             )

    assert plain.memory == %{plain: true}

    failed_input = put_in(input, [:meta, :memory_reply], {:error, :memory_down})

    assert {:error, :memory_down} =
             Runtime.load_context(
               SpectreRuntimePersistenceContractTest.MemoryRecallAgent,
               Input.new(failed_input),
               state: %State{}
             )

    assert {:error, {:invalid_memory_persist_failure, :unknown_policy}} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.MemoryRemember4Agent,
               "persist",
               state: %State{},
               test_pid: self(),
               memory_reply: :invalid,
               memory_persist_failure: :unknown_policy
             )

    assert_receive {:memory_callback, :remember, 4, "persist", 1, _agent}

    assert {:error,
            {:memory_persist_failed, {:payload_too_large, :memory_persist, _, 1}, committed}} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.MemoryRemember4Agent,
               "persist",
               state: %State{},
               test_pid: self(),
               memory_persist_max_bytes: 1,
               memory_persist_failure: :error
             )

    assert committed.state.revision == 1
    refute_receive {:memory_callback, :remember, 4, "persist", _, _agent}
  end

  test "continuations normalize input, reject stale execution metadata, and replay terminals" do
    staged_effect =
      Effect.stage_action(
        %{name: :perform, args: %{source: :continuation}},
        SpectreRuntimePersistenceContractTest.ContinuationAgent,
        :agent
      )

    awaiting_state = State.put_pending_effect(%State{}, staged_effect, :terms)

    awaiting = %Result{
      input: nil,
      state: awaiting_state,
      effects: [State.pending_effect(awaiting_state)],
      metadata: %{}
    }

    assert {:ok, approved} =
             Runtime.resolve_policy(
               SpectreRuntimePersistenceContractTest.ContinuationAgent,
               awaiting,
               {:accept, :accepted}
             )

    assert State.pending_effect(approved.state).status == :approved
    assert approved.input.text == ""

    stale = %{
      approved
      | metadata:
          Map.put(approved.metadata, :state_persistence, %{
            status: :committed,
            revision: approved.state.revision - 1
          })
    }

    assert {:error, {:stale_execution_result, stale_revision, current_revision}} =
             Runtime.execute(
               SpectreRuntimePersistenceContractTest.ContinuationAgent,
               stale,
               input: "raw continuation",
               test_pid: self()
             )

    assert stale_revision == approved.state.revision - 1
    assert current_revision == approved.state.revision
    refute_receive {:performed, _args, _key}

    completed_effect = %{staged_effect | status: :completed, result: %{ok: true}}

    terminal = %Result{
      input: nil,
      state: %State{planned_effects: [completed_effect]},
      effects: [:malformed_effect, completed_effect],
      metadata: %{}
    }

    assert {:ok, ^terminal} =
             Runtime.execute(
               SpectreRuntimePersistenceContractTest.ContinuationAgent,
               terminal
             )

    assert {:ok, ^terminal} =
             Runtime.execute(
               SpectreRuntimePersistenceContractTest.ContinuationAgent,
               terminal,
               input: "raw continuation"
             )
  end

  test "invalid input pipeline and input limits fail before state or handlers run" do
    assert {:error, {:invalid_input_pipeline, :not_a_pipeline}} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.BareAgent,
               "hello",
               input_pipeline: :not_a_pipeline
             )

    assert {:error, {:payload_too_large, :input, 5, 4}} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.BareAgent,
               "hello",
               input_max_bytes: 4
             )

    assert {:error, {:payload_too_large, :input, 5, :invalid}} =
             Spectre.ask(
               SpectreRuntimePersistenceContractTest.BareAgent,
               "hello",
               input_max_bytes: :invalid
             )
  end

  defp assert_reason(actual, {:invalid_persisted_state, :any}) do
    assert match?({:invalid_persisted_state, _reason}, actual)
  end

  defp assert_reason(actual, expected), do: assert(actual == expected)
end
