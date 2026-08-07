defmodule Spectre.Router.SemanticCache.Owner do
  @moduledoc """
  Stable owner for the built-in semantic-cache ETS tables and collection
  lifecycle operations.

  Tables created by arbitrary request processes disappear when those callers
  exit. Owning them from the application supervision tree makes their lifetime
  explicit and lets a supervisor rebuild a consistent empty projection after a
  crash.
  """

  use GenServer

  @index_table Spectre.Router.SemanticCache.Learned
  @online_table Module.concat(Spectre.Router.SemanticCache.Learned, Online)
  @revision_table Module.concat(Spectre.Router.SemanticCache.Learned, Revisions)
  @source_table Module.concat(Spectre.Router.SemanticCache.Learned.Sources, Cache)
  @embedding_table Module.concat(Spectre.Router.Plugs.EmbeddingSimilarity, Cache)
  @tables [@index_table, @online_table, @revision_table, @source_table, @embedding_table]

  @table_specs %{
    @index_table => [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true
    ],
    @online_table => [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true,
      write_concurrency: true
    ],
    @revision_table => [
      :named_table,
      :public,
      :set,
      write_concurrency: true
    ],
    @source_table => [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true,
      write_concurrency: true
    ],
    @embedding_table => [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true,
      write_concurrency: true
    ]
  }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc false
  @spec ensure_table(atom(), list()) :: {:ok, atom()} | {:error, term()}
  def ensure_table(name, options) when name in @tables and is_list(options),
    do: call_owner({:ensure_table, name, options})

  def ensure_table(name, _options), do: {:error, {:unknown_semantic_cache_table, name}}

  @doc false
  @spec new_collection(keyword()) :: {:ok, Vettore.Collection.t()} | {:error, term()}
  def new_collection(opts) when is_list(opts), do: call_owner({:new_collection, opts})
  def new_collection(opts), do: {:error, {:invalid_collection_options, opts}}

  @doc false
  @spec drop_collection(Vettore.Collection.t()) :: :ok | {:error, term()}
  def drop_collection(%Vettore.Collection{} = collection),
    do: call_owner({:drop_collection, collection})

  @doc false
  @spec cache_index(atom(), term(), map(), pos_integer() | :unlimited) ::
          {:ok, map()} | {:error, term()}
  def cache_index(@index_table, key, index, capacity)
      when is_map(index) and (capacity == :unlimited or (is_integer(capacity) and capacity > 0)),
      do: call_owner({:cache_index, key, index, capacity})

  def cache_index(table, _key, _index, _capacity),
    do: {:error, {:invalid_semantic_cache_index, table}}

  @doc false
  @spec clear_indexes(module()) :: :ok | {:error, term()}
  def clear_indexes(agent) when is_atom(agent), do: call_owner({:clear_indexes, agent})
  def clear_indexes(agent), do: {:error, {:invalid_agent, agent}}

  @impl GenServer
  def init(:ok) do
    Process.flag(:trap_exit, true)
    Enum.each(@table_specs, fn {name, options} -> create_table(name, options) end)
    {:ok, %{collections: %{}}}
  end

  @impl GenServer
  def handle_call({:ensure_table, name, options}, _from, state) do
    {:reply, create_table(name, options), state}
  end

  def handle_call({:new_collection, opts}, _from, state) do
    # Collection lifecycle changes remain serialized with cache updates. Modern
    # Vettore versions place each ETS collection under their own supervised
    # owner. Link those temporary owners back to this process so an abnormal
    # semantic-cache owner exit cannot orphan vector stores that are no longer
    # reachable from the rebuilt index table.
    case create_collection(opts) do
      {:ok, %Vettore.Collection{} = collection} ->
        collection_owner = collection.store_state.owner
        Process.link(collection_owner)

        {:reply, {:ok, collection}, put_in(state, [:collections, collection_owner], collection)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:drop_collection, collection}, _from, state) do
    owner = collection.store_state.owner
    {:reply, close_collection(collection), update_in(state.collections, &Map.delete(&1, owner))}
  end

  def handle_call({:cache_index, key, index, capacity}, _from, state) do
    {:reply, put_index(key, index, capacity), state}
  end

  def handle_call({:clear_indexes, agent}, _from, state) do
    {:reply, clear_agent_indexes(agent), state}
  end

  @impl GenServer
  def handle_info({:EXIT, collection_owner, _reason}, state) do
    delete_indexes_owned_by(collection_owner)
    {:noreply, update_in(state.collections, &Map.delete(&1, collection_owner))}
  end

  @impl GenServer
  def terminate(_reason, state) do
    state.collections
    |> Map.values()
    |> Enum.each(&close_collection/1)

    :ok
  end

  @spec call_owner(term()) :: term()
  defp call_owner(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :semantic_cache_owner_not_started}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  @spec create_collection(keyword()) :: {:ok, Vettore.Collection.t()} | {:error, term()}
  defp create_collection(opts) do
    Vettore.new(opts)
  rescue
    exception ->
      {:error,
       {:semantic_cache_collection_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:semantic_cache_collection_failure, kind, reason}}
  end

  @spec put_index(term(), map(), pos_integer() | :unlimited) :: {:ok, map()}
  defp put_index(key, index, capacity) do
    case :ets.lookup(@index_table, key) do
      [{^key, existing}] ->
        drop_index_collection(index)
        {:ok, existing}

      [] ->
        true = :ets.insert(@index_table, {key, index})
        evict_agent_indexes(key, capacity)
        {:ok, index}
    end
  end

  @spec evict_agent_indexes(term(), pos_integer() | :unlimited) :: :ok
  defp evict_agent_indexes(_new_key, :unlimited), do: :ok

  defp evict_agent_indexes({{:agent, agent}, _hash}, capacity) do
    entries =
      @index_table
      |> :ets.tab2list()
      |> Enum.filter(fn
        {{{:agent, ^agent}, _hash}, _index} -> true
        _other -> false
      end)

    entries
    |> Enum.sort_by(fn {_key, index} -> Map.get(index, :inserted_at, 0) end)
    |> Enum.take(max(length(entries) - capacity, 0))
    |> Enum.each(&drop_cached_index/1)

    :ok
  end

  defp evict_agent_indexes(_new_key, _capacity), do: :ok

  @spec clear_agent_indexes(module()) :: :ok
  defp clear_agent_indexes(agent) do
    @index_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {{{:agent, ^agent}, _hash}, _index} = entry -> drop_cached_index(entry)
      _other -> :ok
    end)

    :ok
  end

  @spec delete_indexes_owned_by(pid()) :: :ok
  defp delete_indexes_owned_by(collection_owner) do
    @index_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {key, %{collection: %Vettore.Collection{store_state: %{owner: ^collection_owner}}}} ->
        true = :ets.delete(@index_table, key)

      _other ->
        :ok
    end)

    :ok
  end

  @spec drop_cached_index({term(), map()}) :: :ok
  defp drop_cached_index({key, index}) do
    drop_index_collection(index)
    true = :ets.delete(@index_table, key)
    :ok
  end

  @spec drop_index_collection(map()) :: :ok | {:error, term()}
  defp drop_index_collection(%{collection: %Vettore.Collection{} = collection}),
    do: close_collection(collection)

  defp drop_index_collection(_index), do: :ok

  @spec create_table(atom(), list()) :: {:ok, atom()}
  defp create_table(name, options) do
    case :ets.whereis(name) do
      :undefined ->
        ^name = :ets.new(name, options)
        {:ok, name}

      _tid ->
        {:ok, name}
    end
  end

  @spec close_collection(Vettore.Collection.t()) :: :ok | {:error, term()}
  defp close_collection(collection) do
    Vettore.close(collection)
  rescue
    exception ->
      {:error,
       {:semantic_cache_collection_close_exception, exception.__struct__,
        Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:semantic_cache_collection_close_failure, kind, reason}}
  end
end
