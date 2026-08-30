defmodule Mix.Tasks.Spectre.Classifier.DownloadModel do
  @moduledoc """
  Downloads/loads the embedding model used by Spectre classifier artifacts.

  ## Usage

      mix spectre.classifier.download_model --model intfloat/multilingual-e5-small

  ## Options

    * `--model` - embedding model id. Defaults to Spectre's classifier model.
  """

  use Mix.Task

  alias Spectre.Classifier.Encoder

  @shortdoc "Download/load the Spectre classifier embedding model"

  @switches [model: :string]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    invalid == [] || Mix.raise("invalid options: #{inspect(invalid)}")

    model = opts[:model] || configured_model()

    case Encoder.download(model, configured_opts()) do
      {:ok, dimensions} ->
        Mix.shell().info("Spectre classifier model ready")

        Mix.shell().info(
          Spectre.JSON.encode!(%{model: model, dimensions: dimensions}, pretty: true)
        )

        :ok

      {:error, {:missing_dependency, :ex_fastembed}} ->
        Mix.raise("Spectre classifier download needs the optional :ex_fastembed dependency")

      {:error, reason} ->
        Mix.raise("Spectre classifier model download failed: #{inspect(reason)}")
    end
  end

  @spec configured_model() :: String.t()
  defp configured_model do
    configured_opts()
    |> Keyword.get(:encoder_model, Encoder.default_model())
  end

  @spec configured_opts() :: keyword()
  defp configured_opts do
    Application.get_env(:spectre, :classifier, [])
  end
end
