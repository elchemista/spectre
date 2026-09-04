defmodule Spectre.Erasure.Analysis.Closure do
  @moduledoc """
  Computes the fixed-point causal closure of an erasable payload.

  The closure follows only decoded governed records held by `Analysis.Facts`.
  It is deliberately independent of storage and ledger position: callers pin
  those boundaries before constructing the facts container.
  """

  alias Spectre.{Disclosure, Presentation}
  alias Spectre.Erasure.Analysis.{Execution, Facts}

  @closure_keys [
    :evidence,
    :presentations,
    :acts,
    :decisions,
    :attempts,
    :outcomes,
    :duties,
    :declassifications
  ]

  @type t :: %{
          evidence: MapSet.t(String.t()),
          presentations: MapSet.t(String.t()),
          acts: MapSet.t(String.t()),
          decisions: MapSet.t(String.t()),
          attempts: MapSet.t(String.t()),
          outcomes: MapSet.t(String.t()),
          duties: MapSet.t(String.t()),
          declassifications: MapSet.t(String.t())
        }

  @doc false
  @spec affected_refs(Facts.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def affected_refs(%Facts{} = facts, target_ref) when is_binary(target_ref) do
    with {:ok, closure} <- derive(facts, target_ref) do
      affected =
        @closure_keys
        |> Enum.reduce(MapSet.new(), &MapSet.union(Map.fetch!(closure, &1), &2))
        |> MapSet.to_list()
        |> Enum.sort()

      {:ok, affected}
    end
  end

  @doc false
  @spec affected_evidence_refs(Facts.t(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def affected_evidence_refs(%Facts{} = facts, target_ref) when is_binary(target_ref) do
    with {:ok, closure} <- derive(facts, target_ref), do: {:ok, closure.evidence}
  end

  @doc false
  @spec unavailable_evidence_refs(Facts.t()) :: MapSet.t(String.t())
  def unavailable_evidence_refs(%Facts{} = facts) do
    facts.erasures
    |> Enum.reduce(MapSet.new(), fn {_ref, erasure}, targets ->
      MapSet.put(targets, erasure.target_ref)
    end)
    |> Enum.reduce(MapSet.new(), fn target_ref, unavailable ->
      with state when state in [:possibly_absent, :erased] <- Execution.state(facts, target_ref),
           {:ok, closure} <- derive(facts, target_ref) do
        MapSet.union(unavailable, closure.evidence)
      else
        _live_or_invalid -> unavailable
      end
    end)
  end

  @doc false
  @spec derive(Facts.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def derive(%Facts{} = facts, target_ref) when is_binary(target_ref) do
    evidence = refs_matching(facts.evidence, &(&1.payload_ref == target_ref))

    presentations =
      refs_matching(facts.presentations, &(&1.rendered_payload_ref == target_ref))

    if MapSet.size(evidence) + MapSet.size(presentations) == 0 do
      {:error, {:erasable_payload_not_referenced, target_ref}}
    else
      initial = Map.merge(empty(), %{evidence: evidence, presentations: presentations})
      {:ok, expand(facts, initial)}
    end
  end

  defp expand(facts, current) do
    evidence_from_outcomes =
      current.outcomes
      |> Enum.flat_map(&Map.fetch!(facts.outcomes, &1).evidence_refs)
      |> existing_refs(facts.evidence)

    evidence =
      facts.evidence
      |> refs_matching(&intersects?(&1.parent_refs, current.evidence))
      |> MapSet.union(current.evidence)
      |> MapSet.union(evidence_from_outcomes)

    presentations =
      facts.presentations
      |> refs_matching(&intersects?(disclosure_sources(&1.disclosure), evidence))
      |> MapSet.union(current.presentations)

    acts =
      facts.acts
      |> refs_matching(&affected_act?(&1, evidence, presentations))
      |> MapSet.union(current.acts)

    decisions =
      acts
      |> Enum.map(&Map.fetch!(facts.acts, &1).decision_ref)
      |> existing_refs(facts.decisions)
      |> MapSet.union(current.decisions)

    attempts =
      facts.attempts
      |> refs_matching(&MapSet.member?(acts, &1.act_ref))
      |> MapSet.union(current.attempts)

    outcomes =
      facts.outcomes
      |> refs_matching(fn outcome ->
        MapSet.member?(acts, outcome.act_ref) or
          MapSet.member?(attempts, outcome.attempt_ref) or
          intersects?(outcome.evidence_refs, evidence)
      end)
      |> MapSet.union(current.outcomes)

    duties =
      facts.duties
      |> refs_matching(fn duty ->
        MapSet.member?(acts, duty.act_ref) or
          MapSet.member?(attempts, duty.attempt_ref) or
          intersects?(duty.evidence_refs, evidence) or
          contains_any?(duty.cause_key, outcomes)
      end)
      |> MapSet.union(current.duties)

    declassifications =
      facts.declassifications
      |> refs_matching(fn declassification ->
        MapSet.member?(acts, declassification.source_act_ref) or
          MapSet.member?(evidence, declassification.evidence_ref) or
          intersects?(declassification.parent_refs, evidence)
      end)
      |> MapSet.union(current.declassifications)

    next = %{
      evidence: evidence,
      presentations: presentations,
      acts: acts,
      decisions: decisions,
      attempts: attempts,
      outcomes: outcomes,
      duties: duties,
      declassifications: declassifications
    }

    if next == current, do: next, else: expand(facts, next)
  end

  defp affected_act?(act, evidence, presentations) do
    show_ref =
      case Presentation.show_presentation_ref(act.consequence) do
        {:ok, ref} -> ref
        {:error, _reason} -> nil
      end

    intersects?(act.evidence_refs, evidence) or
      intersects?(disclosure_sources(act.disclosure), evidence) or
      MapSet.member?(presentations, act.presentation_ref) or
      MapSet.member?(presentations, show_ref)
  end

  defp empty, do: Map.new(@closure_keys, &{&1, MapSet.new()})

  defp refs_matching(records, predicate) do
    Enum.reduce(records, MapSet.new(), fn {_key, record}, refs ->
      if predicate.(record), do: MapSet.put(refs, record.ref), else: refs
    end)
  end

  defp existing_refs(refs, records) do
    Enum.reduce(refs, MapSet.new(), fn ref, existing ->
      if Map.has_key?(records, ref), do: MapSet.put(existing, ref), else: existing
    end)
  end

  defp disclosure_sources(nil), do: []
  defp disclosure_sources(%Disclosure{source_evidence_refs: refs}), do: refs

  defp intersects?(values, refs), do: Enum.any?(values, &MapSet.member?(refs, &1))

  defp contains_any?(value, refs) when is_binary(value), do: MapSet.member?(refs, value)

  defp contains_any?(value, refs) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_any?(&1, refs))

  defp contains_any?(value, refs) when is_list(value),
    do: Enum.any?(value, &contains_any?(&1, refs))

  defp contains_any?(value, refs) when is_map(value) and not is_struct(value),
    do:
      Enum.any?(value, fn {key, item} ->
        contains_any?(key, refs) or contains_any?(item, refs)
      end)

  defp contains_any?(_value, _refs), do: false
end
