defmodule Spectre.Server.TransportGuard do
  @moduledoc false

  def start(adapter, transport, context, generation) do
    caller = self()
    token = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
        monitor = Process.monitor(caller)
        owner = if is_pid(context[:runtime]), do: Process.monitor(context.runtime)
        watch(adapter, transport, context, generation, caller, monitor, owner, token)
      end)

    {pid, token}
  end

  def update({pid, token}, transport), do: send(pid, {token, :transport, transport})
  def finish({pid, token}, result), do: send(pid, {token, :finish, result})

  defp watch(adapter, transport, context, generation, caller, monitor, owner, token) do
    receive do
      {^token, :transport, latest} ->
        watch(adapter, latest, context, generation, caller, monitor, owner, token)

      {^token, :finish, result} ->
        Process.demonitor(monitor, [:flush])
        if owner, do: Process.demonitor(owner, [:flush])
        finish_transport(adapter, transport, context, generation, result)

      {:DOWN, ^owner, :process, _runtime, _reason} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(caller, :kill)
        finish_transport(adapter, transport, context, generation, {:error, :stream_interrupted})

      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        if owner, do: Process.demonitor(owner, [:flush])
        finish_transport(adapter, transport, context, generation, {:error, :stream_interrupted})
    end
  end

  defp finish_transport(adapter, transport, context, generation, result) do
    status = terminal_status(result)

    if is_pid(context[:consumer]) do
      Spectre.Server.Runtime.notify_service(
        context,
        {:preview_end, context.interaction, generation, status}
      )
    end

    if status != :completed, do: cancel(adapter, transport)
  end

  defp terminal_status({:ok, _}), do: :completed
  defp terminal_status({:error, reason}), do: {:error, reason}
  defp terminal_status(_), do: {:error, :stream_interrupted}

  defp cancel(adapter, transport) do
    task =
      Task.Supervisor.async_nolink(Spectre.Server.TaskSupervisor, fn ->
        safe_cancel(adapter, transport)
      end)

    Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_cancel(adapter, transport) do
    adapter.cancel(transport, :stream_interrupted)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
