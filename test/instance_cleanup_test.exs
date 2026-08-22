defmodule SpectreInstanceCleanupTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Cleanup
  alias Spectre.Instance.State

  test "cleanup releases every owned boot resource and tolerates partial state" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    staging = spawn(fn -> Process.sleep(:infinity) end)
    delivery = spawn(fn -> Process.sleep(:infinity) end)

    worker_monitor = Process.monitor(worker)
    staging_monitor = Process.monitor(staging)
    delivery_monitor = Process.monitor(delivery)
    attempt_timer = Process.send_after(self(), :stale_attempt_timer, 60_000)
    inference_timer = Process.send_after(self(), :stale_inference_timer, 60_000)

    data = %State{
      workers: %{worker => %{}},
      operation_runners: %{"partial" => %{}},
      operation_attempt_timers: %{"attempt" => %{ref: attempt_timer}},
      inference_attempt_timers: %{"inference" => %{ref: inference_timer}},
      receipt_staging: %{"staging" => %{pid: staging}},
      receipt_deliveries: %{"delivery" => %{pid: delivery}},
      receipt_retry_timers: %{"invalid" => :not_a_timer},
      owner: nil,
      ref: nil,
      owner_lease: nil,
      base_opts: []
    }

    assert :ok = Cleanup.run(data)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^staging_monitor, :process, ^staging, :shutdown}, 1_000
    assert_receive {:DOWN, ^delivery_monitor, :process, ^delivery, :shutdown}, 1_000
    assert Process.read_timer(attempt_timer) == false
    assert Process.read_timer(inference_timer) == false
    refute_receive :stale_attempt_timer
    refute_receive :stale_inference_timer
  end
end
