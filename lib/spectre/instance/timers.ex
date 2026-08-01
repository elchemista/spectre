defmodule Spectre.Instance.Timers do
  @moduledoc """
  Operational timer management for `Spectre.Instance`.

  Owns the per-loop wait timers and per-attempt watchdog timers, including
  the generation and fencing-token checks that drop stale firings. Timers
  send canonical `{:spectre, ...}` messages to the calling Instance process,
  so every function must run inside the owner.
  """

  alias Spectre.Instance.Loops
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Loop, as: OperationLoop

  @doc "Schedules the watchdog timeout for one committed loop attempt."
  @spec schedule_attempt_timeout(InstanceState.t(), OperationLoop.t(), map()) ::
          InstanceState.t()
  def schedule_attempt_timeout(%InstanceState{} = data, loop, attempt) do
    data = cancel_attempt_timer(data, attempt.id)

    reference =
      Process.send_after(
        self(),
        {:spectre, :operation_attempt_timeout, loop.id, attempt.id, attempt.fencing_token},
        attempt.timeout
      )

    timer = %{
      ref: reference,
      loop_id: loop.id,
      attempt_id: attempt.id,
      fencing_token: attempt.fencing_token,
      due_at: attempt.started_at + attempt.timeout
    }

    %{
      data
      | operation_attempt_timers: Map.put(data.operation_attempt_timers, attempt.id, timer)
    }
  end

  @doc "Cancels and forgets the watchdog timer for one attempt, if armed."
  @spec cancel_attempt_timer(InstanceState.t(), String.t()) :: InstanceState.t()
  def cancel_attempt_timer(%InstanceState{} = data, attempt_id) do
    case Map.pop(data.operation_attempt_timers, attempt_id) do
      {nil, timers} ->
        %{data | operation_attempt_timers: timers}

      {%{ref: reference}, timers} ->
        if is_reference(reference), do: Process.cancel_timer(reference)
        %{data | operation_attempt_timers: timers}
    end
  end

  @doc "Consumes a watchdog firing when its fences still match a live runner."
  @spec consume_attempt_timer(InstanceState.t(), String.t(), String.t(), term()) ::
          {:ok, map(), InstanceState.t()} | :stale
  def consume_attempt_timer(%InstanceState{} = data, loop_id, attempt_id, fencing_token) do
    with %{loop_id: ^loop_id, fencing_token: ^fencing_token} <-
           Map.get(data.operation_attempt_timers, attempt_id),
         %{attempt_id: ^attempt_id, loop_id: ^loop_id, fencing_token: ^fencing_token} = ownership <-
           Map.get(data.operation_runners, attempt_id) do
      next = %{
        data
        | operation_attempt_timers: Map.delete(data.operation_attempt_timers, attempt_id)
      }

      {:ok, ownership, next}
    else
      _stale -> :stale
    end
  end

  @doc "Arms or clears the wait timer implied by a loop's committed wait state."
  @spec maybe_schedule_wait_timer(InstanceState.t(), OperationLoop.t()) :: InstanceState.t()
  def maybe_schedule_wait_timer(
        %InstanceState{} = data,
        %OperationLoop{status: :waiting, wait: %{kind: kind}} = loop
      )
      when kind in [:timer, :retry] do
    due_at = loop.wait.due_at

    if is_integer(due_at) do
      data = cancel_wait_timer(data, loop.id)
      delay = max(due_at - System.system_time(:millisecond), 0)

      reference =
        Process.send_after(
          self(),
          {:spectre, :operation_timer, loop.id, loop.wait.id, loop.trigger_generation},
          delay
        )

      timer = %{
        ref: reference,
        wait_id: loop.wait.id,
        generation: loop.trigger_generation,
        due_at: due_at
      }

      %{data | operation_timers: Map.put(data.operation_timers, loop.id, timer)}
    else
      data
    end
  end

  def maybe_schedule_wait_timer(%InstanceState{} = data, %OperationLoop{} = loop),
    do: cancel_wait_timer(data, loop.id)

  @doc "Consumes a wait-timer firing when its wait id and generation still match."
  @spec consume_wait_timer(InstanceState.t(), String.t(), String.t(), term()) ::
          {:ok, InstanceState.t()} | :stale
  def consume_wait_timer(%InstanceState{} = data, loop_id, wait_id, generation) do
    case Map.get(data.operation_timers, loop_id) do
      %{wait_id: ^wait_id, generation: ^generation} ->
        {:ok, %{data | operation_timers: Map.delete(data.operation_timers, loop_id)}}

      _stale ->
        :stale
    end
  end

  @doc "Re-arms wait timers for every restored loop after an Instance restart."
  @spec schedule_restored(InstanceState.t()) :: InstanceState.t()
  def schedule_restored(%InstanceState{} = data) do
    Enum.reduce(Loops.all_operation_loops(data), data, fn {loop, _control}, acc ->
      maybe_schedule_wait_timer(acc, loop)
    end)
  end

  defp cancel_wait_timer(data, loop_id) do
    case Map.pop(data.operation_timers, loop_id) do
      {nil, timers} ->
        %{data | operation_timers: timers}

      {%{ref: reference}, timers} ->
        if is_reference(reference), do: Process.cancel_timer(reference)
        %{data | operation_timers: timers}
    end
  end
end
