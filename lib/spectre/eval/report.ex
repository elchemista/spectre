defmodule Spectre.Eval.Report do
  @moduledoc """
  Aggregate routing quality and LLM-use metrics for an evaluation corpus.
  """

  alias Spectre.Eval.Case
  alias Spectre.Eval.Result

  defstruct [
    :total,
    :passed,
    :failed,
    :pass_rate,
    :route_cases,
    :correct_routes,
    :route_accuracy,
    :llm_calls,
    :unnecessary_llm_calls,
    :missing_required_llm_calls,
    :errors,
    :clarifications,
    :duration_us,
    outcomes: %{},
    strategies: %{},
    confusion_matrix: %{},
    tags: %{},
    results: []
  ]

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          pass_rate: float(),
          route_cases: non_neg_integer(),
          correct_routes: non_neg_integer(),
          route_accuracy: float(),
          llm_calls: non_neg_integer(),
          unnecessary_llm_calls: non_neg_integer(),
          missing_required_llm_calls: non_neg_integer(),
          errors: non_neg_integer(),
          clarifications: non_neg_integer(),
          duration_us: map(),
          outcomes: map(),
          strategies: map(),
          confusion_matrix: map(),
          tags: map(),
          results: [Result.t()]
        }

  @doc """
  Aggregates case results into a report.
  """
  @spec new([Result.t()]) :: t()
  def new(results) when is_list(results) do
    total = length(results)
    passed = Enum.count(results, & &1.passed?)
    route_results = Enum.filter(results, &(&1.evaluation_case.expected_outcome == :route))
    correct_routes = Enum.count(route_results, &route_correct?/1)
    durations = Enum.map(results, & &1.receipt.duration_us)

    %__MODULE__{
      total: total,
      passed: passed,
      failed: total - passed,
      pass_rate: ratio(passed, total),
      route_cases: length(route_results),
      correct_routes: correct_routes,
      route_accuracy: ratio(correct_routes, length(route_results)),
      llm_calls: Enum.count(results, & &1.receipt.llm_called?),
      unnecessary_llm_calls: count_violation(results, :unnecessary_llm_call),
      missing_required_llm_calls: count_violation(results, :missing_required_llm_call),
      errors: Enum.count(results, &(&1.receipt.outcome == :error)),
      clarifications: Enum.count(results, &(&1.receipt.outcome == :clarify)),
      duration_us: duration_stats(durations),
      outcomes: frequencies(results, & &1.receipt.outcome),
      strategies: frequencies(results, &(&1.receipt.strategy || :none)),
      confusion_matrix: confusion_matrix(route_results),
      tags: tag_stats(results),
      results: results
    }
  end

  @doc """
  Checks configurable CI thresholds.

  Defaults require every case to pass and allow no missing or unnecessary LLM
  calls.
  """
  @spec acceptable?(t(), keyword()) :: boolean()
  def acceptable?(%__MODULE__{} = report, opts \\ []) do
    report.pass_rate >= Keyword.get(opts, :min_pass_rate, 1.0) and
      report.unnecessary_llm_calls <= Keyword.get(opts, :max_unnecessary_llm, 0) and
      report.missing_required_llm_calls <= Keyword.get(opts, :max_missing_llm, 0) and
      below_optional_limit?(report.errors, Keyword.get(opts, :max_errors))
  end

  @doc """
  Returns a JSON-safe report map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    report
    |> Map.from_struct()
    |> Map.update!(:results, &Enum.map(&1, fn result -> Result.to_map(result) end))
  end

  @doc """
  Formats the compact terminal summary used by `mix spectre.eval`.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = report) do
    strategy_lines =
      report.strategies
      |> Enum.sort_by(fn {strategy, _count} -> to_string(strategy) end)
      |> Enum.map_join("\n", fn {strategy, count} ->
        "  #{String.pad_trailing(to_string(strategy), 24)} #{count}"
      end)

    failures =
      report.results
      |> Enum.reject(& &1.passed?)
      |> Enum.map_join("\n", fn result ->
        types = Enum.map_join(result.violations, ", ", &to_string(&1.type))
        "  #{result.evaluation_case.id}: #{types}"
      end)

    """
    Spectre routing evaluation

    Cases:                    #{report.total}
    Passed:                   #{report.passed} / #{report.total} (#{percent(report.pass_rate)})
    Correct routes:           #{report.correct_routes} / #{report.route_cases} (#{percent(report.route_accuracy)})
    LLM calls:                #{report.llm_calls}
    Unnecessary LLM calls:    #{report.unnecessary_llm_calls}
    Missing required calls:   #{report.missing_required_llm_calls}
    Clarifications:           #{report.clarifications}
    Errors:                   #{report.errors}
    Duration p50/p95:         #{report.duration_us.p50} / #{report.duration_us.p95} us

    Strategy usage:
    #{strategy_lines}
    #{failure_section(failures)}
    """
    |> String.trim_trailing()
  end

  @spec route_correct?(Result.t()) :: boolean()
  defp route_correct?(%Result{} = result) do
    expected = Case.expected_routes(result.evaluation_case)
    actual = Case.canonical(result.receipt.label)
    result.receipt.outcome == :route and (expected == [] or actual in expected)
  end

  @spec count_violation([Result.t()], atom()) :: non_neg_integer()
  defp count_violation(results, type) do
    Enum.count(results, fn result -> Enum.any?(result.violations, &(&1.type == type)) end)
  end

  @spec frequencies([Result.t()], (Result.t() -> term())) :: map()
  defp frequencies(results, fun) do
    Enum.frequencies_by(results, fun)
  end

  @spec confusion_matrix([Result.t()]) :: map()
  defp confusion_matrix(results) do
    Enum.reduce(results, %{}, fn result, matrix ->
      expected = result.evaluation_case |> Case.expected_routes() |> Enum.join("|")
      actual = Case.canonical(result.receipt.label) || "NONE"

      Map.update(matrix, expected, %{actual => 1}, fn actuals ->
        Map.update(actuals, actual, 1, &(&1 + 1))
      end)
    end)
  end

  @spec tag_stats([Result.t()]) :: map()
  defp tag_stats(results) do
    Enum.reduce(results, %{}, fn result, stats ->
      Enum.reduce(result.evaluation_case.tags, stats, fn tag, stats ->
        update_tag_stats(stats, tag, result)
      end)
    end)
  end

  @spec update_tag_stats(map(), String.t(), Result.t()) :: map()
  defp update_tag_stats(stats, tag, result) do
    Map.update(stats, tag, %{total: 1, passed: pass_count(result)}, fn value ->
      %{total: value.total + 1, passed: value.passed + pass_count(result)}
    end)
  end

  @spec pass_count(Result.t()) :: 0 | 1
  defp pass_count(%Result{passed?: true}), do: 1
  defp pass_count(%Result{}), do: 0

  @spec duration_stats([non_neg_integer()]) :: map()
  defp duration_stats([]), do: %{total: 0, average: 0, p50: 0, p95: 0, max: 0}

  defp duration_stats(durations) do
    sorted = Enum.sort(durations)

    %{
      total: Enum.sum(sorted),
      average: div(Enum.sum(sorted), length(sorted)),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      max: List.last(sorted)
    }
  end

  @spec percentile([non_neg_integer()], float()) :: non_neg_integer()
  defp percentile(sorted, fraction) do
    index = max(ceil(length(sorted) * fraction) - 1, 0)
    Enum.at(sorted, index)
  end

  @spec ratio(non_neg_integer(), non_neg_integer()) :: float()
  defp ratio(_part, 0), do: 0.0
  defp ratio(part, whole), do: part / whole

  @spec percent(float()) :: String.t()
  defp percent(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  @spec failure_section(String.t()) :: String.t()
  defp failure_section(""), do: ""
  defp failure_section(failures), do: "\nFailures:\n#{failures}"

  @spec below_optional_limit?(non_neg_integer(), non_neg_integer() | nil) :: boolean()
  defp below_optional_limit?(_value, nil), do: true
  defp below_optional_limit?(value, limit), do: value <= limit
end
