defmodule Spectre.GovernedAct.Integrity do
  @moduledoc """
  Whole-history invariants for a folded Governed Act ledger.

  `Spectre.GovernedAct.Fold` rejects invalid transitions while replaying each
  event and batch. This module checks properties that only become meaningful
  once a complete prefix and an explicit observation time are available:
  foundation completeness, unresolved causal debt, expired dispatches and
  conservation of Meter accounts.

  The module is pure. It is shared by audit and can be reused by recovery
  diagnostics without making either path trust a live runtime process.
  """

  alias Spectre.{Constitution, Duty}
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{DispatchState, Emergency, Fold, State}
  alias Spectre.Kernel.Meter
  alias Spectre.Validation

  @doc "Validates a complete folded prefix at trusted observation time."
  @spec validate(State.t(), non_neg_integer()) :: :ok | {:error, term()}
  def validate(%State{} = state, observed_at)
      when is_integer(observed_at) and observed_at >= 0 do
    with :ok <- Fold.validate_complete(state),
         :ok <- complete_foundation(state),
         :ok <- complete_dispatch_expirations(state, observed_at),
         :ok <- complete_required_duties(state, observed_at) do
      meters_conserved(state)
    end
  end

  def validate(_state, _observed_at),
    do: {:error, :invalid_governed_integrity_input}

  defp complete_foundation(%State{catalog: %{genesis: nil}}),
    do: {:error, :genesis_missing}

  defp complete_foundation(state) do
    required_principals = MapSet.new(state.catalog.genesis.principal_refs)
    actual_principals = state.catalog.principals |> Map.keys() |> MapSet.new()

    required_mandates =
      [state.catalog.genesis.emergency_mandate_ref | state.catalog.genesis.root_mandate_refs]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    restricted_refs = state.mandate_successors |> Map.values() |> MapSet.new()

    actual_roots =
      state.mandates
      |> Enum.filter(fn {ref, mandate} ->
        is_nil(mandate.parent_ref) and not MapSet.member?(restricted_refs, ref)
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    cond do
      is_nil(State.host_profile(state)) ->
        {:error, :host_profile_missing}

      is_nil(State.surface(state)) ->
        {:error, :surface_missing}

      not MapSet.subset?(required_principals, actual_principals) ->
        {:error, {:genesis_principals_incomplete, MapSet.to_list(required_principals)}}

      required_mandates != actual_roots ->
        {:error, {:genesis_root_mandates_incomplete, MapSet.to_list(required_mandates)}}

      true ->
        with :ok <- complete_constitution(state),
             do: complete_emergency_mandate(state)
    end
  end

  defp complete_constitution(state) do
    known_authorities = Map.keys(state.catalog.principals) ++ Map.keys(state.mandates)

    with {:ok, constitution_ref} <- Constitution.ref(state.constitution),
         true <- constitution_ref == state.catalog.genesis.constitution_ref,
         :ok <- Constitution.validate_duty_routes(state.constitution, known_authorities) do
      :ok
    else
      false -> {:error, :genesis_constitution_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp complete_emergency_mandate(state),
    do: Emergency.validate(state.catalog.genesis, state.mandates, state.constitution)

  defp complete_dispatch_expirations(state, observed_at) do
    case DispatchState.expired(state, observed_at) do
      {:ok, []} -> :ok
      {:ok, [{act, _mandate} | _rest]} -> {:error, {:dispatch_expiration_not_recorded, act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp complete_required_duties(state, observed_at) do
    state
    |> Derive.required_duties(observed_at)
    |> Validation.all(fn cause ->
      case Map.fetch(state.duties, cause.cause_key) do
        {:ok, %Duty{} = actual} ->
          validate_required_duty(cause, actual, observed_at)

        :error ->
          {:error, {:required_duty_not_materialized, cause.cause_key}}
      end
    end)
  end

  defp validate_required_duty(cause, actual, observed_at) do
    case cause |> Derive.materialization_attrs(observed_at) |> Duty.new() do
      {:ok, expected} ->
        if Duty.same_cause?(actual, expected),
          do: :ok,
          else: {:error, {:duty_cause_materialization_mismatch, actual.ref}}

      {:error, reason} ->
        {:error, {:invalid_required_duty, cause.cause_key, reason}}
    end
  end

  defp meters_conserved(state) do
    Validation.all(state.meters, fn {mandate_ref, accounts} ->
      Validation.all(accounts, &validate_meter_account(mandate_ref, &1))
    end)
  end

  defp validate_meter_account(mandate_ref, {meter_ref, account}) do
    case Meter.validate(account) do
      :ok -> :ok
      {:error, reason} -> {:error, {:meter_invalid, mandate_ref, meter_ref, reason}}
    end
  end
end
