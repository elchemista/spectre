Code.require_file("support/p1_fixture.exs", __DIR__)

defmodule Spectre.Bench.P1 do
  @moduledoc false

  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.Sequencer

  @switches [
    stores: :string,
    modes: :string,
    proponents: :string,
    samples: :integer,
    warmup_samples: :integer,
    group_batch_size: :integer,
    group_wait_ms: :integer,
    stream_segments: :integer
  ]

  def run(argv) do
    opts = options!(argv)
    environment = environment()

    IO.puts("Spectre P1 governed-ledger benchmark")
    IO.puts("environment=#{inspect(environment)}")
    IO.puts("options=#{inspect(opts, charlists: :as_lists)}")
    print_result_header()

    results =
      for store <- opts.stores,
          mode <- opts.modes,
          proponents <- opts.proponents do
        result = benchmark(store, mode, proponents, opts)
        print_result_row(result)
        result
      end

    print_append_profiles(results)
    print_plateaus(results)
    print_stream_floor(opts)
  end

  defp benchmark(store, mode, proponents, opts) do
    {batch_size, wait_ms} = batch_config(mode, proponents, opts)

    Enum.each(sample_ordinals(opts.warmup_samples), fn sample ->
      run_benchmark_sample(store, mode, proponents, {:warmup, sample}, batch_size, wait_ms)
    end)

    samples =
      for sample <- sample_ordinals(opts.samples) do
        run_benchmark_sample(store, mode, proponents, {:measured, sample}, batch_size, wait_ms)
      end

    aggregate(store, mode, proponents, batch_size, wait_ms, samples)
  end

  defp run_benchmark_sample(store, mode, proponents, sample, batch_size, wait_ms) do
    namespace =
      Enum.join(
        [
          store,
          mode,
          proponents,
          elem(sample, 0),
          elem(sample, 1),
          System.unique_integer([:positive])
        ],
        "-"
      )

    fixture = Fixture.start(store, namespace, proponents + 16, batch_size, wait_ms)

    try do
      run_sample(fixture, proponents)
    after
      if Process.alive?(fixture.server), do: Fixture.stop(fixture)
    end
  end

  defp run_sample(fixture, proponents) do
    before = snapshot!(fixture)
    parent = self()

    tasks =
      for sequence <- 1..proponents do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> run_cycle(fixture, sequence)
          end
        end)
      end

    Enum.each(tasks, fn _task ->
      receive do
        {:ready, _pid} -> :ok
      end
    end)

    started_at = monotonic_us()
    Enum.each(tasks, &send(&1.pid, :go))
    cycles = Task.await_many(tasks, :infinity)
    finished_at = monotonic_us()

    after_work = snapshot!(fixture)
    append_counts = append_counts(after_work.entries, before.revision)

    recovery_started_at = monotonic_us()
    restarted = Fixture.restart(fixture)
    recovered_at = monotonic_us()
    recovered = Sequencer.projection(restarted)

    unless recovered.revision == after_work.revision and
             map_size(recovered.acts) >= proponents and
             map_size(recovered.attempts) >= proponents do
      raise "recovery did not reconstruct the completed workload"
    end

    Fixture.stop(fixture, restarted)

    %{
      cycles: cycles,
      wall_us: finished_at - started_at,
      admission_us: max_timestamp(cycles, :act_at) - started_at,
      attempt_us: max_timestamp(cycles, :attempt_at) - started_at,
      recovery_us: recovered_at - recovery_started_at,
      append_counts: append_counts
    }
  end

  defp run_cycle(fixture, sequence) do
    started_at = monotonic_us()
    candidate = Fixture.candidate(fixture, sequence)

    admission =
      fixture.server
      |> Sequencer.submit(fixture.context, candidate)
      |> ok!(:admission)

    act_at = monotonic_us()
    %{act: act, grant: grant} = admission
    {^act, attempt, _receipt} = fixture.server |> Sequencer.consume_grant(grant) |> ok!(:attempt)
    attempt_at = monotonic_us()

    evidence = Fixture.outcome_evidence(fixture, act, attempt)

    [^evidence] =
      fixture.server
      |> Sequencer.record_executor_evidence(act.ref, attempt.ref, evidence)
      |> ok!(:executor_evidence)

    outcome = Fixture.outcome(act, attempt, evidence)
    ^outcome = fixture.server |> Sequencer.record_outcome(outcome) |> ok!(:outcome)
    finished_at = monotonic_us()

    %{
      started_at: started_at,
      act_at: act_at,
      attempt_at: attempt_at,
      finished_at: finished_at,
      candidate_to_act_us: act_at - started_at,
      candidate_to_attempt_us: attempt_at - started_at
    }
  end

  defp aggregate(store, mode, proponents, batch_size, batch_wait_ms, samples) do
    cycles = Enum.flat_map(samples, & &1.cycles)
    total = proponents * length(samples)

    %{
      store: store,
      mode: mode,
      proponents: proponents,
      samples: length(samples),
      batch_size: batch_size,
      batch_wait_ms: batch_wait_ms,
      admission_per_second: rate(total, Enum.sum(Enum.map(samples, & &1.admission_us))),
      attempt_per_second: rate(total, Enum.sum(Enum.map(samples, & &1.attempt_us))),
      cycles_per_second: rate(total, Enum.sum(Enum.map(samples, & &1.wall_us))),
      act_latency: percentiles(cycles, :candidate_to_act_us),
      attempt_latency: percentiles(cycles, :candidate_to_attempt_us),
      recovery_ms: mean(Enum.map(samples, fn sample -> sample.recovery_us / 1_000 end)),
      appends: merge_append_counts(samples, total)
    }
  end

  defp append_counts(entries, after_revision) do
    entries
    |> Enum.filter(&(&1.revision > after_revision))
    |> Enum.group_by(& &1.batch_id)
    |> Enum.reduce(%{}, fn {_batch_id, batch_entries}, counts ->
      class = batch_class(batch_entries)
      logical_units = batch_units(class, batch_entries)

      Map.update(
        counts,
        class,
        %{appends: 1, entries: length(batch_entries), logical_units: logical_units},
        fn current ->
          %{
            appends: current.appends + 1,
            entries: current.entries + length(batch_entries),
            logical_units: current.logical_units + logical_units
          }
        end
      )
    end)
  end

  defp batch_class(entries) do
    types = MapSet.new(entries, & &1.payload["type"])

    cond do
      MapSet.member?(types, "decision_recorded") -> :admission
      MapSet.member?(types, "attempt_started") -> :attempt
      MapSet.member?(types, "outcome_recorded") -> :outcome
      MapSet.member?(types, "evidence_recorded") -> :executor_evidence
      true -> :other
    end
  end

  defp batch_units(:admission, entries), do: count_type(entries, "decision_recorded")
  defp batch_units(:attempt, entries), do: count_type(entries, "attempt_started")
  defp batch_units(:executor_evidence, entries), do: count_type(entries, "evidence_recorded")
  defp batch_units(:outcome, entries), do: count_type(entries, "outcome_recorded")
  defp batch_units(:other, entries), do: length(entries)

  defp count_type(entries, type), do: Enum.count(entries, &(&1.payload["type"] == type))

  defp merge_append_counts(samples, total) do
    samples
    |> Enum.flat_map(&Map.to_list(&1.append_counts))
    |> Enum.reduce(%{}, fn {class, count}, merged ->
      Map.update(merged, class, count, fn current ->
        %{
          appends: current.appends + count.appends,
          entries: current.entries + count.entries,
          logical_units: current.logical_units + count.logical_units
        }
      end)
    end)
    |> Map.new(fn {class, counts} ->
      {class,
       %{
         total: counts.appends,
         per_cycle: counts.appends / total,
         mean_batch_entries: counts.entries / counts.appends,
         mean_batch_units: counts.logical_units / counts.appends
       }}
    end)
  end

  defp print_result_header do
    IO.puts("")

    IO.puts(
      "store mode proponents samples admission/s attempt/s cycles/s " <>
        "act_p50_ms act_p95_ms act_p99_ms attempt_p50_ms attempt_p95_ms " <>
        "attempt_p99_ms batch_size wait_ms admission_appends/cycle " <>
        "admission_batch_candidates admission_batch_entries recovery_ms"
    )
  end

  defp print_result_row(result) do
    admission = Map.get(result.appends, :admission, zero_append())

    IO.puts(
      Enum.join(
        [
          result.store,
          result.mode,
          result.proponents,
          result.samples,
          number(result.admission_per_second),
          number(result.attempt_per_second),
          number(result.cycles_per_second),
          number(result.act_latency.p50),
          number(result.act_latency.p95),
          number(result.act_latency.p99),
          number(result.attempt_latency.p50),
          number(result.attempt_latency.p95),
          number(result.attempt_latency.p99),
          result.batch_size,
          result.batch_wait_ms,
          number(admission.per_cycle),
          number(admission.mean_batch_units),
          number(admission.mean_batch_entries),
          number(result.recovery_ms)
        ],
        " "
      )
    )
  end

  defp print_append_profiles(results) do
    IO.puts("")
    IO.puts("append profile (total appends and appends per completed cycle)")

    Enum.each(results, fn result ->
      profile =
        [:admission, :attempt, :executor_evidence, :outcome, :other]
        |> Enum.map_join(" ", fn class ->
          value = Map.get(result.appends, class, zero_append())
          "#{class}=#{value.total}(#{number(value.per_cycle)}/cycle)"
        end)

      IO.puts("#{result.store}/#{result.mode}/#{result.proponents}: #{profile}")
    end)
  end

  defp print_plateaus(results) do
    IO.puts("")
    IO.puts("throughput plateau candidates (first step with <=5% cycle/s improvement)")

    results
    |> Enum.group_by(&{&1.store, &1.mode})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {{store, mode}, group} ->
      ordered = Enum.sort_by(group, & &1.proponents)

      plateau =
        ordered
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find(fn [previous, current] ->
          current.cycles_per_second <= previous.cycles_per_second * 1.05
        end)

      case plateau do
        [_previous, current] -> IO.puts("#{store}/#{mode}: around #{current.proponents}")
        nil -> IO.puts("#{store}/#{mode}: not reached through #{List.last(ordered).proponents}")
      end
    end)
  end

  defp print_stream_floor(%{stream_segments: 0}), do: :ok

  defp print_stream_floor(opts) do
    IO.puts("")
    IO.puts("materially distinct sequential segment floor")

    Enum.each(opts.stores, fn store ->
      namespace = "stream-#{store}-#{System.unique_integer([:positive])}"
      fixture = Fixture.start(store, namespace, opts.stream_segments + 16, 1, 0)

      try do
        started_at = monotonic_us()
        cycles = Enum.map(1..opts.stream_segments, &run_cycle(fixture, &1))
        wall_us = monotonic_us() - started_at

        latency = percentiles(cycles, :candidate_to_attempt_us)

        IO.puts(
          "#{store}: segments=#{opts.stream_segments} segments/s=#{number(rate(opts.stream_segments, wall_us))} " <>
            "candidate_to_attempt_p50_ms=#{number(latency.p50)} " <>
            "p95_ms=#{number(latency.p95)} p99_ms=#{number(latency.p99)}"
        )
      after
        if Process.alive?(fixture.server), do: Fixture.stop(fixture)
      end
    end)
  end

  defp options!(argv) do
    argv = if List.first(argv) == "--", do: tl(argv), else: argv

    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} ->
        %{
          stores: stores!(Keyword.get(parsed, :stores, "ets,disk")),
          modes: modes!(Keyword.get(parsed, :modes, "individual,group")),
          proponents: integers!(Keyword.get(parsed, :proponents, "1,10,100,200")),
          samples: positive!(Keyword.get(parsed, :samples, 1), :samples),
          warmup_samples: non_negative!(Keyword.get(parsed, :warmup_samples, 1), :warmup_samples),
          group_batch_size:
            positive!(Keyword.get(parsed, :group_batch_size, 64), :group_batch_size),
          group_wait_ms: non_negative!(Keyword.get(parsed, :group_wait_ms, 1), :group_wait_ms),
          stream_segments:
            non_negative!(Keyword.get(parsed, :stream_segments, 32), :stream_segments)
        }

      {_parsed, positional, invalid} ->
        raise ArgumentError,
              "invalid arguments: #{inspect(positional ++ invalid)}"
    end
  end

  defp stores!(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn
      "ets" -> :ets
      "disk" -> :disk
      invalid -> raise ArgumentError, "unknown store: #{invalid}"
    end)
    |> Enum.uniq()
    |> case do
      [] -> raise ArgumentError, "at least one store is required"
      stores -> stores
    end
  end

  defp modes!(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn
      "individual" -> :individual
      "group" -> :group
      invalid -> raise ArgumentError, "unknown commit mode: #{invalid}"
    end)
    |> Enum.uniq()
    |> case do
      [] -> raise ArgumentError, "at least one commit mode is required"
      modes -> modes
    end
  end

  defp integers!(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn item ->
      case Integer.parse(item) do
        {integer, ""} -> positive!(integer, :proponents)
        _invalid -> raise ArgumentError, "invalid proponents: #{item}"
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> raise ArgumentError, "at least one proponent count is required"
      proponents -> proponents
    end
  end

  defp positive!(value, _field) when is_integer(value) and value > 0, do: value
  defp positive!(_value, field), do: raise(ArgumentError, "#{field} must be positive")

  defp non_negative!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative!(_value, field),
    do: raise(ArgumentError, "#{field} must be non-negative")

  defp batch_config(:individual, _proponents, _opts), do: {1, 0}

  defp batch_config(:group, proponents, opts),
    do: {min(proponents, opts.group_batch_size), opts.group_wait_ms}

  defp percentiles(values, field) do
    sorted = values |> Enum.map(&(Map.fetch!(&1, field) / 1_000)) |> Enum.sort()

    %{
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99)
    }
  end

  defp percentile([value], _rank), do: value

  defp percentile(values, rank) do
    index = max(ceil(length(values) * rank) - 1, 0)
    Enum.at(values, index)
  end

  defp max_timestamp(values, field), do: values |> Enum.map(&Map.fetch!(&1, field)) |> Enum.max()

  defp sample_ordinals(0), do: []
  defp sample_ordinals(count), do: 1..count

  defp environment do
    %{
      elixir: System.version(),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      schedulers: System.schedulers_online(),
      architecture: List.to_string(:erlang.system_info(:system_architecture))
    }
  end

  defp rate(count, duration_us) when duration_us > 0, do: count * 1_000_000 / duration_us
  defp mean(values), do: Enum.sum(values) / length(values)

  defp zero_append do
    %{total: 0, per_cycle: 0.0, mean_batch_entries: 0.0, mean_batch_units: 0.0}
  end

  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp number(value), do: to_string(value)
  defp monotonic_us, do: System.monotonic_time(:microsecond)

  defp snapshot!(fixture) do
    case Spectre.Ledger.load(fixture.store_config, fixture.refs.domain) do
      {:ok, snapshot} -> snapshot
      other -> raise "cannot load benchmark ledger: #{inspect(other)}"
    end
  end

  defp ok!({:ok, value}, _phase), do: value
  defp ok!({:ok, first, second, third}, _phase), do: {first, second, third}
  defp ok!({:error, reason}, phase), do: raise("#{phase} failed: #{inspect(reason)}")
end

Spectre.Bench.P1.run(System.argv())
