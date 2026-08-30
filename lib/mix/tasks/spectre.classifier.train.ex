defmodule Mix.Tasks.Spectre.Classifier.Train do
  @moduledoc """
  Trains Spectre's local classifier artifact from a JSON dataset.

  Dataset rows must contain `"text"` and either `"label"` or `"intent"`.

  ## Usage

      mix spectre.classifier.train training/dataset.json artifacts/spectre

  ## Options

    * `--model` - embedding model id.
    * `--accept-threshold` - minimum top score for normal acceptance.
    * `--margin-threshold` - minimum gap between first and second score.
    * `--high-confidence-threshold` - score that accepts regardless of margin.
  """

  use Mix.Task

  alias Spectre.Classifier.Encoder
  alias Spectre.Classifier.Trainer

  @shortdoc "Train Spectre classifier artifacts"

  @default_dataset_path "training/dataset.json"
  @default_out_dir "artifacts/spectre"

  @switches [
    model: :string,
    accept_threshold: :float,
    margin_threshold: :float,
    high_confidence_threshold: :float
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")

    {cli_opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    dataset_path = Enum.at(args, 0, @default_dataset_path)
    out_dir = Enum.at(args, 1, configured_out_dir())
    opts = trainer_opts(cli_opts)

    case Trainer.train(dataset_path, out_dir, opts) do
      {:ok, stats} ->
        Mix.shell().info("Spectre classifier trained")
        Mix.shell().info(Spectre.JSON.encode!(stats, pretty: true))
        :ok

      {:error, {:missing_dependency, :ex_fastembed}} ->
        Mix.raise("Spectre classifier training needs the optional :ex_fastembed dependency")

      {:error, reason} ->
        Mix.raise("Spectre classifier training failed: #{inspect(reason)}")
    end
  end

  @spec configured_out_dir() :: String.t()
  defp configured_out_dir do
    :spectre
    |> Application.get_env(:classifier, [])
    |> Keyword.get(:artifact_dir, @default_out_dir)
  end

  @spec trainer_opts(keyword()) :: keyword()
  defp trainer_opts(cli_opts) do
    :spectre
    |> Application.get_env(:classifier, [])
    |> Keyword.merge(normalize_cli_opts(cli_opts))
    |> Keyword.put_new(:encoder_model, Encoder.default_model())
  end

  @spec normalize_cli_opts(keyword()) :: keyword()
  defp normalize_cli_opts(cli_opts) do
    cli_opts
    |> maybe_put(:model, :encoder_model)
    |> maybe_put(:accept_threshold, :local_accept_threshold)
    |> maybe_put(:margin_threshold, :local_margin_threshold)
    |> maybe_put(:high_confidence_threshold, :local_high_confidence_threshold)
  end

  @spec maybe_put(keyword(), atom(), atom()) :: keyword()
  defp maybe_put(opts, from, to) do
    case Keyword.fetch(opts, from) do
      {:ok, value} -> opts |> Keyword.delete(from) |> Keyword.put(to, value)
      :error -> opts
    end
  end
end
