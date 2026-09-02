defmodule Spectre.Erasure.Analysis do
  @moduledoc false

  alias Spectre.{Erasure, Portable, Presentation}

  @payload_ref ~r/\Apayload:([0-9a-f]{64})\z/
  @terminal_outcomes [:succeeded, :failed, :definitive_no_effect]
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

  @type payload_state :: :live | :possibly_absent | :erased

  @doc "Derives the exact immutable erasure draft from the current fact prefix."
  @spec derive_request(map(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, term()}
  def derive_request(facts, target_ref, scope_ref, reason, requested_at)
      when is_map(facts) and is_binary(target_ref) and is_binary(scope_ref) and
             is_binary(reason) and is_integer(requested_at) do
    with {:ok, digest} <- payload_digest(target_ref),
         :ok <- Portable.validate_ref(scope_ref, :scope_ref),
         true <- reason != "",
         {:ok, affected_refs} <- affected_refs(facts, target_ref) do
      {:ok,
       %{
         target_ref: target_ref,
         target_digest: digest,
         scope_ref: scope_ref,
         affected_refs: affected_refs,
         reason: reason,
         reduces_verifiability: affected_refs != [],
         requested_at: requested_at
       }}
    else
      false -> {:error, :invalid_erasure_reason}
      {:error, _reason} = error -> error
    end
  end

  def derive_request(_facts, _target_ref, _scope_ref, _reason, _requested_at),
    do: {:error, :invalid_erasure_analysis}

  @doc false
  def request_attrs(facts, target_ref, scope_ref, reason, requested_at),
    do: derive_request(facts, target_ref, scope_ref, reason, requested_at)

  @doc "Checks a supplied draft against the closure derivable at this exact prefix."
  @spec validate_request(map(), Erasure.t() | map() | keyword()) :: :ok | {:error, term()}
  def validate_request(facts, request) when is_map(facts) do
    with {:ok, actual} <- Erasure.request_draft(request),
         {:ok, expected_attrs} <-
           derive_request(
             facts,
             actual["target_ref"],
             actual["scope_ref"],
             actual["reason"],
             actual["requested_at"]
           ),
         {:ok, expected} <- Erasure.request_draft(expected_attrs),
         true <- actual == expected do
      :ok
    else
      false -> {:error, :erasure_request_not_derived_from_prefix}
      {:error, _reason} = error -> error
    end
  end

  def validate_request(_facts, _request), do: {:error, :invalid_erasure_analysis}

  @doc "Returns every durable record causally affected by one payload."
  @spec affected_refs(map(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def affected_refs(facts, target_ref) when is_map(facts) and is_binary(target_ref) do
    with {:ok, _digest} <- payload_digest(target_ref),
         {:ok, closure} <- closure(facts, target_ref) do
      affected =
        @closure_keys
        |> Enum.reduce(MapSet.new(), &MapSet.union(Map.fetch!(closure, &1), &2))
        |> MapSet.to_list()
        |> Enum.sort()

      {:ok, affected}
    end
  end

  def affected_refs(_facts, target_ref), do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Returns affected Evidence using the current, dynamic causal closure."
  @spec affected_evidence_refs(map(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def affected_evidence_refs(facts, target_ref) when is_map(facts) do
    with {:ok, closure} <- closure(facts, target_ref), do: {:ok, closure.evidence}
  end

  def affected_evidence_refs(_facts, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Classifies whether deletion may have touched the named payload."
  @spec execution_state(map(), String.t()) :: {:ok, payload_state()} | {:error, term()}
  def execution_state(facts, target_ref) when is_map(facts) and is_binary(target_ref) do
    with {:ok, _digest} <- payload_digest(target_ref) do
      facts = normalize_facts(facts)

      state =
        facts.erasures
        |> Map.values()
        |> Enum.filter(&(field(&1, :target_ref) == target_ref))
        |> Enum.map(&erasure_execution_state(facts, &1))
        |> Enum.reduce(:live, &more_conservative/2)

      {:ok, state}
    end
  end

  def execution_state(_facts, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Rejects duplicate erasure while an earlier request may still have had effect."
  @spec requestable?(map(), String.t()) :: :ok | {:error, term()}
  def requestable?(facts, target_ref) when is_map(facts) and is_binary(target_ref) do
    with {:ok, _digest} <- payload_digest(target_ref) do
      facts = normalize_facts(facts)

      blocking =
        facts.erasures
        |> Map.values()
        |> Enum.filter(&(field(&1, :target_ref) == target_ref))
        |> Enum.find(&(erasure_execution_state(facts, &1) != :live or not no_effect?(&1, facts)))

      if is_nil(blocking),
        do: :ok,
        else: {:error, {:erasure_target_already_requested, target_ref, record_ref(blocking)}}
    end
  end

  def requestable?(_facts, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Returns all Evidence made unusable by an attempted erasure."
  @spec unavailable_evidence_refs(map()) :: MapSet.t(String.t())
  def unavailable_evidence_refs(facts) when is_map(facts) do
    normalized = normalize_facts(facts)

    normalized.erasures
    |> Map.values()
    |> Enum.reduce(MapSet.new(), fn erasure, unavailable ->
      target_ref = field(erasure, :target_ref)

      case {execution_state(normalized, target_ref),
            affected_evidence_refs(normalized, target_ref)} do
        {{:ok, state}, {:ok, refs}} when state in [:possibly_absent, :erased] ->
          MapSet.union(unavailable, refs)

        _live_or_invalid ->
          unavailable
      end
    end)
  end

  def unavailable_evidence_refs(_facts), do: MapSet.new()

  @doc "Returns the Evidence records that remain valid inputs after erasure."
  @spec available_evidence(map()) :: map()
  def available_evidence(facts) when is_map(facts) do
    unavailable = unavailable_evidence_refs(facts)

    facts
    |> records(:evidence)
    |> Map.reject(fn {ref, _record} -> MapSet.member?(unavailable, ref) end)
  end

  def available_evidence(_facts), do: %{}

  @doc "Rejects reuse of Evidence whose causal payload may have been erased."
  @spec validate_evidence_available(map(), [String.t()]) :: :ok | {:error, term()}
  def validate_evidence_available(facts, refs) when is_map(facts) and is_list(refs) do
    unavailable = unavailable_evidence_refs(facts)

    case Enum.find(refs, &MapSet.member?(unavailable, &1)) do
      nil -> :ok
      ref -> {:error, {:evidence_unavailable_after_erasure, ref}}
    end
  end

  def validate_evidence_available(_facts, _refs),
    do: {:error, :invalid_evidence_availability_check}

  @doc false
  @spec payload_digest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def payload_digest(target_ref) do
    case Regex.run(@payload_ref, target_ref, capture: :all_but_first) do
      [digest] -> {:ok, digest}
      _invalid -> {:error, {:invalid_erasable_payload_ref, target_ref}}
    end
  end

  defp closure(facts, target_ref) do
    facts = normalize_facts(facts)

    evidence = refs_matching(facts.evidence, &(field(&1, :payload_ref) == target_ref))

    presentations =
      refs_matching(facts.presentations, &(field(&1, :rendered_payload_ref) == target_ref))

    if MapSet.size(evidence) + MapSet.size(presentations) == 0 do
      {:error, {:erasable_payload_not_referenced, target_ref}}
    else
      initial = Map.merge(empty_closure(), %{evidence: evidence, presentations: presentations})
      {:ok, expand_closure(facts, initial)}
    end
  end

  defp expand_closure(facts, current) do
    evidence_from_outcomes =
      current.outcomes
      |> Enum.flat_map(fn ref ->
        facts.outcomes |> Map.get(ref, %{}) |> field(:evidence_refs, []) |> List.wrap()
      end)
      |> existing_refs(facts.evidence)

    evidence =
      facts.evidence
      |> refs_matching(fn record ->
        intersects?(field(record, :parent_refs, []), current.evidence)
      end)
      |> MapSet.union(current.evidence)
      |> MapSet.union(evidence_from_outcomes)

    presentations =
      facts.presentations
      |> refs_matching(fn record ->
        record |> field(:disclosure) |> disclosure_sources() |> intersects?(evidence)
      end)
      |> MapSet.union(current.presentations)

    acts =
      facts.acts
      |> refs_matching(&affected_act?(&1, evidence, presentations))
      |> MapSet.union(current.acts)

    decisions =
      acts
      |> Enum.map(fn ref -> facts.acts |> Map.get(ref, %{}) |> field(:decision_ref) end)
      |> existing_refs(facts.decisions)
      |> MapSet.union(current.decisions)

    attempts =
      facts.attempts
      |> refs_matching(&MapSet.member?(acts, field(&1, :act_ref)))
      |> MapSet.union(current.attempts)

    outcomes =
      facts.outcomes
      |> refs_matching(fn record ->
        MapSet.member?(acts, field(record, :act_ref)) or
          MapSet.member?(attempts, field(record, :attempt_ref)) or
          intersects?(field(record, :evidence_refs, []), evidence)
      end)
      |> MapSet.union(current.outcomes)

    duties =
      facts.duties
      |> refs_matching(fn record ->
        MapSet.member?(acts, field(record, :act_ref)) or
          MapSet.member?(attempts, field(record, :attempt_ref)) or
          intersects?(field(record, :evidence_refs, []), evidence) or
          contains_any?(field(record, :cause_key), outcomes)
      end)
      |> MapSet.union(current.duties)

    declassifications =
      facts.declassifications
      |> refs_matching(fn record ->
        MapSet.member?(acts, field(record, :source_act_ref)) or
          MapSet.member?(evidence, field(record, :evidence_ref)) or
          intersects?(field(record, :parent_refs, []), evidence)
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

    if next == current, do: next, else: expand_closure(facts, next)
  end

  defp affected_act?(act, evidence, presentations) do
    show_ref =
      case Presentation.show_presentation_ref(field(act, :consequence)) do
        {:ok, ref} -> ref
        {:error, _reason} -> nil
      end

    intersects?(field(act, :evidence_refs, []), evidence) or
      intersects?(disclosure_sources(field(act, :disclosure)), evidence) or
      MapSet.member?(presentations, field(act, :presentation_ref)) or
      MapSet.member?(presentations, show_ref)
  end

  defp erasure_execution_state(facts, erasure) do
    act_ref = field(erasure, :source_act_ref)

    facts.attempts
    |> Map.values()
    |> Enum.filter(&(field(&1, :act_ref) == act_ref))
    |> Enum.map(&attempt_execution_state(facts, &1))
    |> Enum.reduce(:live, &more_conservative/2)
  end

  defp attempt_execution_state(facts, attempt) do
    attempt_ref = record_ref(attempt)

    outcomes =
      facts.outcomes
      |> Map.values()
      |> Enum.filter(&(field(&1, :attempt_ref) == attempt_ref))

    initial_terminal =
      outcomes
      |> Enum.filter(&(field(&1, :status) in @terminal_outcomes))
      |> Enum.min_by(&{field(&1, :observed_at, 0), record_ref(&1)}, fn -> nil end)

    correction =
      if initial_terminal do
        Enum.find(outcomes, fn outcome ->
          field(outcome, :contradicts_outcome_ref) == record_ref(initial_terminal)
        end)
      end

    terminal = correction || initial_terminal

    cond do
      is_nil(terminal) -> :possibly_absent
      field(terminal, :status) == :succeeded -> :erased
      field(terminal, :status) == :definitive_no_effect -> :live
      true -> :possibly_absent
    end
  end

  defp no_effect?(erasure, facts) do
    act_ref = field(erasure, :source_act_ref)

    attempts =
      facts.attempts
      |> Map.values()
      |> Enum.filter(&(field(&1, :act_ref) == act_ref))

    attempts != [] and Enum.all?(attempts, &(attempt_execution_state(facts, &1) == :live))
  end

  defp more_conservative(:erased, _state), do: :erased
  defp more_conservative(_state, :erased), do: :erased
  defp more_conservative(:possibly_absent, _state), do: :possibly_absent
  defp more_conservative(_state, :possibly_absent), do: :possibly_absent
  defp more_conservative(:live, :live), do: :live

  defp normalize_facts(facts) do
    %{
      evidence: records(facts, :evidence),
      presentations: records(facts, :presentations),
      acts: records(facts, :acts),
      decisions: records(facts, :decisions),
      attempts: records(facts, :attempts),
      outcomes: records(facts, :outcomes),
      duties: records(facts, :duties),
      declassifications: records(facts, :declassifications),
      erasures: records(facts, :erasures)
    }
  end

  defp records(facts, key) do
    case field(facts, key, %{}) do
      values when is_map(values) -> values
      values when is_list(values) -> Map.new(values, &{record_ref(&1), &1})
      _invalid -> %{}
    end
  end

  defp empty_closure, do: Map.new(@closure_keys, &{&1, MapSet.new()})

  defp refs_matching(records, predicate) do
    Enum.reduce(records, MapSet.new(), fn {key, record}, refs ->
      if predicate.(record), do: MapSet.put(refs, record_ref(record) || key), else: refs
    end)
  end

  defp existing_refs(refs, records) do
    refs
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&Map.has_key?(records, &1))
    |> MapSet.new()
  end

  defp disclosure_sources(nil), do: []
  defp disclosure_sources(disclosure), do: field(disclosure, :source_evidence_refs, [])

  defp intersects?(values, refs) when is_list(values),
    do: Enum.any?(values, &MapSet.member?(refs, &1))

  defp intersects?(_values, _refs), do: false

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

  defp record_ref(%{ref: ref}), do: ref
  defp record_ref(%{"ref" => ref}), do: ref
  defp record_ref(_record), do: nil

  defp field(value, key, default \\ nil)

  defp field(value, key, default) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key), default))

  defp field(_value, _key, default), do: default
end
