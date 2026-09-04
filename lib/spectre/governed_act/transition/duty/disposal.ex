defmodule Spectre.GovernedAct.Transition.Duty.Disposal do
  @moduledoc """
  Validates the governed Act that closes an open Duty.

  Supporting records must exist at the disposition time, Evidence must be
  frozen into the Act and still available, and discretionary closure must pass
  the Duty's independent-authority rule. This module proves closure; it does
  not mutate the projection or move Meter balances.
  """

  alias Spectre.{Act, Condition, Duty}
  alias Spectre.Duty.{Authority, Disposition}
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Recognition
  alias Spectre.Scope.Opening

  @type supporting_record ::
          {:evidence, Spectre.Evidence.t()}
          | {:outcome, Spectre.Outcome.t()}
          | {:act, Act.t()}

  @doc false
  @spec validate(State.t(), Act.t(), Duty.t(), Disposition.t()) ::
          {:ok, [supporting_record()]} | {:error, term()}
  def validate(%State{} = projection, %Act{} = act, %Duty{} = duty, %Disposition{} = disposition) do
    with :ok <- validate_act(act, duty),
         :ok <- validate_binding(duty, disposition),
         {:ok, supporting} <- supporting_records(projection, disposition, act),
         :ok <- validate_authority(projection, act, duty, disposition),
         :ok <- validate_basis(projection, act, duty, disposition, supporting) do
      {:ok, supporting}
    end
  end

  @doc false
  @spec outcome_not_corrected_at?(State.t(), Spectre.Outcome.t(), integer()) :: boolean()
  def outcome_not_corrected_at?(%State{} = projection, outcome, committed_at) do
    not Enum.any?(projection.outcomes, fn {_ref, candidate} ->
      candidate.contradicts_outcome_ref == outcome.ref and candidate.observed_at <= committed_at
    end)
  end

  defp validate_authority(_projection, _act, _duty, %Disposition{kind: :condition_met}),
    do: :ok

  defp validate_authority(projection, act, duty, disposition) do
    if Disposition.discretionary?(disposition) do
      Authority.validate(
        duty,
        act,
        cause_act(projection, duty),
        projection.principals,
        projection.mandates
      )
    else
      :ok
    end
  end

  defp cause_act(projection, %Duty{act_ref: act_ref}) when is_binary(act_ref),
    do: Map.get(projection.acts, act_ref)

  defp cause_act(
         projection,
         %Duty{class: :scope_promise_overdue, cause_key: {:scope_promise_overdue, scope_ref}}
       ) do
    case Map.get(projection.scopes, scope_ref) do
      %Opening{source_act_ref: act_ref} -> Map.get(projection.acts, act_ref)
      _missing -> nil
    end
  end

  defp cause_act(_projection, %Duty{}), do: nil

  defp validate_act(act, duty) do
    cond do
      act.class != "duty.dispose" ->
        {:error, {:duty_disposition_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:duty_disposition_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:duty_disposition_act_has_reservations, act.ref}}

      not Act.targets?(act, [duty.ref]) ->
        {:error, {:duty_disposition_target_missing, act.ref, duty.ref}}

      act.ref == duty.act_ref ->
        {:error, {:duty_cause_act_cannot_dispose, duty.ref, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_binding(duty, disposition) do
    cond do
      disposition.duty_ref != duty.ref ->
        {:error, {:duty_disposition_ref_mismatch, duty.ref, disposition.duty_ref}}

      disposition.cause_key != duty.cause_key ->
        {:error, {:duty_disposition_cause_mismatch, duty.ref}}

      disposition.opening_digest != Duty.digest(duty) ->
        {:error, {:duty_disposition_opening_mismatch, duty.ref}}

      true ->
        :ok
    end
  end

  defp supporting_records(projection, disposition, act) do
    Enum.reduce_while(disposition.supporting_refs, {:ok, []}, fn ref, {:ok, records} ->
      case supporting_record(projection, ref) do
        {:ok, record} ->
          with :ok <- support_frozen_and_available(projection, act, ref, record),
               true <- support_available_at?(record, act.committed_at) do
            {:cont, {:ok, [record | records]}}
          else
            false -> {:halt, {:error, {:duty_disposition_support_from_future, ref}}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp support_frozen_and_available(projection, act, ref, {:evidence, _evidence}) do
    if ref in act.evidence_refs,
      do: ErasureAnalysis.validate_evidence_available(projection, [ref]),
      else: {:error, {:duty_disposition_evidence_not_frozen, act.ref, ref}}
  end

  defp support_frozen_and_available(_projection, _act, _ref, {_kind, _record}), do: :ok

  defp supporting_record(projection, ref) do
    matches =
      [
        {:evidence, Map.get(projection.evidence, ref)},
        {:outcome, Map.get(projection.outcomes, ref)},
        {:act, Map.get(projection.acts, ref)}
      ]
      |> Enum.reject(fn {_kind, record} -> is_nil(record) end)

    case matches do
      [record] -> {:ok, record}
      [] -> {:error, {:duty_disposition_support_not_found, ref}}
      _collision -> {:error, {:duty_disposition_support_ambiguous, ref}}
    end
  end

  defp support_available_at?({:evidence, evidence}, committed_at),
    do: evidence.observed_at <= committed_at

  defp support_available_at?({:outcome, outcome}, committed_at),
    do: outcome.observed_at <= committed_at

  defp support_available_at?({:act, act}, committed_at),
    do: act.committed_at <= committed_at

  defp validate_basis(
         projection,
         act,
         duty,
         %Disposition{kind: :condition_met},
         supporting
       ) do
    if Enum.any?(
         duty.closing_conditions,
         &closing_condition_met?(projection, &1, supporting, act.committed_at)
       ) do
      :ok
    else
      {:error, {:duty_closing_condition_not_met, duty.ref}}
    end
  end

  defp validate_basis(_projection, act, duty, disposition, _supporting) do
    if Disposition.discretionary?(disposition),
      do: :ok,
      else: {:error, {:invalid_duty_disposition_kind, disposition.kind, act.ref, duty.ref}}
  end

  defp closing_condition_met?(
         projection,
         %{"kind" => :definitive_outcome, "attempt_ref" => attempt_ref} = condition,
         supporting,
         committed_at
       )
       when map_size(condition) == 2 do
    Enum.any?(supporting, fn
      {:outcome, outcome} ->
        outcome.attempt_ref == attempt_ref and
          outcome.status in [:succeeded, :failed, :definitive_no_effect] and
          outcome.observed_at <= committed_at and
          outcome_not_corrected_at?(projection, outcome, committed_at)

      _other ->
        false
    end)
  end

  defp closing_condition_met?(projection, condition, supporting, committed_at) do
    available_evidence = projection |> ErasureAnalysis.available_evidence() |> Map.values()
    supporting_refs = for {:evidence, item} <- supporting, do: item.ref

    with {:ok, condition} <- Condition.new(condition),
         {:satisfied, basis_refs} <-
           Recognition.check_with_basis([condition], available_evidence, committed_at) do
      basis_refs -- supporting_refs == []
    else
      _not_satisfied_or_invalid -> false
    end
  end
end
