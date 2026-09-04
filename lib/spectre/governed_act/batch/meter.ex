defmodule Spectre.GovernedAct.Batch.Meter do
  @moduledoc """
  Cross-event invariants for conserved Meter transitions.

  Account arithmetic is validated by the fold. This module proves the batch
  relationship: reservation follows Admission, settlement follows an Outcome
  or internal Act, ambiguity is contained, and a contradictory Outcome is
  paired with recontainment and a Duty.
  """

  alias Spectre.Act
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Batch.Events
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{MeterState, State}

  @doc false
  @spec validate(State.t(), State.t(), [Event.t()]) :: :ok | {:error, term()}
  def validate(%State{} = before, %State{} = projection, events) when is_list(events) do
    with :ok <- validate_events(before, projection, events) do
      validate_required_recontainments(before, events)
    end
  end

  @doc false
  @spec internal_settlement_at?([Event.t()], Act.t(), integer()) :: boolean()
  def internal_settlement_at?(events, %Act{} = act, act_index) do
    case {event_at(events, act_index + 1), event_at(events, act_index + 2)} do
      {%{type: "meter_reserved", data: reservation}, %{type: "meter_settled", data: settlement}} ->
        internal_spend_act?(act) and reservation["act_ref"] == act.ref and
          settlement["act_ref"] == act.ref

      _missing_or_interposed ->
        false
    end
  end

  defp validate_events(before, projection, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "meter_reserved" ->
            validate_reserve(events, event)

          "meter_settled" ->
            validate_disposition(projection, events, event, [:succeeded, :failed])

          "meter_released" ->
            validate_disposition(projection, events, event, [:definitive_no_effect])

          "meter_suspended" ->
            validate_suspension(before, projection, events, event)

          "meter_recontained" ->
            validate_recontainment(events, event)

          "meter_duty_resolved" ->
            validate_duty_resolution(events, event)

          _other ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_reserve(events, event) do
    act_ref = event.data["act_ref"]

    if batch_event?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:meter_reservation_outside_admission_batch, act_ref}}
  end

  defp validate_disposition(projection, events, event, allowed_statuses) do
    act_ref = event.data["act_ref"]

    outcome_disposition? =
      Enum.any?(events, fn candidate ->
        candidate.type == "outcome_recorded" and candidate.data["act_ref"] == act_ref and
          candidate.data["status"] in allowed_statuses
      end)

    cancellation_release? =
      event.type == "meter_released" and
        case event_at(events, event.batch_index - 1) do
          %{type: "dispatch_cancelled", data: data} -> data["act_ref"] == act_ref
          _other -> false
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

  defp validate_suspension(before, projection, events, event) do
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

  defp validate_recontainment(events, event) do
    act_ref = event.data["act_ref"]
    outcome_ref = event.data["outcome_ref"]
    outcome = event_at(events, event.batch_index - 1)
    duty = event_at(events, event.batch_index + 1)

    valid_outcome? =
      outcome && outcome.type == "outcome_recorded" && outcome.identity == outcome_ref &&
        outcome.data["act_ref"] == act_ref && outcome.data["status"] in [:succeeded, :failed] &&
        present_ref?(outcome.data["contradicts_outcome_ref"])

    attempt_ref = if outcome, do: outcome.data["attempt_ref"]
    cause_key = {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}

    valid_duty? =
      duty && duty.type == "duty_opened" && duty.data["cause_key"] == cause_key

    if valid_outcome? and valid_duty?,
      do: :ok,
      else: {:error, {:meter_recontainment_batch_incomplete, act_ref, outcome_ref}}
  end

  defp validate_duty_resolution(events, event) do
    disposition_act_ref = event.data["disposition_act_ref"]
    act = event_at(events, event.batch_index - 1)
    disposal = event_at(events, event.batch_index + 1)

    valid_act? =
      act && act.type == "act_committed" && act.identity == disposition_act_ref &&
        act.data["class"] == "duty.dispose"

    valid_disposal? =
      disposal && disposal.type == "duty_disposed" &&
        disposal.identity == disposition_act_ref &&
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
        MeterState.reservation_status(before, event.data["act_ref"]) == :released
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
    Events.after?(events, type, identity, after_index)
  end

  defp event_at(events, index), do: Events.at(events, index)

  defp internal_spend_act?(act), do: GovernedExecution.metered_ledger_internal?(act)

  defp present_ref?(value), do: is_binary(value) and value != ""
end
