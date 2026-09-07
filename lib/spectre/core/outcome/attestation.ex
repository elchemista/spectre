defmodule Spectre.Outcome.Attestation do
  @moduledoc false

  # These are semantic binding checks, not signature verification. The host
  # executor/observer adapter must establish real provenance before entering
  # the runtime. Replays check the recorded identity, timing and claim again.

  alias Spectre.{Act, Attempt, Evidence, Outcome}

  @statuses Outcome.statuses()

  @doc "Checks observed Evidence against the exact executor, Attempt, observation time and claimed Outcome."
  @spec validate(Evidence.t(), Outcome.t(), Attempt.t(), Act.t()) ::
          :ok | {:error, term()}
  def validate(
        %Evidence{} = evidence,
        %Outcome{} = outcome,
        %Attempt{} = attempt,
        %Act{} = act
      ) do
    case boundary_error(evidence, act, attempt, outcome.observed_at) do
      nil -> validate_claim(evidence, outcome, attempt, act)
      reason -> {:error, {reason, outcome.ref, evidence.ref}}
    end
  end

  @doc "Returns whether a causally bound observation supports this status, not merely any status for the Attempt."
  @spec supports?(Evidence.t(), Outcome.status(), Act.t(), Attempt.t(), integer()) :: boolean()
  def supports?(%Evidence{} = evidence, status, %Act{} = act, %Attempt{} = attempt, at)
      when status in @statuses and is_integer(at) do
    is_nil(boundary_error(evidence, act, attempt, at)) and
      evidence.proposition == proposition(status, act, attempt) and
      evidence.stance == Outcome.evidence_stance(status)
  end

  def supports?(_evidence, _status, _act, _attempt, _at), do: false

  @doc "Returns whether Evidence is a trusted executor assertion causally relevant to the Attempt."
  @spec causal?(Evidence.t(), Act.t(), Attempt.t(), integer()) :: boolean()
  def causal?(%Evidence{} = evidence, %Act{} = act, %Attempt{} = attempt, at)
      when is_integer(at) do
    is_nil(boundary_error(evidence, act, attempt, at)) and
      Enum.any?(@statuses, &(evidence.proposition == proposition(&1, act, attempt)))
  end

  def causal?(_evidence, _act, _attempt, _at), do: false

  # Replay needs the diagnostic; Runner classification needs only a predicate.
  # Both must enforce the same causal boundary before interpreting any claim.
  @spec boundary_error(Evidence.t(), Act.t(), Attempt.t(), integer()) :: atom() | nil
  defp boundary_error(evidence, act, attempt, at) do
    cond do
      evidence.provenance != :observed ->
        :outcome_evidence_not_observed

      evidence.provisional ->
        :outcome_evidence_provisional

      evidence.assumptions != [] ->
        :outcome_evidence_has_assumptions

      evidence.parent_refs != [] ->
        :outcome_evidence_has_parents

      evidence.observed_at < attempt.started_at ->
        :outcome_evidence_precedes_attempt

      true ->
        executor_binding_error(evidence, act, attempt, at)
    end
  end

  defp executor_binding_error(evidence, act, attempt, at) do
    cond do
      evidence.source_ref != act.executor_ref ->
        :outcome_evidence_source_mismatch

      evidence.issuer_ref != act.executor_ref ->
        :outcome_evidence_issuer_mismatch

      evidence.bindings != bindings(act, attempt) ->
        :outcome_evidence_binding_mismatch

      not Evidence.current_at?(evidence, at) ->
        :outcome_evidence_not_current

      true ->
        nil
    end
  end

  defp validate_claim(evidence, %Outcome{status: :ambiguous} = outcome, attempt, act) do
    if Enum.any?(@statuses, &(evidence.proposition == proposition(&1, act, attempt))) do
      :ok
    else
      {:error, {:outcome_evidence_proposition_mismatch, outcome.ref, evidence.ref}}
    end
  end

  defp validate_claim(evidence, outcome, attempt, act) do
    expected_stance = Outcome.evidence_stance(outcome.status)

    cond do
      evidence.proposition != proposition(outcome.status, act, attempt) ->
        {:error, {:outcome_evidence_proposition_mismatch, outcome.ref, evidence.ref}}

      evidence.stance != expected_stance ->
        {:error,
         {:outcome_evidence_stance_mismatch, outcome.ref, evidence.ref, expected_stance,
          evidence.stance}}

      true ->
        :ok
    end
  end

  defp proposition(status, act, attempt) do
    Outcome.proposition(status, act.ref, attempt.ref, act.executor_contract_ref)
  end

  defp bindings(act, attempt), do: %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}
end
