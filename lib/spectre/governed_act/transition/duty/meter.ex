defmodule Spectre.GovernedAct.Transition.Duty.Meter do
  @moduledoc """
  Applies the explicit Meter disposition attached to an open Duty.

  A suspended balance is changed only after `Duty.Disposal` has proved the
  closing Act and its supporting records. Recontained quantities preserve
  their causal Duty binding until this transition marks them disposed.
  """

  alias Spectre.{Act, Duty}
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.{Index, MeterState, State}
  alias Spectre.GovernedAct.Transition.Duty.Disposal
  alias Spectre.Kernel.Meter.Amounts

  @doc false
  @spec resolve(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def resolve(%State{} = projection, data) when is_map(data) do
    disposition_act_ref = data["disposition_act_ref"]
    duty_ref = data["duty_ref"]
    cause_act_ref = data["act_ref"]
    mandate_ref = data["mandate_ref"]
    operation = data["operation"]

    with true <- operation in [:settle, :release],
         {:ok, amounts} <- Amounts.normalize(data["amounts"]),
         :ok <- resolution_absent(projection, disposition_act_ref),
         {:ok, duty} <- Index.fetch_duty_by_ref(projection, duty_ref),
         :ok <- duty_open(duty),
         true <- duty.act_ref == cause_act_ref,
         {:ok, disposition_act} <- Index.fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(disposition_act.consequence),
         {:ok, supporting} <-
           Disposal.validate(projection, disposition_act, duty, disposition),
         true <- disposition.meter_resolution == operation,
         {:ok, cause_act} <- Index.fetch_act(projection, cause_act_ref),
         true <- cause_act.mandate_ref == mandate_ref,
         true <- Act.reservations?(cause_act),
         {:ok, %{status: :suspended} = reservation} <-
           MeterState.reservation(projection, cause_act.ref),
         :ok <- match_reservation(reservation, cause_act, mandate_ref),
         {:ok, expected_amounts, recontainment} <- expected_amounts(projection, cause_act, duty),
         true <- amounts == expected_amounts,
         :ok <-
           validate_resolution(
             projection,
             operation,
             supporting,
             cause_act,
             duty,
             disposition_act.committed_at
           ),
         {:ok, accounts} <- MeterState.accounts(projection, mandate_ref),
         {:ok, accounts} <-
           MeterState.transition_accounts(accounts, amounts, operation, :suspended),
         {:ok, projection} <- MeterState.put_accounts(projection, mandate_ref, accounts),
         {:ok, projection} <-
           MeterState.set_reservation_status(
             projection,
             cause_act.ref,
             resolved_status(operation)
           ) do
      projection =
        projection
        |> put_resolution(disposition_act.ref)
        |> put_resolved_recontainment(cause_act.ref, recontainment, disposition_act.ref)

      {:ok, projection}
    else
      false ->
        {:error, {:invalid_duty_meter_resolution_event, disposition_act_ref}}

      {:ok, %{status: status}} ->
        {:error, {:duty_meter_resolution_requires_suspension, cause_act_ref, status}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec validate_disposed(State.t(), Duty.t(), Disposition.t(), String.t()) ::
          :ok | {:error, term()}
  def validate_disposed(
        %State{} = projection,
        %Duty{act_ref: nil} = duty,
        %Disposition{} = disposition,
        act_ref
      ) do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      MapSet.member?(projection.duty_meter_resolutions, act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, act_ref}}

      true ->
        :ok
    end
  end

  def validate_disposed(
        %State{} = projection,
        %Duty{} = duty,
        %Disposition{} = disposition,
        disposition_act_ref
      ) do
    with {:ok, cause_act} <- Index.fetch_act(projection, duty.act_ref) do
      validate_disposed_for_act(
        projection,
        duty,
        cause_act,
        disposition,
        disposition_act_ref
      )
    end
  end

  defp resolution_absent(projection, disposition_act_ref) do
    if MapSet.member?(projection.duty_meter_resolutions, disposition_act_ref),
      do: {:error, {:duplicate_duty_meter_resolution, disposition_act_ref}},
      else: :ok
  end

  defp match_reservation(reservation, cause_act, mandate_ref) do
    with true <- reservation.mandate_ref == mandate_ref,
         {:ok, declared} <- Amounts.normalize(cause_act.reservations),
         true <- reservation.amounts == declared do
      :ok
    else
      false -> {:error, {:duty_meter_reservation_binding_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp expected_amounts(projection, cause_act, duty) do
    case Map.get(projection.meter_recontainments, cause_act.ref) do
      nil ->
        with {:ok, reservation} <- MeterState.reservation(projection, cause_act.ref) do
          {:ok, reservation.amounts, nil}
        end

      %{disposition_act_ref: nil, cause_key: cause_key} = record ->
        if cause_key == duty.cause_key,
          do: {:ok, record.recontained, record},
          else: {:error, {:meter_recontainment_requires_causal_duty, cause_act.ref, cause_key}}

      %{disposition_act_ref: disposition_act_ref} when is_binary(disposition_act_ref) ->
        {:error, {:meter_recontainment_already_resolved, cause_act.ref, disposition_act_ref}}

      _invalid ->
        {:error, {:invalid_meter_recontainment, cause_act.ref}}
    end
  end

  defp put_resolution(projection, disposition_act_ref) do
    %{
      projection
      | duty_meter_resolutions: MapSet.put(projection.duty_meter_resolutions, disposition_act_ref)
    }
  end

  defp put_resolved_recontainment(
         projection,
         _cause_act_ref,
         nil,
         _disposition_act_ref
       ),
       do: projection

  defp put_resolved_recontainment(projection, cause_act_ref, record, disposition_act_ref) do
    updated = %{record | disposition_act_ref: disposition_act_ref}

    %{
      projection
      | meter_recontainments: Map.put(projection.meter_recontainments, cause_act_ref, updated)
    }
  end

  defp validate_disposed_for_act(
         projection,
         duty,
         %Act{reservations: reservations} = cause_act,
         disposition,
         disposition_act_ref
       )
       when map_size(reservations) == 0 do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(projection.meter_reservations, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      MapSet.member?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      true ->
        :ok
    end
  end

  defp validate_disposed_for_act(
         projection,
         duty,
         cause_act,
         %Disposition{meter_resolution: :none},
         disposition_act_ref
       ) do
    recontainment = Map.get(projection.meter_recontainments, cause_act.ref)

    cond do
      MapSet.member?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      MeterState.reservation_status(projection, cause_act.ref) == :suspended and
        match?(%{disposition_act_ref: nil}, recontainment) and
          recontainment.cause_key != duty.cause_key ->
        :ok

      MeterState.reservation_status(projection, cause_act.ref) not in [:settled, :released] ->
        {:error, {:duty_meter_not_resolved, cause_act.ref}}

      true ->
        :ok
    end
  end

  defp validate_disposed_for_act(
         projection,
         duty,
         cause_act,
         disposition,
         disposition_act_ref
       ) do
    expected_status = resolved_status(disposition.meter_resolution)

    with true <- MapSet.member?(projection.duty_meter_resolutions, disposition_act_ref),
         true <- MeterState.reservation_status(projection, cause_act.ref) == expected_status,
         :ok <-
           validate_resolved_recontainment(
             projection,
             cause_act.ref,
             duty.cause_key,
             disposition_act_ref
           ) do
      :ok
    else
      false -> {:error, {:duty_meter_resolution_binding_mismatch, disposition_act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_resolved_recontainment(projection, cause_act_ref, cause_key, disposition_act_ref) do
    case Map.get(projection.meter_recontainments, cause_act_ref) do
      nil ->
        :ok

      %{cause_key: ^cause_key, disposition_act_ref: ^disposition_act_ref} ->
        :ok

      _invalid ->
        {:error, {:meter_recontainment_not_resolved, cause_act_ref}}
    end
  end

  defp validate_resolution(_projection, :settle, _supporting, _cause_act, _duty, _committed_at),
    do: :ok

  defp validate_resolution(projection, :release, supporting, cause_act, duty, committed_at) do
    proven? =
      Enum.any?(supporting, fn
        {:outcome, %{status: :definitive_no_effect} = outcome} ->
          outcome.act_ref == cause_act.ref and
            (is_nil(duty.attempt_ref) or outcome.attempt_ref == duty.attempt_ref) and
            Disposal.outcome_not_corrected_at?(projection, outcome, committed_at)

        _other ->
          false
      end)

    if proven? do
      :ok
    else
      {:error, :duty_meter_release_not_proven}
    end
  end

  defp resolved_status(:settle), do: :settled
  defp resolved_status(:release), do: :released

  defp duty_open(%Duty{status: :open}), do: :ok
  defp duty_open(%Duty{cause_key: cause_key}), do: {:error, {:duty_disposed, cause_key}}
end
