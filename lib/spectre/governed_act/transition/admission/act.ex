defmodule Spectre.GovernedAct.Transition.Admission.Act do
  @moduledoc """
  Reconstructs the complete admission proof carried from Decision into Act.

  The proof rebuilds the frozen Candidate, checks its Surface contract,
  admission-time authority, Evidence and Presentation basis, then recomputes
  the Meter reservation plan. It accepts no live callback or host route; all
  inputs are canonical records already present in the governed prefix.
  """

  alias Spectre.{Act, Candidate, Decision, Disclosure, SubmissionContext, Surface}
  alias Spectre.Canonical.Record
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.Admission.Binding
  alias Spectre.GovernedAct.{Index, MeterState, State, View}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.Transition.Admission.Decision, as: DecisionProof
  alias Spectre.GovernedAct.Transition.Admission.Presentation, as: PresentationProof
  alias Spectre.Kernel.{Authority, Meter, Recognition}
  alias Spectre.Kernel.Authority.Effective
  alias Spectre.Kernel.Meter.Amounts

  @doc false
  @spec validate(State.t(), Act.t(), Decision.t()) :: :ok | {:error, term()}
  def validate(%State{} = state, %Act{} = act, %Decision{} = decision) do
    with :ok <- one_act_per_decision(state, decision),
         :ok <- match_act_to_decision(state, act, decision),
         {:ok, candidate} <- Binding.candidate(act) do
      validate_candidate(state, candidate, act, decision)
    end
  end

  defp match_act_to_decision(state, act, decision) do
    mismatch = Binding.mismatch(decision, act)
    admission = Map.get(state.admissions, act.candidate_identity_key)
    mandate = Map.get(state.mandates, act.mandate_ref)

    cond do
      decision.outcome != :admitted ->
        {:error, {:act_for_non_admitted_decision, decision.ref}}

      state.revision != decision.authority_revision + 1 ->
        {:error, {:act_not_adjacent_to_decision, act.ref, decision.ref}}

      match?({:candidate_class, _, _}, mismatch) ->
        {:error, {:decision_act_class_mismatch, decision.ref, act.ref}}

      match?({:material_digest, _, _}, mismatch) ->
        {:error, {:act_material_digest_mismatch, act.ref}}

      match?({:committed_at, _, _}, mismatch) ->
        {:error, {:act_commit_time_mismatch, act.ref}}

      mismatch ->
        {field, _expected, _actual} = mismatch
        {:error, {:decision_act_mismatch, field, decision.ref, act.ref}}

      not executor_contract_authorized?(act, decision, mandate) ->
        {:error, {:act_executor_contract_outside_mandate, act.ref}}

      not match?(%{decision_ref: decision_ref} when decision_ref == decision.ref, admission) ->
        {:error, {:act_candidate_identity_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp executor_contract_authorized?(_act, _decision, nil), do: false

  defp executor_contract_authorized?(act, decision, mandate) do
    act.executor_contract_ref in mandate.executor_contract_refs or
      (DecisionProof.retained_revocation?(decision, mandate) and
         act.executor_contract_ref == GovernedExecution.kernel_contract_ref())
  end

  defp one_act_per_decision(state, decision) do
    case Map.fetch(state.admissions, decision.candidate_identity_key) do
      {:ok, %{decision_ref: decision_ref, act_ref: nil}} when decision_ref == decision.ref ->
        :ok

      {:ok, %{decision_ref: decision_ref, act_ref: existing_ref}}
      when decision_ref == decision.ref and is_binary(existing_ref) ->
        {:error, {:decision_already_has_act, decision.ref, existing_ref}}

      _missing_or_invalid ->
        {:error, {:invalid_candidate_admission, decision.candidate_identity_key}}
    end
  end

  defp validate_candidate(state, candidate, act, decision) do
    available_evidence = state |> ErasureAnalysis.available_evidence() |> Map.values()

    with {:ok, mandate} <- Index.fetch_mandate(state, act.mandate_ref),
         :ok <- validate_surface_binding(state, candidate, act),
         :ok <- ErasureAnalysis.validate_evidence_available(state, candidate.evidence_refs),
         :ok <- validate_disclosure(state, candidate),
         {:ok, effective_mandate} <-
           authorize_candidate(state, candidate, act, decision, mandate),
         {:ok, mandate_basis_refs} <-
           validate_recognition(state, candidate, decision, effective_mandate, available_evidence),
         {:ok, presentation_basis_refs} <-
           PresentationProof.validate(state, candidate, act, available_evidence),
         :ok <-
           validate_exact_recognition_basis(
             decision,
             mandate_basis_refs ++ presentation_basis_refs
           ) do
      validate_reservation_contract(state, candidate, act, decision, effective_mandate)
    end
  end

  defp validate_disclosure(_state, %Candidate{disclosure: nil}), do: :ok

  defp validate_disclosure(state, %Candidate{disclosure: disclosure}),
    do: Disclosure.verify_sources(disclosure, state.evidence)

  defp validate_surface_binding(%State{} = state, candidate, act) do
    case State.surface(state) do
      %Surface{} = surface -> validate_surface(surface, candidate, act)
      nil -> {:error, {:act_surface_not_found, act.ref}}
    end
  end

  defp validate_surface(%Surface{} = surface, candidate, act) do
    case Surface.classify(surface, candidate.class) do
      {:ok, row} when row == candidate.row ->
        with :ok <- Surface.validate_consequence(surface, candidate) do
          if Surface.presentation_required?(surface, candidate.class) and
               is_nil(candidate.presentation_ref) do
            {:error, {:act_missing_required_presentation, act.ref, candidate.class}}
          else
            :ok
          end
        else
          {:error, reason} -> {:error, {:act_consequence_contract_mismatch, act.ref, reason}}
        end

      {:ok, _different} ->
        {:error, {:act_surface_row_mismatch, act.ref}}

      {:error, :unknown_class} ->
        {:error, {:act_unknown_surface_class, act.ref, candidate.class}}
    end
  end

  defp authorize_candidate(state, candidate, act, decision, mandate) do
    view = View.authority(state)

    with {:ok, context} <- SubmissionContext.from_decision(decision),
         {:ok, effective} <-
           Authority.authorize(candidate, context, mandate, view, act.committed_at),
         {:ok, snapshot} <- Effective.snapshot(effective, candidate) do
      {:ok, snapshot}
    else
      {:error, reason} -> {:error, {:act_without_current_authority, act.ref, reason}}
    end
  end

  defp validate_recognition(state, candidate, decision, mandate, evidence) do
    expected_refs = mandate.conditions |> Enum.map(&Record.ref/1) |> Enum.sort()

    {recognition, basis_refs} =
      Recognition.check_with_basis(mandate.conditions, evidence, decision.decided_at)

    with true <- decision.recognition_refs == expected_refs,
         {:ok, _declared_evidence} <- View.evidence_set(state, candidate.evidence_refs),
         :ok <- Recognition.validate_declared_basis(basis_refs, candidate.evidence_refs),
         :satisfied <- recognition do
      {:ok, basis_refs}
    else
      false -> {:error, {:decision_recognition_refs_mismatch, decision.ref}}
      {:error, _reason} = error -> error
      result -> {:error, {:act_recognition_not_satisfied, candidate.ref, result}}
    end
  end

  defp validate_exact_recognition_basis(decision, basis_refs) do
    expected = basis_refs |> Enum.uniq() |> Enum.sort()

    if decision.recognition_evidence_refs == expected,
      do: :ok,
      else: {:error, {:decision_recognition_evidence_refs_mismatch, decision.ref}}
  end

  defp validate_reservation_contract(state, candidate, act, decision, mandate) do
    requests = candidate.meter_requests

    cond do
      map_size(requests) > 0 and not act.row.spend ->
        {:error, {:act_meter_request_not_declared_in_row, act.ref}}

      map_size(requests) == 0 and act.row.spend ->
        {:error, {:act_spend_without_meter_request, act.ref}}

      Enum.any?(Map.keys(requests), &(not Map.has_key?(mandate.meters, &1))) ->
        {:error, {:act_meter_outside_mandate, act.ref}}

      true ->
        with {:ok, declared} <- Amounts.normalize(decision.reservations),
             true <- declared == requests,
             {:ok, accounts} <- MeterState.accounts(state, mandate.ref),
             {:ok, planned} <- Meter.plan_reservations(requests, accounts),
             true <- planned == requests do
          :ok
        else
          false -> {:error, {:act_reservation_plan_mismatch, act.ref}}
          {:error, reason} -> {:error, {:act_invalid_reservation_plan, act.ref, reason}}
        end
    end
  end
end
