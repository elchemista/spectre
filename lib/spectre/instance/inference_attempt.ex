defmodule Spectre.Instance.InferenceAttempt do
  @moduledoc false

  # Process-local lifecycle support for one inference attempt. Timer ownership,
  # stream-session notifications, and observer events share the same attempt
  # fences, so keeping them together avoids subtly different cleanup paths.

  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Event
  alias Spectre.Instance.State, as: InstanceState

  @max_timer_delay 4_294_967_295

  @doc false
  @spec arm_timer(InstanceState.t(), map(), BudgetSnapshot.t() | nil) :: InstanceState.t()
  def arm_timer(%InstanceState{} = data, _ownership, nil), do: data

  def arm_timer(
        %InstanceState{} = data,
        _ownership,
        %BudgetSnapshot{deadline_at: nil}
      ),
      do: data

  def arm_timer(
        %InstanceState{} = data,
        ownership,
        %BudgetSnapshot{deadline_at: deadline}
      ) do
    rearm_timer(data, ownership, deadline)
  end

  @doc false
  @spec rearm_timer(InstanceState.t(), map(), non_neg_integer()) :: InstanceState.t()
  def rearm_timer(%InstanceState{} = data, ownership, deadline)
      when is_integer(deadline) and deadline >= 0 do
    data = clear_timer(data, ownership.invocation.id)
    remaining = max(deadline - Spectre.Determinism.system_time(:millisecond), 0)
    delay = min(remaining, @max_timer_delay)

    ref =
      Process.send_after(
        self(),
        {:spectre, :inference_attempt_deadline, ownership.invocation.id, ownership.generation,
         ownership.dispatch_id},
        delay
      )

    timer = %{
      ref: ref,
      deadline_at: deadline,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id
    }

    %{
      data
      | inference_attempt_timers:
          Map.put(data.inference_attempt_timers, ownership.invocation.id, timer)
    }
  end

  @doc false
  @spec clear_timer(InstanceState.t(), String.t()) :: InstanceState.t()
  def clear_timer(%InstanceState{} = data, invocation_id) when is_binary(invocation_id) do
    case Map.pop(data.inference_attempt_timers, invocation_id) do
      {nil, timers} ->
        %{data | inference_attempt_timers: timers}

      {%{ref: ref}, timers} ->
        _cancelled = Process.cancel_timer(ref)
        %{data | inference_attempt_timers: timers}
    end
  end

  @doc false
  @spec notify_committed(InstanceState.t(), String.t(), term()) :: InstanceState.t()
  def notify_committed(%InstanceState{} = data, invocation_id, response)
      when is_binary(invocation_id) do
    notify_session(data, invocation_id, {:stream_attempt_committed, response})
  end

  @doc false
  @spec notify_failed(InstanceState.t(), String.t(), term()) :: InstanceState.t()
  def notify_failed(%InstanceState{} = data, invocation_id, reason)
      when is_binary(invocation_id) do
    notify_session(data, invocation_id, {:stream_attempt_failed, reason})
  end

  @doc false
  @spec publish(
          InstanceState.t(),
          atom(),
          String.t() | nil,
          String.t() | nil,
          map(),
          map()
        ) :: InstanceState.t()
  def publish(%InstanceState{} = data, type, inference_id, invocation_id, attempt, metadata)
      when is_atom(type) and is_map(attempt) and is_map(metadata) do
    if Keyword.get(data.base_opts, :inference_observer_lane, false) and
         is_binary(inference_id) and is_binary(invocation_id) do
      event =
        Event.new(type,
          instance_key: data.ref.key,
          inference_id: inference_id,
          invocation_id: invocation_id,
          attempt_id: Map.get(attempt, :attempt_id),
          stream_epoch: Map.get(attempt, :stream_epoch),
          canonical_revision: data.canonical.revision,
          metadata: metadata
        )

      _ = Spectre.Inference.Events.publish(data.ref, event)
    end

    data
  rescue
    _invalid_observer_projection -> data
  end

  @doc false
  @spec failure_event_type(term()) :: :stream_interrupted | :terminal_committed
  def failure_event_type({:stream_interrupted, _reason}), do: :stream_interrupted

  def failure_event_type({:inference_attempt_failed, _attempt, reason}),
    do: failure_event_type(reason)

  def failure_event_type(_reason), do: :terminal_committed

  defp notify_session(data, invocation_id, {event, payload}) do
    case Map.get(data.stream_sessions, invocation_id) do
      %{pid: pid} ->
        send(pid, {:spectre, event, invocation_id, payload})
        data

      nil ->
        data
    end
  end
end
