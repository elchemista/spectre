defmodule Spectre.GovernedAct.Batch do
  @moduledoc """
  Cross-event grammar for one atomic governed transaction.

  Individual event decoding belongs to `Spectre.Domain.Event`, and individual
  state transitions belong to `Spectre.GovernedAct.Fold`. This module checks
  the relationships that only make sense across a complete ledger batch:
  Admission adjacency, governance consequences, dispatch cancellation, world
  boundary ordering, and Meter reservation/disposition pairing.

  It is deliberately pure. The sequencer decides when to append a batch; this
  validator only proves that replaying it preserves the Governed Act Model.
  """

  alias Spectre.{
    Act,
    Declassification,
    Definition,
    Erasure,
    Evidence,
    Governance,
    HostProfile,
    Mandate,
    Principal,
    Surface
  }

  alias Spectre.Domain.Event
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.AuthorityChange
  alias Spectre.Canonical.Record
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.Scope.Opening

  @doc "Validates the cross-event grammar of one atomic governed transaction."
  @spec validate(map(), map(), [Event.t()]) :: :ok | {:error, term()}
  def validate(before, after_projection, events) do
    with :ok <- validate_dispatch_expiration_batch(before, events),
         :ok <- validate_admission_batch(before, after_projection, events),
         :ok <- validate_world_stage_batch(before, events),
         :ok <- validate_foundation_batch(events),
         :ok <- validate_mandate_batch(after_projection, events),
         :ok <- validate_governance_batch(events) do
      validate_meter_batch(before, after_projection, events)
    end
  end

  defp validate_dispatch_expiration_batch(_before, []), do: :ok

  defp validate_dispatch_expiration_batch(before, [%{recorded_at: recorded_at} | _] = events) do
    with {:ok, expired} <- expired_pending_dispatches(before, recorded_at),
         {:ok, expected_events} <- expected_dispatch_expiration_events(expired),
         true <-
           Enum.all?(events, &(&1.recorded_at == recorded_at)) and
             expiration_event_refs(events) == Enum.map(expired, fn {act, _mandate} -> act.ref end) and
             exact_event_sequence?(events, expected_events, 0) do
      :ok
    else
      false -> {:error, :dispatch_expiration_batch_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp expired_pending_dispatches(projection, recorded_at) do
    projection.dispatch_ready
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, expired} ->
      with {:ok, act} <- fetch_act(projection, act_ref),
           {:ok, mandate} <- fetch_mandate(projection, act.mandate_ref),
           true <- Governance.executor_mediated?(act),
           true <- act.mandate_revision == mandate.revision,
           false <- Map.has_key?(projection.attempts_by_act, act.ref),
           false <- Map.has_key?(projection.dispatch_cancellations, act.ref) do
        if mandate.expires_at <= recorded_at,
          do: {:cont, {:ok, [{act, mandate} | expired]}},
          else: {:cont, {:ok, expired}}
      else
        false -> {:halt, {:error, {:invalid_pending_dispatch, act_ref}}}
        true -> {:halt, {:error, {:terminal_pending_dispatch, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, expired} -> {:ok, Enum.reverse(expired)}
      {:error, _reason} = error -> error
    end
  end

  defp expected_dispatch_expiration_events(expired) do
    expired
    |> Enum.reduce_while({:ok, []}, fn {act, mandate}, {:ok, reversed} ->
      expiration =
        {"dispatch_cancelled", "dispatch_cancelled:" <> act.ref,
         %{
           "act_ref" => act.ref,
           "mandate_ref" => mandate.ref,
           "cause_ref" => mandate.ref,
           "reason" => :mandate_expired,
           "cancelled_at" => mandate.expires_at
         }}

      if Act.reservations?(act) do
        case Amounts.normalize(act.reservations) do
          {:ok, amounts} ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => mandate.ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, [release, expiration | reversed]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, [expiration | reversed]}}
      end
    end)
    |> reverse_ok()
  end

  defp expiration_event_refs(events) do
    events
    |> Enum.filter(&(&1.type == "dispatch_cancelled" and &1.data["reason"] == :mandate_expired))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.map(& &1.data["act_ref"])
  end

  defp exact_event_sequence?(events, expected, first_index) do
    expected
    |> Enum.with_index(first_index)
    |> Enum.all?(fn {{type, identity, data}, index} ->
      exact_manual_event_at?(events, index, type, identity, data)
    end)
  end

  defp validate_admission_batch(before, projection, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "decision_recorded" ->
            validate_decision_batch_event(projection, events, event)

          "act_committed" ->
            validate_act_batch_event(before, projection, events, event)

          "dispatch_ready" ->
            validate_dispatch_batch_event(events, event)

          "dispatch_cancelled" ->
            validate_dispatch_cancellation_batch_event(events, event)

          "duty_opened" ->
            validate_disputed_dispatch_cancellation_batch(before, projection, events, event)

          _other ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_decision_batch_event(projection, events, event) do
    decision = Map.fetch!(projection.decisions, event.identity)

    acts =
      Enum.filter(
        events,
        &(&1.type == "act_committed" and &1.data["decision_ref"] == event.identity)
      )

    case {decision.outcome, acts} do
      {:admitted, [%{batch_index: act_index}]} when act_index == event.batch_index + 1 -> :ok
      {:admitted, _other} -> {:error, {:admitted_decision_batch_incomplete, decision.ref}}
      {_not_admitted, []} -> :ok
      {_not_admitted, _acts} -> {:error, {:non_admitted_decision_has_batch_act, decision.ref}}
    end
  end

  defp validate_act_batch_event(before, projection, events, event) do
    act = Map.fetch!(projection.acts, event.identity)
    previous = event_at(events, event.batch_index - 1)

    cond do
      is_nil(previous) or previous.type != "decision_recorded" or
          previous.identity != act.decision_ref ->
        {:error, {:act_outside_admission_batch, act.ref}}

      Act.reservations?(act) and
          not batch_event?(
            events,
            "meter_reserved",
            "meter_reserved:" <> act.ref,
            event.batch_index
          ) ->
        {:error, {:act_reservation_missing_from_admission_batch, act.ref}}

      Act.reservations?(act) and not Governance.executor_mediated?(act) and
          not internal_settlement_at?(events, act, event.batch_index) ->
        {:error, {:internal_act_settlement_missing_from_admission_batch, act.ref}}

      Governance.executor_mediated?(act) and
          not batch_event?(
            events,
            "dispatch_ready",
            "dispatch_ready:" <> act.ref,
            event.batch_index
          ) ->
        {:error, {:act_dispatch_missing_from_admission_batch, act.ref}}

      true ->
        validate_governance_act_batch(before, projection, events, act, event.batch_index)
    end
  end

  defp validate_governance_act_batch(before, projection, events, act, after_index) do
    case exact_governance_effect?(events, act, after_index) do
      true -> validate_authority_cancellation_batch(before, projection, events, act, after_index)
      false -> {:error, {:governance_act_batch_incomplete, act.ref, act.class}}
      :unsupported -> {:error, {:unsupported_governance_act_class, act.ref, act.class}}
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "principal.register",
           consequence: %{"principal_registration" => canonical}
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, principal} <- Record.decode(Principal, canonical) do
      exact_manual_event_at?(
        events,
        act_index + 1,
        "principal_registered",
        principal.ref,
        %{
          "act_ref" => act.ref,
          "principal" => Principal.canonical(principal)
        }
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_record_event_at?(events, act_index + 1, "mandate_issued", Mandate, mandate)
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.revoke",
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 1 do
    exact_manual_event_at?(
      events,
      act_index + 1,
      "mandate_revoked",
      act.ref,
      %{"mandate_ref" => mandate_ref, "effective_at" => act.committed_at}
    )
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.restrict",
           consequence: %{
             "mandate_restrict" =>
               %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "mandate_restricted",
        act.ref,
        predecessor_ref,
        "predecessor_ref",
        "successor",
        Mandate,
        successor
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "mandate.devolve",
           consequence: %{
             "mandate_devolve" =>
               %{"child_mandate_ref" => child_ref, "amounts" => amounts} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    exact_manual_event_at?(
      events,
      act_index + 1,
      "meter_devolved",
      "meter_devolved:" <> act.ref,
      %{"act_ref" => act.ref, "child_mandate_ref" => child_ref, "amounts" => amounts}
    )
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "surface.revise",
           consequence: %{
             "surface_revision" =>
               %{"previous_ref" => previous_ref, "surface" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, surface} <- Record.decode(Surface, canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "surface_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "surface",
        Surface,
        surface
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "host_profile.revise",
           consequence: %{
             "host_profile_revision" =>
               %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, profile} <- Record.decode(HostProfile, canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "host_profile_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "host_profile",
        HostProfile,
        profile
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{
           class: "definition.revise",
           consequence: %{
             "definition_revision" =>
               %{"previous_ref" => previous_ref, "definition" => canonical} = command
           }
         } = act,
         act_index
       )
       when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, definition} <- Record.decode(Definition, canonical) do
      exact_embedded_event_at?(
        events,
        act_index + 1,
        "definition_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "definition",
        Definition,
        definition
      )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "data.declassify", consequence: %{"evidence_declassification" => draft}} =
           act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, decoded} <- Declassification.decode_draft(draft),
         {:ok, declassification} <-
           Declassification.from_draft(decoded.canonical, act.ref, act.committed_at) do
      exact_record_event_at?(
        events,
        act_index + 1,
        "declassification_recorded",
        Declassification,
        declassification
      ) and
        exact_record_event_at?(
          events,
          act_index + 2,
          "evidence_recorded",
          Evidence,
          decoded.evidence
        )
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, canonical} <- Erasure.request_draft(draft),
         true <- canonical == draft,
         {:ok, erasure} <- Erasure.from_request_draft(canonical, act.ref) do
      exact_record_event_at?(
        events,
        act_index + 1,
        "erasure_requested",
        Erasure,
        erasure
      )
    else
      _invalid -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act,
         act_index
       )
       when map_size(act.consequence) == 1 do
    with {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at) do
      exact_record_event_at?(events, act_index + 1, "scope_opened", Opening, opening)
    else
      {:error, _reason} -> false
    end
  end

  defp exact_governance_effect?(
         events,
         %Act{class: "duty.dispose"} = act,
         act_index
       ) do
    duty_disposition_batch_complete?(events, act, act_index)
  end

  defp exact_governance_effect?(_events, %Act{class: class}, _act_index)
       when class in [
              "principal.register",
              "mandate.delegate",
              "mandate.restrict",
              "mandate.revoke",
              "mandate.devolve",
              "surface.revise",
              "host_profile.revise",
              "definition.revise",
              "data.declassify",
              "data.erase",
              "scope.open",
              "duty.dispose"
            ],
       do: false

  defp exact_governance_effect?(_events, %Act{} = act, _act_index) do
    if act.row.delegate or act.row.govern, do: :unsupported, else: true
  end

  defp exact_record_event_at?(events, index, type, module, expected) do
    case event_at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == Record.ref(expected) and Record.decode(module, data) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  defp exact_embedded_event_at?(
         events,
         index,
         type,
         act_ref,
         relation_ref,
         relation_key,
         record_key,
         module,
         expected
       ) do
    case event_at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == Record.ref(expected) and data["act_ref"] == act_ref and
          data[relation_key] == relation_ref and
          Record.decode(module, data[record_key]) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  defp exact_manual_event_at?(events, index, type, identity, expected_data) do
    case event_at(events, index) do
      %{type: ^type, identity: ^identity, data: data} ->
        Enum.all?(expected_data, fn {key, value} -> data[key] == value end)

      _missing_or_different ->
        false
    end
  end

  # Ledger verification guarantees ordered, contiguous zero-based batch
  # indexes, so positional lookup avoids rescanning every event by predicate.
  defp event_at(_events, index) when index < 0, do: nil
  defp event_at(events, index), do: Enum.at(events, index)

  defp validate_dispatch_batch_event(events, event) do
    act_ref = event.data["act_ref"]

    if batch_event?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:dispatch_outside_admission_batch, act_ref}}
  end

  defp validate_dispatch_cancellation_batch_event(events, event) do
    cause_ref = event.data["cause_ref"]

    case event.data["reason"] do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        if batch_event?(events, "act_committed", cause_ref, -1),
          do: :ok,
          else: {:error, {:dispatch_cancellation_outside_governance_batch, event.identity}}

      :disputed_evidence ->
        case event_at(events, event.batch_index - 1) do
          %{type: "duty_opened", identity: ^cause_ref, data: duty_data} ->
            with {:ok, duty} <- Record.decode(Spectre.Duty, duty_data),
                 true <- duty.class == :disputed_evidence,
                 true <- duty.act_ref == event.data["act_ref"],
                 true <- is_nil(duty.attempt_ref),
                 true <- duty.mandate_ref == event.data["mandate_ref"] do
              :ok
            else
              false -> {:error, {:invalid_disputed_dispatch_cancellation, event.identity}}
              {:error, _reason} = error -> error
            end

          _missing_or_different ->
            {:error, {:dispatch_cancellation_outside_duty_batch, event.identity}}
        end

      :mandate_expired ->
        :ok

      reason ->
        {:error, {:invalid_dispatch_cancellation_reason, event.identity, reason}}
    end
  end

  defp validate_disputed_dispatch_cancellation_batch(before, projection, events, event) do
    with {:ok, duty} <- Record.decode(Spectre.Duty, event.data) do
      if duty.class == :disputed_evidence and
           MapSet.member?(
             pending_dispatch_refs_before(before, events, event.batch_index),
             duty.act_ref
           ) do
        with {:ok, act} <- fetch_act(projection, duty.act_ref),
             true <-
               exact_disputed_dispatch_cancellation?(
                 events,
                 event.batch_index + 1,
                 act,
                 duty
               ),
             true <- exact_cancellation_release?(events, event.batch_index + 2, act) do
          :ok
        else
          false -> {:error, {:disputed_dispatch_cancellation_batch_mismatch, duty.ref}}
          {:error, _reason} = error -> error
        end
      else
        :ok
      end
    end
  end

  defp exact_disputed_dispatch_cancellation?(events, index, act, duty) do
    exact_manual_event_at?(
      events,
      index,
      "dispatch_cancelled",
      "dispatch_cancelled:" <> act.ref,
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "cause_ref" => duty.ref,
        "reason" => :disputed_evidence,
        "cancelled_at" => duty.opened_at
      }
    )
  end

  defp exact_cancellation_release?(events, index, act) do
    if Act.reservations?(act) do
      with {:ok, amounts} <- Amounts.normalize(act.reservations) do
        exact_manual_event_at?(
          events,
          index,
          "meter_released",
          "meter_released:" <> act.ref,
          %{
            "act_ref" => act.ref,
            "mandate_ref" => act.mandate_ref,
            "amounts" => amounts
          }
        )
      else
        {:error, _reason} -> false
      end
    else
      true
    end
  end

  defp duty_disposition_batch_complete?(events, act, act_index) do
    with {:ok, disposition} <- Disposition.from_consequence(act.consequence) do
      case disposition.meter_resolution do
        :none ->
          exact_duty_disposal_at?(events, act_index + 1, act, disposition)

        operation when operation in [:settle, :release] ->
          exact_duty_meter_resolution_at?(
            events,
            act_index + 1,
            act,
            disposition,
            operation
          ) and exact_duty_disposal_at?(events, act_index + 2, act, disposition)
      end
    else
      {:error, _reason} -> false
    end
  end

  defp exact_duty_meter_resolution_at?(events, index, act, disposition, operation) do
    case event_at(events, index) do
      %{
        type: "meter_duty_resolved",
        identity: "meter_duty_resolved:" <> disposition_act_ref,
        data: data
      } ->
        disposition_act_ref == act.ref and data["disposition_act_ref"] == act.ref and
          data["duty_ref"] == disposition.duty_ref and
          data["operation"] == operation

      _missing_or_different ->
        false
    end
  end

  defp exact_duty_disposal_at?(events, index, act, disposition) do
    exact_manual_event_at?(
      events,
      index,
      "duty_disposed",
      act.ref,
      %{"cause_key" => disposition.cause_key, "disposition_act_ref" => act.ref}
    )
  end

  defp validate_authority_cancellation_batch(
         before,
         projection,
         events,
         %Act{class: class} = cause_act,
         act_index
       )
       when class in ["mandate.revoke", "mandate.restrict"] do
    reason =
      if class == "mandate.revoke", do: :mandate_revoked, else: :mandate_restricted

    with {:ok, target_mandate_ref, cascade?} <-
           AuthorityChange.resolve(projection, cause_act, reason),
         {:ok, affected_acts} <-
           affected_pending_acts(
             before,
             projection,
             events,
             act_index,
             target_mandate_ref,
             cascade?
           ),
         {:ok, expected_events} <-
           expected_dispatch_cancellation_events(affected_acts, cause_act, reason),
         true <-
           exact_dispatch_cancellation_sequence?(
             events,
             cause_act,
             affected_acts,
             expected_events,
             act_index + 2
           ) do
      :ok
    else
      false -> {:error, {:dispatch_cancellation_batch_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_authority_cancellation_batch(_before, _projection, events, cause_act, _index) do
    if Enum.any?(events, fn event ->
         event.type == "dispatch_cancelled" and
           event.data["cause_ref"] == cause_act.ref
       end),
       do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref}},
       else: :ok
  end

  defp affected_pending_acts(
         before,
         projection,
         events,
         before_index,
         target_mandate_ref,
         cascade?
       ) do
    before
    |> pending_dispatch_refs_before(events, before_index)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, affected} ->
      with {:ok, act} <- fetch_act(projection, act_ref),
           {:ok, affected?} <-
             AuthorityChange.affects?(
               projection,
               act.mandate_ref,
               target_mandate_ref,
               cascade?
             ) do
        if affected?,
          do: {:cont, {:ok, [act | affected]}},
          else: {:cont, {:ok, affected}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, affected} -> {:ok, Enum.reverse(affected)}
      {:error, _reason} = error -> error
    end
  end

  defp pending_dispatch_refs_before(before, events, before_index) do
    events
    |> Enum.filter(&(&1.batch_index < before_index))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.reduce(before.dispatch_ready, fn event, pending ->
      case event.type do
        "dispatch_ready" -> MapSet.put(pending, event.data["act_ref"])
        "dispatch_cancelled" -> MapSet.delete(pending, event.data["act_ref"])
        "attempt_started" -> MapSet.delete(pending, event.data["act_ref"])
        _other -> pending
      end
    end)
  end

  defp expected_dispatch_cancellation_events(acts, cause_act, reason) do
    acts
    |> Enum.reduce_while({:ok, []}, fn act, {:ok, reversed} ->
      cancellation =
        {"dispatch_cancelled", "dispatch_cancelled:" <> act.ref,
         %{
           "act_ref" => act.ref,
           "mandate_ref" => act.mandate_ref,
           "cause_ref" => cause_act.ref,
           "reason" => reason,
           "cancelled_at" => cause_act.committed_at
         }}

      if Act.reservations?(act) do
        case Amounts.normalize(act.reservations) do
          {:ok, amounts} ->
            release =
              {"meter_released", "meter_released:" <> act.ref,
               %{
                 "act_ref" => act.ref,
                 "mandate_ref" => act.mandate_ref,
                 "amounts" => amounts
               }}

            {:cont, {:ok, [release, cancellation | reversed]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:cont, {:ok, [cancellation | reversed]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp exact_dispatch_cancellation_sequence?(
         events,
         cause_act,
         affected_acts,
         expected_events,
         first_index
       ) do
    actual_act_refs =
      events
      |> Enum.filter(fn event ->
        event.type == "dispatch_cancelled" and
          event.data["cause_ref"] == cause_act.ref
      end)
      |> Enum.sort_by(& &1.batch_index)
      |> Enum.map(& &1.data["act_ref"])

    expected_act_refs = Enum.map(affected_acts, & &1.ref)

    actual_act_refs == expected_act_refs and
      expected_events
      |> Enum.with_index(first_index)
      |> Enum.all?(fn {{type, identity, data}, index} ->
        exact_manual_event_at?(events, index, type, identity, data)
      end)
  end

  # Admission, capability consumption and observation are separate durable
  # transitions. Seeing an earlier event in the same atomic batch is not proof
  # that its append was acknowledged before the next boundary was crossed.
  defp validate_world_stage_batch(before, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "attempt_started" -> validate_prior_dispatch(before, event)
          "outcome_recorded" -> validate_prior_attempt(before, event)
          _other -> :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_prior_dispatch(before, event) do
    act_ref = event.data["act_ref"]

    if MapSet.member?(before.dispatch_ready, act_ref),
      do: :ok,
      else: {:error, {:attempt_without_prior_durable_dispatch, event.identity, act_ref}}
  end

  defp validate_prior_attempt(before, event) do
    attempt_ref = event.data["attempt_ref"]
    act_ref = event.data["act_ref"]

    case Map.fetch(before.attempts, attempt_ref) do
      {:ok, %{act_ref: ^act_ref}} ->
        :ok

      {:ok, _different} ->
        {:error, {:outcome_prior_attempt_mismatch, event.identity, attempt_ref}}

      :error ->
        {:error, {:outcome_without_prior_durable_attempt, event.identity, attempt_ref}}
    end
  end

  defp validate_foundation_batch(events) do
    genesis? = Enum.any?(events, &(&1.type == "genesis_recorded"))

    foundation? =
      Enum.any?(
        events,
        &(&1.type in ["principal_recorded", "host_profile_recorded", "surface_recorded"])
      )

    if foundation? and not genesis?,
      do: {:error, :foundation_record_outside_genesis_batch},
      else: :ok
  end

  defp validate_mandate_batch(projection, events) do
    Enum.reduce_while(Enum.filter(events, &(&1.type == "mandate_issued")), :ok, fn event, :ok ->
      mandate = Map.fetch!(projection.mandates, event.identity)

      valid? =
        if is_nil(mandate.parent_ref) do
          batch_event?(events, "genesis_recorded", projection.genesis.ref, -1)
        else
          batch_event?(events, "act_committed", mandate.source_ref, -1)
        end

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:mandate_outside_authorizing_batch, mandate.ref}}}
    end)
  end

  defp validate_governance_batch(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      required_act_ref =
        case event.type do
          "mandate_revoked" -> event.identity
          "principal_registered" -> event.data["act_ref"]
          "mandate_restricted" -> event.data["act_ref"]
          "meter_devolved" -> event.data["act_ref"]
          "surface_revised" -> event.data["act_ref"]
          "host_profile_revised" -> event.data["act_ref"]
          "definition_revised" -> event.data["act_ref"]
          "declassification_recorded" -> event.data["source_act_ref"]
          "erasure_requested" -> event.data["source_act_ref"]
          "scope_opened" -> event.data["source_act_ref"]
          "meter_duty_resolved" -> event.data["disposition_act_ref"]
          "duty_disposed" -> event.data["disposition_act_ref"]
          _other -> nil
        end

      cond do
        is_nil(required_act_ref) ->
          {:cont, :ok}

        batch_event?(events, "act_committed", required_act_ref, -1) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:governance_event_outside_act_batch, event.type, required_act_ref}}}
      end
    end)
  end

  defp validate_meter_batch(before, projection, events) do
    with :ok <-
           Enum.reduce_while(events, :ok, fn event, :ok ->
             result =
               case event.type do
                 "meter_reserved" ->
                   validate_reserve_batch_event(events, event)

                 "meter_settled" ->
                   validate_disposition_batch_event(projection, events, event, [
                     :succeeded,
                     :failed
                   ])

                 "meter_released" ->
                   validate_disposition_batch_event(projection, events, event, [
                     :definitive_no_effect
                   ])

                 "meter_suspended" ->
                   validate_suspend_batch_event(before, projection, events, event)

                 "meter_recontained" ->
                   validate_recontainment_batch_event(events, event)

                 "meter_duty_resolved" ->
                   validate_duty_meter_resolution_batch_event(events, event)

                 _other ->
                   :ok
               end

             case result do
               :ok -> {:cont, :ok}
               {:error, _reason} = error -> {:halt, error}
             end
           end) do
      validate_required_recontainments(before, events)
    end
  end

  defp validate_reserve_batch_event(events, event) do
    act_ref = event.data["act_ref"]

    if batch_event?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:meter_reservation_outside_admission_batch, act_ref}}
  end

  defp validate_disposition_batch_event(projection, events, event, allowed_statuses) do
    act_ref = event.data["act_ref"]

    outcome_disposition? =
      Enum.any?(events, fn candidate ->
        candidate.type == "outcome_recorded" and candidate.data["act_ref"] == act_ref and
          candidate.data["status"] in allowed_statuses
      end)

    cancellation_release? =
      event.type == "meter_released" and
        case event_at(events, event.batch_index - 1) do
          %{type: "dispatch_cancelled", data: data} ->
            data["act_ref"] == act_ref

          _other ->
            false
        end

    internal_settlement? =
      event.type == "meter_settled" and
        case Map.get(projection.acts, act_ref) do
          %Act{} = act -> internal_settlement_at?(events, act, event.batch_index - 2)
          nil -> false
        end

    if outcome_disposition? or cancellation_release? or internal_settlement? do
      :ok
    else
      {:error, {:meter_disposition_outside_outcome_batch, act_ref, event.type}}
    end
  end

  defp validate_suspend_batch_event(before, projection, events, event) do
    act_ref = event.data["act_ref"]

    outcome_in_batch? =
      Enum.any?(events, fn candidate ->
        candidate.type == "outcome_recorded" and candidate.data["act_ref"] == act_ref and
          candidate.data["status"] == :ambiguous
      end)

    duty_in_batch? =
      Enum.any?(events, fn candidate ->
        candidate.type == "duty_opened" and candidate.data["act_ref"] == act_ref
      end)

    preexisting_duty? = Enum.any?(before.duties, fn {_key, duty} -> duty.act_ref == act_ref end)
    resulting_duty? = Enum.any?(projection.duties, fn {_key, duty} -> duty.act_ref == act_ref end)

    if outcome_in_batch? or (duty_in_batch? and resulting_duty?) or preexisting_duty?,
      do: :ok,
      else: {:error, {:meter_suspension_without_duty_or_outcome, act_ref}}
  end

  defp validate_recontainment_batch_event(events, event) do
    act_ref = event.data["act_ref"]
    outcome_ref = event.data["outcome_ref"]
    cause_key = {:contradicted_outcome, act_ref, nil, outcome_ref}

    outcome = event_at(events, event.batch_index - 1)
    duty = event_at(events, event.batch_index + 1)

    valid_outcome? =
      outcome && outcome.type == "outcome_recorded" && outcome.identity == outcome_ref &&
        outcome.data["act_ref"] == act_ref &&
        outcome.data["status"] in [:succeeded, :failed] &&
        present_ref?(outcome.data["contradicts_outcome_ref"])

    attempt_ref = if outcome, do: outcome.data["attempt_ref"]
    cause_key = put_elem(cause_key, 2, attempt_ref)

    valid_duty? =
      duty && duty.type == "duty_opened" && duty.data["cause_key"] == cause_key

    if valid_outcome? and valid_duty?,
      do: :ok,
      else: {:error, {:meter_recontainment_batch_incomplete, act_ref, outcome_ref}}
  end

  defp validate_duty_meter_resolution_batch_event(events, event) do
    disposition_act_ref = event.data["disposition_act_ref"]
    act = event_at(events, event.batch_index - 1)
    disposal = event_at(events, event.batch_index + 1)

    valid_act? =
      act && act.type == "act_committed" && act.identity == disposition_act_ref &&
        act.data["class"] == "duty.dispose"

    valid_disposal? =
      disposal && disposal.type == "duty_disposed" && disposal.identity == disposition_act_ref &&
        disposal.data["disposition_act_ref"] == disposition_act_ref

    if valid_act? and valid_disposal?,
      do: :ok,
      else: {:error, {:duty_meter_resolution_batch_incomplete, disposition_act_ref}}
  end

  defp validate_required_recontainments(before, events) do
    events
    |> Enum.filter(fn event ->
      event.type == "outcome_recorded" and
        present_ref?(event.data["contradicts_outcome_ref"]) and
        Map.get(before.reservation_states, event.data["act_ref"]) == :released
    end)
    |> Enum.reduce_while(:ok, fn outcome, :ok ->
      act_ref = outcome.data["act_ref"]

      matches =
        Enum.filter(events, fn event ->
          event.type == "meter_recontained" and event.data["act_ref"] == act_ref and
            event.data["outcome_ref"] == outcome.identity
        end)

      case matches do
        [_one] -> {:cont, :ok}
        _other -> {:halt, {:error, {:contradiction_recontainment_missing, outcome.identity}}}
      end
    end)
  end

  defp batch_event?(events, type, identity, after_index) do
    Enum.any?(
      events,
      &(&1.type == type and &1.identity == identity and &1.batch_index > after_index)
    )
  end

  defp fetch_act(state, act_ref) do
    case Map.fetch(state.acts, act_ref) do
      {:ok, %Act{} = act} -> {:ok, act}
      {:ok, _invalid} -> {:error, {:invalid_act, act_ref}}
      :error -> {:error, {:act_not_found, act_ref}}
    end
  end

  defp fetch_mandate(state, mandate_ref) do
    case Map.fetch(state.mandates, mandate_ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_mandate, mandate_ref}}
      :error -> {:error, {:mandate_not_found, mandate_ref}}
    end
  end

  defp internal_settlement_at?(events, %Act{} = act, act_index) do
    case {event_at(events, act_index + 1), event_at(events, act_index + 2)} do
      {%{type: "meter_reserved", data: reservation}, %{type: "meter_settled", data: settlement}} ->
        internal_spend_act?(act) and reservation["act_ref"] == act.ref and
          settlement["act_ref"] == act.ref

      _missing_or_interposed ->
        false
    end
  end

  defp internal_spend_act?(%Act{row: %{spend: true}} = act),
    do: Governance.ledger_internal?(act) and Act.reservations?(act)

  defp internal_spend_act?(_act), do: false

  defp present_ref?(value), do: is_binary(value) and value != ""

  defp reverse_ok({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_ok({:error, _reason} = error), do: error
end
