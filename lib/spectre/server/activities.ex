defmodule Spectre.Server.Activities do
  @moduledoc false

  use GenServer

  alias Spectre.Server.{Checkpoint, Delivery, GAM.Managed, InputWait, Skills, TaskSupervisor}
  alias Spectre.Server.Registry, as: ServerRegistry

  @default_terminal_limit 256
  @event_limit 256

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

  @doc false
  @spec validate_input(pid(), binary(), {binary(), pos_integer()}) :: :ok | {:error, atom()}
  def validate_input(owner, ref, target),
    do: GenServer.call(owner, {:validate_input, ref, target})

  @doc false
  @spec input(pid(), nil | {binary(), {binary(), pos_integer()}}, Spectre.Input.t()) ::
          :ok | :unmatched | {:error, atom()}
  def input(owner, target, input), do: GenServer.call(owner, {:input, target, input})

  @spec report(pid(), ref(), term()) :: :ok
  def report(owner, ref, event), do: GenServer.cast(owner, {:report, ref, self(), event})

  @doc false
  @spec finish(pid(), ref(), non_neg_integer(), term()) :: :ok | :superseded | {:error, atom()}
  def finish(owner, ref, revision, event) do
    GenServer.call(owner, {:finish, ref, revision, event})
  catch
    :exit, _ -> {:error, :activity_owner_unavailable}
  end

  @doc false
  @spec acknowledge(pid(), reference(), binary()) :: :ok
  def acknowledge(owner, control, id), do: GenServer.cast(owner, {:ack, self(), control, id})

  @doc false
  @spec replace_storage(pid(), reference()) :: :ok | {:error, :untrusted_activity_transport}
  def replace_storage(owner, control), do: GenServer.call(owner, {:replace_storage, control})

  @doc false
  @spec resume_delivery(pid(), reference(), reference()) :: :ok
  def resume_delivery(owner, control, generation),
    do: GenServer.cast(owner, {:resume_delivery, self(), control, generation})

  @doc false
  @spec track_effect({pid(), reference()}, ref(), binary(), pid()) :: :ok | {:error, atom()}
  def track_effect({owner, control}, ref, id, worker) do
    GenServer.call(owner, {:track_effect, control, ref, id, worker})
  catch
    :exit, _ -> {:error, :activity_owner_unavailable}
  end

  @doc false
  @spec settle_effect({pid(), reference()}, term()) :: :ok
  def settle_effect({owner, control}, result),
    do: GenServer.cast(owner, {:settle_effect, control, self(), effect_result(result)})

  defp effect_result({:governed, %{act: act}} = result) when not is_nil(act), do: result

  defp effect_result({:governed, %{proposal: %{fallback: %{result: fallback}} = proposal}})
       when not is_nil(fallback.act),
       do: {:governed, Map.put(Map.from_struct(fallback), :proposal, proposal)}

  defp effect_result({:error, reason})
       when reason in [
              :ambiguous_commit_unresolved,
              :admission_not_recovered,
              :invalid_outcome_record_response,
              :recorded_outcome_mismatch
            ],
       do: :unknown

  defp effect_result({:error, {reason, _}})
       when reason in [
              :invalid_recorded_outcome,
              :outcome_record_failed,
              :outcome_record_boundary_failure
            ],
       do: :unknown

  defp effect_result(_result), do: :no_effect

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
         delivery_paused: false,
         events: :queue.new(),
         effect_workers: %{},
         retired_checkpoints: %{},
         unconfirmed_effects: %{},
         transitions: %{},
         input_waits: %{},
         input_focus: nil,
         presentations: %{},
         retired_presentations: %{}
       }}
    else
      {:stop, :invalid_terminal_limit}
    end
  end

  @impl true
  def handle_call({:reserve, command_id, child, opts}, _from, %{managed: managed} = state)
      when is_pid(managed) do
    if opts[:generation] == state.activity_control,
      do: reserve_entry(state, command_id, child, opts),
      else: {:reply, {:error, :gam_storage_recovered}, state}
  end

  def handle_call({:reserve, command_id, child, opts}, _from, state) do
    reserve_entry(state, command_id, child, opts)
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

  def handle_call({:validate_input, ref, target}, {root, _}, %{root: root} = state) do
    {:reply, if(input_recipient(state, ref, target), do: :ok, else: {:error, :stale_pending}),
     state}
  end

  def handle_call({:validate_input, _, _}, _from, state),
    do: {:reply, {:error, :untrusted_activity_transport}, state}

  def handle_call({:input, nil, input}, {root, _}, %{root: root} = state) do
    with ref when is_binary(ref) <- state.input_focus,
         %{id: id, revision: revision, accept: matcher} <- state.input_waits[ref],
         true <- InputWait.matches?(matcher, input.text),
         {pid, activity_revision} <- input_recipient(state, ref, {id, revision}) do
      deliver_input(state, ref, pid, activity_revision, {id, revision}, input)
    else
      _ -> {:reply, :unmatched, %{state | input_focus: nil}}
    end
  end

  def handle_call({:input, {ref, target}, input}, {root, _}, %{root: root} = state) do
    case input_recipient(state, ref, target) do
      {pid, revision} -> deliver_input(state, ref, pid, revision, target, input)
      nil -> {:reply, {:error, :stale_pending}, state}
    end
  end

  def handle_call({:input, _, _}, _from, state),
    do: {:reply, {:error, :untrusted_activity_transport}, state}

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

  def handle_call({:finish, ref, revision, {status, _} = event}, {caller, _}, state)
      when status in [:completed, :failed] do
    case state.entries[ref] do
      %{pid: ^caller, status: :running, revision: ^revision} = entry ->
        {:reply, :ok, report_entry(state, ref, entry, event)}

      %{pid: ^caller, status: :running} = entry ->
        {:reply, :superseded, emit(state, ref, entry, {:superseded, revision, event})}

      _ ->
        {:reply, {:error, :inactive_activity}, state}
    end
  end

  def handle_call({:replace_storage, control}, {managed, _}, %{managed: managed} = state)
      when is_reference(control) do
    {:reply, :ok, close_storage_generation(state, control)}
  end

  def handle_call({:replace_storage, _}, _from, state),
    do: {:reply, {:error, :untrusted_activity_transport}, state}

  def handle_call(
        {:track_effect, control, ref, id, worker},
        {managed, _},
        %{managed: managed, activity_control: control} = state
      )
      when is_reference(control) do
    {:reply, :ok, track_effect_worker(state, ref, id, worker, control)}
  end

  def handle_call({:track_effect, _, _, _, _}, _from, state),
    do: {:reply, {:error, :untrusted_activity_transport}, state}

  @impl true
  def handle_cast({:control, ref, id, action, opts}, state) do
    case handle_call({:control, ref, id, action, opts}, nil, state) do
      {:reply, result, state} ->
        {:noreply, emit_control(state, ref, id, result)}

      {:noreply, _} = deferred ->
        deferred
    end
  end

  def handle_cast({:ack, pid, control, id}, %{root: pid, root_control: control} = state),
    do:
      {:noreply,
       %{state | events: :queue.filter(fn {event_id, _, _} -> event_id != id end, state.events)}}

  def handle_cast({:ack, _, _, _}, state), do: {:noreply, state}

  def handle_cast(
        {:resume_delivery, pid, control, generation},
        %{root: pid, root_control: control, delivery_paused: true, activity_control: generation} =
          state
      ),
      do: {:noreply, resume_events(state)}

  def handle_cast({:resume_delivery, _, _, _}, state), do: {:noreply, state}

  def handle_cast({:settle_effect, control, worker, result}, state) do
    case state.effect_workers[worker] do
      %{control: ^control} = work -> {:noreply, settle_effect_worker(state, worker, work, result)}
      _ -> {:noreply, state}
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
      when is_reference(token) do
    if state.root != pid or state.root_control != control do
      state = %{state | root: pid, root_control: control}
      {:noreply, resume_events(state)}
    else
      {:noreply, state}
    end
  end

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
    state = %{state | children: children} |> finish_child(ref, reason)
    state = put_in(state.retired_checkpoints[ref], checkpoint)
    {:noreply, retire_settled_checkpoint(state, ref)}
  end

  def handle_info({:DOWN, monitor, :process, worker, _}, state)
      when is_map_key(state.effect_workers, worker) do
    case state.effect_workers[worker] do
      %{monitor: ^monitor} = work ->
        {:noreply, settle_effect_worker(state, worker, work, :unknown)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{registry_monitor: monitor} = state) do
    Process.exit(state.supervisor, :shutdown)
    {:noreply, %{state | registry: nil, registry_monitor: nil}}
  end

  def handle_info({:EXIT, supervisor, _}, %{supervisor: supervisor} = state) do
    if state.registry_monitor, do: Process.demonitor(state.registry_monitor, [:flush])
    {:noreply, %{state | supervisor: nil, registry: nil, registry_monitor: nil}}
  end

  def handle_info({:EXIT, managed, reason}, %{managed: managed} = state),
    do: {:stop, reason, state}

  def handle_info({:EXIT, _old_branch, _reason}, %{managed: managed} = state)
      when is_pid(managed),
      do: {:noreply, state}

  def handle_info({:EXIT, _parent, reason}, state), do: {:stop, reason, state}
  def handle_info(_, state), do: {:noreply, state}

  defp track_effect_worker(state, ref, id, worker, control) do
    case state.entries[ref] do
      nil ->
        state

      entry ->
        work = %{
          ref: ref,
          id: id,
          identity: public(ref, entry),
          control: control,
          monitor: Process.monitor(worker)
        }

        put_in(state.effect_workers[worker], work)
    end
  end

  defp settle_effect_worker(state, worker, work, result) do
    Process.demonitor(work.monitor, [:flush])
    state = %{state | effect_workers: Map.delete(state.effect_workers, worker)}
    state |> record_effect(work, result) |> retire_settled_checkpoint(work.ref)
  end

  defp record_effect(state, work, {:governed, data} = result) do
    id = "activity-effect:" <> Delivery.result_key(result, work.id)

    confirmed? = match?(%{status: status} when status != :ambiguous, data.outcome)
    state = if confirmed?, do: resolve_effect(state, work), else: retain_effect(state, work)
    emit_effect(state, work, id, result)
  end

  defp record_effect(state, work, :unknown) do
    state
    |> retain_effect(work)
    |> emit_effect(
      work,
      unknown_effect_id(work.id),
      {:governed_unknown, %{command_id: work.id}}
    )
  end

  defp record_effect(state, _work, :no_effect), do: state

  defp unknown_effect_id(id), do: "activity-unknown:" <> id

  defp emit_effect(state, work, id, result) do
    identity =
      if entry = state.entries[work.ref], do: public(work.ref, entry), else: work.identity

    enqueue_event(state, id, identity, {:effect, result})
  end

  defp retain_effect(state, work),
    do:
      update_in(
        state.unconfirmed_effects,
        &Map.update(&1, work.ref, MapSet.new([work.id]), fn ids -> MapSet.put(ids, work.id) end)
      )

  defp resolve_effect(state, work) do
    case state.unconfirmed_effects[work.ref] do
      nil ->
        state

      ids ->
        remaining = MapSet.delete(ids, work.id)

        if MapSet.size(remaining) == 0,
          do: %{state | unconfirmed_effects: Map.delete(state.unconfirmed_effects, work.ref)},
          else: put_in(state.unconfirmed_effects[work.ref], remaining)
    end
  end

  defp retire_settled_checkpoint(state, ref) do
    if Map.has_key?(state.retired_checkpoints, ref) and
         not match?(%{status: :running}, state.entries[ref]) and
         not Enum.any?(state.effect_workers, fn {_, work} -> work.ref == ref end) do
      {checkpoint, checkpoints} = Map.pop(state.retired_checkpoints, ref)
      {unconfirmed, remaining} = Map.pop(state.unconfirmed_effects, ref)
      retire_checkpoint(checkpoint, unconfirmed)

      %{state | retired_checkpoints: checkpoints, unconfirmed_effects: remaining}
    else
      state
    end
  end

  defp retire_checkpoint(checkpoint, nil) when not is_nil(checkpoint),
    do: Task.Supervisor.start_child(TaskSupervisor, fn -> Checkpoint.retire(checkpoint) end)

  defp retire_checkpoint(_checkpoint, _unconfirmed), do: :ok

  defp close_storage_generation(state, control) do
    state = %{state | delivery_paused: true}

    if state.supervisor do
      Process.unlink(state.supervisor)
      Process.exit(state.supervisor, :shutdown)
    end

    if state.registry_monitor, do: Process.demonitor(state.registry_monitor, [:flush])

    Enum.each(state.transitions, fn {monitor, request} ->
      Process.demonitor(monitor, [:flush])
      Enum.each(request.from, &GenServer.reply(&1, {:error, :gam_storage_recovered}))
    end)

    Enum.each(state.launches, fn {monitor, _ref} -> Process.demonitor(monitor, [:flush]) end)

    state =
      Enum.reduce(state.entries, state, fn
        {ref, %{status: status}}, acc when status in [:starting, :reserved, :running] ->
          fail(acc, ref, :gam_storage_recovered)

        _, acc ->
          acc
      end)

    %{
      state
      | supervisor: nil,
        registry: nil,
        registry_monitor: nil,
        activity_control: control,
        transitions: %{},
        launches: %{}
    }
  end

  defp reserve_new(state, command_id, child, opts) do
    key = opts[:as]

    if not is_nil(key) and Enum.any?(state.entries, fn {_, entry} -> live_key?(entry, key) end) do
      {:reply, {:error, :already_running}, state}
    else
      ref = Spectre.Identity.uuid7()

      entry = %{
        command_id: command_id,
        child: child,
        intent: intent(child, opts),
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

  defp intent(child, opts),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Keyword.get(opts, :intent, child), [:deterministic])
      )

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

    state =
      if match?({:signal, _}, request.command) or request.command == :cancel,
        do: emit_control(state, ref, id, reply),
        else: state

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
    if entry = state.entries[ref],
      do: emit(state, ref, entry, {:signalled, id, result}),
      else: state
  end

  defp control_result(state, ref, {:signal, signal}, {:ok, revision}) do
    entry = %{state.entries[ref] | revision: revision}

    if is_pid(entry.pid) and not Map.has_key?(entry, :terminal_report) do
      send(entry.pid, {__MODULE__, state.activity_control, :signal, revision, signal})
      state = state |> clear_presentations(ref) |> clear_input(ref) |> put_entry(ref, entry)
      {{:ok, public(ref, entry)}, state}
    else
      {:noreply, state} =
        start_control(
          state,
          ref,
          entry,
          Spectre.Identity.uuid7(),
          child_terminal_report(entry, Map.get(entry, :exit_reason, :normal)),
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
    state = emit(state, ref, entry, {:pending, presentation})

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

  defp report_entry(state, ref, %{revision: revision} = entry, {:waiting_input, revision, wait}) do
    focus = if wait.accept, do: ref, else: state.input_focus

    %{state | input_waits: Map.put(state.input_waits, ref, wait), input_focus: focus}
    |> emit(ref, entry, {:waiting_input, InputWait.public(wait)})
  end

  defp report_entry(state, ref, _entry, {:closed_input, id}) do
    case state.input_waits[ref] do
      %{id: ^id} -> clear_input(state, ref)
      _ -> state
    end
  end

  defp report_entry(state, ref, %{transition: nil} = entry, {status, _} = event)
       when status in [:completed, :failed] do
    {:noreply, state} = start_control(state, ref, entry, Spectre.Identity.uuid7(), event, [])
    state
  end

  defp report_entry(state, ref, entry, {status, _} = event) when status in [:completed, :failed],
    do: put_entry(state, ref, Map.put_new(entry, :terminal_report, event))

  defp report_entry(state, ref, entry, {:effect, {:governed_unknown, %{command_id: id}}} = event),
    do: enqueue_event(state, unknown_effect_id(id), public(ref, entry), event)

  defp report_entry(state, _ref, _entry, _event), do: state

  defp emit(%{managed: nil, root: nil} = state, _ref, _entry, _event), do: state

  defp emit(state, ref, entry, event) do
    enqueue_event(state, Spectre.Identity.uuid7(), public(ref, entry), event)
  end

  defp enqueue_event(state, id, identity, event) do
    message = {id, Map.put(identity, :event_id, id), event}
    deliver_event(state, message)
    events = :queue.in(message, state.events)
    events = if :queue.len(events) > @event_limit, do: :queue.drop(events), else: events
    %{state | events: events}
  end

  defp resume_events(state) do
    state = %{state | delivery_paused: false}
    Enum.each(:queue.to_list(state.events), &deliver_event(state, &1))
    state
  end

  defp deliver_event(%{root: root, delivery_paused: false} = state, {id, identity, event})
       when is_pid(root),
       do: send(root, {__MODULE__, state.root_control, :lifecycle, self(), id, identity, event})

  defp deliver_event(_state, _message), do: :ok

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

  defp input_recipient(state, ref, {id, revision}) do
    with %{status: :running, transition: nil, pid: pid, revision: current} <- state.entries[ref],
         %{id: ^id, revision: ^revision} = wait <- state.input_waits[ref],
         true <- is_pid(pid) and InputWait.live?(wait) do
      {pid, current}
    else
      _ -> nil
    end
  end

  defp deliver_input(state, ref, pid, revision, target, input) do
    send(pid, {__MODULE__, state.activity_control, :reply_input, revision, target, input})
    {:reply, :ok, clear_input(state, ref)}
  end

  defp clear_input(state, ref) do
    focus = if state.input_focus == ref, do: nil, else: state.input_focus
    %{state | input_waits: Map.delete(state.input_waits, ref), input_focus: focus}
  end

  defp close_show(%{managed: managed, activity_control: control}, show) when is_binary(show),
    do:
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        Managed.close_activity_show(managed, control, show)
      end)

  defp close_show(_state, _show), do: :ok

  defp terminal(state, ref, entry, status, event) do
    entry = %{entry | status: status, pid: nil, attempt: nil, child: nil}

    state
    |> emit(ref, entry, event)
    |> clear_presentations(ref)
    |> clear_input(ref)
    |> remember_terminal(ref, entry)
    |> retire_settled_checkpoint(ref)
  end

  defp reserve_entry(state, command_id, child, opts) do
    case Map.fetch(state.commands, command_id) do
      {:ok, ref} ->
        if state.entries[ref].intent == intent(child, opts) and
             state.entries[ref].key == opts[:as] and
             state.entries[ref].parent == opts[:parent],
           do: {:reply, {:ok, ref}, state},
           else: {:reply, {:error, :activity_command_conflict}, state}

      :error ->
        reserve_new(state, command_id, child, opts)
    end
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

    state = emit(state, ref, state.entries[ref], :started)
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
            child_terminal_report(entry, reason),
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

  defp child_terminal_report(%{terminal_report: report}, _reason), do: report
  defp child_terminal_report(_entry, :normal), do: {:completed, nil}
  defp child_terminal_report(_entry, reason), do: {:failed, reason}

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
