defmodule Spectre.Instance.RunQueue do
  @moduledoc false

  # Owns the transient, process-local side of Run scheduling. Canonical Run
  # state remains in `Spectre.Instance.Runs`; this module only coordinates the
  # ready queue, live callers, and stream result hand-off.
  #
  # These functions are called by the Instance owner process. In particular,
  # `schedule/1` deliberately sends the next advance message to `self()` so
  # every Run transition still crosses the Instance mailbox boundary.

  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.State, as: InstanceState

  @type entry :: %{required(:run_id) => String.t(), optional(atom()) => term()}

  @doc false
  @spec enqueue(InstanceState.t(), entry(), boolean()) :: InstanceState.t()
  def enqueue(data, entry, priority? \\ false)

  def enqueue(%InstanceState{} = data, %{run_id: run_id} = entry, priority?)
      when is_binary(run_id) and is_boolean(priority?) do
    if MapSet.member?(data.queued, run_id) or active?(data, run_id) do
      data
    else
      put_ready_entry(data, entry, priority?)
    end
  end

  # A closed `{:continue, run}` is the same public call advancing by another
  # mailbox move. Its caller remains registered while the Run returns to the
  # ready queue. Start is intentionally a bounded two-move sequence so another
  # Run cannot normalize against State and then wait behind the first Run's
  # commit.
  @doc false
  @spec enqueue_continuation(InstanceState.t(), entry(), boolean()) :: InstanceState.t()
  def enqueue_continuation(%InstanceState{} = data, %{run_id: run_id} = entry, priority?)
      when is_binary(run_id) and is_boolean(priority?) do
    put_ready_entry(data, entry, priority?)
  end

  @doc false
  @spec schedule(InstanceState.t()) :: InstanceState.t()
  def schedule(%InstanceState{scheduled: true} = data), do: data
  def schedule(%InstanceState{active: active} = data) when not is_nil(active), do: data
  def schedule(%InstanceState{state_lock: lock} = data) when not is_nil(lock), do: data

  def schedule(%InstanceState{} = data) do
    case :queue.peek(data.ready) do
      {:value, run_id} -> schedule_run(data, run_id)
      :empty -> data
    end
  end

  @doc false
  @spec pop(InstanceState.t(), String.t()) ::
          {:ok, entry(), InstanceState.t()} | {:error, atom(), InstanceState.t()}
  def pop(%InstanceState{} = data, expected_run_id) when is_binary(expected_run_id) do
    case :queue.out(data.ready) do
      {{:value, ^expected_run_id}, ready} ->
        entry = Map.fetch!(data.entries, expected_run_id)

        next = %{
          data
          | ready: ready,
            queued: MapSet.delete(data.queued, expected_run_id),
            entries: Map.delete(data.entries, expected_run_id)
        }

        {:ok, entry, next}

      {{:value, _other}, _ready} ->
        {:error, :out_of_order_advance, data}

      {:empty, _ready} ->
        {:error, :empty_ready_queue, data}
    end
  end

  @doc false
  @spec put_caller(InstanceState.t(), String.t(), GenServer.from()) :: InstanceState.t()
  def put_caller(%InstanceState{} = data, run_id, from) when is_binary(run_id) do
    %{data | callers: Map.put_new(data.callers, run_id, from)}
  end

  @doc false
  @spec reply_stream_caller(InstanceState.t(), String.t(), Enumerable.t()) :: InstanceState.t()
  def reply_stream_caller(%InstanceState{} = data, run_id, stream) when is_binary(run_id) do
    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, {:ok, stream})
        %{data | callers: callers}
    end
  end

  @doc false
  @spec reply_caller(InstanceState.t(), String.t(), term()) :: InstanceState.t()
  def reply_caller(%InstanceState{} = data, run_id, reply) when is_binary(run_id) do
    data = data |> notify_stream_result(run_id, reply) |> InferenceCapacity.release(run_id)

    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, reply)
        %{data | callers: callers}
    end
  end

  @doc false
  @spec stream_session(InstanceState.t(), String.t()) :: {String.t(), map()} | nil
  def stream_session(%InstanceState{} = data, run_id) when is_binary(run_id) do
    Enum.find(data.stream_sessions, fn {_invocation_id, ownership} ->
      ownership.run_id == run_id
    end)
  end

  @doc false
  @spec active?(InstanceState.t(), String.t()) :: boolean()
  def active?(%InstanceState{} = data, run_id) when is_binary(run_id) do
    match?(%{run_id: ^run_id}, data.active) or
      MapSet.member?(data.queued, run_id) or
      Map.has_key?(data.callers, run_id) or
      Enum.any?(data.invocations, fn {_id, ownership} -> ownership.run_id == run_id end)
  end

  defp put_ready_entry(data, entry, priority?) do
    ready =
      if priority?,
        do: :queue.in_r(entry.run_id, data.ready),
        else: :queue.in(entry.run_id, data.ready)

    data = %{
      data
      | ready: ready,
        queued: MapSet.put(data.queued, entry.run_id),
        entries: Map.put(data.entries, entry.run_id, entry)
    }

    schedule(data)
  end

  defp schedule_run(data, run_id) do
    send(self(), {:spectre, :advance, run_id})
    %{data | scheduled: true}
  end

  defp notify_stream_result(data, run_id, reply) do
    case stream_session(data, run_id) do
      nil ->
        data

      {invocation_id, ownership} ->
        send(ownership.pid, {:spectre, :stream_result, invocation_id, reply})
        Process.demonitor(ownership.monitor, [:flush])

        %{
          data
          | stream_sessions: Map.delete(data.stream_sessions, invocation_id),
            stream_monitors: Map.delete(data.stream_monitors, ownership.pid)
        }
    end
  end
end
