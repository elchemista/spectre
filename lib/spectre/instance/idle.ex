defmodule Spectre.Instance.Idle do
  @moduledoc false

  # Owns the process-local idle clock used by the Instance owner. The functions
  # in this module must run synchronously inside that owner process: timers are
  # addressed to `self()` and the transient queues they inspect are not
  # canonical state.

  alias Spectre.Instance.Loops
  alias Spectre.Instance.Runs
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Loop, as: OperationLoop

  @doc false
  @spec arm(InstanceState.t()) :: InstanceState.t()
  def arm(%InstanceState{} = data) do
    data = disarm(data)
    generation = data.idle_generation + 1

    timer =
      case data.idle_timeout do
        timeout when is_integer(timeout) and timeout > 0 ->
          if busy?(data) or live_runs?(data),
            do: nil,
            else: Process.send_after(self(), {:idle_shutdown, generation}, timeout)

        _other ->
          nil
      end

    %{data | idle_timer: timer, idle_generation: generation}
  end

  @doc false
  @spec disarm(InstanceState.t()) :: InstanceState.t()
  def disarm(%InstanceState{} = data) do
    if is_reference(data.idle_timer), do: Process.cancel_timer(data.idle_timer)
    %{data | idle_timer: nil}
  end

  @doc false
  @spec busy?(InstanceState.t()) :: boolean()
  def busy?(%InstanceState{} = data) do
    [
      present?(data.active),
      present?(data.state_lock),
      queue_busy?(data.ready),
      map_busy?(data.invocations),
      map_busy?(data.operation_runners),
      queue_busy?(data.operation_ready),
      present?(data.checkpoint_inflight),
      present?(data.checkpoint_reconcile_inflight),
      map_busy?(data.receipt_staging),
      map_busy?(data.receipt_deliveries),
      map_busy?(data.receipt_resumes),
      data.receipt_recovery_deferred,
      map_busy?(data.stream_sessions),
      map_busy?(data.stream_reservations)
    ]
    |> Enum.any?()
  end

  @doc false
  @spec live_runs?(InstanceState.t()) :: boolean()
  def live_runs?(%InstanceState{} = data) do
    Enum.any?(data.runs, fn {_id, run} -> not Runs.terminal_run?(run) end) or
      Enum.any?(Loops.all_operation_loops(data), fn {loop, _control} ->
        not OperationLoop.terminal?(loop)
      end)
  end

  defp present?(value), do: not is_nil(value)
  defp queue_busy?(queue), do: not :queue.is_empty(queue)
  defp map_busy?(map), do: map_size(map) > 0
end
