defmodule Mix.Tasks.Spectre.Profile do
  @moduledoc """
  Profiles representative Instance boot scenarios.

      mix spectre.profile
      mix spectre.profile --scenario restore_runs --runs 64 --iterations 5

  The task prints median owner/total reductions, post-GC footprint, boot wall
  time, and a `:tprof` allocation breakdown. It never prints retained binary
  contents.
  """

  use Mix.Task

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.BootCapacity
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Ref

  @shortdoc "Profiles Instance boot reductions, allocation, and footprint"

  @switches [
    scenario: :string,
    runs: :integer,
    bytes: :integer,
    iterations: :integer,
    no_tprof: :boolean
  ]

  @scenarios ["fresh", "restore_runs", "large_checkpoint"]

  @impl Mix.Task
  def run(arguments) do
    Mix.Task.run("app.start")
    {opts, positional, invalid} = OptionParser.parse(arguments, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid spectre.profile arguments")
    end

    runs = positive!(Keyword.get(opts, :runs, 32), :runs)
    bytes = positive!(Keyword.get(opts, :bytes, 1_000_000), :bytes)
    iterations = positive!(Keyword.get(opts, :iterations, 3), :iterations)
    scenarios = scenarios(Keyword.get(opts, :scenario, "all"))

    Mix.shell().info(
      "Spectre profile on OTP #{System.otp_release()} / Elixir #{System.version()} " <>
        "(#{System.schedulers_online()} schedulers)"
    )

    Enum.each(scenarios, fn scenario ->
      samples = Enum.map(1..iterations, fn _ -> measure(scenario, runs, bytes) end)
      print_summary(scenario, samples)

      unless Keyword.get(opts, :no_tprof, false) do
        profile(scenario, runs, bytes)
      end
    end)
  end

  defmodule AgentDefinition do
    @moduledoc false
    use Spectre.Agent, id: :spectre_profile_agent
  end

  defp measure(scenario, runs, bytes) do
    total_before = total_reductions()
    started_at = System.monotonic_time()
    {:ok, pid} = start_scenario(scenario, runs, bytes)
    wall_time_us = elapsed_us(started_at)
    _ = :erlang.garbage_collect(pid)

    info =
      Process.info(pid, [
        :binary,
        :heap_size,
        :memory,
        :reductions,
        :total_heap_size
      ])

    sample = %{
      wall_time_us: wall_time_us,
      total_reductions: max(total_reductions() - total_before, 0),
      owner_reductions: Keyword.fetch!(info, :reductions),
      memory_bytes: Keyword.fetch!(info, :memory),
      heap_words: Keyword.fetch!(info, :heap_size),
      total_heap_words: Keyword.fetch!(info, :total_heap_size),
      binary_bytes: binary_bytes(Keyword.fetch!(info, :binary))
    }

    GenServer.stop(pid)
    sample
  end

  defp profile(scenario, runs, bytes) do
    ensure_tprof!()
    Mix.shell().info("\n:tprof call_memory — #{scenario}")

    rootset =
      [
        Process.whereis(BootCapacity),
        Process.whereis(Spectre.Instance.BootTaskSupervisor)
      ]
      |> Enum.filter(&is_pid/1)

    # `:tprof` may live outside the compile-time code path on split OTP packages.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    {_result, raw} =
      apply(
        :tprof,
        :profile,
        [
          fn ->
            {:ok, pid} = start_scenario(scenario, runs, bytes)
            GenServer.stop(pid)
            :ok
          end,
          %{
            type: :call_memory,
            pattern: profile_patterns(),
            report: :return,
            rootset: rootset,
            set_on_spawn: true,
            timeout: 60_000
          }
        ]
      )

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    inspected = apply(:tprof, :inspect, [raw, :total, :percent])
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(:tprof, :format, [inspected])
  end

  defp start_scenario(scenario, runs, bytes) do
    subject =
      "profile-#{scenario}-#{System.unique_integer([:positive, :monotonic])}"

    ref = Ref.new(AgentDefinition, subject)

    opts = [
      agent: AgentDefinition,
      subject: subject,
      idle: false,
      hibernate_after: :infinity
    ]

    opts =
      case scenario do
        "fresh" -> opts
        "restore_runs" -> Keyword.put(opts, :canonical_checkpoint, checkpoint(ref, runs, 0))
        "large_checkpoint" -> Keyword.put(opts, :canonical_checkpoint, checkpoint(ref, 0, bytes))
      end

    Spectre.Instance.start_link(opts)
  end

  defp checkpoint(ref, run_count, blob_bytes) do
    state = %Spectre.State{
      conversation_id: ref.key,
      data:
        if(blob_bytes > 0,
          do: %{profile_blob: String.duplicate("x", blob_bytes)},
          else: %{}
        )
    }

    runs =
      run_count
      |> indices()
      |> Map.new(fn index ->
        id = "profile-run-#{index}"

        run_opts = [run_id: id]

        {:ok, run} =
          Spectre.Runtime.admit(
            AgentDefinition,
            Spectre.Input.new("profile input #{index}"),
            state,
            run_opts,
            run_opts
          )

        {:ok, encoded} = Spectre.Run.checkpoint(run)
        {id, encoded}
      end)

    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}},
        runs: runs
      })

    {:ok, encoded} = Codec.encode_json(canonical)
    {:ok, _report} = Foundation.verify_instance_checkpoint(encoded, ref)
    encoded
  end

  defp print_summary(scenario, samples) do
    Mix.shell().info("\n#{scenario} (median of #{length(samples)})")

    Enum.each(
      [
        {:wall_time_us, "wall µs"},
        {:owner_reductions, "owner reductions"},
        {:total_reductions, "total reductions"},
        {:memory_bytes, "owner memory bytes"},
        {:heap_words, "owner heap words"},
        {:total_heap_words, "owner total heap words"},
        {:binary_bytes, "retained binary bytes"}
      ],
      fn {key, label} ->
        values = Enum.map(samples, &Map.fetch!(&1, key))
        Mix.shell().info("  #{label}: #{median(values)}")
      end
    )
  end

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
  end

  defp scenarios("all"), do: @scenarios

  defp scenarios(scenario) when scenario in @scenarios, do: [scenario]

  defp scenarios(scenario),
    do:
      Mix.raise(
        "unknown scenario #{inspect(scenario)}; expected all or #{@scenarios |> Enum.join(", ")}"
      )

  defp positive!(value, _key) when is_integer(value) and value > 0, do: value
  defp positive!(value, key), do: Mix.raise("--#{key} must be positive, got: #{inspect(value)}")

  defp indices(0), do: []
  defp indices(count), do: 1..count

  defp profile_patterns do
    [
      {Spectre.Instance, :_, :_},
      {Spectre.Instance.Boot, :_, :_},
      {Spectre.Instance.Checkpoint, :_, :_},
      {Spectre.Instance.Canonical.Codec, :_, :_},
      {Spectre.Instance.Canonical.Validator, :_, :_},
      {Spectre.Instance.Restore, :_, :_},
      {Spectre.Instance.DefinitionCompatibility, :_, :_},
      {Spectre.Run.Codec, :_, :_},
      {Spectre.JSON, :_, :_},
      {JSON, :_, :_}
    ]
  end

  defp ensure_tprof! do
    case Code.ensure_loaded(:tprof) do
      {:module, :tprof} ->
        :ok

      {:error, _reason} ->
        root = :code.lib_dir() |> to_string()

        path =
          root
          |> Path.join("tools-*/ebin")
          |> String.to_charlist()
          |> :filelib.wildcard()
          |> List.first()

        if is_list(path), do: :code.add_patha(path)

        case Code.ensure_loaded(:tprof) do
          {:module, :tprof} -> :ok
          {:error, reason} -> Mix.raise(":tprof is unavailable: #{inspect(reason)}")
        end
    end
  end

  defp binary_bytes(binaries) do
    binaries
    |> Enum.map(fn {_reference, bytes, _references} -> bytes end)
    |> Enum.sum()
  end

  defp total_reductions, do: :erlang.statistics(:reductions) |> elem(0)

  defp elapsed_us(started_at),
    do: System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)
end
