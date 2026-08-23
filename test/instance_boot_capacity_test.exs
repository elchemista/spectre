defmodule SpectreInstanceBootCapacityTest.AgentDefinition do
  @moduledoc false

  use Spectre.Agent, id: :instance_boot_capacity_agent
end

defmodule SpectreInstanceBootCapacityTest.OneShotCapacity do
  @moduledoc false

  use GenServer

  def start, do: GenServer.start(__MODULE__, :available)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:start, owner, ref, callback}, _from, :available) do
    worker =
      spawn(fn ->
        send(owner, {:spectre_instance_boot, ref, {:return, callback.()}})
      end)

    {:reply, {:ok, ref, worker}, :unavailable}
  end

  def handle_call({:start, _owner, _ref, _callback}, _from, :unavailable) do
    {:reply, {:error, :verification_capacity_unavailable}, :unavailable}
  end
end

defmodule SpectreInstanceBootCapacityTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance.Boot
  alias Spectre.Instance.BootCapacity
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Ref
  alias Spectre.Instance.Restore

  alias SpectreInstanceBootCapacityTest.AgentDefinition
  alias SpectreInstanceBootCapacityTest.OneShotCapacity

  test "boot workers return values and replay the original exception" do
    assert {:ok, 42} = Boot.run(fn -> {:ok, 42} end)

    assert_raise RuntimeError, "boot fixture failed", fn ->
      Boot.run(fn -> raise "boot fixture failed" end)
    end
  end

  test "bounded map preserves input order and the earliest returned error" do
    assert [3, 1, 2] =
             Boot.map(
               [3, 1, 2],
               fn delay ->
                 Process.sleep(delay)
                 delay
               end,
               max_concurrency: 3
             )

    assert [{:error, :first}] =
             Boot.map(
               [:first, :later],
               fn
                 :first -> {:error, :first}
                 :later -> raise "must remain behind the earlier typed error"
               end,
               max_concurrency: 2
             )

    assert [2, 4] =
             Boot.map([1, 2], &(&1 * 2),
               max_concurrency: 2,
               timeout: 1_000
             )

    assert_raise RuntimeError, "single boot failure", fn ->
      Boot.map([:entry], fn _entry -> raise "single boot failure" end)
    end
  end

  test "capacity queues workers and drains them after the active worker exits" do
    capacity = start_capacity(limit: 1)
    test_pid = self()

    {:ok, first_ref, first_worker} =
      BootCapacity.start(
        fn ->
          send(test_pid, {:first_worker_started, self()})

          receive do
            :finish -> :first
          end
        end,
        capacity
      )

    assert_receive {:first_worker_started, ^first_worker}, 1_000

    second_owner =
      spawn(fn ->
        result =
          BootCapacity.start(
            fn ->
              send(test_pid, {:second_worker_started, self()})
              :second
            end,
            capacity
          )

        send(test_pid, {:second_start_result, result})

        receive do
          outcome -> send(test_pid, {:second_owner_outcome, outcome})
        end
      end)

    refute_receive {:second_worker_started, _pid}, 25
    send(first_worker, :finish)

    assert_receive {:spectre_instance_boot, ^first_ref, {:return, :first}}, 1_000
    assert_receive {:second_start_result, {:ok, second_ref, second_worker}}, 1_000
    assert_receive {:second_worker_started, ^second_worker}, 1_000

    assert_receive {:second_owner_outcome,
                    {:spectre_instance_boot, ^second_ref, {:return, :second}}},
                   1_000

    refute Process.alive?(second_owner)
  end

  test "a queued boot is removed when its owner exits" do
    capacity = start_capacity(limit: 1)

    {:ok, first_ref, first_worker} =
      BootCapacity.start(
        fn ->
          receive do
            :finish -> :first
          end
        end,
        capacity
      )

    queued_owner = spawn(fn -> BootCapacity.start(fn -> :never_started end, capacity) end)
    assert wait_until(fn -> queued_count(capacity) == 1 end)

    Process.exit(queued_owner, :kill)
    assert wait_until(fn -> queued_count(capacity) == 0 end)

    send(first_worker, :finish)
    assert_receive {:spectre_instance_boot, ^first_ref, {:return, :first}}, 1_000
    assert :available = Boot.run(fn -> :available end, capacity: capacity)
  end

  test "queued work can be cancelled before it starts" do
    capacity = start_capacity(limit: 1)
    test_pid = self()

    {:ok, first_ref, first_worker} =
      BootCapacity.start(
        fn ->
          receive do
            :finish -> :first
          end
        end,
        capacity
      )

    queued_owner =
      spawn(fn ->
        send(test_pid, {:queued_start_result, BootCapacity.start(fn -> :cancelled end, capacity)})
      end)

    assert wait_until(fn -> queued_count(capacity) == 1 end)
    [entry] = capacity |> :sys.get_state() |> Map.fetch!(:queue) |> :queue.to_list()
    assert :ok = BootCapacity.cancel(entry.ref, capacity)
    assert_receive {:queued_start_result, {:error, :boot_task_cancelled}}, 1_000
    refute Process.alive?(queued_owner)

    capacity_state = :sys.get_state(capacity)
    assert :queue.is_empty(capacity_state.queue)
    assert map_size(capacity_state.monitors) == 2

    send(first_worker, :finish)
    assert_receive {:spectre_instance_boot, ^first_ref, {:return, :first}}, 1_000
  end

  test "queued and stale monitor entries are filtered independently" do
    capacity = start_capacity(limit: 1)
    capacity_pid = :global.whereis_name(elem(capacity, 1))

    {:ok, first_ref, first_worker} =
      BootCapacity.start(
        fn ->
          receive do
            :finish -> :first
          end
        end,
        capacity
      )

    first_owner = spawn(fn -> BootCapacity.start(fn -> :first_queued end, capacity) end)
    second_owner = spawn(fn -> BootCapacity.start(fn -> :second_queued end, capacity) end)

    assert wait_until(fn -> queued_count(capacity) == 2 end)
    assert :ok = BootCapacity.cancel(make_ref(), capacity)
    assert queued_count(capacity) == 2

    Process.exit(first_owner, :kill)
    assert wait_until(fn -> queued_count(capacity) == 1 end)

    stale_monitor = make_ref()
    stale_ref = make_ref()

    :sys.replace_state(capacity_pid, fn state ->
      put_in(state.monitors[stale_monitor], {:task, stale_ref})
    end)

    send(capacity_pid, {:DOWN, stale_monitor, :process, self(), :normal})

    assert wait_until(fn ->
             capacity
             |> :sys.get_state()
             |> Map.fetch!(:monitors)
             |> Map.has_key?(stale_monitor)
             |> Kernel.not()
           end)

    Process.exit(second_owner, :kill)
    assert wait_until(fn -> queued_count(capacity) == 0 end)

    send(first_worker, :finish)
    assert_receive {:spectre_instance_boot, ^first_ref, {:return, :first}}, 1_000
  end

  test "timeouts cancel running workers and release global capacity" do
    capacity = start_capacity(limit: 1)

    timeout =
      Task.async(fn ->
        catch_exit(
          Boot.run(
            fn ->
              receive do
                :finish -> :unreachable
              end
            end,
            capacity: capacity,
            timeout: 25
          )
        )
      end)

    assert {:instance_boot_worker_timeout, 25} = Task.await(timeout, 1_000)
    assert :available = Boot.run(fn -> :available end, capacity: capacity)

    map_timeout =
      Task.async(fn ->
        catch_exit(
          Boot.map(
            [:blocked],
            fn _entry ->
              receive do
                :finish -> :unreachable
              end
            end,
            capacity: capacity,
            timeout: 25
          )
        )
      end)

    assert {:instance_boot_worker_timeout, 25} = Task.await(map_timeout, 1_000)
    assert :available = Boot.run(fn -> :available end, capacity: capacity)
  end

  test "the timeout includes time queued behind global boot capacity" do
    capacity = start_capacity(limit: 1)

    {:ok, first_ref, first_worker} =
      BootCapacity.start(
        fn ->
          receive do
            :finish -> :first
          end
        end,
        capacity
      )

    started_at = System.monotonic_time(:millisecond)

    queued =
      Task.async(fn ->
        catch_exit(Boot.run(fn -> :must_not_start end, capacity: capacity, timeout: 100))
      end)

    assert wait_until(fn -> queued_count(capacity) == 1 end)
    assert {:instance_boot_worker_timeout, 100} = Task.await(queued, 1_000)
    assert System.monotonic_time(:millisecond) - started_at < 500

    capacity_state = :sys.get_state(capacity)
    assert :queue.is_empty(capacity_state.queue)
    assert map_size(capacity_state.monitors) == 2

    queued_map =
      Task.async(fn ->
        catch_exit(
          Boot.map([:queued], fn _entry -> :must_not_start end,
            capacity: capacity,
            timeout: 100
          )
        )
      end)

    assert wait_until(fn -> queued_count(capacity) == 1 end)
    assert {:instance_boot_worker_timeout, 100} = Task.await(queued_map, 1_000)

    capacity_state = :sys.get_state(capacity)
    assert :queue.is_empty(capacity_state.queue)
    assert map_size(capacity_state.monitors) == 2

    send(first_worker, :finish)
    assert_receive {:spectre_instance_boot, ^first_ref, {:return, :first}}, 1_000
    assert :available = Boot.run(fn -> :available end, capacity: capacity)
  end

  test "worker termination and unavailable capacity fail closed" do
    capacity = start_capacity(limit: 1)
    test_pid = self()

    boot =
      Task.async(fn ->
        catch_exit(
          Boot.run(
            fn ->
              send(test_pid, {:killable_boot_worker, self()})

              receive do
                :finish -> :unreachable
              end
            end,
            capacity: capacity
          )
        )
      end)

    assert_receive {:killable_boot_worker, worker}, 1_000
    Process.exit(worker, :kill)
    assert {:instance_boot_worker_exit, :killed} = Task.await(boot, 1_000)

    unavailable = {:global, {__MODULE__, :unavailable, make_ref()}}

    assert {:error, {:instance_boot_capacity_unavailable, _reason}} =
             Boot.run(fn -> :ok end, capacity: unavailable)

    assert [{:error, {:instance_boot_capacity_unavailable, _reason}}] =
             Boot.map([:entry], fn _entry -> :ok end, capacity: unavailable)

    assert :ok = BootCapacity.cancel(make_ref(), unavailable)
  end

  test "retained Run verification preserves a capacity failure as a typed boot error" do
    {:ok, capacity} = OneShotCapacity.start()
    ref = Ref.new(AgentDefinition, "boot-capacity-verification")
    state = %Spectre.State{conversation_id: ref.key}
    opts = [run_id: "retained"]

    {:ok, run} =
      Spectre.Runtime.admit(
        AgentDefinition,
        Spectre.Input.new("retained"),
        state,
        opts,
        opts
      )

    {:ok, checkpoint} = Spectre.Run.checkpoint(run)
    {:ok, canonical} = Canonical.new(%{runs: %{"retained" => checkpoint}})

    assert {:error, :verification_capacity_unavailable} =
             Restore.runs(canonical, nil, nil, [], 1,
               capacity: capacity,
               max_concurrency: 1
             )

    GenServer.stop(capacity)
  end

  test "invalid capacity and unrelated messages are rejected safely" do
    assert {:error, {:already_started, _pid}} = BootCapacity.start_link()

    invalid = {:global, {__MODULE__, :invalid, make_ref()}}
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {:invalid_instance_boot_capacity, 0}} =
             BootCapacity.start_link(name: invalid, limit: 0)

    Process.flag(:trap_exit, previous_trap_exit)

    capacity = start_capacity(limit: 1)
    send(:global.whereis_name(elem(capacity, 1)), :unrelated)
    send(:global.whereis_name(elem(capacity, 1)), {:DOWN, make_ref(), :process, self(), :normal})
    assert :ok = Boot.run(fn -> :ok end, capacity: capacity)

    assert {:ok, ref, _worker} = BootCapacity.start(fn -> :default_capacity end)
    assert_receive {:spectre_instance_boot, ^ref, {:return, :default_capacity}}, 1_000
    assert :ok = BootCapacity.cancel(make_ref())
  end

  test "capacity kills a running worker when its boot owner dies" do
    capacity = start_capacity(limit: 1)

    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, ref, worker} =
          BootCapacity.start(
            fn ->
              send(test_pid, {:boot_worker_started, self()})

              receive do
                :finish -> :ok
              end
            end,
            capacity
          )

        send(test_pid, {:boot_task_started, ref, worker})
        Process.sleep(:infinity)
      end)

    assert_receive {:boot_worker_started, worker}, 1_000
    assert_receive {:boot_task_started, _ref, ^worker}, 1_000

    monitor = Process.monitor(worker)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert :ok = Boot.run(fn -> :ok end, capacity: capacity)
  end

  defp start_capacity(opts) do
    capacity = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      Supervisor.child_spec({BootCapacity, Keyword.merge([name: capacity], opts)},
        id: {:boot_capacity, make_ref()}
      )
    )

    capacity
  end

  defp queued_count(capacity) do
    capacity
    |> :sys.get_state()
    |> Map.fetch!(:queue)
    |> :queue.len()
  end

  defp wait_until(callback, attempts \\ 100)

  defp wait_until(callback, attempts) when attempts > 0 do
    if callback.() do
      true
    else
      Process.sleep(5)
      wait_until(callback, attempts - 1)
    end
  end

  defp wait_until(_callback, 0), do: false
end
