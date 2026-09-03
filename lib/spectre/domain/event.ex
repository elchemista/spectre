defmodule Spectre.Domain.Event do
  @moduledoc false

  alias Spectre.Domain.Projection
  alias Spectre.Governance

  @record_events %{
    genesis: {"genesis_recorded", Spectre.Genesis},
    principal: {"principal_recorded", Spectre.Principal},
    host_profile: {"host_profile_recorded", Spectre.HostProfile},
    surface: {"surface_recorded", Spectre.Surface},
    mandate: {"mandate_issued", Spectre.Mandate},
    declassification: {"declassification_recorded", Spectre.Declassification},
    evidence: {"evidence_recorded", Spectre.Evidence},
    presentation: {"presentation_recorded", Spectre.Presentation},
    decision: {"decision_recorded", Spectre.Decision},
    act: {"act_committed", Spectre.Act},
    attempt: {"attempt_started", Spectre.Attempt},
    outcome: {"outcome_recorded", Spectre.Outcome},
    duty: {"duty_opened", Spectre.Duty},
    scope: {"scope_opened", Spectre.Scope.Opening},
    erasure: {"erasure_requested", Spectre.Erasure}
  }

  @spec record(atom(), struct()) :: {:ok, map()} | {:error, term()}
  def record(kind, record) do
    with {:ok, {type, module}} <- fetch_record_event(kind),
         true <- is_struct(record, module),
         {:ok, record} <- module.new(record),
         ref when is_binary(ref) and ref != "" <- Map.get(record, :ref),
         data when is_map(data) <- module.canonical(record) do
      {:ok, Projection.event(type, ref, data)}
    else
      false -> {:error, {:invalid_domain_record, kind}}
      nil -> {:error, {:invalid_domain_record_ref, kind}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_domain_record, kind}}
    end
  end

  @spec meter(:reserve | :settle | :release | :suspend, Spectre.Act.t()) ::
          {:ok, map()} | {:error, term()}
  def meter(operation, %Spectre.Act{} = act)
      when operation in [:reserve, :settle, :release, :suspend] do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, amounts} <- reservation_amounts(act.reservations) do
      type = meter_event_type(operation)
      identity = type <> ":" <> act.ref

      {:ok,
       Projection.event(type, identity, %{
         "act_ref" => act.ref,
         "mandate_ref" => act.mandate_ref,
         "amounts" => amounts
       })}
    end
  end

  def meter(_operation, _act), do: {:error, :invalid_meter_event}

  @spec meter_recontained(Spectre.Act.t(), Spectre.Outcome.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def meter_recontained(
        %Spectre.Act{} = act,
        %Spectre.Outcome{status: status, contradicts_outcome_ref: corrected_ref} = outcome,
        recontained,
        deficits
      )
      when status in [:succeeded, :failed] and is_binary(corrected_ref) and
             corrected_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, outcome} <- Spectre.Outcome.new(outcome),
         true <- outcome.act_ref == act.ref,
         {:ok, amounts} <- reservation_amounts(act.reservations),
         {:ok, recontained} <- partial_amounts(recontained),
         {:ok, deficits} <- partial_amounts(deficits),
         :ok <- exact_partition(amounts, recontained, deficits) do
      {:ok,
       Projection.event("meter_recontained", "meter_recontained:" <> act.ref, %{
         "act_ref" => act.ref,
         "mandate_ref" => act.mandate_ref,
         "outcome_ref" => outcome.ref,
         "amounts" => amounts,
         "recontained" => recontained,
         "deficits" => deficits
       })}
    else
      false -> {:error, :meter_recontainment_cause_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def meter_recontained(_act, _outcome, _recontained, _deficits),
    do: {:error, :invalid_meter_recontainment_event}

  @spec meter_duty_resolved(
          Spectre.Act.t(),
          Spectre.Act.t(),
          Spectre.Duty.t(),
          :settle | :release,
          map()
        ) :: {:ok, map()} | {:error, term()}
  def meter_duty_resolved(
        %Spectre.Act{} = cause_act,
        %Spectre.Act{} = disposition_act,
        %Spectre.Duty{} = duty,
        operation,
        amounts
      )
      when operation in [:settle, :release] and is_map(amounts) and not is_struct(amounts) do
    with {:ok, cause_act} <- Spectre.Act.new(cause_act),
         {:ok, disposition_act} <- Spectre.Act.new(disposition_act),
         {:ok, duty} <- Spectre.Duty.new(duty),
         {:ok, disposition} <-
           Spectre.Duty.Disposition.from_consequence(disposition_act.consequence),
         true <- duty.status == :open,
         true <- duty.act_ref == cause_act.ref,
         true <- disposition.duty_ref == duty.ref,
         true <- disposition.cause_key == duty.cause_key,
         true <- disposition.meter_resolution == operation,
         {:ok, amounts} <- duty_resolution_amounts(amounts) do
      {:ok,
       Projection.event(
         "meter_duty_resolved",
         "meter_duty_resolved:" <> disposition_act.ref,
         %{
           "act_ref" => cause_act.ref,
           "disposition_act_ref" => disposition_act.ref,
           "duty_ref" => duty.ref,
           "mandate_ref" => cause_act.mandate_ref,
           "operation" => operation,
           "amounts" => amounts
         }
       )}
    else
      false -> {:error, :duty_meter_resolution_binding_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def meter_duty_resolved(_cause_act, _disposition_act, _duty, _operation, _amounts),
    do: {:error, :invalid_duty_meter_resolution_event}

  @spec meter_devolved(Spectre.Act.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def meter_devolved(%Spectre.Act{} = act, child_mandate_ref, amounts)
      when is_binary(child_mandate_ref) and child_mandate_ref != "" and is_map(amounts) and
             not is_struct(amounts) do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, amounts} <- devolution_amounts(amounts) do
      {:ok,
       Projection.event("meter_devolved", "meter_devolved:" <> act.ref, %{
         "act_ref" => act.ref,
         "child_mandate_ref" => child_mandate_ref,
         "amounts" => amounts
       })}
    end
  end

  def meter_devolved(_act, _child_mandate_ref, _amounts),
    do: {:error, :invalid_meter_devolution_event}

  @spec surface_revised(Spectre.Act.t(), String.t(), Spectre.Surface.t()) ::
          {:ok, map()} | {:error, term()}
  def surface_revised(%Spectre.Act{} = act, previous_ref, %Spectre.Surface{} = surface)
      when is_binary(previous_ref) and previous_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, surface} <- Spectre.Surface.new(surface) do
      {:ok,
       Projection.event("surface_revised", surface.ref, %{
         "act_ref" => act.ref,
         "previous_ref" => previous_ref,
         "surface" => Spectre.Surface.canonical(surface)
       })}
    end
  end

  def surface_revised(_act, _previous_ref, _surface),
    do: {:error, :invalid_surface_revision_event}

  @spec host_profile_revised(Spectre.Act.t(), String.t(), Spectre.HostProfile.t()) ::
          {:ok, map()} | {:error, term()}
  def host_profile_revised(
        %Spectre.Act{} = act,
        previous_ref,
        %Spectre.HostProfile{} = profile
      )
      when is_binary(previous_ref) and previous_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, profile} <- Spectre.HostProfile.new(profile) do
      {:ok,
       Projection.event("host_profile_revised", profile.ref, %{
         "act_ref" => act.ref,
         "previous_ref" => previous_ref,
         "host_profile" => Spectre.HostProfile.canonical(profile)
       })}
    end
  end

  def host_profile_revised(_act, _previous_ref, _profile),
    do: {:error, :invalid_host_profile_revision_event}

  @spec definition_revised(Spectre.Act.t(), String.t() | nil, Spectre.Definition.t()) ::
          {:ok, map()} | {:error, term()}
  def definition_revised(%Spectre.Act{} = act, previous_ref, %Spectre.Definition{} = definition)
      when is_nil(previous_ref) or (is_binary(previous_ref) and previous_ref != "") do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, definition} <- Spectre.Definition.new(definition),
         true <- definition.previous_ref == previous_ref do
      {:ok,
       Projection.event("definition_revised", definition.ref, %{
         "act_ref" => act.ref,
         "previous_ref" => previous_ref,
         "definition" => Spectre.Definition.canonical(definition)
       })}
    else
      false -> {:error, :definition_previous_ref_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def definition_revised(_act, _previous_ref, _definition),
    do: {:error, :invalid_definition_revision_event}

  @spec dispatch_ready(Spectre.Act.t()) :: map()
  def dispatch_ready(%Spectre.Act{} = act) do
    Projection.event("dispatch_ready", "dispatch_ready:" <> act.ref, %{
      "act_ref" => act.ref,
      "executor_ref" => act.executor_ref,
      "executor_contract_ref" => act.executor_contract_ref
    })
  end

  @spec dispatch_cancelled(
          Spectre.Act.t(),
          Spectre.Act.t() | Spectre.Duty.t() | Spectre.Mandate.t(),
          atom()
        ) :: {:ok, map()} | {:error, term()}
  def dispatch_cancelled(%Spectre.Act{} = act, %Spectre.Act{} = cause_act, reason)
      when reason in [:mandate_revoked, :mandate_restricted] do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, cause_act} <- Spectre.Act.new(cause_act),
         :ok <- executor_mediated_dispatch(act),
         :ok <- ledger_internal_cause(cause_act) do
      {:ok,
       Projection.event("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
         "act_ref" => act.ref,
         "mandate_ref" => act.mandate_ref,
         "cause_ref" => cause_act.ref,
         "reason" => reason,
         "cancelled_at" => cause_act.committed_at
       })}
    else
      {:error, _reason} = error -> error
    end
  end

  def dispatch_cancelled(
        %Spectre.Act{} = act,
        %Spectre.Duty{class: :disputed_evidence} = duty,
        :disputed_evidence
      ) do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, duty} <- Spectre.Duty.new(duty),
         true <- Governance.executor_mediated?(act),
         true <- duty.status == :open,
         true <- duty.act_ref == act.ref,
         true <- is_nil(duty.attempt_ref),
         true <- duty.mandate_ref == act.mandate_ref do
      {:ok,
       Projection.event("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
         "act_ref" => act.ref,
         "mandate_ref" => act.mandate_ref,
         "cause_ref" => duty.ref,
         "reason" => :disputed_evidence,
         "cancelled_at" => duty.opened_at
       })}
    else
      false -> {:error, :disputed_dispatch_cancellation_binding_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def dispatch_cancelled(
        %Spectre.Act{} = act,
        %Spectre.Mandate{} = mandate,
        :mandate_expired
      ) do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, mandate} <- Spectre.Mandate.new(mandate),
         true <- Governance.executor_mediated?(act),
         true <- act.mandate_ref == mandate.ref,
         true <- act.mandate_revision == mandate.revision do
      {:ok,
       Projection.event("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
         "act_ref" => act.ref,
         "mandate_ref" => mandate.ref,
         "cause_ref" => mandate.ref,
         "reason" => :mandate_expired,
         "cancelled_at" => mandate.expires_at
       })}
    else
      false -> {:error, :dispatch_expiration_mandate_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def dispatch_cancelled(_act, _cause_act, _reason),
    do: {:error, :invalid_dispatch_cancellation_event}

  defp executor_mediated_dispatch(act) do
    if Governance.executor_mediated?(act),
      do: :ok,
      else: {:error, :dispatch_cancellation_requires_executor_mediated_act}
  end

  defp ledger_internal_cause(act) do
    if Governance.ledger_internal?(act),
      do: :ok,
      else: {:error, :dispatch_cancellation_cause_not_ledger_internal}
  end

  @spec mandate_revoked(String.t(), String.t(), integer()) ::
          map() | {:error, :invalid_mandate_revocation_event}
  def mandate_revoked(identity, mandate_ref, effective_at)
      when is_binary(identity) and identity != "" and is_binary(mandate_ref) and
             mandate_ref != "" and is_integer(effective_at) do
    Projection.event("mandate_revoked", identity, %{
      "mandate_ref" => mandate_ref,
      "effective_at" => effective_at
    })
  end

  def mandate_revoked(_identity, _mandate_ref, _effective_at),
    do: {:error, :invalid_mandate_revocation_event}

  @spec mandate_restricted(Spectre.Act.t(), String.t(), Spectre.Mandate.t()) ::
          {:ok, map()} | {:error, term()}
  def mandate_restricted(
        %Spectre.Act{} = act,
        predecessor_ref,
        %Spectre.Mandate{} = successor
      )
      when is_binary(predecessor_ref) and predecessor_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, successor} <- Spectre.Mandate.new(successor) do
      {:ok,
       Projection.event("mandate_restricted", successor.ref, %{
         "act_ref" => act.ref,
         "predecessor_ref" => predecessor_ref,
         "successor" => Spectre.Mandate.canonical(successor)
       })}
    end
  end

  def mandate_restricted(_act, _predecessor_ref, _successor),
    do: {:error, :invalid_mandate_restriction_event}

  @spec duty_disposed(String.t(), term(), String.t()) ::
          map() | {:error, :invalid_duty_disposition_event}
  def duty_disposed(disposition_act_ref, cause_key, disposition_act_ref)
      when is_binary(disposition_act_ref) and disposition_act_ref != "" and
             not is_nil(cause_key) do
    Projection.event("duty_disposed", disposition_act_ref, %{
      "cause_key" => cause_key,
      "disposition_act_ref" => disposition_act_ref
    })
  end

  def duty_disposed(_identity, _cause_key, _disposition_act_ref),
    do: {:error, :invalid_duty_disposition_event}

  @spec scope_opened(Spectre.Scope.Opening.t()) :: {:ok, map()} | {:error, term()}
  def scope_opened(%Spectre.Scope.Opening{} = opening), do: record(:scope, opening)
  def scope_opened(_opening), do: {:error, :invalid_scope_event}

  defp fetch_record_event(kind) do
    case Map.fetch(@record_events, kind) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, {:unknown_domain_record_kind, kind}}
    end
  end

  defp reservation_amounts(reservations) when is_map(reservations) do
    if map_size(reservations) == 0,
      do: {:error, :empty_meter_reservations},
      else: validate_amounts(reservations)
  end

  defp reservation_amounts(reservations) when is_list(reservations) do
    reservations
    |> Enum.reduce_while({:ok, %{}}, fn reservation, {:ok, amounts} ->
      with ref when is_binary(ref) and ref != "" <- field(reservation, :meter_ref),
           quantity when is_integer(quantity) and quantity > 0 <- field(reservation, :quantity),
           false <- Map.has_key?(amounts, ref) do
        {:cont, {:ok, Map.put(amounts, ref, quantity)}}
      else
        true -> {:halt, {:error, :duplicate_meter_reservation}}
        _invalid -> {:halt, {:error, :invalid_meter_reservation}}
      end
    end)
    |> case do
      {:ok, amounts} when map_size(amounts) == 0 -> {:error, :empty_meter_reservations}
      result -> result
    end
  end

  defp reservation_amounts(_reservations), do: {:error, :invalid_meter_reservations}

  defp devolution_amounts(amounts) when map_size(amounts) == 0,
    do: {:error, :empty_meter_devolution}

  defp devolution_amounts(amounts) do
    case validate_amounts(amounts) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, _reason} -> {:error, :invalid_meter_devolution}
    end
  end

  defp validate_amounts(amounts) do
    if Enum.all?(amounts, fn
         {ref, quantity} ->
           is_binary(ref) and ref != "" and is_integer(quantity) and quantity > 0
       end) do
      {:ok, amounts}
    else
      {:error, :invalid_meter_reservations}
    end
  end

  defp partial_amounts(amounts) when is_map(amounts) and not is_struct(amounts) do
    if Enum.all?(amounts, fn
         {ref, quantity} ->
           is_binary(ref) and ref != "" and is_integer(quantity) and quantity > 0
       end) do
      {:ok, amounts}
    else
      {:error, :invalid_meter_recontainment_amounts}
    end
  end

  defp partial_amounts(_amounts), do: {:error, :invalid_meter_recontainment_amounts}

  defp duty_resolution_amounts(amounts) do
    case partial_amounts(amounts) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, _reason} -> {:error, :invalid_duty_meter_resolution_amounts}
    end
  end

  defp exact_partition(amounts, recontained, deficits) do
    keys = Map.keys(recontained) ++ Map.keys(deficits)

    valid? =
      Enum.all?(keys, &Map.has_key?(amounts, &1)) and
        Enum.all?(amounts, fn {ref, quantity} ->
          Map.get(recontained, ref, 0) + Map.get(deficits, ref, 0) == quantity
        end)

    if valid?, do: :ok, else: {:error, :invalid_meter_recontainment_partition}
  end

  defp meter_event_type(:reserve), do: "meter_reserved"
  defp meter_event_type(:settle), do: "meter_settled"
  defp meter_event_type(:release), do: "meter_released"
  defp meter_event_type(:suspend), do: "meter_suspended"

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
