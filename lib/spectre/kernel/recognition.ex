defmodule Spectre.Kernel.Recognition do
  @moduledoc """
  Pure recognition of Evidence against declared mandate conditions.

  Recognition answers only whether facts satisfy conditions. It never resolves
  a Mandate and never returns a Grant. Conditions and Evidence may be structs or
  portable maps; no callback, predicate closure, I/O, or ambient clock is used.

  A missing, stale, insufficient, or merely provisional proof is
  `:undecidable`. Explicit contrary Evidence is `:unsatisfied`. Conflicting
  support and contradiction remains `:undecidable` rather than being resolved by
  ordering.
  """

  @type condition :: map()
  @type evidence :: map()
  @type reason :: term()
  @type result :: :satisfied | {:unsatisfied, [reason()]} | {:undecidable, [reason()]}

  @doc """
  Checks every condition against an Evidence collection at trusted `time`.

  The Evidence collection may be a list, a map keyed by Evidence ref, or a map
  containing `:evidence`. Empty conditions are satisfied.
  """
  @spec check([condition()] | nil, [evidence()] | map() | nil, term()) :: result()
  def check(conditions, _evidence, _time) when conditions in [nil, []], do: :satisfied

  def check(conditions, evidence, time) when is_list(conditions) do
    {result, _basis_refs} = check_with_basis(conditions, evidence, time)
    result
  end

  def check(_conditions, _evidence, _time),
    do: {:undecidable, [:invalid_conditions]}

  @doc """
  Checks conditions and returns the exact qualified Evidence basis.

  The basis contains every current supporting or contradicting record that can
  affect the result, plus qualified records used to establish their assumptions.
  Callers can require these refs to be frozen into an Act instead of trusting a
  proposer-selected subset.
  """
  @spec check_with_basis([condition()] | nil, [evidence()] | map() | nil, term()) ::
          {result(), [String.t()]}
  def check_with_basis(conditions, _evidence, _time) when conditions in [nil, []],
    do: {:satisfied, []}

  def check_with_basis(conditions, evidence, time) when is_list(conditions) do
    evidence = evidence_list(evidence)
    results = Enum.map(conditions, &check_condition(&1, evidence, time))
    basis_refs = evidence_basis_refs(conditions, evidence, time)

    {combined_result(results), basis_refs}
  end

  def check_with_basis(_conditions, _evidence, _time),
    do: {{:undecidable, [:invalid_conditions]}, []}

  defp combined_result(results) do
    unsatisfied = reasons_for(results, :unsatisfied)
    undecidable = reasons_for(results, :undecidable)

    cond do
      unsatisfied != [] -> {:unsatisfied, unsatisfied}
      undecidable != [] -> {:undecidable, undecidable}
      true -> :satisfied
    end
  end

  @doc """
  Checks one portable condition and returns a stable, local explanation.

  Supported structural constraints are proposition, bindings, accepted issuer
  and provenance, freshness, validity, provisional acceptance, cardinality and
  aggregate coverage. Domain-specific meaning stays in the proposition itself.
  """
  @spec check_condition(condition(), [evidence()] | map(), term()) ::
          :satisfied | {:unsatisfied, reason()} | {:undecidable, reason()}
  def check_condition(condition, evidence, time) when is_map(condition) do
    with :ok <- valid_condition(condition),
         {:ok, bounds} <- cardinality_bounds(condition) do
      evaluate_condition(condition, evidence_list(evidence), time, bounds)
    else
      {:error, reason} -> {:undecidable, {condition_ref(condition), reason}}
    end
  end

  def check_condition(_condition, _evidence, _time),
    do: {:undecidable, {:unknown_condition, :invalid_condition}}

  @doc false
  @spec qualified?(evidence(), condition(), [evidence()] | map(), term()) :: boolean()
  def qualified?(evidence, condition, evidence_set, time)
      when is_map(evidence) and is_map(condition) do
    qualify(evidence, condition, evidence_list(evidence_set), time, MapSet.new()) == :ok
  end

  def qualified?(_evidence, _condition, _evidence_set, _time), do: false

  defp evaluate_condition(condition, all_evidence, time, bounds) do
    relevant =
      all_evidence
      |> Enum.filter(&same_proposition?(&1, condition))
      |> Enum.uniq_by(&evidence_ref/1)

    {qualified, rejected} = qualify_all(relevant, condition, all_evidence, time)
    supporting = Enum.filter(qualified, &(stance(&1) == :supports))
    contradicting = Enum.filter(qualified, &(stance(&1) == :contradicts))

    classify(condition, supporting, contradicting, rejected, bounds)
  end

  defp qualify_all(relevant, condition, all_evidence, time) do
    Enum.reduce(relevant, {[], []}, fn item, {accepted, rejected} ->
      case qualify(item, condition, all_evidence, time, MapSet.new()) do
        :ok -> {[item | accepted], rejected}
        {:error, reason} -> {accepted, [{evidence_ref(item), reason} | rejected]}
      end
    end)
  end

  defp classify(condition, supporting, contradicting, rejected, {minimum, maximum}) do
    ref = condition_ref(condition)
    count = supporting |> Enum.map(&evidence_identity/1) |> Enum.uniq() |> length()

    cond do
      supporting != [] and contradicting != [] ->
        {:undecidable, {ref, :conflicting_evidence, evidence_refs(supporting ++ contradicting)}}

      contradicting != [] ->
        {:unsatisfied, {ref, :contradicted, evidence_refs(contradicting)}}

      not is_nil(maximum) and count > maximum ->
        {:undecidable, {ref, :cardinality_exceeded, %{maximum: maximum, actual: count}}}

      count < minimum ->
        {:undecidable,
         {ref, :insufficient_evidence,
          %{minimum: minimum, actual: count, rejected: Enum.reverse(rejected)}}}

      not coverage_satisfied?(condition, supporting) ->
        {:undecidable, {ref, :coverage_incomplete, get(condition, [:coverage])}}

      true ->
        :satisfied
    end
  end

  defp valid_condition(condition) do
    if present?(get(condition, [:proposition])),
      do: :ok,
      else: {:error, :missing_proposition}
  end

  defp qualify(evidence, condition, evidence_set, time, visited) when is_map(evidence) do
    key = evidence_identity_key(evidence)

    with false <- MapSet.member?(visited, key),
         visited = MapSet.put(visited, key),
         :ok <- valid_stance(evidence),
         :ok <- accepted_provenance(evidence, condition),
         :ok <- accepted_issuer(evidence, condition),
         :ok <- accepted_source(evidence, condition),
         :ok <- accepted_provisional(evidence, condition),
         :ok <- valid_at(evidence, time),
         :ok <- fresh_enough(evidence, condition, time),
         :ok <- bindings_cover(evidence, condition),
         :ok <- labels_cover(evidence, condition) do
      assumptions_supported(evidence, condition, evidence_set, time, visited)
    else
      true -> {:error, :cyclic_evidence_assumptions}
      {:error, _reason} = error -> error
    end
  end

  defp qualify(_evidence, _condition, _evidence_set, _time, _visited),
    do: {:error, :invalid_evidence}

  defp valid_stance(evidence) do
    if stance(evidence) in [:supports, :contradicts],
      do: :ok,
      else: {:error, :unknown_evidence_stance}
  end

  defp accepted_provenance(evidence, condition) do
    accepted =
      condition
      |> get([:accepted_provenance, :provenance])
      |> listify()

    actual = get(evidence, [:provenance])

    if accepted == [] or actual in accepted,
      do: :ok,
      else: {:error, {:unaccepted_provenance, actual}}
  end

  defp accepted_issuer(evidence, condition) do
    accepted = accepted_constraint(condition, [:issuer_refs, :issuers, :issuer_ref])
    actual = get(evidence, [:issuer_ref])

    if not present?(accepted) or constraint_covers?(accepted, actual),
      do: :ok,
      else: {:error, {:unaccepted_issuer, actual}}
  end

  defp accepted_source(evidence, condition) do
    accepted = accepted_constraint(condition, [:source_refs, :sources, :source_ref])
    actual = get(evidence, [:source_ref, :source])

    if not present?(accepted) or constraint_covers?(accepted, actual),
      do: :ok,
      else: {:error, {:unaccepted_source, actual}}
  end

  defp accepted_constraint(condition, keys) do
    case get(condition, keys) do
      nil -> condition |> get([:parameters], %{}) |> get(keys)
      value -> value
    end
  end

  defp accepted_provisional(evidence, condition) do
    provisional? = get(evidence, [:provisional], false) == true
    allowed? = get(condition, [:allow_provisional], false) == true

    if not provisional? or allowed?,
      do: :ok,
      else: {:error, :provisional_evidence_not_accepted}
  end

  defp valid_at(evidence, time) do
    observed_at = get(evidence, [:observed_at, :recorded_at])
    valid_from = get(evidence, [:valid_from])
    valid_until = get(evidence, [:valid_until, :expires_at])

    cond do
      not at_or_after?(time, observed_at) ->
        {:error, :evidence_from_future}

      present?(valid_from) and not at_or_after?(time, valid_from) ->
        {:error, :evidence_not_yet_valid}

      present?(valid_until) and at_or_after?(time, valid_until) ->
        {:error, :evidence_expired}

      true ->
        :ok
    end
  end

  defp fresh_enough(evidence, condition, time) do
    condition_freshness = get(condition, [:freshness_ms, :max_age_ms])
    evidence_freshness = get(evidence, [:freshness_ms])
    freshness = strictest_freshness(condition_freshness, evidence_freshness)

    if is_nil(freshness) do
      :ok
    else
      observed_at = get(evidence, [:observed_at, :recorded_at])

      with true <- is_integer(freshness) and freshness >= 0,
           {:ok, now} <- timestamp(time),
           {:ok, observed} <- timestamp(observed_at),
           true <- now >= observed and now - observed <= freshness do
        :ok
      else
        _other -> {:error, :stale_or_unverifiable_freshness}
      end
    end
  end

  defp strictest_freshness(nil, nil), do: nil
  defp strictest_freshness(value, nil), do: value
  defp strictest_freshness(nil, value), do: value

  defp strictest_freshness(left, right) when is_integer(left) and is_integer(right),
    do: min(left, right)

  defp strictest_freshness(_left, _right), do: :invalid

  defp bindings_cover(evidence, condition) do
    required = get(condition, [:bindings])
    actual = get(evidence, [:bindings])

    if subset_value?(required, actual),
      do: :ok,
      else: {:error, :binding_mismatch}
  end

  defp labels_cover(evidence, condition) do
    required =
      condition
      |> get([:parameters], %{})
      |> get([:required_labels, :labels])

    actual = get(evidence, [:labels])

    if subset_value?(required, actual),
      do: :ok,
      else: {:error, :required_labels_missing}
  end

  defp assumptions_supported(evidence, condition, evidence_set, time, visited) do
    assumptions = listify(get(evidence, [:assumptions], []))
    parameters = get(condition, [:parameters], %{})
    accepted = listify(get(parameters, [:accepted_assumptions], []))

    Enum.reduce_while(assumptions, :ok, fn assumption, :ok ->
      case assumption_status(
             assumption,
             assumption in accepted,
             condition,
             evidence_set,
             time,
             visited
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp assumption_status(assumption, accepted?, condition, evidence_set, time, visited) do
    qualified =
      evidence_set
      |> Enum.filter(&(is_map(&1) and get(&1, [:proposition]) == assumption))
      |> Enum.filter(&(qualify(&1, condition, evidence_set, time, visited) == :ok))

    supporting = Enum.filter(qualified, &(stance(&1) == :supports))
    contradicting = Enum.filter(qualified, &(stance(&1) == :contradicts))

    cond do
      supporting != [] and contradicting != [] ->
        {:error,
         {:conflicting_evidence_assumption, assumption,
          evidence_refs(supporting ++ contradicting)}}

      contradicting != [] ->
        {:error, {:contradicted_evidence_assumption, assumption, evidence_refs(contradicting)}}

      supporting != [] or accepted? ->
        :ok

      true ->
        {:error, {:unresolved_evidence_assumption, assumption}}
    end
  end

  defp evidence_basis_refs(conditions, evidence, time) do
    conditions
    |> Enum.reduce(MapSet.new(), fn condition, refs ->
      seeds = Enum.filter(evidence, &same_proposition?(&1, condition))
      collect_evidence_basis(seeds, condition, evidence, time, refs, MapSet.new())
    end)
    |> MapSet.to_list()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp collect_evidence_basis(candidates, condition, evidence, time, refs, visited) do
    Enum.reduce(candidates, refs, fn candidate, current_refs ->
      identity = evidence_identity_key(candidate)

      cond do
        MapSet.member?(visited, identity) ->
          current_refs

        qualify(candidate, condition, evidence, time, MapSet.new()) != :ok ->
          current_refs

        true ->
          visited = MapSet.put(visited, identity)
          current_refs = MapSet.put(current_refs, evidence_ref(candidate))

          candidate
          |> get([:assumptions], [])
          |> listify()
          |> Enum.reduce(current_refs, fn assumption, assumption_refs ->
            dependencies = Enum.filter(evidence, &(get(&1, [:proposition]) == assumption))

            collect_evidence_basis(
              dependencies,
              condition,
              evidence,
              time,
              assumption_refs,
              visited
            )
          end)
      end
    end)
  end

  defp coverage_satisfied?(condition, evidence) do
    required = get(condition, [:coverage])

    if not present?(required) or required in [:any, :all] do
      true
    else
      actual =
        Enum.reduce(evidence, empty_coverage(required), fn item, acc ->
          merge_coverage(acc, get(item, [:coverage, :bindings]))
        end)

      subset_value?(required, actual)
    end
  end

  defp empty_coverage(required) when is_map(required), do: %{}
  defp empty_coverage(_required), do: []

  defp merge_coverage(acc, nil), do: acc
  defp merge_coverage(acc, value) when is_list(acc), do: Enum.uniq(acc ++ listify(value))

  defp merge_coverage(acc, value) when is_map(acc) and is_map(value) do
    Map.merge(acc, value, fn _key, left, right -> merge_coverage(listify(left), right) end)
  end

  defp merge_coverage(acc, _value), do: acc

  defp cardinality_bounds(condition),
    do: condition |> get([:cardinality], 1) |> normalize_cardinality()

  defp normalize_cardinality(nil), do: {:ok, {1, nil}}

  defp normalize_cardinality(value) when is_integer(value) and value >= 0,
    do: {:ok, {value, nil}}

  defp normalize_cardinality({:exactly, value}) when is_integer(value) and value >= 0,
    do: {:ok, {value, value}}

  defp normalize_cardinality({:at_least, value}) when is_integer(value) and value >= 0,
    do: {:ok, {value, nil}}

  defp normalize_cardinality({:at_most, value}) when is_integer(value) and value >= 0,
    do: {:ok, {0, value}}

  defp normalize_cardinality(value) when is_map(value), do: cardinality_map(value)
  defp normalize_cardinality(_value), do: {:error, :invalid_cardinality}

  defp cardinality_map(value) do
    exact = get(value, [:exact, :exactly])
    minimum = if present?(exact), do: exact, else: get(value, [:min, :minimum], 1)
    maximum = if present?(exact), do: exact, else: get(value, [:max, :maximum])

    if is_integer(minimum) and minimum >= 0 and
         (is_nil(maximum) or (is_integer(maximum) and maximum >= minimum)) do
      {:ok, {minimum, maximum}}
    else
      {:error, :invalid_cardinality}
    end
  end

  defp same_proposition?(evidence, condition) when is_map(evidence) do
    get(evidence, [:proposition]) == get(condition, [:proposition])
  end

  defp same_proposition?(_evidence, _condition), do: false

  defp stance(evidence) do
    case get(evidence, [:stance, :support, :verdict], :supports) do
      true -> :supports
      false -> :contradicts
      value when value in [:supports, :supported, :affirmed, :positive] -> :supports
      value when value in [:contradicts, :contradicted, :denied, :negative] -> :contradicts
      _other -> :unknown
    end
  end

  defp subset_value?(nil, _actual), do: true
  defp subset_value?([], _actual), do: true
  defp subset_value?(required, :any), do: present?(required)

  defp subset_value?(required, actual) when is_map(required) and is_map(actual) do
    Enum.all?(required, fn {key, value} ->
      case fetch(actual, key) do
        {:ok, actual_value} -> subset_value?(value, actual_value)
        :error -> false
      end
    end)
  end

  defp subset_value?(required, actual) when is_list(required) do
    actual = listify(actual)
    Enum.all?(required, &(&1 in actual))
  end

  defp subset_value?(required, actual), do: required == actual

  defp constraint_covers?(%MapSet{} = allowed, actual), do: MapSet.member?(allowed, actual)
  defp constraint_covers?(allowed, actual) when is_list(allowed), do: actual in allowed
  defp constraint_covers?(allowed, actual), do: allowed == actual

  defp evidence_list(nil), do: []
  defp evidence_list(value) when is_list(value), do: Enum.filter(value, &is_map/1)

  defp evidence_list(value) when is_map(value) do
    cond do
      present?(get(value, [:proposition])) ->
        [value]

      is_list(get(value, [:evidence])) ->
        evidence_list(get(value, [:evidence]))

      is_map(get(value, [:evidence])) ->
        value |> get([:evidence]) |> Map.values() |> evidence_list()

      true ->
        value |> Map.values() |> evidence_list()
    end
  end

  defp evidence_list(_value), do: []

  defp reasons_for(results, kind) do
    for {^kind, reason} <- results, do: reason
  end

  defp evidence_refs(evidence) do
    evidence
    |> Enum.map(&evidence_ref/1)
    |> Enum.sort_by(&inspect/1)
  end

  defp evidence_ref(evidence),
    do: get(evidence, [:ref, :evidence_ref, :id], {:anonymous, get(evidence, [:proposition])})

  defp evidence_identity_key(evidence), do: {:evidence, evidence_ref(evidence)}

  # Cardinality counts independent issuers/sources, not differently named
  # copies of the same observation. Coverage still sees every unique record.
  defp evidence_identity(evidence) do
    get(evidence, [:issuer_ref]) || get(evidence, [:source_ref, :source]) ||
      evidence_ref(evidence)
  end

  defp condition_ref(condition),
    do:
      get(condition, [:ref, :condition_ref, :id], {:proposition, get(condition, [:proposition])})

  defp at_or_after?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left >= right
      _other -> false
    end
  end

  defp timestamp(value) when is_integer(value), do: {:ok, value}
  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.to_unix(value, :millisecond)}

  defp timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> then(&{:ok, &1})
  end

  defp timestamp(_value), do: :error

  defp listify(nil), do: []
  defp listify(%MapSet{} = value), do: MapSet.to_list(value)
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp get(map, fields, default \\ nil)

  defp get(map, fields, default) when is_map(map) do
    Enum.find_value(fields, default, fn field ->
      case fetch(map, field) do
        {:ok, nil} -> nil
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      value -> value
    end
  end

  defp get(_other, _fields, default), do: default

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error when is_atom(key) -> Map.fetch(map, Atom.to_string(key))
      :error -> :error
    end
  end
end
