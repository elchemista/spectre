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

  alias Spectre.Act

  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Batch.Dispatch
  alias Spectre.GovernedAct.Batch.Effect
  alias Spectre.GovernedAct.Batch.Events
  alias Spectre.GovernedAct.Batch.Meter, as: MeterBatch
  alias Spectre.GovernedAct.Batch.World
  alias Spectre.GovernedAct.Execution, as: GovernedExecution

  @doc "Validates the cross-event grammar of one atomic governed transaction."
  @spec validate(map(), map(), [Event.t()]) :: :ok | {:error, term()}
  def validate(before, after_projection, events) do
    with :ok <- Dispatch.validate_expirations(before, events),
         :ok <- validate_admission_batch(before, after_projection, events),
         :ok <- World.validate(before, events),
         :ok <- validate_foundation_batch(events),
         :ok <- validate_mandate_batch(after_projection, events),
         :ok <- validate_governance_batch(events) do
      MeterBatch.validate(before, after_projection, events)
    end
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
            Dispatch.validate_ready(events, event)

          "dispatch_cancelled" ->
            Dispatch.validate_cancellation(events, event)

          "duty_opened" ->
            Dispatch.validate_disputed_duty(before, projection, events, event)

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
    previous = Events.at(events, event.batch_index - 1)

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

      Act.reservations?(act) and not GovernedExecution.executor_mediated?(act) and
          not MeterBatch.internal_settlement_at?(events, act, event.batch_index) ->
        {:error, {:internal_act_settlement_missing_from_admission_batch, act.ref}}

      GovernedExecution.executor_mediated?(act) and
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
    case Effect.exact?(events, act, after_index) do
      true -> Dispatch.validate_authority_change(before, projection, events, act, after_index)
      false -> {:error, {:governance_act_batch_incomplete, act.ref, act.class}}
      :unsupported -> {:error, {:unsupported_governance_act_class, act.ref, act.class}}
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

  defp batch_event?(events, type, identity, after_index) do
    Events.after?(events, type, identity, after_index)
  end
end
