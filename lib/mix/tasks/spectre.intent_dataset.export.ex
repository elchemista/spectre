defmodule Mix.Tasks.Spectre.IntentDataset.Export do
  @moduledoc """
  Exports labeled intent examples to a portable JSONL snapshot.

      mix spectre.intent_dataset.export MyApp.SupportAgent priv/intents.jsonl

  Includes verified examples by default. Pass `--include-unverified` to export
  collected examples awaiting verification. `--source all` also includes static
  sources; the default is the mutable online dataset. Stored vectors and their
  metadata are preserved; export never calls the encoder or trains a classifier.
  """
  use Mix.Task

  @shortdoc "Export intent dataset examples without recomputing embeddings"

  @impl true
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [include_unverified: :boolean, source: :string])

    if invalid != [] or length(args) != 2,
      do:
        Mix.raise(
          "expected: mix spectre.intent_dataset.export MyApp.Agent path.jsonl [--include-unverified] [--source online|all]"
        )

    Mix.Task.run("app.start")
    [name, path] = args
    agent = name |> String.split(".") |> Module.concat()

    source =
      case Keyword.get(opts, :source, "online") do
        "online" -> :online_learned
        "all" -> :all
        other -> Mix.raise("invalid dataset source #{inspect(other)}; expected online or all")
      end

    case Spectre.IntentDataset.examples(agent, source: source) do
      {:ok, rows} ->
        rows = if opts[:include_unverified], do: rows, else: Enum.filter(rows, & &1.verified?)
        write(rows, path)

      {:error, reason} ->
        Mix.raise("intent dataset export failed: #{inspect(reason)}")
    end
  end

  defp write(rows, path) do
    case Spectre.Router.SemanticCache.Learned.Snapshot.write(rows, path) do
      {:ok, ^path} ->
        Mix.shell().info("Exported #{length(rows)} intent examples to #{path}")
        :ok

      {:error, reason} ->
        Mix.raise("intent dataset export failed: #{inspect(reason)}")
    end
  end
end
