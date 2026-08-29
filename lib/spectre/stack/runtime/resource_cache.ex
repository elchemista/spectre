defmodule Spectre.Stack.Runtime.ResourceCache do
  @moduledoc false

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  @spec lookup(pid(), term()) :: {:ok, pid()} | :miss
  def lookup(runtime, key) when is_pid(runtime) do
    case :ets.lookup(@table, {runtime, key}) do
      [{{^runtime, ^key}, resource}] when is_pid(resource) ->
        if Process.alive?(runtime) and Process.alive?(resource) do
          {:ok, resource}
        else
          invalidate(runtime, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc false
  @spec put(pid(), term(), pid()) :: :ok
  def put(runtime, key, resource)
      when is_pid(runtime) and is_pid(resource) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:put, runtime, key, resource})
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec clear :: :ok
  def clear do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :clear), else: :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(:ok) do
    _table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    {:ok, %{monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:put, runtime, key, resource}, _from, state) do
    true = :ets.insert(@table, {{runtime, key}, resource})
    {:reply, :ok, rebuild_monitors(state)}
  end

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(@table)
    {:reply, :ok, rebuild_monitors(state)}
  end

  @impl GenServer
  def handle_cast({:invalidate, runtime, key}, state) do
    true = :ets.delete(@table, {runtime, key})
    {:noreply, rebuild_monitors(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, pid, _reason}, %{monitors: monitors} = state) do
    case Map.get(monitors, monitor) do
      {:runtime, ^pid} -> :ets.match_delete(@table, {{pid, :_}, :_})
      {:resource, ^pid} -> :ets.match_delete(@table, {{:_, :_}, pid})
      _unknown -> :ok
    end

    {:noreply, rebuild_monitors(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec invalidate(pid(), term()) :: :ok
  defp invalidate(runtime, key) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:invalidate, runtime, key})
    :ok
  end

  @spec rebuild_monitors(map()) :: map()
  defp rebuild_monitors(state) do
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))

    {runtimes, resources} =
      @table
      |> :ets.tab2list()
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn {{runtime, _key}, resource},
                                                      {runtimes, resources} ->
        {MapSet.put(runtimes, runtime), MapSet.put(resources, resource)}
      end)

    runtime_monitors = Map.new(runtimes, &{Process.monitor(&1), {:runtime, &1}})
    resource_monitors = Map.new(resources, &{Process.monitor(&1), {:resource, &1}})
    %{state | monitors: Map.merge(runtime_monitors, resource_monitors)}
  end
end
