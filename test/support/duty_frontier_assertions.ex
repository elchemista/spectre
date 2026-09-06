defmodule Spectre.Test.DutyFrontierAssertions do
  @moduledoc false
  import ExUnit.Assertions

  alias Spectre.Duty.{Derive, Frontier}
  alias Spectre.Erasure.Analysis.{Closure, Execution, Facts}
  alias Spectre.Erasure.Index
  alias Spectre.GovernedAct.{AuthorityIndex, Fold}
  alias Spectre.Kernel.Authority
  alias Spectre.Kernel.Authority.Facts, as: AuthorityFacts

  def assert_prefixes(snapshot, constitution) do
    snapshot.entries
    |> Enum.chunk_by(& &1.batch_id)
    |> Enum.reduce(Fold.new(snapshot.domain_ref, constitution), fn batch, state ->
      assert {:ok, state} = Fold.append_batch(state, batch)
      assert_erasure_index(state)
      assert AuthorityIndex.complete?(state.read_index.authority, state)

      assert AuthorityFacts.current(state) === AuthorityFacts.from_state(state),
             "incremental authority differs at revision #{state.revision}"

      assert_dispatch_facts(state)

      times = [state.recorded_at | deadlines(state)]
      times = times |> Enum.uniq() |> Enum.filter(&(&1 >= state.recorded_at))

      for time <- times do
        assert Frontier.missing(state, time) === Derive.missing_openings(state, time),
               "frontier differs at revision #{state.revision}, trusted time #{time}"

        assert_targeted_causes(state, time)
      end

      assert :ok = Fold.validate_complete(state)
      state
    end)
  end

  defp assert_erasure_index(state) do
    index = state.read_index.erasure
    facts = Facts.from_state(state)
    assert Index.complete?(index, state)

    assert index.unavailable === Closure.unavailable_evidence_refs(facts),
           "incremental erasure differs at revision #{state.revision}"

    for {target, status} <- index.states do
      assert status === Execution.state(facts, target),
             "erasure execution differs for #{target} at revision #{state.revision}"
    end
  end

  defp assert_dispatch_facts(state) do
    exhaustive = AuthorityFacts.from_state(state)

    for {_ref, act} <- state.acts do
      mandate = Map.fetch!(state.mandates, act.mandate_ref)
      selected = AuthorityFacts.for_act(state, act)

      assert Authority.dispatchable?(act, mandate, selected, state.recorded_at) ===
               Authority.dispatchable?(act, mandate, exhaustive, state.recorded_at),
             "targeted dispatch differs for #{act.ref} at revision #{state.revision}"
    end
  end

  defp assert_targeted_causes(state, time) do
    for constitution <- [state.constitution, %{}],
        cause <- Derive.required_duties(state, constitution, time) do
      assert Derive.required_cause(state, constitution, cause.cause_key, time) === cause,
             "targeted cause differs at revision #{state.revision}: #{inspect(cause.cause_key)}"
    end
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
