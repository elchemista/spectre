defmodule SpectreJournalBufferTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spectre.Journal.Buffer

  test "delivers queued work in insertion order" do
    buffer = start_buffer()
    parent = self()

    assert :ok =
             Buffer.enqueue(
               buffer,
               fn ->
                 send(parent, {:started, self()})

                 receive do
                   :release -> send(parent, :first_delivered)
                 end
               end,
               buffer_size: 2
             )

    assert_receive {:started, worker}

    assert :ok =
             Buffer.enqueue(buffer, fn -> send(parent, :second_delivered) end, buffer_size: 2)

    send(worker, :release)
    assert_receive :first_delivered
    assert_receive :second_delivered
  end

  test "drop_newest rejects work when the configured bound is full" do
    buffer = start_buffer()
    parent = self()

    assert :ok = Buffer.enqueue(buffer, blocking_delivery(parent), buffer_size: 1)
    assert_receive {:started, worker}

    assert {:error, :journal_buffer_full} =
             Buffer.enqueue(buffer, fn -> send(parent, :unexpected) end,
               buffer_size: 1,
               overflow: :drop_newest
             )

    send(worker, :release)
    refute_receive :unexpected
  end

  test "drop_oldest replaces queued work but never interrupts an active append" do
    buffer = start_buffer()
    parent = self()

    assert :ok = Buffer.enqueue(buffer, blocking_delivery(parent), buffer_size: 2)
    assert_receive {:started, worker}

    assert :ok =
             Buffer.enqueue(buffer, fn -> send(parent, :oldest_queued) end, buffer_size: 2)

    assert {:ok, :dropped_oldest} =
             Buffer.enqueue(buffer, fn -> send(parent, :replacement) end,
               buffer_size: 2,
               overflow: :drop_oldest
             )

    send(worker, :release)
    assert_receive :replacement
    refute_receive :oldest_queued
  end

  test "a crashing delivery does not stall later records" do
    buffer = start_buffer()
    parent = self()

    log =
      capture_log(fn ->
        assert :ok = Buffer.enqueue(buffer, fn -> exit(:store_crashed) end, buffer_size: 2)

        assert :ok =
                 Buffer.enqueue(buffer, fn -> send(parent, :delivered_after_crash) end,
                   buffer_size: 2
                 )

        assert_receive :delivered_after_crash
      end)

    assert log =~ "store_crashed"
  end

  test "a blocked partition does not head-of-line block another store" do
    buffer = start_buffer()
    parent = self()

    assert :ok =
             Buffer.enqueue(buffer, blocking_delivery(parent),
               buffer_size: 2,
               partition: :slow_store
             )

    assert_receive {:started, slow_worker}

    assert :ok =
             Buffer.enqueue(
               buffer,
               fn ->
                 send(parent, {:fast_started, self()})

                 receive do
                   :release -> :ok
                 end
               end,
               buffer_size: 2,
               partition: :fast_store
             )

    assert_receive {:fast_started, fast_worker}
    assert %{queue_depth: 0, running_count: 2, running?: true} = Buffer.stats(buffer)

    send(fast_worker, :release)
    send(slow_worker, :release)
  end

  test "filling the final worker slot never reverses FIFO within a blocked partition" do
    buffer = start_buffer()
    parent = self()

    assert :ok =
             Buffer.enqueue(buffer, blocking_delivery(parent),
               buffer_size: 5,
               partition: :a
             )

    assert_receive {:started, a1}

    assert :ok =
             Buffer.enqueue(buffer, blocking_delivery(parent),
               buffer_size: 5,
               partition: :c
             )

    assert_receive {:started, c1}

    a2 = fn ->
      send(parent, {:a2_started, self()})

      receive do
        :release -> :ok
      end
    end

    assert :ok = Buffer.enqueue(buffer, a2, buffer_size: 5, partition: :a)
    assert :ok = Buffer.enqueue(buffer, blocking_delivery(parent), buffer_size: 5, partition: :b)

    assert :ok =
             Buffer.enqueue(buffer, fn -> send(parent, :a3_started) end,
               buffer_size: 5,
               partition: :a
             )

    send(c1, :release)
    assert_receive {:started, b1}

    send(a1, :release)
    assert_receive {:a2_started, a2_worker}
    refute_receive :a3_started, 50

    send(a2_worker, :release)
    assert_receive :a3_started
    send(b1, :release)
  end

  test "reports successful and failed deliveries without poisoning the queue" do
    buffer = start_buffer()
    parent = self()

    assert :ok =
             Buffer.enqueue(
               buffer,
               fn ->
                 send(parent, :successful_delivery)
                 :ok
               end,
               buffer_size: 3
             )

    assert :ok =
             Buffer.enqueue(
               buffer,
               fn ->
                 send(parent, :failed_delivery)
                 {:error, :store_unavailable}
               end,
               buffer_size: 3
             )

    assert_receive :successful_delivery
    assert_receive :failed_delivery

    assert %{completed: 1, failed: 1, queue_depth: 0, running?: false} =
             eventually_stats(buffer, &(&1.completed == 1 and &1.failed == 1))
  end

  test "rejects malformed queue limits and overflow policies while preserving active work" do
    buffer = start_buffer()
    parent = self()

    assert {:error, {:invalid_journal_buffer_size, 0}} =
             Buffer.enqueue(buffer, fn -> :ok end, buffer_size: 0)

    assert :ok = Buffer.enqueue(buffer, blocking_delivery(parent), buffer_size: 1)
    assert_receive {:started, worker}

    assert {:error, {:invalid_journal_overflow_policy, :overwrite}} =
             Buffer.enqueue(buffer, fn -> send(parent, :unexpected) end,
               buffer_size: 1,
               overflow: :overwrite
             )

    assert %{dropped: 0, enqueued: 1, running_count: 1} = Buffer.stats(buffer)
    send(worker, :release)
    refute_receive :unexpected
  end

  test "ignores stale task replies, stale DOWN messages, and unrelated mailbox traffic" do
    buffer = start_buffer()
    initial = Buffer.stats(buffer)
    stale = make_ref()

    send(buffer, {stale, :ok})
    send(buffer, {:DOWN, stale, :process, self(), :stale})
    send(buffer, {:unrelated, :message})

    assert eventually_stats(buffer, &(&1 == initial)) == initial
    assert Process.alive?(buffer)

    assert :ok =
             Buffer.enqueue(buffer, fn -> send(self(), :wrong_process) end, buffer_size: 1)

    assert eventually_stats(buffer, &(&1.completed == 1)).completed == 1
  end

  test "the application-owned default buffer supports the public convenience API" do
    parent = self()

    assert :ok =
             Buffer.enqueue(fn ->
               send(parent, :default_buffer_delivery)
               :ok
             end)

    assert_receive :default_buffer_delivery
  end

  test "the default start_link contract can recreate the application buffer" do
    supervisor = Process.whereis(Spectre.ApplicationSupervisor)
    assert is_pid(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, Buffer)
    refute Process.whereis(Buffer)

    on_exit(fn ->
      if pid = Process.whereis(Buffer) do
        Process.unlink(pid)

        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        catch
          :exit, _reason -> :ok
        end
      end

      case Supervisor.restart_child(supervisor, Buffer) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end)

    assert {:ok, standalone} = Buffer.start_link()
    Process.unlink(standalone)
    assert Process.whereis(Buffer) == standalone
    assert %{queue_depth: 0, running_count: 0} = Buffer.stats()
  end

  defp start_buffer do
    name = Module.concat(__MODULE__, "Buffer#{System.unique_integer([:positive])}")
    start_supervised!({Buffer, name: name})
  end

  defp blocking_delivery(parent) do
    fn ->
      send(parent, {:started, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defp eventually_stats(buffer, predicate, attempts \\ 100)

  defp eventually_stats(buffer, predicate, attempts) when attempts > 0 do
    stats = Buffer.stats(buffer)

    if predicate.(stats) do
      stats
    else
      Process.sleep(10)
      eventually_stats(buffer, predicate, attempts - 1)
    end
  end

  defp eventually_stats(buffer, _predicate, 0), do: Buffer.stats(buffer)
end
