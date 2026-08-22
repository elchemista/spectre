defmodule Spectre.Instance.Cleanup do
  @moduledoc false

  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.Owner
  alias Spectre.Instance.State
  alias Spectre.Operation.RunnerSupervisor

  @spec run(State.t()) :: :ok
  def run(%State{} = data) do
    Enum.each(Map.keys(data.workers), &stop_process(&1, :kill))

    Enum.each(data.operation_runners, fn {_attempt_id, ownership} ->
      stop_runner(data.runner_supervisor, ownership)
    end)

    Enum.each(data.stream_sessions, fn {_invocation_id, ownership} ->
      stop_runner(data.runner_supervisor, ownership)
    end)

    safely(fn -> InferenceCapacity.release_all(data) end)

    Enum.each(data.operation_timers, fn {_loop_id, timer} -> cancel_timer(timer.ref) end)

    Enum.each(data.operation_attempt_timers, fn {_attempt_id, timer} ->
      cancel_timer(timer.ref)
    end)

    Enum.each(data.inference_attempt_timers, fn {_invocation_id, timer} ->
      cancel_timer(timer.ref)
    end)

    stop_inflight(data.checkpoint_inflight)
    stop_inflight(data.checkpoint_reconcile_inflight)

    Enum.each(data.receipt_staging, fn {_token, staging} ->
      stop_process(staging.pid, :shutdown)
    end)

    Enum.each(data.receipt_deliveries, fn {_receipt_id, delivery} ->
      stop_process(delivery.pid, :shutdown)
    end)

    Enum.each(data.receipt_retry_timers, fn {_receipt_id, timer} -> cancel_timer(timer) end)

    safely(fn -> Owner.release(data.owner, data.ref, data.owner_lease, data.base_opts) end)
    :ok
  end

  defp stop_runner(supervisor, %{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      safely(fn -> RunnerSupervisor.stop_runner(supervisor, pid) end)
    end
  end

  defp stop_runner(_supervisor, _ownership), do: :ok

  defp stop_inflight(%{pid: pid}) when is_pid(pid), do: stop_process(pid, :shutdown)
  defp stop_inflight(_inflight), do: :ok

  defp stop_process(pid, reason) when is_pid(pid) do
    if Process.alive?(pid), do: safely(fn -> Process.exit(pid, reason) end)
  end

  defp cancel_timer(timer) when is_reference(timer),
    do: safely(fn -> Process.cancel_timer(timer) end)

  defp cancel_timer(_timer), do: :ok

  defp safely(callback) do
    _ = callback.()
    :ok
  catch
    _kind, _reason -> :ok
  end
end
