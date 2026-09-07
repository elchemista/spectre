defmodule Spectre.Kernel.Authority.RetainedRevocation do
  @moduledoc """
  Validates the one-operation authority retained by a Mandate controller.

  A retained controller may revoke only the exact Mandate which names it. The
  result is an ephemeral `Authority.Effective` value, never a second durable
  Mandate and never authority for an arbitrary ledger-internal consequence.
  """

  alias Spectre.{Candidate, Mandate}
  alias Spectre.GovernedAct.Class
  alias Spectre.GovernedAct.Execution
  alias Spectre.Kernel.Authority.{Effective, Facts, Status}

  @class "mandate.revoke"

  @doc false
  @spec request?(Candidate.t(), Mandate.t()) :: boolean()
  def request?(%Candidate{} = candidate, %Mandate{} = mandate) do
    candidate.class == @class and
      candidate.requested_mandate_ref == mandate.ref and
      mandate.revocation["mode"] == :retained_controller
  end

  @doc false
  @spec authorize(Candidate.t(), map(), Mandate.t(), Facts.t(), integer()) ::
          {:ok, Effective.t()} | {:error, term()}
  def authorize(
        %Candidate{} = candidate,
        context,
        %Mandate{} = mandate,
        %Facts{} = facts,
        time
      )
      when is_map(context) and is_integer(time) do
    controller_ref = context.authenticated_principal_ref

    with :ok <- Status.current_at(mandate, time),
         :ok <- Status.not_directly_revoked(mandate, facts, time),
         :ok <- retained_controller(candidate, controller_ref, mandate),
         :ok <- exact_request(candidate, context, mandate) do
      {:ok, Effective.retained_revocation(mandate, candidate, controller_ref)}
    end
  end

  defp retained_controller(candidate, controller_ref, mandate) do
    claimed = candidate.proposer_ref
    controllers = mandate.revocation["controller_refs"]

    cond do
      not present?(claimed) -> {:error, :candidate_proposer_missing}
      claimed != controller_ref -> {:error, :proposer_claim_mismatch}
      controller_ref not in controllers -> {:error, :principal_not_revocation_controller}
      true -> :ok
    end
  end

  defp exact_request(candidate, context, mandate) do
    expected_consequence = %{"mandate_revoke" => %{"mandate_ref" => mandate.ref}}

    checks = [
      {candidate.consequence == expected_consequence, :revocation_consequence_mismatch},
      {candidate.executor_ref == Execution.kernel_executor_ref(),
       :retained_revocation_executor_mismatch},
      {candidate.executor_contract_ref == Execution.kernel_contract_ref(),
       :retained_revocation_contract_mismatch},
      {candidate.scope_ref == context.scope_ref, :candidate_scope_mismatch},
      {candidate.subject_refs == [], :retained_revocation_subjects_not_empty},
      {candidate.target_refs == [mandate.ref], :retained_revocation_targets_mismatch},
      {candidate.purpose_ref == Class.retained_revocation_purpose_ref(),
       :retained_revocation_purpose_mismatch},
      {candidate.purpose_params == %{}, :retained_revocation_purpose_parameters_not_empty},
      {candidate.evidence_refs == [], :retained_revocation_evidence_not_empty},
      {is_nil(candidate.disclosure), :retained_revocation_disclosure_present},
      {is_nil(candidate.presentation_ref), :retained_revocation_presentation_present},
      {candidate.meter_requests == %{}, :retained_revocation_meter_request_present},
      {candidate.observation_window_ms == 0, :retained_revocation_observation_window_present},
      {candidate.accountable_ref == mandate.accountable_ref, :accountable_claim_mismatch},
      {Class.exact_row?(@class, candidate.row), :retained_revocation_row_mismatch}
    ]

    case Enum.find(checks, fn {valid?, _reason} -> not valid? end) do
      nil -> :ok
      {false, reason} -> {:error, reason}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
