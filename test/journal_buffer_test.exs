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
end
