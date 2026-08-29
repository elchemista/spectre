defmodule SpectreStackRuntimeResourceCacheTest do
  use ExUnit.Case, async: false

  alias Spectre.Stack.Runtime.ResourceCache

  setup do
    ResourceCache.clear()
    on_exit(&ensure_cache_started/0)
    :ok
  end

  test "clear removes every cached resource" do
    runtime = idle_process()
    resource = idle_process()
    on_exit(fn -> stop_processes([runtime, resource]) end)

    assert :ok = ResourceCache.put(runtime, :client, resource)
    assert {:ok, ^resource} = ResourceCache.lookup(runtime, :client)

    assert :ok = ResourceCache.clear()
    assert :miss = ResourceCache.lookup(runtime, :client)
  end

  test "a runtime DOWN invalidates all of its cached resources" do
    runtime = idle_process()
    first_resource = idle_process()
    second_resource = idle_process()
    on_exit(fn -> stop_processes([runtime, first_resource, second_resource]) end)

    assert :ok = ResourceCache.put(runtime, :first, first_resource)
    assert :ok = ResourceCache.put(runtime, :second, second_resource)

    Process.exit(runtime, :kill)

    assert :ok =
             eventually(fn ->
               case {
                 :ets.lookup(ResourceCache, {runtime, :first}),
                 :ets.lookup(ResourceCache, {runtime, :second})
               } do
                 {[], []} -> :ok
                 _entries -> :retry
               end
             end)
  end

  test "unknown monitor and ordinary messages leave the cache alive" do
    cache = Process.whereis(ResourceCache)

    send(cache, {:DOWN, make_ref(), :process, self(), :normal})
    send(cache, :unexpected_message)

    assert %{monitors: %{}} = :sys.get_state(cache)
    assert Process.alive?(cache)
  end

  test "cache operations degrade safely while the application child is stopped" do
    assert :ok =
             Supervisor.terminate_child(Spectre.ApplicationSupervisor, ResourceCache)

    assert Process.whereis(ResourceCache) == nil
    assert :miss = ResourceCache.lookup(self(), :missing)
    assert :ok = ResourceCache.put(self(), :client, self())
    assert :ok = ResourceCache.clear()

    put_cache = failing_cache_process()
    put_monitor = Process.monitor(put_cache)
    assert :ok = ResourceCache.put(self(), :client, self())
    assert_receive {:DOWN, ^put_monitor, :process, ^put_cache, :cache_stopped}

    clear_cache = failing_cache_process()
    clear_monitor = Process.monitor(clear_cache)
    assert :ok = ResourceCache.clear()
    assert_receive {:DOWN, ^clear_monitor, :process, ^clear_cache, :cache_stopped}

    assert {:ok, cache} =
             Supervisor.restart_child(Spectre.ApplicationSupervisor, ResourceCache)

    assert Process.alive?(cache)
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp failing_cache_process do
    process =
      spawn(fn ->
        receive do
          _message -> exit(:cache_stopped)
        end
      end)

    true = Process.register(process, ResourceCache)
    process
  end

  defp stop_processes(processes) do
    Enum.each(processes, fn process ->
      if Process.alive?(process), do: send(process, :stop)
    end)
  end

  defp ensure_cache_started do
    if Process.whereis(ResourceCache) do
      ResourceCache.clear()
    else
      _result = Supervisor.restart_child(Spectre.ApplicationSupervisor, ResourceCache)
      :ok
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      :retry ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")
end
