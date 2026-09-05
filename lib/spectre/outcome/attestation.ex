defmodule Spectre.Outcome.Attestation do
  @moduledoc false

  alias Spectre.{Act, Attempt, Evidence, Outcome}

  @statuses Outcome.statuses()

  @spec validate(Evidence.t(), Outcome.t(), Attempt.t(), Act.t()) ::
          :ok | {:error, term()}
  def validate(
        %Evidence{} = evidence,
        %Outcome{} = outcome,
        %Attempt{} = attempt,
        %Act{} = act
      ) do
    with :ok <- validate_boundary(evidence, outcome, attempt, act) do
      validate_claim(evidence, outcome, attempt, act)
    end
  end

  @spec supports?(Evidence.t(), Outcome.status(), Act.t(), Attempt.t(), integer()) :: boolean()
  def supports?(%Evidence{} = evidence, status, %Act{} = act, %Attempt{} = attempt, at)
      when status in @statuses and is_integer(at) do
    valid_boundary?(evidence, act, attempt, at) and
      evidence.proposition == proposition(status, act, attempt) and
      evidence.stance == Outcome.evidence_stance(status)
  end

  def supports?(_evidence, _status, _act, _attempt, _at), do: false

  @doc "Returns whether Evidence is a trusted executor assertion causally relevant to the Attempt."
  @spec causal?(Evidence.t(), Act.t(), Attempt.t(), integer()) :: boolean()
  def causal?(%Evidence{} = evidence, %Act{} = act, %Attempt{} = attempt, at)
      when is_integer(at) do
    valid_boundary?(evidence, act, attempt, at) and
      Enum.any?(@statuses, &(evidence.proposition == proposition(&1, act, attempt)))
  end

  def causal?(_evidence, _act, _attempt, _at), do: false

  defp validate_boundary(evidence, outcome, attempt, act) do
    cond do
      evidence.provenance != :observed ->
        {:error, {:outcome_evidence_not_observed, outcome.ref, evidence.ref}}

      evidence.provisional ->
        {:error, {:outcome_evidence_provisional, outcome.ref, evidence.ref}}

      evidence.assumptions != [] ->
        {:error, {:outcome_evidence_has_assumptions, outcome.ref, evidence.ref}}

      evidence.parent_refs != [] ->
        {:error, {:outcome_evidence_has_parents, outcome.ref, evidence.ref}}

      evidence.observed_at < attempt.started_at ->
        {:error, {:outcome_evidence_precedes_attempt, outcome.ref, evidence.ref}}

      true ->
        validate_executor_binding(evidence, outcome, attempt, act)
    end
  end

  defp validate_executor_binding(evidence, outcome, attempt, act) do
    cond do
      evidence.source_ref != act.executor_ref ->
        {:error, {:outcome_evidence_source_mismatch, outcome.ref, evidence.ref}}

      evidence.issuer_ref != act.executor_ref ->
        {:error, {:outcome_evidence_issuer_mismatch, outcome.ref, evidence.ref}}

      evidence.bindings != bindings(act, attempt) ->
        {:error, {:outcome_evidence_binding_mismatch, outcome.ref, evidence.ref}}

      not Evidence.current_at?(evidence, outcome.observed_at) ->
        {:error, {:outcome_evidence_not_current, outcome.ref, evidence.ref}}

      true ->
        :ok
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

  defp valid_boundary?(evidence, act, attempt, at) do
    evidence.provenance == :observed and not evidence.provisional and
      evidence.assumptions == [] and evidence.parent_refs == [] and
      evidence.source_ref == act.executor_ref and evidence.issuer_ref == act.executor_ref and
      evidence.bindings == bindings(act, attempt) and
      evidence.observed_at >= attempt.started_at and Evidence.current_at?(evidence, at)
  end

  defp proposition(status, act, attempt) do
    Outcome.proposition(status, act.ref, attempt.ref, act.executor_contract_ref)
  end

  defp bindings(act, attempt), do: %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}
end
