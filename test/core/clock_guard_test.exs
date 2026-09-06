defmodule Spectre.Core.ClockGuardTest do
  use ExUnit.Case, async: false

  alias Spectre.Clock.Guard
  alias Spectre.Domain.{Configuration, Sequencer, Transaction}
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(clock_tolerance_ms: 1_000)
    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f}
  end

  test "idle months are elapsed time, not a wall-clock jump" do
    {:ok, guard} = Guard.new(1_000_000, 1_000, -10_000)
    elapsed = 90 * 86_400_000
    assert :ok = Guard.validate(guard, 1_000_000 + elapsed, -10_000 + elapsed)
    assert :ok = Guard.validate(guard, 1_000_000 + elapsed + 1_000, -10_000 + elapsed)

    assert {:error, {:clock_drift_exceeded, 1_001, 1_000}} =
             Guard.validate(guard, 1_000_000 + elapsed + 1_001, -10_000 + elapsed)

    assert {:error, {:clock_drift_exceeded, -1_001, 1_000}} =
             Guard.validate(guard, 1_000_000 + elapsed - 1_001, -10_000 + elapsed)
  end

  test "forward poison and backwards regression are rejected without changing the ledger", %{f: f} do
    now = Runtime.now()
    snapshot = Fixture.snapshot(f)

    for delta <- [86_400_000, -10_000] do
      Runtime.set_time(now + delta)
      assert {:error, {:clock_drift_exceeded, _, 1_000}} = Sequencer.trusted_time(f.server)
      assert Fixture.snapshot(f) === snapshot
    end

    Runtime.set_time(now)
    assert {:ok, ^now} = Sequencer.trusted_time(f.server)
  end

  test "a future durable prefix cannot be silently clamped forever after restart", %{f: f} do
    state = :sys.get_state(f.server)
    future = state.projection.recorded_at + 10_000
    state = %{state | projection: %{state.projection | recorded_at: future}}
    assert {:error, {:ledger_clock_ahead, ^future, _}} = Transaction.trusted_recorded_at(state)
  end

  test "configuration fences real clocks by default; virtual clocks can explicitly opt out", %{
    f: f
  } do
    opts = Keyword.delete(f.sequencer_opts, :clock_tolerance_ms)
    assert {:ok, %{clock_guard: %Guard{tolerance_ms: 60_000}}} = Configuration.new(opts)

    assert {:ok, %{clock_guard: nil}} =
             Configuration.new(Keyword.put(opts, :clock_tolerance_ms, :infinity))

    for bad <- [0, -1, 1.0, nil, "1000"] do
      assert {:error, :invalid_clock_tolerance_ms} =
               Configuration.new(Keyword.put(opts, :clock_tolerance_ms, bad))
    end
  end
end
