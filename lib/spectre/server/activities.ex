defmodule Spectre.Server.Activities do
  @moduledoc false

  use GenServer

  alias Spectre.Server.Registry, as: ServerRegistry
  alias Spectre.Server.TaskSupervisor
  alias Spectre.Server.{Checkpoint, GAM.Managed, Skills}

  @default_terminal_limit 256

  @type child :: {module(), keyword()}
  @type ref :: String.t()
  @type entry :: %{
          status: :reserved | :starting | :running | :completed | :failed | :cancelled,
          pid: pid() | nil,
          reason: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {settings, opts} =
      Keyword.split(opts, [:registry, :terminal_limit, :managed, :activity_control])

    GenServer.start_link(__MODULE__, settings, opts)
  end

  @spec start(pid(), term(), child(), keyword()) :: {:ok, ref()} | {:error, term()}
  def start(owner, command_id, child, opts \\ []) do
    with {:ok, ref} <- reserve(owner, command_id, child, opts), do: resume(owner, ref)
  end

  @spec reserve(pid(), term(), child(), keyword()) :: {:ok, ref()} | {:error, term()}
  def reserve(owner, command_id, child, opts \\ []),
    do: GenServer.call(owner, {:reserve, command_id, child, opts})

  @spec list(pid()) :: [map()]
  def list(owner), do: GenServer.call(owner, :list)

  @spec view(pid(), term()) :: {:ok, map()} | {:error, :unknown_activity}
  def view(owner, target), do: GenServer.call(owner, {:view, target})

  @spec control(pid(), ref(), binary(), term(), keyword()) :: term()
  def control(owner, ref, id, operation, opts),
    do: GenServer.call(owner, {:control, ref, id, operation, opts}, :infinity)

  @spec submit(pid(), ref(), binary(), term(), keyword()) :: :ok
  def submit(owner, ref, id, operation, opts),
    do: GenServer.cast(owner, {:control, ref, id, operation, opts})

  @spec presentation(pid(), binary()) ::
          {:ok, pid(), reference(), non_neg_integer()} | {:error, :superseded} | :error
  def presentation(owner, ref), do: GenServer.call(owner, {:presentation, ref})

  @spec report(pid(), ref(), term()) :: :ok
  def report(owner, ref, event), do: GenServer.cast(owner, {:report, ref, self(), event})

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
         terminal_limit: limit,
         managed: opts[:managed],
         activity_control: opts[:activity_control],
         root: nil,
         root_control: nil,
         transitions: %{},
         presentations: %{},
         retired_presentations: %{}
       }}
    else
      {:stop, :invalid_terminal_limit}
    end
  end

  @impl true
  def handle_call({:reserve, command_id, child, opts}, _from, state) do
    case Map.fetch(state.commands, command_id) do
      {:ok, ref} ->
        if state.entries[ref].intent == intent(child) and state.entries[ref].key == opts[:as] and
             state.entries[ref].parent == opts[:parent],
           do: {:reply, {:ok, ref}, state},
           else: {:reply, {:error, :activity_command_conflict}, state}

      :error ->
        reserve_new(state, command_id, child, opts)
    end
  end

  def handle_call(:list, _from, state),
    do: {:reply, Enum.map(state.entries, fn {ref, entry} -> public(ref, entry) end), state}

  def handle_call({:view, target}, _from, state),
    do: {:reply, find(state, target), state}

  def handle_call({:presentation, ref}, _from, state) do
    result =
      with %{ref: activity, revision: revision} <- state.presentations[ref],
           %{status: :running, pid: pid, revision: ^revision, transition: nil} <-
             state.entries[activity],
           true <- is_pid(pid) do
        {:ok, pid, state.activity_control, revision}
      else
        _ -> if retired_presentation?(state, ref), do: {:error, :superseded}, else: :error
      end

    {:reply, result, state}
  end

  def handle_call({:control, ref, id, command, opts}, from, state) do
    case Map.get(state.entries, ref) do
      %{last_control: {^id, result}} -> {:reply, result, state}
      %{status: :running} = entry -> control_entry(state, ref, entry, id, command, opts, from)
      _ -> {:reply, {:error, :inactive_activity}, state}
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
  def handle_cast({:control, ref, id, action, opts}, state) do
    case handle_call({:control, ref, id, action, opts}, nil, state) do
      {:reply, result, state} ->
        emit_control(state, ref, id, result)
        {:noreply, state}

      {:noreply, _} = deferred ->
        deferred
    end
  end

  def handle_cast({:report, ref, caller, event}, state) do
    case state.entries[ref] do
      %{pid: ^caller, status: :running} = entry ->
        {:noreply, report_entry(state, ref, entry, event)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {__MODULE__, token, :bind_root, pid, control},
        %{activity_control: token} = state
      )
      when is_reference(token),
      do: {:noreply, %{state | root: pid, root_control: control}}

  def handle_info({monitor, result}, state) when is_map_key(state.transitions, monitor) do
    Process.demonitor(monitor, [:flush])
    {:noreply, finish_control(state, monitor, result)}
  end

  def handle_info({:DOWN, monitor, :process, _, reason}, state)
      when is_map_key(state.transitions, monitor),
      do: {:noreply, finish_control(state, monitor, {:error, reason})}

  def handle_info({:retry_control, %{ref: ref, id: id} = request}, state) do
    case state.entries[ref] do
      %{transition: ^id} = entry -> {:noreply, fence_async(state, entry, request)}
      _ -> {:noreply, state}
    end
  end

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
    {{ref, checkpoint}, children} = Map.pop(state.children, monitor)

    if checkpoint,
      do: Task.Supervisor.start_child(TaskSupervisor, fn -> Checkpoint.retire(checkpoint) end)

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

  defp reserve_new(state, command_id, child, opts) do
    key = opts[:as]

    if not is_nil(key) and Enum.any?(state.entries, fn {_, entry} -> live_key?(entry, key) end) do
      {:reply, {:error, :already_running}, state}
    else
      ref = Spectre.Identity.uuid7()

      entry = %{
        command_id: command_id,
        child: child,
        intent: intent(child),
        key: key,
        parent: opts[:parent],
        status: :reserved,
        pid: nil,
        reason: nil,
        result: nil,
        attempt: nil,
        waiting: nil,
        waiters: [],
        revision: 0,
        transition: nil,
        last_control: nil
      }

      state = %{state | commands: Map.put(state.commands, command_id, ref)}
      {:reply, {:ok, ref}, put_entry(state, ref, entry)}
    end
  end

  defp intent(child), do: :crypto.hash(:sha256, :erlang.term_to_binary(child))

  defp live_key?(entry, key),
    do: entry.key == key and entry.status in [:reserved, :starting, :running]

  defp public(ref, entry),
    do: %{
      ref: ref,
      key: entry.key,
      parent: entry.parent,
      status: entry.status,
      revision: entry.revision
    }

  defp find(state, target) do
    case Map.fetch(state.entries, target) do
      {:ok, entry} ->
        {:ok, public(target, entry)}

      :error ->
        find_key(state, target)
    end
  end

  defp find_key(_state, nil), do: {:error, :unknown_activity}

  defp find_key(state, target) do
    case Enum.find(state.entries, fn {_, entry} -> live_key?(entry, target) end) do
      {ref, entry} -> {:ok, public(ref, entry)}
      nil -> {:error, :unknown_activity}
    end
  end

  defp control_entry(state, ref, entry, id, command, opts, from) do
    expected = Keyword.get(opts, :if_revision, entry.revision)

    cond do
      entry.transition == id ->
        {:reply, {:pending, id}, state}

      entry.transition ->
        {:reply, {:error, :activity_busy}, state}

      expected != entry.revision ->
        {:reply, {:error, :superseded}, state}

      fenced?(command) ->
        start_control(state, ref, entry, id, command, List.wrap(from))

      true ->
        send(
          entry.pid,
          {__MODULE__, state.activity_control, :signal, entry.revision, elem(command, 1)}
        )

        result = {:ok, public(ref, entry)}
        {:reply, result, put_entry(state, ref, %{entry | last_control: {id, result}})}
    end
  end

  defp fenced?({:signal, {:revise, _}}), do: true
  defp fenced?(command), do: command == :cancel or match?({:failed, _}, command)

  defp start_control(state, ref, entry, id, command, from) do
    if is_pid(entry.pid),
      do: send(entry.pid, {__MODULE__, state.activity_control, :pause, entry.revision})

    entry = %{entry | transition: id}
    request = %{ref: ref, id: id, command: command, from: from}
    {:noreply, state |> put_entry(ref, entry) |> fence_async(entry, request)}
  end

  defp fence_async(state, entry, request) do
    %{managed: managed, activity_control: control} = state
    revision = entry.revision

    task =
      Task.Supervisor.async_nolink(TaskSupervisor, fn ->
        kind = if match?({:signal, _}, request.command), do: :revise, else: :cancel

        Managed.fence_activity(managed, control, %{
          ref: request.ref,
          revision: revision,
          transition_id: request.id,
          kind: kind
        })
      end)

    %{state | transitions: Map.put(state.transitions, task.ref, request)}
  end

  defp finish_control(state, monitor, result) do
    {%{ref: ref, id: id} = request, transitions} = Map.pop(state.transitions, monitor)
    state = %{state | transitions: transitions}

    if retry_fence?(result) do
      Enum.each(request.from, &GenServer.reply(&1, {:pending, id}))
      Process.send_after(self(), {:retry_control, %{request | from: []}}, 1_000)
      state
    else
      complete_control(state, ref, id, request, result)
    end
  end

  defp retry_fence?({:ok, _}), do: false

  defp retry_fence?({:error, reason}),
    do:
      reason not in [
        :superseded,
        :unknown_activity,
        :activity_transition_conflict,
        :invalid_activity_fence
      ]

  defp complete_control(state, ref, id, request, result) do
    {reply, state} = control_result(state, ref, request.command, result)
    Enum.each(request.from, &GenServer.reply(&1, reply))

    if match?({:signal, _}, request.command) or request.command == :cancel,
      do: emit_control(state, ref, id, reply)

    case state.entries[ref] do
      nil ->
        state

      %{transition: ^id} = entry ->
        put_entry(state, ref, %{entry | transition: nil, last_control: {id, reply}})

      _ ->
        state
    end
  end

  defp emit_control(state, ref, id, result) do
    if entry = state.entries[ref], do: emit(state, ref, entry, {:signalled, id, result})
  end

  defp control_result(state, ref, {:signal, signal}, {:ok, revision}) do
    entry = %{state.entries[ref] | revision: revision}

    if is_pid(entry.pid) do
      send(entry.pid, {__MODULE__, state.activity_control, :signal, revision, signal})
      {{:ok, public(ref, entry)}, state |> clear_presentations(ref) |> put_entry(ref, entry)}
    else
      {:noreply, state} =
        start_control(
          state,
          ref,
          entry,
          Spectre.Identity.uuid7(),
          {:failed, entry.exit_reason},
          []
        )

      {{:error, :inactive_activity}, state}
    end
  end

  defp control_result(state, ref, :cancel, {:ok, revision}) do
    entry = %{state.entries[ref] | revision: revision}

    if is_pid(entry.pid),
      do: send(entry.pid, {__MODULE__, state.activity_control, :cancel, revision})

    state = terminal(state, ref, entry, :cancelled, :cancelled)
    {{:ok, %{ref: ref, key: entry.key, status: :cancelled, revision: revision}}, state}
  end

  defp control_result(state, ref, {status, _} = event, {:ok, revision})
       when status in [:completed, :failed] do
    entry = %{state.entries[ref] | revision: revision}
    {:ok, terminal(state, ref, entry, status, event)}
  end

  defp control_result(state, ref, _command, error) do
    entry = state.entries[ref]

    if is_pid(entry.pid),
      do: send(entry.pid, {__MODULE__, state.activity_control, :cancel, entry.revision + 1})

    {error, terminal(state, ref, entry, :failed, {:failed, error})}
  end

  defp report_entry(state, ref, entry, {:pending, presentation, show_ref}) do
    emit(state, ref, entry, {:pending, presentation})

    %{
      state
      | presentations:
          Map.put(state.presentations, presentation, %{
            ref: ref,
            revision: entry.revision,
            show_ref: show_ref
          })
    }
  end

  defp report_entry(state, _ref, _entry, {:closed, presentation}),
    do: %{state | presentations: Map.delete(state.presentations, presentation)}

  defp report_entry(state, _ref, _entry, {:close_stale, show_ref}) do
    close_show(state, show_ref)
    state
  end

  defp report_entry(state, ref, %{transition: nil} = entry, {status, _} = event)
       when status in [:completed, :failed] do
    {:noreply, state} = start_control(state, ref, entry, Spectre.Identity.uuid7(), event, [])
    state
  end

  defp report_entry(state, ref, entry, {:effect, _} = event) do
    emit(state, ref, entry, event)
    state
  end

  defp report_entry(state, _ref, _entry, _event), do: state

  defp emit(%{root: root} = state, ref, entry, event) when is_pid(root) do
    send(root, {__MODULE__, state.root_control, :lifecycle, public(ref, entry), event})
  end

  defp emit(_state, _ref, _entry, _event), do: :ok

  defp clear_presentations(state, ref) do
    {closed, open} = Enum.split_with(state.presentations, fn {_, data} -> data.ref == ref end)

    if closed == [] do
      state
    else
      Enum.each(closed, fn {_, data} -> close_show(state, data.show_ref) end)
      retired = Map.put(state.retired_presentations, ref, Enum.map(closed, &elem(&1, 0)))
      %{state | presentations: Map.new(open), retired_presentations: retired}
    end
  end

  defp retired_presentation?(state, ref),
    do:
      Enum.any?(state.retired_presentations, fn {_, refs} -> ref in refs end) or
        match?(%{ref: activity} when not is_nil(activity), state.presentations[ref])

  defp close_show(%{managed: managed, activity_control: control}, show) when is_binary(show),
    do:
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        Managed.close_activity_show(managed, control, show)
      end)

  defp close_show(_state, _show), do: :ok

  defp terminal(state, ref, entry, status, event) do
    entry = %{entry | status: status, pid: nil, attempt: nil, child: nil}
    emit(state, ref, entry, event)
    state |> clear_presentations(ref) |> remember_terminal(ref, entry)
  end

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
        child = {module, child_options(opts, owner, ref, entry.key, name)}

        registration = if state.managed, do: {state.managed, state.activity_control, ref}

        task =
          Task.Supervisor.async_nolink(TaskSupervisor, fn ->
            launch_child(child, {supervisor, owner, token}, registration)
          end)

        state = put_entry(state, ref, %{entry | status: :starting, attempt: attempt})
        {:noreply, %{state | launches: Map.put(state.launches, task.ref, ref)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp launch_child(child, {supervisor, owner, token}, registration) do
    with :ok <- register(registration) do
      spec = Supervisor.child_spec(child, restart: :temporary)
      wrapped = %{spec | start: {__MODULE__, :start_waiting, [spec.start, owner, token]}}
      DynamicSupervisor.start_child(supervisor, wrapped)
    end
  end

  defp register(nil), do: :ok
  defp register({managed, control, ref}), do: Managed.register_activity(managed, control, ref)

  defp child_options(opts, owner, ref, key, name) do
    opts = Keyword.put(opts, :name, name)

    case opts[:activity] do
      nil ->
        opts

      binding ->
        binding = Map.merge(binding, %{owner: owner, ref: ref, key: key, revision: 0})

        opts
        |> Keyword.put(:activity, binding)
        |> Keyword.update(:checkpoint, nil, &Skills.checkpoint(&1, {:activity, ref}))
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
    checkpoint = child_checkpoint(entry.child, ref)
    result = {:ok, ref}

    state =
      put_entry(state, ref, %{
        entry
        | pid: pid,
          status: :running,
          result: result,
          child: nil,
          waiting: nil,
          waiters: []
      })

    # The child stays inert until the owner has adopted it.
    if state.activity_control,
      do: send(pid, {__MODULE__, state.activity_control, :activate, ref}),
      else: send(pid, {:spectre_activity, :activate, ref})

    emit(state, ref, state.entries[ref], :started)
    Enum.each(entry.waiters, &GenServer.reply(&1, result))
    %{state | children: Map.put(state.children, monitor, {ref, checkpoint})}
  end

  defp adopt(state, ref, {:ok, pid, _info}), do: adopt(state, ref, {:ok, pid})
  defp adopt(state, ref, {:error, reason}), do: fail(state, ref, reason)
  defp adopt(state, ref, :ignore), do: fail(state, ref, :activity_start_ignored)

  defp child_checkpoint({Spectre.Server.Runtime, opts}, ref),
    do: Skills.checkpoint(opts[:checkpoint], {:activity, ref})

  defp child_checkpoint(_child, _ref), do: nil

  defp finish_child(state, ref, reason) do
    reason = child_exit(reason)

    case state.entries[ref] do
      %{status: :running, transition: transition} = entry when not is_nil(transition) ->
        put_entry(state, ref, Map.merge(entry, %{pid: nil, exit_reason: reason}))

      %{status: :running} = entry when is_pid(state.managed) ->
        {:noreply, state} =
          start_control(
            state,
            ref,
            %{entry | pid: nil},
            Spectre.Identity.uuid7(),
            {:failed, reason},
            []
          )

        state

      %{status: :running} = entry when reason == :normal ->
        terminal(state, ref, entry, :completed, {:completed, nil})

      %{status: :running} ->
        fail(state, ref, reason)

      _ ->
        state
    end
  end

  defp child_exit(reason) when reason in [:normal, :shutdown, :killed], do: reason
  defp child_exit(_reason), do: :activity_crashed

  defp fail(state, ref, reason) do
    entry = state.entries[ref]
    stop_waiting(entry.waiting)
    result = entry.result || {:error, reason}
    Enum.each(entry.waiters, &GenServer.reply(&1, result))

    terminal(
      state,
      ref,
      %{
        entry
        | status: :failed,
          pid: nil,
          reason: reason,
          result: result,
          attempt: nil,
          waiting: nil,
          waiters: []
      },
      :failed,
      {:failed, reason}
    )
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
      retire_fence(state, oldest)

      %{
        state
        | terminal: terminal,
          entries: entries,
          retired_presentations: Map.delete(state.retired_presentations, oldest),
          commands: Map.delete(state.commands, evicted.command_id)
      }
    end
  end

  defp retire_fence(%{managed: nil}, _ref), do: :ok

  defp retire_fence(%{managed: managed, activity_control: control}, ref),
    do:
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        Managed.retire_activity(managed, control, ref)
      end)

  defp put_entry(state, ref, entry), do: %{state | entries: Map.put(state.entries, ref, entry)}
end
