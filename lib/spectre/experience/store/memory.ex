defmodule Spectre.Experience.Store.Memory do
  @moduledoc "Volatile reference implementation of `Spectre.Experience.Store`."

  use GenServer

  @behaviour Spectre.Experience.Store

  @type state :: %{id: term(), entries: %{optional(String.t()) => binary()}}

  @doc "Starts an empty in-memory Experience Store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {server_opts, init_opts} =
      Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns the current evidence count."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server), do: GenServer.call(server, :count)

  @impl Spectre.Experience.Store
  def identity(opts), do: GenServer.call(server!(opts), :identity)

  @impl Spectre.Experience.Store
  def durability(_opts), do: :volatile

  @impl Spectre.Experience.Store
  def get(key, opts), do: GenServer.call(server!(opts), {:get, key})

  @impl Spectre.Experience.Store
  def put(key, encoded, opts), do: GenServer.call(server!(opts), {:put, key, encoded})

  @impl Spectre.Experience.Store
  def list(opts), do: GenServer.call(server!(opts), :list)

  @impl Spectre.Experience.Store
  def delete(key, opts), do: GenServer.call(server!(opts), {:delete, key})

  @impl GenServer
  def init(opts) do
    {:ok, %{id: Keyword.get(opts, :id, :spectre_experience_memory), entries: %{}}}
  end

  @impl GenServer
  def handle_call(:identity, _from, state), do: {:reply, state.id, state}
  def handle_call(:count, _from, state), do: {:reply, map_size(state.entries), state}
  def handle_call(:list, _from, state), do: {:reply, {:ok, Enum.sort(state.entries)}, state}

  def handle_call({:get, key}, _from, state) do
    reply =
      case Map.fetch(state.entries, key) do
        {:ok, encoded} -> {:ok, encoded}
        :error -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:put, key, encoded}, _from, state) do
    case Map.fetch(state.entries, key) do
      :error -> {:reply, {:ok, :created}, put_in(state, [:entries, key], encoded)}
      {:ok, ^encoded} -> {:reply, {:ok, :existing}, state}
      {:ok, _different} -> {:reply, {:error, {:immutable_conflict, key}}, state}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    if Map.has_key?(state.entries, key),
      do: {:reply, :ok, update_in(state.entries, &Map.delete(&1, key))},
      else: {:reply, :not_found, state}
  end

  defp server!(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> server
      :error -> raise ArgumentError, "Experience Store Memory requires the :server option"
    end
  end
end
