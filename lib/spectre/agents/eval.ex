defmodule Spectre.Eval do
  @moduledoc """
  Offline routing regression, not an agent runner or a governance evaluation.

      {:ok, flow} = Spectre.Eval.prepare(MyApp.Hello, "greetings")
      Spectre.Eval.run_file(flow, "test/my_app/hello_routes.jsonl")

  Each JSONL object has exactly `input` and `expected`. For example:

      {"input":"hello Ada","expected":{"status":"matched","rule":"greetings/hello"}}
      {"input":"refund","expected":{"status":"no_match"}}

  Expected statuses are `matched` (requires `rule`, optionally `via`),
  `ambiguous` (requires `rules`, order-independent), `no_match`, `halted`,
  `unrouted`, and `error`. Scores are not accuracy; only the expected routing
  outcome counts as a pass. Empty/invalid datasets are errors, never success.

  `run/3` accepts a prepared Router, Flow, or a function of one input returning
  a routing result. Use the function form for recorded classifier outputs or
  application-specific offline fixtures. No model, executor, cache training,
  Domain, or supervisor is started by this harness. Explicitly supplied
  pipelines/adapters/functions remain host code, not a sandbox or purity proof.

  Reports count all cases but retain at most `max_failures` (default 20),
  without input, captures or callback error details. `max_cases` defaults to
  10,000 and rejects larger datasets rather than silently evaluating a prefix.
  JSONL is read as a stream. Case numbers in file reports are physical lines.
  """

  alias Spectre.Agent.Flow
  alias Spectre.{Portable, Router}
  alias Spectre.Router.Selection

  @type target :: Router.t() | Flow.t() | (term() -> Flow.result())
  @type report :: %{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          failures: [map()]
        }

  @doc """
  Compiles a named flow from current Agent/Router/Skill code without publication.

  Nested Skill paths work too, e.g. `support/questions`. `:pipelines` and
  `:adapters` are the same explicit registries as `Spectre.Agent.flow/3`.
  This evaluation plan is bound to code, not an activated Definition. To test
  an exact published Definition, pass its prepared `Spectre.Agent.flow/3` to `run/3`.
  Cache/classifier bridges are supplied explicitly through `:adapters`.
  """
  @spec prepare(module(), String.t(), keyword()) :: {:ok, Flow.t()} | {:error, term()}
  def prepare(module, name, opts \\ [])

  def prepare(module, name, opts) when is_binary(name) do
    case Flow.from_code(module, name, opts) do
      {:ok, flow, _declaration} -> {:ok, flow}
      {:error, :unknown_agent_flow} -> {:error, :unknown_eval_flow}
      error -> error
    end
  end

  def prepare(_module, _name, _opts), do: {:error, :invalid_eval_flow}

  @doc "Evaluates an enumerable of input/expected maps, keeping bounded failure details."
  @spec run(target(), Enumerable.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(target, cases, opts \\ []) do
    with {:ok, route} <- evaluator(target),
         {:ok, limits} <- limits(opts) do
      cases
      |> Stream.with_index(1)
      |> evaluate(route, limits)
    end
  end

  @doc "Reads JSONL without loading the dataset into memory; blank lines are ignored."
  @spec run_file(target(), Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run_file(target, path, opts \\ []) do
    with {:ok, route} <- evaluator(target),
         {:ok, limits} <- limits(opts) do
      case File.open(path, [:read]) do
        {:ok, file} ->
          try do
            file
            |> IO.binstream(:line)
            |> Stream.with_index(1)
            |> Stream.reject(fn {line, _index} -> String.trim(line) == "" end)
            |> Stream.map(fn {line, index} -> {decode(line), index} end)
            |> evaluate(route, limits)
          after
            File.close(file)
          end

        {:error, reason} ->
          {:error, {:eval_file, reason}}
      end
    end
  end

  defp evaluator(%Router{} = router), do: {:ok, &Router.route(router, &1)}
  defp evaluator(fun) when is_function(fun, 1), do: {:ok, fun}

  defp evaluator(target) do
    case Flow.fetch(target) do
      {:ok, flow} -> {:ok, &Flow.route(flow, &1)}
      {:error, _} -> {:error, :invalid_eval_target}
    end
  end

  defp limits(opts) do
    with {:ok, opts} <- Portable.normalize_attrs(opts, [:max_cases, :max_failures], :eval),
         limits = Map.merge(%{max_cases: 10_000, max_failures: 20}, opts),
         true <- Enum.all?(limits, fn {_key, n} -> is_integer(n) and n > 0 end) do
      {:ok, limits}
    else
      false -> {:error, :invalid_eval_limits}
      error -> error
    end
  end

  defp decode(line) when byte_size(line) <= 1_048_576 do
    case JSON.decode(line) do
      {:ok, value} -> value
      {:error, _} -> {:invalid, :invalid_json}
    end
  end

  defp decode(_line), do: {:invalid, :eval_line_too_large}

  defp evaluate(cases, route, limits) do
    initial = %{total: 0, passed: 0, failed: 0, failures: []}

    cases
    |> Enum.reduce_while({:ok, initial}, fn {sample, index}, {:ok, report} ->
      with true <- report.total < limits.max_cases,
           {:ok, input, expected} <- sample(sample),
           {:ok, actual} <- result(route.(input)) do
        {:cont, {:ok, record(report, index, expected, actual, limits.max_failures)}}
      else
        false -> {:halt, {:error, :eval_case_limit_exceeded}}
        {:error, reason} -> {:halt, {:error, {:eval_case, index, reason}}}
      end
    end)
    |> finish()
  end

  defp sample(%{"input" => input, "expected" => expected} = value) when map_size(value) == 2 do
    with :ok <- expectation(expected), do: {:ok, input, expected}
  end

  defp sample({:invalid, reason}), do: {:error, reason}
  defp sample(_value), do: {:error, :invalid_eval_case}

  defp expectation(%{"status" => "matched", "rule" => rule} = expected)
       when is_binary(rule) and rule != "" do
    if Enum.all?(Map.keys(expected), &(&1 in ["status", "rule", "via"])) and
         (not Map.has_key?(expected, "via") or is_binary(expected["via"])),
       do: :ok,
       else: {:error, :invalid_eval_expectation}
  end

  defp expectation(%{"status" => "ambiguous", "rules" => rules} = value)
       when map_size(value) == 2 and is_list(rules) and length(rules) >= 2 do
    if Enum.all?(rules, &(is_binary(&1) and &1 != "")) and Enum.uniq(rules) == rules,
      do: :ok,
      else: {:error, :invalid_eval_expectation}
  end

  defp expectation(%{"status" => status} = value)
       when map_size(value) == 1 and status in ["no_match", "halted", "unrouted", "error"],
       do: :ok

  defp expectation(_value), do: {:error, :invalid_eval_expectation}

  defp result({:ok, %Selection{} = s}),
    do: {:ok, %{"status" => "matched", "rule" => s.rule, "via" => s.via}}

  defp result({:ambiguous, rules}) do
    value = %{"status" => "ambiguous", "rules" => rules}

    case expectation(value) do
      :ok -> {:ok, %{value | "rules" => Enum.sort(rules)}}
      _invalid -> {:error, :invalid_eval_result}
    end
  end

  defp result(:no_match), do: {:ok, %{"status" => "no_match"}}
  defp result({:halt, _}), do: {:ok, %{"status" => "halted"}}
  defp result({:unrouted, _}), do: {:ok, %{"status" => "unrouted"}}
  defp result({:error, _}), do: {:ok, %{"status" => "error"}}
  defp result(_other), do: {:error, :invalid_eval_result}

  defp record(report, index, expected, actual, max_failures) do
    matches? =
      Enum.all?(expected, fn
        {"rules", rules} -> Enum.sort(rules) === actual["rules"]
        {key, value} -> value === actual[key]
      end)

    report = %{report | total: report.total + 1}

    if matches? do
      %{report | passed: report.passed + 1}
    else
      failure = %{case: index, expected: expected, actual: actual}

      failures =
        if report.failed < max_failures, do: [failure | report.failures], else: report.failures

      %{report | failed: report.failed + 1, failures: failures}
    end
  end

  defp finish({:ok, %{total: 0}}), do: {:error, :empty_eval_dataset}
  defp finish({:ok, report}), do: {:ok, %{report | failures: Enum.reverse(report.failures)}}
  defp finish(error), do: error
end
