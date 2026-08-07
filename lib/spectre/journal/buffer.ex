defmodule Spectre.Journal.Buffer do
  @moduledoc """
  Bounded asynchronous delivery queue for observational journal writes.

  Deliveries are serialized within a partition and may run concurrently across
  partitions. Recorder partitions are keyed by store module, so a slow store
  cannot head-of-line block an unrelated store. The global queue and worker
  bound prevent failed stores from creating unbounded tasks.
  """

  use GenServer

  @type enqueue_option ::
          {:buffer_size, pos_integer()}
          | {:overflow, :drop_newest | :drop_oldest}
          | {:partition, term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Adds a zero-arity delivery function to the bounded queue.
  """
  @spec enqueue((-> term()), [enqueue_option()]) ::
          :ok | {:ok, :dropped_oldest} | {:error, term()}
  def enqueue(delivery, opts \\ []) when is_function(delivery, 0) do
    enqueue(__MODULE__, delivery, opts)
  end

  @doc false
  @spec enqueue(GenServer.server(), (-> term()), [enqueue_option()]) ::
          :ok | {:ok, :dropped_oldest} | {:error, term()}
  def enqueue(server, delivery, opts) when is_function(delivery, 0) do
    GenServer.call(server, {:enqueue, delivery, opts})
  end

  @doc """
  Returns privacy-safe queue, delivery, drop, and latency counters.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl GenServer
  def init(opts) do
    concurrency = Keyword.get(opts, :concurrency, 8)

    if is_integer(concurrency) and concurrency > 0 do
      {:ok,
       %{
         queue: :queue.new(),
         running: %{},
         concurrency: concurrency,
         stats: %{enqueued: 0, completed: 0, failed: 0, dropped: 0, last_latency_us: 0}
       }}
    else
      {:stop, {:invalid_journal_concurrency, concurrency}}
    end
  end

  @impl GenServer
  def handle_call({:enqueue, delivery, opts}, _from, state) do
    buffer_size = Keyword.get(opts, :buffer_size, 1_000)
    overflow = Keyword.get(opts, :overflow, :drop_newest)
    partition = Keyword.get(opts, :partition, :default)

    case enqueue_delivery(state, delivery, buffer_size, overflow, partition) do
      {:ok, status, state} -> {:reply, status, dispatch(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        queue_depth: :queue.len(state.queue),
        running?: map_size(state.running) > 0,
        running_count: map_size(state.running)
      })

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info({reference, result}, state) when is_reference(reference) do
    case take_running(state, reference) do
      {:ok, running, state} ->
        Process.demonitor(reference, [:flush])
        outcome = if match?({:error, _reason}, result), do: :failed, else: :completed
        {:noreply, state |> record_delivery(running, outcome) |> dispatch()}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case take_running(state, reference) do
      {:ok, running, state} ->
        {:noreply, state |> record_delivery(running, :failed) |> dispatch()}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec enqueue_delivery(map(), (-> term()), pos_integer(), atom(), term()) ::
          {:ok, :ok | {:ok, :dropped_oldest}, map()} | {:error, term(), map()}
  defp enqueue_delivery(state, delivery, buffer_size, overflow, partition)
       when is_integer(buffer_size) and buffer_size > 0 do
    pending = :queue.len(state.queue) + map_size(state.running)

    cond do
      pending < buffer_size ->
        state = increment_stat(state, :enqueued)
        queued = {partition, delivery, System.monotonic_time()}
        {:ok, :ok, %{state | queue: :queue.in(queued, state.queue)}}

      overflow == :drop_oldest and not :queue.is_empty(state.queue) ->
        {{:value, _dropped}, queue} = :queue.out(state.queue)
        state = state |> increment_stat(:enqueued) |> increment_stat(:dropped)
        queued = {partition, delivery, System.monotonic_time()}
        {:ok, {:ok, :dropped_oldest}, %{state | queue: :queue.in(queued, queue)}}

      overflow in [:drop_newest, :drop_oldest] ->
        {:error, :journal_buffer_full, increment_stat(state, :dropped)}

      true ->
        {:error, {:invalid_journal_overflow_policy, overflow}, state}
    end
  end

  defp enqueue_delivery(state, _delivery, buffer_size, _overflow, _partition),
    do: {:error, {:invalid_journal_buffer_size, buffer_size}, state}

  @spec dispatch(map()) :: map()
  defp dispatch(%{running: running, concurrency: concurrency} = state)
       when map_size(running) >= concurrency,
       do: state

  defp dispatch(state) do
    case take_dispatchable(:queue.to_list(state.queue), state.running, []) do
      :none ->
        state

      {:ok, {partition, delivery, enqueued_at}, remaining} ->
        task = Task.Supervisor.async_nolink(Spectre.Journal.TaskSupervisor, delivery)

        running = %{
          reference: task.ref,
          enqueued_at: enqueued_at,
          partition: partition
        }

        state
        |> Map.put(:queue, :queue.from_list(remaining))
        |> put_in([:running, partition], running)
        |> dispatch()
    end
  end

  # Scan without rotating blocked entries. This keeps each partition's FIFO
  # order even when another partition uses the final concurrency slot.
  defp take_dispatchable([], _running, _skipped), do: :none

  defp take_dispatchable([{partition, _delivery, _at} = queued | rest], running, skipped) do
    if Map.has_key?(running, partition) do
      take_dispatchable(rest, running, [queued | skipped])
    else
      {:ok, queued, Enum.reverse(skipped, rest)}
    end
  end

  @spec take_running(map(), reference()) :: {:ok, map(), map()} | :error
  defp take_running(state, reference) do
    case Enum.find(state.running, fn {_partition, running} ->
           running.reference == reference
         end) do
      {partition, running} -> {:ok, running, update_in(state.running, &Map.delete(&1, partition))}
      nil -> :error
    end
  end

  @spec record_delivery(map(), map(), :completed | :failed) :: map()
  defp record_delivery(state, running, outcome) do
    latency =
      running.enqueued_at
      |> then(&(System.monotonic_time() - &1))
      |> System.convert_time_unit(:native, :microsecond)

    state
    |> increment_stat(outcome)
    |> put_in([:stats, :last_latency_us], max(latency, 0))
  end

  @spec increment_stat(map(), atom()) :: map()
  defp increment_stat(state, key) do
    update_in(state, [:stats, key], &((&1 || 0) + 1))
  end
end
