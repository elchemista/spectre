defmodule Spectre.GovernedAct.Transition.Outcome do
  @moduledoc """
  Pure cross-record rules for admitting an Outcome into governed history.

  The live observation planner and ledger replay call the same functions for
  class restrictions, correction ordering and Evidence attestation. They keep
  their own responsibilities—event construction on one side and state mutation
  on the other—without maintaining two versions of what an Outcome means.
  """

  alias Spectre.{Act, Attempt, Evidence, Outcome}
  alias Spectre.GovernedAct.ReadIndex
  alias Spectre.Outcome.Attestation

  @doc "Checks class-specific restrictions on an observed result."
  @spec validate_for_act(Act.t(), Outcome.t()) :: :ok | {:error, term()}
  def validate_for_act(%Act{class: "data.erase"}, %Outcome{status: :failed}),
    do: {:error, :erasure_failure_must_be_definitive_or_ambiguous}

  def validate_for_act(%Act{}, %Outcome{}), do: :ok
  def validate_for_act(_act, _outcome), do: {:error, :invalid_outcome_transition}

  @doc "Checks that an Outcome is a valid next observation for its Attempt."
  @spec validate_history(%{optional(String.t()) => Outcome.t()}, Outcome.t()) ::
          :ok | {:error, term()}
  def validate_history(outcomes, %Outcome{} = outcome) when is_map(outcomes) do
    if Outcome.correction?(outcome) do
      validate_correction(outcomes, outcome)
    else
      validate_terminal_history(outcomes, outcome)
    end
  end

  def validate_history(_outcomes, _outcome), do: {:error, :invalid_outcome_history}

  @doc false
  def validate_state_history(%Spectre.GovernedAct.State{} = state, %Outcome{} = outcome) do
    history = ReadIndex.outcomes_for(state, :attempt, outcome.attempt_ref)
    # Keep even a foreign correction target: the validator must still reject
    # its causal mismatch, rather than hide it through the local index.
    target = Map.take(state.outcomes, [outcome.contradicts_outcome_ref])
    validate_history(Map.merge(history, target), outcome)
  end

  @doc "Validates every Evidence reference attesting an Outcome."
  @spec validate_evidence(
          %{optional(String.t()) => Evidence.t()},
          Outcome.t(),
          Attempt.t(),
          Act.t()
        ) :: :ok | {:error, term()}
  def validate_evidence(evidence_index, %Outcome{} = outcome, %Attempt{} = attempt, %Act{} = act)
      when is_map(evidence_index) do
    Spectre.Validation.all(outcome.evidence_refs, fn ref ->
      case Map.fetch(evidence_index, ref) do
        {:ok, %Evidence{} = evidence} ->
          Attestation.validate(evidence, outcome, attempt, act)

        :error ->
          {:error, {:outcome_evidence_not_found, ref}}

        {:ok, _invalid} ->
          {:error, {:invalid_outcome_evidence, ref}}
      end
    end)
  end

  def validate_evidence(_evidence_index, _outcome, _attempt, _act),
    do: {:error, :invalid_outcome_evidence_index}

  defp validate_terminal_history(outcomes, outcome) do
    terminal =
      Enum.find_value(outcomes, fn {_ref, prior} ->
        if prior.attempt_ref == outcome.attempt_ref and prior.status != :ambiguous,
          do: prior
      end)

    case terminal do
      nil ->
        :ok

      terminal ->
        {:error,
         {:attempt_already_has_definitive_outcome, outcome.attempt_ref, terminal.ref,
          terminal.status}}
    end
  end

  defp validate_correction(outcomes, outcome) do
    case Map.get(outcomes, outcome.contradicts_outcome_ref) do
      nil ->
        {:error, {:corrected_outcome_not_found, outcome.contradicts_outcome_ref}}

      target ->
        validate_correction_target(outcomes, outcome, target)
    end
  end

  defp validate_correction_target(outcomes, outcome, target) do
    cond do
      target.act_ref != outcome.act_ref or target.attempt_ref != outcome.attempt_ref ->
        {:error, {:outcome_correction_cause_mismatch, outcome.ref, target.ref}}

      target.status != :definitive_no_effect ->
        {:error, {:corrected_outcome_not_no_effect, target.ref}}

      outcome.observed_at < target.observed_at ->
        {:error, {:outcome_correction_precedes_target, outcome.ref, target.ref}}

      existing = correction_for(outcomes, target.ref) ->
        {:error, {:outcome_already_corrected, target.ref, existing.ref}}

      true ->
        :ok
    end
  end

  defp correction_for(outcomes, target_ref) do
    Enum.find_value(outcomes, fn {_ref, prior} ->
      if prior.contradicts_outcome_ref == target_ref, do: prior
    end)
  end
end
