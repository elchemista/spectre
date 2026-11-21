defmodule Spectre.Server.Activities do
  @moduledoc false

  use GenServer

  alias Spectre.Server.Registry, as: ServerRegistry
  alias Spectre.Server.TaskSupervisor

  @type child :: {module(), keyword()}
  @type ref :: String.t()
  @type entry :: %{
          status: :reserved | :starting | :running | :completed | :failed,
          pid: pid() | nil,
          reason: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, nil, opts)

  @spec start(pid(), term(), child()) :: {:ok, ref()} | {:error, term()}
  def start(owner, command_id, child) do
    with {:ok, ref} <- reserve(owner, command_id, child), do: resume(owner, ref)
  end

  @spec reserve(pid(), term(), child()) :: {:ok, ref()} | {:error, term()}
  def reserve(owner, command_id, child), do: GenServer.call(owner, {:reserve, command_id, child})

  @spec resume(pid(), ref()) :: {:ok, ref()} | {:error, term()}
  def resume(owner, ref), do: GenServer.call(owner, {:resume, ref}, :infinity)

  @spec lookup(pid(), ref()) :: {:ok, entry()} | {:error, :unknown_activity}
  def lookup(owner, ref), do: GenServer.call(owner, {:lookup, ref})

  @spec supervisor(pid()) :: pid() | nil
  def supervisor(owner), do: GenServer.call(owner, :supervisor)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       supervisor: nil,
       registry_monitor: nil,
       commands: %{},
       entries: %{},
       launches: %{},
       children: %{}
     }}
  end

  @impl true
  def handle_call({:reserve, command_id, child}, _from, state) do
    case Map.fetch(state.commands, command_id) do
      {:ok, ref} ->
        if state.entries[ref].child == child,
          do: {:reply, {:ok, ref}, state},
          else: {:reply, {:error, :activity_command_conflict}, state}

      :error ->
        ref = Spectre.Identity.uuid7()

        entry = %{
          child: child,
          status: :reserved,
          pid: nil,
          reason: nil,
          result: nil,
          waiters: []
        }

        {:reply, {:ok, ref},
         %{state | commands: Map.put(state.commands, command_id, ref)}
         |> put_entry(ref, entry)}
    end
  end

  def handle_call({:resume, ref}, from, state) do
    case Map.fetch(state.entries, ref) do
      {:ok, %{status: :reserved} = entry} ->
        launch(state, ref, %{entry | waiters: [from]})

      {:ok, %{status: :starting} = entry} ->
        {:noreply, put_entry(state, ref, %{entry | waiters: [from | entry.waiters]})}

      {:ok, entry} ->
        {:reply, entry.result, state}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:lookup, ref}, _from, state) do
    result =
      case Map.fetch(state.entries, ref) do
        {:ok, entry} -> {:ok, Map.take(entry, [:status, :pid, :reason])}
        :error -> {:error, :unknown_activity}
      end

    {:reply, result, state}
  end

  def handle_call(:supervisor, _from, state), do: {:reply, state.supervisor, state}

  @impl true
  def handle_info({monitor, result}, state) when is_map_key(state.launches, monitor) do
    Process.demonitor(monitor, [:flush])
    {ref, launches} = Map.pop(state.launches, monitor)
    {:noreply, adopt(%{state | launches: launches}, ref, result)}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, state)
      when is_map_key(state.launches, monitor) do
    {ref, launches} = Map.pop(state.launches, monitor)
    {:noreply, fail(%{state | launches: launches}, ref, reason)}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, state)
      when is_map_key(state.children, monitor) do
    {ref, children} = Map.pop(state.children, monitor)
    {:noreply, finish_child(%{state | children: children}, ref, reason)}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{registry_monitor: monitor} = state) do
    Process.exit(state.supervisor, :shutdown)
    {:noreply, %{state | registry_monitor: nil}}
  end

  def handle_info({:EXIT, supervisor, _}, %{supervisor: supervisor} = state) do
    if state.registry_monitor, do: Process.demonitor(state.registry_monitor, [:flush])
    {:noreply, %{state | supervisor: nil, registry_monitor: nil}}
  end

  def handle_info({:EXIT, _parent, reason}, state), do: {:stop, reason, state}
  def handle_info(_, state), do: {:noreply, state}

  defp launch(state, ref, entry) do
    case ensure_supervisor(state) do
      {:ok, state} ->
        supervisor = state.supervisor
        name = {:via, Registry, {ServerRegistry, {__MODULE__, self(), ref}}}
        {module, opts} = entry.child

        # Starting a child can wait for its init. Keep the owner free to handle exits.
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            spec =
              Supervisor.child_spec({module, Keyword.put(opts, :name, name)}, restart: :temporary)

            DynamicSupervisor.start_child(supervisor, spec)
          end)

        state = put_entry(state, ref, %{entry | status: :starting})
        {:noreply, %{state | launches: Map.put(state.launches, task.ref, ref)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_supervisor(%{supervisor: nil} = state) do
    case Process.whereis(ServerRegistry) do
      nil ->
        {:error, :server_registry_unavailable}

      registry ->
        with {:ok, supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
          {:ok, %{state | supervisor: supervisor, registry_monitor: Process.monitor(registry)}}
        end
    end
  end

  defp ensure_supervisor(state), do: {:ok, state}

  defp adopt(state, ref, {:ok, pid}) do
    monitor = Process.monitor(pid)
    entry = state.entries[ref]
    result = {:ok, ref}

    state =
      put_entry(state, ref, %{entry | pid: pid, status: :running, result: result, waiters: []})

    # The child stays inert until the owner has adopted it.
    send(pid, {:spectre_activity, :activate, ref})
    Enum.each(entry.waiters, &GenServer.reply(&1, result))
    %{state | children: Map.put(state.children, monitor, ref)}
  end

  defp adopt(state, ref, {:ok, pid, _info}), do: adopt(state, ref, {:ok, pid})
  defp adopt(state, ref, {:error, reason}), do: fail(state, ref, reason)
  defp adopt(state, ref, :ignore), do: fail(state, ref, :activity_start_ignored)

  defp finish_child(state, ref, :normal) do
    entry = state.entries[ref]
    put_entry(state, ref, %{entry | status: :completed, pid: nil})
  end

  defp finish_child(state, ref, reason), do: fail(state, ref, reason)

  defp fail(state, ref, reason) do
    entry = state.entries[ref]
    result = entry.result || {:error, reason}
    Enum.each(entry.waiters, &GenServer.reply(&1, result))

    put_entry(state, ref, %{
      entry
      | status: :failed,
        pid: nil,
        reason: reason,
        result: result,
        waiters: []
    })
  end

  defp put_entry(state, ref, entry), do: %{state | entries: Map.put(state.entries, ref, entry)}
end
