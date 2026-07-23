defmodule SpectreStateStoreSessionResumeTest.Store do
  @moduledoc false
  @behaviour Spectre.State.Store

  alias Spectre.State
  alias Spectre.State.Codec

  @impl Spectre.State.Store
  def load(_input, _agent, opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    store = Keyword.fetch!(opts, :store)
    persisted = Elixir.Agent.get(store, &Map.get(&1, conversation_id))

    send(
      Keyword.fetch!(opts, :test_pid),
      {:state_store_loaded, conversation_id, persisted}
    )

    case persisted do
      nil -> {:ok, %State{conversation_id: conversation_id}}
      payload -> {:ok, payload}
    end
  end

  @impl Spectre.State.Store
  def compare_and_swap(%State{} = state, expected, input, _agent, opts) do
    store = Keyword.fetch!(opts, :store)
    conversation_id = state.conversation_id || Keyword.fetch!(opts, :conversation_id)

    with {:ok, payload} <- Codec.encode(state) do
      result =
        Elixir.Agent.get_and_update(
          store,
          &persist(&1, conversation_id, expected, payload)
        )

      if match?({:ok, _payload}, result) do
        send(
          Keyword.fetch!(opts, :test_pid),
          {:state_store_saved, conversation_id, expected, state.revision, input.text}
        )
      end

      result
    end
  end

  defp persist(persisted, conversation_id, expected, payload) do
    actual_revision =
      persisted
      |> Map.get(conversation_id)
      |> persisted_revision()

    if actual_revision == expected do
      {{:ok, payload}, Map.put(persisted, conversation_id, payload)}
    else
      {{:error, {:stale_state, actual_revision}}, persisted}
    end
  end

  defp persisted_revision(nil), do: 0

  defp persisted_revision(payload) do
    {:ok, state} = Codec.decode(payload)
    state.revision
  end
end

defmodule SpectreStateStoreSessionResumeTest.Renderer do
  @moduledoc false

  def render(_prompt, input, _context), do: "reply:#{input.text}"
end

defmodule SpectreStateStoreSessionResumeTest.Agent do
  @moduledoc false

  use Spectre.Agent

  state(SpectreStateStoreSessionResumeTest.Store)
  router(via: [:regex], classification_log?: false)

  flow :conversation do
    on :MESSAGE, regex: ~r/\S/u do
      reply(:message, renderer: {SpectreStateStoreSessionResumeTest.Renderer, :render})
    end
  end
end

defmodule SpectreStateStoreSessionResumeTest do
  use ExUnit.Case, async: false

  alias Spectre.State.Codec

  test "the state store adapter restores a session and continues from its persisted revision" do
    conversation_id = "resume-#{System.unique_integer([:positive])}"
    store = start_supervised!({Elixir.Agent, fn -> %{} end})
    first_child_id = {:state_store_session, conversation_id, :first}

    first_session =
      start_supervised!(
        {Spectre.Session,
         agent: SpectreStateStoreSessionResumeTest.Agent,
         id: first_child_id,
         conversation_id: conversation_id,
         idle: false,
         opts: [store: store, test_pid: self()]}
      )

    assert_receive {:state_store_loaded, ^conversation_id, nil}

    assert {:ok, first} = Spectre.ask(first_session, "first")
    assert first.state.revision == 1
    assert Enum.map(first.state.data.chat_history, & &1.user) == ["first"]
    assert_receive {:state_store_saved, ^conversation_id, 0, 1, "first"}

    first_payload = Elixir.Agent.get(store, &Map.fetch!(&1, conversation_id))
    assert {:ok, persisted_first_state} = Codec.decode(first_payload)
    assert persisted_first_state == first.state

    assert :ok = stop_supervised(first_child_id)

    restarted_session =
      start_supervised!(
        {Spectre.Session,
         agent: SpectreStateStoreSessionResumeTest.Agent,
         id: {:state_store_session, conversation_id, :restarted},
         conversation_id: conversation_id,
         idle: false,
         opts: [store: store, test_pid: self()]}
      )

    assert_receive {:state_store_loaded, ^conversation_id, ^first_payload}
    assert Spectre.state(restarted_session) == first.state

    assert {:ok, second} = Spectre.ask(restarted_session, "second")
    assert second.state.revision == 2
    assert second.state.conversation_id == conversation_id
    assert Enum.map(second.state.data.chat_history, & &1.user) == ["first", "second"]

    assert Enum.map(second.state.data.chat_history, & &1.assistant) == [
             "reply:first",
             "reply:second"
           ]

    assert_receive {:state_store_saved, ^conversation_id, 1, 2, "second"}

    second_payload = Elixir.Agent.get(store, &Map.fetch!(&1, conversation_id))
    assert {:ok, persisted_second_state} = Codec.decode(second_payload)
    assert persisted_second_state == second.state
  end
end
