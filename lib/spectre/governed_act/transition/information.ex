defmodule Spectre.GovernedAct.Transition.Information do
  @moduledoc """
  Transitions for governed information and its provenance.

  Evidence, prepared Presentations, declassification records, and erasure
  requests share one concern: preserving a canonical, auditable information
  lineage. This module validates Scope binding, source availability, parent
  ordering, approval evidence, and the exact governing Act before updating the
  disposable read model.
  """

  alias Spectre.{
    Act,
    Declassification,
    Disclosure,
    Erasure,
    Evidence,
    Presentation,
    SubmissionContext
  }

  alias Spectre.Domain.Event
  alias Spectre.Duty.EvidenceCause
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Evidence.Derivation
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{Index, State, View}
  alias Spectre.Kernel.Authority

  def apply(
        %State{} = projection,
        %Event{type: "declassification_recorded", identity: identity, data: data},
        _revision
      ) do
    with {:ok, record} <-
           Index.restore_unique(
             projection.declassifications,
             Declassification,
             identity,
             data,
             :declassification
           ),
         :ok <- unique_declassification_act(projection, record),
         :ok <- unique_declassified_evidence(projection, record),
         {:ok, act} <- Index.fetch_act(projection, record.source_act_ref),
         {:ok, evidence} <- validate_declassification(projection, act, record) do
      {:ok,
       %{
         projection
         | declassifications: Map.put(projection.declassifications, identity, record),
           declassifications_by_evidence:
             Map.put(projection.declassifications_by_evidence, evidence.ref, identity)
       }}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "evidence_recorded", identity: identity, data: data},
        _revision
      ) do
    with {:ok, evidence} <-
           Index.restore_unique(projection.evidence, Evidence, identity, data, :evidence),
         :ok <- validate_evidence_scope_binding(projection, evidence),
         :ok <- validate_evidence_lineage(projection, evidence),
         :ok <- validate_presentation_approval_evidence(projection, evidence),
         :ok <- validate_duty_cause_evidence(projection, evidence) do
      {:ok, %{projection | evidence: Map.put(projection.evidence, identity, evidence)}}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "presentation_recorded", identity: identity, data: data},
        _revision
      ) do
    with {:ok, presentation} <-
           Index.restore_unique(
             projection.presentations,
             Presentation,
             identity,
             data,
             :presentation
           ),
         :ok <- validate_prepared_presentation(projection, presentation) do
      {:ok,
       %{projection | presentations: Map.put(projection.presentations, identity, presentation)}}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "erasure_requested", identity: identity, data: data},
        _revision
      ) do
    with {:ok, erasure} <-
           Index.restore_unique(projection.erasures, Erasure, identity, data, :erasure),
         :ok <- unique_erasure_act(projection, erasure),
         {:ok, act} <- Index.fetch_act(projection, erasure.source_act_ref),
         :ok <- validate_erasure_request(projection, act, erasure) do
      {:ok, %{projection | erasures: Map.put(projection.erasures, identity, erasure)}}
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_information_event, type}}

  defp unique_declassification_act(projection, record) do
    case record_for_source_act(projection.declassifications, record.source_act_ref) do
      nil ->
        :ok

      existing_ref ->
        {:error, {:act_already_has_declassification, record.source_act_ref, existing_ref}}
    end
  end

  defp unique_declassified_evidence(projection, record) do
    cond do
      Map.has_key?(projection.evidence, record.evidence_ref) ->
        {:error, {:declassified_evidence_already_recorded, record.evidence_ref}}

      Map.has_key?(projection.declassifications_by_evidence, record.evidence_ref) ->
        {:error, {:evidence_already_declassified, record.evidence_ref}}

      true ->
        :ok
    end
  end

  defp validate_declassification(
         projection,
         %Act{
           class: "data.declassify",
           consequence: %{"evidence_declassification" => draft}
         } = act,
         record
       )
       when map_size(act.consequence) == 1 do
    with true <- Act.row?(act, [:write, :govern]),
         true <- not Act.reservations?(act),
         true <- GovernedExecution.ledger_internal?(act),
         {:ok, decoded} <- Declassification.decode_draft(draft),
         true <- decoded.canonical == draft,
         :ok <- Declassification.validate_producer(decoded.evidence, act.proposer_ref),
         {:ok, mandate} <- Index.fetch_mandate(projection, act.mandate_ref),
         :ok <-
           Authority.owners_authorize_mandate?(
             mandate,
             decoded.removed_owner_refs,
             View.authority(projection)
           ),
         {:ok, expected} <- Declassification.from_draft(draft, act.ref, act.committed_at),
         true <- expected == record,
         :ok <-
           ErasureAnalysis.validate_evidence_available(
             projection,
             decoded.evidence.parent_refs
           ),
         {:ok, parents} <- View.evidence_set(projection, decoded.evidence.parent_refs),
         :ok <- Declassification.validate_transition(record, decoded.evidence, parents),
         {:ok, required_targets} <-
           Declassification.required_target_refs(decoded.evidence, decoded.removed_labels),
         true <- Act.targets?(act, required_targets) do
      {:ok, decoded.evidence}
    else
      false -> {:error, {:invalid_evidence_declassification, record.ref, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_declassification(_projection, act, record),
    do: {:error, {:invalid_declassification_act, record.ref, act.ref}}

  defp unique_erasure_act(projection, erasure) do
    case record_for_source_act(projection.erasures, erasure.source_act_ref) do
      nil ->
        :ok

      existing_ref ->
        {:error, {:act_already_has_erasure_request, erasure.source_act_ref, existing_ref}}
    end
  end

  defp record_for_source_act(records, source_act_ref) do
    Enum.find_value(records, fn
      {ref, %{source_act_ref: ^source_act_ref}} -> ref
      {_ref, _record} -> nil
    end)
  end

  defp validate_erasure_request(projection, act, erasure) do
    prefix = %{projection | acts: Map.delete(projection.acts, act.ref)}

    with {:ok, draft} <- Erasure.request_draft(erasure) do
      cond do
        act.class != "data.erase" ->
          {:error, {:erasure_act_class_mismatch, act.ref, act.class}}

        not Act.row?(act, [:attempt, :write, :govern]) ->
          {:error, {:erasure_act_row_mismatch, act.ref}}

        act.consequence != %{"erasure_request" => draft} ->
          {:error, {:erasure_consequence_mismatch, act.ref}}

        erasure.scope_ref != act.scope_ref ->
          {:error, {:erasure_scope_mismatch, erasure.ref, act.ref}}

        erasure.target_ref not in act.target_refs ->
          {:error, {:erasure_target_not_bound_to_act, erasure.ref, act.ref}}

        erasure.requested_at > act.committed_at ->
          {:error, {:erasure_request_from_future, erasure.ref}}

        true ->
          validate_erasure_target(prefix, erasure, draft)
      end
    end
  end

  defp validate_erasure_target(prefix, erasure, draft) do
    with :ok <- ErasureAnalysis.requestable?(prefix, erasure.target_ref) do
      ErasureAnalysis.validate_request(prefix, draft)
    end
  end

  defp validate_evidence_scope_binding(projection, evidence) do
    with {:ok, context} <- SubmissionContext.extract_evidence_context(evidence.bindings) do
      validate_evidence_context(projection, evidence, context)
    end
  end

  defp validate_evidence_context(_projection, _evidence, nil), do: :ok

  defp validate_evidence_context(projection, evidence, context) do
    with {:ok, opening} <- View.scope_context(projection, context) do
      if evidence.provenance != :observed or evidence.source_ref == opening.ingress_ref,
        do: :ok,
        else: {:error, {:evidence_scope_ingress_source_mismatch, evidence.ref, context.scope_ref}}
    end
  end

  defp validate_prepared_presentation(projection, presentation) do
    case Map.fetch(projection.scopes, presentation.scope_ref) do
      {:ok, opening} when presentation.prepared_at >= opening.opened_at ->
        with :ok <-
               ErasureAnalysis.validate_evidence_available(
                 projection,
                 presentation.disclosure.source_evidence_refs
               ) do
          Disclosure.verify_sources(presentation.disclosure, projection.evidence)
        end

      {:ok, _opening} ->
        {:error, {:presentation_precedes_scope, presentation.ref}}

      :error ->
        {:error, {:presentation_scope_not_open, presentation.ref, presentation.scope_ref}}
    end
  end

  defp validate_presentation_approval_evidence(projection, evidence) do
    case Presentation.approval_refs(evidence) do
      :not_approval ->
        :ok

      {:error, reason} ->
        {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}

      {:ok, presentation_ref, show_act_ref} ->
        with {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
             {:ok, show_act} <- Map.fetch(projection.acts, show_act_ref),
             {:ok, _basis_refs} <-
               Presentation.validate_response_with_basis(
                 evidence,
                 presentation,
                 show_act,
                 Map.values(projection.outcomes),
                 [
                   evidence
                   | projection
                     |> ErasureAnalysis.available_evidence()
                     |> Map.values()
                 ],
                 evidence.observed_at
               ) do
          :ok
        else
          :error ->
            {:error,
             {:presentation_approval_cause_not_found, evidence.ref, presentation_ref,
              show_act_ref}}

          {:error, reason} ->
            {:error, {:invalid_presentation_approval_evidence, evidence.ref, reason}}
        end
    end
  end

  defp validate_duty_cause_evidence(projection, evidence) do
    case EvidenceCause.extract(evidence, projection.constitution) do
      :not_cause ->
        :ok

      {:ok, cause} ->
        with true <- Map.has_key?(projection.principals, cause.accountable_ref),
             :ok <- optional_mandate_exists(projection, cause.mandate_ref),
             :ok <-
               ErasureAnalysis.validate_evidence_available(
                 projection,
                 cause.related_evidence_refs
               ),
             :ok <-
               Index.ensure_present(
                 projection.evidence,
                 cause.related_evidence_refs,
                 :outcome_evidence_not_found
               ) do
          :ok
        else
          false ->
            {:error, {:duty_evidence_accountable_not_found, evidence.ref, cause.accountable_ref}}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp optional_mandate_exists(_projection, nil), do: :ok

  defp optional_mandate_exists(projection, mandate_ref) do
    if Map.has_key?(projection.mandates, mandate_ref),
      do: :ok,
      else: {:error, {:duty_evidence_mandate_not_found, mandate_ref}}
  end

  defp validate_evidence_lineage(_projection, %Evidence{provenance: :observed, parent_refs: []}),
    do: :ok

  defp validate_evidence_lineage(projection, %Evidence{} = evidence)
       when evidence.provenance in [:derived, :generated] do
    with :ok <- ErasureAnalysis.validate_evidence_available(projection, evidence.parent_refs),
         {:ok, parents} <- View.evidence_set(projection, evidence.parent_refs),
         :ok <- parents_not_after_evidence(parents, evidence) do
      case Map.fetch(projection.declassifications_by_evidence, evidence.ref) do
        {:ok, declassification_ref} ->
          validate_declassified_lineage(projection, declassification_ref, evidence, parents)

        :error ->
          Derivation.validate(evidence, parents)
      end
    else
      {:error, {:evidence_not_found, ref}} ->
        {:error, {:evidence_parent_not_found, evidence.ref, ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_evidence_lineage(_projection, %Evidence{} = evidence),
    do: {:error, {:invalid_evidence_lineage, evidence.ref, evidence.provenance}}

  defp validate_declassified_lineage(projection, ref, evidence, parents) do
    case Map.fetch(projection.declassifications, ref) do
      {:ok, record} -> Declassification.validate_transition(record, evidence, parents)
      :error -> {:error, {:declassification_not_found, ref}}
    end
  end

  defp parents_not_after_evidence(parents, evidence) do
    case Enum.find(parents, &(&1.observed_at > evidence.observed_at)) do
      nil -> :ok
      parent -> {:error, {:evidence_parent_from_future, evidence.ref, parent.ref}}
    end
  end
end
