defmodule Mix.Tasks.Spectre.Classifier.Dataset do
  @moduledoc """
  Exports classifier training rows from a Spectre agent.

  Route and policy declarations can provide training metadata:

      on :GREETING, regex: ~r/^hi$/i, train: true do
        reply :greeting
      end

      on :SPAM, via: [:classifier], train: true do
        reply :spam
      end

  `train: true` pulls examples for that label from configured classifier dataset
  sources or `--source` datasets. The DSL flag is boolean only; examples belong
  in dataset files.

  ## Usage

      mix spectre.classifier.dataset MyApp.Agent training/dataset.json --source training/raw.json

  ## Options

    * `--source` - additional dataset source used by routes marked
      `train: true`. May be passed more than once.
    * `--pretty` - pretty-print JSON output.
  """

  use Mix.Task

  alias Spectre.Training.Dataset

  @shortdoc "Export classifier dataset rows from a Spectre agent"

  @switches [
    source: :keep,
    pretty: :boolean
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")

    {cli_opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    agent = args |> Enum.at(0) |> agent_module!()
    out_path = Enum.at(args, 1, "training/dataset.json")

    case Dataset.from_agent(agent, cli_opts) do
      {:ok, rows} ->
        File.mkdir_p!(Path.dirname(out_path))
        File.write!(out_path, Jason.encode!(rows, pretty: Keyword.get(cli_opts, :pretty, true)))
        Mix.shell().info("Wrote #{length(rows)} Spectre classifier rows to #{out_path}")
        :ok

      {:error, reason} ->
        Mix.raise("Spectre classifier dataset export failed: #{inspect(reason)}")
    end
  end

  @spec agent_module!(String.t() | nil) :: module() | no_return()
  defp agent_module!(nil) do
    Mix.raise("expected an agent module, for example: mix spectre.classifier.dataset MyApp.Agent")
  end

  defp agent_module!(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end
end
