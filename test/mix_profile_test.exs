defmodule SpectreMixProfileTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Spectre.Profile

  test "profiles every boot scenario without exposing checkpoint contents" do
    output =
      run_profile([
        "--scenario",
        "all",
        "--runs",
        "2",
        "--bytes",
        "1024",
        "--iterations",
        "1",
        "--no-tprof"
      ])

    assert output =~ "Spectre profile on OTP"
    assert output =~ "fresh (median of 1)"
    assert output =~ "restore_runs (median of 1)"
    assert output =~ "large_checkpoint (median of 1)"
    assert output =~ "owner reductions:"
    assert output =~ "retained binary bytes:"
    refute output =~ String.duplicate("x", 32)
  end

  test "profiles allocation through tprof and computes an even median" do
    output =
      run_profile([
        "--scenario",
        "fresh",
        "--runs",
        "1",
        "--bytes",
        "1",
        "--iterations",
        "2"
      ])

    assert output =~ "fresh (median of 2)"
    assert output =~ ":tprof call_memory — fresh"
    assert output =~ "Spectre.Instance"
  end

  test "rejects malformed arguments and invalid scenario sizes" do
    assert_raise Mix.Error, ~r/invalid spectre.profile arguments/, fn ->
      run_profile(["unexpected"])
    end

    assert_raise Mix.Error, ~r/unknown scenario/, fn ->
      run_profile(["--scenario", "unknown"])
    end

    assert_raise Mix.Error, ~r/--runs must be positive/, fn ->
      run_profile(["--runs", "0"])
    end
  end

  defp run_profile(arguments) do
    Mix.Task.reenable("spectre.profile")
    capture_io(fn -> Profile.run(arguments) end)
  end
end
