defmodule Spectre.Inference.StreamCapacity do
  @moduledoc false

  use GenServer

  @default_limit 256

  @type reservation_id :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reserve(reservation_id(), pid(), GenServer.server()) ::
          :ok
          | {:error, :stream_node_capacity_exhausted | :stream_capacity_reservation_conflict}
  def reserve(reservation_id, owner \\ self(), server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:reserve, reservation_id, owner})
  end

  @spec transfer(reservation_id(), pid(), GenServer.server()) ::
          :ok | {:error, :unknown_stream_capacity_reservation}
  def transfer(reservation_id, owner, server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:transfer, reservation_id, owner})
  end

  @spec release(reservation_id(), GenServer.server()) :: :ok
  def release(reservation_id, server \\ __MODULE__) do
    GenServer.call(server, {:release, reservation_id})
  end

  @spec replace(reservation_id(), reservation_id(), pid(), GenServer.server()) ::
          :ok
          | {:error, :unknown_stream_capacity_reservation | :stream_capacity_reservation_conflict}
  def replace(current_id, successor_id, owner, server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:replace, current_id, successor_id, owner})
  end

  @spec status(GenServer.server()) :: %{active: non_neg_integer(), limit: pos_integer()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    limit =
      Keyword.get(
        opts,
        :limit,
        Application.get_env(:spectre, :stream_node_capacity, @default_limit)
      )

    if is_integer(limit) and limit > 0 do
      {:ok, %{limit: limit, reservations: %{}, monitors: %{}}}
    else
      {:stop, {:invalid_stream_node_capacity, limit}}
    end
  end

  @impl GenServer
  def handle_call({:reserve, id, owner}, _from, state) do
    case Map.fetch(state.reservations, id) do
      {:ok, %{owner: ^owner}} ->
        {:reply, :ok, state}

      {:ok, %{owner: previous_owner, monitor: monitor}}
      when node(previous_owner) == node() ->
        if Process.alive?(previous_owner) do
          {:reply, {:error, :stream_capacity_reservation_conflict}, state}
        else
          # A restarted Instance can race the monitor's `:DOWN` message. The
          # reservation is safe to reclaim only after the old local owner is
          # observably dead; reservations owned by a live process are never
          # stolen.
          Process.demonitor(monitor, [:flush])

          state =
            state
            |> drop_reservation(id, monitor)
            |> put_reservation(id, owner)

          {:reply, :ok, state}
        end

      {:ok, _different_owner} ->
        {:reply, {:error, :stream_capacity_reservation_conflict}, state}

      :error when map_size(state.reservations) >= state.limit ->
        {:reply, {:error, :stream_node_capacity_exhausted}, state}

      :error ->
        {:reply, :ok, put_reservation(state, id, owner)}
    end
  end

  def handle_call({:transfer, id, owner}, _from, state) do
    case Map.fetch(state.reservations, id) do
      {:ok, reservation} ->
        Process.demonitor(reservation.monitor, [:flush])
        state = drop_reservation(state, id, reservation.monitor)
        {:reply, :ok, put_reservation(state, id, owner)}

      :error ->
        {:reply, {:error, :unknown_stream_capacity_reservation}, state}
    end
  end

  def handle_call({:release, id}, _from, state) do
    case Map.fetch(state.reservations, id) do
      {:ok, reservation} ->
        Process.demonitor(reservation.monitor, [:flush])
        {:reply, :ok, drop_reservation(state, id, reservation.monitor)}

      :error ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:replace, current_id, successor_id, owner}, _from, state) do
    case {Map.fetch(state.reservations, current_id), Map.fetch(state.reservations, successor_id)} do
      {{:ok, reservation}, :error} ->
        Process.demonitor(reservation.monitor, [:flush])

        state =
          state
          |> drop_reservation(current_id, reservation.monitor)
          |> put_reservation(successor_id, owner)

        {:reply, :ok, state}

      {{:ok, %{owner: ^owner}}, {:ok, %{owner: ^owner}}} when current_id == successor_id ->
        # Replacing a reservation with itself is an idempotent ownership
        # assertion; do not allocate a second monitor.
        {:reply, :ok, state}

      {{:ok, _reservation}, {:ok, _successor}} ->
        # Never overwrite an unrelated successor. Doing so would orphan its
        # monitor and let two logical streams consume one capacity slot.
        {:reply, {:error, :stream_capacity_reservation_conflict}, state}

      {:error, _successor} ->
        {:reply, {:error, :unknown_stream_capacity_reservation}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: map_size(state.reservations), limit: state.limit}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {id, monitors} ->
        {:noreply,
         %{state | reservations: Map.delete(state.reservations, id), monitors: monitors}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_reservation(state, id, owner) do
    monitor = Process.monitor(owner)
    reservation = %{owner: owner, monitor: monitor}

    %{
      state
      | reservations: Map.put(state.reservations, id, reservation),
        monitors: Map.put(state.monitors, monitor, id)
    }
  end

  defp drop_reservation(state, id, monitor) do
    %{
      state
      | reservations: Map.delete(state.reservations, id),
        monitors: Map.delete(state.monitors, monitor)
    }
  end
end
