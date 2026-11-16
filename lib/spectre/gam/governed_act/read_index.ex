defmodule Spectre.GAM.GovernedAct.ReadIndex do
  @moduledoc """
  Rebuildable reference indexes for local reads of a governed prefix.

  Records remain in their single typed collection. These indexes select them
  by proposition, acquisition revision or payload reference without walking
  unrelated history. They contain no authority and are updated by the fold,
  including during independent replay.
  """

  alias Spectre.GAM.Erasure.{Analysis, Index}
  alias Spectre.GAM.GovernedAct.Reads, as: Selection
  alias Spectre.GAM.GovernedAct.AuthorityIndex
  alias Spectre.GAM.Presentation

  defstruct duties: %Spectre.GAM.Duty.Frontier{},
            selection: nil,
            erasure: %Index{},
            authority: %AuthorityIndex{},
            batches: MapSet.new(),
            evidence_by_proposition: %{},
            evidence_by_attempt: %{},
            approval_propositions: %{},
            show_acts: %{},
            act_count: 0,
            evidence_by_revision: :gb_trees.empty(),
            payload_refs: MapSet.new(),
            presentation_count: 0,
            outcome_count: 0,
            dispatch_deadlines: :gb_trees.empty()

  @type t :: %__MODULE__{}

  @doc false
  def record(state, event) do
    state |> record_indexes(event) |> Index.record(event) |> AuthorityIndex.record(event)
  end

  defp record_indexes(state, %{type: "evidence_recorded", identity: ref, revision: revision}) do
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

    index =
      case evidence.bindings do
        %{"act_ref" => act, "attempt_ref" => attempt} ->
          %{index | evidence_by_attempt: put_ref(index.evidence_by_attempt, {act, attempt}, ref)}

        _other ->
          index
      end

    index =
      case Presentation.approval_refs(evidence) do
        {:ok, presentation, _show} ->
          %{
            index
            | approval_propositions:
                put_ref(index.approval_propositions, presentation, evidence.proposition)
          }

        _not_approval ->
          index
      end

    %{state | read_index: index}
  end

  defp record_indexes(state, %{type: "act_committed", identity: ref}) do
    act = Map.fetch!(state.acts, ref)
    index = state.read_index

    shows =
      case Presentation.show_presentation_ref(act.consequence) do
        {:ok, presentation} -> put_ref(index.show_acts, presentation, ref)
        _not_show -> index.show_acts
      end

    %{state | read_index: %{index | show_acts: shows, act_count: map_size(state.acts)}}
  end

  defp record_indexes(state, %{type: "presentation_recorded", identity: ref}) do
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

  defp record_indexes(state, %{type: "dispatch_ready", data: %{"act_ref" => ref}}) do
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

  defp record_indexes(state, %{type: "outcome_recorded", identity: ref}) do
    outcome = Map.fetch!(state.outcomes, ref)
    frontier = state.read_index.duties

    frontier = %{
      frontier
      | outcomes_by_act: put_ref(frontier.outcomes_by_act, outcome.act_ref, ref),
        outcomes_by_attempt: put_ref(frontier.outcomes_by_attempt, outcome.attempt_ref, ref)
    }

    %{
      state
      | read_index: %{
          state.read_index
          | duties: frontier,
            outcome_count: map_size(state.outcomes)
        }
    }
  end

  defp record_indexes(state, %{type: "erasure_requested", identity: ref}) do
    erasure = Map.fetch!(state.erasures, ref)
    frontier = state.read_index.duties

    frontier = %{
      frontier
      | erasures_by_act: put_ref(frontier.erasures_by_act, erasure.source_act_ref, ref)
    }

    %{state | read_index: %{state.read_index | duties: frontier}}
  end

  defp record_indexes(state, %{type: "dispatch_cancelled", data: %{"act_ref" => ref}}),
    do: remove_dispatch(state, ref)

  defp record_indexes(state, %{type: "attempt_started", identity: ref}),
    do: remove_dispatch(state, Map.fetch!(state.attempts, ref).act_ref)

  defp record_indexes(state, _event), do: state

  defp put_ref(index, key, ref),
    do: Map.update(index, key, MapSet.new([ref]), &MapSet.put(&1, ref))

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
  def evidence_for(state, conditions, presentation_ref \\ nil) do
    reads = state.read_index.selection
    propositions = Enum.map(conditions || [], & &1.proposition)
    if presentation_ref, do: Selection.group(reads, :approval_propositions, presentation_ref)
    responses = Map.get(state.read_index.approval_propositions, presentation_ref, MapSet.new())
    propositions = propositions ++ MapSet.to_list(responses)

    if reads != nil or complete?(state) do
      selected = collect(propositions, state, %{}, %{})
      unavailable = Analysis.unavailable_evidence_refs(state)

      selected
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(unavailable, &1))
      |> Enum.map(&Map.fetch!(state.evidence, &1))
      |> Enum.sort_by(& &1.ref)
    else
      # Pure callers can assemble a State without running a ledger fold.
      # An absent index must never hide a counterproof in that input.
      state |> Analysis.available_evidence() |> Map.values()
    end
  end

  @doc "Selects the shows and all their Outcomes, including failed and contradictory receipts."
  def presentation_history(state, ref) do
    Selection.group(state.read_index.selection, :presentation_shows, ref)

    if state.read_index.selection != nil or
         (state.read_index.act_count === map_size(state.acts) and
            state.read_index.outcome_count === map_size(state.outcomes)) do
      refs = Map.get(state.read_index.show_acts, ref, MapSet.new()) |> MapSet.to_list()
      outcomes = Enum.reduce(refs, %{}, &Map.merge(&2, outcomes_for(state, :act, &1)))
      {Map.take(state.acts, refs), Map.values(outcomes)}
    else
      {state.acts, Map.values(state.outcomes)}
    end
  end

  @doc false
  def evidence_for_attempt(state, act_ref, attempt_ref) do
    Selection.group(state.read_index.selection, :attempt_evidence, {act_ref, attempt_ref})

    if state.read_index.selection != nil or complete?(state) do
      refs = Map.get(state.read_index.evidence_by_attempt, {act_ref, attempt_ref}, MapSet.new())
      Map.take(state.evidence, MapSet.to_list(refs))
    else
      state.evidence
    end
  end

  @doc false
  def complete?(state),
    do:
      state.read_index.selection == nil and
        :gb_trees.size(state.read_index.evidence_by_revision) == map_size(state.evidence) and
        state.read_index.presentation_count == map_size(state.presentations)

  @doc false
  def outcomes_for(state, kind, ref) when kind in [:act, :attempt] do
    collection = if kind == :act, do: :act_outcomes, else: :attempt_outcomes
    Selection.group(state.read_index.selection, collection, ref)

    if state.read_index.selection != nil or
         state.read_index.outcome_count == map_size(state.outcomes) do
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
    if Map.has_key?(seen, proposition) do
      collect(rest, state, seen, selected)
    else
      Selection.group(state.read_index.selection, :evidence_propositions, proposition)
      refs = Map.get(state.read_index.evidence_by_proposition, proposition, MapSet.new())
      assumptions = Enum.flat_map(refs, &Map.fetch!(state.evidence, &1).assumptions)

      collect(
        assumptions ++ rest,
        state,
        Map.put(seen, proposition, true),
        Enum.reduce(refs, selected, &Map.put(&2, &1, true))
      )
    end
  end

  defp put_payload(refs, nil), do: refs
  defp put_payload(refs, ref), do: MapSet.put(refs, ref)
end
