defmodule Spectre.Classifier do
  @moduledoc """
  Runtime for Spectre's lightweight local vector classifier.

  The classifier loads artifacts produced by `Spectre.Classifier.Trainer` and
  exposes a route-like result for router plugs. It can run as a GenServer for
  warm artifacts or load artifacts on demand with `classify_once/2`.

      {:ok, _pid} = Spectre.Classifier.start_link(artifact_dir: "artifacts/spectre")
      {:ok, route} = Spectre.Classifier.classify("create a project")
  """

  use GenServer

  require Logger

  alias Spectre.Classifier.Encoder
  alias Spectre.Classifier.Math
  alias Spectre.Route
  alias Vettore.Embedding

  @default_name __MODULE__
  @default_high_confidence_threshold 0.93
  @default_artifact_max_bytes 64_000_000
  @centroid_collection "spectre_classifier_centroids"
  @example_collection "spectre_classifier_examples"

  # Artifacts decode with binary_to_term/2 in :safe mode, which refuses to
  # create new atoms. Listing the artifact schema atoms here interns them when
  # this module loads, so a fresh release VM can decode a trusted artifact
  # without the host pre-loading internal Spectre atoms itself.
  @artifact_schema_atoms [
    :accept_threshold,
    :centroids,
    :dimensions,
    :encoder_model,
    :example_counts,
    :example_index,
    :examples,
    :high_confidence_threshold,
    :id,
    :kind,
    :label,
    :labels,
    :margin_threshold,
    :mode,
    :trained_at,
    :vector,
    :version
  ]

  @doc false
  @spec artifact_schema_atoms() :: [atom()]
  def artifact_schema_atoms, do: @artifact_schema_atoms

  @doc """
  Starts a classifier process that keeps the artifact loaded.

      {:ok, pid} = Spectre.Classifier.start_link(artifact_dir: "artifacts/spectre")
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = classifier_opts(opts)

    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @default_name))
  end

  @doc """
  Classifies text using a running classifier process when available.

      {:ok, route} = Spectre.Classifier.classify("show my projects")
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

      {:ok, route} = Spectre.Classifier.classify_once("show my projects", artifact_dir: path)
  """
  @spec classify_once(String.t(), keyword()) :: {:ok, Route.t()} | {:error, term()}
  def classify_once(text, opts) do
    opts = classifier_opts(opts)

    do_classify(text, load_state(opts), opts)
  end

  @impl GenServer
  def init(opts) do
    opts = classifier_opts(opts)
    state = load_state(opts)

    cond do
      state.ready? ->
        Logger.info(
          "spectre_classifier ready artifact_dir=#{state.artifact_dir} dimensions=#{state.dimensions}"
        )

        {:ok, state}

      Keyword.get(opts, :required?, false) ->
        Logger.error(
          "spectre_classifier startup_failed artifact_dir=#{state.artifact_dir} reason=#{inspect(state.error)}"
        )

        {:stop, state.error}

      true ->
        Logger.warning(
          "spectre_classifier unavailable artifact_dir=#{state.artifact_dir} reason=#{inspect(state.error)}"
        )

        {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:classify, text, opts}, _from, state) do
    {:reply, do_classify(text, state, opts), state}
  end

  @spec load_state(keyword()) :: map()
  defp load_state(opts) do
    artifact_dir = Keyword.get(opts, :artifact_dir, "artifacts/spectre")
    classifier_path = Path.join(artifact_dir, "classifier.etf")

    with {:ok, stat} <- File.stat(classifier_path),
         :ok <- validate_artifact_size(stat.size, opts),
         {:ok, bytes} <- File.read(classifier_path),
         {:ok, classifier} <- decode_classifier(bytes),
         encoder_model <- Map.get(classifier, :encoder_model, Encoder.default_model()),
         {:ok, dimensions} <- Encoder.load(encoder_model, opts),
         :ok <- validate_encoder_dimensions(classifier, dimensions),
         {:ok, classifier_index} <- build_classifier_index(classifier, dimensions, opts) do
      %{
        ready?: true,
        classifier: classifier,
        classifier_index: classifier_index,
        dimensions: dimensions,
        artifact_dir: artifact_dir,
        error: nil
      }
    else
      {:error, reason} ->
        %{ready?: false, classifier: nil, artifact_dir: artifact_dir, error: reason}
    end
  end

  @spec validate_artifact_size(non_neg_integer(), keyword()) :: :ok | {:error, term()}
  defp validate_artifact_size(size, opts) do
    max_bytes = Keyword.get(opts, :classifier_artifact_max_bytes, @default_artifact_max_bytes)

    if is_integer(max_bytes) and max_bytes > 0 and size <= max_bytes do
      :ok
    else
      {:error, {:classifier_artifact_too_large, size, max_bytes}}
    end
  end

  @spec decode_classifier(binary()) :: {:ok, map()} | {:error, term()}
  defp decode_classifier(bytes) do
    bytes
    |> :erlang.binary_to_term([:safe])
    |> validate_classifier()
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
      ranked = rank_labels(query_vector, state, opts)

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
    if Keyword.get(opts, :classification_log?, false) do
      input =
        if Keyword.get(opts, :classification_log_input?, false) do
          " text=#{inspect(String.slice(text, 0, 180))}"
        else
          " input_bytes=#{byte_size(text)}"
        end

      Logger.info(
        "spectre_classifier local_result#{input} " <>
          "label=#{label} accepted=#{accepted?} confidence=#{fmt(confidence)} margin=#{fmt(margin)}"
      )
    end
  end

  @spec validate_classifier(term()) :: {:ok, map()} | {:error, term()}
  defp validate_classifier(classifier) when is_map(classifier) do
    kind = Map.get(classifier, :kind)
    version = Map.get(classifier, :version)
    dimensions = Map.get(classifier, :dimensions)
    labels = Map.get(classifier, :labels)

    with true <- kind in [:centroid_head, :example_index],
         true <- version == 1,
         true <- is_integer(dimensions) and dimensions > 0,
         :ok <- validate_labels(labels),
         :ok <- validate_thresholds(classifier),
         :ok <- validate_classifier_vectors(classifier, kind, dimensions, labels) do
      {:ok, classifier}
    else
      false -> {:error, {:invalid_classifier_schema, kind, version, dimensions}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_classifier(other),
    do: {:error, {:invalid_classifier_artifact_type, artifact_shape(other)}}

  @spec validate_labels(term()) :: :ok | {:error, term()}
  defp validate_labels(labels) when is_list(labels) and labels != [] do
    if Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "")) and
         length(labels) == length(Enum.uniq(labels)) do
      :ok
    else
      {:error, :invalid_classifier_labels}
    end
  end

  defp validate_labels(_labels), do: {:error, :invalid_classifier_labels}

  @spec validate_thresholds(map()) :: :ok | {:error, term()}
  defp validate_thresholds(classifier) do
    keys = [:accept_threshold, :margin_threshold, :high_confidence_threshold]

    case Enum.find(keys, fn key ->
           value = Map.get(classifier, key)
           not is_number(value) or value < 0 or value > 1
         end) do
      nil -> :ok
      key -> {:error, {:invalid_classifier_threshold, key, Map.get(classifier, key)}}
    end
  end

  @spec validate_classifier_vectors(map(), atom(), pos_integer(), [String.t()]) ::
          :ok | {:error, term()}
  defp validate_classifier_vectors(classifier, :centroid_head, dimensions, labels) do
    centroids = Map.get(classifier, :centroids)

    cond do
      not is_map(centroids) ->
        {:error, :invalid_classifier_centroids}

      MapSet.new(Map.keys(centroids), &label_id/1) != MapSet.new(labels) ->
        {:error, :classifier_label_mismatch}

      invalid =
          Enum.find(centroids, fn {_label, vector} -> not valid_vector?(vector, dimensions) end) ->
        {:error, {:invalid_classifier_vector, invalid |> elem(0) |> label_id()}}

      true ->
        :ok
    end
  end

  defp validate_classifier_vectors(classifier, :example_index, dimensions, labels) do
    examples = Map.get(classifier, :examples)

    cond do
      not is_list(examples) or examples == [] ->
        {:error, :invalid_classifier_examples}

      invalid =
          Enum.find(examples, fn example ->
            not is_map(example) or label_id(Map.get(example, :label)) not in labels or
              not is_binary(Map.get(example, :id)) or
                not valid_vector?(Map.get(example, :vector), dimensions)
          end) ->
        {:error, {:invalid_classifier_example, artifact_shape(invalid)}}

      true ->
        :ok
    end
  end

  @spec validate_encoder_dimensions(map(), pos_integer()) :: :ok | {:error, term()}
  defp validate_encoder_dimensions(%{dimensions: expected}, actual) when expected == actual,
    do: :ok

  defp validate_encoder_dimensions(%{dimensions: expected}, actual),
    do: {:error, {:classifier_dimension_mismatch, expected, actual}}

  @spec valid_vector?(term(), pos_integer()) :: boolean()
  defp valid_vector?(vector, dimensions) when is_list(vector) and length(vector) == dimensions,
    do: Enum.all?(vector, &finite_number?/1)

  defp valid_vector?(_vector, _dimensions), do: false

  defp finite_number?(number) when is_integer(number), do: true

  defp finite_number?(number) when is_float(number) do
    _encoded = :erlang.float_to_binary(number, [:compact])
    true
  rescue
    ArithmeticError -> false
  end

  defp finite_number?(_number), do: false

  @spec artifact_shape(term()) :: term()
  defp artifact_shape(value) when is_atom(value), do: :atom
  defp artifact_shape(value) when is_binary(value), do: :binary
  defp artifact_shape(value) when is_list(value), do: :list
  defp artifact_shape(value) when is_map(value), do: :map
  defp artifact_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp artifact_shape(_value), do: :other

  @spec fmt(number()) :: String.t()
  defp fmt(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 4)
  defp fmt(number) when is_integer(number), do: Integer.to_string(number)

  @spec build_classifier_index(map(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp build_classifier_index(%{examples: examples} = classifier, dimensions, opts)
       when is_list(examples) and examples != [] do
    build_example_index(classifier, dimensions, opts)
  end

  defp build_classifier_index(classifier, dimensions, opts) do
    build_centroid_index(classifier, dimensions, opts)
  end

  @spec build_example_index(map(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp build_example_index(%{examples: examples, labels: labels}, dimensions, opts) do
    collection = "#{@example_collection}:#{System.unique_integer([:positive])}"

    embeddings =
      Enum.map(examples, fn example ->
        label = label_id(Map.fetch!(example, :label))

        %Embedding{
          id: label_id(Map.fetch!(example, :id)),
          value: label,
          vector: Map.fetch!(example, :vector),
          metadata: %{"label" => label}
        }
      end)

    with {:ok, index} <- new_classifier_collection(collection, dimensions, opts),
         :ok <- Vettore.put_many(index, embeddings) do
      {:ok, %{type: :examples, collection: index, labels: Enum.map(labels, &label_id/1)}}
    end
  end

  @spec build_centroid_index(map(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp build_centroid_index(%{centroids: centroids}, dimensions, opts)
       when map_size(centroids) > 0 do
    collection = "#{@centroid_collection}:#{System.unique_integer([:positive])}"

    embeddings =
      Enum.map(centroids, fn {label, centroid} ->
        %Embedding{
          id: label_id(label),
          value: label_id(label),
          vector: centroid,
          metadata: %{"label" => label_id(label)}
        }
      end)

    with {:ok, index} <- new_classifier_collection(collection, dimensions, opts),
         :ok <- Vettore.put_many(index, embeddings) do
      {:ok, %{type: :centroids, collection: index}}
    end
  end

  defp build_centroid_index(_classifier, _dimensions, _opts), do: {:error, :empty_centroids}

  @spec new_classifier_collection(String.t(), pos_integer(), keyword()) ::
          {:ok, Vettore.Collection.t()} | {:error, term()}
  defp new_classifier_collection(collection, dimensions, opts) do
    Vettore.new(
      name: collection,
      dimensions: dimensions,
      metric: :cosine,
      normalize: :l2,
      index: Keyword.get(opts, :local_classifier_index, :flat),
      index_options: Keyword.get(opts, :local_classifier_index_options, []),
      score: :raw
    )
  end

  @spec rank_labels([number()], map(), keyword()) :: [{String.t(), float()}]
  defp rank_labels(
         query_vector,
         %{classifier_index: %{type: :examples, collection: collection, labels: labels}},
         opts
       ) do
    limit = Keyword.get(opts, :local_example_top_k, default_example_top_k(labels))

    case Vettore.search(collection, query_vector, limit: search_limit(limit)) do
      {:ok, results} ->
        results
        |> example_label_scores(Keyword.get(opts, :local_example_score, :max))
        |> ranked_label_scores(labels)

      {:error, _reason} ->
        []
    end
  end

  defp rank_labels(
         query_vector,
         %{classifier_index: %{type: :centroids, collection: collection}},
         opts
       ) do
    limit = Keyword.get(opts, :local_top_k, :all)

    case Vettore.search(collection, query_vector, limit: search_limit(limit)) do
      {:ok, results} ->
        Enum.map(results, fn result -> {result.id, result.score} end)

      {:error, _reason} ->
        []
    end
  end

  defp rank_labels(query_vector, %{classifier: classifier}, _opts) do
    classifier.centroids
    |> Enum.map(fn {label, centroid} -> {label, Math.cosine(query_vector, centroid)} end)
    |> Enum.sort_by(fn {_label, score} -> score end, :desc)
  end

  @spec example_label_scores([Vettore.Result.t()], :max | :mean | term()) :: map()
  defp example_label_scores(results, :mean) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      Map.update(acc, result_label(result), {result.score, 1}, fn {sum, count} ->
        {sum + result.score, count + 1}
      end)
    end)
    |> Map.new(fn {label, {sum, count}} -> {label, sum / count} end)
  end

  defp example_label_scores(results, _max) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.update(acc, result_label(result), result.score, &max(&1, result.score))
    end)
  end

  @spec ranked_label_scores(map(), [String.t()]) :: [{String.t(), float()}]
  defp ranked_label_scores(scores, labels) do
    labels
    |> Enum.map(fn label -> {label, Map.get(scores, label, -1.0)} end)
    |> Enum.sort_by(fn {_label, score} -> score end, :desc)
  end

  @spec result_label(Vettore.Result.t()) :: String.t()
  defp result_label(%{metadata: %{"label" => label}}), do: label_id(label)
  defp result_label(%{value: value}), do: label_id(value)

  @spec default_example_top_k([term()]) :: pos_integer()
  defp default_example_top_k(labels), do: max(length(labels) * 4, 20)

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
