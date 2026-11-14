defmodule Spectre.Server.GAM.Managed.Store do
  @moduledoc false
  use GenServer
  @behaviour Spectre.Server.Store
  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl Spectre.Server.Store
  def fetch(server, key), do: GenServer.call(server, {:fetch, key})
  @impl Spectre.Server.Store
  def put_new(server, key, value), do: GenServer.call(server, {:put, key, value})
  @impl Spectre.Server.Store
  def compare_and_swap(server, key, revision, value),
    do: GenServer.call(server, {:cas, key, revision, value})

  @impl Spectre.Server.Store
  def delete(server, key, revision), do: GenServer.call(server, {:delete, key, revision})
  @impl true
  def init(_), do: {:ok, %{values: %{}, sequence: 0}}
  @impl true
  def handle_call({:fetch, key}, _, state),
    do: {:reply, Map.get(state.values, key, :not_found), state}

  def handle_call({:put, key, value}, _, state) do
    if Map.has_key?(state.values, key),
      do: {:reply, {:error, :exists}, state},
      else: put(state, key, value)
  end

  def handle_call({:cas, key, revision, value}, _, state) do
    if match?({:ok, %{revision: ^revision}}, Map.get(state.values, key)),
      do: put(state, key, value),
      else: {:reply, {:error, :conflict}, state}
  end

  def handle_call({:delete, key, revision}, _, state) do
    if match?({:ok, %{revision: ^revision}}, Map.get(state.values, key)),
      do: {:reply, :ok, %{state | values: Map.delete(state.values, key)}},
      else: {:reply, {:error, :conflict}, state}
  end

  @spec put(map(), term(), term()) :: {:reply, term(), map()}
  defp put(state, key, value) do
    sequence = state.sequence + 1

    {:reply, {:ok, sequence},
     %{
       state
       | sequence: sequence,
         values: Map.put(state.values, key, {:ok, %{revision: sequence, value: value}})
     }}
  end
end
