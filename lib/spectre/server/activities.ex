defmodule Spectre.Server.Activities do
  @moduledoc false

  use GenServer

  alias Spectre.Server.Registry, as: ServerRegistry
  alias Spectre.Server.TaskSupervisor

  @default_terminal_limit 256

  @type child :: {module(), keyword()}
  @type ref :: String.t()
  @type entry :: %{
          status: :reserved | :starting | :running | :completed | :failed,
          pid: pid() | nil,
          reason: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {settings, opts} = Keyword.split(opts, [:registry, :terminal_limit])
    GenServer.start_link(__MODULE__, settings, opts)
  end

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

  @doc false
  @spec start_waiting({module(), atom(), [term()]}, pid(), tuple()) ::
          DynamicSupervisor.on_start_child()
  def start_waiting({module, function, args}, owner, token) do
    # The supervisor executes this MFA even if the Task awaiting its reply dies.
    case apply(module, function, args) do
      {:ok, pid} = result when is_pid(pid) ->
        send(owner, {__MODULE__, token, pid})
        result

      {:ok, pid, _info} = result when is_pid(pid) ->
        send(owner, {__MODULE__, token, pid})
        result

      {:error, _reason} = error ->
        error

      :ignore ->
        :ignore

      _ ->
        {:error, :invalid_activity_child_start}
    end
  end

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :terminal_limit, @default_terminal_limit)

    if limit == :infinity or (is_integer(limit) and limit >= 0) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         supervisor: nil,
         registry_name: Keyword.get(opts, :registry, ServerRegistry),
         registry: nil,
         registry_monitor: nil,
         control: make_ref(),
         commands: %{},
         entries: %{},
         launches: %{},
         children: %{},
         terminal: :queue.new(),
         terminal_count: 0,
         terminal_limit: limit
       }}
    else
      {:stop, :invalid_terminal_limit}
    end
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
          command_id: command_id,
          child: child,
          status: :reserved,
          pid: nil,
          reason: nil,
          result: nil,
          attempt: nil,
          waiting: nil,
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
  def handle_info({__MODULE__, {control, ref, attempt}, pid}, %{control: control} = state) do
    case Map.get(state.entries, ref) do
      %{status: :starting, attempt: ^attempt} = entry ->
        {:noreply, put_entry(state, ref, %{entry | waiting: pid})}

      %{status: :running, attempt: ^attempt, pid: ^pid} ->
        {:noreply, state}

      _ ->
        stop_waiting(pid)
        {:noreply, state}
    end
  end

  def handle_info({monitor, result}, state) when is_map_key(state.launches, monitor) do
    Process.demonitor(monitor, [:flush])
    {ref, launches} = Map.pop(state.launches, monitor)
    {:noreply, finish_launch(%{state | launches: launches}, ref, result)}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, state)
      when is_map_key(state.launches, monitor) do
    {ref, launches} = Map.pop(state.launches, monitor)
    {:noreply, finish_launch(%{state | launches: launches}, ref, {:error, reason})}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, state)
      when is_map_key(state.children, monitor) do
    {ref, children} = Map.pop(state.children, monitor)
    {:noreply, finish_child(%{state | children: children}, ref, reason)}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{registry_monitor: monitor} = state) do
    Process.exit(state.supervisor, :shutdown)
    {:noreply, %{state | registry: nil, registry_monitor: nil}}
  end

  def handle_info({:EXIT, supervisor, _}, %{supervisor: supervisor} = state) do
    if state.registry_monitor, do: Process.demonitor(state.registry_monitor, [:flush])
    {:noreply, %{state | supervisor: nil, registry: nil, registry_monitor: nil}}
  end

  def handle_info({:EXIT, _parent, reason}, state), do: {:stop, reason, state}
  def handle_info(_, state), do: {:noreply, state}

  defp launch(state, ref, entry) do
    case ensure_supervisor(state) do
      {:ok, state} ->
        supervisor = state.supervisor
        owner = self()
        attempt = {make_ref(), supervisor, state.registry}
        token = {state.control, ref, attempt}
        name = {:via, Registry, {state.registry_name, {__MODULE__, owner, ref}}}
        {module, opts} = entry.child

        # Starting a child can wait for its init. Keep the owner free to handle exits.
        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            spec =
              Supervisor.child_spec({module, Keyword.put(opts, :name, name)}, restart: :temporary)

            wrapped = %{spec | start: {__MODULE__, :start_waiting, [spec.start, owner, token]}}
            DynamicSupervisor.start_child(supervisor, wrapped)
          end)

        state = put_entry(state, ref, %{entry | status: :starting, attempt: attempt})
        {:noreply, %{state | launches: Map.put(state.launches, task.ref, ref)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp ensure_supervisor(%{supervisor: nil} = state) do
    case Process.whereis(state.registry_name) do
      nil ->
        {:error, :server_registry_unavailable}

      registry ->
        with {:ok, supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
          {:ok,
           %{
             state
             | supervisor: supervisor,
               registry: registry,
               registry_monitor: Process.monitor(registry)
           }}
        end
    end
  end

  defp ensure_supervisor(state) do
    if branch_available?(state, state.supervisor, state.registry),
      do: {:ok, state},
      else: {:error, :activity_supervisor_unavailable}
  end

  defp branch_available?(state, supervisor, registry) do
    state.supervisor == supervisor and state.registry == registry and is_pid(registry) and
      Process.alive?(supervisor) and Process.whereis(state.registry_name) == registry
  end

  defp finish_launch(state, ref, result) do
    %{attempt: {_, supervisor, registry}} = entry = state.entries[ref]

    if branch_available?(state, supervisor, registry) do
      adopt(state, ref, result)
    else
      # Loss of infrastructure before adoption leaves the reservation retryable.
      stop_waiting(entry.waiting)
      Enum.each(entry.waiters, &GenServer.reply(&1, {:error, :activity_supervisor_unavailable}))
      put_entry(state, ref, %{entry | status: :reserved, attempt: nil, waiting: nil, waiters: []})
    end
  end

  defp adopt(state, ref, {:ok, pid}) do
    monitor = Process.monitor(pid)
    entry = state.entries[ref]
    result = {:ok, ref}

    state =
      put_entry(state, ref, %{
        entry
        | pid: pid,
          status: :running,
          result: result,
          waiting: nil,
          waiters: []
      })

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
    remember_terminal(state, ref, %{entry | status: :completed, pid: nil, attempt: nil})
  end

  defp finish_child(state, ref, reason), do: fail(state, ref, reason)

  defp fail(state, ref, reason) do
    entry = state.entries[ref]
    stop_waiting(entry.waiting)
    result = entry.result || {:error, reason}
    Enum.each(entry.waiters, &GenServer.reply(&1, result))

    remember_terminal(state, ref, %{
      entry
      | status: :failed,
        pid: nil,
        reason: reason,
        result: result,
        attempt: nil,
        waiting: nil,
        waiters: []
    })
  end

  defp stop_waiting(nil), do: :ok
  defp stop_waiting(pid), do: Process.exit(pid, :kill)

  defp remember_terminal(%{terminal_limit: :infinity} = state, ref, entry),
    do: put_entry(state, ref, entry)

  # In-memory replay is available while the terminal record is retained.
  # Keep the command index and its record in the same eviction step.
  defp remember_terminal(state, ref, entry) do
    state = put_entry(state, ref, entry)
    terminal = :queue.in(ref, state.terminal)

    if state.terminal_count < state.terminal_limit do
      %{state | terminal: terminal, terminal_count: state.terminal_count + 1}
    else
      {{:value, oldest}, terminal} = :queue.out(terminal)
      {evicted, entries} = Map.pop(state.entries, oldest)

      %{
        state
        | terminal: terminal,
          entries: entries,
          commands: Map.delete(state.commands, evicted.command_id)
      }
    end
  end

  defp put_entry(state, ref, entry), do: %{state | entries: Map.put(state.entries, ref, entry)}
end
