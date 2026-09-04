defmodule Spectre.Domain.Event.Builder do
  @moduledoc """
  Canonical constructors for Domain event envelopes.

  Builders validate records and causal bindings before producing the plain maps
  accepted by the ledger writer. Decoding and acquisition-time checks remain in
  `Spectre.Domain.Event`; this module contains no replay semantics.
  """

  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.Outcome

  @correction_statuses Outcome.correction_statuses()

  @spec record(atom(), struct()) :: {:ok, map()} | {:error, term()}
  def record(kind, record) do
    with {:ok, {type, module}} <- Event.record_event(kind),
         true <- is_struct(record, module),
         {:ok, record} <- module.new(record),
         ref when is_binary(ref) and ref != "" <- Map.get(record, :ref),
         data when is_map(data) <- module.canonical(record) do
      {:ok, Event.envelope(type, ref, data)}
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
       Event.envelope(type, identity, %{
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
        %Outcome{status: status, contradicts_outcome_ref: corrected_ref} = outcome,
        recontained,
        deficits
      )
      when status in @correction_statuses and is_binary(corrected_ref) and
             corrected_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, outcome} <- Outcome.new(outcome),
         true <- outcome.act_ref == act.ref,
         {:ok, amounts} <- reservation_amounts(act.reservations),
         {:ok, recontained} <- partial_amounts(recontained),
         {:ok, deficits} <- partial_amounts(deficits),
         :ok <- exact_partition(amounts, recontained, deficits) do
      {:ok,
       Event.envelope("meter_recontained", "meter_recontained:" <> act.ref, %{
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
       Event.envelope(
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
       Event.envelope("meter_devolved", "meter_devolved:" <> act.ref, %{
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
       Event.envelope("surface_revised", surface.ref, %{
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
       Event.envelope("host_profile_revised", profile.ref, %{
         "act_ref" => act.ref,
         "previous_ref" => previous_ref,
         "host_profile" => Spectre.HostProfile.canonical(profile)
       })}
    end
  end

  def host_profile_revised(_act, _previous_ref, _profile),
    do: {:error, :invalid_host_profile_revision_event}

  @spec definition_revised(Spectre.Act.t(), Spectre.Definition.t()) ::
          {:ok, map()} | {:error, term()}
  def definition_revised(%Spectre.Act{} = act, %Spectre.Definition{} = definition) do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, definition} <- Spectre.Definition.new(definition) do
      {:ok,
       Event.envelope("definition_revised", definition.ref, %{
         "act_ref" => act.ref,
         "previous_ref" => definition.previous_ref,
         "definition" => Spectre.Definition.canonical(definition)
       })}
    end
  end

  def definition_revised(_act, _definition),
    do: {:error, :invalid_definition_revision_event}

  @spec principal_registered(Spectre.Act.t(), Spectre.Principal.t()) ::
          {:ok, map()} | {:error, term()}
  def principal_registered(%Spectre.Act{} = act, %Spectre.Principal{} = principal) do
    with {:ok, act} <- Spectre.Act.new(act),
         {:ok, principal} <- Spectre.Principal.new(principal) do
      {:ok,
       Event.envelope("principal_registered", principal.ref, %{
         "act_ref" => act.ref,
         "principal" => Spectre.Principal.canonical(principal)
       })}
    end
  end

  def principal_registered(_act, _principal),
    do: {:error, :invalid_principal_registration_event}

  @spec dispatch_ready(Spectre.Act.t()) :: map()
  def dispatch_ready(%Spectre.Act{} = act) do
    Event.envelope("dispatch_ready", "dispatch_ready:" <> act.ref, %{
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
       Event.envelope("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
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
         true <- GovernedExecution.executor_mediated?(act),
         true <- duty.status == :open,
         true <- duty.act_ref == act.ref,
         true <- is_nil(duty.attempt_ref),
         true <- duty.mandate_ref == act.mandate_ref do
      {:ok,
       Event.envelope("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
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
         true <- GovernedExecution.executor_mediated?(act),
         true <- act.mandate_ref == mandate.ref,
         true <- act.mandate_revision == mandate.revision do
      {:ok,
       Event.envelope("dispatch_cancelled", "dispatch_cancelled:" <> act.ref, %{
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
    if GovernedExecution.executor_mediated?(act),
      do: :ok,
      else: {:error, :dispatch_cancellation_requires_executor_mediated_act}
  end

  defp ledger_internal_cause(act) do
    if GovernedExecution.ledger_internal?(act),
      do: :ok,
      else: {:error, :dispatch_cancellation_cause_not_ledger_internal}
  end

  @spec mandate_revoked(Spectre.Act.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def mandate_revoked(%Spectre.Act{} = act, mandate_ref)
      when is_binary(mandate_ref) and mandate_ref != "" do
    with {:ok, act} <- Spectre.Act.new(act) do
      {:ok,
       Event.envelope("mandate_revoked", act.ref, %{
         "mandate_ref" => mandate_ref,
         "effective_at" => act.committed_at
       })}
    end
  end

  def mandate_revoked(_act, _mandate_ref),
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
       Event.envelope("mandate_restricted", successor.ref, %{
         "act_ref" => act.ref,
         "predecessor_ref" => predecessor_ref,
         "successor" => Spectre.Mandate.canonical(successor)
       })}
    end
  end

  def mandate_restricted(_act, _predecessor_ref, _successor),
    do: {:error, :invalid_mandate_restriction_event}

  @spec duty_disposed(Spectre.Act.t(), term()) :: {:ok, map()} | {:error, term()}
  def duty_disposed(%Spectre.Act{} = disposition_act, cause_key) when not is_nil(cause_key) do
    with {:ok, disposition_act} <- Spectre.Act.new(disposition_act) do
      {:ok,
       Event.envelope("duty_disposed", disposition_act.ref, %{
         "cause_key" => cause_key,
         "disposition_act_ref" => disposition_act.ref
       })}
    end
  end

  def duty_disposed(_disposition_act, _cause_key),
    do: {:error, :invalid_duty_disposition_event}

  @spec scope_opened(Spectre.Scope.Opening.t()) :: {:ok, map()} | {:error, term()}
  def scope_opened(%Spectre.Scope.Opening{} = opening), do: record(:scope, opening)
  def scope_opened(_opening), do: {:error, :invalid_scope_event}

  defp reservation_amounts(reservations) do
    case Amounts.non_empty(reservations) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, :empty_meter_amounts} -> {:error, :empty_meter_reservations}
      {:error, _reason} -> {:error, :invalid_meter_reservations}
    end
  end

  defp devolution_amounts(amounts) do
    case Amounts.non_empty(amounts) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, :empty_meter_amounts} -> {:error, :empty_meter_devolution}
      {:error, _reason} -> {:error, :invalid_meter_devolution}
    end
  end

  defp partial_amounts(amounts) when is_map(amounts) and not is_struct(amounts) do
    case Amounts.normalize(amounts) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, _reason} -> {:error, :invalid_meter_recontainment_amounts}
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
    case Amounts.exact_partition(amounts, recontained, deficits) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_meter_recontainment_partition}
    end
  end

  defp meter_event_type(:reserve), do: "meter_reserved"
  defp meter_event_type(:settle), do: "meter_settled"
  defp meter_event_type(:release), do: "meter_released"
  defp meter_event_type(:suspend), do: "meter_suspended"
end
