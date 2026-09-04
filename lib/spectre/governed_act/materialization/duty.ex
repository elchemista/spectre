defmodule Spectre.GovernedAct.Materialization.Duty do
  @moduledoc false

  alias Spectre.Act
  alias Spectre.Domain.Event
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.{MeterState, State}

  @spec events(State.t(), Act.t()) :: {:ok, [map()]} | {:error, term()}
  def events(%State{} = projection, %Act{} = disposition_act) do
    with true <- Act.row?(disposition_act, [:govern]),
         true <- not Act.reservations?(disposition_act),
         {:ok, disposition} <- Disposition.from_consequence(disposition_act.consequence),
         {:ok, duty} <- fetch_open_duty(projection, disposition),
         {:ok, meter_events} <- meter_events(projection, duty, disposition, disposition_act),
         {:ok, disposed} <- Event.duty_disposed(disposition_act, disposition.cause_key) do
      {:ok, meter_events ++ [disposed]}
    else
      false -> {:error, :invalid_duty_disposition}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_open_duty(projection, disposition) do
    case Map.fetch(projection.duties, disposition.cause_key) do
      {:ok, %{status: :open, ref: ref} = duty} when ref == disposition.duty_ref -> {:ok, duty}
      {:ok, %{status: :disposed}} -> {:error, {:duty_already_disposed, disposition.duty_ref}}
      {:ok, _mismatch} -> {:error, {:duty_disposition_binding_mismatch, disposition.duty_ref}}
      :error -> {:error, {:duty_not_found, disposition.cause_key}}
    end
  end

  defp meter_events(_projection, %{act_ref: nil}, disposition, _disposition_act) do
    if disposition.meter_resolution == :none,
      do: {:ok, []},
      else: {:error, {:duty_has_no_meter_reservation, disposition.duty_ref}}
  end

  defp meter_events(projection, duty, disposition, disposition_act) do
    with {:ok, cause_act} <- Map.fetch(projection.acts, duty.act_ref) do
      derive_meter_events(projection, duty, cause_act, disposition, disposition_act)
    else
      :error -> {:error, {:duty_cause_act_not_found, duty.act_ref}}
    end
  end

  defp derive_meter_events(
         projection,
         _duty,
         %Act{reservations: reservations} = cause_act,
         disposition,
         _disposition_act
       )
       when map_size(reservations) == 0 do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, disposition.duty_ref}}

      Map.has_key?(projection.meter_reservations, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      true ->
        {:ok, []}
    end
  end

  defp derive_meter_events(projection, duty, cause_act, disposition, disposition_act) do
    status = MeterState.reservation_status(projection, cause_act.ref)
    recontainment = Map.get(projection.meter_recontainments, cause_act.ref)

    case {status, disposition.meter_resolution, recontainment} do
      {:suspended, :none, %{disposition_act_ref: nil, cause_key: cause_key}}
      when cause_key != duty.cause_key ->
        {:ok, []}

      {status, :none, nil} when status in [:settled, :released] ->
        {:ok, []}

      {:suspended, operation,
       %{disposition_act_ref: nil, cause_key: cause_key, recontained: amounts}}
      when operation in [:settle, :release] and cause_key == duty.cause_key ->
        build_meter_event(cause_act, disposition_act, duty, operation, amounts)

      {:suspended, operation, nil} when operation in [:settle, :release] ->
        with {:ok, reservation} <- MeterState.reservation(projection, cause_act.ref) do
          build_meter_event(cause_act, disposition_act, duty, operation, reservation.amounts)
        end

      {:suspended, :none, _recontainment} ->
        {:error, {:duty_meter_resolution_required, cause_act.ref}}

      {:reserved, _resolution, _recontainment} ->
        {:error, {:duty_meter_not_contained, cause_act.ref}}

      {nil, _resolution, _recontainment} ->
        {:error, {:reservation_not_found, cause_act.ref}}

      {_status, _resolution, %{disposition_act_ref: nil, cause_key: cause_key}}
      when cause_key != duty.cause_key ->
        {:error, {:meter_recontainment_requires_causal_duty, cause_act.ref, cause_key}}

      {status, resolution, _recontainment} ->
        {:error, {:invalid_duty_meter_resolution, cause_act.ref, status, resolution}}
    end
  end

  defp build_meter_event(cause_act, disposition_act, duty, operation, amounts) do
    with {:ok, event} <-
           Event.meter_duty_resolved(cause_act, disposition_act, duty, operation, amounts) do
      {:ok, [event]}
    end
  end
end
