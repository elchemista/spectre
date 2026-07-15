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
  def ensure_table(name, options) when name in @tables and is_list(options) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :semantic_cache_owner_not_started}
      _pid -> GenServer.call(__MODULE__, {:ensure_table, name, options})
    end
  end

  def ensure_table(name, _options), do: {:error, {:unknown_semantic_cache_table, name}}

  @impl GenServer
  def init(:ok) do
    Enum.each(@table_specs, fn {name, options} -> create_table(name, options) end)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:ensure_table, name, options}, _from, state) do
    {:reply, create_table(name, options), state}
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
end
