defmodule Spectre.GovernedAct.Batch.Dispatch do
  @moduledoc """
  Cross-event grammar for pending executor dispatch and cancellation.

  It derives every cancellation forced by expiry, authority change or a
  disputed-Evidence Duty and verifies the exact ordered release events for any
  reserved Meter quantities.
  """

  alias Spectre.Act
  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.AuthorityChange
  alias Spectre.GovernedAct.Batch.Events
  alias Spectre.GovernedAct.{DispatchState, State}
  alias Spectre.GovernedAct.Materialization.{Authority, Dispatch}

  @doc false
  @spec validate_expirations(State.t(), [Event.t()]) :: :ok | {:error, term()}
  def validate_expirations(%State{}, []), do: :ok

  def validate_expirations(%State{} = before, [%{recorded_at: recorded_at} | _] = events) do
    with {:ok, expired} <- expired_pending(before, recorded_at),
         {:ok, expected_events} <- expiration_events(expired),
         true <-
           Enum.all?(events, &(&1.recorded_at == recorded_at)) and
             expiration_refs(events) == Enum.map(expired, fn {act, _mandate} -> act.ref end) and
             Events.payload_sequence?(events, expected_events, 0) do
      :ok
    else
      false -> {:error, :dispatch_expiration_batch_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_ready([Event.t()], Event.t()) :: :ok | {:error, term()}
  def validate_ready(events, event) do
    act_ref = event.data["act_ref"]

    if Events.after?(events, "act_committed", act_ref, -1),
      do: :ok,
      else: {:error, {:dispatch_outside_admission_batch, act_ref}}
  end

  @doc false
  @spec validate_cancellation([Event.t()], Event.t()) :: :ok | {:error, term()}
  def validate_cancellation(events, event) do
    cause_ref = event.data["cause_ref"]

    case event.data["reason"] do
      reason when reason in [:mandate_revoked, :mandate_restricted] ->
        if Events.after?(events, "act_committed", cause_ref, -1),
          do: :ok,
          else: {:error, {:dispatch_cancellation_outside_governance_batch, event.identity}}

      :disputed_evidence ->
        validate_disputed_cancellation(events, event, cause_ref)

      :mandate_expired ->
        :ok

      reason ->
        {:error, {:invalid_dispatch_cancellation_reason, event.identity, reason}}
    end
  end

  @doc false
  @spec validate_disputed_duty(State.t(), State.t(), [Event.t()], Event.t()) ::
          :ok | {:error, term()}
  def validate_disputed_duty(%State{} = before, %State{} = projection, events, event) do
    with {:ok, duty} <- Record.decode(Spectre.Duty, event.data) do
      if duty.class == :disputed_evidence and
           MapSet.member?(
             pending_refs_before(before, events, event.batch_index),
             duty.act_ref
           ) do
        validate_disputed_duty_cancellation(projection, events, event, duty)
      else
        :ok
      end
    end
  end

  defp validate_disputed_duty_cancellation(projection, events, event, duty) do
    with {:ok, act} <- fetch_act(projection, duty.act_ref),
         true <- exact_disputed_cancellation?(events, event.batch_index + 1, act, duty) do
      :ok
    else
      false -> {:error, {:disputed_dispatch_cancellation_batch_mismatch, duty.ref}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_authority_change(State.t(), State.t(), [Event.t()], Act.t(), integer()) ::
          :ok | {:error, term()}
  def validate_authority_change(
        %State{} = before,
        %State{} = projection,
        events,
        %Act{class: class} = cause_act,
        act_index
      )
      when class in ["mandate.revoke", "mandate.restrict"] do
    reason = if class == "mandate.revoke", do: :mandate_revoked, else: :mandate_restricted

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
         {:ok, expected_events} <- Authority.cancellation_events(affected_acts, cause_act, reason),
         true <-
           exact_cancellation_sequence?(
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

  def validate_authority_change(_before, _projection, events, %Act{} = cause_act, _index) do
    if Enum.any?(events, fn event ->
         event.type == "dispatch_cancelled" and event.data["cause_ref"] == cause_act.ref
       end),
       do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref}},
       else: :ok
  end

  defp validate_disputed_cancellation(events, event, cause_ref) do
    case Events.at(events, event.batch_index - 1) do
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
  end

  defp expired_pending(projection, recorded_at) do
    DispatchState.expired(projection, recorded_at)
  end

  defp expiration_events(expired) do
    Enum.reduce_while(expired, {:ok, []}, fn {act, mandate}, {:ok, reversed} ->
      case Dispatch.cancellation(act, mandate, :mandate_expired) do
        {:ok, payloads} -> {:cont, {:ok, Enum.reverse(payloads, reversed)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp expiration_refs(events) do
    events
    |> Enum.filter(&(&1.type == "dispatch_cancelled" and &1.data["reason"] == :mandate_expired))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.map(& &1.data["act_ref"])
  end

  defp exact_disputed_cancellation?(events, index, act, duty) do
    case Dispatch.cancellation(act, duty, :disputed_evidence) do
      {:ok, payloads} ->
        Events.payload_sequence?(events, payloads, index)

      {:error, _reason} ->
        false
    end
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
    |> pending_refs_before(events, before_index)
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
        {:cont, {:ok, collect_affected(affected?, act, affected)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp collect_affected(true, act, affected), do: [act | affected]
  defp collect_affected(false, _act, affected), do: affected

  defp pending_refs_before(before, events, before_index) do
    events
    |> Enum.filter(&(&1.batch_index < before_index))
    |> Enum.sort_by(& &1.batch_index)
    |> Enum.reduce(DispatchState.pending_refs(before), fn event, pending ->
      case event.type do
        "dispatch_ready" -> MapSet.put(pending, event.data["act_ref"])
        "dispatch_cancelled" -> MapSet.delete(pending, event.data["act_ref"])
        "attempt_started" -> MapSet.delete(pending, event.data["act_ref"])
        _other -> pending
      end
    end)
  end

  defp exact_cancellation_sequence?(
         events,
         cause_act,
         affected_acts,
         expected_events,
         first_index
       ) do
    actual_refs =
      events
      |> Enum.filter(fn event ->
        event.type == "dispatch_cancelled" and event.data["cause_ref"] == cause_act.ref
      end)
      |> Enum.sort_by(& &1.batch_index)
      |> Enum.map(& &1.data["act_ref"])

    actual_refs == Enum.map(affected_acts, & &1.ref) and
      Events.payload_sequence?(events, expected_events, first_index)
  end

  defp fetch_act(state, act_ref) do
    case Map.fetch(state.acts, act_ref) do
      {:ok, %Act{} = act} -> {:ok, act}
      {:ok, _invalid} -> {:error, {:invalid_act, act_ref}}
      :error -> {:error, {:act_not_found, act_ref}}
    end
  end

  defp reverse_ok({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_ok({:error, _reason} = error), do: error
end
