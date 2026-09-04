defmodule Spectre.Domain.Reconciliation do
  @moduledoc """
  Pure scheduling policy for reconciliation of durable Domain facts.

  `Spectre.Attempt.Reconciler` determines which repairs are required. This
  module answers only when the sequencer must ask it again: immediately when a
  required Duty is missing, or at the nearest dispatch, observation or Scope
  promise deadline. It owns no timer and performs no ledger write.
  """

  alias Spectre.Attempt.Reconciler
  alias Spectre.Domain.Projection
  alias Spectre.GovernedAct.{DispatchState, State}
  alias Spectre.Scope.Opening

  @doc "Returns the next trusted timestamp requiring reconciliation, or `nil`."
  @spec next_deadline(Projection.t(), non_neg_integer()) :: non_neg_integer() | nil
  def next_deadline(%State{} = projection, now) when is_integer(now) and now >= 0 do
    case Reconciler.missing_openings(projection, now) do
      [] -> deadlines(projection, now) |> Enum.min(fn -> nil end)
      [_cause | _rest] -> now
    end
  end

  defp deadlines(projection, now) do
    dispatch_deadlines(projection, now) ++
      attempt_deadlines(projection, now) ++ scope_deadlines(projection, now)
  end

  defp dispatch_deadlines(projection, now) do
    Enum.flat_map(DispatchState.pending_refs(projection), fn act_ref ->
      with {:ok, act} <- Map.fetch(projection.acts, act_ref),
           {:ok, mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
           true <- act.mandate_revision == mandate.revision,
           false <- DispatchState.attempted?(projection, act.ref) do
        [max(mandate.expires_at, now)]
      else
        _invalid -> [now]
      end
    end)
  end

  defp attempt_deadlines(projection, now) do
    attempts_with_outcome =
      MapSet.new(projection.outcomes, fn {_ref, outcome} -> outcome.attempt_ref end)

    projection.attempts
    |> Map.values()
    |> Enum.reject(&MapSet.member?(attempts_with_outcome, &1.ref))
    |> Enum.flat_map(fn attempt ->
      case Map.fetch(projection.acts, attempt.act_ref) do
        {:ok, act} ->
          deadline = attempt.started_at + act.observation_window_ms
          if deadline > now, do: [deadline], else: []

        :error ->
          []
      end
    end)
  end

  defp scope_deadlines(projection, now) do
    projection.scopes
    |> Map.values()
    |> Enum.flat_map(fn
      %Opening{kind: kind, due_at: due_at} when kind in [:work, :vigil] and due_at > now ->
        [due_at]

      _other ->
        []
    end)
  end
end
