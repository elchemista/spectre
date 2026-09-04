defmodule Spectre.GovernedAct.Completeness do
  @moduledoc """
  Structural invariants over a completely folded ledger prefix.

  Event transition rules belong to `Spectre.GovernedAct.Fold`. These checks
  cover relationships that require the complete prefix: every admitted
  Decision has one Act, every Act has a coherent dispatch/reservation state,
  restriction indexes are acyclic, and logical Meter owners remain complete.
  """

  alias Spectre.{Act, Attempt, Outcome}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{DispatchState, MeterState, State}

  @doc "Validates relationships that cannot be closed over a single event."
  @spec validate(State.t()) :: :ok | {:error, term()}
  def validate(%State{} = state) do
    with :ok <- complete_admissions(state),
         :ok <- complete_reservations(state),
         :ok <- complete_dispatches(state),
         :ok <- complete_suspensions(state),
         :ok <- complete_meter_recontainments(state),
         :ok <- complete_mandate_restrictions(state),
         :ok <- complete_meter_ownership(state) do
      complete_declassifications(state)
    end
  end

  def validate(_state), do: {:error, :invalid_governed_fold}

  defp complete_admissions(state) do
    acts_by_decision = Enum.group_by(state.acts, fn {_ref, act} -> act.decision_ref end)

    if map_size(state.admissions) == map_size(state.decisions) do
      Enum.reduce_while(state.decisions, :ok, fn {_ref, decision}, :ok ->
        acts = Map.get(acts_by_decision, decision.ref, [])
        admission = Map.get(state.admissions, decision.candidate_identity_key)

        case {decision.outcome, acts, admission} do
          {:admitted, [{act_ref, _act}], %{decision_ref: decision_ref, act_ref: act_ref}}
          when decision_ref == decision.ref ->
            {:cont, :ok}

          {:admitted, _acts, _admission} ->
            {:halt, {:error, {:incomplete_admitted_decision, decision.ref}}}

          {_other, [], %{decision_ref: decision_ref, act_ref: nil}}
          when decision_ref == decision.ref ->
            {:cont, :ok}

          {_other, _acts, _admission} ->
            {:halt, {:error, {:non_admitted_decision_has_act, decision.ref}}}
        end
      end)
    else
      {:error, :admission_index_size_mismatch}
    end
  end

  defp complete_reservations(state) do
    with :ok <- complete_act_reservations(state) do
      Enum.reduce_while(state.meter_reservations, :ok, fn {act_ref, _status}, :ok ->
        case MeterState.reservation(state, act_ref) do
          {:ok, _reservation} -> {:cont, :ok}
          {:error, _reason} -> {:halt, {:error, {:invalid_meter_reservation, act_ref}}}
        end
      end)
    end
  end

  defp complete_act_reservations(state) do
    Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
      cond do
        Act.reservations?(act) and not Map.has_key?(state.meter_reservations, act.ref) ->
          {:halt, {:error, {:act_reservation_not_recorded, act.ref}}}

        DispatchState.cancelled?(state, act.ref) and Act.reservations?(act) and
            MeterState.reservation_status(state, act.ref) != :released ->
          {:halt, {:error, {:cancelled_dispatch_reservation_not_released, act.ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp complete_dispatches(state) do
    with :ok <- complete_dispatch_index_refs(state),
         :ok <- complete_act_dispatch_states(state) do
      complete_attempt_dispatches(state)
    end
  end

  defp complete_dispatch_index_refs(state) do
    refs = MapSet.union(state.pending_dispatches, MapSet.new(Map.keys(state.terminal_dispatches)))

    case Enum.find(refs, &(not Map.has_key?(state.acts, &1))) do
      nil -> :ok
      act_ref -> {:error, {:dispatch_act_not_found, act_ref}}
    end
  end

  defp complete_act_dispatch_states(state) do
    Enum.reduce_while(state.acts, :ok, fn {act_ref, act}, :ok ->
      dispatch = {DispatchState.pending?(state, act_ref), DispatchState.terminal(state, act_ref)}

      valid? =
        case {GovernedExecution.executor_mediated?(act), dispatch} do
          {false, {false, nil}} -> true
          {true, {true, nil}} -> true
          {true, {false, {:attempt, attempt_ref}}} -> valid_attempt?(state, act_ref, attempt_ref)
          {true, {false, {:cancelled, cancellation}}} -> valid_cancellation?(cancellation)
          _missing_conflicting_or_invalid -> false
        end

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_act_dispatch_state, act_ref, dispatch}}}
    end)
  end

  defp complete_attempt_dispatches(state) do
    Enum.reduce_while(state.attempts, :ok, fn {attempt_ref, attempt}, :ok ->
      if match?(%Attempt{ref: ^attempt_ref}, attempt) and
           DispatchState.attempt_ref(state, attempt.act_ref) == attempt_ref do
        {:cont, :ok}
      else
        {:halt, {:error, {:attempt_dispatch_binding_mismatch, attempt_ref}}}
      end
    end)
  end

  defp valid_attempt?(state, act_ref, attempt_ref) do
    match?(%Attempt{ref: ^attempt_ref, act_ref: ^act_ref}, Map.get(state.attempts, attempt_ref))
  end

  defp valid_cancellation?(cancellation) do
    match?(
      %{
        cause_ref: cause_ref,
        reason: reason,
        cancelled_at: cancelled_at
      }
      when is_binary(cause_ref) and cause_ref != "" and
             reason in [
               :mandate_revoked,
               :mandate_restricted,
               :mandate_expired,
               :disputed_evidence
             ] and
             is_integer(cancelled_at) and cancelled_at >= 0,
      cancellation
    ) and map_size(cancellation) == 3
  end

  defp complete_suspensions(state) do
    duty_act_refs = state.duties |> Map.values() |> MapSet.new(& &1.act_ref)

    Enum.reduce_while(state.meter_reservations, :ok, fn
      {act_ref, :suspended}, :ok ->
        if MapSet.member?(duty_act_refs, act_ref),
          do: {:cont, :ok},
          else: {:halt, {:error, {:suspended_reservation_without_duty, act_ref}}}

      {_act_ref, _reservation}, :ok ->
        {:cont, :ok}
    end)
  end

  defp complete_meter_recontainments(state) do
    with :ok <- validate_recontainment_records(state) do
      state.outcomes
      |> Map.values()
      |> Enum.filter(&requires_recontainment?(state, &1))
      |> Enum.reduce_while(:ok, fn outcome, :ok ->
        if Map.has_key?(state.meter_recontainments, outcome.act_ref),
          do: {:cont, :ok},
          else: {:halt, {:error, {:missing_meter_recontainment, outcome.ref}}}
      end)
    end
  end

  defp validate_recontainment_records(state) do
    Enum.reduce_while(state.meter_recontainments, :ok, fn {act_ref, record}, :ok ->
      outcome = Map.get(state.outcomes, record.outcome_ref)
      duty = Map.get(state.duties, record.cause_key)

      valid? =
        case MeterState.reservation(state, act_ref) do
          {:ok, reservation} ->
            match?(%Outcome{act_ref: ^act_ref}, outcome) and
              Outcome.correction?(outcome) and
              reservation.mandate_ref == outcome_mandate_ref(state, outcome) and
              recontainment_record_complete?(record, duty, reservation.status)

          {:error, _reason} ->
            false
        end

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:incomplete_meter_recontainment, act_ref}}}
    end)
  end

  defp recontainment_record_complete?(record, %{status: :open}, :suspended),
    do: is_nil(record.disposition_act_ref)

  defp recontainment_record_complete?(record, %{status: :disposed} = duty, status)
       when status in [:settled, :released],
       do: record.disposition_act_ref == duty.disposition_act_ref

  defp recontainment_record_complete?(_record, _duty, _status), do: false

  defp requires_recontainment?(state, %Outcome{} = outcome) do
    case Map.get(state.acts, outcome.act_ref) do
      %Act{reservations: reservations} when map_size(reservations) > 0 ->
        Outcome.correction?(outcome)

      _other ->
        false
    end
  end

  defp complete_mandate_restrictions(state) do
    with {:ok, predecessors} <- restriction_predecessors(state.mandate_successors),
         :ok <- complete_successor_links(state),
         :ok <- complete_restricted_mandates(state, predecessors),
         :ok <- complete_restriction_acts(state, predecessors) do
      acyclic_successions(state.mandate_successors)
    end
  end

  defp restriction_predecessors(successors) do
    Enum.reduce_while(successors, {:ok, %{}}, fn {predecessor_ref, successor_ref},
                                                 {:ok, predecessors} ->
      if Map.has_key?(predecessors, successor_ref) do
        {:halt, {:error, {:mandate_already_has_predecessor, successor_ref}}}
      else
        {:cont, {:ok, Map.put(predecessors, successor_ref, predecessor_ref)}}
      end
    end)
  end

  defp complete_successor_links(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        valid? =
          Map.has_key?(state.mandates, predecessor_ref) and
            Map.has_key?(state.mandates, successor_ref)

        if valid?,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_restricted_mandates(state, predecessors) do
    Enum.reduce_while(state.mandates, :ok, fn {ref, mandate}, :ok ->
      predecessor_ref = Map.get(predecessors, ref)

      cond do
        mandate.revision == 1 and is_nil(predecessor_ref) -> {:cont, :ok}
        mandate.revision > 1 and is_binary(predecessor_ref) -> {:cont, :ok}
        true -> {:halt, {:error, {:mandate_revision_lineage_incomplete, ref, mandate.revision}}}
      end
    end)
  end

  defp complete_restriction_acts(state, predecessors) do
    restrictions_by_act =
      predecessors
      |> Map.keys()
      |> Enum.map(&Map.fetch!(state.mandates, &1).source_ref)
      |> Enum.frequencies()

    state.acts
    |> Map.values()
    |> Enum.filter(&(&1.class == "mandate.restrict"))
    |> Enum.reduce_while(:ok, fn act, :ok ->
      if Map.get(restrictions_by_act, act.ref, 0) == 1,
        do: {:cont, :ok},
        else: {:halt, {:error, {:mandate_restriction_act_incomplete, act.ref}}}
    end)
  end

  defp acyclic_successions(successors) do
    Enum.reduce_while(Map.keys(successors), :ok, fn ref, :ok ->
      if succession_cycle?(successors, ref, MapSet.new()),
        do: {:halt, {:error, {:mandate_restriction_cycle, ref}}},
        else: {:cont, :ok}
    end)
  end

  defp succession_cycle?(successors, ref, visited) do
    cond do
      MapSet.member?(visited, ref) -> true
      is_nil(Map.get(successors, ref)) -> false
      true -> succession_cycle?(successors, Map.fetch!(successors, ref), MapSet.put(visited, ref))
    end
  end

  defp complete_meter_ownership(state) do
    mandate_refs = state.mandates |> Map.keys() |> MapSet.new()
    physical_owners = state.meters |> Map.keys() |> MapSet.new()
    aliases = state.meter_owner_aliases |> Map.keys() |> MapSet.new()

    with true <- MapSet.disjoint?(physical_owners, aliases),
         true <- MapSet.union(physical_owners, aliases) == mandate_refs,
         :ok <- complete_meter_owner_refs(state) do
      complete_restriction_meter_owners(state)
    else
      false -> {:error, :mandate_meter_ownership_incomplete}
      {:error, _reason} = error -> error
    end
  end

  defp complete_meter_owner_refs(state) do
    Enum.reduce_while(state.mandates, :ok, fn {mandate_ref, _mandate}, :ok ->
      valid? =
        case Map.fetch(state.meter_owner_aliases, mandate_ref) do
          :error ->
            Map.has_key?(state.meters, mandate_ref)

          {:ok, owner_ref} ->
            owner_ref != mandate_ref and Map.has_key?(state.mandates, owner_ref) and
              Map.has_key?(state.meters, owner_ref) and
              not Map.has_key?(state.meter_owner_aliases, owner_ref)
        end

      if valid?,
        do: {:cont, :ok},
        else:
          {:halt,
           {:error,
            {:invalid_mandate_meter_owner, mandate_ref,
             Map.get(state.meter_owner_aliases, mandate_ref)}}}
    end)
  end

  defp complete_restriction_meter_owners(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        with {:ok, predecessor_owner} <- MeterState.owner(state, predecessor_ref),
             {:ok, successor_owner} <- MeterState.owner(state, successor_ref),
             true <- predecessor_owner == successor_owner do
          {:cont, :ok}
        else
          _mismatch_or_missing ->
            {:halt,
             {:error, {:mandate_restriction_meter_owner_mismatch, predecessor_ref, successor_ref}}}
        end
    end)
  end

  defp complete_declassifications(state) do
    with {:ok, records_by_act} <- index_declassifications_by_act(state.declassifications),
         :ok <- validate_declassification_indexes(state, records_by_act) do
      Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
        if act.class != "data.declassify" or
             Map.has_key?(records_by_act, act.ref),
           do: {:cont, :ok},
           else: {:halt, {:error, {:declassification_act_incomplete, act.ref}}}
      end)
    end
  end

  defp index_declassifications_by_act(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn {ref, record}, {:ok, by_act} ->
      if Map.has_key?(by_act, record.source_act_ref) do
        {:halt, {:error, {:duplicate_declassification_act, record.source_act_ref}}}
      else
        {:cont, {:ok, Map.put(by_act, record.source_act_ref, ref)}}
      end
    end)
  end

  defp validate_declassification_indexes(state, records_by_act) do
    Enum.reduce_while(state.declassifications, :ok, fn {ref, record}, :ok ->
      valid? =
        records_by_act[record.source_act_ref] == ref and
          state.declassifications_by_evidence[record.evidence_ref] == ref and
          Map.has_key?(state.evidence, record.evidence_ref)

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:incomplete_declassification, ref}}}
    end)
  end

  defp outcome_mandate_ref(state, %Outcome{act_ref: act_ref}) do
    case Map.get(state.acts, act_ref) do
      %Act{mandate_ref: mandate_ref} -> mandate_ref
      _other -> nil
    end
  end
end
