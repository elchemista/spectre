defmodule Spectre.Attempt.Runner.Recovery do
  @moduledoc """
  Reconstructs a completed or still-dispatchable Runner result from governed state.

  This reader performs no I/O and never retries an executor. It is used after
  an uncertain process boundary to distinguish a durable Attempt or cancelled
  dispatch from work which is still safe to start.
  """

  alias Spectre.{Act, Attempt, Decision}
  alias Spectre.Attempt.Binding
  alias Spectre.Attempt.Runner.Result
  alias Spectre.GovernedAct.{DispatchState, State}

  @type result :: {:ok, Result.t()} | :dispatch_ready | {:error, term()}

  @doc false
  @spec from_projection(State.t(), Decision.t(), Act.t()) :: result()
  def from_projection(%State{} = projection, %Decision{} = decision, %Act{} = expected_act) do
    with {:ok, act} <- Map.fetch(projection.acts, expected_act.ref),
         true <- act == expected_act do
      case DispatchState.attempt_ref(projection, act.ref) do
        attempt_ref when is_binary(attempt_ref) ->
          recover_attempt(projection, decision, act, attempt_ref)

        nil ->
          recover_dispatch(projection, decision, act)
      end
    else
      :error -> {:error, {:admitted_act_not_found, expected_act.ref}}
      false -> {:error, {:admitted_act_changed, expected_act.ref}}
    end
  end

  defp recover_attempt(projection, decision, act, attempt_ref) do
    with {:ok, %Attempt{} = attempt} <- Map.fetch(projection.attempts, attempt_ref),
         nil <- Binding.mismatch(attempt, act) do
      result(
        decision,
        act,
        attempt,
        recovered_evidence(projection, act, attempt),
        recovered_outcome(projection, act, attempt)
      )
    else
      :error -> {:error, {:attempt_not_found, attempt_ref}}
      {_field, _expected, _actual} -> {:error, :recorded_attempt_binding_mismatch}
      {:ok, _invalid} -> {:error, {:invalid_recorded_attempt, attempt_ref}}
    end
  end

  defp recover_dispatch(projection, decision, act) do
    cond do
      DispatchState.cancelled?(projection, act.ref) and
          not DispatchState.pending?(projection, act.ref) ->
        result(decision, act, nil, [], nil)

      DispatchState.pending?(projection, act.ref) ->
        :dispatch_ready

      true ->
        {:error, {:invalid_dispatch_state, act.ref}}
    end
  end

  defp recovered_evidence(projection, act, attempt) do
    expected_bindings = Binding.evidence_bindings(act, attempt)

    projection.evidence
    |> Map.values()
    |> Enum.filter(&(&1.bindings == expected_bindings))
    |> Enum.sort_by(&event_order(projection, &1.ref))
  end

  defp recovered_outcome(projection, act, attempt) do
    projection.outcomes
    |> Map.values()
    |> Enum.filter(&(&1.act_ref == act.ref and &1.attempt_ref == attempt.ref))
    |> Enum.max_by(&event_order(projection, &1.ref), fn -> nil end)
  end

  defp event_order(projection, ref) do
    revision =
      case Map.get(projection.event_metadata, ref) do
        %{revision: revision} -> revision
        nil -> 0
      end

    {revision, ref}
  end

  defp result(decision, act, attempt, evidence, outcome),
    do: Result.ok(decision, act, attempt, evidence, outcome)
end
