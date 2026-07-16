defmodule Mix.Tasks.Spectre.Eval do
  @moduledoc """
  Evaluates Spectre routing accuracy and LLM usage from a JSONL corpus.

      mix spectre.eval MyApp.Agent test/fixtures/routing.jsonl

      mix spectre.eval --agent MyApp.Agent test/fixtures/routing.jsonl \
        --json tmp/routing-report.json \
        --min-pass-rate 0.98

  The task exits unsuccessfully when configured thresholds are not met.

  ## Options

    * `--agent` - agent module; may instead be the first positional argument.
    * `--json` - write the complete JSON report to this path.
    * `--min-pass-rate` - minimum accepted case pass ratio, default `1.0`.
    * `--max-unnecessary-llm` - maximum forbidden LLM calls, default `0`.
    * `--max-missing-llm` - maximum missing required LLM calls, default `0`.
    * `--max-errors` - optional maximum number of router errors.
  """

  use Mix.Task

  alias Spectre.Eval
  alias Spectre.Eval.Report

  @shortdoc "Evaluate routing accuracy and LLM usage"

  @switches [
    agent: :string,
    json: :string,
    min_pass_rate: :float,
    max_unnecessary_llm: :integer,
    max_missing_llm: :integer,
    max_errors: :integer
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    {agent_name, corpus_path} = positional_args(opts, args)
    agent = agent_module!(agent_name)
    corpus_path || Mix.raise(usage())

    case Eval.run(agent, corpus_path) do
      {:ok, report} ->
        Mix.shell().info(Report.format(report))
        maybe_write_json(report, Keyword.get(opts, :json))
        enforce_thresholds!(report, opts)
        :ok

      {:error, reason} ->
        Mix.raise("Spectre routing evaluation failed: #{inspect(reason)}")
    end
  end

  @spec positional_args(keyword(), [String.t()]) :: {String.t() | nil, String.t() | nil}
  defp positional_args(opts, args) do
    case Keyword.get(opts, :agent) do
      nil -> {Enum.at(args, 0), Enum.at(args, 1)}
      agent -> {agent, Enum.at(args, 0)}
    end
  end

  @spec agent_module!(String.t() | nil) :: module() | no_return()
  defp agent_module!(nil), do: Mix.raise(usage())

  defp agent_module!(name) do
    module = name |> String.split(".") |> Module.concat()

    if Code.ensure_loaded?(module) and function_exported?(module, :__spectre_rules__, 0) do
      module
    else
      Mix.raise("#{name} is not a loaded Spectre agent")
    end
  end

  @spec maybe_write_json(Report.t(), String.t() | nil) :: :ok
  defp maybe_write_json(_report, nil), do: :ok

  defp maybe_write_json(report, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(Report.to_map(report), pretty: true))
    Mix.shell().info("Wrote Spectre evaluation report to #{path}")
    :ok
  end

  @spec enforce_thresholds!(Report.t(), keyword()) :: :ok | no_return()
  defp enforce_thresholds!(report, opts) do
    threshold_opts =
      Keyword.take(opts, [
        :min_pass_rate,
        :max_unnecessary_llm,
        :max_missing_llm,
        :max_errors
      ])

    if Report.acceptable?(report, threshold_opts) do
      :ok
    else
      Mix.raise("Spectre routing evaluation did not meet its regression thresholds")
    end
  end

  @spec usage() :: String.t()
  defp usage do
    "expected: mix spectre.eval MyApp.Agent path/to/routing.jsonl"
  end
end
