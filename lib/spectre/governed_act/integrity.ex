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

  alias Spectre.{Act, Constitution, Duty, Genesis, Mandate, Outcome}
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{DispatchState, Fold, State}
  alias Spectre.Kernel.Meter

  @duty_causal_fields [
    :schema_version,
    :ref,
    :cause_key,
    :class,
    :act_ref,
    :attempt_ref,
    :mandate_ref,
    :subjects,
    :accountable,
    :evidence_refs,
    :missing,
    :containment,
    :closing_conditions,
    :disposition_authority_refs,
    :conflict_refs,
    :opened_at
  ]

  @doc "Validates a complete folded prefix at trusted observation time."
  @spec validate(State.t(), non_neg_integer()) :: :ok | {:error, term()}
  def validate(%State{} = state, observed_at)
      when is_integer(observed_at) and observed_at >= 0 do
    with :ok <- Fold.validate_complete(state),
         :ok <- complete_foundation(state),
         :ok <- complete_uncertain_outcomes(state),
         :ok <- complete_erasure_duties(state),
         :ok <- complete_dispatch_expirations(state, observed_at),
         :ok <- complete_required_duties(state, observed_at) do
      meters_conserved(state)
    end
  end

  def validate(_state, _observed_at),
    do: {:error, :invalid_governed_integrity_input}

  defp complete_foundation(%State{genesis: nil}),
    do: {:error, :genesis_missing}

  defp complete_foundation(state) do
    required_principals = MapSet.new(state.genesis.principal_refs)
    actual_principals = state.principals |> Map.keys() |> MapSet.new()

    required_mandates =
      [state.genesis.emergency_mandate_ref | state.genesis.root_mandate_refs]
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
    known_authorities = Map.keys(state.principals) ++ Map.keys(state.mandates)

    with {:ok, constitution_ref} <- Constitution.ref(state.constitution),
         true <- constitution_ref == state.genesis.constitution_ref,
         :ok <- Constitution.validate_duty_routes(state.constitution, known_authorities) do
      :ok
    else
      false -> {:error, :genesis_constitution_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp complete_emergency_mandate(%State{genesis: %Genesis{emergency_mandate_ref: nil}}),
    do: :ok

  defp complete_emergency_mandate(state) do
    with {:ok, mandate} <-
           fetch(state.mandates, state.genesis.emergency_mandate_ref, :emergency_mandate),
         {:ok, maximum_duration} <- Constitution.emergency_max_duration(state.constitution) do
      forbidden =
        MapSet.new(
          ~w(mandate.delegate mandate.restrict surface.revise host_profile.revise definition.revise)
        )

      cond do
        mandate.delegation != %{"allowed" => false, "max_depth" => 0} ->
          {:error, :emergency_mandate_may_not_delegate}

        Enum.any?(mandate.classes, &MapSet.member?(forbidden, &1)) ->
          {:error, :emergency_mandate_may_not_rewrite_exception}

        mandate.expires_at - mandate.not_before > maximum_duration ->
          {:error, :emergency_mandate_duration_exceeded}

        true ->
          :ok
      end
    end
  end

  defp complete_uncertain_outcomes(state) do
    state.outcomes
    |> Map.values()
    |> Enum.filter(&(&1.status == :ambiguous or Outcome.correction?(&1)))
    |> Enum.reduce_while(:ok, fn outcome, :ok ->
      cause_key =
        if Outcome.correction?(outcome),
          do: {:contradicted_outcome, outcome.act_ref, outcome.attempt_ref, outcome.ref},
          else: {:ambiguous_outcome, outcome.act_ref, outcome.attempt_ref}

      if Map.has_key?(state.duties, cause_key),
        do: {:cont, :ok},
        else: {:halt, {:error, {:uncertain_outcome_without_duty, outcome.ref}}}
    end)
  end

  defp complete_erasure_duties(state) do
    state.erasures
    |> Map.values()
    |> Enum.filter(& &1.reduces_verifiability)
    |> Enum.reduce_while(:ok, fn erasure, :ok ->
      succeeded =
        state.outcomes
        |> Map.values()
        |> Enum.find(&(&1.act_ref == erasure.source_act_ref and &1.status == :succeeded))

      if is_nil(succeeded) do
        {:cont, :ok}
      else
        cause_key =
          {:erasure_reduces_verifiability, erasure.ref, erasure.source_act_ref,
           succeeded.attempt_ref, succeeded.ref}

        if Map.has_key?(state.duties, cause_key),
          do: {:cont, :ok},
          else: {:halt, {:error, {:erasure_outcome_without_verifiability_duty, erasure.ref}}}
      end
    end)
  end

  defp complete_dispatch_expirations(state, observed_at) do
    state
    |> DispatchState.pending_refs()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn act_ref, :ok ->
      with {:ok, %Act{} = act} <- fetch(state.acts, act_ref, :act),
           {:ok, %Mandate{} = mandate} <- fetch(state.mandates, act.mandate_ref, :mandate),
           true <- act.mandate_revision == mandate.revision do
        if mandate.expires_at <= observed_at,
          do: {:halt, {:error, {:dispatch_expiration_not_recorded, act.ref}}},
          else: {:cont, :ok}
      else
        false -> {:halt, {:error, {:dispatch_expiration_mandate_mismatch, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp complete_required_duties(state, observed_at) do
    state
    |> Derive.required_duties(state.constitution, observed_at)
    |> Enum.reduce_while(:ok, fn cause, :ok ->
      case Map.fetch(state.duties, cause.cause_key) do
        {:ok, %Duty{} = actual} ->
          case cause |> Derive.materialization_attrs(observed_at) |> Duty.new() do
            {:ok, expected} ->
              if same_duty_cause?(actual, expected),
                do: {:cont, :ok},
                else: {:halt, {:error, {:duty_cause_materialization_mismatch, actual.ref}}}

            {:error, reason} ->
              {:halt, {:error, {:invalid_required_duty, cause.cause_key, reason}}}
          end

        :error ->
          {:halt, {:error, {:required_duty_not_materialized, cause.cause_key}}}
      end
    end)
  end

  defp same_duty_cause?(actual, expected) do
    Map.take(Map.from_struct(actual), @duty_causal_fields) ==
      Map.take(Map.from_struct(expected), @duty_causal_fields)
  end

  defp meters_conserved(state) do
    Enum.reduce_while(state.meters, :ok, fn {mandate_ref, accounts}, :ok ->
      case Enum.reduce_while(accounts, :ok, fn {meter_ref, account}, :ok ->
             case Meter.validate(account) do
               :ok ->
                 {:cont, :ok}

               {:error, reason} ->
                 {:halt, {:error, {:meter_invalid, mandate_ref, meter_ref, reason}}}
             end
           end) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch(collection, key, kind) do
    case Map.fetch(collection, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {kind, :not_found, key}}
    end
  end
end
