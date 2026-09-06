Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)
Code.require_file("../../bench/support/workload.exs", __DIR__)

defmodule Spectre.Core.ErasureHotPathTest do
  # call_count instrumentation is VM-wide; never overlap other ExUnit cases.
  use ExUnit.Case, async: false

  alias Spectre.Bench.Workload
  alias Spectre.Erasure.Analysis.{Closure, Execution}
  alias Spectre.Kernel.Authority.Facts

  test "ordinary cycles after a real deletion do not rescan closure or erasure execution history" do
    fixture =
      Workload.start(
        %{
          store: :ets,
          history: 100,
          operations: 20,
          batch_size: 1,
          batch_wait_ms: 0,
          payload_bytes: 64
        },
        :after_erasure
      )

    on_exit(fn -> Workload.stop(fixture) end)

    probes = [
      {Closure, :derive, 2},
      {Execution, :state, 2},
      {Facts, :blocked_effect_digests, 1},
      {Facts, :blocked_mandate_refs, 1}
    ]

    try do
      for probe <- probes,
          do: assert(:erlang.trace_pattern(probe, true, [:local, :call_count]) === 1)

      for sequence <- 101..120, do: Workload.cycle(fixture, sequence, :inline)

      for probe <- probes do
        assert :erlang.trace_info(probe, :call_count) === {:call_count, 0},
               "unrelated work traversed historical erasure or authority facts: #{inspect(probe)}"
      end
    after
      for probe <- probes, do: :erlang.trace_pattern(probe, false, [:local, :call_count])
    end
  end
end
