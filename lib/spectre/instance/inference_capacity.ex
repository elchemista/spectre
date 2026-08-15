defmodule Spectre.Instance.InferenceCapacity do
  @moduledoc false

  # Stream reservations are process-local leases, not canonical Run state.
  # Keeping their local/node accounting here makes every admission, steer,
  # recovery, and cleanup path use the same translation of capacity errors.

  alias Spectre.Inference.StreamCapacity
  alias Spectre.Instance.State, as: InstanceState

  @doc false
  @spec reserve(InstanceState.t(), String.t(), atom(), pid()) ::
          {:ok, InstanceState.t(), term() | nil} | {:error, term()}
  def reserve(data, run_id, projection, owner \\ self())

  def reserve(%InstanceState{} = data, _run_id, projection, _owner)
      when projection != :stream,
      do: {:ok, data, nil}

  def reserve(%InstanceState{} = data, run_id, :stream, owner)
      when is_binary(run_id) and is_pid(owner) do
    active = map_size(data.stream_sessions) + map_size(data.stream_reservations)

    if active >= data.max_stream_sessions do
      {:error, :stream_capacity_exhausted}
    else
      reservation = {data.ref.key, run_id}

      case StreamCapacity.reserve(reservation, owner, data.stream_capacity) do
        :ok ->
          reservations = Map.put(data.stream_reservations, run_id, reservation)
          {:ok, %{data | stream_reservations: reservations}, reservation}

        {:error, :stream_node_capacity_exhausted} ->
          {:error, :stream_capacity_exhausted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec replace(InstanceState.t(), term(), term(), pid()) :: :ok | {:error, term()}
  def replace(%InstanceState{} = data, current, replacement, owner) when is_pid(owner) do
    StreamCapacity.replace(current, replacement, owner, data.stream_capacity)
  end

  @doc false
  @spec release(InstanceState.t(), String.t()) :: InstanceState.t()
  def release(%InstanceState{} = data, run_id) do
    case Map.pop(data.stream_reservations, run_id) do
      {nil, reservations} ->
        %{data | stream_reservations: reservations}

      {reservation, reservations} ->
        release_reservation(data, reservation)
        %{data | stream_reservations: reservations}
    end
  end

  @doc false
  @spec release_reservation(InstanceState.t(), term()) :: :ok
  def release_reservation(%InstanceState{} = data, reservation) do
    _ = StreamCapacity.release(reservation, data.stream_capacity)
    :ok
  end

  @doc false
  @spec release_all(InstanceState.t()) :: :ok
  def release_all(%InstanceState{} = data) do
    Enum.each(data.stream_reservations, fn {_run_id, reservation} ->
      release_reservation(data, reservation)
    end)

    :ok
  end
end
