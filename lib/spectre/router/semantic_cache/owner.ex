defmodule Spectre.Router.SemanticCache.Owner do
  @moduledoc """
  Stable owner for the built-in semantic-cache ETS tables.

  Tables created by arbitrary request processes disappear when those callers
  exit. Owning them from the application supervision tree makes their lifetime
  explicit and lets a supervisor rebuild a consistent empty projection after a
  crash.
  """

  use GenServer

  @index_table Spectre.Router.SemanticCache.Learned
  @online_table Module.concat(Spectre.Router.SemanticCache.Learned, Online)
  @revision_table Module.concat(Spectre.Router.SemanticCache.Learned, Revisions)
  @tables [@index_table, @online_table, @revision_table]

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
      read_concurrency: true
    ],
    @revision_table => [
      :named_table,
      :public,
      :set,
      write_concurrency: true
    ]
  }

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
  def drop_collection(%Vettore.Collection{
        store_state: %Vettore.Store.ETS{table: table}
      }),
      do: call_owner({:drop_table, table})

  def drop_collection(%Vettore.Collection{}), do: :ok

  @impl GenServer
  def init(:ok) do
    Enum.each(@table_specs, fn {name, options} -> create_table(name, options) end)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:ensure_table, name, options}, _from, state) do
    {:reply, create_table(name, options), state}
  end

  def handle_call({:new_collection, opts}, _from, state) do
    # Vettore's ETS store is owned by the process calling Vettore.new/1. Build
    # it here so a short-lived lookup process cannot invalidate a cached index.
    {:reply, Vettore.new(opts), state}
  end

  def handle_call({:drop_table, table}, _from, state) do
    {:reply, drop_owned_table(table), state}
  end

  @spec call_owner(term()) :: term()
  defp call_owner(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :semantic_cache_owner_not_started}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

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

  @spec drop_owned_table(:ets.tid()) :: :ok | {:error, term()}
  defp drop_owned_table(table) do
    case :ets.info(table, :owner) do
      owner when owner == self() ->
        true = :ets.delete(table)
        :ok

      :undefined ->
        :ok

      owner ->
        {:error, {:semantic_cache_table_not_owned, owner}}
    end
  rescue
    ArgumentError -> :ok
  end
end
