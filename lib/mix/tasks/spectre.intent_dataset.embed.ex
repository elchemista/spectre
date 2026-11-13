defmodule Mix.Tasks.Spectre.IntentDataset.Embed do
  @moduledoc """
  Prepares semantic vectors for intent examples without training a classifier.

      mix spectre.intent_dataset.embed MyApp.SupportAgent source.jsonl vectors.jsonl

  Uses the encoder already bound by the Agent or Stack. Compatible stored
  vectors are reused; text-only rows are encoded. Every label must be declared
  and eligible for dataset lookup. Validation or encoder failure leaves source
  and any previous target unchanged. Existing vectors require profile metadata;
  unknown vectors are rejected instead of silently adopting the current profile.
  """
  use Mix.Task

  @shortdoc "Prepare intent dataset embeddings without classifier training"

  @impl true
  def run(argv) do
    case argv do
      [name, source, output] ->
        Mix.Task.run("app.start")
        agent = name |> String.split(".") |> Module.concat()

        case Spectre.IntentDataset.Embedding.prepare(agent, source, output) do
          {:ok, stats} ->
            Mix.shell().info(
              "Prepared #{stats.examples} intent examples: #{stats.embedded} embedded, #{stats.reused} reused → #{stats.path}"
            )

            :ok

          {:error, reason} ->
            Mix.raise("intent dataset embedding failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise(
          "expected: mix spectre.intent_dataset.embed MyApp.Agent source.jsonl output.jsonl"
        )
    end
  end
end
