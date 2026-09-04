defmodule Spectre.GovernedAct.Admission.Binding do
  @moduledoc """
  Pure structural boundary between Candidate, admitted Decision and Act.

  Admission, replay and execution recovery all cross the same immutable
  boundary. Keeping its field correspondence here prevents those drivers from
  gradually constructing or accepting different representations of the same
  governed act. The Decision/Act matrix names the semantic field exposed in an
  error, followed by the fields which must be equal. The construction matrices
  keep the two intentional sources visible: Candidate material and the
  admission facts frozen by Decision.
  """

  alias Spectre.{Act, Candidate, Decision}

  @field_matrix [
    {:decision_ref, :ref, :decision_ref},
    {:candidate_identity_key, :candidate_identity_key, :candidate_identity_key},
    {:candidate_digest, :candidate_digest, :candidate_digest},
    {:candidate_class, :candidate_class, :class},
    {:consent, :consent, :consent},
    {:submission_context_ref, :submission_context_ref, :submission_context_ref},
    {:authenticated_principal_ref, :authenticated_principal_ref, :authenticated_principal_ref},
    {:authentication_ref, :authentication_ref, :authentication_ref},
    {:ingress_ref, :ingress_ref, :ingress_ref},
    {:host_generation, :host_generation, :host_generation},
    {:material_digest, :candidate_digest, :material_digest},
    {:mandate_ref, :mandate_ref, :mandate_ref},
    {:mandate_revision, :mandate_revision, :mandate_revision},
    {:proposer_ref, :proposer_ref, :proposer_ref},
    {:executor_ref, :executor_ref, :executor_ref},
    {:authorizer_ref, :authorizer_ref, :authorizer_ref},
    {:accountable_ref, :accountable_ref, :accountable_ref},
    {:scope_ref, :scope_ref, :scope_ref},
    {:recognition_refs, :recognition_refs, :recognition_refs},
    {:recognition_evidence_refs, :recognition_evidence_refs, :recognition_evidence_refs},
    {:reservations, :reservations, :reservations},
    {:host_profile_ref, :host_profile_ref, :host_profile_ref},
    {:surface_revision, :surface_revision, :surface_revision},
    {:committed_at, :decided_at, :committed_at}
  ]

  @candidate_to_act [
    {:candidate_identity_key, :identity_key},
    {:candidate_digest, :material_digest},
    {:class, :class},
    {:row, :row},
    {:consequence, :consequence},
    {:consent, :consent},
    {:material_digest, :material_digest},
    {:requested_mandate_ref, :requested_mandate_ref},
    {:subject_refs, :subject_refs},
    {:target_refs, :target_refs},
    {:purpose_ref, :purpose_ref},
    {:purpose_params, :purpose_params},
    {:evidence_refs, :evidence_refs},
    {:disclosure, :disclosure},
    {:presentation_ref, :presentation_ref},
    {:executor_contract_ref, :executor_contract_ref},
    {:observation_window_ms, :observation_window_ms}
  ]

  @decision_to_act [
    {:decision_ref, :ref},
    {:submission_context_ref, :submission_context_ref},
    {:authenticated_principal_ref, :authenticated_principal_ref},
    {:authentication_ref, :authentication_ref},
    {:ingress_ref, :ingress_ref},
    {:host_generation, :host_generation},
    {:proposer_ref, :proposer_ref},
    {:executor_ref, :executor_ref},
    {:authorizer_ref, :authorizer_ref},
    {:accountable_ref, :accountable_ref},
    {:scope_ref, :scope_ref},
    {:mandate_ref, :mandate_ref},
    {:mandate_revision, :mandate_revision},
    {:recognition_refs, :recognition_refs},
    {:recognition_evidence_refs, :recognition_evidence_refs},
    {:reservations, :reservations},
    {:host_profile_ref, :host_profile_ref},
    {:surface_revision, :surface_revision},
    {:committed_at, :decided_at}
  ]

  @act_to_candidate [
    {:identity_key, :candidate_identity_key},
    {:material_digest, :material_digest},
    {:class, :class},
    {:consequence, :consequence},
    {:row, :row},
    {:requested_mandate_ref, :requested_mandate_ref},
    {:proposer_ref, :proposer_ref},
    {:executor_ref, :executor_ref},
    {:accountable_ref, :accountable_ref},
    {:scope_ref, :scope_ref},
    {:subject_refs, :subject_refs},
    {:target_refs, :target_refs},
    {:purpose_ref, :purpose_ref},
    {:purpose_params, :purpose_params},
    {:consent, :consent},
    {:evidence_refs, :evidence_refs},
    {:disclosure, :disclosure},
    {:presentation_ref, :presentation_ref},
    {:meter_requests, :reservations},
    {:executor_contract_ref, :executor_contract_ref},
    {:observation_window_ms, :observation_window_ms}
  ]

  @type mismatch :: {atom(), term(), term()}

  @doc "Returns the first canonical field mismatch, or `nil` when the records are linked."
  @spec mismatch(Decision.t(), Act.t()) :: mismatch() | nil
  def mismatch(%Decision{} = decision, %Act{} = act) do
    Enum.find_value(@field_matrix, fn {name, decision_field, act_field} ->
      expected = Map.fetch!(decision, decision_field)
      actual = Map.fetch!(act, act_field)

      if expected == actual, do: nil, else: {name, expected, actual}
    end)
  end

  @doc "Builds the immutable Act from Candidate material and its admitted Decision."
  @spec act(Candidate.t(), Decision.t()) :: {:ok, Act.t()} | {:error, term()}
  def act(%Candidate{} = candidate, %Decision{outcome: :admitted} = decision) do
    candidate
    |> take_as(@candidate_to_act)
    |> Map.merge(take_as(decision, @decision_to_act))
    |> Act.new()
  end

  def act(%Candidate{}, %Decision{}), do: {:error, :act_requires_admitted_decision}

  @doc "Rebuilds the exact Candidate material frozen in an Act."
  @spec candidate(Act.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def candidate(%Act{} = act) do
    act
    |> take_as(@act_to_candidate)
    |> Candidate.new()
    |> case do
      {:ok, candidate} -> {:ok, candidate}
      {:error, _reason} -> {:error, :act_candidate_material_mismatch}
    end
  end

  defp take_as(record, fields) do
    Map.new(fields, fn {target, source} -> {target, Map.fetch!(record, source)} end)
  end
end
