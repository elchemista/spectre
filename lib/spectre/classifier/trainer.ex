defmodule Spectre.Classifier.Trainer do
  @moduledoc """
  Builds a lightweight centroid classifier artifact for Spectre routing.
  """

  alias Spectre.Classifier.{Encoder, Math}

  @default_high_confidence_threshold 0.93

  @doc """
  Trains classifier artifacts from a JSON dataset.

  Dataset rows accept either `"label"` or `"intent"` for compatibility with the
  original AgentCore datasets.
  """
  @spec train(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def train(dataset_path, out_dir, opts \\ []) do
    model = Keyword.get(opts, :encoder_model, Encoder.default_model())
    accept_threshold = Keyword.get(opts, :local_accept_threshold, 0.8)
    margin_threshold = Keyword.get(opts, :local_margin_threshold, 0.08)

    high_confidence_threshold =
      Keyword.get(opts, :local_high_confidence_threshold, @default_high_confidence_threshold)

    with {:ok, examples} <- read_dataset(dataset_path),
         {:ok, dimensions} <- Encoder.load(model, opts),
         {:ok, rows} <- embed_examples(examples, opts),
         {:ok, classifier} <-
           build_classifier(rows, %{
             encoder_model: model,
             dimensions: dimensions,
             accept_threshold: accept_threshold,
             margin_threshold: margin_threshold,
             high_confidence_threshold: high_confidence_threshold
           }),
         :ok <- write_artifacts(classifier, out_dir, dataset_path) do
      {:ok,
       %{
         out_dir: out_dir,
         labels: classifier.labels,
         examples: length(examples),
         encoder_model: model,
         dimensions: dimensions
       }}
    end
  end

  @spec read_dataset(String.t()) :: {:ok, [map()]} | {:error, term()}
  defp read_dataset(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, examples} <- Jason.decode(bytes),
         true <- is_list(examples) do
      {:ok, Enum.filter(examples, &valid_example?/1)}
    else
      false -> {:error, :invalid_dataset}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec valid_example?(map()) :: boolean()
  defp valid_example?(%{"text" => text} = example) when is_binary(text) do
    label(example) != nil
  end

  defp valid_example?(_example), do: false

  @spec embed_examples([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  defp embed_examples(examples, opts) do
    examples
    |> Enum.reduce_while([], fn example, acc ->
      case Encoder.embed(example["text"], opts) do
        {:ok, vector} -> {:cont, [%{example: example, vector: vector} | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      rows -> {:ok, Enum.reverse(rows)}
    end
  end

  @spec build_classifier([map()], map()) :: {:ok, map()} | {:error, term()}
  defp build_classifier([], _metadata), do: {:error, :empty_dataset}

  defp build_classifier(rows, metadata) do
    grouped = Enum.group_by(rows, &label(&1.example), & &1.vector)

    centroids =
      grouped
      |> Enum.map(fn {label, vectors} -> {label, Math.centroid(vectors)} end)
      |> Map.new()

    labels = grouped |> Map.keys() |> Enum.sort()

    {:ok,
     Map.merge(metadata, %{
       version: 1,
       kind: :centroid_head,
       labels: labels,
       centroids: centroids,
       example_counts: Map.new(grouped, fn {label, vectors} -> {label, length(vectors)} end),
       trained_at: DateTime.utc_now(:second) |> DateTime.to_iso8601()
     })}
  end

  @spec write_artifacts(map(), String.t(), String.t()) :: :ok | {:error, term()}
  defp write_artifacts(classifier, out_dir, dataset_path) do
    metadata =
      classifier
      |> Map.drop([:centroids])
      |> Map.put(:dataset_path, dataset_path)

    calibration = %{
      accept_threshold: classifier.accept_threshold,
      margin_threshold: classifier.margin_threshold,
      high_confidence_threshold: classifier.high_confidence_threshold
    }

    with :ok <- File.mkdir_p(out_dir),
         :ok <-
           File.write(Path.join(out_dir, "classifier.etf"), :erlang.term_to_binary(classifier)),
         :ok <-
           File.write(Path.join(out_dir, "metadata.json"), Jason.encode!(metadata, pretty: true)),
         :ok <-
           File.write(
             Path.join(out_dir, "calibration.json"),
             Jason.encode!(calibration, pretty: true)
           ) do
      File.write(
        Path.join(out_dir, "labels.json"),
        Jason.encode!(classifier.labels, pretty: true)
      )
    end
  end

  @spec label(map()) :: String.t() | nil
  defp label(%{"label" => label}) when is_binary(label) and label != "", do: label
  defp label(%{"intent" => intent}) when is_binary(intent) and intent != "", do: intent
  defp label(_example), do: nil
end
