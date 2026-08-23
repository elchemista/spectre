defmodule SpectreInstanceCleanupTest.Owner do
  @moduledoc false
  @behaviour Spectre.Instance.Owner

  @impl true
  def claim(_ref, _opts), do: {:error, :unused}

  @impl true
  def validate(_ref, _lease, _opts), do: :ok

  @impl true
  def release(ref, lease, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:owner_released, ref, lease})
    :ok
  end
end

defmodule SpectreInstanceCleanupTest.AgentDefinition do
  @moduledoc false
  use Spectre.Agent, id: :instance_cleanup_test_agent
end

defmodule SpectreInstanceCleanupTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Cleanup
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref
  alias Spectre.Instance.State
  alias Spectre.Inference.StreamCapacity

  alias SpectreInstanceCleanupTest.AgentDefinition
  alias SpectreInstanceCleanupTest.Owner

  test "cleanup releases every owned boot resource and tolerates partial state" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    staging = spawn(fn -> Process.sleep(:infinity) end)
    delivery = spawn(fn -> Process.sleep(:infinity) end)

    worker_monitor = Process.monitor(worker)
    staging_monitor = Process.monitor(staging)
    delivery_monitor = Process.monitor(delivery)
    attempt_timer = Process.send_after(self(), :stale_attempt_timer, 60_000)
    inference_timer = Process.send_after(self(), :stale_inference_timer, 60_000)
    ref = Ref.new(AgentDefinition, "cleanup-owned-resources")
    lease = Lease.new!(owner_id: "cleanup-owner", fencing_token: 1, issued_at: 0)
    reservation = {ref.key, "stream-run"}
    capacity = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      Supervisor.child_spec({StreamCapacity, name: capacity, limit: 1},
        id: {:cleanup_stream_capacity, make_ref()}
      )
    )

    assert :ok = StreamCapacity.reserve(reservation, self(), capacity)
    assert StreamCapacity.status(capacity).active == 1

    test_pid = self()

    capacity_proxy =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:release, ^reservation}} ->
            reply = StreamCapacity.release(reservation, capacity)
            send(test_pid, {:inference_capacity_released, reservation})
            GenServer.reply(from, reply)
        end
      end)

    data = %State{
      workers: %{worker => %{}},
      operation_runners: %{"partial" => %{}},
      operation_attempt_timers: %{"attempt" => %{ref: attempt_timer}},
      inference_attempt_timers: %{"inference" => %{ref: inference_timer}},
      receipt_staging: %{"staging" => %{pid: staging}},
      receipt_deliveries: %{"delivery" => %{pid: delivery}},
      receipt_retry_timers: %{"invalid" => :not_a_timer},
      stream_capacity: capacity_proxy,
      stream_reservations: %{"stream-run" => reservation},
      owner: {Owner, test_pid: self()},
      ref: ref,
      owner_lease: lease,
      base_opts: []
    }

    assert :ok = Cleanup.run(data)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^staging_monitor, :process, ^staging, :shutdown}, 1_000
    assert_receive {:DOWN, ^delivery_monitor, :process, ^delivery, :shutdown}, 1_000
    assert Process.read_timer(attempt_timer) == false
    assert Process.read_timer(inference_timer) == false
    assert_receive {:inference_capacity_released, ^reservation}, 1_000
    assert StreamCapacity.status(capacity).active == 0
    assert_receive {:owner_released, ^ref, ^lease}, 1_000
    refute_receive :stale_attempt_timer
    refute_receive :stale_inference_timer
  end
end
