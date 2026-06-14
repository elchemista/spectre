defmodule Spectre.Router.SemanticCache.Learned do
  @moduledoc """
  Built-in semantic cache backed by learned route examples.

  Rules opt in with `learn: true` and `train: true`. Examples are loaded from
  the configured dataset sources and become exact lookup rows and, for semantic
  search, Vettore embeddings. Hosts can still override this cache with
  `semantic_lookup:` or `semantic_cache:`.
  """

  alias Spectre.Classifier.Encoder
  alias Spectre.Rule
  alias Vettore.Embedding

  @table __MODULE__
  @default_threshold 0.88
  @default_top_k 3

  @type row :: %{text: String.t(), label: atom()}

  @doc """
  Looks up text in the learned semantic cache.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def lookup(text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, rows} <- rows(opts),
         [_ | _] <- rows do
      if Keyword.get(opts, :semantic_search?, false) do
        search(text, rows, opts)
      else
        exact(text, rows)
      end
    else
      [] -> {:error, :empty_learned_semantic_cache}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears cached Vettore indexes for an agent.
  """
  @spec clear(module(), keyword()) :: :ok
  def clear(agent, _opts \\ []) when is_atom(agent) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.each(fn
          {{{:agent, ^agent}, _hash} = key, index} ->
            drop_index(index)
            :ets.delete(@table, key)

          _other ->
            :ok
        end)

        :ok
    end
  end

  @spec exact(String.t(), [row()]) :: {:ok, map()} | {:error, :miss}
  defp exact(text, rows) do
    key = normalize_text(text)

    rows
    |> Enum.find(&(normalize_text(&1.text) == key))
    |> case do
      %{label: label, text: matched} ->
        {:ok,
         %{
           label: label,
           accepted?: true,
           confidence: 1.0,
           margin: 1.0,
           matched: matched,
           strategy: :semantic_cache_exact
         }}

      nil ->
        {:error, :miss}
    end
  end

  @spec search(String.t(), [row()], keyword()) :: {:ok, map()} | {:error, term()}
  defp search(text, rows, opts) do
    with {:ok, %{collection: collection}} <- index(rows, opts),
         {:ok, query} <- embed(text, opts),
         {:ok, results} <- Vettore.search(collection, query, limit: top_k(opts)),
         [%{score: score} = first | rest] <- results,
         true <- score >= threshold(opts) do
      second_score = rest |> List.first(%{score: 0.0}) |> Map.get(:score)

      {:ok,
       %{
         label: result_label(first),
         accepted?: true,
         confidence: score,
         margin: score - second_score,
         matched: result_text(first),
         scores: label_scores(results),
         strategy: :semantic_cache_search
       }}
    else
      [] -> {:error, :miss}
      false -> {:error, :below_threshold}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec index([row()], keyword()) :: {:ok, map()} | {:error, term()}
  defp index(rows, opts) do
    key = cache_key(rows, opts)
    table = ensure_table()

    case :ets.lookup(table, key) do
      [{^key, index}] -> {:ok, index}
      [] -> build_index(table, key, rows, opts)
    end
  end

  @spec build_index(atom(), term(), [row()], keyword()) :: {:ok, map()} | {:error, term()}
  defp build_index(table, key, rows, opts) do
    with {:ok, vectors} <- embed_rows(rows, opts),
         [%{vector: first_vector} | _] <- vectors,
         {:ok, collection} <- new_collection(length(first_vector), opts),
         :ok <- Vettore.put_many(collection, embeddings(vectors)) do
      index = %{collection: collection}
      :ets.insert(table, {key, index})
      {:ok, index}
    else
      [] -> {:error, :empty_learned_semantic_cache}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec new_collection(pos_integer(), keyword()) ::
          {:ok, Vettore.Collection.t()} | {:error, term()}
  defp new_collection(dimensions, opts) do
    Vettore.new(
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

  @spec embed_rows([row()], keyword()) :: {:ok, [map()]} | {:error, term()}
  defp embed_rows(rows, opts) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case embed(row.text, opts) do
        {:ok, vector} -> {:cont, {:ok, acc ++ [Map.put(row, :vector, vector)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec embeddings([map()]) :: [Embedding.t()]
  defp embeddings(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {%{label: label, text: text, vector: vector}, index} ->
      %Embedding{
        id: "#{label}:#{index}:#{:erlang.phash2(text)}",
        value: text,
        vector: vector,
        metadata: %{"label" => label, "text" => text}
      }
    end)
  end

  @spec rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  defp rows(opts) do
    opts
    |> Keyword.get(:spectre_rules, [])
    |> Enum.filter(&Map.get(&1, :learn, false))
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case rule_rows(rule, opts) do
        {:ok, rule_rows} -> {:cont, {:ok, acc ++ rule_rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, learned_rows} -> {:ok, dedupe(learned_rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rule_rows(Rule.t(), keyword()) :: {:ok, [row()]} | {:error, term()}
  defp rule_rows(%Rule{training_source?: true, label: label}, opts) do
    opts
    |> sources()
    |> collect_entries(label)
  end

  defp rule_rows(%Rule{}, _opts), do: {:ok, []}

  @spec collect_entries([term()], atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_entries(entries, label) do
    entries
    |> Enum.reject(&(&1 in [true, false, nil]))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case collect_entry(entry, label) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec collect_entry(term(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_entry(entry, label) when is_binary(entry) do
    if File.exists?(entry) do
      collect_file(entry, label)
    else
      {:ok, [row(entry, label)]}
    end
  end

  defp collect_entry(entry, _label), do: {:error, {:invalid_learning_entry, entry}}

  @spec collect_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_file(path, label) do
    case Path.extname(path) do
      ".json" -> collect_json_file(path, label)
      ".jsonl" -> collect_jsonl_file(path, label)
      _other -> collect_lines_file(path, label)
    end
  end

  @spec collect_json_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_json_file(path, label) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text),
         true <- is_list(decoded) || {:error, {:invalid_learning_json, path}} do
      {:ok, decoded |> Enum.flat_map(&normalize_source_row(&1, label))}
    end
  end

  @spec collect_jsonl_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_file(path, label) do
    with {:ok, text} <- File.read(path) do
      text
      |> dataset_lines()
      |> collect_jsonl_lines(path, label)
    end
  end

  @spec collect_jsonl_lines([String.t()], String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_lines(lines, path, label) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      collect_jsonl_line(line, acc, path, label)
    end)
  end

  @spec collect_jsonl_line(String.t(), [row()], String.t(), atom()) ::
          {:cont, {:ok, [row()]}} | {:halt, {:error, term()}}
  defp collect_jsonl_line(line, acc, path, label) do
    case Jason.decode(line) do
      {:ok, decoded} -> {:cont, {:ok, acc ++ normalize_source_row(decoded, label)}}
      {:error, reason} -> {:halt, {:error, {:invalid_learning_jsonl_row, path, reason}}}
    end
  end

  @spec collect_lines_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_lines_file(path, label) do
    with {:ok, text} <- File.read(path) do
      {:ok, text |> dataset_lines() |> Enum.map(&row(&1, label))}
    end
  end

  @spec normalize_source_row(term(), atom()) :: [row()]
  defp normalize_source_row(%{"text" => text} = source, label) when is_binary(text) do
    source_label = Map.get(source, "label", Map.get(source, "intent"))

    if blank?(source_label) or same_label?(source_label, label) do
      [row(text, label)]
    else
      []
    end
  end

  defp normalize_source_row(%{text: text} = source, label) when is_binary(text) do
    source_label = Map.get(source, :label, Map.get(source, :intent))

    if blank?(source_label) or same_label?(source_label, label) do
      [row(text, label)]
    else
      []
    end
  end

  defp normalize_source_row(_source, _label), do: []

  @spec dataset_lines(String.t()) :: [String.t()]
  defp dataset_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @spec row(String.t(), atom()) :: row()
  defp row(text, label), do: %{text: String.trim(text), label: label}

  @spec dedupe([row()]) :: [row()]
  defp dedupe(rows) do
    rows
    |> Enum.reject(&(&1.text == ""))
    |> Enum.uniq_by(&{&1.label, normalize_text(&1.text)})
  end

  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  defp embed(text, opts) do
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

  @spec result_label(Vettore.Result.t()) :: atom() | String.t()
  defp result_label(%{metadata: %{"label" => label}}), do: label
  defp result_label(%{value: value}), do: value

  @spec result_text(Vettore.Result.t()) :: String.t() | nil
  defp result_text(%{metadata: %{"text" => text}}), do: text
  defp result_text(%{value: value}) when is_binary(value), do: value
  defp result_text(_result), do: nil

  @spec label_scores([Vettore.Result.t()]) :: map()
  defp label_scores(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.update(acc, result_label(result), result.score, &max(&1, result.score))
    end)
  end

  @spec cache_key([row()], keyword()) :: term()
  defp cache_key(rows, opts) do
    {{:agent, Keyword.get(opts, :spectre_agent, :anonymous)},
     :erlang.phash2({
       rows,
       Keyword.get(opts, :embedding),
       Keyword.get(opts, :embedding_adapter),
       Keyword.get(opts, :encoder_model),
       Keyword.get(opts, :semantic_cache_index, :flat),
       Keyword.get(opts, :semantic_cache_index_options, [])
     })}
  end

  @spec drop_index(map()) :: :ok
  defp drop_index(%{
         collection: %Vettore.Collection{store_state: %Vettore.Store.ETS{table: table}}
       }) do
    drop_ets_table(table)
  end

  defp drop_index(_index), do: :ok

  @spec drop_ets_table(:ets.tid()) :: :ok
  defp drop_ets_table(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec ensure_table() :: atom()
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, :compressed, read_concurrency: true])

      _tid ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  @spec sources(keyword()) :: [String.t()]
  defp sources(opts) do
    opts
    |> Keyword.get_values(:semantic_cache_source)
    |> Kernel.++(Keyword.get_values(opts, :source))
    |> Kernel.++(configured_sources())
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp configured_sources do
    config = Application.get_env(:spectre, :classifier, [])

    []
    |> Kernel.++(List.wrap(Keyword.get(config, :source)))
    |> Kernel.++(List.wrap(Keyword.get(config, :sources)))
    |> Kernel.++(List.wrap(Keyword.get(config, :dataset_path)))
    |> Kernel.++(default_source())
  end

  defp default_source do
    if File.exists?("training/dataset.json"), do: ["training/dataset.json"], else: []
  end

  @spec top_k(keyword()) :: pos_integer()
  defp top_k(opts) do
    case Keyword.get(opts, :semantic_cache_top_k, @default_top_k) do
      top_k when is_integer(top_k) and top_k > 0 -> top_k
      _other -> @default_top_k
    end
  end

  @spec threshold(keyword()) :: number()
  defp threshold(opts) do
    Keyword.get(
      opts,
      :semantic_cache_threshold,
      Keyword.get(opts, :semantic_cache_search_threshold, @default_threshold)
    )
  end

  @spec normalize_text(String.t()) :: String.t()
  defp normalize_text(text), do: text |> String.trim() |> String.downcase()

  @spec same_label?(term(), atom()) :: boolean()
  defp same_label?(source_label, label) do
    source_label
    |> to_string()
    |> String.upcase()
    |> Kernel.==(label |> to_string() |> String.upcase())
  end

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
