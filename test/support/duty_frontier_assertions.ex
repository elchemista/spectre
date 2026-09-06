defmodule Spectre.Test.DutyFrontierAssertions do
  @moduledoc false
  import ExUnit.Assertions

  alias Spectre.Duty.{Derive, Frontier}
  alias Spectre.GovernedAct.Fold

  def assert_prefixes(snapshot, constitution) do
    snapshot.entries
    |> Enum.chunk_by(& &1.batch_id)
    |> Enum.reduce(Fold.new(snapshot.domain_ref, constitution), fn batch, state ->
      assert {:ok, state} = Fold.append_batch(state, batch)
      times = [state.recorded_at | deadlines(state)]
      times = times |> Enum.uniq() |> Enum.filter(&(&1 >= state.recorded_at))

      for time <- times do
        assert Frontier.missing(state, time) === Derive.missing_openings(state, time),
               "frontier differs at revision #{state.revision}, trusted time #{time}"
      end

      assert :ok = Fold.validate_complete(state)
      state
    end)
  end

  defp deadlines(state) do
    attempts =
      Enum.map(state.attempts, fn {_ref, attempt} ->
        attempt.started_at + Map.fetch!(state.acts, attempt.act_ref).observation_window_ms
      end)

    scopes = for {_ref, %{due_at: due}} <- state.catalog.scopes, is_integer(due), do: due
    Enum.flat_map(attempts ++ scopes, &[&1 - 1, &1, &1 + 1])
  end
end
