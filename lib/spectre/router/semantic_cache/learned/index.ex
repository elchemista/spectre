defmodule Spectre.Router.SemanticCache.Learned.Index do
  @moduledoc """
  Vettore-backed semantic index and embedding acquisition for the learned
  cache.

  Builds and caches per-content collections from embeddings already stored on
  rows, runs threshold-gated vector search, and resolves embeddings for new
  online rows through the configured adapter. The index cache table name is
  the `Learned` module itself, preserved as an operational contract.
  """

  import Spectre.Router.SemanticCache.Learned.Rows

  alias Spectre.Canonical.Value
  alias Spectre.Classifier.Encoder
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner
  alias Vettore.Embedding

  @index_table Spectre.Router.SemanticCache.Learned

  @default_threshold 0.88
  @default_top_k 3
  @default_index_capacity 4

  @doc "Searches the cached collection for rows semantically close to the text."
  @spec search(String.t(), [Learned.row()], keyword()) ::
          {:ok, map(), map()} | {:error, term(), map()}
  def search(text, rows, opts) do
    with :ok <- validate_embedding_profiles(rows, opts),
         {:ok, %{collection: collection}} <- index(rows, opts),
         {:ok, query} <- embed(text, opts) do
      search_collection(collection, query, opts)
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  @doc "Warms the index for rows that already store embeddings."
  @spec warm([Learned.row()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def warm(rows, opts) do
    with :ok <- validate_embedding_profiles(rows, opts) do
      do_warm(rows, opts)
    end
  end

  defp do_warm(rows, opts) do
    case length(stored_vectors(rows)) do
      0 ->
        {:ok, 0}

      count ->
        case index(rows, opts) do
          {:ok, _index} -> {:ok, count}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  @spec bind_embedding_profile(map(), [float()] | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def bind_embedding_profile(metadata, nil, _opts) when is_map(metadata), do: {:ok, metadata}

  def bind_embedding_profile(metadata, embedding, opts)
      when is_map(metadata) and is_list(embedding) and embedding != [] do
    with {:ok, profile} <- embedding_profile(opts) do
      expected_ref = profile.ref
      expected_digest = profile.digest

      case {field(metadata, :embedding_profile_ref), field(metadata, :embedding_profile_digest)} do
        {nil, nil} ->
          {:ok,
           metadata
           |> Map.put("embedding_profile_ref", profile.ref)
           |> Map.put("embedding_profile_digest", profile.digest)}

        {^expected_ref, ^expected_digest} ->
          {:ok, metadata}

        _mismatch ->
          {:error, :semantic_cache_embedding_profile_mismatch}
      end
    end
  end

  @doc false
  @spec validate_embedding_profile(map(), [float()] | nil, keyword()) :: :ok | {:error, term()}
  def validate_embedding_profile(_metadata, nil, _opts), do: :ok

  def validate_embedding_profile(metadata, embedding, opts)
      when is_map(metadata) and is_list(embedding) and embedding != [] do
    with {:ok, %{ref: expected_ref, digest: expected_digest}} <- embedding_profile(opts),
         ^expected_ref <- field(metadata, :embedding_profile_ref),
         ^expected_digest <- field(metadata, :embedding_profile_digest) do
      :ok
    else
      nil -> {:error, :semantic_cache_embedding_profile_missing}
      {:error, _reason} = error -> error
      _mismatch -> {:error, :semantic_cache_embedding_profile_mismatch}
    end
  end

  defp validate_embedding_profiles(rows, opts) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case validate_embedding_profile(row.metadata, row.embedding, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {reason, row.id}}}
      end
    end)
  end

  @doc false
  @spec embedding_profile_identity(keyword()) :: {:ok, map()} | {:error, term()}
  def embedding_profile_identity(opts), do: embedding_profile(opts)

  defp embedding_profile(opts) do
    config = Application.get_env(:spectre, :classifier, []) |> Keyword.merge(opts)
    adapter = Keyword.get(opts, :embedding, Keyword.get(config, :embedding_adapter))
    model = Keyword.get(opts, :embedding_model, adapter_model(adapter))
    explicit = Keyword.get(config, :embedding_model_profile_ref)
    profile = Keyword.get(config, :embedding_model_profile, %{})

    cond do
      not is_map(profile) ->
        {:error, :invalid_semantic_cache_embedding_model_profile}

      is_binary(explicit) and explicit != "" ->
        profile_identity(explicit, profile)

      is_nil(explicit) ->
        with {:ok, adapter_ref} <- adapter_ref(adapter) do
          profile_identity(default_profile_ref(adapter_ref, model), profile)
        end

      true ->
        {:error, :invalid_semantic_cache_embedding_model_profile_ref}
    end
  end

  defp profile_identity(nil, _profile), do: {:error, :semantic_cache_embedding_profile_required}

  defp profile_identity(ref, profile) do
    data = %{profile: profile, profile_ref: ref}
    {:ok, %{ref: ref, digest: Value.digest!(data)}}
  end

  defp adapter_ref({module, _opts}) when is_atom(module), do: {:ok, Atom.to_string(module)}

  defp adapter_ref(module) when is_atom(module) and not is_nil(module),
    do: {:ok, Atom.to_string(module)}

  defp adapter_ref(fun) when is_function(fun), do: {:ok, "host:function"}
  defp adapter_ref(nil), do: {:error, :semantic_cache_embedding_profile_required}
  defp adapter_ref(value), do: {:error, {:invalid_embedding_adapter, value}}

  defp adapter_model({_module, opts}) when is_list(opts), do: Keyword.get(opts, :model)
  defp adapter_model(_adapter), do: nil

  defp default_profile_ref("host:function", nil), do: nil

  defp default_profile_ref(adapter_ref, model) do
    "spectre.embedding:" <> adapter_ref <> ":" <> to_string(model || "default")
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "Embeds text through the configured embedding adapter."
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts) do
    case Keyword.fetch(opts, :embedding) do
      {:ok, {module, adapter_opts}} when is_atom(module) and is_list(adapter_opts) ->
        module.embed(text, Keyword.merge(adapter_opts, opts))

      {:ok, module} when is_atom(module) ->
        module.embed(text, opts)

      {:ok, fun} when is_function(fun, 2) ->
        fun.(text, opts)

      {:ok, fun} when is_function(fun, 1) ->
        fun.(text)

      :error ->
        Encoder.embed(text, opts)

      {:ok, other} ->
        {:error, {:invalid_embedding_adapter, other}}
    end
  rescue
    exception ->
      {:error, {:embedding_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:embedding_exit, reason}}
    kind, reason -> {:error, {:embedding_failure, kind, reason}}
  end

  @doc "Resolves the embedding stored with a learn result, reusing or embedding."
  @spec stored_embedding(String.t(), map(), Learned.row() | nil, keyword()) ::
          {:ok, [float()] | nil} | {:error, term()}
  def stored_embedding(text, result, existing, opts) do
    case result_embedding(result) do
      {:present, embedding} -> normalize_embedding(embedding)
      :missing -> existing_or_new_embedding(text, existing, opts)
    end
  end

  @doc "Drops the cached collections of one agent, raising if the owner is down."
  @spec clear(module()) :: :ok
  def clear(agent) do
    case Owner.clear_indexes(agent) do
      :ok -> :ok
      {:error, reason} -> raise "semantic cache indexes unavailable: #{inspect(reason)}"
    end
  end

  defp index(rows, opts) do
    key = cache_key(rows, opts)
    table = index_table()

    case :ets.lookup(table, key) do
      [{^key, index}] -> {:ok, index}
      [] -> load_index(table, key, rows, opts)
    end
  end

  defp search_collection(collection, query, opts) do
    metadata = %{query_embedding: query}
    minimum_score = threshold(opts)

    case Vettore.search(collection, query, limit: top_k(opts)) do
      {:ok, [%{score: score} = first | rest] = results} when score >= minimum_score ->
        second_score = rest |> List.first(%{score: 0.0}) |> Map.get(:score)

        {:ok,
         %{
           label: result_label(first),
           accepted?: true,
           confidence: score,
           margin: score - second_score,
           matched: result_text(first),
           scores: label_scores(results),
           strategy: :semantic_cache_search,
           semantic_examples: result_rows(results)
         }, metadata}

      {:ok, [_first | _rest]} ->
        {:error, :below_threshold, metadata}

      {:ok, []} ->
        {:error, :miss, metadata}

      {:error, reason} ->
        {:error, reason, metadata}
    end
  end

  defp load_index(table, key, rows, opts) do
    with [_ | _] = vectors <- stored_vectors(rows),
         [%{vector: first_vector} | _] <- vectors,
         :ok <- validate_stored_dimensions(vectors, length(first_vector)),
         {:ok, collection} <- new_collection(length(first_vector), opts) do
      cache_collection(table, key, collection, vectors, opts)
    else
      [] -> {:error, :semantic_cache_embeddings_not_loaded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cache_collection(table, key, collection, vectors, opts) do
    case Vettore.put_many(collection, embeddings(vectors)) do
      :ok ->
        index = %{
          collection: collection,
          inserted_at: System.unique_integer([:monotonic, :positive])
        }

        Owner.cache_index(
          table,
          key,
          index,
          semantic_cache_capacity(opts)
        )

      {:error, reason} ->
        discard_collection(collection)
        {:error, reason}
    end
  rescue
    exception ->
      discard_collection(collection)

      {:error,
       {:semantic_cache_index_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      discard_collection(collection)
      {:error, {:semantic_cache_index_failure, kind, reason}}
  end

  defp discard_collection(collection) do
    Owner.drop_collection(collection)
    :ok
  end

  defp new_collection(dimensions, opts) do
    Owner.new_collection(
      name: "spectre_learned_semantic_cache:#{System.unique_integer([:positive])}",
      dimensions: dimensions,
      metric: :cosine,
      normalize: :l2,
      index: Keyword.get(opts, :semantic_cache_index, :flat),
      index_options: Keyword.get(opts, :semantic_cache_index_options, []),
      score: :raw,
      compressed: Keyword.get(opts, :semantic_cache_compressed?, true)
    )
  end

  defp stored_vectors(rows) do
    Enum.flat_map(rows, fn
      %{embedding: embedding} = row when is_list(embedding) and embedding != [] ->
        [Map.put(row, :vector, embedding)]

      _row ->
        []
    end)
  end

  defp validate_stored_dimensions(rows, dimensions) do
    case Enum.find(rows, &(length(&1.vector) != dimensions)) do
      nil ->
        :ok

      %{id: id, vector: vector} ->
        {:error, {:semantic_cache_dimension_mismatch, id, length(vector), dimensions}}
    end
  end

  defp embeddings(rows) do
    rows
    |> Enum.map(fn %{id: id, label: label, text: text, vector: vector} = row ->
      %Embedding{
        id: id,
        value: text,
        vector: vector,
        metadata: %{"label" => label, "text" => text, "row" => Map.delete(row, :vector)}
      }
    end)
  end

  defp result_embedding(result) do
    cond do
      Map.has_key?(result, :embedding) -> {:present, Map.get(result, :embedding)}
      Map.has_key?(result, "embedding") -> {:present, Map.get(result, "embedding")}
      Map.has_key?(result, :vector) -> {:present, Map.get(result, :vector)}
      Map.has_key?(result, "vector") -> {:present, Map.get(result, "vector")}
      true -> :missing
    end
  end

  defp existing_or_new_embedding(_text, %{embedding: embedding, metadata: metadata}, opts)
       when is_list(embedding) and embedding != [] do
    with :ok <- validate_embedding_profile(metadata, embedding, opts), do: {:ok, embedding}
  end

  defp existing_or_new_embedding(text, _existing, opts) do
    if embedding_configured?(opts) do
      case embed(text, opts) do
        {:ok, embedding} -> normalize_embedding(embedding)
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp embedding_configured?(opts) do
    classifier_opts =
      :spectre
      |> Application.get_env(:classifier, [])
      |> Keyword.merge(opts)

    Keyword.has_key?(opts, :embedding) or
      Keyword.has_key?(classifier_opts, :embedding_adapter) or
      Keyword.has_key?(classifier_opts, :embed)
  end

  defp result_label(%{metadata: %{"label" => label}}), do: label
  defp result_label(%{value: value}), do: value

  defp result_text(%{metadata: %{"text" => text}}), do: text
  defp result_text(%{value: value}) when is_binary(value), do: value
  defp result_text(_result), do: nil

  defp result_rows(results) do
    Enum.flat_map(results, fn
      %{metadata: %{"row" => row}} when is_map(row) -> [row]
      _other -> []
    end)
  end

  defp label_scores(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.update(acc, result_label(result), result.score, &max(&1, result.score))
    end)
  end

  defp cache_key(rows, opts) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    {{:agent, agent},
     :erlang.phash2({
       index_rows_revision(rows),
       Keyword.get(opts, :semantic_cache_index, :flat),
       Keyword.get(opts, :semantic_cache_index_options, []),
       Keyword.get(opts, :semantic_cache_compressed?, true)
     })}
  end

  defp index_rows_revision(rows) do
    rows
    |> Enum.map(&{&1.id, &1.label, &1.normalized_text, &1.embedding})
    |> Enum.sort()
  end

  defp semantic_cache_capacity(opts) do
    case Keyword.get(opts, :semantic_cache_capacity, configured_index_capacity()) do
      :unlimited -> :unlimited
      capacity when is_integer(capacity) and capacity > 0 -> capacity
      _other -> @default_index_capacity
    end
  end

  defp configured_index_capacity do
    case Application.get_env(:spectre, :semantic_cache, []) do
      config when is_list(config) ->
        Keyword.get(config, :index_capacity, @default_index_capacity)

      _other ->
        @default_index_capacity
    end
  end

  defp index_table do
    ensure_table(@index_table, [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true
    ])
  end

  defp ensure_table(name, options) do
    case Owner.ensure_table(name, options) do
      {:ok, ^name} -> name
      {:error, reason} -> raise "semantic cache table unavailable: #{inspect(reason)}"
    end
  end

  defp top_k(opts) do
    case Keyword.get(opts, :semantic_cache_top_k, @default_top_k) do
      top_k when is_integer(top_k) and top_k > 0 -> top_k
      _other -> @default_top_k
    end
  end

  defp threshold(opts) do
    Keyword.get(
      opts,
      :semantic_cache_threshold,
      Keyword.get(opts, :semantic_cache_search_threshold, @default_threshold)
    )
  end
end
