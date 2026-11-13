defmodule Spectre.GAM.Erasure.Index do
  @moduledoc """
  Incremental Evidence availability at a folded prefix.

  Edges contain references, never copies of records. Only the five kinds which
  can lead back to Evidence participate; Decisions, Duties and declassifications
  are sinks in the full tombstone closure. That full analysis remains separate.

  Each active payload labels its reachable nodes. New edges propagate only
  those labels, so unrelated events never revisit an old erasure. A definitive
  no-effect receipt removes one payload's labels, not another erasure's coverage.
  This index is disposable and rebuilt by the same live/replay fold.
  """

  alias Spectre.GAM.{Disclosure, Presentation}
  alias Spectre.GAM.Erasure.Analysis.{Execution, Facts}

  @collections [:evidence, :presentations, :acts, :attempts, :outcomes, :erasures]
  @positions %{
    "evidence_recorded" => 0,
    "presentation_recorded" => 1,
    "act_committed" => 2,
    "attempt_started" => 3,
    "outcome_recorded" => 4,
    "erasure_requested" => 5
  }
  defstruct children: %{},
            roots: %{},
            sources: %{},
            reached: %{},
            targets: %{},
            states: %{},
            unavailable: MapSet.new(),
            counts: {0, 0, 0, 0, 0, 0}

  @type t :: %__MODULE__{}

  @doc false
  def complete?(index, state), do: index.counts === counts(state)

  @doc false
  def record(state, event) do
    index = state.read_index.erasure
    counts = counts(state)

    before =
      case Map.fetch(@positions, event.type) do
        {:ok, position} -> put_elem(counts, position, elem(counts, position) - 1)
        :error -> counts
      end

    # A hand-built/filtered pure State has no complete graph. Never bless its
    # old records merely because we indexed one new event.
    index =
      if index.counts === before,
        do: %{update(index, state, event) | counts: counts},
        else: %{index | counts: nil}

    %{state | read_index: %{state.read_index | erasure: index}}
  end

  defp update(index, state, %{type: "evidence_recorded", identity: ref}) do
    item = Map.fetch!(state.evidence, ref)

    index
    |> link(Enum.map(item.parent_refs, &{:evidence, &1}), {:evidence, ref})
    |> root(item.payload_ref, {:evidence, ref})
  end

  defp update(index, state, %{type: "presentation_recorded", identity: ref}) do
    item = Map.fetch!(state.presentations, ref)

    index
    |> link(Enum.map(disclosure_sources(item.disclosure), &{:evidence, &1}), {:presentation, ref})
    |> root(item.rendered_payload_ref, {:presentation, ref})
  end

  defp update(index, state, %{type: "act_committed", identity: ref}) do
    act = Map.fetch!(state.acts, ref)

    show =
      case Presentation.show_presentation_ref(act.consequence) do
        {:ok, ref} -> [ref]
        {:error, _} -> []
      end

    sources = Enum.map(act.evidence_refs ++ disclosure_sources(act.disclosure), &{:evidence, &1})
    sources = sources ++ Enum.map(List.wrap(act.presentation_ref) ++ show, &{:presentation, &1})
    link(index, sources, {:act, ref})
  end

  defp update(index, state, %{type: "attempt_started", identity: ref}) do
    attempt = Map.fetch!(state.attempts, ref)

    index
    |> link([{:act, attempt.act_ref}], {:attempt, ref})
    |> refresh_act(state, attempt.act_ref)
  end

  defp update(index, state, %{type: "outcome_recorded", identity: ref}) do
    outcome = Map.fetch!(state.outcomes, ref)
    evidence = Enum.map(outcome.evidence_refs, &{:evidence, &1})
    sources = [{:act, outcome.act_ref}, {:attempt, outcome.attempt_ref} | evidence]
    index = link(index, sources, {:outcome, ref})
    # Receipt Evidence inherits the causal dependency of the reported effect.
    index = Enum.reduce(evidence, index, &link(&2, [{:outcome, ref}], &1))
    refresh_act(index, state, outcome.act_ref)
  end

  defp update(index, state, %{type: "erasure_requested", identity: ref}) do
    erasure = Map.fetch!(state.erasures, ref)
    index = %{index | targets: put_ref(index.targets, erasure.target_ref, ref)}
    refresh(index, state, erasure.target_ref)
  end

  defp update(index, _state, _event), do: index

  defp refresh_act(index, state, act_ref) do
    state.read_index.duties.erasures_by_act
    |> Map.get(act_ref, MapSet.new())
    |> Enum.reduce(MapSet.new(), &MapSet.put(&2, Map.fetch!(state.erasures, &1).target_ref))
    |> Enum.reduce(index, &refresh(&2, state, &1))
  end

  defp refresh(index, state, target) do
    refs = Map.fetch!(index.targets, target) |> MapSet.to_list()
    status = state |> Facts.execution_subset(refs) |> Execution.state(target)
    previous = Map.get(index.states, target, :live)
    index = %{index | states: Map.put(index.states, target, status)}

    cond do
      previous === :live and status !== :live ->
        propagate(index, target, Map.get(index.roots, target, MapSet.new()) |> MapSet.to_list())

      previous !== :live and status === :live ->
        clear(index, target)

      true ->
        index
    end
  end

  defp root(index, nil, _node), do: index

  defp root(index, target, node) do
    index = %{index | roots: put_ref(index.roots, target, node)}

    if Map.get(index.states, target, :live) === :live,
      do: index,
      else: propagate(index, target, [node])
  end

  defp link(index, sources, child) do
    Enum.reduce(sources, index, fn source, index ->
      index = %{index | children: put_ref(index.children, source, child)}

      index.sources
      |> Map.get(source, MapSet.new())
      |> Enum.reduce(index, &propagate(&2, &1, [child]))
    end)
  end

  defp propagate(index, _target, []), do: index

  defp propagate(index, target, [node | rest]) do
    sources = Map.get(index.sources, node, MapSet.new())

    if MapSet.member?(sources, target) do
      propagate(index, target, rest)
    else
      index = %{
        index
        | sources: Map.put(index.sources, node, MapSet.put(sources, target)),
          reached: put_ref(index.reached, target, node),
          unavailable: mark_evidence(index.unavailable, node, :put)
      }

      children = Map.get(index.children, node, MapSet.new()) |> MapSet.to_list()
      propagate(index, target, children ++ rest)
    end
  end

  defp clear(index, target) do
    index.reached
    |> Map.get(target, MapSet.new())
    |> Enum.reduce(index, fn node, index ->
      remaining = index.sources |> Map.fetch!(node) |> MapSet.delete(target)

      if MapSet.size(remaining) === 0 do
        %{
          index
          | sources: Map.delete(index.sources, node),
            unavailable: mark_evidence(index.unavailable, node, :delete)
        }
      else
        %{index | sources: Map.put(index.sources, node, remaining)}
      end
    end)
    |> then(&%{&1 | reached: Map.delete(&1.reached, target)})
  end

  defp mark_evidence(refs, {:evidence, ref}, :put), do: MapSet.put(refs, ref)
  defp mark_evidence(refs, {:evidence, ref}, :delete), do: MapSet.delete(refs, ref)
  defp mark_evidence(refs, _node, _operation), do: refs

  defp put_ref(index, key, ref),
    do: Map.update(index, key, MapSet.new([ref]), &MapSet.put(&1, ref))

  defp disclosure_sources(nil), do: []
  defp disclosure_sources(%Disclosure{source_evidence_refs: refs}), do: refs

  defp counts(state),
    do: @collections |> Enum.map(&map_size(Map.fetch!(state, &1))) |> List.to_tuple()
end
