defmodule Spectre.Kernel.Commit do
  @moduledoc """
  Pure construction of the atomic Admission payload set.

  Despite its name, this module does not append to a ledger.  It converts a
  validated Decision and its optional Act into ordered `Spectre.Domain.Event`
  payloads for a sequencer to commit atomically.  A Decision is always first;
  only an admitted Decision may carry an Act.

  Executor-mediated Acts add `dispatch_ready` only when their frozen Row has
  `attempt: true`.  Ledger-internal governed consequences therefore finish at
  Admission and can never accidentally enter the Grant path.
  """

  alias Spectre.{
    Act,
    Decision,
    Declassification,
    Definition,
    Erasure,
    Governance,
    HostProfile,
    Mandate,
    Row,
    Surface
  }

  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Duty.Disposition
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Scope.Opening

  @type payload :: map()

  @doc "Builds the ordered event payloads for one Admission transaction."
  @spec payloads(Projection.t(), Decision.t(), Act.t() | nil) ::
          {:ok, [payload()]} | {:error, term()}
  def payloads(%Projection{} = projection, %Decision{} = decision, act)
      when is_nil(act) or is_struct(act, Act) do
    with {:ok, decision} <- Decision.new(decision),
         {:ok, act} <- normalize_act(act),
         {:ok, payloads} <- build_payloads(projection, decision, act) do
      {:ok, payloads}
    end
  end

  def payloads(_projection, _decision, _act), do: {:error, :invalid_admission_records}

  defp build_payloads(projection, %Decision{outcome: :admitted} = decision, %Act{} = act) do
    with :ok <- linked?(decision, act),
         :ok <- Governance.execution_boundary(act),
         {:ok, decision_event} <- Event.record(:decision, decision),
         {:ok, act_event} <- Event.record(:act, act),
         {:ok, meter_events} <- meter_events(act),
         {:ok, governance_events} <- governance_events(projection, act) do
      dispatch_events = if act.row.attempt, do: [Event.dispatch_ready(act)], else: []

      {:ok, [decision_event, act_event] ++ meter_events ++ governance_events ++ dispatch_events}
    end
  end

  defp build_payloads(_projection, %Decision{outcome: :admitted}, nil),
    do: {:error, :admitted_decision_missing_act}

  defp build_payloads(_projection, %Decision{outcome: outcome} = decision, nil)
       when outcome != :admitted do
    with {:ok, event} <- Event.record(:decision, decision), do: {:ok, [event]}
  end

  defp build_payloads(_projection, %Decision{outcome: outcome}, %Act{}) when outcome != :admitted,
    do: {:error, {:non_admitted_decision_has_act, outcome}}

  defp normalize_act(nil), do: {:ok, nil}
  defp normalize_act(%Act{} = act), do: Act.new(act)

  defp linked?(decision, act) do
    checks = [
      {:decision_ref, decision.ref, act.decision_ref},
      {:candidate_identity_key, decision.candidate_identity_key, act.candidate_identity_key},
      {:candidate_digest, decision.candidate_digest, act.candidate_digest},
      {:candidate_class, decision.candidate_class, act.class},
      {:consent, decision.consent, act.consent},
      {:submission_context_ref, decision.submission_context_ref, act.submission_context_ref},
      {:authenticated_principal_ref, decision.authenticated_principal_ref,
       act.authenticated_principal_ref},
      {:authentication_ref, decision.authentication_ref, act.authentication_ref},
      {:ingress_ref, decision.ingress_ref, act.ingress_ref},
      {:host_generation, decision.host_generation, act.host_generation},
      {:material_digest, decision.candidate_digest, act.material_digest},
      {:mandate_ref, decision.mandate_ref, act.mandate_ref},
      {:mandate_revision, decision.mandate_revision, act.mandate_revision},
      {:proposer_ref, decision.proposer_ref, act.proposer_ref},
      {:executor_ref, decision.executor_ref, act.executor_ref},
      {:authorizer_ref, decision.authorizer_ref, act.authorizer_ref},
      {:accountable_ref, decision.accountable_ref, act.accountable_ref},
      {:scope_ref, decision.scope_ref, act.scope_ref},
      {:recognition_refs, decision.recognition_refs, act.recognition_refs},
      {:recognition_evidence_refs, decision.recognition_evidence_refs,
       act.recognition_evidence_refs},
      {:reservations, decision.reservations, act.reservations},
      {:host_profile_ref, decision.host_profile_ref, act.host_profile_ref},
      {:surface_revision, decision.surface_revision, act.surface_revision}
    ]

    case Enum.find(checks, fn {_field, expected, actual} -> expected != actual end) do
      nil -> :ok
      {field, expected, actual} -> {:error, {:decision_act_mismatch, field, expected, actual}}
    end
  end

  defp meter_events(%Act{reservations: reservations}) when reservations in [%{}, []],
    do: {:ok, []}

  defp meter_events(%Act{} = act) do
    with {:ok, event} <- Event.meter(:reserve, act), do: {:ok, [event]}
  end

  defp governance_events(
         %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act
       )
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:delegate, :govern]),
         true <- act.reservations in [%{}, []],
         {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref),
         false <- Mandate.root?(mandate),
         {:ok, event} <- Event.record(:mandate, mandate) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_delegated_mandate_issue}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "mandate.devolve",
           consequence: %{
             "mandate_devolve" =>
               %{"child_mandate_ref" => child_mandate_ref, "amounts" => amounts} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- exact_row?(act.row, [:delegate, :govern]),
         true <- act.reservations in [%{}, []],
         {:ok, event} <- Event.meter_devolved(act, child_mandate_ref, amounts) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_meter_devolution}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "mandate.revoke",
           consequence: %{
             "mandate_revoke" => %{"mandate_ref" => mandate_ref} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 1 do
    with true <- exact_row?(act.row, [:govern]),
         true <- act.reservations in [%{}, []],
         event when is_map(event) <-
           Event.mandate_revoked(act.ref, mandate_ref, act.committed_at) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_mandate_revocation}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" =>
               %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- exact_row?(act.row, [:govern]),
         true <- act.reservations in [%{}, []],
         true <- ledger_internal?(act),
         {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref),
         {:ok, event} <- Event.mandate_restricted(act, predecessor_ref, successor) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_mandate_restriction}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "surface.revise",
           consequence: %{
             "surface_revision" =>
               %{"previous_ref" => previous_ref, "surface" => canonical} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- exact_row?(act.row, [:govern]),
         {:ok, surface} <- Surface.from_canonical(canonical),
         true <- canonical == Surface.canonical(surface),
         {:ok, event} <- Event.surface_revised(act, previous_ref, surface) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_surface_revision}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "host_profile.revise",
           consequence: %{
             "host_profile_revision" =>
               %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- exact_row?(act.row, [:govern]),
         {:ok, profile} <- HostProfile.from_canonical(canonical),
         true <- canonical == HostProfile.canonical(profile),
         {:ok, event} <- Event.host_profile_revised(act, previous_ref, profile) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_host_profile_revision}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "definition.revise",
           consequence: %{
             "definition_revision" =>
               %{"previous_ref" => previous_ref, "definition" => canonical} = command
           }
         } = act
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- exact_row?(act.row, [:govern]),
         true <- act.reservations in [%{}, []],
         {:ok, definition} <- Definition.from_canonical(canonical),
         true <- canonical == Definition.canonical(definition),
         true <- previous_ref == definition.previous_ref,
         {:ok, event} <- Event.definition_revised(act, previous_ref, definition) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_definition_revision}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(
         %Act{
           class: "data.declassify",
           consequence: %{"evidence_declassification" => draft}
         } = act
       )
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:write, :govern]),
         true <- act.reservations in [%{}, []],
         true <- ledger_internal?(act),
         {:ok, decoded} <- Declassification.decode_draft(draft),
         true <- decoded.canonical == draft,
         {:ok, required_targets} <-
           Declassification.required_target_refs(decoded.evidence, decoded.removed_labels),
         true <- Enum.all?(required_targets, &(&1 in act.target_refs)),
         {:ok, declassification} <-
           Declassification.from_draft(decoded.canonical, act.ref, act.committed_at),
         {:ok, declassification_event} <- Event.record(:declassification, declassification),
         {:ok, evidence_event} <- Event.record(:evidence, decoded.evidence) do
      {:ok, [declassification_event, evidence_event]}
    else
      false -> {:error, :invalid_evidence_declassification}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(%Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act)
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:write, :govern]),
         true <- act.reservations in [%{}, []],
         true <- ledger_internal?(act),
         {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at),
         true <- opening.parent_ref == act.scope_ref,
         true <- opening.ref in act.target_refs,
         {:ok, event} <- Event.scope_opened(opening) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_governed_scope_opening}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(%Act{row: %{delegate: true}}),
    do: {:error, :invalid_delegation_consequence}

  defp governance_events(%Act{row: %{govern: true}}),
    do: {:error, :unknown_governance_consequence}

  defp governance_events(%Act{}), do: {:ok, []}

  defp governance_events(
         %Projection{} = projection,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref}}
         } = act
       ) do
    with {:ok, governance_events} <- governance_events(act),
         {:ok, cancellation_events} <-
           authority_cancellation_events(
             projection,
             act,
             mandate_ref,
             :mandate_revoked
           ) do
      {:ok, governance_events ++ cancellation_events}
    end
  end

  defp governance_events(
         %Projection{} = projection,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" => %{"predecessor_ref" => predecessor_ref}
           }
         } = act
       ) do
    with {:ok, governance_events} <- governance_events(act),
         {:ok, cancellation_events} <-
           authority_cancellation_events(
             projection,
             act,
             predecessor_ref,
             :mandate_restricted
           ) do
      {:ok, governance_events ++ cancellation_events}
    end
  end

  defp governance_events(
         %Projection{} = projection,
         %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act
       )
       when map_size(act.consequence) == 1 do
    with true <- exact_row?(act.row, [:attempt, :write, :govern]),
         {:ok, canonical_draft} <- Erasure.request_draft(draft),
         true <- canonical_draft == draft,
         :ok <- ErasureAnalysis.requestable?(projection, canonical_draft["target_ref"]),
         :ok <- ErasureAnalysis.validate_request(projection, canonical_draft),
         {:ok, erasure} <- Erasure.from_request_draft(canonical_draft, act.ref),
         true <- erasure.scope_ref == act.scope_ref,
         true <- erasure.target_ref in act.target_refs,
         true <- erasure.requested_at <= act.committed_at,
         {:ok, event} <- Event.record(:erasure, erasure) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_erasure_request}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(%Projection{} = projection, %Act{class: "duty.dispose"} = act) do
    with true <- exact_row?(act.row, [:govern]),
         true <- act.reservations in [%{}, []],
         {:ok, disposition} <- Disposition.from_consequence(act.consequence),
         {:ok, duty} <- fetch_open_duty(projection, disposition),
         {:ok, meter_events} <- duty_meter_events(projection, duty, disposition, act),
         disposed when is_map(disposed) <-
           Event.duty_disposed(act.ref, disposition.cause_key, act.ref) do
      {:ok, meter_events ++ [disposed]}
    else
      false -> {:error, :invalid_duty_disposition}
      {:error, _reason} = error -> error
    end
  end

  defp governance_events(%Projection{}, %Act{} = act), do: governance_events(act)

  defp authority_cancellation_events(projection, cause_act, mandate_ref, reason) do
    cascade? = reason == :mandate_restricted or revocation_cascades?(projection, mandate_ref)

    projection.dispatch_ready
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, events} ->
      with {:ok, pending_act} <- Map.fetch(projection.acts, act_ref),
           {:ok, affected?} <-
             mandate_affected?(
               projection,
               pending_act.mandate_ref,
               mandate_ref,
               cascade?
             ),
           {:ok, cancellation_events} <-
             maybe_cancellation_events(pending_act, cause_act, reason, affected?) do
        {:cont, {:ok, events ++ cancellation_events}}
      else
        :error -> {:halt, {:error, {:dispatch_act_not_found, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp revocation_cascades?(projection, mandate_ref) do
    case Map.fetch(projection.mandates, mandate_ref) do
      {:ok, mandate} -> Map.get(mandate.revocation, "mode") == :cascade
      :error -> false
    end
  end

  defp mandate_affected?(_projection, mandate_ref, mandate_ref, _cascade?), do: {:ok, true}
  defp mandate_affected?(_projection, _mandate_ref, _target_ref, false), do: {:ok, false}

  defp mandate_affected?(projection, mandate_ref, target_ref, true) do
    descendant_of?(projection, mandate_ref, target_ref, MapSet.new())
  end

  defp descendant_of?(_projection, target_ref, target_ref, _visited), do: {:ok, true}

  defp descendant_of?(projection, mandate_ref, target_ref, visited) do
    cond do
      MapSet.member?(visited, mandate_ref) ->
        {:error, {:mandate_ancestry_cycle, mandate_ref}}

      true ->
        case Map.fetch(projection.mandates, mandate_ref) do
          {:ok, %{parent_ref: nil}} ->
            {:ok, false}

          {:ok, %{parent_ref: parent_ref}} ->
            descendant_of?(
              projection,
              parent_ref,
              target_ref,
              MapSet.put(visited, mandate_ref)
            )

          :error ->
            {:error, {:mandate_not_found, mandate_ref}}
        end
    end
  end

  defp maybe_cancellation_events(_pending_act, _cause_act, _reason, false), do: {:ok, []}

  defp maybe_cancellation_events(pending_act, cause_act, reason, true) do
    with {:ok, cancelled} <- Event.dispatch_cancelled(pending_act, cause_act, reason),
         {:ok, release_events} <- cancellation_meter_events(pending_act) do
      {:ok, [cancelled | release_events]}
    end
  end

  defp cancellation_meter_events(%Act{reservations: reservations})
       when reservations in [%{}, []],
       do: {:ok, []}

  defp cancellation_meter_events(%Act{} = act) do
    with {:ok, event} <- Event.meter(:release, act), do: {:ok, [event]}
  end

  defp fetch_open_duty(projection, disposition) do
    case Map.fetch(projection.duties, disposition.cause_key) do
      {:ok, %{status: :open, ref: ref} = duty} when ref == disposition.duty_ref -> {:ok, duty}
      {:ok, %{status: :disposed}} -> {:error, {:duty_already_disposed, disposition.duty_ref}}
      {:ok, _mismatch} -> {:error, {:duty_disposition_binding_mismatch, disposition.duty_ref}}
      :error -> {:error, {:duty_not_found, disposition.cause_key}}
    end
  end

  defp duty_meter_events(_projection, %{act_ref: nil}, disposition, _disposition_act) do
    if disposition.meter_resolution == :none,
      do: {:ok, []},
      else: {:error, {:duty_has_no_meter_reservation, disposition.duty_ref}}
  end

  defp duty_meter_events(projection, duty, disposition, disposition_act) do
    with {:ok, cause_act} <- Map.fetch(projection.acts, duty.act_ref) do
      derive_duty_meter_events(projection, duty, cause_act, disposition, disposition_act)
    else
      :error -> {:error, {:duty_cause_act_not_found, duty.act_ref}}
    end
  end

  defp derive_duty_meter_events(
         projection,
         _duty,
         %{reservations: reservations} = cause_act,
         disposition,
         _disposition_act
       )
       when reservations in [%{}, []] do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, disposition.duty_ref}}

      Map.has_key?(projection.reservation_states, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      true ->
        {:ok, []}
    end
  end

  defp derive_duty_meter_events(projection, duty, cause_act, disposition, disposition_act) do
    status = Map.get(projection.reservation_states, cause_act.ref)
    recontainment = Map.get(projection.meter_recontainments, cause_act.ref)

    case {status, disposition.meter_resolution, recontainment} do
      {:suspended, :none, %{status: :open, cause_key: cause_key}}
      when cause_key != duty.cause_key ->
        {:ok, []}

      {status, :none, nil} when status in [:settled, :released] ->
        {:ok, []}

      {:suspended, operation, %{status: :open, cause_key: cause_key, recontained: amounts}}
      when operation in [:settle, :release] and cause_key == duty.cause_key ->
        build_duty_meter_event(cause_act, disposition_act, duty, operation, amounts)

      {:suspended, operation, nil} when operation in [:settle, :release] ->
        with {:ok, binding} <- Map.fetch(projection.reservation_bindings, cause_act.ref) do
          build_duty_meter_event(cause_act, disposition_act, duty, operation, binding.amounts)
        else
          :error -> {:error, {:reservation_binding_not_found, cause_act.ref}}
        end

      {:suspended, :none, _recontainment} ->
        {:error, {:duty_meter_resolution_required, cause_act.ref}}

      {:reserved, _resolution, _recontainment} ->
        {:error, {:duty_meter_not_contained, cause_act.ref}}

      {nil, _resolution, _recontainment} ->
        {:error, {:reservation_not_found, cause_act.ref}}

      {_status, _resolution, %{status: :open, cause_key: cause_key}}
      when cause_key != duty.cause_key ->
        {:error, {:meter_recontainment_requires_causal_duty, cause_act.ref, cause_key}}

      {status, resolution, _recontainment} ->
        {:error, {:invalid_duty_meter_resolution, cause_act.ref, status, resolution}}
    end
  end

  defp build_duty_meter_event(cause_act, disposition_act, duty, operation, amounts) do
    with {:ok, event} <-
           Event.meter_duty_resolved(cause_act, disposition_act, duty, operation, amounts) do
      {:ok, [event]}
    end
  end

  defp exact_row?(%Row{} = row, dimensions), do: Row.dimensions(row) == dimensions

  defp ledger_internal?(act) do
    Governance.ledger_internal?(act)
  end
end
