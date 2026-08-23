defmodule Spectre.Instance.BootCapacity do
  @moduledoc false

  use GenServer

  @task_supervisor Spectre.Instance.BootTaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec start((-> term()), GenServer.server(), timeout()) ::
          {:ok, reference(), pid()} | {:error, term()}
  def start(callback, server \\ __MODULE__, timeout \\ :infinity)

  def start(callback, server, timeout)
      when is_function(callback, 0) and
             (timeout == :infinity or (is_integer(timeout) and timeout > 0)) do
    ref = make_ref()

    try do
      GenServer.call(server, {:start, self(), ref, callback}, timeout)
    catch
      :exit, {:timeout, _call} ->
        :ok = cancel(ref, server)
        {:error, :boot_task_start_timeout}
    end
  end

  @spec cancel(reference(), GenServer.server()) :: :ok
  def cancel(ref, server \\ __MODULE__) when is_reference(ref) do
    GenServer.call(server, {:cancel, ref})
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    configured =
      Keyword.get_lazy(opts, :limit, fn ->
        Application.get_env(:spectre, :boot_max_concurrency, System.schedulers_online())
      end)

    if is_integer(configured) and configured > 0 do
      {:ok,
       %{
         limit: configured,
         monitors: %{},
         queue: :queue.new(),
         running: %{}
       }}
    else
      {:stop, {:invalid_instance_boot_capacity, configured}}
    end
  end

  @impl GenServer
  def handle_call({:start, owner, ref, callback}, from, state)
      when is_pid(owner) and is_reference(ref) and is_function(callback, 0) do
    entry = %{
      callback: callback,
      from: from,
      owner: owner,
      owner_monitor: Process.monitor(owner),
      ref: ref
    }

    state = put_monitor(state, entry.owner_monitor, {:owner, entry.ref})

    if map_size(state.running) < state.limit do
      {:noreply, start_entry(entry, state)}
    else
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  def handle_call({:cancel, ref}, _from, state) do
    {:reply, :ok, cancel_entry(ref, state)}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:task, ref}, monitors} ->
        task_down(ref, reason, %{state | monitors: monitors})

      {{:owner, ref}, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, owner_down(ref, state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp task_down(ref, reason, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {entry, running} ->
        Process.demonitor(entry.owner_monitor, [:flush])
        monitors = Map.delete(state.monitors, entry.owner_monitor)
        maybe_report_worker_exit(entry.owner, ref, reason)

        {:noreply, state |> Map.put(:running, running) |> Map.put(:monitors, monitors) |> drain()}
    end
  end

  defp maybe_report_worker_exit(_owner, _ref, :normal), do: :ok

  defp maybe_report_worker_exit(owner, ref, reason),
    do: send(owner, {:spectre_instance_boot, ref, {:worker_exit, reason}})

  defp start_entry(entry, state) do
    ref = entry.ref
    owner = entry.owner
    callback = entry.callback
    start_gate = make_ref()

    worker = fn ->
      receive do
        {:spectre_instance_boot_start, ^start_gate} ->
          outcome = capture(callback)
          send(owner, {:spectre_instance_boot, ref, outcome})
      end
    end

    case Task.Supervisor.start_child(@task_supervisor, worker) do
      {:ok, pid} ->
        task_monitor = Process.monitor(pid)
        GenServer.reply(entry.from, {:ok, ref, pid})

        entry = Map.merge(entry, %{pid: pid, task_monitor: task_monitor})

        state =
          state
          |> put_in([:running, ref], entry)
          |> put_monitor(task_monitor, {:task, ref})

        send(pid, {:spectre_instance_boot_start, start_gate})
        state

      {:error, reason} ->
        Process.demonitor(entry.owner_monitor, [:flush])
        GenServer.reply(entry.from, {:error, {:instance_boot_task_start_failed, reason}})

        state
        |> delete_monitor(entry.owner_monitor)
        |> drain()
    end
  end

  defp capture(callback) do
    {:return, callback.()}
  catch
    kind, reason -> {:raise, kind, reason, __STACKTRACE__}
  end

  defp owner_down(ref, state) do
    case Map.pop(state.running, ref) do
      {nil, running} ->
        queue =
          state.queue
          |> :queue.to_list()
          |> Enum.reject(&drop_owner_entry?(&1, ref))
          |> :queue.from_list()

        %{state | queue: queue, running: running}

      {entry, _running} ->
        if Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
        state
    end
  end

  defp drop_owner_entry?(%{ref: ref, from: from}, ref) do
    GenServer.reply(from, {:error, :boot_owner_down})
    true
  end

  defp drop_owner_entry?(_entry, _ref), do: false

  defp cancel_entry(ref, state) do
    case Map.get(state.running, ref) do
      nil ->
        {cancelled, retained} =
          state.queue
          |> :queue.to_list()
          |> Enum.split_with(&(&1.ref == ref))

        monitors =
          Enum.reduce(cancelled, state.monitors, fn entry, monitors ->
            Process.demonitor(entry.owner_monitor, [:flush])
            GenServer.reply(entry.from, {:error, :boot_task_cancelled})
            Map.delete(monitors, entry.owner_monitor)
          end)

        %{state | queue: :queue.from_list(retained), monitors: monitors}

      entry ->
        if Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
        state
    end
  end

  defp drain(state) when map_size(state.running) >= state.limit, do: state

  defp drain(state) do
    case :queue.out(state.queue) do
      {{:value, entry}, queue} ->
        drain_entry(entry, %{state | queue: queue})

      {:empty, _queue} ->
        state
    end
  end

  defp drain_entry(entry, state) do
    if Process.alive?(entry.owner) do
      entry
      |> start_entry(state)
      |> drain()
    else
      Process.demonitor(entry.owner_monitor, [:flush])

      state
      |> delete_monitor(entry.owner_monitor)
      |> drain()
    end
  end

  defp put_monitor(state, monitor, value),
    do: %{state | monitors: Map.put(state.monitors, monitor, value)}

  defp delete_monitor(state, monitor),
    do: %{state | monitors: Map.delete(state.monitors, monitor)}
end
