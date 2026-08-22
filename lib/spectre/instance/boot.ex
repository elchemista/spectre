defmodule Spectre.Instance.Boot do
  @moduledoc false

  alias Spectre.Instance.BootCapacity

  @spec run((-> result), keyword()) :: result when result: term()
  def run(callback, opts \\ []) when is_function(callback, 0) do
    server = Keyword.get(opts, :capacity, BootCapacity)
    timeout = Keyword.get(opts, :timeout, :infinity)

    case start(callback, server) do
      {:ok, ref, _pid} -> await(ref, timeout, server)
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
      fill(queue, pending, outcomes, concurrency, server, callback)

    cond do
      map_size(pending) == 0 and :queue.is_empty(queue) ->
        outcomes

      map_size(pending) == 0 ->
        collect(queue, pending, outcomes, concurrency, timeout, server, callback)

      true ->
        receive_outcome(queue, pending, outcomes, concurrency, timeout, server, callback)
    end
  end

  defp fill(queue, pending, outcomes, concurrency, server, callback)
       when map_size(pending) < concurrency do
    case :queue.out(queue) do
      {{:value, {entry, index}}, queue} ->
        fill_entry(entry, index, queue, pending, outcomes, concurrency, server, callback)

      {:empty, queue} ->
        {queue, pending, outcomes}
    end
  end

  defp fill(queue, pending, outcomes, _concurrency, _server, _callback),
    do: {queue, pending, outcomes}

  defp fill_entry(entry, index, queue, pending, outcomes, concurrency, server, callback) do
    case start(fn -> callback.(entry) end, server) do
      {:ok, ref, _pid} ->
        fill(
          queue,
          Map.put(pending, ref, index),
          outcomes,
          concurrency,
          server,
          callback
        )

      {:error, reason} ->
        {queue, pending, Map.put(outcomes, index, {:return, {:error, reason}})}
    end
  end

  defp receive_outcome(queue, pending, outcomes, concurrency, :infinity, server, callback) do
    receive do
      {:spectre_instance_boot, ref, outcome} when is_map_key(pending, ref) ->
        index = Map.fetch!(pending, ref)

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
    receive do
      {:spectre_instance_boot, ref, outcome} when is_map_key(pending, ref) ->
        index = Map.fetch!(pending, ref)

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
      timeout ->
        Enum.each(Map.keys(pending), &BootCapacity.cancel(&1, server))
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

  defp await(ref, :infinity, _server) do
    receive do
      {:spectre_instance_boot, ^ref, outcome} -> replay(outcome)
    end
  end

  defp await(ref, timeout, server) when is_integer(timeout) and timeout > 0 do
    receive do
      {:spectre_instance_boot, ^ref, outcome} -> replay(outcome)
    after
      timeout ->
        :ok = BootCapacity.cancel(ref, server)
        exit({:instance_boot_worker_timeout, timeout})
    end
  end

  defp replay({:return, value}), do: value

  defp replay({:raise, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp replay({:worker_exit, reason}), do: exit({:instance_boot_worker_exit, reason})

  defp start(callback, server) do
    BootCapacity.start(callback, server)
  catch
    :exit, reason -> {:error, {:instance_boot_capacity_unavailable, reason}}
  end
end
