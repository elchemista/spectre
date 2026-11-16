ExUnit.start()

exclude = []

exclude =
  if System.get_env("SPECTRE_REAL_EMBEDDING_TESTS") in ["1", "true"],
    do: exclude,
    else: [{:real_ex_fastembed, true} | exclude]

exclude =
  if System.get_env("SPECTRE_PERF_TESTS") in ["1", "true"],
    do: exclude,
    else: [{:perf, true} | exclude]

ExUnit.configure(exclude: exclude)

# A linked server may already be shutting down when the test owner exits.
# Wait for termination rather than racing Process.alive? with GenServer.stop.
defmodule Spectre.Test.Processes do
  def stop(pid) do
    monitor = Process.monitor(pid)

    try do
      GenServer.stop(pid, :normal, 10_000)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      10_000 -> raise "test process did not terminate"
    end
  end
end
