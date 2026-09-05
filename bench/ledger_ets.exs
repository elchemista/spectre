# Run with: mix run bench/ledger_ets.exs
# Isolates adapter costs; this is not an end-to-end Domain/P1 benchmark.
defmodule Spectre.Bench.LedgerETS do
  alias Spectre.Ledger.Store
  alias Spectre.Ledger.Store.ETS

  def run do
    IO.inspect(%{otp: System.otp_release(), elixir: System.version()}, label: "runtime")
    # Load modules/JIT before collecting the reported samples.
    measure(10, false)
    for compressed <- [false, true], size <- [100, 1_000, 5_000], do: measure(size, compressed)
  end

  defp measure(history_size, compressed) do
    {:ok, server} = ETS.start_link(compressed: compressed)
    store = {ETS, server: server}

    try do
      Enum.each(1..history_size, &append!(store, &1))
      :erlang.garbage_collect(server)
      before = reductions(server)

      lookup =
        timings(200, fn _ ->
          {:ok, _} = Store.lookup_batch(store, "domain", "batch:1", [])
        end)

      lookup_reductions = reductions(server) - before
      before = reductions(server)
      append = timings(100, fn index -> append!(store, history_size + index) end)
      append_reductions = reductions(server) - before
      {:memory, heap_before_gc} = Process.info(server, :memory)
      :erlang.garbage_collect(server)
      {:memory, heap_after_gc} = Process.info(server, :memory)
      %{table: table} = :sys.get_state(server)
      before = reductions(server)
      {export_us, {:ok, _export}} = :timer.tc(fn -> Store.export(store, "domain", []) end)
      export_reductions = reductions(server) - before

      IO.inspect(%{
        compressed: compressed,
        history_entries: history_size,
        lookup_us: percentiles(lookup),
        append_us: percentiles(append),
        lookup_reductions_per_op: div(lookup_reductions, 200),
        append_reductions_per_op: div(append_reductions, 100),
        owner_bytes_before_gc: heap_before_gc,
        owner_bytes_after_gc: heap_after_gc,
        export_us: export_us,
        export_owner_reductions: export_reductions,
        ets_bytes: :ets.info(table, :memory) * :erlang.system_info(:wordsize)
      })
    after
      GenServer.stop(server)
    end
  end

  defp append!(store, revision) do
    {:ok, ^revision} =
      Store.append(
        store,
        "domain",
        "batch:#{revision}",
        [%{"sequence" => revision}],
        revision - 1,
        recorded_at: revision
      )
  end

  defp timings(count, operation) do
    Enum.map(1..count, fn index ->
      {elapsed, _} = :timer.tc(fn -> operation.(index) end)
      elapsed
    end)
  end

  defp percentiles(values) do
    sorted = Enum.sort(values)
    Map.new([50, 95, 99], fn p -> {p, Enum.at(sorted, ceil(length(sorted) * p / 100) - 1)} end)
  end

  defp reductions(server) do
    {:reductions, count} = Process.info(server, :reductions)
    count
  end
end

Spectre.Bench.LedgerETS.run()
