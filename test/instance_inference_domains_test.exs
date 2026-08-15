defmodule SpectreInstanceInferenceDomainsTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.StreamCapacity
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceControl
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Operation.Control.Command

  test "inference control owns revision, idempotency, and recovery decisions" do
    invocation = struct(Invocation, id: "invocation-one", control_revision: 0)
    control = InferenceControl.new(0)
    cancel = command(:cancel, "cancel-one", payload: %{reason: :host_cancelled})

    assert {:ok, applied} = InferenceControl.apply_cancel(control, cancel)
    assert applied.generation == 1
    assert applied.pending == nil
    assert applied.last_command.status == :applied
    assert :duplicate = InferenceControl.apply_cancel(applied, cancel)

    assert {:error, {:stale_inference_control_revision, 0, 1}} =
             InferenceControl.apply_cancel(applied, command(:cancel, "cancel-stale"))

    pending_control = %{control | pending: command(:steer, "already-pending")}

    assert {:error, {:inference_control_pending, "already-pending"}} =
             InferenceControl.apply_cancel(pending_control, cancel)

    steer = command(:steer, "steer-one", payload: %{input: "replacement"})
    assert {:ok, steering} = InferenceControl.begin_steer(control, steer)
    assert steering.generation == 1
    assert steering.pending.status == :committed

    finished = InferenceControl.finish(steering, Command.applied(steering.pending))
    assert finished.pending == nil
    assert hd(finished.history).id == "steer-one"

    seen_control = %{control | last_command: steer, history: [steer]}

    assert {:error, {:duplicate_inference_control, "steer-one"}} =
             InferenceControl.begin_steer(seen_control, steer)

    assert :accept = InferenceControl.receipt_disposition(nil, invocation, {:ok, :response})

    assert :accept =
             InferenceControl.receipt_disposition(
               applied,
               invocation,
               {:error, {:cancelled, :host_cancelled}}
             )

    assert {:cancel, :control_committed_before_terminal_acceptance} =
             InferenceControl.receipt_disposition(applied, invocation, {:ok, :late})

    assert :stale =
             InferenceControl.receipt_disposition(finished, invocation, {:ok, :late})

    assert :continue = InferenceControl.recover(nil, invocation)

    assert {:error, :missing_inference_control_fence} =
             InferenceControl.recover(nil, %{invocation | control_revision: 1})

    assert {:error, :pending_inference_control_on_recovery} =
             InferenceControl.recover(steering, invocation)

    assert {:cancelled, :host_cancelled} = InferenceControl.recover(applied, invocation)

    missing_reason =
      command(:cancel, "cancel-without-reason")
      |> Command.committed()
      |> Command.applied()

    assert {:error, :missing_recovered_cancel_reason} =
             InferenceControl.recover(%{applied | last_command: missing_reason}, invocation)
  end

  test "inference capacity owns local and node reservations" do
    server = start_supervised!({StreamCapacity, name: nil, limit: 1})

    data = %InstanceState{
      ref: struct(InstanceRef, key: "instance-one"),
      max_stream_sessions: 2,
      stream_capacity: server
    }

    assert {:ok, ^data, nil} = InferenceCapacity.reserve(data, "one-shot", :one_shot)

    assert {:ok, reserved, {"instance-one", "stream-one"} = reservation} =
             InferenceCapacity.reserve(data, "stream-one", :stream)

    assert {:error, :stream_capacity_exhausted} =
             InferenceCapacity.reserve(reserved, "stream-two", :stream)

    assert {:error, :stream_capacity_exhausted} =
             InferenceCapacity.reserve(
               %{reserved | max_stream_sessions: 1},
               "locally-full",
               :stream
             )

    replacement = {"instance-one", "stream-successor"}
    assert :ok = InferenceCapacity.replace(reserved, reservation, replacement, self())

    replaced = %{reserved | stream_reservations: %{"stream-one" => replacement}}
    released = InferenceCapacity.release(replaced, "stream-one")
    assert released.stream_reservations == %{}

    assert released == InferenceCapacity.release(released, "unknown")

    assert {:ok, reserved_again, _reservation} =
             InferenceCapacity.reserve(released, "stream-three", :stream)

    assert :ok = InferenceCapacity.release_all(reserved_again)
    assert %{active: 0} = StreamCapacity.status(server)
  end

  defp command(action, id, opts \\ []) do
    Command.new("inference-one", action,
      id: id,
      payload: Keyword.get(opts, :payload),
      correlation_id: "control-correlation",
      causation_id: "invocation-one",
      base_revision: 0,
      requested_at: 1,
      provenance: %{source: :test}
    )
  end
end
