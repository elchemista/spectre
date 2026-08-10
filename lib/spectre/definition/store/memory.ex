defmodule Spectre.Definition.Store.Memory do
  @moduledoc """
  Volatile in-memory reference implementation of `Spectre.Definition.Store`.

  It is appropriate for conformance tests and entirely ephemeral Instances.
  The adapter explicitly reports `:volatile`, so core rejects it when a durable
  Checkpoint Store is configured.
  """

  use GenServer

  @behaviour Spectre.Definition.Store

  @type state :: %{id: term(), entries: %{optional(String.t()) => binary()}}

  @doc "Starts an empty immutable artifact store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {server_opts, init_opts} =
      Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns the number of published artifacts."
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server), do: GenServer.call(server, :count)

  @impl Spectre.Definition.Store
  def identity(opts), do: GenServer.call(server!(opts), :identity)

  @impl Spectre.Definition.Store
  def durability(_opts), do: :volatile

  @impl Spectre.Definition.Store
  def get(key, opts) when is_binary(key), do: GenServer.call(server!(opts), {:get, key})

  @impl Spectre.Definition.Store
  def put(key, encoded, opts) when is_binary(key) and is_binary(encoded),
    do: GenServer.call(server!(opts), {:put, key, encoded})

  @impl GenServer
  def init(opts) do
    {:ok, %{id: Keyword.get(opts, :id, :spectre_definition_memory), entries: %{}}}
  end

  @impl GenServer
  def handle_call(:identity, _from, state), do: {:reply, state.id, state}
  def handle_call(:count, _from, state), do: {:reply, map_size(state.entries), state}

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
      :error ->
        {:reply, {:ok, :created}, put_in(state, [:entries, key], encoded)}

      {:ok, ^encoded} ->
        {:reply, {:ok, :existing}, state}

      {:ok, _different} ->
        {:reply, {:error, {:immutable_conflict, key}}, state}
    end
  end

  @spec server!(keyword()) :: GenServer.server()
  defp server!(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> server
      :error -> raise ArgumentError, "Definition Store Memory requires the :server option"
    end
  end
end
