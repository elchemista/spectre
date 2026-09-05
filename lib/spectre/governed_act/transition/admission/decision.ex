defmodule Spectre.GovernedAct.Transition.Admission.Decision do
  @moduledoc """
  Reconstructs the complete admission-time proof for one durable Decision.

  A Decision is accepted only against the immediately preceding authority
  revision, its authenticated Scope, the active foundation records, its exact
  Evidence basis and the Mandate snapshot it names. Retained-controller
  revocation remains a closed, deliberately narrow exception.
  """

  alias Spectre.{Decision, SubmissionContext}
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{State, View}
  alias Spectre.Mandate.Revocation

  @doc false
  @spec validate(State.t(), Decision.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def validate(%State{} = state, %Decision{} = decision, entry_revision) do
    with :ok <- validate_revision(state, decision, entry_revision),
         :ok <- validate_context(state, decision),
         :ok <- validate_evidence_basis(state, decision) do
      validate_authority(state, decision)
    end
  end

  @doc false
  @spec retained_revocation?(Decision.t(), Spectre.Mandate.t()) :: boolean()
  def retained_revocation?(%Decision{} = decision, %Spectre.Mandate{} = mandate) do
    decision.candidate_class == "mandate.revoke" and
      decision.mandate_ref == mandate.ref and
      mandate.revocation["mode"] == :retained_controller
  end

  defp validate_revision(state, decision, entry_revision) do
    expected_entry_revision = state.revision + 1

    cond do
      decision.authority_revision != state.revision ->
        {:error,
         {:decision_authority_revision_mismatch, decision.ref, state.revision,
          decision.authority_revision}}

      not is_nil(entry_revision) and entry_revision != expected_entry_revision ->
        {:error,
         {:decision_entry_revision_mismatch, decision.ref, expected_entry_revision,
          entry_revision}}

      not is_nil(entry_revision) and decision.authority_revision != entry_revision - 1 ->
        {:error, {:decision_authority_fence_mismatch, decision.ref, entry_revision}}

      true ->
        :ok
    end
  end

  defp validate_context(state, decision) do
    with {:ok, context} <- submission_context(decision),
         {:ok, _opening} <- View.scope_context(state, context) do
      validate_context_bindings(state, decision)
    end
  end

  defp validate_context_bindings(state, decision) do
    cond do
      decision.domain_ref != state.domain_ref ->
        {:error, {:decision_domain_mismatch, decision.ref, decision.domain_ref}}

      not Map.has_key?(state.catalog.principals, decision.authenticated_principal_ref) ->
        {:error, {:authenticated_principal_not_found, decision.authenticated_principal_ref}}

      true ->
        validate_foundation_binding(state, decision)
    end
  end

  defp validate_foundation_binding(state, decision) do
    profile = State.host_profile(state)
    surface = State.surface(state)

    cond do
      is_nil(profile) or decision.host_profile_ref != profile.ref ->
        {:error, {:decision_host_profile_mismatch, decision.ref}}

      is_nil(surface) or decision.surface_revision != surface.revision ->
        {:error, {:decision_surface_revision_mismatch, decision.ref}}

      decision.outcome == :admitted and
          decision.proposer_ref != decision.authenticated_principal_ref ->
        {:error, {:admitted_decision_principal_mismatch, decision.ref}}

      true ->
        :ok
    end
  end

  defp submission_context(decision) do
    SubmissionContext.from_decision(decision)
    |> case do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:invalid_decision_submission_context, decision.ref, reason}}
    end
  end

  defp validate_evidence_basis(state, decision) do
    with :ok <-
           ErasureAnalysis.validate_evidence_available(
             state,
             decision.recognition_evidence_refs
           ),
         {:ok, evidence} <- View.evidence_set(state, decision.recognition_evidence_refs) do
      case Enum.find(evidence, &(&1.observed_at > decision.decided_at)) do
        nil -> :ok
        future -> {:error, {:decision_evidence_from_future, decision.ref, future.ref}}
      end
    end
  end

  defp validate_authority(_state, %{mandate_ref: nil, outcome: outcome})
       when outcome != :admitted,
       do: :ok

  defp validate_authority(state, decision) do
    case Map.fetch(state.mandates, decision.mandate_ref) do
      {:ok, mandate} -> validate_mandate(state, decision, mandate)
      :error -> {:error, {:decision_mandate_not_found, decision.mandate_ref}}
    end
  end

  defp validate_mandate(state, decision, mandate) do
    cond do
      decision.mandate_revision != mandate.revision ->
        {:error, {:decision_mandate_revision_mismatch, decision.ref}}

      decision.outcome != :admitted ->
        :ok

      decision.reasons != [] ->
        {:error, {:admitted_decision_has_reasons, decision.ref}}

      retained_revocation?(decision, mandate) ->
        validate_retained_revocation(state, decision, mandate)

      true ->
        validate_holder_authority(state, decision, mandate)
    end
  end

  defp validate_holder_authority(state, decision, mandate) do
    cond do
      decision.authenticated_principal_ref != mandate.holder_ref ->
        {:error, {:decision_mandate_holder_mismatch, decision.ref}}

      decision.authorizer_ref != mandate.grantor_ref ->
        {:error, {:decision_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref not in mandate.executor_refs ->
        {:error, {:decision_executor_outside_mandate, decision.ref}}

      true ->
        validate_mandate_current(state, decision, mandate)
    end
  end

  defp validate_retained_revocation(state, decision, mandate) do
    controllers = mandate.revocation["controller_refs"]

    cond do
      decision.authenticated_principal_ref not in controllers ->
        {:error, {:decision_revocation_controller_mismatch, decision.ref}}

      decision.proposer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_proposer_mismatch, decision.ref}}

      decision.authorizer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref != GovernedExecution.kernel_executor_ref() ->
        {:error, {:decision_revocation_executor_mismatch, decision.ref}}

      not narrow_revocation?(decision) ->
        {:error, {:decision_revocation_not_narrow, decision.ref}}

      true ->
        validate_mandate_current(state, decision, mandate)
    end
  end

  defp narrow_revocation?(decision) do
    decision.recognition_refs == [] and decision.recognition_evidence_refs == [] and
      not Decision.reservations?(decision)
  end

  defp validate_mandate_current(state, decision, mandate) do
    cond do
      decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
        {:error, {:decision_mandate_not_current, decision.ref}}

      effective_revocation?(Map.get(state.revocations, mandate.ref), decision.decided_at) ->
        {:error, {:decision_mandate_revoked, decision.ref}}

      true ->
        :ok
    end
  end

  defp effective_revocation?(nil, _time), do: false

  defp effective_revocation?(%Revocation{effective_at: effective_at}, time)
       when is_integer(time),
       do: time >= effective_at

  defp effective_revocation?(_invalid, _time), do: true
end
