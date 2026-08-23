if System.get_env("SPECTRE_PERF_TESTS") in ["1", "true"] do
  defmodule SpectreInstancePerformanceTest.AgentDefinition do
    @moduledoc false
    use Spectre.Agent, id: :instance_performance_agent
  end

  defmodule SpectreInstancePerformanceTest do
    use ExUnit.Case, async: false

    @moduletag :perf

    alias Spectre.Instance
    alias Spectre.Test.Performance
    alias SpectreInstancePerformanceTest.AgentDefinition

    test "fresh boot leaves the owner compact after the automatic hibernation" do
      subject = "perf-boot-#{System.unique_integer([:positive, :monotonic])}"

      sample =
        Performance.measure_start(fn ->
          Spectre.summon(agent: AgentDefinition, subject: subject, idle: false)
        end)

      {:ok, instance} = sample.result

      assert sample.owner_reductions < 250_000
      assert sample.total_heap_words < 20_000
      assert sample.memory_bytes < 250_000
      assert sample.binary_bytes < 2_000_000

      GenServer.stop(instance)
    end

    test "passive monitoring has bounded per-call owner cost" do
      subject = "perf-info-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, instance} = Spectre.summon(agent: AgentDefinition, subject: subject, idle: false)

      samples =
        Enum.map(1..25, fn _index ->
          Performance.measure_process(instance, fn -> Spectre.Instance.info(instance) end)
        end)

      median = samples |> Enum.map(& &1.owner_reductions) |> Performance.median()
      assert median < 10_000
      GenServer.stop(instance)
    end

    test "a sustained passive-monitoring soak does not accumulate owner heap or binaries" do
      subject = "perf-soak-#{System.unique_integer([:positive, :monotonic])}"
      {:ok, instance} = Spectre.summon(agent: AgentDefinition, subject: subject, idle: false)

      _ = Instance.info(instance)
      baseline = Performance.snapshot(instance)

      Enum.each(1..2_000, fn _index ->
        %{ref: ref} = Instance.info(instance)
        assert is_binary(ref)
      end)

      after_soak = Performance.snapshot(instance)

      assert after_soak.total_heap_words <= max(baseline.total_heap_words * 2, 20_000)
      assert after_soak.memory_bytes <= max(baseline.memory_bytes * 2, 250_000)
      assert after_soak.binary_bytes <= baseline.binary_bytes + 262_144

      GenServer.stop(instance)
    end
  end
end
