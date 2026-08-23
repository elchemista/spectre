defmodule Spectre.Instance.Boot do
  @moduledoc false

  alias Spectre.Instance.BootCapacity

  @spec run((-> result), keyword()) :: result when result: term()
  def run(callback, opts \\ []) when is_function(callback, 0) do
    server = Keyword.get(opts, :capacity, BootCapacity)
    timeout = Keyword.get(opts, :timeout, :infinity)
    deadline = deadline(timeout)

    case start(callback, server, timeout) do
      {:ok, ref, _pid} -> await(ref, remaining(deadline), timeout, server)
      {:error, :boot_task_start_timeout} -> exit({:instance_boot_worker_timeout, timeout})
      {:error, reason} -> {:error, reason}
    end
  end

  @spec map(Enumerable.t(), (term() -> term()), keyword()) :: [term()]
  def map(entries, callback, opts \\ []) when is_function(callback, 1) do
    concurrency = Keyword.get(opts, :max_concurrency, 1)
    timeout = Keyword.get(opts, :timeout, :infinity)
    server = Keyword.get(opts, :capacity, BootCapacity)

    entries
    |> Enum.with_index()
    |> :queue.from_list()
    |> collect(%{}, %{}, concurrency, timeout, server, callback)
    |> ordered_values()
  end

  defp collect(queue, pending, outcomes, concurrency, timeout, server, callback) do
    {queue, pending, outcomes} =
      fill(queue, pending, outcomes, concurrency, timeout, server, callback)

    cond do
      map_size(pending) == 0 and :queue.is_empty(queue) ->
        outcomes

      map_size(pending) == 0 ->
        collect(queue, pending, outcomes, concurrency, timeout, server, callback)

      true ->
        receive_outcome(queue, pending, outcomes, concurrency, timeout, server, callback)
    end
  end

  defp fill(queue, pending, outcomes, concurrency, timeout, server, callback)
       when map_size(pending) < concurrency do
    case :queue.out(queue) do
      {{:value, {entry, index}}, queue} ->
        fill_entry(
          {entry, index},
          queue,
          pending,
          outcomes,
          concurrency,
          timeout,
          server,
          callback
        )

      {:empty, queue} ->
        {queue, pending, outcomes}
    end
  end

  defp fill(queue, pending, outcomes, _concurrency, _timeout, _server, _callback),
    do: {queue, pending, outcomes}

  defp fill_entry(
         {entry, index},
         queue,
         pending,
         outcomes,
         concurrency,
         timeout,
         server,
         callback
       ) do
    deadline = deadline(timeout)

    case start(fn -> callback.(entry) end, server, timeout) do
      {:ok, ref, _pid} ->
        fill(
          queue,
          Map.put(pending, ref, %{deadline: deadline, index: index}),
          outcomes,
          concurrency,
          timeout,
          server,
          callback
        )

      {:error, :boot_task_start_timeout} ->
        cancel_pending(pending, server)
        exit({:instance_boot_worker_timeout, timeout})

      {:error, reason} ->
        {queue, pending, Map.put(outcomes, index, {:return, {:error, reason}})}
    end
  end

  defp receive_outcome(queue, pending, outcomes, concurrency, :infinity, server, callback) do
    receive do
      {:spectre_instance_boot, ref, outcome} when is_map_key(pending, ref) ->
        index = pending |> Map.fetch!(ref) |> Map.fetch!(:index)

        collect(
          queue,
          Map.delete(pending, ref),
          Map.put(outcomes, index, outcome),
          concurrency,
          :infinity,
          server,
          callback
        )
    end
  end

  defp receive_outcome(queue, pending, outcomes, concurrency, timeout, server, callback) do
    wait = pending_timeout(pending)

    receive do
      {:spectre_instance_boot, ref, outcome} when is_map_key(pending, ref) ->
        index = pending |> Map.fetch!(ref) |> Map.fetch!(:index)

        collect(
          queue,
          Map.delete(pending, ref),
          Map.put(outcomes, index, outcome),
          concurrency,
          timeout,
          server,
          callback
        )
    after
      wait ->
        cancel_pending(pending, server)
        exit({:instance_boot_worker_timeout, timeout})
    end
  end

  defp ordered_values(outcomes) do
    outcomes
    |> Enum.sort_by(&elem(&1, 0))
    |> ordered_values([])
  end

  defp ordered_values([], values), do: Enum.reverse(values)

  defp ordered_values([{_index, {:return, {:error, _reason} = error}} | _rest], values),
    do: Enum.reverse([error | values])

  defp ordered_values([{_index, {:return, value}} | rest], values),
    do: ordered_values(rest, [value | values])

  defp ordered_values([{_index, {:raise, kind, reason, stacktrace}} | _rest], _values),
    do: :erlang.raise(kind, reason, stacktrace)

  defp ordered_values([{_index, {:worker_exit, reason}} | _rest], _values),
    do: exit({:instance_boot_worker_exit, reason})

  defp await(ref, :infinity, _configured_timeout, _server) do
    receive do
      {:spectre_instance_boot, ^ref, outcome} -> replay(outcome)
    end
  end

  defp await(ref, timeout, configured_timeout, server)
       when is_integer(timeout) and timeout > 0 do
    receive do
      {:spectre_instance_boot, ^ref, outcome} -> replay(outcome)
    after
      timeout ->
        :ok = BootCapacity.cancel(ref, server)
        exit({:instance_boot_worker_timeout, configured_timeout})
    end
  end

  defp await(ref, 0, configured_timeout, server) do
    :ok = BootCapacity.cancel(ref, server)
    exit({:instance_boot_worker_timeout, configured_timeout})
  end

  defp replay({:return, value}), do: value

  defp replay({:raise, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp replay({:worker_exit, reason}), do: exit({:instance_boot_worker_exit, reason})

  defp start(callback, server, timeout) do
    BootCapacity.start(callback, server, timeout)
  catch
    :exit, reason -> {:error, {:instance_boot_capacity_unavailable, reason}}
  end

  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout) and timeout > 0,
    do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp pending_timeout(pending) do
    pending
    |> Map.values()
    |> Enum.map(&remaining(&1.deadline))
    |> Enum.min()
  end

  defp cancel_pending(pending, server),
    do: Enum.each(Map.keys(pending), &BootCapacity.cancel(&1, server))
end
