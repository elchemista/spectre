defmodule Spectre.Bench.Metrics do
  @moduledoc """
  Idle-checkpoint measurements, kept out of the timed proposal path.

  Ledger bytes, process heaps, owned ETS tables and shared binary references
  describe different things. Do not add them as exclusive ownership or mistake
  one checkpoint for peak RAM. See bench/README.md for each CSV column's units.
  """
  alias Spectre.Ledger.{Entry, Reader}

  @doc "Samples a completed fixture; optional forced GC is a separate diagnostic."
  def capture(f, collect_gc? \\ false) do
    process = process(f.server)
    store_process = process(f.store)
    ets_bytes = owned_ets_bytes(f.store)
    # GC is a diagnostic checkpoint, never part of the timed production path.
    if collect_gc?, do: :erlang.garbage_collect(f.server)
    retained = process(f.server)

    ledger = Task.async(fn -> ledger(f) end) |> Task.await(:infinity)

    # The fixture owns this directory; do not couple measurements to a Store's
    # private GenServer state or assume that every backend has a local file.
    physical = if f.store_directory, do: directory_bytes(f.store_directory)

    Map.merge(ledger, %{
      sequencer_bytes: process.memory,
      sequencer_after_gc_bytes: if(collect_gc?, do: retained.memory),
      sequencer_binary_ref_bytes: retained.binary_ref_bytes,
      sequencer_queue: process.message_queue_len,
      sequencer_reductions: process.reductions,
      store_process_bytes: store_process.memory,
      store_ets_bytes: ets_bytes,
      ledger_file_bytes: physical,
      payload_file_bytes: directory_bytes(f.payload_root),
      payload_verify_calls: :counters.get(f.payload_counter, 1),
      vm_bytes: :erlang.memory(:total),
      vm_rss_bytes: rss_bytes()
    })
  end

  def process(pid) do
    values = Process.info(pid, [:memory, :reductions, :message_queue_len, :binary]) |> Map.new()
    # Ref-counted binaries may be shared: this is not exclusive retained RAM.
    bytes = Enum.reduce(values.binary, 0, fn {_ref, size, _refs}, n -> n + size end)
    values |> Map.delete(:binary) |> Map.put(:binary_ref_bytes, bytes)
  end

  def write_csv(path, columns, rows) do
    content = [
      csv_row(columns)
      | Enum.map(rows, fn row -> csv_row(Enum.map(columns, &Map.get(row, &1))) end)
    ]

    File.write!(path, content)
  end

  def percentiles([]), do: %{samples: 0, mean_ms: nil, p50_ms: nil, p95_ms: nil, p99_ms: nil}

  def percentiles(times) do
    sorted = Enum.sort(times)
    at = fn p -> Enum.at(sorted, max(ceil(length(sorted) * p) - 1, 0)) end

    %{
      samples: length(times),
      mean_ms: Enum.sum(times) / length(times),
      p50_ms: at.(0.50),
      p95_ms: at.(0.95),
      p99_ms: at.(0.99)
    }
  end

  defp ledger(f) do
    zero = %{revision: 0, head_digest: Entry.genesis_digest()}
    initial = %{ledger_entries: 0, ledger_batches: 0, ledger_canonical_bytes: 0, events: %{}}

    {:ok, result} =
      Reader.reduce(f.store_config, f.refs.domain, zero, initial, fn batch, stats ->
        next =
          Enum.reduce(batch, stats, fn entry, current ->
            {:ok, encoded} = Entry.encode(entry)
            bytes = byte_size(encoded)
            type = entry.payload["type"]
            event = %{count: 1, bytes: bytes}

            events =
              Map.update(
                current.events,
                type,
                event,
                &%{count: &1.count + 1, bytes: &1.bytes + bytes}
              )

            %{
              current
              | ledger_entries: current.ledger_entries + 1,
                ledger_canonical_bytes: current.ledger_canonical_bytes + bytes,
                events: events
            }
          end)

        {:ok, %{next | ledger_batches: next.ledger_batches + 1}}
      end)

    result
  end

  @doc "Sums all tables owned by the process, without inspecting its private State."
  def owned_ets_bytes(owner) do
    Enum.reduce(:ets.all(), 0, fn table, sum ->
      if :ets.info(table, :owner) == owner,
        do: sum + :ets.info(table, :memory) * :erlang.system_info(:wordsize),
        else: sum
    end)
  end

  defp directory_bytes(root) do
    root
    |> File.ls!()
    |> Enum.reduce(0, fn name, bytes ->
      case File.stat!(Path.join(root, name)) do
        %{type: :regular, size: size} -> bytes + size
        _other -> bytes
      end
    end)
  end

  defp rss_bytes do
    with {:ok, content} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/^VmRSS:\s+(\d+)\s+kB$/m, content),
         do: String.to_integer(kb) * 1_024,
         else: (_ -> nil)
  end

  defp csv_row(values) do
    [
      Enum.map_join(values, ",", fn value ->
        "\"" <> String.replace(to_string(value || ""), "\"", "\"\"") <> "\""
      end),
      "\n"
    ]
  end
end
