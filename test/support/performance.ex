defmodule Spectre.Test.Performance do
  @moduledoc false

  @type sample :: %{
          required(:result) => term(),
          required(:wall_time_us) => non_neg_integer(),
          required(:total_reductions) => non_neg_integer(),
          required(:owner_reductions) => non_neg_integer(),
          required(:memory_bytes) => non_neg_integer(),
          required(:heap_words) => non_neg_integer(),
          required(:total_heap_words) => non_neg_integer(),
          required(:binary_bytes) => non_neg_integer()
        }

  @spec measure_start((-> {:ok, pid()} | {:ok, pid(), term()})) :: sample()
  def measure_start(callback) when is_function(callback, 0) do
    total_before = total_reductions()
    started_at = System.monotonic_time()
    result = callback.()
    wall_time_us = elapsed_us(started_at)
    pid = result_pid!(result)
    _ = :erlang.garbage_collect(pid)
    info = process_info(pid)

    Map.merge(info, %{
      result: result,
      wall_time_us: wall_time_us,
      total_reductions: max(total_reductions() - total_before, 0)
    })
  end

  @spec measure_process(pid(), (-> result)) :: sample() when result: term()
  def measure_process(pid, callback) when is_pid(pid) and is_function(callback, 0) do
    before = process_info(pid)
    total_before = total_reductions()
    started_at = System.monotonic_time()
    result = callback.()
    wall_time_us = elapsed_us(started_at)
    _ = :erlang.garbage_collect(pid)
    after_info = process_info(pid)

    Map.merge(after_info, %{
      result: result,
      wall_time_us: wall_time_us,
      owner_reductions: max(after_info.owner_reductions - before.owner_reductions, 0),
      total_reductions: max(total_reductions() - total_before, 0)
    })
  end

  @spec snapshot(pid()) :: map()
  def snapshot(pid) when is_pid(pid) do
    _ = :erlang.garbage_collect(pid)
    process_info(pid)
  end

  @spec median([number()]) :: number()
  def median(values) when is_list(values) and values != [] do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp process_info(pid) do
    info =
      Process.info(pid, [
        :binary,
        :heap_size,
        :memory,
        :reductions,
        :total_heap_size
      ])

    %{
      binary_bytes: binary_bytes(Keyword.fetch!(info, :binary)),
      heap_words: Keyword.fetch!(info, :heap_size),
      memory_bytes: Keyword.fetch!(info, :memory),
      owner_reductions: Keyword.fetch!(info, :reductions),
      total_heap_words: Keyword.fetch!(info, :total_heap_size)
    }
  end

  defp binary_bytes(binaries) do
    binaries
    |> Enum.map(fn {_reference, bytes, _references} -> bytes end)
    |> Enum.sum()
  end

  defp result_pid!({:ok, pid}) when is_pid(pid), do: pid
  defp result_pid!({:ok, pid, _info}) when is_pid(pid), do: pid

  defp result_pid!(result),
    do: raise(ArgumentError, "start measurement expected a pid result, got: #{inspect(result)}")

  defp total_reductions, do: :erlang.statistics(:reductions) |> elem(0)

  defp elapsed_us(started_at),
    do: System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)
end
