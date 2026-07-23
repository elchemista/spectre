defmodule SpectreJournalOrderingTest.Store do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(record, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:journal_append_started, record.turn_id, self()})

    if record.turn_id == Keyword.get(opts, :blocked_turn) do
      receive do
        :release_journal_append -> :ok
      end
    end

    opts
    |> Keyword.fetch!(:store)
    |> Elixir.Agent.update(&(&1 ++ [record]))

    send(test_pid, {:journal_stored, record.turn_id})
    :ok
  end
end

defmodule SpectreJournalOrderingTest.Renderer do
  @moduledoc false

  def render(_prompt, input, _context), do: "ack:#{input.text}"
end

defmodule SpectreJournalOrderingTest.Agent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], classification_log?: false)

  flow :conversation do
    on :MESSAGE, regex: ~r/\S/u do
      reply(:message, renderer: {SpectreJournalOrderingTest.Renderer, :render})
    end
  end
end

defmodule SpectreJournalOrderingTest do
  use ExUnit.Case, async: false

  alias Spectre.Journal.Record

  test "the asynchronous journal stores turns in submission order" do
    store = start_supervised!({Elixir.Agent, fn -> [] end})

    journal =
      {SpectreJournalOrderingTest.Store,
       [
         events: [:routing],
         mode: :async,
         journal_timeout: 2_000,
         store_opts: [
           store: store,
           test_pid: self(),
           blocked_turn: "turn-1"
         ]
       ]}

    assert {:ok, _turn} = run_turn("first", "turn-1", journal)
    assert_receive {:journal_append_started, "turn-1", first_append}, 1_000

    assert {:ok, _turn} = run_turn("second", "turn-2", journal)
    assert {:ok, _turn} = run_turn("third", "turn-3", journal)

    refute_receive {:journal_append_started, "turn-2", _worker}, 25
    refute_receive {:journal_append_started, "turn-3", _worker}, 0

    send(first_append, :release_journal_append)

    assert receive_stored_turn_ids(3) == ["turn-1", "turn-2", "turn-3"]

    records = Elixir.Agent.get(store, & &1)

    assert Enum.all?(records, &match?(%Record{}, &1))
    assert Enum.map(records, & &1.turn_id) == ["turn-1", "turn-2", "turn-3"]
    assert Enum.map(records, & &1.sequence) == [1, 1, 1]
    assert Enum.map(records, & &1.phase) == [:arbitration, :arbitration, :arbitration]
  end

  defp run_turn(text, turn_id, journal) do
    Spectre.turn(SpectreJournalOrderingTest.Agent, text,
      conversation_id: "ordered-conversation",
      turn_id: turn_id,
      journal: journal
    )
  end

  defp receive_stored_turn_ids(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:journal_stored, turn_id} -> turn_id
      after
        2_000 -> flunk("timed out waiting for a journal record")
      end
    end)
  end
end
