defmodule Spectre.Journal.Buffer do
  @moduledoc """
  Bounded asynchronous delivery queue for observational journal writes.

  One supervised worker drains the queue in insertion order. The bounded queue
  prevents a failing or slow journal store from creating an unbounded number of
  tasks in the host application.
  """

  use GenServer

  @type enqueue_option ::
          {:buffer_size, pos_integer()} | {:overflow, :drop_newest | :drop_oldest}

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

  @impl GenServer
  def init(_opts) do
    {:ok, %{queue: :queue.new(), running: nil}}
  end

  @impl GenServer
  def handle_call({:enqueue, delivery, opts}, _from, state) do
    buffer_size = Keyword.get(opts, :buffer_size, 1_000)
    overflow = Keyword.get(opts, :overflow, :drop_newest)

    case enqueue_delivery(state, delivery, buffer_size, overflow) do
      {:ok, status, state} -> {:reply, status, dispatch(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({reference, _result}, %{running: reference} = state)
      when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, state |> Map.put(:running, nil) |> dispatch()}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{running: reference} = state) do
    {:noreply, state |> Map.put(:running, nil) |> dispatch()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec enqueue_delivery(map(), (-> term()), pos_integer(), atom()) ::
          {:ok, :ok | {:ok, :dropped_oldest}, map()} | {:error, term(), map()}
  defp enqueue_delivery(state, delivery, buffer_size, overflow)
       when is_integer(buffer_size) and buffer_size > 0 do
    pending = :queue.len(state.queue) + if(state.running, do: 1, else: 0)

    cond do
      pending < buffer_size ->
        {:ok, :ok, %{state | queue: :queue.in(delivery, state.queue)}}

      overflow == :drop_oldest and not :queue.is_empty(state.queue) ->
        {{:value, _dropped}, queue} = :queue.out(state.queue)
        {:ok, {:ok, :dropped_oldest}, %{state | queue: :queue.in(delivery, queue)}}

      overflow in [:drop_newest, :drop_oldest] ->
        {:error, :journal_buffer_full, state}

      true ->
        {:error, {:invalid_journal_overflow_policy, overflow}, state}
    end
  end

  defp enqueue_delivery(state, _delivery, buffer_size, _overflow),
    do: {:error, {:invalid_journal_buffer_size, buffer_size}, state}

  @spec dispatch(map()) :: map()
  defp dispatch(%{running: running} = state) when not is_nil(running), do: state

  defp dispatch(state) do
    case :queue.out(state.queue) do
      {{:value, delivery}, queue} ->
        task = Task.Supervisor.async_nolink(Spectre.Journal.TaskSupervisor, delivery)
        %{state | queue: queue, running: task.ref}

      {:empty, _queue} ->
        state
    end
  end
end
