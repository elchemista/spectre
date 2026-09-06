Code.require_file("support/p1_fixture.exs", __DIR__)

defmodule Spectre.Bench.HistoryGrowth do
  @moduledoc false

  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.Sequencer

  # Keep one Domain alive: fresh fixtures per sample hide history-dependent work.
  # Timings include submission, checkout, executor evidence and terminal outcome.
  def run do
    f = Fixture.start(:ets, "growth-#{System.unique_integer([:positive])}", 2_100, 1, 0)

    try do
      IO.puts(
        "cycles,revision,ms_per_cycle,p50_ms,p95_ms,p99_ms,reductions_per_cycle,sequencer_bytes"
      )

      Enum.reduce([10, 50, 100, 150, 200, 500, 1_000, 2_000], 0, fn total, previous ->
        {:reductions, before_reductions} = Process.info(f.server, :reductions)

        times =
          Enum.map((previous + 1)..total, fn sequence ->
            {us, :ok} = :timer.tc(fn -> cycle(f, sequence) end)
            us / 1_000
          end)

        {:memory, memory} = Process.info(f.server, :memory)
        {:reductions, after_reductions} = Process.info(f.server, :reductions)
        {:ok, head} = Sequencer.head(f.server)
        sorted = Enum.sort(times)

        IO.puts(
          Enum.join(
            [
              total,
              head.revision,
              average(times),
              percentile(sorted, 0.5),
              percentile(sorted, 0.95),
              percentile(sorted, 0.99),
              div(after_reductions - before_reductions, total - previous),
              memory
            ],
            ","
          )
        )

        total
      end)

      if "--profile" in System.argv(), do: profile(f)
      if "--compare" in System.argv(), do: compare(f)

      {us, restarted} = :timer.tc(fn -> Fixture.restart(f) end)
      IO.puts("cold_recovery_ms=#{us / 1_000}")
      Fixture.stop(f, restarted)
    after
      if Process.alive?(f.server), do: Fixture.stop(f)
    end
  end

  # Interleave a young and an old Domain in the same VM. A growing-history
  # series alone can confuse history cost with changing machine load.
  defp compare(old) do
    young = Fixture.start(:ets, "control-#{System.unique_integer([:positive])}", 100, 1, 0)

    try do
      Enum.each(1..10, &cycle(young, &1))

      traced =
        if "--gc" in System.argv(), do: [{old.server, :old}, {young.server, :young}], else: []

      for {pid, _label} <- traced do
        :erlang.trace(pid, true, [:garbage_collection, :monotonic_timestamp])
      end

      measurements =
        Enum.reduce(1..64, %{old: [], young: []}, fn n, measurements ->
          pair = [{:old, old, 2_010 + n}, {:young, young, 10 + n}]
          pair = if rem(n, 2) == 0, do: Enum.reverse(pair), else: pair

          Enum.reduce(pair, measurements, fn {label, fixture, sequence}, acc ->
            {us, :ok} = :timer.tc(fn -> cycle(fixture, sequence) end)
            Map.update!(acc, label, &[us / 1_000 | &1])
          end)
        end)

      for label <- [:young, :old] do
        times = Map.fetch!(measurements, label)
        sorted = Enum.sort(times)

        IO.puts(
          "paired_#{label}: mean_ms=#{average(times)}, " <>
            "p50_ms=#{percentile(sorted, 0.5)}, " <>
            "p95_ms=#{percentile(sorted, 0.95)}, p99_ms=#{percentile(sorted, 0.99)}"
        )
      end

      report_gc(traced)
    after
      Fixture.stop(young)
    end
  end

  defp report_gc([]), do: :ok

  defp report_gc(traced) do
    pending =
      MapSet.new(traced, fn {pid, _label} ->
        :erlang.trace(pid, false, [:garbage_collection])
        :erlang.trace_delivered(pid)
      end)

    stats = collect_gc(pending, %{}, %{})

    for {pid, label} <- traced do
      totals = Map.get(stats, pid, %{minor: 0, major: 0, us: 0})

      IO.puts(
        "paired_#{label}_gc: minor=#{totals.minor}, major=#{totals.major}, " <>
          "gc_ms_per_cycle=#{Float.round(totals.us / 64_000, 3)}"
      )
    end
  end

  defp collect_gc(pending, starts, stats) do
    if MapSet.size(pending) == 0 do
      stats
    else
      receive do
        {:trace_ts, pid, event, _info, timestamp}
        when event in [:gc_minor_start, :gc_major_start] ->
          collect_gc(pending, Map.put(starts, pid, timestamp), stats)

        {:trace_ts, pid, event, _info, timestamp}
        when event in [:gc_minor_end, :gc_major_end] ->
          {start, starts} = Map.pop!(starts, pid)
          us = System.convert_time_unit(timestamp - start, :native, :microsecond)
          kind = if event == :gc_minor_end, do: :minor, else: :major
          totals = Map.get(stats, pid, %{minor: 0, major: 0, us: 0})
          totals = totals |> Map.update!(kind, &(&1 + 1)) |> Map.update!(:us, &(&1 + us))
          collect_gc(pending, starts, Map.put(stats, pid, totals))

        {:trace_delivered, _pid, ref} ->
          collect_gc(MapSet.delete(pending, ref), starts, stats)
      after
        5_000 -> raise "GC trace delivery timed out"
      end
    end
  end

  defp profile(f) do
    modules =
      for {mod, _} <- :code.all_loaded(),
          String.starts_with?(Atom.to_string(mod), "Elixir.Spectre."),
          do: mod

    Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, true, [:call_time]))
    :erlang.trace(f.server, true, [:call])
    Enum.each(2_001..2_010, &cycle(f, &1))
    Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, :pause, [:call_time]))
    :erlang.trace(f.server, false, [:call])

    for mod <- modules, {fun, arity} <- mod.module_info(:functions), reduce: [] do
      acc ->
        case :erlang.trace_info({mod, fun, arity}, :call_time) do
          {:call_time, rows} when is_list(rows) ->
            for {pid, calls, seconds, us} <- rows, pid == f.server, reduce: acc do
              acc -> [{seconds * 1_000_000 + us, calls, {mod, fun, arity}} | acc]
            end

          _ ->
            acc
        end
    end
    |> Enum.sort(:desc)
    |> Enum.take(20)
    |> Enum.each(&IO.inspect/1)

    Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, false, [:call_time]))
  end

  defp cycle(f, sequence) do
    {:ok, %{act: act, grant: grant}} =
      Sequencer.submit(f.server, f.context, Fixture.candidate(f, sequence))

    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)
    evidence = Fixture.outcome_evidence(f, act, attempt)

    {:ok, [^evidence]} =
      Sequencer.record_executor_evidence(f.server, act.ref, attempt.ref, evidence)

    outcome = Fixture.outcome(act, attempt, evidence)
    {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    :ok
  end

  defp average(values), do: Float.round(Enum.sum(values) / length(values), 3)

  defp percentile(sorted, p),
    do: sorted |> Enum.at(ceil(length(sorted) * p) - 1) |> Float.round(3)
end

Spectre.Bench.HistoryGrowth.run()
