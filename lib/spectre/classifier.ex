defmodule Spectre.Classifier do
  @moduledoc """
  Runtime for Spectre's lightweight local centroid classifier.
  """

  use GenServer

  require Logger

  alias Spectre.Classifier.{Encoder, Math}
  alias Spectre.Route
  alias Vettore.Embedding

  @default_name __MODULE__
  @default_high_confidence_threshold 0.93
  @centroid_collection "spectre_classifier_centroids"

  @doc """
  Starts a classifier process that keeps the artifact loaded.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = classifier_opts(opts)

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @doc """
  Classifies text using a running classifier process when available.
  """
  @spec classify(String.t(), keyword()) :: {:ok, Route.t()} | {:error, term()}
  def classify(text, opts \\ []) when is_binary(text) do
    opts = classifier_opts(opts)
    name = Keyword.get(opts, :name, @default_name)

    if Process.whereis(name) do
      GenServer.call(name, {:classify, text, opts}, Keyword.get(opts, :timeout, 30_000))
    else
      classify_once(text, opts)
    end
  end

  @doc """
  Classifies text by loading artifacts for this call.
  """
  @spec classify_once(String.t(), keyword()) :: {:ok, Route.t()} | {:error, term()}
  def classify_once(text, opts) do
    opts = classifier_opts(opts)

    do_classify(text, load_state(opts), opts)
  end

  @impl true
  def init(opts), do: {:ok, opts |> classifier_opts() |> load_state()}

  @impl true
  def handle_call({:classify, text, opts}, _from, state) do
    {:reply, do_classify(text, state, opts), state}
  end

  @spec load_state(keyword()) :: map()
  defp load_state(opts) do
    artifact_dir = Keyword.get(opts, :artifact_dir, "artifacts/spectre")
    classifier_path = Path.join(artifact_dir, "classifier.etf")

    with {:ok, bytes} <- File.read(classifier_path),
         {:ok, classifier} <- decode_classifier(bytes),
         encoder_model <- Map.get(classifier, :encoder_model, Encoder.default_model()),
         {:ok, dimensions} <- Encoder.load(encoder_model, opts),
         {:ok, centroid_index} <- build_centroid_index(classifier, dimensions) do
      %{
        ready?: true,
        classifier: classifier,
        centroid_index: centroid_index,
        dimensions: dimensions,
        artifact_dir: artifact_dir,
        error: nil
      }
    else
      {:error, reason} ->
        %{ready?: false, classifier: nil, artifact_dir: artifact_dir, error: reason}
    end
  end

  @spec decode_classifier(binary()) :: {:ok, map()} | {:error, term()}
  defp decode_classifier(bytes) do
    {:ok, :erlang.binary_to_term(bytes)}
  rescue
    exception ->
      {:error, {:invalid_classifier_artifact, exception.__struct__, Exception.message(exception)}}
  end

  @spec do_classify(String.t(), map(), keyword()) :: {:ok, Route.t()} | {:error, term()}
  defp do_classify(_text, %{ready?: false, error: reason}, _opts), do: {:error, reason}

  defp do_classify(text, %{classifier: classifier} = state, opts) do
    accept_threshold =
      Keyword.get(opts, :local_accept_threshold, Map.get(classifier, :accept_threshold, 0.8))

    margin_threshold =
      Keyword.get(opts, :local_margin_threshold, Map.get(classifier, :margin_threshold, 0.08))

    high_confidence_threshold =
      Keyword.get(
        opts,
        :local_high_confidence_threshold,
        Map.get(classifier, :high_confidence_threshold, @default_high_confidence_threshold)
      )

    with {:ok, query_vector} <- Encoder.embed(text, opts) do
      ranked = rank_centroids(query_vector, state, opts)

      {label, confidence} = List.first(ranked, {"UNKNOWN", 0.0})
      {_second_label, second_score} = Enum.at(ranked, 1, {"UNKNOWN", 0.0})
      margin = confidence - second_score

      accepted? =
        (confidence >= accept_threshold and margin >= margin_threshold) or
          confidence >= high_confidence_threshold

      log_result(text, label, accepted?, confidence, margin, opts)

      {:ok,
       Route.new(%{
         label: label,
         confidence: confidence,
         margin: margin,
         scores: Map.new(ranked),
         accepted?: accepted?,
         strategy: :local_classifier
       })}
    end
  end

  @spec log_result(String.t(), String.t(), boolean(), number(), number(), keyword()) :: :ok
  defp log_result(text, label, accepted?, confidence, margin, opts) do
    if Keyword.get(opts, :classification_log?, true) do
      Logger.info(
        "spectre_classifier local_result text=#{inspect(String.slice(text, 0, 180))} " <>
          "label=#{label} accepted=#{accepted?} confidence=#{fmt(confidence)} margin=#{fmt(margin)}"
      )
    end
  end

  @spec fmt(number()) :: String.t()
  defp fmt(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 4)
  defp fmt(number) when is_integer(number), do: Integer.to_string(number)

  @spec build_centroid_index(map(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  defp build_centroid_index(%{centroids: centroids}, dimensions) when map_size(centroids) > 0 do
    db = Vettore.new()
    collection = "#{@centroid_collection}:#{System.unique_integer([:positive])}"

    embeddings =
      Enum.map(centroids, fn {label, centroid} ->
        %Embedding{
          value: label_id(label),
          vector: centroid,
          metadata: %{"label" => label_id(label)}
        }
      end)

    with {:ok, _collection} <- Vettore.create_collection(db, collection, dimensions, :cosine),
         {:ok, _ids} <- Vettore.batch(db, collection, embeddings) do
      {:ok, %{db: db, collection: collection}}
    end
  end

  defp build_centroid_index(_classifier, _dimensions), do: {:error, :empty_centroids}

  @spec rank_centroids([number()], map(), keyword()) :: [{String.t(), float()}]
  defp rank_centroids(query_vector, %{centroid_index: %{db: db, collection: collection}}, opts) do
    limit = Keyword.get(opts, :local_top_k, :all)

    case Vettore.similarity_search(db, collection, query_vector, limit: search_limit(limit)) do
      {:ok, results} ->
        Enum.map(results, fn {label, score} -> {label, Math.raw_cosine_score(score)} end)

      {:error, _reason} ->
        []
    end
  end

  defp rank_centroids(query_vector, %{classifier: classifier}, _opts) do
    classifier.centroids
    |> Enum.map(fn {label, centroid} -> {label, Math.cosine(query_vector, centroid)} end)
    |> Enum.sort_by(fn {_label, score} -> score end, :desc)
  end

  @spec search_limit(:all | pos_integer() | term()) :: pos_integer()
  defp search_limit(:all), do: 1_000_000
  defp search_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp search_limit(_limit), do: 1_000_000

  @spec label_id(term()) :: String.t()
  defp label_id(label) when is_binary(label), do: label
  defp label_id(label), do: to_string(label)

  @spec classifier_opts(keyword()) :: keyword()
  defp classifier_opts(opts) do
    :spectre
    |> Application.get_env(:classifier, [])
    |> Keyword.merge(opts)
  end
end
