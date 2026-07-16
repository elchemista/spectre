defmodule Spectre.Eval do
  @moduledoc """
  Route-only routing regression evaluation.

  `Spectre.Eval` executes only input normalization and routing. Selected route
  handlers, actions, state adapters, memory adapters, journal stores, and online
  semantic learning are not executed.
  """

  alias Spectre.Eval.Case
  alias Spectre.Eval.Report
  alias Spectre.Eval.Result
  alias Spectre.Router

  @doc """
  Evaluates an agent against a JSONL path or a list of case structs/maps.

      {:ok, report} = Spectre.Eval.run(MyAgent, "test/fixtures/routing.jsonl")
  """
  @spec run(module(), Path.t() | [Case.t() | map()], keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def run(agent, source, opts \\ []) when is_atom(agent) and is_list(opts) do
    with {:ok, cases} <- load(source) do
      router_opts = Keyword.get(opts, :router_opts, [])

      results =
        Enum.map(cases, fn evaluation_case ->
          case_opts = Keyword.put(router_opts, :state, evaluation_case.state)
          {:ok, receipt} = Router.evaluate(agent, evaluation_case.input, case_opts)
          Result.new(evaluation_case, receipt)
        end)

      {:ok, Report.new(results)}
    end
  end

  @doc """
  Loads and validates JSONL cases or an in-memory case list.
  """
  @spec load(Path.t() | [Case.t() | map()]) :: {:ok, [Case.t()]} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> decode_jsonl(contents)
      {:error, reason} -> {:error, {:eval_corpus_read_failed, path, reason}}
    end
  end

  def load(cases) when is_list(cases) do
    cases
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, loaded} ->
      case Case.new(attrs) do
        {:ok, evaluation_case} -> {:cont, {:ok, [evaluation_case | loaded]}}
        {:error, reason} -> {:halt, {:error, {:invalid_eval_case, index, reason}}}
      end
    end)
    |> reverse_cases()
  end

  def load(other), do: {:error, {:invalid_eval_source, other}}

  @spec decode_jsonl(String.t()) :: {:ok, [Case.t()]} | {:error, term()}
  defp decode_jsonl(contents) do
    contents
    |> String.split(~r/\R/u)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, line_number}, {:ok, cases} ->
      decode_line(line, line_number, cases)
    end)
    |> reverse_cases()
  end

  @spec decode_line(String.t(), pos_integer(), [Case.t()]) ::
          {:cont, {:ok, [Case.t()]}} | {:halt, {:error, term()}}
  defp decode_line(line, line_number, cases) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      {:cont, {:ok, cases}}
    else
      with {:ok, attrs} <- Jason.decode(trimmed),
           {:ok, evaluation_case} <- Case.new(attrs) do
        {:cont, {:ok, [evaluation_case | cases]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_eval_case, line_number, reason}}}
      end
    end
  end

  @spec reverse_cases({:ok, [Case.t()]} | {:error, term()}) ::
          {:ok, [Case.t()]} | {:error, term()}
  defp reverse_cases({:ok, cases}), do: {:ok, Enum.reverse(cases)}
  defp reverse_cases({:error, reason}), do: {:error, reason}
end
