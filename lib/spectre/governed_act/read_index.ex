defmodule Spectre.GovernedAct.ReadIndex do
  @moduledoc """
  Rebuildable reference indexes for local reads of a governed prefix.

  Records remain in their single typed collection. These indexes select them
  by proposition, acquisition revision or payload reference without walking
  unrelated history. They contain no authority and are updated by the fold,
  including during independent replay.
  """

  alias Spectre.Erasure.Analysis

  defstruct duties: %Spectre.Duty.Frontier{},
            batches: MapSet.new(),
            evidence_by_proposition: %{},
            evidence_by_revision: :gb_trees.empty(),
            payload_refs: MapSet.new(),
            presentation_count: 0,
            outcome_count: 0,
            dispatch_deadlines: :gb_trees.empty()

  @type t :: %__MODULE__{}

  @doc false
  def record(state, %{type: "evidence_recorded", identity: ref, revision: revision}) do
    evidence = Map.fetch!(state.evidence, ref)
    index = state.read_index

    by_proposition =
      Map.update(
        index.evidence_by_proposition,
        evidence.proposition,
        MapSet.new([ref]),
        &MapSet.put(&1, ref)
      )

    index = %{
      index
      | evidence_by_proposition: by_proposition,
        evidence_by_revision: :gb_trees.enter(revision, ref, index.evidence_by_revision),
        payload_refs: put_payload(index.payload_refs, evidence.payload_ref)
    }

    %{state | read_index: index}
  end

  def record(state, %{type: "presentation_recorded", identity: ref}) do
    presentation = Map.fetch!(state.presentations, ref)
    index = state.read_index

    %{
      state
      | read_index: %{
          index
          | payload_refs: put_payload(index.payload_refs, presentation.rendered_payload_ref),
            presentation_count: map_size(state.presentations)
        }
    }
  end

  def record(state, %{type: "dispatch_ready", data: %{"act_ref" => ref}}) do
    key = dispatch_key(state, ref)
    index = state.read_index

    %{
      state
      | read_index: %{
          index
          | dispatch_deadlines: :gb_trees.enter(key, true, index.dispatch_deadlines)
        }
    }
  end

  def record(state, %{type: "outcome_recorded"}),
    do: %{state | read_index: %{state.read_index | outcome_count: map_size(state.outcomes)}}

  def record(state, %{type: "dispatch_cancelled", data: %{"act_ref" => ref}}),
    do: remove_dispatch(state, ref)

  def record(state, %{type: "attempt_started", identity: ref}),
    do: remove_dispatch(state, Map.fetch!(state.attempts, ref).act_ref)

  def record(state, _event), do: state

  @doc false
  def dispatch_indexed?(state),
    do:
      :gb_trees.size(state.read_index.dispatch_deadlines) == MapSet.size(state.pending_dispatches)

  @doc false
  def expired_dispatch_refs(state, time),
    do: expired(:gb_trees.iterator(state.read_index.dispatch_deadlines), time, [])

  @doc false
  def next_dispatch_deadline(state) do
    case :gb_trees.is_empty(state.read_index.dispatch_deadlines) do
      true ->
        nil

      false ->
        {{time, _ref}, _} = :gb_trees.smallest(state.read_index.dispatch_deadlines)
        time
    end
  end

  defp expired(iterator, time, refs) do
    case :gb_trees.next(iterator) do
      {{due, ref}, _, next} when due <= time -> expired(next, time, [ref | refs])
      _future_or_empty -> Enum.sort(refs)
    end
  end

  defp dispatch_key(state, ref) do
    act = Map.fetch!(state.acts, ref)
    {Map.fetch!(state.mandates, act.mandate_ref).expires_at, ref}
  end

  defp remove_dispatch(state, ref) do
    index = state.read_index

    %{
      state
      | read_index: %{
          index
          | dispatch_deadlines:
              :gb_trees.delete_any(dispatch_key(state, ref), index.dispatch_deadlines)
        }
    }
  end

  @doc "Selects all potentially relevant proof and counterproof, including recursive assumptions."
  def evidence_for(state, conditions) do
    propositions = Enum.map(conditions || [], & &1.proposition)

    if complete?(state) do
      selected = collect(propositions, state, MapSet.new(), MapSet.new())
      unavailable = Analysis.unavailable_evidence_refs(state)

      selected
      |> MapSet.difference(unavailable)
      |> Enum.map(&Map.fetch!(state.evidence, &1))
      |> Enum.sort_by(& &1.ref)
    else
      # Pure callers can assemble a State without running a ledger fold.
      # An absent index must never hide a counterproof in that input.
      state |> Analysis.available_evidence() |> Map.values()
    end
  end

  @doc false
  def complete?(state),
    do:
      :gb_trees.size(state.read_index.evidence_by_revision) == map_size(state.evidence) and
        state.read_index.presentation_count == map_size(state.presentations)

  @doc false
  def outcomes_for(state, kind, ref) when kind in [:act, :attempt] do
    if state.read_index.outcome_count == map_size(state.outcomes) do
      index =
        if kind == :act,
          do: state.read_index.duties.outcomes_by_act,
          else: state.read_index.duties.outcomes_by_attempt

      refs = index |> Map.get(ref, MapSet.new()) |> MapSet.to_list()
      Map.take(state.outcomes, refs)
    else
      state.outcomes
    end
  end

  @doc "Returns Evidence acquired in the last N ledger positions, newest first."
  def recent_evidence(state, max_events) do
    first = max(state.revision - max_events + 1, 1)
    iterator = :gb_trees.iterator_from(first, state.read_index.evidence_by_revision)
    recent(iterator, state.evidence, [])
  end

  defp recent(iterator, records, acc) do
    case :gb_trees.next(iterator) do
      :none -> acc
      {_revision, ref, iterator} -> recent(iterator, records, [Map.fetch!(records, ref) | acc])
    end
  end

  defp collect([], _state, _seen, selected), do: selected

  defp collect([proposition | rest], state, seen, selected) do
    if MapSet.member?(seen, proposition) do
      collect(rest, state, seen, selected)
    else
      refs = Map.get(state.read_index.evidence_by_proposition, proposition, MapSet.new())
      assumptions = Enum.flat_map(refs, &Map.fetch!(state.evidence, &1).assumptions)

      collect(
        assumptions ++ rest,
        state,
        MapSet.put(seen, proposition),
        MapSet.union(selected, refs)
      )
    end
  end

  defp put_payload(refs, nil), do: refs
  defp put_payload(refs, ref), do: MapSet.put(refs, ref)
end
