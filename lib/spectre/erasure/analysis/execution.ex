defmodule Spectre.Erasure.Analysis.Execution do
  @moduledoc """
  Classifies the externally visible execution state of an erasure request.

  The ordering is conservative: a successful deletion dominates uncertainty,
  and uncertainty dominates evidence of no effect. This module never touches
  the payload store; it interprets only durable Attempts, Outcomes and dispatch
  cancellations from the pinned fact prefix.
  """

  alias Spectre.Erasure.Analysis.Facts

  @terminal_outcomes [:succeeded, :failed, :definitive_no_effect]

  @type payload_state :: :live | :possibly_absent | :erased

  @doc false
  @spec state(Facts.t(), String.t()) :: payload_state()
  def state(%Facts{} = facts, target_ref) when is_binary(target_ref) do
    Enum.reduce(facts.erasures, :live, fn {_ref, erasure}, state ->
      if erasure.target_ref == target_ref do
        more_conservative(erasure_state(facts, erasure), state)
      else
        state
      end
    end)
  end

  @doc false
  @spec requestable?(Facts.t(), String.t()) :: :ok | {:error, term()}
  def requestable?(%Facts{} = facts, target_ref) when is_binary(target_ref) do
    blocking =
      Enum.find_value(facts.erasures, fn {_ref, erasure} ->
        if erasure.target_ref == target_ref and
             (erasure_state(facts, erasure) != :live or not no_effect?(facts, erasure)) do
          erasure
        end
      end)

    if is_nil(blocking),
      do: :ok,
      else: {:error, {:erasure_target_already_requested, target_ref, blocking.ref}}
  end

  defp erasure_state(facts, erasure) do
    Enum.reduce(facts.attempts, :live, fn {_ref, attempt}, state ->
      if attempt.act_ref == erasure.source_act_ref do
        more_conservative(attempt_state(facts, attempt), state)
      else
        state
      end
    end)
  end

  defp attempt_state(facts, attempt) do
    outcomes =
      facts.outcomes
      |> Map.values()
      |> Enum.filter(&(&1.attempt_ref == attempt.ref))

    initial_terminal =
      outcomes
      |> Enum.filter(&(&1.status in @terminal_outcomes))
      |> Enum.min_by(&{&1.observed_at, &1.ref}, fn -> nil end)

    correction =
      if initial_terminal do
        Enum.find(outcomes, &(&1.contradicts_outcome_ref == initial_terminal.ref))
      end

    case correction || initial_terminal do
      nil -> :possibly_absent
      %{status: :succeeded} -> :erased
      %{status: :definitive_no_effect} -> :live
      _failed_or_ambiguous -> :possibly_absent
    end
  end

  defp no_effect?(facts, erasure) do
    {attempt_seen?, every_attempt_live?} =
      Enum.reduce(facts.attempts, {false, true}, fn {_ref, attempt}, {seen?, live?} ->
        if attempt.act_ref == erasure.source_act_ref do
          {true, live? and attempt_state(facts, attempt) == :live}
        else
          {seen?, live?}
        end
      end)

    if attempt_seen?,
      do: every_attempt_live?,
      else: match?({:cancelled, _cancellation}, facts.terminal_dispatches[erasure.source_act_ref])
  end

  defp more_conservative(:erased, _state), do: :erased
  defp more_conservative(_state, :erased), do: :erased
  defp more_conservative(:possibly_absent, _state), do: :possibly_absent
  defp more_conservative(_state, :possibly_absent), do: :possibly_absent
  defp more_conservative(:live, :live), do: :live
end
