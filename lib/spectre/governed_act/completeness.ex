defmodule Spectre.GovernedAct.Completeness do
  @moduledoc """
  Structural invariants over a completely folded ledger prefix.

  Event transition rules belong to `Spectre.GovernedAct.Fold`. These checks
  cover relationships that require the complete prefix: every admitted
  Decision has one Act, every Act has a coherent dispatch/reservation state,
  restriction indexes are acyclic, and logical Meter owners remain complete.
  """

  alias Spectre.{Act, Governance, Outcome}
  alias Spectre.GovernedAct.State

  @doc "Validates relationships that cannot be closed over a single event."
  @spec validate(State.t()) :: :ok | {:error, term()}
  def validate(%State{} = state) do
    with :ok <- complete_admissions(state),
         :ok <- complete_reservations(state),
         :ok <- complete_suspensions(state),
         :ok <- complete_meter_recontainments(state),
         :ok <- complete_mandate_restrictions(state),
         :ok <- complete_meter_ownership(state) do
      complete_declassifications(state)
    end
  end

  def validate(_state), do: {:error, :invalid_governed_fold}

  defp complete_admissions(state) do
    acts_by_decision = Enum.frequencies_by(state.acts, fn {_ref, act} -> act.decision_ref end)

    Enum.reduce_while(state.decisions, :ok, fn {_ref, decision}, :ok ->
      act_count = Map.get(acts_by_decision, decision.ref, 0)

      case {decision.outcome, act_count} do
        {:admitted, 1} -> {:cont, :ok}
        {:admitted, _count} -> {:halt, {:error, {:incomplete_admitted_decision, decision.ref}}}
        {_other, 0} -> {:cont, :ok}
        {_other, _count} -> {:halt, {:error, {:non_admitted_decision_has_act, decision.ref}}}
      end
    end)
  end

  defp complete_reservations(state) do
    Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
      cond do
        Act.reservations?(act) and not Map.has_key?(state.reservation_states, act.ref) ->
          {:halt, {:error, {:act_reservation_not_recorded, act.ref}}}

        Governance.executor_mediated?(act) and
          not Map.has_key?(state.attempts_by_act, act.ref) and
          not MapSet.member?(state.dispatch_ready, act.ref) and
            not Map.has_key?(state.dispatch_cancellations, act.ref) ->
          {:halt, {:error, {:act_dispatch_state_missing, act.ref}}}

        Map.has_key?(state.dispatch_cancellations, act.ref) and Act.reservations?(act) and
            Map.get(state.reservation_states, act.ref) != :released ->
          {:halt, {:error, {:cancelled_dispatch_reservation_not_released, act.ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp complete_suspensions(state) do
    duty_act_refs = state.duties |> Map.values() |> MapSet.new(& &1.act_ref)

    Enum.reduce_while(state.reservation_states, :ok, fn
      {act_ref, :suspended}, :ok ->
        if MapSet.member?(duty_act_refs, act_ref),
          do: {:cont, :ok},
          else: {:halt, {:error, {:suspended_reservation_without_duty, act_ref}}}

      {_act_ref, _status}, :ok ->
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
      reservation_status = Map.get(state.reservation_states, act_ref)

      valid? =
        record.act_ref == act_ref and
          match?(%Outcome{act_ref: ^act_ref}, outcome) and
          Outcome.correction?(outcome) and
          record.mandate_ref == outcome_mandate_ref(state, outcome) and
          recontainment_record_complete?(record, duty, reservation_status)

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:incomplete_meter_recontainment, act_ref}}}
    end)
  end

  defp recontainment_record_complete?(record, %{status: :open}, :suspended),
    do: record.status == :open and is_nil(record.disposition_act_ref)

  defp recontainment_record_complete?(record, %{status: :disposed} = duty, status)
       when status in [:settled, :released],
       do: record.status == :disposed and record.disposition_act_ref == duty.disposition_act_ref

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
    with :ok <- complete_successor_links(state),
         :ok <- complete_predecessor_links(state),
         :ok <- complete_restricted_mandates(state),
         :ok <- complete_restriction_acts(state) do
      acyclic_successions(state.mandate_successors)
    end
  end

  defp complete_successor_links(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        valid? =
          Map.has_key?(state.mandates, predecessor_ref) and
            Map.has_key?(state.mandates, successor_ref) and
            Map.get(state.mandate_predecessors, successor_ref) == predecessor_ref

        if valid?,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_predecessor_links(state) do
    Enum.reduce_while(state.mandate_predecessors, :ok, fn
      {successor_ref, predecessor_ref}, :ok ->
        if Map.get(state.mandate_successors, predecessor_ref) == successor_ref,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_links_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_restricted_mandates(state) do
    Enum.reduce_while(state.mandates, :ok, fn {ref, mandate}, :ok ->
      predecessor_ref = Map.get(state.mandate_predecessors, ref)

      cond do
        mandate.revision == 1 and is_nil(predecessor_ref) -> {:cont, :ok}
        mandate.revision > 1 and is_binary(predecessor_ref) -> {:cont, :ok}
        true -> {:halt, {:error, {:mandate_revision_lineage_incomplete, ref, mandate.revision}}}
      end
    end)
  end

  defp complete_restriction_acts(state) do
    restrictions_by_act =
      state.mandate_predecessors
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
    physical_owners =
      state.meter_owners
      |> Enum.filter(fn {mandate_ref, owner_ref} -> mandate_ref == owner_ref end)
      |> MapSet.new(&elem(&1, 0))

    actual_accounts = state.meters |> Map.keys() |> MapSet.new()

    with true <- map_size(state.meter_owners) == map_size(state.mandates),
         true <- physical_owners == actual_accounts,
         :ok <- complete_meter_owner_refs(state) do
      complete_restriction_meter_owners(state)
    else
      false -> {:error, :mandate_meter_ownership_incomplete}
      {:error, _reason} = error -> error
    end
  end

  defp complete_meter_owner_refs(state) do
    Enum.reduce_while(state.mandates, :ok, fn {mandate_ref, _mandate}, :ok ->
      owner_ref = Map.get(state.meter_owners, mandate_ref)

      valid? =
        is_binary(owner_ref) and Map.has_key?(state.mandates, owner_ref) and
          Map.has_key?(state.meters, owner_ref) and state.meter_owners[owner_ref] == owner_ref

      if valid?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_mandate_meter_owner, mandate_ref, owner_ref}}}
    end)
  end

  defp complete_restriction_meter_owners(state) do
    Enum.reduce_while(state.mandate_successors, :ok, fn
      {predecessor_ref, successor_ref}, :ok ->
        if state.meter_owners[predecessor_ref] == state.meter_owners[successor_ref],
          do: {:cont, :ok},
          else:
            {:halt,
             {:error, {:mandate_restriction_meter_owner_mismatch, predecessor_ref, successor_ref}}}
    end)
  end

  defp complete_declassifications(state) do
    with :ok <- validate_declassification_indexes(state) do
      Enum.reduce_while(state.acts, :ok, fn {_ref, act}, :ok ->
        if act.class != "data.declassify" or
             Map.has_key?(state.declassifications_by_act, act.ref),
           do: {:cont, :ok},
           else: {:halt, {:error, {:declassification_act_incomplete, act.ref}}}
      end)
    end
  end

  defp validate_declassification_indexes(state) do
    Enum.reduce_while(state.declassifications, :ok, fn {ref, record}, :ok ->
      valid? =
        state.declassifications_by_act[record.source_act_ref] == ref and
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
