defmodule Spectre.Mind.Context do
  @moduledoc """
  Optional, bounded recent memory supplied to a Mind, never to authority checks.

  Domain option `context: [max_events: 100, max_evidence: 50, max_bytes: 256_000]`
  enables recent Scope-bound Evidence. `max_events` is a window of ledger
  positions, not a validity horizon for Mandates, revocations or Duties.
  `max_bytes` bounds the sum of canonical Evidence bytes, excluding the small
  Turn envelope. Zero limits are valid and produce an empty evidence context.

  Omitted configuration preserves explicitly requested contextual Evidence.
  A configured Turn reports its exact revision, limits and partial selection.
  Kernel recognition always uses the complete relevant governed facts.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Erasure.Analysis
  alias Spectre.Evidence
  alias Spectre.GovernedAct.ReadIndex

  @defaults %{max_events: 100, max_evidence: 50, max_bytes: 256_000}

  @type limits :: %{
          max_events: non_neg_integer(),
          max_evidence: non_neg_integer(),
          max_bytes: non_neg_integer()
        }

  @doc false
  def normalize(nil), do: {:ok, nil}

  def normalize(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- Map.keys(@defaults) == [] do
      validate_limits(Map.merge(@defaults, Map.new(opts)))
    else
      {:error, :invalid_mind_context_limits}
    end
  end

  def normalize(_opts), do: {:error, :invalid_mind_context_limits}

  defp validate_limits(limits) do
    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: {:ok, limits},
      else: {:error, :invalid_mind_context_limits}
  end

  @doc false
  def select(_state, _scope_ref, evidence, nil), do: {evidence, nil}

  def select(state, scope_ref, evidence, limits) do
    first = max(state.revision - limits.max_events + 1, 1)

    recent =
      state
      |> ReadIndex.recent_evidence(limits.max_events)
      |> Enum.filter(&(Map.get(&1.bindings, "scope_ref") == scope_ref))

    unavailable = Analysis.unavailable_evidence_refs(state)

    candidates =
      (evidence ++ recent)
      |> Enum.uniq_by(& &1.ref)
      |> Enum.reject(&MapSet.member?(unavailable, &1.ref))
      |> Enum.sort_by(&{-Map.fetch!(state.event_metadata, &1.ref).revision, &1.ref})

    {selected, bytes, count, omitted?} =
      Enum.reduce(candidates, {[], 0, 0, false}, fn item, acc ->
        select_item(item, acc, state, first, limits)
      end)

    window = %{
      revision: state.revision,
      first_revision: first,
      limits: limits,
      partial?: first > 1 or omitted?,
      evidence_count: count,
      evidence_bytes: bytes
    }

    {Enum.reverse(selected), window}
  end

  defp select_item(item, {selected, bytes, count, omitted?}, state, first, limits) do
    if Map.fetch!(state.event_metadata, item.ref).revision < first or count >= limits.max_evidence do
      {selected, bytes, count, true}
    else
      case Value.encode(Evidence.canonical(item), max_bytes: max(limits.max_bytes - bytes, 1)) do
        {:ok, encoded} when byte_size(encoded) + bytes <= limits.max_bytes ->
          {[item | selected], bytes + byte_size(encoded), count + 1, omitted?}

        _exceeds_budget ->
          {selected, bytes, count, true}
      end
    end
  end
end
