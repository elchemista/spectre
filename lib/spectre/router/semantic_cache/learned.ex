defmodule Spectre.Router.SemanticCache.Learned do
  @moduledoc """
  Built-in semantic cache backed by static dataset rows and online examples.

  Static rows come from labeled classifier datasets and route examples. Online
  rows are mutable runtime examples stored in ETS. Exact lookup reads the merged
  row set directly. Semantic search only indexes embeddings already stored with
  those rows; it never embeds the full dataset from a request process.
  """

  alias Spectre.Classifier.Encoder
  alias Spectre.Router.SemanticCache.Owner
  alias Spectre.Rule
  alias Vettore.Embedding

  @index_table __MODULE__
  @online_table Module.concat(__MODULE__, Online)
  @revision_table Module.concat(__MODULE__, Revisions)

  @default_threshold 0.88
  @default_top_k 3
  @default_learn_confidence 0.86
  @default_index_capacity 4

  @type source :: :offline_dataset | :static_route_example | :online_learned
  @type row :: %{
          id: String.t(),
          agent: module(),
          text: String.t(),
          normalized_text: String.t(),
          label: atom(),
          source: source(),
          source_strategy: atom() | nil,
          accepted?: boolean(),
          confidence: float() | nil,
          margin: float() | nil,
          verified?: boolean(),
          editable?: boolean(),
          embedding: [float()] | nil,
          metadata: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Looks up text in the built-in semantic cache.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def lookup(text, opts) when is_binary(text) and is_list(opts) do
    case lookup_with_metadata(text, opts) do
      {:ok, result, _metadata} -> {:ok, result}
      {:error, reason, _metadata} -> {:error, reason}
    end
  end

  @doc false
  @spec lookup_with_metadata(String.t(), keyword()) ::
          {:ok, map(), map()} | {:error, term(), map()}
  def lookup_with_metadata(text, opts) when is_binary(text) and is_list(opts) do
    with {:ok, rows} <- rows(opts),
         [_ | _] <- rows do
      if Keyword.get(opts, :semantic_search?, false) do
        search(text, rows, opts)
      else
        with_empty_metadata(exact(text, rows))
      end
    else
      [] -> {:error, :empty_learned_semantic_cache, %{}}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  @doc """
  Stores or updates an online learned row.
  """
  @spec put(String.t(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  def put(text, result, opts) when is_binary(text) and is_map(result) and is_list(opts) do
    with {:ok, agent} <- fetch_agent(opts),
         {:ok, label} <- routeable_label(result_route_label(result), opts),
         :ok <- cacheable_label(label, opts),
         {:ok, text} <- valid_text(text),
         existing <- find_online_by_normalized(agent, normalize_text(text)),
         {:ok, embedding} <- stored_embedding(text, result, existing, opts) do
      now = DateTime.utc_now()
      normalized = normalize_text(text)
      id = (existing && existing.id) || result_id(result) || online_id()

      row =
        normalize_row(%{
          id: id,
          agent: agent,
          text: text,
          normalized_text: normalized,
          label: label,
          source: :online_learned,
          source_strategy: result_source_strategy(result),
          accepted?: true,
          confidence: result_confidence(result, opts),
          margin: Map.get(result, :margin),
          verified?: Map.get(result, :verified?, false),
          editable?: true,
          embedding: embedding,
          metadata: online_metadata(result, agent, label, now),
          inserted_at: (existing && existing.inserted_at) || now,
          updated_at: now
        })

      online_table()
      |> :ets.insert({{agent, id}, row})

      bump_online_revision(agent)
      _index_status = warm_stored_index(opts)
      {:ok, row}
    end
  end

  def put(text, %Spectre.Route{} = route, opts), do: put(text, Map.from_struct(route), opts)
  def put(_text, result, _opts), do: {:error, {:invalid_semantic_cache_result, result}}

  @doc """
  Returns semantic-cache rows for review.

  By default this returns online learned rows only. Use `source: :all`,
  `source: :offline_dataset`, or `source: :static_route_example` to inspect
  other sources.
  """
  @spec examples(module(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def examples(agent, opts \\ [])

  def examples(agent, opts) when is_atom(agent) and is_list(opts) do
    with {:ok, opts} <- agent_opts(agent, opts) do
      review_opts = Keyword.put(opts, :semantic_cache_include_unverified?, true)

      case Keyword.get(opts, :source, :online_learned) do
        :online_learned -> {:ok, online_rows(agent, review_opts)}
        :offline_dataset -> offline_dataset_rows(opts)
        :static_route_example -> {:ok, static_route_rows(opts)}
        :all -> rows(Keyword.put(review_opts, :semantic_cache_static?, true))
        source -> {:error, {:invalid_semantic_cache_source, source}}
      end
    end
  end

  def examples(agent, _opts), do: {:error, {:invalid_agent, agent}}

  @doc """
  Fetches one review row by identifier.

  The lookup includes online, dataset, and static route examples. Static rows
  are returned with `editable?: false`; only rows whose source is
  `:online_learned` can be changed by `relabel/4`, `verify/3`, or `delete/3`.

      {:ok, rows} = Learned.examples(MyApp.Agent)
      {:ok, row} = Learned.get_example(MyApp.Agent, hd(rows).id)

  Agent router options are loaded first and may be overridden through `opts`.
  Returns `{:error, :not_found}` when no source contains the identifier.
  """
  @spec get_example(module(), String.t(), keyword()) :: {:ok, row()} | {:error, term()}
  def get_example(agent, id, opts \\ [])

  def get_example(agent, id, opts) when is_atom(agent) and is_binary(id) do
    with {:ok, rows} <- examples(agent, Keyword.put(opts, :source, :all)) do
      case Enum.find(rows, &(&1.id == id)) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  def get_example(agent, id, _opts), do: {:error, {:invalid_example_lookup, agent, id}}

  @doc """
  Changes the route label of an online example and marks it verified.

  `new_label` must name a route declared by the agent and that route must allow
  semantic caching. Offline dataset rows and static route examples are
  immutable and return `{:error, :read_only_example}`.

      {:ok, updated} =
        Learned.relabel(MyApp.Agent, example_id, :support_request)

      true = updated.verified?

  A successful mutation increments `online_revision/1` and refreshes the local
  semantic index from the embeddings already stored on the rows.
  """
  @spec relabel(module(), String.t(), atom(), keyword()) :: {:ok, row()} | {:error, term()}
  def relabel(agent, id, new_label, opts \\ [])

  def relabel(agent, id, new_label, opts)
      when is_atom(agent) and is_binary(id) and is_atom(new_label) do
    with {:ok, opts} <- agent_opts(agent, opts),
         {:ok, row} <- mutable_or_read_only_row(agent, id, opts),
         {:ok, label} <- routeable_label(new_label, opts),
         :ok <- cacheable_label(label, opts) do
      updated =
        row
        |> Map.put(:label, label)
        |> Map.put(:verified?, true)
        |> Map.put(:updated_at, DateTime.utc_now())
        |> put_metadata(:verified_at, DateTime.utc_now())

      :ets.insert(online_table(), {{agent, id}, updated})
      bump_online_revision(agent)
      _index_status = warm_stored_index(opts)
      {:ok, updated}
    end
  end

  def relabel(agent, id, label, _opts), do: {:error, {:invalid_relabel, agent, id, label}}

  @doc """
  Deletes an online learned example.

  Static route examples and offline dataset rows are read-only. The function
  therefore returns `{:error, :read_only_example}` for their identifiers and
  `{:error, :not_found}` for an unknown identifier.

      :ok = Learned.delete(MyApp.Agent, example_id)

  Deleting a row also advances `online_revision/1` and refreshes the local
  Vettore projection so it cannot keep serving the removed example.
  """
  @spec delete(module(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(agent, id, opts \\ [])

  def delete(agent, id, opts) when is_atom(agent) and is_binary(id) do
    with {:ok, opts} <- agent_opts(agent, opts) do
      case mutable_online_row(agent, id, opts) do
        {:ok, _row} ->
          :ets.delete(online_table(), {agent, id})
          bump_online_revision(agent)
          _index_status = warm_stored_index(opts)
          :ok

        {:error, :not_found} ->
          read_only_or_not_found(agent, id, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete(agent, id, _opts), do: {:error, {:invalid_delete, agent, id}}

  @doc """
  Marks an online example as reviewed and eligible for normal lookup.

  Learned rows may be stored as unverified and are excluded unless
  `:semantic_cache_include_unverified?` is enabled. Verification sets
  `verified?: true`, records `:verified_at` in metadata, and refreshes the local
  index from the row's stored embedding.

      {:ok, verified} = Learned.verify(MyApp.Agent, example_id)
      true = verified.verified?

  Static and dataset-backed examples are already trusted and read-only.
  """
  @spec verify(module(), String.t(), keyword()) :: {:ok, row()} | {:error, term()}
  def verify(agent, id, opts \\ [])

  def verify(agent, id, opts) when is_atom(agent) and is_binary(id) do
    with {:ok, opts} <- agent_opts(agent, opts),
         {:ok, row} <- mutable_or_read_only_row(agent, id, opts) do
      now = DateTime.utc_now()

      updated =
        row
        |> Map.put(:verified?, true)
        |> Map.put(:updated_at, now)
        |> put_metadata(:verified_at, now)

      :ets.insert(online_table(), {{agent, id}, updated})
      bump_online_revision(agent)
      _index_status = warm_stored_index(opts)
      {:ok, updated}
    end
  end

  def verify(agent, id, _opts), do: {:error, {:invalid_verify, agent, id}}

  @doc """
  Exports review rows and their stored embeddings as portable snapshot maps or
  an atomic JSONL file.

  Without `:path`, the return value contains JSON-compatible maps:

      {:ok, rows} = Learned.snapshot(MyApp.Agent)

  With a path, Spectre writes a temporary file and renames it into place:

      {:ok, "priv/cache/support.jsonl"} =
        Learned.snapshot(MyApp.Agent, path: "priv/cache/support.jsonl")

  Online rows are exported by default. Set `source: :all`,
  `:offline_dataset`, or `:static_route_example` to select another review
  view. Snapshot data can be restored with `load_snapshot/3`. Legacy snapshots
  without embeddings remain readable for exact lookup, but are not eligible for
  vector search until the row is learned again with an embedding.
  """
  @spec snapshot(module(), keyword()) :: {:ok, String.t() | [map()]} | {:error, term()}
  def snapshot(agent, opts \\ [])

  def snapshot(agent, opts) when is_atom(agent) and is_list(opts) do
    source = Keyword.get(opts, :source, :online_learned)

    case examples(agent, Keyword.put(opts, :source, source)) do
      {:ok, rows} -> write_snapshot(rows, Keyword.get(opts, :path))
      {:error, reason} -> {:error, reason}
    end
  end

  def snapshot(agent, _opts), do: {:error, {:invalid_agent, agent}}

  @spec write_snapshot([row()], String.t() | nil | term()) ::
          {:ok, String.t() | [map()]} | {:error, term()}
  defp write_snapshot(rows, nil), do: {:ok, Enum.map(rows, &encode_snapshot_row/1)}

  defp write_snapshot(rows, path) when is_binary(path) do
    rows
    |> Enum.map(&encode_snapshot_row/1)
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> write_snapshot_file(path)
  end

  defp write_snapshot(_rows, path), do: {:error, {:invalid_snapshot_path, path}}

  @spec write_snapshot_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_snapshot_file(encoded, path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_snapshot_file_contents(path, encoded)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_snapshot_file_contents(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp write_snapshot_file_contents(path, encoded) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    contents = encoded <> if(encoded == "", do: "", else: "\n")

    with :ok <- File.write(temporary, contents),
         :ok <- File.rename(temporary, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  @doc """
  Loads online examples and their stored embeddings from snapshot rows or a
  JSONL path.

  The second argument may be a path, a list of snapshot maps, or a keyword
  list containing `:path` or `:rows`:

      {:ok, %{loaded: loaded, skipped: skipped, errors: errors}} =
        Learned.load_snapshot(MyApp.Agent, "priv/cache/support.jsonl")

  Each label is resolved against the agent's current routes. Blank, malformed,
  unknown, and no-longer-cacheable rows are skipped and reported in the
  summary. Pass `strict?: true` to return
  `{:error, {:invalid_snapshot, summary}}` when any row is skipped. Valid rows
  loaded before that strict error remain stored, so validate untrusted files
  before using strict loading as a deployment gate.
  """
  @spec load_snapshot(module(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_snapshot(agent, snapshot_or_opts, opts \\ []) when is_atom(agent) and is_list(opts) do
    with {:ok, opts} <- agent_opts(agent, opts),
         {:ok, entries} <- snapshot_entries(snapshot_or_opts) do
      load_entries(agent, entries, opts)
    end
  end

  @doc """
  Clears online rows and cached Vettore indexes for an agent.
  """
  @spec clear(module(), keyword()) :: :ok
  def clear(agent, opts \\ []) when is_atom(agent) do
    source = Keyword.get(opts, :source, :online_learned)

    if source in [:online_learned, :all] do
      clear_online_rows(agent)
      bump_online_revision(agent)
    end

    clear_indexes(agent)
  end

  @doc """
  Returns the merged row set used by built-in exact lookup and semantic search.
  """
  @spec rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  def rows(opts) when is_list(opts) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    with {:ok, offline} <- maybe_offline_dataset_rows(opts) do
      rows =
        offline ++
          maybe_static_route_rows(opts) ++
          online_rows(agent, opts)

      {:ok, dedupe(rows)}
    end
  end

  @doc """
  Returns the monotonic in-memory revision of an agent's online examples.

  The revision starts at zero and advances after successful mutations. Semantic
  index keys are derived from the searchable row contents themselves, while
  this counter remains available for host diagnostics.
  """
  @spec online_revision(module()) :: non_neg_integer()
  def online_revision(agent) do
    case :ets.lookup(revision_table(), agent) do
      [{^agent, revision}] -> revision
      [] -> 0
    end
  end

  @spec exact(String.t(), [row()]) :: {:ok, map()} | {:error, :miss}
  defp exact(text, rows) do
    key = normalize_text(text)

    rows
    |> Enum.find(&(&1.normalized_text == key))
    |> case do
      %{label: label, text: matched, confidence: confidence, source: source} = row ->
        {:ok,
         %{
           label: label,
           accepted?: true,
           confidence: confidence || 1.0,
           margin: 1.0,
           matched: matched,
           strategy: :semantic_cache_exact,
           semantic_examples: [row],
           semantic_cache_source: source
         }}

      nil ->
        {:error, :miss}
    end
  end

  @spec with_empty_metadata({:ok, map()} | {:error, term()}) ::
          {:ok, map(), map()} | {:error, term(), map()}
  defp with_empty_metadata({:ok, result}), do: {:ok, result, %{}}
  defp with_empty_metadata({:error, reason}), do: {:error, reason, %{}}

  @spec search(String.t(), [row()], keyword()) ::
          {:ok, map(), map()} | {:error, term(), map()}
  defp search(text, rows, opts) do
    with {:ok, %{collection: collection}} <- index(rows, opts),
         {:ok, query} <- embed(text, opts) do
      search_collection(collection, query, opts)
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  @spec search_collection(Vettore.Collection.t(), [float()], keyword()) ::
          {:ok, map(), map()} | {:error, term(), map()}
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

  @spec index([row()], keyword()) :: {:ok, map()} | {:error, term()}
  defp index(rows, opts) do
    key = cache_key(rows, opts)
    table = index_table()

    case :ets.lookup(table, key) do
      [{^key, index}] -> {:ok, index}
      [] -> load_index(table, key, rows, opts)
    end
  end

  @spec warm_stored_index(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp warm_stored_index(opts) do
    with {:ok, rows} <- rows(opts) do
      warm_stored_index(rows, length(stored_vectors(rows)), opts)
    end
  end

  @spec warm_stored_index([row()], non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp warm_stored_index(_rows, 0, _opts), do: {:ok, 0}

  defp warm_stored_index(rows, count, opts) do
    case index(rows, opts) do
      {:ok, _index} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_index(atom(), term(), [row()], keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec cache_collection(
          atom(),
          term(),
          Vettore.Collection.t(),
          [map()],
          keyword()
        ) :: {:ok, map()} | {:error, term()}
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

  @spec discard_collection(Vettore.Collection.t()) :: :ok
  defp discard_collection(collection) do
    Owner.drop_collection(collection)
    :ok
  end

  @spec new_collection(pos_integer(), keyword()) ::
          {:ok, Vettore.Collection.t()} | {:error, term()}
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

  @spec stored_vectors([row()]) :: [map()]
  defp stored_vectors(rows) do
    Enum.flat_map(rows, fn
      %{embedding: embedding} = row when is_list(embedding) and embedding != [] ->
        [Map.put(row, :vector, embedding)]

      _row ->
        []
    end)
  end

  @spec validate_stored_dimensions([map()], pos_integer()) :: :ok | {:error, term()}
  defp validate_stored_dimensions(rows, dimensions) do
    case Enum.find(rows, &(length(&1.vector) != dimensions)) do
      nil ->
        :ok

      %{id: id, vector: vector} ->
        {:error, {:semantic_cache_dimension_mismatch, id, length(vector), dimensions}}
    end
  end

  @spec embeddings([map()]) :: [Embedding.t()]
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

  @spec fetch_agent(keyword()) :: {:ok, module()} | {:error, term()}
  defp fetch_agent(opts) do
    case Keyword.get(opts, :spectre_agent) do
      agent when is_atom(agent) and not is_nil(agent) -> {:ok, agent}
      other -> {:error, {:missing_spectre_agent, other}}
    end
  end

  @spec agent_opts(module(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp agent_opts(agent, opts) do
    if valid_agent?(agent) do
      opts =
        agent.__spectre_router__()
        |> Keyword.merge(opts)
        |> Keyword.put_new(:spectre_agent, agent)
        |> Keyword.put_new(:spectre_rules, spectre_rules(agent))

      {:ok, opts}
    else
      {:error, {:invalid_agent, agent}}
    end
  end

  @spec valid_agent?(module()) :: boolean()
  defp valid_agent?(agent) do
    Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_router__, 0)
  end

  @spec spectre_rules(module()) :: [Rule.t()]
  defp spectre_rules(agent) do
    agent
    |> Spectre.Definition.rules()
    |> Enum.map(&Rule.new/1)
  end

  @spec maybe_offline_dataset_rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  defp maybe_offline_dataset_rows(opts) do
    if static_rows_enabled?(opts) and mirror_training_dataset?(opts) do
      offline_dataset_rows(opts)
    else
      {:ok, []}
    end
  end

  @spec maybe_static_route_rows(keyword()) :: [row()]
  defp maybe_static_route_rows(opts) do
    if static_rows_enabled?(opts), do: static_route_rows(opts), else: []
  end

  @spec offline_dataset_rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  defp offline_dataset_rows(opts) do
    rules = cacheable_rules(opts)

    opts
    |> sources()
    |> Enum.reject(&(&1 in [true, false, nil]))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case collect_entry(entry, rules, opts) do
        {:ok, rows} -> {:cont, {:ok, acc ++ rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec static_route_rows(keyword()) :: [row()]
  defp static_route_rows(opts) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    opts
    |> cacheable_rules()
    |> Enum.flat_map(fn rule ->
      rule
      |> static_examples()
      |> Enum.map(&static_route_row(agent, rule, &1))
    end)
  end

  @spec online_rows(module(), keyword()) :: [row()]
  defp online_rows(agent, opts) do
    labels = opts |> cacheable_rules() |> Map.new(&{&1.label, true})

    online_table()
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{^agent, _id}, %{label: label} = row} ->
        if Map.has_key?(labels, label) and usable_online_row?(row, opts), do: [row], else: []

      _other ->
        []
    end)
  end

  @spec usable_online_row?(row(), keyword()) :: boolean()
  defp usable_online_row?(row, opts) do
    row.verified? or Keyword.get(opts, :semantic_cache_include_unverified?, false)
  end

  @spec cacheable_rules(keyword()) :: [Rule.t()]
  defp cacheable_rules(opts) do
    opts
    |> Keyword.get(:spectre_rules, [])
    |> Enum.map(&Rule.new(rule_to_map(&1)))
    |> Enum.filter(&cacheable_rule?/1)
  end

  defp cacheable_rule?(%Rule{cache: false}), do: false
  defp cacheable_rule?(%Rule{via: []}), do: true
  defp cacheable_rule?(%Rule{via: via}), do: :semantic_cache in via

  @spec collect_entry(term(), [Rule.t()], keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_entry(entry, rules, opts) when is_binary(entry) do
    if File.exists?(entry) do
      collect_file(entry, rules, opts)
    else
      {:error, {:missing_semantic_cache_source, entry}}
    end
  end

  defp collect_entry(entry, _rules, _opts), do: {:error, {:invalid_learning_entry, entry}}

  @spec collect_file(String.t(), [Rule.t()], keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_file(path, rules, opts) do
    case Path.extname(path) do
      ".json" -> collect_json_file(path, rules, opts)
      ".jsonl" -> collect_jsonl_file(path, rules, opts)
      _other -> {:error, {:unsupported_semantic_cache_source, path}}
    end
  end

  @spec collect_json_file(String.t(), [Rule.t()], keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_json_file(path, rules, opts) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text),
         true <- is_list(decoded) || {:error, {:invalid_learning_json, path}} do
      {:ok, Enum.flat_map(decoded, &source_rows(&1, rules, opts, path))}
    end
  end

  @spec collect_jsonl_file(String.t(), [Rule.t()], keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_file(path, rules, opts) do
    case File.read(path) do
      {:ok, text} -> collect_jsonl_text(text, path, rules, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec collect_jsonl_text(String.t(), String.t(), [Rule.t()], keyword()) ::
          {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_text(text, path, rules, opts) do
    text
    |> dataset_lines()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      collect_jsonl_line(line, acc, path, rules, opts)
    end)
  end

  @spec collect_jsonl_line(String.t(), [row()], String.t(), [Rule.t()], keyword()) ::
          {:cont, {:ok, [row()]}} | {:halt, {:error, term()}}
  defp collect_jsonl_line(line, acc, path, rules, opts) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        {:cont, {:ok, acc ++ source_rows(decoded, rules, opts, path)}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_learning_jsonl_row, path, reason}}}
    end
  end

  @spec source_rows(term(), [Rule.t()], keyword(), String.t()) :: [row()]
  defp source_rows(%{"text" => text} = source, rules, opts, path) when is_binary(text) do
    source_label = Map.get(source, "label", Map.get(source, "intent"))
    rows_for_source_text(text, source_label, source, rules, opts, path)
  end

  defp source_rows(%{text: text} = source, rules, opts, path) when is_binary(text) do
    source_label = Map.get(source, :label, Map.get(source, :intent))
    rows_for_source_text(text, source_label, source, rules, opts, path)
  end

  defp source_rows(_source, _rules, _opts, _path), do: []

  @spec rows_for_source_text(String.t(), term(), map(), [Rule.t()], keyword(), String.t()) :: [
          row()
        ]
  defp rows_for_source_text(text, source_label, source, rules, opts, path) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    case matching_rules(source_label, rules) do
      [] ->
        []

      matched_rules ->
        Enum.map(matched_rules, fn rule ->
          offline_dataset_row(agent, rule, text, path, source)
        end)
    end
  end

  @spec matching_rules(term(), [Rule.t()]) :: [Rule.t()]
  defp matching_rules(label, _rules) when label in [nil, ""], do: []

  defp matching_rules(label, rules) do
    Enum.filter(rules, &same_label?(label, &1.label))
  end

  @spec offline_dataset_row(module(), Rule.t(), String.t(), String.t() | nil, map()) :: row()
  defp offline_dataset_row(agent, %Rule{} = rule, text, path, source) do
    normalized = normalize_text(text)

    normalize_row(%{
      id: "dataset_#{stable_hash([agent, rule.label, normalized, path])}",
      agent: agent,
      text: String.trim(text),
      normalized_text: normalized,
      label: rule.label,
      source: :offline_dataset,
      source_strategy: nil,
      accepted?: true,
      confidence: 1.0,
      margin: nil,
      verified?: true,
      editable?: false,
      embedding: source_embedding(source),
      metadata: %{
        dataset_path: path,
        source: source_metadata(source),
        rule_label: rule.label
      },
      inserted_at: static_timestamp(),
      updated_at: static_timestamp()
    })
  end

  @spec static_route_row(module(), Rule.t(), String.t()) :: row()
  defp static_route_row(agent, %Rule{} = rule, text) do
    normalized = normalize_text(text)

    normalize_row(%{
      id: "static_#{stable_hash([agent, rule.label, normalized])}",
      agent: agent,
      text: String.trim(text),
      normalized_text: normalized,
      label: rule.label,
      source: :static_route_example,
      source_strategy: nil,
      accepted?: true,
      confidence: 1.0,
      margin: nil,
      verified?: true,
      editable?: false,
      embedding: nil,
      metadata: %{rule_label: rule.label},
      inserted_at: static_timestamp(),
      updated_at: static_timestamp()
    })
  end

  @spec static_examples(Rule.t()) :: [String.t()]
  defp static_examples(%Rule{} = rule) do
    (rule.embedding ++ rule.bag ++ rule.jaro)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec mutable_online_row(module(), String.t(), keyword()) :: {:ok, row()} | {:error, term()}
  defp mutable_online_row(agent, id, opts) do
    case :ets.lookup(online_table(), {agent, id}) do
      [{{^agent, ^id}, %{editable?: true} = row}] ->
        if cacheable_label?(row.label, opts),
          do: {:ok, row},
          else: {:error, {:unknown_label, row.label}}

      [{{^agent, ^id}, _row}] ->
        {:error, :read_only_example}

      [] ->
        {:error, :not_found}
    end
  end

  @spec mutable_or_read_only_row(module(), String.t(), keyword()) ::
          {:ok, row()} | {:error, term()}
  defp mutable_or_read_only_row(agent, id, opts) do
    case mutable_online_row(agent, id, opts) do
      {:error, :not_found} ->
        case get_example(agent, id, opts) do
          {:ok, %{editable?: false}} -> {:error, :read_only_example}
          {:ok, _row} -> {:error, :read_only_example}
          {:error, _reason} -> {:error, :not_found}
        end

      result ->
        result
    end
  end

  @spec read_only_or_not_found(module(), String.t(), keyword()) :: :ok | {:error, term()}
  defp read_only_or_not_found(agent, id, opts) do
    case get_example(agent, id, opts) do
      {:ok, %{editable?: false}} -> {:error, :read_only_example}
      {:ok, _row} -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @spec find_online_by_normalized(module(), String.t()) :: row() | nil
  defp find_online_by_normalized(agent, normalized) do
    online_table()
    |> :ets.tab2list()
    |> Enum.find_value(fn
      {{^agent, _id}, %{normalized_text: ^normalized} = row} -> row
      _other -> nil
    end)
  end

  @spec routeable_label(term(), keyword()) :: {:ok, atom()} | {:error, term()}
  defp routeable_label(label, opts) do
    case route_label(label, Keyword.get(opts, :spectre_rules, [])) do
      nil -> {:error, {:unknown_label, label}}
      label -> {:ok, label}
    end
  end

  @spec cacheable_label(atom(), keyword()) :: :ok | {:error, term()}
  defp cacheable_label(label, opts) do
    if cacheable_label?(label, opts), do: :ok, else: {:error, {:uncacheable_label, label}}
  end

  @spec cacheable_label?(atom(), keyword()) :: boolean()
  defp cacheable_label?(label, opts), do: Enum.any?(cacheable_rules(opts), &(&1.label == label))

  @spec route_label(term(), [Rule.t() | map()]) :: atom() | nil
  defp route_label(label, rules) when is_atom(label) do
    Enum.find_value(rules, fn rule ->
      rule = Rule.new(rule_to_map(rule))
      if rule.label == label, do: rule.label
    end)
  end

  defp route_label(label, rules) when is_binary(label) do
    Enum.find_value(rules, fn rule ->
      rule = Rule.new(rule_to_map(rule))
      if same_label?(label, rule.label), do: rule.label
    end)
  end

  defp route_label(_label, _rules), do: nil

  defp rule_to_map(%Rule{} = rule), do: Map.from_struct(rule)
  defp rule_to_map(rule) when is_map(rule), do: rule

  @spec result_route_label(map()) :: term()
  defp result_route_label(result) do
    Map.get(result, :label) || Map.get(result, :intent) || Map.get(result, "label") ||
      Map.get(result, "intent")
  end

  @spec result_id(map()) :: String.t() | nil
  defp result_id(result) do
    case Map.get(result, :id) || Map.get(result, "id") do
      id when is_binary(id) and id != "" -> id
      _other -> nil
    end
  end

  @spec result_source_strategy(map()) :: atom() | nil
  defp result_source_strategy(result) do
    Map.get(result, :source_strategy) || Map.get(result, "source_strategy") ||
      Map.get(result, :strategy)
  end

  @spec result_confidence(map(), keyword()) :: float()
  defp result_confidence(result, opts) do
    case Map.get(result, :confidence) do
      value when is_number(value) and value > 0 -> value
      _other -> Keyword.get(opts, :semantic_learn_confidence, @default_learn_confidence)
    end
  end

  @spec stored_embedding(String.t(), map(), row() | nil, keyword()) ::
          {:ok, [float()] | nil} | {:error, term()}
  defp stored_embedding(text, result, existing, opts) do
    case result_embedding(result) do
      {:present, embedding} -> normalize_embedding(embedding)
      :missing -> existing_or_new_embedding(text, existing, opts)
    end
  end

  @spec result_embedding(map()) :: {:present, term()} | :missing
  defp result_embedding(result) do
    cond do
      Map.has_key?(result, :embedding) -> {:present, Map.get(result, :embedding)}
      Map.has_key?(result, "embedding") -> {:present, Map.get(result, "embedding")}
      Map.has_key?(result, :vector) -> {:present, Map.get(result, :vector)}
      Map.has_key?(result, "vector") -> {:present, Map.get(result, "vector")}
      true -> :missing
    end
  end

  @spec existing_or_new_embedding(String.t(), row() | nil, keyword()) ::
          {:ok, [float()] | nil} | {:error, term()}
  defp existing_or_new_embedding(_text, %{embedding: embedding}, _opts)
       when is_list(embedding) and embedding != [],
       do: {:ok, embedding}

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

  @spec embedding_configured?(keyword()) :: boolean()
  defp embedding_configured?(opts) do
    classifier_opts =
      :spectre
      |> Application.get_env(:classifier, [])
      |> Keyword.merge(opts)

    Keyword.has_key?(opts, :embedding) or
      Keyword.has_key?(classifier_opts, :embedding_adapter) or
      Keyword.has_key?(classifier_opts, :embed)
  end

  @spec normalize_embedding(term()) :: {:ok, [float()] | nil} | {:error, term()}
  defp normalize_embedding(nil), do: {:ok, nil}

  defp normalize_embedding(embedding) when is_list(embedding) and embedding != [] do
    if Enum.all?(embedding, &finite_number?/1) do
      {:ok, Enum.map(embedding, &(&1 * 1.0))}
    else
      {:error, :invalid_semantic_cache_embedding}
    end
  end

  defp normalize_embedding(_embedding), do: {:error, :invalid_semantic_cache_embedding}

  @spec finite_number?(term()) :: boolean()
  defp finite_number?(number) when is_integer(number), do: true

  defp finite_number?(number) when is_float(number) do
    _encoded = :erlang.float_to_binary(number, [:compact])
    true
  rescue
    ArithmeticError -> false
  end

  defp finite_number?(_number), do: false

  @spec online_metadata(map(), module(), atom(), DateTime.t()) :: map()
  defp online_metadata(result, agent, label, now) do
    result_metadata =
      case Map.get(result, :metadata, %{}) do
        metadata when is_map(metadata) -> metadata
        _other -> %{}
      end

    Map.merge(result_metadata, %{
      agent: agent,
      route: label,
      verified?: Map.get(result, :verified?, false),
      learned_at: now,
      original_route_strategy: result_source_strategy(result)
    })
  end

  @spec valid_text(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp valid_text(text) do
    text = String.trim(text)
    if text == "", do: {:error, :blank_text}, else: {:ok, text}
  end

  @spec normalize_row(map()) :: row()
  defp normalize_row(row) do
    row
    |> Map.update!(:text, &String.trim/1)
    |> Map.update(:normalized_text, normalize_text(row.text), &normalize_text/1)
    |> Map.put_new(:accepted?, true)
    |> Map.put_new(:confidence, nil)
    |> Map.put_new(:margin, nil)
    |> Map.put_new(:source_strategy, nil)
    |> Map.put_new(:embedding, nil)
    |> Map.put_new(:metadata, %{})
  end

  @spec put_metadata(row(), atom(), term()) :: row()
  defp put_metadata(row, key, value) do
    Map.update!(row, :metadata, &Map.put(&1, key, value))
  end

  @spec dedupe([row()]) :: [row()]
  defp dedupe(rows) do
    rows
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(&dedupe_rank/1)
    |> Enum.uniq_by(&{&1.agent, &1.normalized_text})
  end

  @spec dedupe_rank(row()) :: {integer(), integer()}
  defp dedupe_rank(%{source: :online_learned, verified?: true, updated_at: updated_at}) do
    {0, -DateTime.to_unix(updated_at, :microsecond)}
  end

  defp dedupe_rank(%{source: :offline_dataset, embedding: embedding})
       when is_list(embedding) and embedding != [],
       do: {1, 0}

  defp dedupe_rank(%{source: :offline_dataset}), do: {1, 1}
  defp dedupe_rank(%{source: :static_route_example}), do: {2, 0}

  defp dedupe_rank(%{source: :online_learned, updated_at: updated_at}) do
    {3, -DateTime.to_unix(updated_at, :microsecond)}
  end

  @spec encode_snapshot_row(row()) :: map()
  defp encode_snapshot_row(row) do
    %{
      id: row.id,
      text: row.text,
      label: to_string(row.label),
      source: to_string(row.source),
      source_strategy: source_strategy_string(row.source_strategy),
      confidence: row.confidence,
      verified: row.verified?,
      embedding: row.embedding,
      inserted_at: DateTime.to_iso8601(row.inserted_at),
      updated_at: DateTime.to_iso8601(row.updated_at),
      metadata: encode_metadata(row.metadata)
    }
  end

  @spec source_strategy_string(atom() | nil) :: String.t() | nil
  defp source_strategy_string(nil), do: nil
  defp source_strategy_string(strategy), do: to_string(strategy)

  @spec snapshot_entries(term()) :: {:ok, [map()]} | {:error, term()}
  defp snapshot_entries(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      snapshot_entries_from_opts(opts)
    else
      {:ok, opts}
    end
  end

  defp snapshot_entries(path) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, snapshot_lines(text)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_entries(other), do: {:error, {:invalid_snapshot, other}}

  @spec snapshot_entries_from_opts(keyword()) :: {:ok, [map()]} | {:error, term()}
  defp snapshot_entries_from_opts(opts) do
    cond do
      path = Keyword.get(opts, :path) -> snapshot_entries(path)
      rows = Keyword.get(opts, :rows) -> snapshot_entries(rows)
      true -> {:error, :missing_snapshot}
    end
  end

  @spec snapshot_lines(String.t()) :: [map()]
  defp snapshot_lines(text) do
    text
    |> dataset_lines()
    |> Enum.map(&decode_snapshot_line/1)
  end

  @spec decode_snapshot_line(String.t()) :: map()
  defp decode_snapshot_line(line) do
    case Jason.decode(line) do
      {:ok, row} -> row
      {:error, reason} -> %{"__error__" => {:invalid_json, reason}}
    end
  end

  @spec load_entries(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  defp load_entries(agent, entries, opts) do
    {loaded, skipped, errors} =
      Enum.reduce(entries, {0, 0, []}, fn entry, {loaded, skipped, errors} ->
        case load_entry(agent, entry, opts) do
          {:ok, row} ->
            :ets.insert(online_table(), {{agent, row.id}, row})
            {loaded + 1, skipped, errors}

          {:skip, reason} ->
            {loaded, skipped + 1, [reason | errors]}
        end
      end)

    if loaded > 0 do
      bump_online_revision(agent)
    end

    _index_status = warm_stored_index(opts)
    summary = %{loaded: loaded, skipped: skipped, errors: Enum.reverse(errors)}

    if Keyword.get(opts, :strict?, false) and errors != [] do
      {:error, {:invalid_snapshot, summary}}
    else
      {:ok, summary}
    end
  end

  @spec load_entry(module(), map(), keyword()) :: {:ok, row()} | {:skip, term()}
  defp load_entry(_agent, %{"__error__" => reason}, _opts), do: {:skip, reason}

  defp load_entry(agent, entry, opts) when is_map(entry) do
    with {:ok, text} <- snapshot_text(entry),
         {:ok, label} <- routeable_label(snapshot_label(entry), opts),
         :ok <- cacheable_label(label, opts),
         {:ok, embedding} <- snapshot_embedding(entry) do
      {:ok, snapshot_row(agent, entry, text, label, embedding)}
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp load_entry(_agent, entry, _opts), do: {:skip, {:invalid_snapshot_row, entry}}

  @spec snapshot_text(map()) :: {:ok, String.t()} | {:skip, term()}
  defp snapshot_text(entry) do
    case Map.get(entry, "text") || Map.get(entry, :text) do
      text when is_binary(text) ->
        if String.trim(text) == "", do: {:skip, :blank_text}, else: {:ok, text}

      _other ->
        {:skip, :blank_text}
    end
  end

  @spec snapshot_label(map()) :: term()
  defp snapshot_label(entry), do: Map.get(entry, "label") || Map.get(entry, :label)

  @spec snapshot_row(module(), map(), String.t(), atom(), [float()] | nil) :: row()
  defp snapshot_row(agent, entry, text, label, embedding) do
    now = DateTime.utc_now()
    id = Map.get(entry, "id") || Map.get(entry, :id) || online_id()

    normalize_row(%{
      id: id,
      agent: agent,
      text: text,
      normalized_text: normalize_text(text),
      label: label,
      source: :online_learned,
      source_strategy:
        snapshot_atom(Map.get(entry, "source_strategy") || Map.get(entry, :source_strategy)),
      accepted?: true,
      confidence: snapshot_confidence(entry),
      margin: nil,
      verified?:
        Map.get(entry, "verified", Map.get(entry, :verified, Map.get(entry, :verified?, false))),
      editable?: true,
      embedding: embedding || existing_snapshot_embedding(agent, id, text),
      metadata: snapshot_metadata(entry),
      inserted_at:
        snapshot_time(Map.get(entry, "inserted_at") || Map.get(entry, :inserted_at), now),
      updated_at: snapshot_time(Map.get(entry, "updated_at") || Map.get(entry, :updated_at), now)
    })
  end

  @spec snapshot_confidence(map()) :: float()
  defp snapshot_confidence(entry) do
    case Map.get(entry, "confidence") || Map.get(entry, :confidence) do
      value when is_number(value) and value > 0 -> value
      _other -> @default_learn_confidence
    end
  end

  @spec snapshot_embedding(map()) :: {:ok, [float()] | nil} | {:error, term()}
  defp snapshot_embedding(entry) do
    entry
    |> Map.get("embedding", Map.get(entry, :embedding))
    |> normalize_embedding()
  end

  @spec existing_snapshot_embedding(module(), String.t(), String.t()) :: [float()] | nil
  defp existing_snapshot_embedding(agent, id, text) do
    case :ets.lookup(online_table(), {agent, id}) do
      [{{^agent, ^id}, %{text: existing_text, embedding: embedding}}]
      when is_list(embedding) and embedding != [] ->
        if normalize_text(existing_text) == normalize_text(text), do: embedding

      _other ->
        nil
    end
  end

  @spec snapshot_metadata(map()) :: map()
  defp snapshot_metadata(entry) do
    case Map.get(entry, "metadata") || Map.get(entry, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  @spec snapshot_atom(term()) :: atom() | nil
  defp snapshot_atom(nil), do: nil

  defp snapshot_atom(value) when is_atom(value), do: value

  defp snapshot_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> existing_snapshot_atom(text)
    end
  end

  @spec existing_snapshot_atom(String.t()) :: atom() | nil
  defp existing_snapshot_atom(text) do
    String.to_existing_atom(text)
  rescue
    ArgumentError -> nil
  end

  @spec snapshot_time(term(), DateTime.t()) :: DateTime.t()
  defp snapshot_time(%DateTime{} = time, _default), do: time

  defp snapshot_time(value, default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _other -> default
    end
  end

  defp snapshot_time(_value, default), do: default

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

  @spec result_rows([Vettore.Result.t()]) :: [row()]
  defp result_rows(results) do
    Enum.flat_map(results, fn
      %{metadata: %{"row" => row}} when is_map(row) -> [row]
      _other -> []
    end)
  end

  @spec label_scores([Vettore.Result.t()]) :: map()
  defp label_scores(results) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.update(acc, result_label(result), result.score, &max(&1, result.score))
    end)
  end

  @spec cache_key([row()], keyword()) :: term()
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

  @spec index_rows_revision([row()]) :: [term()]
  defp index_rows_revision(rows) do
    rows
    |> Enum.map(&{&1.id, &1.label, &1.normalized_text, &1.embedding})
    |> Enum.sort()
  end

  @spec clear_indexes(module()) :: :ok
  defp clear_indexes(agent) do
    case Owner.clear_indexes(agent) do
      :ok -> :ok
      {:error, reason} -> raise "semantic cache indexes unavailable: #{inspect(reason)}"
    end
  end

  @spec clear_online_rows(module()) :: :ok
  defp clear_online_rows(agent) do
    online_table()
    |> :ets.tab2list()
    |> Enum.each(fn
      {{^agent, id}, _row} -> :ets.delete(@online_table, {agent, id})
      _other -> :ok
    end)

    :ok
  end

  @spec semantic_cache_capacity(keyword()) :: pos_integer() | :unlimited
  defp semantic_cache_capacity(opts) do
    case Keyword.get(opts, :semantic_cache_capacity, configured_index_capacity()) do
      :unlimited -> :unlimited
      capacity when is_integer(capacity) and capacity > 0 -> capacity
      _other -> @default_index_capacity
    end
  end

  @spec configured_index_capacity() :: pos_integer() | :unlimited
  defp configured_index_capacity do
    case Application.get_env(:spectre, :semantic_cache, []) do
      config when is_list(config) ->
        Keyword.get(config, :index_capacity, @default_index_capacity)

      _other ->
        @default_index_capacity
    end
  end

  @spec index_table() :: atom()
  defp index_table do
    ensure_table(@index_table, [:named_table, :public, :set, :compressed, read_concurrency: true])
  end

  @spec online_table() :: atom()
  defp online_table do
    ensure_table(@online_table, [:named_table, :public, :set, :compressed, read_concurrency: true])
  end

  @spec revision_table() :: atom()
  defp revision_table do
    ensure_table(@revision_table, [:named_table, :public, :set, write_concurrency: true])
  end

  @spec ensure_table(atom(), list()) :: atom()
  defp ensure_table(name, options) do
    case Owner.ensure_table(name, options) do
      {:ok, ^name} -> name
      {:error, reason} -> raise "semantic cache table unavailable: #{inspect(reason)}"
    end
  end

  @spec bump_online_revision(module()) :: non_neg_integer()
  defp bump_online_revision(agent) do
    :ets.update_counter(revision_table(), agent, {2, 1}, {agent, 0})
  end

  @spec sources(keyword()) :: [String.t()]
  defp sources(opts) do
    opts
    |> Keyword.get_values(:semantic_cache_source)
    |> Kernel.++(Keyword.get_values(opts, :source))
    |> Kernel.++(semantic_artifact_sources(opts))
    |> Kernel.++(configured_sources())
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  @spec semantic_artifact_sources(keyword()) :: [String.t()]
  defp semantic_artifact_sources(opts) do
    config = Application.get_env(:spectre, :classifier, [])
    artifact_dir = Keyword.get(opts, :artifact_dir, Keyword.get(config, :artifact_dir))

    case artifact_dir do
      path when is_binary(path) ->
        semantic_path = Path.join(path, "semantic_cache.jsonl")
        if File.regular?(semantic_path), do: [semantic_path], else: []

      _other ->
        []
    end
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

  @spec static_rows_enabled?(keyword()) :: boolean()
  defp static_rows_enabled?(opts), do: Keyword.get(opts, :semantic_cache_static?, true)

  @spec mirror_training_dataset?(keyword()) :: boolean()
  defp mirror_training_dataset?(opts) do
    opts
    |> Keyword.get(
      :mirror_training_dataset?,
      Application.get_env(:spectre, :semantic_cache, [])
      |> Keyword.get(:mirror_training_dataset?, true)
    )
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

  @spec dataset_lines(String.t()) :: [String.t()]
  defp dataset_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
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

  @spec static_timestamp() :: DateTime.t()
  defp static_timestamp, do: ~U[1970-01-01 00:00:00Z]

  @spec stable_hash(term()) :: String.t()
  defp stable_hash(term), do: term |> :erlang.phash2() |> Integer.to_string(36)

  @spec online_id() :: String.t()
  defp online_id do
    "scx_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  @spec source_embedding(map()) :: [float()] | nil
  defp source_embedding(source) do
    source
    |> Map.get(
      "embedding",
      Map.get(source, :embedding, Map.get(source, "vector", Map.get(source, :vector)))
    )
    |> normalize_embedding()
    |> case do
      {:ok, embedding} -> embedding
      {:error, _reason} -> nil
    end
  end

  @spec source_metadata(map()) :: map()
  defp source_metadata(source) do
    source
    |> Map.drop(["embedding", :embedding, "vector", :vector])
    |> Enum.reject(fn {_key, value} -> is_binary(value) and byte_size(value) > 2_000 end)
    |> Map.new()
  end

  @spec encode_metadata(map()) :: map()
  defp encode_metadata(metadata) do
    Map.new(metadata, fn {key, value} ->
      {to_string(key), encode_metadata_value(value)}
    end)
  end

  defp encode_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_metadata_value(value) when is_atom(value), do: to_string(value)
  defp encode_metadata_value(value) when is_map(value), do: encode_metadata(value)

  defp encode_metadata_value(value) when is_list(value),
    do: Enum.map(value, &encode_metadata_value/1)

  defp encode_metadata_value(value), do: value
end
