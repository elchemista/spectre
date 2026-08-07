defmodule Spectre.Router.SemanticCache.Learned do
  @moduledoc """
  Built-in semantic cache backed by static dataset rows and online examples.

  Static rows come from labeled classifier datasets and route examples. Online
  rows are mutable runtime examples stored in ETS. Exact lookup reads the merged
  row set directly. Semantic search only indexes embeddings already stored with
  those rows; it never embeds the full dataset from a request process.

  The cache is split by concern: `Learned.Rows` owns the row and label
  vocabulary, `Learned.Online` the ETS-backed online store, `Learned.Sources`
  the static dataset and route-example rows, `Learned.Index` the Vettore
  index and embedding acquisition, and `Learned.Snapshot` portable
  export/import. This module keeps the public API and review workflow.
  """

  import Spectre.Router.SemanticCache.Learned.Rows

  alias Spectre.Router.SemanticCache.Learned.Index
  alias Spectre.Router.SemanticCache.Learned.Online
  alias Spectre.Router.SemanticCache.Learned.Snapshot
  alias Spectre.Router.SemanticCache.Learned.Sources
  alias Spectre.Rule

  @default_learn_confidence 0.86

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
    with {:ok, rows} <- rows(Keyword.put(opts, :semantic_cache_runtime_lookup?, true)),
         [_ | _] <- rows do
      if Keyword.get(opts, :semantic_search?, false) do
        Index.search(text, rows, opts)
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
         existing <- Online.find_by_normalized(agent, normalize_text(text)),
         {:ok, embedding} <- Index.stored_embedding(text, result, existing, opts) do
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

      Online.put_row(row, opts)
      Online.bump_revision(agent)
      _index_status = warm_index(opts)
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
        :online_learned -> {:ok, Online.rows(agent, review_opts)}
        :offline_dataset -> Sources.offline_dataset_rows(opts)
        :static_route_example -> {:ok, Sources.static_route_rows(opts)}
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

      Online.put_row(updated, opts)
      Online.bump_revision(agent)
      _index_status = warm_index(opts)
      {:ok, updated}
    end
  end

  def relabel(agent, id, label, _opts), do: {:error, {:invalid_relabel, agent, id, label}}

  @doc """
  Edits an online learned example in place.

  Supported attrs: `:text` (re-embedded through the configured embedding
  adapter), `:label` (must name a cacheable route), and `:verified`. Static
  route examples and offline dataset rows are read-only and return
  `{:error, :read_only_example}`.

      {:ok, updated} =
        Learned.update_example(MyApp.Agent, id, %{text: "nuovo testo", label: :PRICING})

  A successful mutation increments `online_revision/1` and refreshes the local
  semantic index.
  """
  @spec update_example(module(), String.t(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  def update_example(agent, id, attrs, opts \\ [])

  def update_example(agent, id, attrs, opts)
      when is_atom(agent) and is_binary(id) and is_map(attrs) do
    with {:ok, opts} <- agent_opts(agent, opts),
         {:ok, row} <- mutable_or_read_only_row(agent, id, opts),
         {:ok, row} <- apply_example_label(row, attrs, opts),
         {:ok, row} <- apply_example_text(row, attrs, opts) do
      now = DateTime.utc_now()

      updated =
        row
        |> apply_example_verified(attrs, now)
        |> Map.put(:updated_at, now)

      Online.put_row(updated, opts)
      Online.bump_revision(agent)
      _index_status = warm_index(opts)
      {:ok, updated}
    end
  end

  def update_example(agent, id, attrs, _opts),
    do: {:error, {:invalid_example_update, agent, id, attrs}}

  @spec apply_example_label(row(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  defp apply_example_label(row, %{label: label}, opts) when is_atom(label) do
    with {:ok, label} <- routeable_label(label, opts),
         :ok <- cacheable_label(label, opts) do
      {:ok, Map.put(row, :label, label)}
    end
  end

  defp apply_example_label(_row, %{label: label}, _opts),
    do: {:error, {:invalid_example_label, label}}

  defp apply_example_label(row, _attrs, _opts), do: {:ok, row}

  @spec apply_example_text(row(), map(), keyword()) :: {:ok, row()} | {:error, term()}
  defp apply_example_text(row, %{text: text}, opts) when is_binary(text) do
    with {:ok, text} <- valid_text(text),
         {:ok, embedding} <- Index.stored_embedding(text, %{}, nil, opts) do
      {:ok,
       Map.merge(row, %{text: text, normalized_text: normalize_text(text), embedding: embedding})}
    end
  end

  defp apply_example_text(_row, %{text: text}, _opts),
    do: {:error, {:invalid_example_text, text}}

  defp apply_example_text(row, _attrs, _opts), do: {:ok, row}

  @spec apply_example_verified(row(), map(), DateTime.t()) :: row()
  defp apply_example_verified(row, %{verified: verified}, now) when is_boolean(verified) do
    if verified do
      row |> Map.put(:verified?, true) |> put_metadata(:verified_at, now)
    else
      Map.put(row, :verified?, false)
    end
  end

  defp apply_example_verified(row, _attrs, _now), do: row

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
      case Online.mutable_row(agent, id, opts) do
        {:ok, _row} ->
          Online.delete_row(agent, id)
          Online.bump_revision(agent)
          _index_status = warm_index(opts)
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

      Online.put_row(updated, opts)
      Online.bump_revision(agent)
      _index_status = warm_index(opts)
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
      {:ok, rows} -> Snapshot.write(rows, Keyword.get(opts, :path))
      {:error, reason} -> {:error, reason}
    end
  end

  def snapshot(agent, _opts), do: {:error, {:invalid_agent, agent}}

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
         {:ok, entries} <- Snapshot.entries(snapshot_or_opts) do
      Snapshot.load(agent, entries, opts)
    end
  end

  @doc """
  Clears online rows and cached Vettore indexes for an agent.
  """
  @spec clear(module(), keyword()) :: :ok
  def clear(agent, opts \\ []) when is_atom(agent) do
    source = Keyword.get(opts, :source, :online_learned)

    if source in [:online_learned, :all] do
      Online.clear_rows(agent)
      Online.bump_revision(agent)
    end

    Index.clear(agent)
  end

  @doc """
  Returns the merged row set used by built-in exact lookup and semantic search.
  """
  @spec rows(keyword()) :: {:ok, [row()]} | {:error, term()}
  def rows(opts) when is_list(opts) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    with {:ok, offline} <- Sources.maybe_offline_dataset_rows(opts) do
      rows =
        offline ++
          Sources.maybe_static_route_rows(opts) ++
          Online.rows(agent, opts)

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
  def online_revision(agent), do: Online.revision(agent)

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

  @spec warm_index(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp warm_index(opts) do
    with {:ok, rows} <- rows(opts) do
      Index.warm(rows, opts)
    end
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

  @spec mutable_or_read_only_row(module(), String.t(), keyword()) ::
          {:ok, row()} | {:error, term()}
  defp mutable_or_read_only_row(agent, id, opts) do
    case Online.mutable_row(agent, id, opts) do
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
end
