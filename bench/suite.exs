if Mix.env() != :dev, do: raise("Run the benchmark suite with MIX_ENV=dev")
Code.require_file("support/p1_fixture.exs", __DIR__)
Code.require_file("support/workload.exs", __DIR__)
Code.require_file("support/metrics.exs", __DIR__)

defmodule Spectre.Bench.Suite do
  @moduledoc false
  alias Spectre.Bench.{Metrics, Workload}

  @stores %{
    "ets" => :ets,
    "ets_compressed" => :ets_compressed,
    "disk" => :disk,
    "disk_compressed" => :disk_compressed
  }
  @modes [:individual, :group, :external, :erasure, :recovery]
  @resources [
    :store,
    :mode,
    :cycles,
    :samples,
    :mean_ms,
    :p50_ms,
    :p95_ms,
    :p99_ms,
    :ledger_entries,
    :ledger_batches,
    :ledger_canonical_bytes,
    :ledger_file_bytes,
    :entry_delta,
    :batch_delta,
    :canonical_byte_delta,
    :payload_file_bytes,
    :payload_verify_calls,
    :verify_call_delta,
    :sequencer_bytes,
    :sequencer_after_gc_bytes,
    :sequencer_binary_ref_bytes,
    :sequencer_queue,
    :sequencer_reductions,
    :store_process_bytes,
    :store_ets_bytes,
    :vm_bytes,
    :vm_rss_bytes
  ]

  def run(args) do
    config = options(args)
    File.mkdir_p!(config.output)

    File.write!(
      Path.join(config.output, "environment.txt"),
      inspect(
        %{
          config: config,
          elixir: System.version(),
          otp: :erlang.system_info(:otp_release),
          schedulers: :erlang.system_info(:schedulers_online),
          word_size: :erlang.system_info(:wordsize),
          git_head: System.cmd("git", ["rev-parse", "HEAD"]),
          git_status: System.cmd("git", ["status", "--short"])
        },
        pretty: true,
        limit: :infinity
      )
    )

    IO.puts("Bench outputs: #{config.output}")

    IO.puts(
      "Fresh Domain per latency sample; setup/history and cleanup excluded. No shared growing input."
    )

    IO.puts(
      "Benchee allocation/reduction metrics describe its caller, not the Sequencer; see resources.csv."
    )

    if config.phase in ["all", "latency"] do
      latency(config)
      scenario_resources(config)
    end

    if config.phase in ["all", "growth"], do: growth(config)
    IO.puts("Saved benchmark results in #{config.output}")
  end

  defp latency(config) do
    jobs =
      Map.new(@modes, fn mode ->
        {Atom.to_string(mode),
         {fn f -> Workload.run(f, mode) end,
          before_each: fn input -> Workload.start(input, mode) end, after_each: &Workload.stop/1}}
      end)

    inputs =
      for store <- config.stores, history <- config.histories, into: %{} do
        {"#{store}/history=#{history}/operations=#{config.operations}",
         input(config, store, history)}
      end

    suite =
      Benchee.run(jobs,
        inputs: inputs,
        time: config.time,
        warmup: config.warmup,
        parallel: 1,
        memory_time: 0,
        reduction_time: 0,
        percentiles: [50, 95, 99],
        pre_check: true,
        formatters: [{Benchee.Formatters.Console, comparison: false}],
        save: [path: Path.join(config.output, "latency.benchee"), tag: "current"]
      )

    rows =
      Enum.map(suite.scenarios, fn scenario ->
        stats = scenario.run_time_data.statistics

        %{
          job: scenario.job_name,
          input: scenario.input_name,
          samples: stats.sample_size,
          average_ms: stats.average / 1_000_000,
          p50_ms: stats.percentiles[50] / 1_000_000,
          p95_ms: stats.percentiles[95] / 1_000_000,
          p99_ms: stats.percentiles[99] / 1_000_000
        }
      end)

    Metrics.write_csv(
      Path.join(config.output, "latency.csv"),
      [:job, :input, :samples, :average_ms, :p50_ms, :p95_ms, :p99_ms],
      rows
    )
  end

  # Separate diagnostic runs keep ledger traversal and memory sampling out of
  # Benchee timings. In particular they show actual group-commit batch counts.
  defp scenario_resources(config) do
    rows =
      for store <- config.stores, history <- config.histories, mode <- @modes do
        f = Workload.start(input(config, store, history), mode)
        before = Metrics.capture(f, config.gc)
        completed = Workload.run(f, mode)

        try do
          after_work = Metrics.capture(completed, config.gc)
          cycles = if mode in [:erasure, :recovery], do: 1, else: config.operations

          resource_row(after_work, before, store, mode, cycles, [])
          |> Map.put(:history, history)
        after
          Workload.stop(completed)
        end
      end

    Metrics.write_csv(
      Path.join(config.output, "scenario_resources.csv"),
      [:history | @resources],
      rows
    )
  end

  defp growth(config) do
    {rows, events} =
      for store <- config.stores,
          mode <- [:inline, :external, :after_erasure],
          reduce: {[], []} do
        {rows, events} ->
          IO.puts("Growth: #{store}/#{mode}, checkpoints #{inspect(config.checkpoints)}")

          f =
            Workload.start(
              %{input(config, store, 0) | operations: List.last(config.checkpoints)},
              mode
            )

          try do
            initial = Metrics.capture(f, config.gc)
            first = resource_row(initial, initial, store, mode, 0, [])

            {_, _, captured} =
              Enum.reduce(config.checkpoints, {0, initial, [first]}, fn total,
                                                                        {previous, before, acc} ->
                times =
                  Enum.map((previous + 1)..total, fn n ->
                    {us, :ok} = :timer.tc(fn -> Workload.cycle(f, n, mode) end)
                    us / 1_000
                  end)

                after_work = Metrics.capture(f, config.gc)
                row = resource_row(after_work, before, store, mode, total, times)
                {total, after_work, [row | acc]}
              end)

            captured = Enum.reverse(captured)

            event_rows =
              Enum.flat_map(captured, fn row ->
                Enum.map(row.events, fn {type, stat} ->
                  %{
                    store: store,
                    mode: mode,
                    cycles: row.cycles,
                    event: type,
                    count: stat.count,
                    canonical_bytes: stat.bytes
                  }
                end)
              end)

            {rows ++ captured, events ++ event_rows}
          after
            Workload.stop(f)
          end
      end

    Metrics.write_csv(Path.join(config.output, "resources.csv"), @resources, rows)

    Metrics.write_csv(
      Path.join(config.output, "events.csv"),
      [:store, :mode, :cycles, :event, :count, :canonical_bytes],
      events
    )
  end

  defp resource_row(current, before, store, mode, cycles, times) do
    current
    |> Map.merge(Metrics.percentiles(times))
    |> Map.merge(%{
      store: store,
      mode: mode,
      cycles: cycles,
      entry_delta: current.ledger_entries - before.ledger_entries,
      batch_delta: current.ledger_batches - before.ledger_batches,
      canonical_byte_delta: current.ledger_canonical_bytes - before.ledger_canonical_bytes,
      verify_call_delta: current.payload_verify_calls - before.payload_verify_calls
    })
  end

  defp input(config, store, history),
    do: %{
      store: store,
      history: history,
      operations: config.operations,
      batch_size: config.operations,
      batch_wait_ms: 1,
      payload_bytes: config.payload_bytes
    }

  defp options(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          quick: :boolean,
          gc: :boolean,
          phase: :string,
          stores: :string,
          history: :string,
          checkpoints: :string,
          operations: :integer,
          time: :float,
          warmup: :float,
          payload_bytes: :integer,
          output: :string
        ]
      )

    if rest != [] or invalid != [],
      do: raise("Invalid benchmark options: #{inspect({rest, invalid})}")

    quick = opts[:quick] || false
    phase = opts[:phase] || "all"
    if phase not in ["all", "latency", "growth"], do: raise("Invalid phase: #{phase}")

    stores =
      String.split(opts[:stores] || "ets,disk_compressed", ",")
      |> Enum.map(&Map.fetch!(@stores, &1))

    histories = numbers(opts[:history] || "0", true)
    checkpoints = numbers(opts[:checkpoints] || if(quick, do: "3,10", else: "10,50,100"), false)
    operations = opts[:operations] || if(quick, do: 2, else: 8)
    bytes = opts[:payload_bytes] || 4_096
    time = opts[:time] || if(quick, do: 0.03, else: 1.0)
    warmup = opts[:warmup] || if(quick, do: 0.0, else: 0.2)

    if operations < 1 or bytes < 0 or time <= 0 or warmup < 0,
      do: raise("Invalid measurement bounds")

    tag =
      Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S") <>
        "-#{System.unique_integer([:positive])}"

    %{
      stores: stores,
      phase: phase,
      gc: opts[:gc] || false,
      histories: histories,
      checkpoints: checkpoints,
      operations: operations,
      payload_bytes: bytes,
      time: time,
      warmup: warmup,
      output: Path.join(opts[:output] || "bench/results/local", tag)
    }
  end

  defp numbers(string, allow_zero) do
    numbers = string |> String.split(",") |> Enum.map(&String.to_integer/1)

    if Enum.any?(numbers, &(&1 < if(allow_zero, do: 0, else: 1))),
      do: raise("Invalid history size")

    Enum.sort(Enum.uniq(numbers))
  end
end

Spectre.Bench.Suite.run(System.argv())
