defmodule Spectre.Kernel.Recognition do
  @moduledoc """
  Pure recognition of typed Evidence against typed Conditions.

  Recognition answers only whether facts satisfy declared conditions. It
  never resolves a Mandate, grants authority or performs I/O. Durable maps are
  decoded before entering this module; consequently this algebra has one
  record shape and cannot assign different meaning to atom- and string-keyed
  representations of the same supposed fact.

  Proposition, bindings, coverage and parameters remain portable opaque
  values chosen by the application. Reserved recognition parameters use
  string keys: `"issuer_refs"`, `"source_refs"`, `"required_labels"` and
  `"accepted_assumptions"`.

  A missing, stale, insufficient or provisional proof is `:undecidable`.
  Explicit contrary Evidence is `:unsatisfied`; conflicting support and
  contradiction remains `:undecidable` rather than being resolved by order.
  """

  alias Spectre.{Condition, Evidence, Label}

  @type reason :: term()
  @type result :: :satisfied | {:unsatisfied, [reason()]} | {:undecidable, [reason()]}

  @doc "Checks every condition against Evidence available at trusted `time`."
  @spec check([Condition.t()] | nil, [Evidence.t()] | map() | nil, integer()) :: result()
  def check(conditions, _evidence, _time) when conditions in [nil, []], do: :satisfied

  def check(conditions, evidence, time) when is_list(conditions) and is_integer(time) do
    {result, _basis_refs} = check_with_basis(conditions, evidence, time)
    result
  end

  def check(_conditions, _evidence, _time), do: {:undecidable, [:invalid_conditions]}

  @doc """
  Checks conditions and returns the exact qualified Evidence basis.

  The basis contains every current supporting or contradicting record that can
  affect the result, plus qualified records used to establish assumptions.
  This lets admission freeze the complete factual basis into its Act.
  """
  @spec check_with_basis([Condition.t()] | nil, [Evidence.t()] | map() | nil, integer()) ::
          {result(), [String.t()]}
  def check_with_basis(conditions, _evidence, _time) when conditions in [nil, []],
    do: {:satisfied, []}

  def check_with_basis(conditions, evidence, time)
      when is_list(conditions) and is_integer(time) do
    evidence = evidence_list(evidence)

    {results, basis} =
      Enum.map_reduce(conditions, MapSet.new(), fn condition, basis ->
        {result, condition_basis} = evaluate(condition, evidence, time)
        {result, MapSet.union(basis, condition_basis)}
      end)

    {combined_result(results), basis |> MapSet.to_list() |> Enum.sort()}
  end

  def check_with_basis(_conditions, _evidence, _time),
    do: {{:undecidable, [:invalid_conditions]}, []}

  @doc "Checks that every Evidence reference used by Recognition was declared by the Candidate."
  @spec validate_declared_basis([String.t()], [String.t()]) :: :ok | {:error, term()}
  def validate_declared_basis(required_refs, declared_refs)
      when is_list(required_refs) and is_list(declared_refs) do
    case required_refs -- declared_refs do
      [] -> :ok
      missing -> {:error, {:recognition_basis_not_declared, missing}}
    end
  end

  def validate_declared_basis(_required_refs, _declared_refs),
    do: {:error, :invalid_recognition_basis}

  @doc "Checks one Condition and returns a stable local explanation."
  @spec check_condition(Condition.t(), [Evidence.t()] | map(), integer()) ::
          :satisfied | {:unsatisfied, reason()} | {:undecidable, reason()}
  def check_condition(%Condition{} = condition, evidence, time) when is_integer(time) do
    {result, _basis} = evaluate(condition, evidence_list(evidence), time)
    result
  end

  def check_condition(condition, _evidence, _time),
    do: {:undecidable, {:unknown_condition, condition_ref(condition)}}

  @doc false
  @spec qualified?(Evidence.t(), Condition.t(), [Evidence.t()] | map(), integer()) :: boolean()
  def qualified?(%Evidence{} = evidence, %Condition{} = condition, evidence_set, time)
      when is_integer(time) do
    match?(
      {:ok, %MapSet{}},
      qualify(evidence, condition, evidence_list(evidence_set), time, MapSet.new())
    )
  end

  def qualified?(_evidence, _condition, _evidence_set, _time), do: false

  defp combined_result(results) do
    unsatisfied = reasons_for(results, :unsatisfied)
    undecidable = reasons_for(results, :undecidable)

    cond do
      unsatisfied != [] -> {:unsatisfied, unsatisfied}
      undecidable != [] -> {:undecidable, undecidable}
      true -> :satisfied
    end
  end

  defp evaluate(%Condition{} = condition, all_evidence, time) do
    relevant =
      all_evidence
      |> Enum.filter(&same_proposition?(&1, condition))
      |> Enum.uniq_by(& &1.ref)

    {qualified, rejected, basis} = qualify_all(relevant, condition, all_evidence, time)
    supporting = Enum.filter(qualified, &(&1.stance == :supports))
    contradicting = Enum.filter(qualified, &(&1.stance == :contradicts))

    result =
      classify(
        condition,
        supporting,
        contradicting,
        rejected,
        cardinality_bounds(condition)
      )

    {result, basis}
  end

  defp evaluate(condition, _evidence, _time),
    do: {{:undecidable, {:unknown_condition, condition_ref(condition)}}, MapSet.new()}

  defp qualify_all(relevant, condition, all_evidence, time) do
    Enum.reduce(relevant, {[], [], MapSet.new()}, fn item, {accepted, rejected, basis} ->
      case qualify(item, condition, all_evidence, time, MapSet.new()) do
        {:ok, item_basis} ->
          {[item | accepted], rejected, MapSet.union(basis, item_basis)}

        {:error, reason} ->
          {accepted, [{item.ref, reason} | rejected], basis}
      end
    end)
  end

  defp classify(condition, supporting, contradicting, rejected, {minimum, maximum}) do
    count = supporting |> Enum.map(&evidence_identity/1) |> Enum.uniq() |> length()

    cond do
      supporting != [] and contradicting != [] ->
        {:undecidable,
         {condition.ref, :conflicting_evidence, evidence_refs(supporting ++ contradicting)}}

      contradicting != [] ->
        {:unsatisfied, {condition.ref, :contradicted, evidence_refs(contradicting)}}

      not is_nil(maximum) and count > maximum ->
        {:undecidable, {condition.ref, :cardinality_exceeded, %{maximum: maximum, actual: count}}}

      count < minimum ->
        {:undecidable,
         {condition.ref, :insufficient_evidence,
          %{minimum: minimum, actual: count, rejected: Enum.reverse(rejected)}}}

      not coverage_satisfied?(condition, supporting) ->
        {:undecidable, {condition.ref, :coverage_incomplete, condition.coverage}}

      true ->
        :satisfied
    end
  end

  defp qualify(evidence, condition, evidence_set, time, visited) do
    identity = {:evidence, evidence.ref}

    with false <- MapSet.member?(visited, identity),
         visited = MapSet.put(visited, identity),
         :ok <- accepted_provenance(evidence, condition),
         :ok <- accepted_issuer(evidence, condition),
         :ok <- accepted_source(evidence, condition),
         :ok <- accepted_provisional(evidence, condition),
         :ok <- valid_at(evidence, time),
         :ok <- fresh_enough(evidence, condition, time),
         :ok <- bindings_cover(evidence, condition),
         :ok <- labels_cover(evidence, condition),
         {:ok, assumption_basis} <-
           assumptions_supported(evidence, condition, evidence_set, time, visited) do
      {:ok, MapSet.put(assumption_basis, evidence.ref)}
    else
      true -> {:error, :cyclic_evidence_assumptions}
      {:error, _reason} = error -> error
    end
  end

  defp accepted_provenance(evidence, condition) do
    if evidence.provenance in condition.accepted_provenance,
      do: :ok,
      else: {:error, {:unaccepted_provenance, evidence.provenance}}
  end

  defp accepted_issuer(evidence, condition) do
    accepted = parameter(condition, "issuer_refs")

    if is_nil(accepted) or constraint_covers?(accepted, evidence.issuer_ref),
      do: :ok,
      else: {:error, {:unaccepted_issuer, evidence.issuer_ref}}
  end

  defp accepted_source(evidence, condition) do
    accepted = parameter(condition, "source_refs")

    if is_nil(accepted) or constraint_covers?(accepted, evidence.source_ref),
      do: :ok,
      else: {:error, {:unaccepted_source, evidence.source_ref}}
  end

  defp accepted_provisional(%Evidence{provisional: false}, _condition), do: :ok
  defp accepted_provisional(_evidence, %Condition{allow_provisional: true}), do: :ok

  defp accepted_provisional(_evidence, _condition),
    do: {:error, :provisional_evidence_not_accepted}

  defp valid_at(evidence, time) do
    case Evidence.temporal_status(evidence, time) do
      :current -> :ok
      :from_future -> {:error, :evidence_from_future}
      :not_yet_valid -> {:error, :evidence_not_yet_valid}
      :expired -> {:error, :evidence_expired}
    end
  end

  defp fresh_enough(evidence, condition, time) do
    if Evidence.current_at?(evidence, time, condition.freshness_ms),
      do: :ok,
      else: {:error, :stale_or_unverifiable_freshness}
  end

  defp bindings_cover(evidence, condition) do
    if subset_value?(condition.bindings, evidence.bindings),
      do: :ok,
      else: {:error, :binding_mismatch}
  end

  defp labels_cover(evidence, condition) do
    required = parameter(condition, "required_labels")
    actual = Enum.map(evidence.labels, &Label.canonical/1)

    if subset_value?(required, actual),
      do: :ok,
      else: {:error, :required_labels_missing}
  end

  defp assumptions_supported(evidence, condition, evidence_set, time, visited) do
    accepted = parameter(condition, "accepted_assumptions", [])

    Enum.reduce_while(evidence.assumptions, {:ok, MapSet.new()}, fn assumption, {:ok, basis} ->
      case assumption_status(
             assumption,
             assumption in accepted,
             condition,
             evidence_set,
             time,
             visited
           ) do
        {:ok, assumption_basis} ->
          {:cont, {:ok, MapSet.union(basis, assumption_basis)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp assumption_status(assumption, accepted?, condition, evidence_set, time, visited) do
    {supporting, contradicting, basis} =
      Enum.reduce(evidence_set, {[], [], MapSet.new()}, fn candidate, accumulated ->
        if candidate.proposition == assumption do
          qualification = qualify(candidate, condition, evidence_set, time, visited)
          collect_assumption(qualification, candidate, accumulated)
        else
          accumulated
        end
      end)

    cond do
      supporting != [] and contradicting != [] ->
        {:error,
         {:conflicting_evidence_assumption, assumption,
          evidence_refs(supporting ++ contradicting)}}

      contradicting != [] ->
        {:error, {:contradicted_evidence_assumption, assumption, evidence_refs(contradicting)}}

      supporting != [] or accepted? ->
        {:ok, basis}

      true ->
        {:error, {:unresolved_evidence_assumption, assumption}}
    end
  end

  defp collect_assumption({:ok, candidate_basis}, candidate, {supporting, contradicting, basis}) do
    {
      if(candidate.stance == :supports, do: [candidate | supporting], else: supporting),
      if(candidate.stance == :contradicts, do: [candidate | contradicting], else: contradicting),
      MapSet.union(basis, candidate_basis)
    }
  end

  defp collect_assumption({:error, _reason}, _candidate, accumulated), do: accumulated

  defp coverage_satisfied?(%Condition{coverage: required}, _evidence)
       when required in [nil, :any, :all],
       do: true

  defp coverage_satisfied?(%Condition{coverage: required}, evidence) do
    actual =
      Enum.reduce(evidence, empty_coverage(required), fn item, acc ->
        merge_coverage(acc, item.bindings)
      end)

    subset_value?(required, actual)
  end

  defp empty_coverage(required) when is_map(required), do: %{}
  defp empty_coverage(_required), do: []

  defp merge_coverage(acc, nil), do: acc

  defp merge_coverage(acc, value) when is_list(acc) do
    (acc ++ List.wrap(value)) |> Enum.uniq()
  end

  defp merge_coverage(acc, value) when is_map(acc) and is_map(value) do
    Map.merge(acc, value, fn _key, left, right -> merge_coverage(List.wrap(left), right) end)
  end

  defp merge_coverage(acc, _value), do: acc

  defp cardinality_bounds(%Condition{cardinality: cardinality}) do
    {Map.fetch!(cardinality, "min"), Map.fetch!(cardinality, "max")}
  end

  defp same_proposition?(evidence, condition), do: evidence.proposition == condition.proposition

  defp subset_value?(nil, _actual), do: true
  defp subset_value?([], _actual), do: true
  defp subset_value?(_required, :any), do: true

  defp subset_value?(required, actual) when is_map(required) and is_map(actual) do
    Enum.all?(required, fn {key, value} ->
      case Map.fetch(actual, key) do
        {:ok, actual_value} -> subset_value?(value, actual_value)
        :error -> false
      end
    end)
  end

  defp subset_value?(required, actual) when is_list(required) and is_list(actual) do
    MapSet.subset?(MapSet.new(required), MapSet.new(actual))
  end

  defp subset_value?(required, actual), do: required == actual

  defp constraint_covers?(%MapSet{} = allowed, actual), do: MapSet.member?(allowed, actual)
  defp constraint_covers?(allowed, actual) when is_list(allowed), do: actual in allowed
  defp constraint_covers?(allowed, actual), do: allowed == actual

  defp evidence_list(nil), do: []
  defp evidence_list(value) when is_list(value), do: Enum.filter(value, &match?(%Evidence{}, &1))

  defp evidence_list(value) when is_map(value) and not is_struct(value) do
    value |> Map.values() |> evidence_list()
  end

  defp evidence_list(_value), do: []

  defp reasons_for(results, kind), do: for({^kind, reason} <- results, do: reason)

  defp evidence_refs(evidence), do: evidence |> Enum.map(& &1.ref) |> Enum.sort()

  # Cardinality counts independent issuers, not differently named copies of
  # the same observation. Coverage still sees every unique Evidence record.
  defp evidence_identity(evidence), do: evidence.issuer_ref

  defp condition_ref(%Condition{ref: ref}), do: ref
  defp condition_ref(_invalid), do: :invalid_condition

  defp parameter(condition, key, default \\ nil),
    do: Map.get(condition.parameters, key, default)
end
