defmodule Spectre.GovernedAct.Transition.Admission do
  @moduledoc """
  Replay transitions for Decision and Act Admission records.

  The live kernel decides whether a Candidate is admitted. Replay does not trust
  that historical answer: it reconstructs the frozen Candidate, rechecks the
  Decision/Act contract, authority, recognition, presentation, disclosure and
  Meter plan, then stores the immutable records in disposable state.

  `rebuild_candidate/2` and `authorize_candidate/5` are also used when an
  Attempt is replayed, because authority must be valid again at execution time.
  """

  alias Spectre.{
    Act,
    Candidate,
    Decision,
    Disclosure,
    Evidence,
    Governance,
    Presentation,
    SubmissionContext,
    Surface
  }

  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.{Index, MeterState, State, View}
  alias Spectre.Kernel.{Authority, Meter, Recognition}
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.Mandate.Revocation

  def apply(
        %State{} = projection,
        %Event{type: "decision_recorded", identity: identity, data: data},
        entry_revision
      ) do
    with {:ok, decision} <- Record.decode(Spectre.Decision, data),
         :ok <- Record.match_identity(identity, Record.ref(decision)),
         :ok <- Index.unique(projection.decisions, identity, :decision),
         :ok <- validate_decision_revision(projection, decision, entry_revision),
         :ok <- validate_decision_context(projection, decision),
         :ok <- validate_decision_evidence_basis(projection, decision),
         :ok <- validate_decision_authority(projection, decision) do
      candidate_key = Map.get(decision, :candidate_identity_key)
      candidate_digest = Map.get(decision, :candidate_digest)

      case Map.fetch(projection.candidate_identities, candidate_key) do
        :error ->
          {:ok,
           %{
             projection
             | decisions: Map.put(projection.decisions, identity, decision),
               candidate_identities:
                 Map.put(projection.candidate_identities, candidate_key, %{
                   digest: candidate_digest,
                   decision_ref: identity
                 })
           }}

        {:ok, %{digest: ^candidate_digest}} ->
          {:error, {:duplicate_candidate_decision, candidate_key}}

        {:ok, _different} ->
          {:error, {:candidate_identity_conflict, candidate_key}}
      end
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "act_committed", identity: identity, data: data},
        _revision
      ) do
    with {:ok, act} <- Record.decode(Spectre.Act, data),
         :ok <- Record.match_identity(identity, Record.ref(act)),
         :ok <- Index.unique(projection.acts, identity, :act),
         :ok <- Spectre.Governance.execution_boundary(act),
         {:ok, decision} <- Index.fetch_decision(projection, act.decision_ref),
         :ok <- one_act_per_decision(projection, decision.ref),
         :ok <- match_act_to_decision(projection, act, decision),
         {:ok, candidate} <- rebuild_candidate(projection, act),
         :ok <- validate_candidate_at_act(projection, candidate, act, decision) do
      {:ok,
       %{
         projection
         | acts: Map.put(projection.acts, identity, act),
           acts_by_decision: Map.put(projection.acts_by_decision, act.decision_ref, identity)
       }}
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_admission_event, type}}

  defp validate_decision_context(projection, decision) do
    with {:ok, context} <- decision_submission_context(decision),
         {:ok, _opening} <- View.scope_context(projection, context) do
      cond do
        decision.domain_ref != projection.domain_ref ->
          {:error, {:decision_domain_mismatch, decision.ref, decision.domain_ref}}

        not Map.has_key?(projection.principals, decision.authenticated_principal_ref) ->
          {:error, {:authenticated_principal_not_found, decision.authenticated_principal_ref}}

        is_nil(projection.host_profile) or
            decision.host_profile_ref != projection.host_profile.ref ->
          {:error, {:decision_host_profile_mismatch, decision.ref}}

        is_nil(projection.surface) or decision.surface_revision != projection.surface.revision ->
          {:error, {:decision_surface_revision_mismatch, decision.ref}}

        decision.outcome == :admitted and
            decision.proposer_ref != decision.authenticated_principal_ref ->
          {:error, {:admitted_decision_principal_mismatch, decision.ref}}

        true ->
          :ok
      end
    end
  end

  defp decision_submission_context(decision) do
    SubmissionContext.new(%{
      ref: decision.submission_context_ref,
      domain_ref: decision.domain_ref,
      scope_ref: decision.scope_ref,
      authenticated_principal_ref: decision.authenticated_principal_ref,
      authentication_ref: decision.authentication_ref,
      ingress_ref: decision.ingress_ref,
      channel_ref: decision.channel_ref,
      session_ref: decision.session_ref,
      host_generation: decision.host_generation
    })
    |> case do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, {:invalid_decision_submission_context, decision.ref, reason}}
    end
  end

  defp validate_decision_revision(projection, decision, entry_revision) do
    expected_entry_revision = projection.revision + 1

    cond do
      decision.authority_revision != projection.revision ->
        {:error,
         {:decision_authority_revision_mismatch, decision.ref, projection.revision,
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

  defp validate_decision_evidence_basis(projection, decision) do
    with :ok <-
           ErasureAnalysis.validate_evidence_available(
             projection,
             decision.recognition_evidence_refs
           ),
         {:ok, evidence} <- View.evidence_set(projection, decision.recognition_evidence_refs) do
      case Enum.find(evidence, &(&1.observed_at > decision.decided_at)) do
        nil -> :ok
        future -> {:error, {:decision_evidence_from_future, decision.ref, future.ref}}
      end
    end
  end

  defp validate_decision_authority(_projection, %{mandate_ref: nil, outcome: outcome})
       when outcome != :admitted,
       do: :ok

  defp validate_decision_authority(projection, decision) do
    case Map.fetch(projection.mandates, decision.mandate_ref) do
      {:ok, mandate} -> validate_decision_mandate(projection, decision, mandate)
      :error -> {:error, {:decision_mandate_not_found, decision.mandate_ref}}
    end
  end

  defp validate_decision_mandate(projection, decision, mandate) do
    cond do
      decision.mandate_revision != mandate.revision ->
        {:error, {:decision_mandate_revision_mismatch, decision.ref}}

      decision.outcome != :admitted ->
        :ok

      decision.reasons != [] ->
        {:error, {:admitted_decision_has_reasons, decision.ref}}

      retained_revocation_decision?(decision, mandate) ->
        validate_retained_revocation_decision(projection, decision, mandate)

      decision.authenticated_principal_ref != mandate.holder_ref ->
        {:error, {:decision_mandate_holder_mismatch, decision.ref}}

      decision.authorizer_ref != mandate.grantor_ref ->
        {:error, {:decision_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref not in mandate.executor_refs ->
        {:error, {:decision_executor_outside_mandate, decision.ref}}

      decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
        {:error, {:decision_mandate_not_current, decision.ref}}

      effective_revocation?(Map.get(projection.revocations, mandate.ref), decision.decided_at) ->
        {:error, {:decision_mandate_revoked, decision.ref}}

      true ->
        :ok
    end
  end

  defp retained_revocation_decision?(decision, mandate) do
    decision.candidate_class == "mandate.revoke" and
      decision.mandate_ref == mandate.ref and
      Map.get(mandate.revocation, "mode") in [:retained_controller, "retained_controller"]
  end

  defp validate_retained_revocation_decision(projection, decision, mandate) do
    controllers = Map.get(mandate.revocation, "controller_refs", [])

    cond do
      decision.authenticated_principal_ref not in controllers ->
        {:error, {:decision_revocation_controller_mismatch, decision.ref}}

      decision.proposer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_proposer_mismatch, decision.ref}}

      decision.authorizer_ref != decision.authenticated_principal_ref ->
        {:error, {:decision_revocation_authorizer_mismatch, decision.ref}}

      decision.accountable_ref != mandate.accountable_ref ->
        {:error, {:decision_accountable_mismatch, decision.ref}}

      decision.executor_ref != Governance.kernel_executor_ref() ->
        {:error, {:decision_revocation_executor_mismatch, decision.ref}}

      decision.recognition_refs != [] or decision.recognition_evidence_refs != [] or
          Decision.reservations?(decision) ->
        {:error, {:decision_revocation_not_narrow, decision.ref}}

      decision.decided_at < mandate.not_before or decision.decided_at >= mandate.expires_at ->
        {:error, {:decision_mandate_not_current, decision.ref}}

      effective_revocation?(Map.get(projection.revocations, mandate.ref), decision.decided_at) ->
        {:error, {:decision_mandate_revoked, decision.ref}}

      true ->
        :ok
    end
  end

  defp match_act_to_decision(projection, act, decision) do
    fields = [
      :candidate_identity_key,
      :candidate_digest,
      :submission_context_ref,
      :authenticated_principal_ref,
      :authentication_ref,
      :ingress_ref,
      :host_generation,
      :mandate_ref,
      :mandate_revision,
      :recognition_refs,
      :recognition_evidence_refs,
      :reservations,
      :proposer_ref,
      :executor_ref,
      :authorizer_ref,
      :accountable_ref,
      :scope_ref,
      :consent,
      :host_profile_ref,
      :surface_revision
    ]

    mismatch = Enum.find(fields, &(Map.fetch!(decision, &1) != Map.fetch!(act, &1)))
    identity = Map.get(projection.candidate_identities, act.candidate_identity_key)
    mandate = Map.get(projection.mandates, act.mandate_ref)

    cond do
      decision.outcome != :admitted ->
        {:error, {:act_for_non_admitted_decision, decision.ref}}

      projection.revision != decision.authority_revision + 1 ->
        {:error, {:act_not_adjacent_to_decision, act.ref, decision.ref}}

      mismatch ->
        {:error, {:decision_act_mismatch, mismatch, decision.ref, act.ref}}

      decision.candidate_class != act.class ->
        {:error, {:decision_act_class_mismatch, decision.ref, act.ref}}

      act.material_digest != decision.candidate_digest ->
        {:error, {:act_material_digest_mismatch, act.ref}}

      not decision_act_contract_authorized?(act, decision, mandate) ->
        {:error, {:act_executor_contract_outside_mandate, act.ref}}

      act.committed_at != decision.decided_at ->
        {:error, {:act_commit_time_mismatch, act.ref}}

      identity != %{digest: act.candidate_digest, decision_ref: decision.ref} ->
        {:error, {:act_candidate_identity_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp decision_act_contract_authorized?(_act, _decision, nil), do: false

  defp decision_act_contract_authorized?(act, decision, mandate) do
    act.executor_contract_ref in mandate.executor_contract_refs or
      (retained_revocation_decision?(decision, mandate) and
         act.executor_contract_ref == Governance.kernel_contract_ref())
  end

  defp one_act_per_decision(projection, decision_ref) do
    case Map.fetch(projection.acts_by_decision, decision_ref) do
      :error -> :ok
      {:ok, existing_ref} -> {:error, {:decision_already_has_act, decision_ref, existing_ref}}
    end
  end

  @doc false
  @spec rebuild_candidate(State.t(), Act.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def rebuild_candidate(_projection, act) do
    with {:ok, reservations} <- Amounts.normalize(act.reservations) do
      Candidate.new(%{
        identity_key: act.candidate_identity_key,
        material_digest: act.material_digest,
        class: act.class,
        consequence: act.consequence,
        row: act.row,
        requested_mandate_ref: act.requested_mandate_ref,
        proposer_ref: act.proposer_ref,
        executor_ref: act.executor_ref,
        accountable_ref: act.accountable_ref,
        scope_ref: act.scope_ref,
        subject_refs: act.subject_refs,
        target_refs: act.target_refs,
        purpose_ref: act.purpose_ref,
        purpose_params: act.purpose_params,
        consent: act.consent,
        evidence_refs: act.evidence_refs,
        disclosure: act.disclosure,
        presentation_ref: act.presentation_ref,
        meter_requests: reservations,
        executor_contract_ref: act.executor_contract_ref,
        observation_window_ms: act.observation_window_ms
      })
      |> case do
        {:ok, candidate} -> {:ok, candidate}
        {:error, _reason} -> {:error, :act_candidate_material_mismatch}
      end
    end
  end

  defp validate_candidate_at_act(projection, candidate, act, decision) do
    with {:ok, mandate} <- Index.fetch_mandate(projection, act.mandate_ref),
         :ok <- validate_surface_binding(projection, candidate, act),
         :ok <-
           ErasureAnalysis.validate_evidence_available(projection, candidate.evidence_refs),
         :ok <- validate_candidate_disclosure(projection, candidate),
         {:ok, effective_mandate} <-
           authorize_candidate(projection, candidate, act, mandate),
         {:ok, mandate_basis_refs} <-
           validate_candidate_recognition(
             projection,
             candidate,
             decision,
             effective_mandate
           ),
         {:ok, presentation_basis_refs} <-
           validate_presentation_binding(projection, candidate, act),
         :ok <-
           validate_exact_recognition_basis(
             decision,
             mandate_basis_refs ++ presentation_basis_refs
           ) do
      validate_reservation_contract(projection, candidate, act, decision, effective_mandate)
    end
  end

  defp validate_candidate_disclosure(_projection, %Candidate{disclosure: nil}), do: :ok

  defp validate_candidate_disclosure(projection, %Candidate{disclosure: disclosure}),
    do: Disclosure.verify_sources(disclosure, projection.evidence)

  defp validate_surface_binding(%{surface: %Surface{} = surface}, candidate, act) do
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

  defp validate_surface_binding(_projection, _candidate, act),
    do: {:error, {:act_surface_not_found, act.ref}}

  @doc false
  @spec authorize_candidate(
          State.t(),
          Candidate.t(),
          Act.t(),
          Spectre.Mandate.t(),
          integer() | nil
        ) ::
          {:ok, Spectre.Kernel.Authority.Effective.t()} | {:error, term()}
  def authorize_candidate(projection, candidate, act, mandate, time \\ nil) do
    context = %{
      domain_ref: projection.domain_ref,
      scope_ref: act.scope_ref,
      authenticated_principal_ref: act.authenticated_principal_ref,
      authentication_ref: act.authentication_ref,
      ingress_ref: act.ingress_ref,
      host_generation: act.host_generation
    }

    view = View.authority(projection)

    case Authority.authorize(candidate, context, mandate, view, time || act.committed_at) do
      {:ok, effective_mandate} -> {:ok, effective_mandate}
      {:error, reason} -> {:error, {:act_without_current_authority, act.ref, reason}}
    end
  end

  defp validate_candidate_recognition(projection, candidate, decision, mandate) do
    expected_refs = mandate.conditions |> Enum.map(&Record.ref/1) |> Enum.sort()

    available_evidence =
      projection |> ErasureAnalysis.available_evidence() |> Map.values()

    {recognition, basis_refs} =
      Recognition.check_with_basis(mandate.conditions, available_evidence, decision.decided_at)

    with true <- decision.recognition_refs == expected_refs,
         {:ok, _declared_evidence} <- View.evidence_set(projection, candidate.evidence_refs),
         :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs),
         :satisfied <- recognition do
      {:ok, basis_refs}
    else
      false -> {:error, {:decision_recognition_refs_mismatch, decision.ref}}
      {:error, _reason} = error -> error
      result -> {:error, {:act_recognition_not_satisfied, candidate.ref, result}}
    end
  end

  defp validate_presentation_binding(
         projection,
         %Candidate{class: "presentation.show"} = candidate,
         act
       ) do
    with {:ok, presentation_ref} <- Presentation.show_presentation_ref(candidate.consequence),
         {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
         :ok <- Presentation.validate_show(candidate, presentation),
         :ok <- Presentation.validate_show(act, presentation),
         true <- presentation.prepared_at <= act.committed_at do
      {:ok, []}
    else
      :error -> {:error, {:act_presentation_not_found, act.ref}}
      false -> {:error, {:act_presentation_show_precedes_preparation, act.ref}}
      {:error, reason} -> {:error, {:invalid_presentation_show_act, act.ref, reason}}
    end
  end

  defp validate_presentation_binding(_projection, %Candidate{presentation_ref: nil}, %{
         presentation_ref: nil
       }),
       do: {:ok, []}

  defp validate_presentation_binding(projection, candidate, act) do
    case Map.fetch(projection.presentations, act.presentation_ref) do
      {:ok, presentation} ->
        with :ok <- Presentation.validate_candidate(candidate, presentation),
             true <- presentation.prepared_at <= act.committed_at,
             {:ok, approval_refs, basis_refs} <-
               validate_presentation_approval(
                 projection,
                 presentation,
                 act.committed_at,
                 act.ref
               ),
             true <-
               presentation.candidate_binding_ref ==
                 Candidate.presentation_binding_ref(candidate, approval_refs),
             :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs) do
          {:ok, basis_refs}
        else
          false -> {:error, {:act_presentation_binding_mismatch, act.ref}}
          {:error, _reason} = error -> error
        end

      :error ->
        {:error, {:act_presentation_not_found, act.ref, act.presentation_ref}}
    end
  end

  defp validate_presentation_approval(projection, presentation, time, act_ref) do
    evidence = projection |> ErasureAnalysis.available_evidence() |> Map.values()
    matching = Enum.filter(evidence, &approval_for_presentation?(&1, presentation.ref))

    current =
      Enum.reduce(matching, [], fn approval, valid ->
        case presentation_approval_basis(
               approval,
               presentation,
               projection,
               evidence,
               time
             ) do
          {:ok, basis_refs} -> [{approval, basis_refs} | valid]
          :invalid -> valid
        end
      end)

    cond do
      Enum.any?(current, fn {approval, _basis} -> approval.stance == :contradicts end) ->
        {:error, {:act_presentation_approval_contradicted, act_ref}}

      Enum.any?(current, fn {approval, _basis} -> approval.stance == :supports end) ->
        approval_refs =
          current |> Enum.map(fn {approval, _basis} -> approval.ref end) |> Enum.sort()

        basis_refs =
          current
          |> Enum.flat_map(fn {_approval, refs} -> refs end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, approval_refs, basis_refs}

      matching == [] ->
        {:error, {:act_presentation_approval_missing, act_ref}}

      true ->
        {:error, {:act_presentation_approval_not_current_or_final, act_ref}}
    end
  end

  defp required_evidence_declared(required_refs, declared_refs) do
    case required_refs -- declared_refs do
      [] -> :ok
      missing -> {:error, {:recognition_basis_not_declared, missing}}
    end
  end

  defp approval_for_presentation?(%Evidence{} = evidence, presentation_ref) do
    case Presentation.approval_refs(evidence) do
      {:ok, ^presentation_ref, _show_act_ref} -> true
      _other -> false
    end
  end

  defp approval_for_presentation?(_evidence, _presentation_ref), do: false

  defp presentation_approval_basis(approval, presentation, projection, evidence, time) do
    with {:ok, _presentation_ref, show_act_ref} <- Presentation.approval_refs(approval),
         {:ok, show_act} <- Map.fetch(projection.acts, show_act_ref),
         {:ok, basis_refs} <-
           Presentation.validate_response_with_basis(
             approval,
             presentation,
             show_act,
             Map.values(projection.outcomes),
             evidence,
             time
           ) do
      {:ok, basis_refs}
    else
      _invalid -> :invalid
    end
  end

  defp validate_exact_recognition_basis(decision, basis_refs) do
    expected = basis_refs |> Enum.uniq() |> Enum.sort()

    if decision.recognition_evidence_refs == expected,
      do: :ok,
      else: {:error, {:decision_recognition_evidence_refs_mismatch, decision.ref}}
  end

  defp validate_reservation_contract(projection, candidate, act, decision, mandate) do
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
             {:ok, accounts} <- MeterState.accounts(projection, mandate.ref),
             {:ok, planned} <- Meter.plan_reservations(requests, accounts),
             true <- reservation_list_to_map(planned) == requests do
          :ok
        else
          false -> {:error, {:act_reservation_plan_mismatch, act.ref}}
          {:error, reason} -> {:error, {:act_invalid_reservation_plan, act.ref, reason}}
        end
    end
  end

  defp reservation_list_to_map(reservations) do
    Map.new(reservations, fn reservation ->
      {Map.fetch!(reservation, :meter_ref), Map.fetch!(reservation, :quantity)}
    end)
  end

  defp effective_revocation?(nil, _time), do: false

  defp effective_revocation?(%Revocation{effective_at: effective_at}, time)
       when is_integer(time),
       do: time >= effective_at

  defp effective_revocation?(_invalid, _time), do: true
end
