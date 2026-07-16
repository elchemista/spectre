defmodule Spectre.Eval.Result do
  @moduledoc """
  Result of comparing one routing receipt with its evaluation expectations.
  """

  alias Spectre.Eval.Case
  alias Spectre.Router.Receipt

  defstruct [:evaluation_case, :receipt, :passed?, violations: []]

  @type violation :: %{
          required(:type) => atom(),
          optional(:expected) => term(),
          optional(:actual) => term()
        }

  @type t :: %__MODULE__{
          evaluation_case: Case.t(),
          receipt: Receipt.t(),
          passed?: boolean(),
          violations: [violation()]
        }

  @doc """
  Compares a receipt with one case.
  """
  @spec new(Case.t(), Receipt.t()) :: t()
  def new(%Case{} = evaluation_case, %Receipt{} = receipt) do
    violations =
      []
      |> check_outcome(evaluation_case, receipt)
      |> check_route(evaluation_case, receipt)
      |> check_strategy(evaluation_case, receipt)
      |> check_llm(evaluation_case, receipt)
      |> check_duration(evaluation_case, receipt)
      |> Enum.reverse()

    %__MODULE__{
      evaluation_case: evaluation_case,
      receipt: receipt,
      passed?: violations == [],
      violations: violations
    }
  end

  @doc """
  Converts a result into a JSON-safe map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    evaluation_case = result.evaluation_case
    receipt = result.receipt

    %{
      id: evaluation_case.id,
      tags: evaluation_case.tags,
      passed: result.passed?,
      expected: %{
        outcome: evaluation_case.expected_outcome,
        routes: Case.expected_routes(evaluation_case),
        strategy: evaluation_case.expected_strategy,
        llm: evaluation_case.llm
      },
      actual: %{
        outcome: receipt.outcome,
        label: receipt.label,
        strategy: receipt.strategy,
        accepted: receipt.accepted?,
        llm_called: receipt.llm_called?,
        duration_us: receipt.duration_us,
        error: receipt.error,
        attempts: receipt.attempts,
        candidates: receipt.candidates,
        trace_codes: receipt.trace_codes
      },
      violations: result.violations
    }
  end

  @spec check_outcome([violation()], Case.t(), Receipt.t()) :: [violation()]
  defp check_outcome(violations, evaluation_case, receipt) do
    if evaluation_case.expected_outcome == receipt.outcome do
      violations
    else
      [
        %{
          type: :outcome_mismatch,
          expected: evaluation_case.expected_outcome,
          actual: receipt.outcome
        }
        | violations
      ]
    end
  end

  @spec check_route([violation()], Case.t(), Receipt.t()) :: [violation()]
  defp check_route(violations, evaluation_case, receipt) do
    expected = Case.expected_routes(evaluation_case)
    actual = Case.canonical(receipt.label)

    if expected == [] or actual in expected do
      violations
    else
      [%{type: :route_mismatch, expected: expected, actual: actual} | violations]
    end
  end

  @spec check_strategy([violation()], Case.t(), Receipt.t()) :: [violation()]
  defp check_strategy(violations, %Case{expected_strategy: nil}, _receipt), do: violations

  defp check_strategy(violations, evaluation_case, receipt) do
    expected = Case.canonical(evaluation_case.expected_strategy)
    actual = Case.canonical(receipt.strategy)

    if expected == actual do
      violations
    else
      [%{type: :strategy_mismatch, expected: expected, actual: actual} | violations]
    end
  end

  @spec check_llm([violation()], Case.t(), Receipt.t()) :: [violation()]
  defp check_llm(violations, %Case{llm: :forbidden}, %Receipt{llm_called?: true}) do
    [%{type: :unnecessary_llm_call, expected: false, actual: true} | violations]
  end

  defp check_llm(violations, %Case{llm: :required}, %Receipt{llm_called?: false}) do
    [%{type: :missing_required_llm_call, expected: true, actual: false} | violations]
  end

  defp check_llm(violations, _evaluation_case, _receipt), do: violations

  @spec check_duration([violation()], Case.t(), Receipt.t()) :: [violation()]
  defp check_duration(violations, %Case{max_duration_us: nil}, _receipt), do: violations

  defp check_duration(violations, evaluation_case, receipt) do
    if receipt.duration_us <= evaluation_case.max_duration_us do
      violations
    else
      [
        %{
          type: :duration_exceeded,
          expected: evaluation_case.max_duration_us,
          actual: receipt.duration_us
        }
        | violations
      ]
    end
  end
end
