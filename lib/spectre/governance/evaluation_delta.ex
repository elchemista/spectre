defmodule Spectre.Governance.EvaluationDelta do
  @moduledoc """
  Deterministic comparison of parent and Candidate results on the same corpus.

  Parent/Candidate score deltas are computed only from protected cases. Cases
  introduced by the current Candidate are tracked separately and must pass,
  but can never improve its score or compensate for a protected regression.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Governance.Data

  @schema_version 1
  @max_results 10_000
  @fields [
    :schema_version,
    :protected_results,
    :candidate_owned_results,
    :protected_cases_digest,
    :candidate_cases_digest,
    :parent_score,
    :candidate_score,
    :score_delta,
    :min_score_delta,
    :max_regressions,
    :regressions,
    :candidate_case_failures,
    :passed
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            protected_results: [],
            candidate_owned_results: [],
            protected_cases_digest: nil,
            candidate_cases_digest: nil,
            parent_score: 0.0,
            candidate_score: 0.0,
            score_delta: 0.0,
            min_score_delta: 0.0,
            max_regressions: 0,
            regressions: [],
            candidate_case_failures: [],
            passed: false

  @type result :: %{
          required(String.t()) => String.t() | boolean() | number()
        }
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          protected_results: [map()],
          candidate_owned_results: [map()],
          protected_cases_digest: String.t(),
          candidate_cases_digest: String.t(),
          parent_score: float(),
          candidate_score: float(),
          score_delta: float(),
          min_score_delta: float(),
          max_regressions: non_neg_integer(),
          regressions: [String.t()],
          candidate_case_failures: [String.t()],
          passed: boolean()
        }

  @doc "Builds an evaluation delta from parent and Candidate result lists."
  @spec new([map()], [map()], keyword()) :: {:ok, t()} | {:error, term()}
  def new(parent_results, candidate_results, opts \\ [])

  def new(parent_results, candidate_results, opts)
      when is_list(parent_results) and is_list(candidate_results) and is_list(opts) and
             length(parent_results) <= @max_results and length(candidate_results) <= @max_results do
    candidate_case_ids = Keyword.get(opts, :candidate_case_ids, [])
    min_delta = Keyword.get(opts, :min_score_delta, 0.0)
    max_regressions = Keyword.get(opts, :max_regressions, 0)

    with {:ok, candidate_case_ids} <- ids(candidate_case_ids, :candidate_case_ids),
         :ok <- threshold(min_delta, max_regressions),
         {:ok, parent} <- normalize_results(parent_results, :parent),
         {:ok, candidate} <- normalize_results(candidate_results, :candidate),
         {:ok, protected, owned} <- partition(parent, candidate, candidate_case_ids) do
      build(protected, owned, min_delta, max_regressions)
    end
  end

  def new(parent_results, candidate_results, _opts),
    do:
      {:error, {:invalid_evaluation_delta_input, shape(parent_results), shape(candidate_results)}}

  @doc "Builds an evaluation delta or raises with the stable reason."
  @spec new!([map()], [map()], keyword()) :: t()
  def new!(parent_results, candidate_results, opts \\ []) do
    case new(parent_results, candidate_results, opts) do
      {:ok, delta} -> delta
      {:error, reason} -> raise ArgumentError, "invalid evaluation delta: #{inspect(reason)}"
    end
  end

  @doc "Returns JSON-shaped evaluation evidence."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = delta) do
    %{
      "schema_version" => delta.schema_version,
      "protected_results" => delta.protected_results,
      "candidate_owned_results" => delta.candidate_owned_results,
      "protected_cases_digest" => delta.protected_cases_digest,
      "candidate_cases_digest" => delta.candidate_cases_digest,
      "parent_score" => delta.parent_score,
      "candidate_score" => delta.candidate_score,
      "score_delta" => delta.score_delta,
      "min_score_delta" => delta.min_score_delta,
      "max_regressions" => delta.max_regressions,
      "regressions" => delta.regressions,
      "candidate_case_failures" => delta.candidate_case_failures,
      "passed" => delta.passed
    }
  end

  @doc "Restores and recomputes an evaluation delta from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when is_map(data) and not is_struct(data) do
    expected = Enum.map(@fields, &Atom.to_string/1)

    with [] <- Map.keys(data) -- expected,
         [] <- expected -- Map.keys(data),
         @schema_version <- Map.get(data, "schema_version"),
         {:ok, protected} <- restored_protected(Map.get(data, "protected_results")),
         {:ok, owned} <- restored_owned(Map.get(data, "candidate_owned_results")),
         :ok <- threshold(Map.get(data, "min_score_delta"), Map.get(data, "max_regressions")),
         {:ok, rebuilt} <-
           rebuild_restored(
             protected,
             owned,
             Map.get(data, "min_score_delta"),
             Map.get(data, "max_regressions")
           ),
         :ok <- exact_restored(rebuilt, data) do
      {:ok, rebuilt}
    else
      [_first | _rest] = fields ->
        {:error, {:invalid_evaluation_delta_fields, fields}}

      version when is_integer(version) ->
        {:error, {:unsupported_evaluation_delta_schema, version}}

      {:error, _reason} = error ->
        error

      _value ->
        {:error, :invalid_evaluation_delta_data}
    end
  end

  def from_data(value), do: {:error, {:invalid_evaluation_delta_data, shape(value)}}

  @doc "Returns the canonical evaluation-delta digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = delta), do: delta |> to_data() |> Value.digest!()

  defp normalize_results(results, side) do
    results
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {result, index}, {:ok, normalized} ->
      with {:ok, result} <- normalize_result(result),
           false <- Map.has_key?(normalized, result["case_id"]) do
        {:cont, {:ok, Map.put(normalized, result["case_id"], result)}}
      else
        true ->
          {:halt, {:error, {:duplicate_evaluation_case_result, side, result_id(result)}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_evaluation_case_result, side, index, reason}}}
      end
    end)
  end

  defp normalize_result(result) when is_map(result) and not is_struct(result) do
    allowed = [:case_id, :passed, :score, "case_id", "passed", "score"]

    with [] <- Map.keys(result) -- allowed,
         [] <- Data.alias_collisions(result, [:case_id, :passed, :score]),
         case_id when is_binary(case_id) and case_id != "" <- get(result, :case_id),
         passed when is_boolean(passed) <- get(result, :passed),
         score when is_number(score) <- get(result, :score, if(passed, do: 1.0, else: 0.0)),
         true <- finite?(score) do
      {:ok, %{"case_id" => case_id, "passed" => passed, "score" => score * 1.0}}
    else
      [_first | _rest] = fields -> {:error, {:invalid_evaluation_result_fields, fields}}
      _value -> {:error, :invalid_evaluation_result}
    end
  end

  defp normalize_result(value), do: {:error, {:invalid_evaluation_result, shape(value)}}

  defp partition(parent, candidate, candidate_case_ids) do
    parent_ids = parent |> Map.keys() |> Enum.sort()
    candidate_ids = candidate |> Map.keys() |> Enum.sort()
    protected_candidate_ids = candidate_ids -- candidate_case_ids

    cond do
      parent_ids != protected_candidate_ids ->
        {:error, {:evaluation_delta_case_mismatch, parent_ids, protected_candidate_ids}}

      Enum.sort(candidate_case_ids) != Enum.sort(candidate_ids -- parent_ids) ->
        {:error, :evaluation_delta_candidate_case_mismatch}

      true ->
        protected =
          Enum.map(
            parent_ids,
            &%{"parent" => Map.fetch!(parent, &1), "candidate" => Map.fetch!(candidate, &1)}
          )

        owned = Enum.map(candidate_case_ids, &Map.fetch!(candidate, &1))
        {:ok, protected, owned}
    end
  end

  defp build(protected, owned, min_delta, max_regressions) do
    parent_score = protected |> Enum.map(&get_in(&1, ["parent", "score"])) |> average()
    candidate_score = protected |> Enum.map(&get_in(&1, ["candidate", "score"])) |> average()
    score_delta = candidate_score - parent_score

    regressions =
      protected
      |> Enum.filter(fn pair -> pair["parent"]["passed"] and not pair["candidate"]["passed"] end)
      |> Enum.map(&get_in(&1, ["parent", "case_id"]))
      |> Enum.sort()

    candidate_failures =
      owned
      |> Enum.reject(& &1["passed"])
      |> Enum.map(& &1["case_id"])
      |> Enum.sort()

    passed =
      score_delta >= min_delta and length(regressions) <= max_regressions and
        candidate_failures == []

    {:ok,
     %__MODULE__{
       schema_version: @schema_version,
       protected_results: protected,
       candidate_owned_results: owned,
       protected_cases_digest:
         Value.digest!(Enum.map(protected, &get_in(&1, ["parent", "case_id"]))),
       candidate_cases_digest: Value.digest!(Enum.map(owned, & &1["case_id"])),
       parent_score: parent_score,
       candidate_score: candidate_score,
       score_delta: score_delta,
       min_score_delta: min_delta * 1.0,
       max_regressions: max_regressions,
       regressions: regressions,
       candidate_case_failures: candidate_failures,
       passed: passed
     }}
  end

  defp restored_protected(values) when is_list(values) and length(values) <= @max_results do
    Enum.reduce_while(values, {:ok, []}, fn
      %{"parent" => parent, "candidate" => candidate}, {:ok, normalized} ->
        with {:ok, parent} <- normalize_result(parent),
             {:ok, candidate} <- normalize_result(candidate),
             true <- parent["case_id"] == candidate["case_id"] do
          {:cont, {:ok, [%{"parent" => parent, "candidate" => candidate} | normalized]}}
        else
          _value -> {:halt, {:error, :invalid_evaluation_delta_protected_results}}
        end

      _value, _acc ->
        {:halt, {:error, :invalid_evaluation_delta_protected_results}}
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp restored_protected(values) when is_list(values),
    do: {:error, {:evaluation_delta_result_limit_exceeded, :protected, length(values)}}

  defp restored_protected(_value), do: {:error, :invalid_evaluation_delta_protected_results}

  defp restored_owned(values) when is_list(values) and length(values) <= @max_results do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize_result(value) do
        {:ok, result} -> {:cont, {:ok, [result | normalized]}}
        {:error, _reason} -> {:halt, {:error, :invalid_evaluation_delta_candidate_results}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp restored_owned(values) when is_list(values),
    do: {:error, {:evaluation_delta_result_limit_exceeded, :candidate_owned, length(values)}}

  defp restored_owned(_value), do: {:error, :invalid_evaluation_delta_candidate_results}

  defp rebuild_restored(protected, owned, min_delta, max_regressions) do
    parent_results = Enum.map(protected, & &1["parent"])
    candidate_results = Enum.map(protected, & &1["candidate"]) ++ owned
    candidate_case_ids = Enum.map(owned, & &1["case_id"])

    new(parent_results, candidate_results,
      candidate_case_ids: candidate_case_ids,
      min_score_delta: min_delta,
      max_regressions: max_regressions
    )
  end

  defp exact_restored(rebuilt, data) do
    if to_data(rebuilt) == data do
      :ok
    else
      {:error, :evaluation_delta_integrity_mismatch}
    end
  end

  defp ids(values, _field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and
         length(values) == length(Enum.uniq(values)),
       do: {:ok, Enum.sort(values)},
       else: {:error, :invalid_evaluation_delta_case_ids}
  end

  defp ids(value, field), do: {:error, {:invalid_evaluation_delta_field, field, value}}

  defp threshold(min_delta, max_regressions)
       when is_number(min_delta) and is_integer(max_regressions) and max_regressions >= 0 do
    if finite?(min_delta), do: :ok, else: {:error, :invalid_evaluation_delta_threshold}
  end

  defp threshold(_min_delta, _max_regressions), do: {:error, :invalid_evaluation_delta_threshold}

  defp finite?(value) when is_integer(value), do: true
  defp finite?(value) when is_float(value), do: abs(value) < 1.0e308

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp result_id(result) when is_map(result), do: get(result, :case_id)
  defp result_id(_value), do: nil

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
