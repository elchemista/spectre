defmodule Spectre.Server.TaskGuard do
  @moduledoc false

  @doc false
  @spec start(pid(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(owner, worker) do
    Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
      owner_monitor = Process.monitor(owner)
      worker_monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, _} -> Process.exit(worker, :kill)
        {:DOWN, ^worker_monitor, :process, ^worker, _} -> :ok
        :release -> :ok
      end
    end)
  end

  @doc false
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(guard) do
    send(guard, :release)
    :ok
  end
end
