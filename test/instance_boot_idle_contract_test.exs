defmodule SpectreInstanceBootIdleContractTest.BlockingStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:boot_checkpoint_load, self(), ref.key})

    receive do
      {:release_boot_checkpoint_load, key} when key == ref.key -> :not_found
    end
  end
end

defmodule SpectreInstanceBootIdleContractTest.AgentDefinition do
  @moduledoc false

  use Spectre.Agent, id: :instance_boot_idle_contract_agent
end

defmodule SpectreInstanceBootIdleContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance

  alias SpectreInstanceBootIdleContractTest.AgentDefinition
  alias SpectreInstanceBootIdleContractTest.BlockingStore

  test "start_link remains synchronous while checkpoint work runs in a disposable worker" do
    subject = "boot-sync-#{System.unique_integer([:positive])}"
    test_pid = self()

    starter =
      Task.async(fn ->
        result =
          Spectre.summon(
            agent: AgentDefinition,
            subject: subject,
            checkpoint_store: {BlockingStore, test_pid: test_pid}
          )

        send(test_pid, {:boot_start_complete, self(), result})

        receive do
          :release_boot_starter -> result
        end
      end)

    assert_receive {:boot_checkpoint_load, stable_worker, stable_key}, 1_000
    assert Task.yield(starter, 0) == nil
    send(stable_worker, {:release_boot_checkpoint_load, stable_key})

    assert_receive {:boot_checkpoint_load, legacy_worker, legacy_key}, 1_000
    assert Task.yield(starter, 0) == nil
    send(legacy_worker, {:release_boot_checkpoint_load, legacy_key})

    assert_receive {:boot_start_complete, starter_pid, {:ok, instance}}, 1_000
    assert starter_pid == starter.pid
    assert Process.alive?(instance)
    GenServer.stop(instance)
    send(starter.pid, :release_boot_starter)
    assert {:ok, ^instance} = Task.await(starter, 1_000)
  end

  test "a successful boot hibernates once and configured idle hibernation repeats" do
    subject = "boot-hibernate-#{System.unique_integer([:positive])}"

    assert {:ok, instance} =
             Spectre.summon(
               agent: AgentDefinition,
               subject: subject,
               hibernate_after: 10,
               boot_worker_timeout: 1_000
             )

    assert_eventually(fn -> hibernating?(instance) end)
    assert %{ref: ref_key} = Instance.info(instance)
    assert is_binary(ref_key)
    assert_eventually(fn -> hibernating?(instance) end)
    GenServer.stop(instance)
  end

  test "boot and hibernation options fail before serving a message" do
    subject = "boot-options-#{System.unique_integer([:positive])}"

    assert {:error, {:invalid_instance_option, :hibernate_after, -1}} =
             summon_isolated(
               agent: AgentDefinition,
               subject: subject,
               hibernate_after: -1
             )

    assert {:error, {:invalid_instance_option, :boot_concurrency, 0}} =
             summon_isolated(
               agent: AgentDefinition,
               subject: subject,
               boot_concurrency: 0
             )

    assert {:error, {:invalid_instance_option, :boot_worker_timeout, 0}} =
             summon_isolated(
               agent: AgentDefinition,
               subject: subject,
               boot_worker_timeout: 0
             )
  end

  defp hibernating?(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {_module, function, _arity}}
      when function in [:hibernate, :loop_hibernate] ->
        true

      _other ->
        false
    end
  end

  defp summon_isolated(opts) do
    Task.async(fn ->
      Process.flag(:trap_exit, true)
      Spectre.summon(opts)
    end)
    |> Task.await(1_000)
  end

  defp assert_eventually(callback, attempts \\ 100)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(callback, attempts - 1)
    end
  end

  defp assert_eventually(_callback, 0), do: flunk("Instance did not hibernate")
end
