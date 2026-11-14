defmodule Spectre.Server.Runtime do
  @moduledoc """
  Internal OTP owner of an agent conversation.

  Applications start through `Spectre.Server.start_link/1`, which owns the
  automatic GAM configuration boundary. Direct runtime construction exists for
  supervised Skill wiring and isolated protocol tests, not application setup.

  Application callbacks run in this process. Routing, cognitive services,
  actor calls and the internal GAM adapter run in monitored workers. Each result
  carries a runtime-owned reference and its original interaction. Application
  callbacks cannot intercept internal worker messages accidentally.
  """
  use GenServer

  alias Spectre.Server.GAM.Managed

  alias Spectre.Server.{
    Checkpoint,
    Command,
    Context,
    Delivery,
    Failure,
    Inbox,
    Operations,
    PendingLifecycle,
    Skills,
    Tool
  }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    result =
      GenServer.start(
        __MODULE__,
        {opts, self()},
        Keyword.take(opts, [:name, :debug, :spawn_opt, :hibernate_after])
      )

    case result do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      {:error, _} = error ->
        error

      :ignore ->
        :ignore
    end
  end

  @impl true
  def init({opts, owner}) do
    Process.put({__MODULE__, :startup_owner}, {owner, Process.monitor(owner)})
    init(opts)
  end

  def init(opts) do
    state = opts |> initial_state() |> Checkpoint.load() |> Tool.validate_persisted!()
    send(self(), {__MODULE__, state.control, :recover})

    case start_skills(state) do
      {:ok, state} ->
        register_skill(state)
        init_application(state)

      {:error, reason} ->
        {:stop, {:skills_start_failed, reason}}
    end
  catch
    {:managed_gam_start_failed, reason} -> {:stop, reason}
  end

  @spec start_skills(map()) :: {:ok, map()} | {:error, term()}
  defp start_skills(state) do
    if Keyword.has_key?(state.opts, :skill) or Skills.mounts(state.agent) == [] do
      {:ok, state}
    else
      with {:ok, gam} <- Spectre.Server.GAM.pin_domain(state.gam, service_context(state, nil)),
           state = %{state | gam: gam},
           {:ok, supervisor} <- Skills.start_link(state) do
        {:ok, %{state | skill_supervisor: supervisor}}
      end
    end
  end

  @spec register_skill(map()) :: :ok
  defp register_skill(state) do
    case Keyword.get(state.opts, :skill_parent) do
      {parent, token} ->
        send(parent, {__MODULE__, token, :skill_started, state.opts[:skill].id, self()})

      nil ->
        :ok
    end

    :ok
  end

  defp initial_state(opts) do
    agent = Keyword.fetch!(opts, :agent)
    Code.ensure_loaded!(agent)
    server = Keyword.get(opts, :server) || server_binding(agent)
    Code.ensure_loaded!(server)
    opts = Keyword.merge(server_options(server), opts)
    Spectre.Server.Contracts.validate_configuration!(server)
    Spectre.Server.PermissionDiagnostics.validate_options!(agent, opts)
    state = new_state(agent, server, opts) |> setup_managed_gam()
    validate_initial_state!(state)
    Map.put(state, :tool_bindings, Tool.bindings!(state))
  end

  @spec setup_managed_gam(map()) :: map()
  defp setup_managed_gam(%{gam: config} = state) when is_list(config) do
    options =
      config
      |> Keyword.put(:agent, state.agent)
      |> Keyword.put(:identity, state.identity)
      |> Keyword.put(:consumer, state.consumer)
      |> Keyword.put(:runtime, self())
      |> Keyword.put(:options, Keyword.drop(state.opts, [:gam, :assigns, :identity]))
      |> Keyword.put(:stack_runtime, Keyword.get(state.opts, :stack_runtime))

    case Managed.start_link(options) do
      {:ok, pid} ->
        opts =
          if Keyword.get(state.opts, :checkpoint),
            do: state.opts,
            else: Keyword.put(state.opts, :checkpoint, Managed.runtime_checkpoint(pid))

        Map.merge(state, %{gam: {Managed, [server: pid]}, managed_owner: pid, opts: opts})

      {:error, reason} ->
        throw({:managed_gam_start_failed, reason})
    end
  end

  defp setup_managed_gam(state), do: Map.put(state, :managed_owner, nil)

  defp server_options(server) do
    if function_exported?(server, :__spectre_server_options__, 0),
      do: server.__spectre_server_options__(),
      else: []
  end

  defp new_state(agent, server, opts) do
    %{
      agent: agent,
      server: server,
      runtime_pid: self(),
      identity: Keyword.get(opts, :identity, %{}),
      assigns: Keyword.get(opts, :assigns, %{}),
      private: %{},
      opts: Keyword.delete(opts, :private),
      services: Map.new(Keyword.get(opts, :services, [])),
      consumer: Keyword.get(opts, :consumer),
      gam: Keyword.get(opts, :gam),
      skill_supervisor: nil,
      skill_pids: %{},
      skill_current: %{},
      skill_pid_order: [],
      workers: %{},
      pending: %{},
      pending_timers: %{},
      close_timers: %{},
      foreground: nil,
      current: nil,
      queue: :queue.new(),
      queue_limit: Keyword.get(opts, :queue_limit, 32),
      max_steps: Keyword.get(opts, :max_steps, 32),
      control: make_ref(),
      sequence: 0,
      history: [],
      current_flow: nil,
      current_scope: nil,
      outbox: %{},
      inbox: %{},
      seen_events: %{},
      external_submissions: %{},
      submission_epoch: Spectre.Identity.uuid7(),
      seen_event_order: [],
      dead_letters: %{},
      operations: %{},
      memory_dirty: %{},
      released_commands: [],
      checkpoint_revision: nil,
      active_command: nil,
      processing_result: nil,
      startup_owner: Process.get({__MODULE__, :startup_owner})
    }
  end

  defp validate_initial_state!(state) do
    unless is_map(state.identity) and is_map(state.assigns) and
             is_integer(state.queue_limit) and state.queue_limit >= 0 and
             is_integer(state.max_steps) and state.max_steps > 0 do
      raise ArgumentError, "invalid Server identity, assigns or limits"
    end
  end

  defp init_application(state) do
    {ctx, dispatch} = context(state, nil)

    result = Failure.capture(fn -> prepare_init(state, ctx, dispatch) end)

    case result do
      {:ok, {:ok, prepared}} -> {:ok, commit_acquisition(prepared)}
      {:ok, {:ok, prepared, action}} -> {:ok, commit_acquisition(prepared), action}
      {:ok, other} -> other
      {:error, reason} -> {:stop, reason}
    end
  end

  defp prepare_init(state, ctx, dispatch) do
    case state.server.init(Keyword.get(state.opts, :init_arg), ctx) do
      {:ok, returned} ->
        {:ok, prepare_acquisition(state, returned, dispatch)}

      {:ok, returned, action} ->
        {:ok, prepare_acquisition(state, returned, dispatch), otp_action(action)}

      :ignore ->
        :ignore

      {:stop, reason} ->
        {:stop, reason}

      other ->
        {:stop, {:invalid_init_return, other}}
    end
  end

  @impl true
  def handle_call({__MODULE__, :gam_view}, {caller, _}, state) do
    {:reply, diagnostic_managed_call(state, :view, [caller]), state}
  end

  def handle_call({__MODULE__, :gam_inspect, opts}, {caller, _}, state) do
    result =
      if caller == state.consumer and not Keyword.has_key?(state.opts, :skill),
        do: diagnostic_managed_call(state, :diagnostics, [opts, caller]),
        else: {:error, :untrusted_audit_transport}

    {:reply, result, state}
  end

  def handle_call({__MODULE__, :diagnostics, mode, opts}, {caller, _}, state) do
    result =
      if caller == state.consumer,
        do: diagnostic_read(state, mode, opts),
        else: {:error, :untrusted_audit_transport}

    {:reply, result, state}
  end

  def handle_call({__MODULE__, :diagnostics_subscribe}, {caller, _}, state) do
    if caller == state.consumer do
      result =
        if Keyword.has_key?(state.opts, :skill),
          do: :ok,
          else: diagnostic_managed_call(state, :subscribe, [caller])

      if result == :ok do
        Enum.each(Map.values(state.skill_current), &subscribe_diagnostics(state, &1))
        {:reply, :ok, %{state | opts: Keyword.put(state.opts, :diagnostics_notifications, true)}}
      else
        {:reply, result, state}
      end
    else
      {:reply, {:error, :untrusted_audit_transport}, state}
    end
  end

  def handle_call({__MODULE__, :revoke}, {caller, _}, state) do
    if caller == state.consumer and not Keyword.has_key?(state.opts, :skill),
      do: {:reply, managed_call(state, :revoke, []), state},
      else: {:reply, {:error, :untrusted_governance_transport}, state}
  end

  def handle_call({__MODULE__, :resolve_duty, ref, kind, opts}, {caller, _}, state) do
    if Keyword.has_key?(state.opts, :skill),
      do: {:reply, {:error, :review_through_root_agent}, state},
      else: {:reply, managed_call(state, :dispose, [ref, kind, opts, caller]), state}
  end

  def handle_call({__MODULE__, :submit, operation, arguments, opts}, {caller, _}, state) do
    with :ok <- authorize_submission(state, caller),
         :ok <- validate_submission(operation, arguments, opts) do
      acquire_submission(state, caller, operation, arguments, opts)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({__MODULE__, :presented, ref}, {caller, _}, state) do
    {:reply, managed_call(state, :presented, [ref, caller]), state}
  end

  def handle_call({__MODULE__, :decide, skill, ref, decision}, {caller, _} = from, state) do
    if caller == state.consumer and decision in [:confirm, :reject],
      do: dispatch_decision(state, skill, ref, decision, from),
      else: {:reply, {:error, :untrusted_consent_transport}, state}
  end

  def handle_call({__MODULE__, :transport_input, skill, value, opts}, from, state) do
    case Skills.lookup(state.skill_supervisor, skill) do
      {:ok, child} ->
        start_transport_query(state, child, from, value, opts)
        {:noreply, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({__MODULE__, :relay, token, {:decision, ref, decision, proof}}, _from, state) do
    case Keyword.get(state.opts, :skill_parent) do
      {_parent, ^token} -> accept_decision(state, ref, decision, proof)
      _ -> {:reply, {:error, :untrusted_consent_transport}, state}
    end
  end

  def handle_call({__MODULE__, :relay, token, {:input, value, opts, proof}}, _from, state) do
    case Keyword.get(state.opts, :skill_parent) do
      {_parent, ^token} -> accept_relay_input(state, value, opts, proof)
      _ -> {:reply, {:error, :untrusted_consent_transport}, state}
    end
  end

  def handle_call({__MODULE__, :skill_server, id}, _from, state) do
    result =
      case Map.get(state.skill_current, id) do
        nil -> {:error, :unknown_skill}
        pid -> if Process.alive?(pid), do: {:ok, pid}, else: {:error, :skill_restarting}
      end

    {:reply, result, state}
  end

  def handle_call({__MODULE__, :skill_input, id, input, dispatch}, _from, state) do
    if Keyword.has_key?(state.opts, :skill) do
      if Map.has_key?(state.seen_events, "skill:" <> id) do
        {:reply, {:ok, id}, state}
      else
        accept_input(state, Spectre.Input.new(input), dispatch, id, nil)
      end
    else
      {:reply, {:error, :not_a_skill_runtime}, state}
    end
  end

  def handle_call({__MODULE__, :input, value, opts}, {caller, _}, state) do
    input = Spectre.Input.new(value)

    with :ok <- Spectre.Input.validate(input),
         :ok <- validate_input_options(opts),
         :ok <- validate_pending_target(state, Keyword.get(opts, :pending)) do
      proof = textual_consent_proof(state, input, caller)
      accept_input(state, input, nil, nil, Keyword.get(opts, :pending), proof)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({__MODULE__, :deliver, event_id, tag, result}, from, state) do
    cond do
      not is_binary(event_id) or event_id == "" ->
        {:reply, {:error, :invalid_event_id}, state}

      Map.has_key?(state.seen_events, event_id) ->
        {:reply, :ok, state}

      is_nil(Keyword.get(state.opts, :checkpoint)) ->
        {:reply, {:error, :checkpoint_required}, state}

      true ->
        accept_delivery(state, event_id, tag, result, from)
    end
  end

  def handle_call({__MODULE__, :status}, _from, state) do
    {:reply,
     %{
       assigns: state.assigns,
       busy: not is_nil(state.current),
       pending: Map.values(state.pending),
       queued: :queue.len(state.queue),
       workers: map_size(state.workers),
       dead_letters: state.dead_letters,
       outbox_size: map_size(state.outbox),
       operations: state.operations
     }, state}
  end

  def handle_call({__MODULE__, :cancel}, _from, state) do
    state = cancel_current(state)
    {:reply, :ok, finish(state)}
  end

  def handle_call(message, from, state), do: delegate_otp(:handle_call, [message, from], state)

  @spec authorize_submission(map(), pid()) :: :ok | {:error, atom()}
  defp authorize_submission(state, caller) do
    cond do
      Keyword.has_key?(state.opts, :skill) ->
        {:error, :submit_through_root_agent}

      caller != state.consumer and caller not in Keyword.get(state.opts, :submitters, []) ->
        {:error, :untrusted_submitter}

      true ->
        :ok
    end
  end

  @spec validate_submission(term(), term(), term()) :: :ok | {:error, term()}
  defp validate_submission(operation, arguments, opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:on_result, :confirmation, :key] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      command = %Command{kind: :propose, args: [operation, arguments], opts: opts}

      with :ok <- submission_key(Keyword.get(opts, :key)),
           :ok <- Command.validate(command),
           do: Checkpoint.validate_value({operation, arguments, opts})
    else
      {:error, :invalid_submission_options}
    end
  end

  defp validate_submission(_, _, _), do: {:error, :invalid_submission_options}

  @spec submission_key(term()) :: :ok | {:error, :invalid_submission_key}
  defp submission_key(nil), do: :ok
  defp submission_key(key) when is_binary(key) and byte_size(key) in 1..256, do: :ok
  defp submission_key(_), do: {:error, :invalid_submission_key}

  @spec acquire_submission(map(), pid(), term(), map(), keyword()) :: tuple()
  defp acquire_submission(state, caller, operation, arguments, opts) do
    key = Keyword.get(opts, :key)

    fingerprint =
      Spectre.GAM.Canonical.Value.digest!({operation, arguments, Keyword.delete(opts, :key)})

    case Map.get(state.external_submissions, key) do
      %{id: id, fingerprint: ^fingerprint} ->
        {:reply, {:ok, id}, state}

      %{} ->
        {:reply, {:error, :submission_key_conflict}, state}

      nil ->
        prepare_submission(state, caller, operation, arguments, opts, key, fingerprint)
    end
  end

  @spec prepare_submission(map(), pid(), term(), map(), keyword(), binary() | nil, binary()) ::
          tuple()
  defp prepare_submission(state, caller, operation, arguments, opts, key, fingerprint) do
    cond do
      not is_nil(state.current) ->
        {:reply, {:error, :busy}, state}

      map_size(state.outbox) >= max(1, state.queue_limit) ->
        {:reply, {:error, :busy}, state}

      not is_nil(key) and map_size(state.external_submissions) >= 4096 ->
        {:reply, {:error, :submission_key_capacity_reached}, state}

      true ->
        commit_submission(state, caller, operation, arguments, opts, key, fingerprint)
    end
  end

  @spec commit_submission(map(), pid(), term(), map(), keyword(), binary() | nil, binary()) ::
          tuple()
  defp commit_submission(state, caller, operation, arguments, opts, key, fingerprint) do
    {ctx, dispatch} = context(state, nil)

    provenance = %{
      source: :external_actor,
      submitter_ref:
        Spectre.GAM.Canonical.Value.digest!({state.submission_epoch, inspect(caller)})
    }

    opts =
      opts
      |> Keyword.delete(:key)
      |> Keyword.put_new(:on_result, :submission)

    returned = Spectre.Server.propose(ctx, operation, arguments, opts)

    case Failure.capture(fn -> prepare_acquisition(state, returned, dispatch) end) do
      {:ok, {:prepared, next, [{id, entry} | remaining]}} ->
        command = %{
          entry.command
          | opts: Keyword.put(entry.command.opts, :external_submission, provenance)
        }

        entry = %{entry | command: command}
        next = %{next | outbox: Map.put(next.outbox, id, entry)}

        submissions =
          if is_nil(key),
            do: next.external_submissions,
            else: Map.put(next.external_submissions, key, %{id: id, fingerprint: fingerprint})

        prepared =
          {:prepared, %{next | external_submissions: submissions}, [{id, entry} | remaining]}

        {:reply, {:ok, id}, prepared |> commit_acquisition() |> finish()}

      {:error, reason} ->
        {:reply, {:error, {:submission_rejected, Tool.bounded(reason)}}, state}
    end
  end

  @impl true
  def handle_cast(message, state), do: delegate_otp(:handle_cast, [message], state)

  @impl true
  def handle_continue({__MODULE__, value}, state),
    do: delegate_otp(:handle_continue, [value], state)

  @impl true
  def handle_info(
        {__MODULE__, token, :decision_ready, {caller, _} = from, child, ref, decision,
         {:ok, pending}},
        %{control: token} = state
      ) do
    with true <- valid_decision_target?(pending, ref),
         {:ok, proof} <- managed_call(state, :authorize_decision, [ref, decision, caller]) do
      relay_request(state, child, from, {:decision, ref, decision, proof})
    else
      false -> GenServer.reply(from, {:error, :stale_presentation})
      {:error, _} = error -> GenServer.reply(from, error)
    end

    {:noreply, state}
  end

  def handle_info(
        {__MODULE__, token, :decision_ready, from, _child, _ref, _decision, {:error, reason}},
        %{control: token} = state
      ) do
    GenServer.reply(from, {:error, {:skill_unavailable, reason}})
    {:noreply, state}
  end

  def handle_info(
        {__MODULE__, token, :transport_ready, {caller, _} = from, child, value, opts,
         {:ok, pending}},
        %{control: token} = state
      ) do
    proof_state = %{
      state
      | pending: if(pending, do: %{pending.id => pending}, else: %{}),
        foreground: if(pending, do: pending.id)
    }

    proof = textual_consent_proof(proof_state, Spectre.Input.new(value), caller)
    relay_request(state, child, from, {:input, value, opts, proof})
    {:noreply, state}
  end

  def handle_info(
        {__MODULE__, token, :transport_ready, from, _child, _value, _opts, {:error, reason}},
        %{control: token} = state
      ) do
    GenServer.reply(from, {:error, {:skill_unavailable, reason}})
    {:noreply, state}
  end

  def handle_info({__MODULE__, ref, :close_pending}, state) do
    case Map.pop(state.close_timers, ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, timers} ->
        state = %{state | close_timers: timers}
        {:noreply, timed_close(state, entry) |> finish()}
    end
  end

  def handle_info({__MODULE__, ref, :expire_pending, id}, state) do
    case Map.pop(state.pending_timers, ref) do
      {nil, _} ->
        {:noreply, state}

      {entry, timers} ->
        state = %{state | pending_timers: timers}
        {:noreply, expire_pending(state, id, entry.revision) |> finish()}
    end
  end

  def handle_info({__MODULE__, control, :recover}, %{control: control} = state) do
    {:noreply, recover(state) |> finish()}
  end

  def handle_info({__MODULE__, control, :pump}, %{control: control} = state) do
    {:noreply, pump(state)}
  end

  def handle_info({__MODULE__, ref, :result, result}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {worker, workers} ->
        if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])
        cancel_timer(worker.timer)
        state = %{state | workers: workers}
        {:noreply, receive_result(state, worker, result) |> finish()}
    end
  end

  def handle_info({__MODULE__, ref, :timeout}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {worker, workers} ->
        state = %{state | workers: workers}
        {:noreply, timeout_worker(state, ref, worker) |> finish()}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, reason},
        %{startup_owner: {owner, monitor}} = state
      ),
      do: {:stop, reason, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason} = message, state) do
    case Enum.find(state.workers, fn {_ref, worker} -> worker.monitor == monitor end) do
      nil ->
        delegate_otp(:handle_info, [message], state)

      {ref, worker} ->
        cancel_timer(worker.timer)
        state = %{state | workers: Map.delete(state.workers, ref)}

        state =
          if governed?(worker.kind),
            do: uncertain_governed(state, ref, worker, {:worker_exit, reason}),
            else: receive_result(state, worker, tool_failure(worker, {:worker_exit, reason}))

        {:noreply, finish(state)}
    end
  end

  def handle_info({__MODULE__, token, :skill_started, id, pid}, %{control: token} = state) do
    if Keyword.get(state.opts, :diagnostics_notifications, false),
      do: subscribe_diagnostics(state, pid)

    current = Map.put(state.skill_current, id, pid)
    order = Enum.take([pid | state.skill_pid_order], 256)
    retained = Enum.uniq(Map.values(current) ++ order)
    pids = state.skill_pids |> Map.put(pid, id) |> Map.take(retained)
    {:noreply, %{state | skill_current: current, skill_pids: pids, skill_pid_order: order}}
  end

  def handle_info({__MODULE__, :diagnostics_subscribe, parent, token}, state) do
    if Keyword.get(state.opts, :skill_parent) == {parent, token} do
      Enum.each(Map.values(state.skill_current), &subscribe_diagnostics(state, &1))
      state = %{state | opts: Keyword.put(state.opts, :diagnostics_notifications, true)}
      Spectre.Server.Diagnostics.changed(state, state.checkpoint_revision)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({Spectre.Server, child, event} = message, state) do
    case Map.fetch(state.skill_pids, child) do
      {:ok, id} ->
        notify(state, {:skill, id, event})

        if Skills.preview?(event) or match?({:diagnostics_changed, _}, event),
          do: {:noreply, state},
          else: {:noreply, conversation(state, :handle_skill, [id, event], nil) |> finish()}

      :error ->
        delegate_otp(:handle_info, [message], state)
    end
  end

  # Unknown messages in this reserved envelope cannot complete an operation.
  def handle_info({__MODULE__, _ref, _kind}, state), do: {:noreply, state}
  def handle_info({__MODULE__, _ref, _kind, _value}, state), do: {:noreply, state}
  def handle_info(message, state), do: delegate_otp(:handle_info, [message], state)

  @impl true
  def terminate(reason, state) do
    Skills.stop(state.skill_supervisor)

    Enum.each(state.pending_timers, fn {_ref, entry} -> cancel_timer(entry.timer) end)
    Enum.each(state.close_timers, fn {_ref, entry} -> cancel_timer(entry.timer) end)

    Enum.each(state.workers, fn {_ref, worker} ->
      if worker.pid && not governed?(worker.kind), do: Process.exit(worker.pid, :kill)
      cancel_timer(worker.timer)
    end)

    if is_pid(state.managed_owner) and Process.alive?(state.managed_owner),
      do: Managed.close(state.managed_owner)

    {ctx, _} = context(state, nil)
    state.server.terminate(reason, ctx)
  end

  @impl true
  def code_change(old_vsn, state, extra) do
    {ctx, dispatch} = context(state, nil)

    case state.server.code_change(old_vsn, ctx, extra) do
      {:ok, returned} ->
        validate_context!(returned, dispatch)
        if returned.commands != [], do: raise(ArgumentError, "code_change cannot start commands")
        Spectre.Server.Contracts.validate_assigns!(state.server, returned.assigns)
        Spectre.Server.Contracts.validate_retained!(state.server, state)
        state = %{state | assigns: returned.assigns}
        state = Map.put(state, :tool_bindings, Tool.bindings!(state))
        state = state |> Tool.validate_persisted!() |> Checkpoint.refresh_fingerprint()
        validate_tool_state!(state)
        {:ok, state}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def format_status(status) do
    state = status.state

    safe = %{
      server: state.server,
      agent: state.agent,
      busy: not is_nil(state.current),
      pending_count: map_size(state.pending),
      worker_count: map_size(state.workers)
    }

    state.server.format_status(%{status | state: safe})
  end

  defp timeout_worker(state, ref, worker) do
    if governed?(worker.kind) do
      worker = worker |> Map.put(:timer, nil) |> Map.put(:detached, true)
      state = %{state | workers: Map.put(state.workers, ref, worker)}
      uncertain_governed(state, ref, worker, :timeout)
    else
      if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])
      if worker.pid, do: Process.exit(worker.pid, :kill)
      receive_result(state, worker, tool_failure(worker, :timeout))
    end
  end

  defp accept_delivery(state, event_id, tag, result, from) do
    case Delivery.validate(state, tag, result) do
      :ok -> accept_valid_delivery(state, event_id, tag, result, from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp accept_valid_delivery(state, event_id, {:command, id} = tag, result, from) do
    if Map.has_key?(state.seen_events, id),
      do: {:reply, :ok, state},
      else: dispatch_delivery(state, event_id, tag, result, from)
  end

  defp accept_valid_delivery(state, event_id, tag, result, from),
    do: dispatch_delivery(state, event_id, tag, result, from)

  defp dispatch_delivery(state, event_id, tag, {:governed_ref, reference}, from) do
    state =
      worker(
        state,
        :resolve_delivery,
        nil,
        nil,
        [],
        fn ->
          resolve_delivery_reference(state, tag, reference)
        end,
        reply_to: from,
        delivery_tag: tag,
        external_event_id: event_id
      )

    {:noreply, state}
  end

  defp dispatch_delivery(state, event_id, tag, result, _from) do
    case delivery_worker(state, tag) do
      {:ok, worker} ->
        state = retire_delivered_worker(state, worker)
        {:reply, :ok, receive_result(state, worker, result, event_id) |> finish()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp resolve_delivery_reference(state, _tag, reference),
    do: bridge(state, :resolve_result, [reference, service_context(state, nil), []])

  defp accept_input(state, input, dispatch, invocation, target, proof \\ nil) do
    queued? = not :queue.is_empty(state.queue)
    busy? = not is_nil(state.current) or resolving_pending?(state)
    waiting? = busy? or queued?

    if waiting? and :queue.len(state.queue) >= state.queue_limit do
      {:reply, {:error, :busy}, state}
    else
      event =
        input_event(state, input, dispatch, invocation)
        |> Map.put(:target_pending, target)
        |> Map.put(:consent_proof, proof)
        |> Map.put(
          :consent_source_digest,
          if(proof, do: Base.encode16(:crypto.hash(:sha256, input.text), case: :lower))
        )

      id = event.id
      state = %{state | sequence: state.sequence + 1}
      state = if invocation, do: Inbox.mark_seen(state, "skill:" <> invocation), else: state

      state =
        if waiting?,
          do: %{state | queue: :queue.in(event, state.queue)},
          else: begin_input(state, event)

      if queued? and not busy?, do: send(self(), {__MODULE__, state.control, :pump})
      {:reply, {:ok, id}, Checkpoint.save(state)}
    end
  end

  @spec managed_call(map(), atom(), list()) :: term()
  defp managed_call(%{gam: {Managed, config}}, function, args),
    do: apply(Managed, function, [Keyword.fetch!(config, :server) | args])

  defp managed_call(_state, _function, _args), do: {:error, :managed_gam_not_configured}

  @spec diagnostic_managed_call(map(), atom(), list()) :: term()
  defp diagnostic_managed_call(state, function, args) do
    managed_call(state, function, args)
  catch
    :exit, _ -> {:error, :diagnostic_source_unavailable}
  end

  @spec subscribe_diagnostics(map(), pid()) :: :ok
  defp subscribe_diagnostics(state, pid) do
    send(pid, {__MODULE__, :diagnostics_subscribe, self(), state.control})
    :ok
  end

  @spec diagnostic_read(map(), term(), term()) :: {:ok, map()} | {:error, term()}
  defp diagnostic_read(state, mode, opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:skill, :limit, :cursor])),
         true <- mode != :operational or not Keyword.has_key?(opts, :cursor),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         {:ok, snapshot} <- diagnostic_snapshot(state, mode, opts) do
      diagnostic_correlate(state, mode, opts, snapshot)
    else
      false -> {:error, :invalid_diagnostic_options}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :diagnostic_source_unavailable}
  end

  @spec diagnostic_snapshot(map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  defp diagnostic_snapshot(state, mode, opts) do
    local_opts = Keyword.take(opts, [:limit])

    case Keyword.get(opts, :skill) do
      nil ->
        diagnostic_local(state, mode, local_opts)

      skill ->
        with {:ok, pid} <- Skills.lookup(state.skill_supervisor, skill),
             do: GenServer.call(pid, {__MODULE__, :diagnostics, mode, local_opts})
    end
  end

  @spec diagnostic_local(map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  defp diagnostic_local(state, :operational, opts),
    do: Spectre.Server.Diagnostics.read(state, opts)

  defp diagnostic_local(state, {:trace, interaction}, opts),
    do: Spectre.Server.Diagnostics.read_trace(state, interaction, opts)

  defp diagnostic_local(_, _, _), do: {:error, :invalid_diagnostic_query}

  @spec diagnostic_correlate(map(), term(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  defp diagnostic_correlate(state, {:trace, interaction}, opts, snapshot) do
    if Keyword.has_key?(state.opts, :skill) do
      {:ok, snapshot}
    else
      gam_opts = opts |> Keyword.take([:limit, :cursor]) |> Keyword.put(:interaction, interaction)

      case diagnostic_managed_call(state, :diagnostics, [gam_opts, state.consumer]) do
        {:ok, gam} ->
          {:ok, Map.put(snapshot, :gam, gam)}

        {:error, :managed_gam_not_configured} ->
          coverage =
            Map.put(snapshot.coverage, :gam, %{
              available: false,
              reason: :managed_gam_not_configured
            })

          {:ok, snapshot |> Map.put(:gam, nil) |> Map.put(:coverage, coverage)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp diagnostic_correlate(_, _, _, snapshot), do: {:ok, snapshot}

  @spec accept_decision(map(), String.t(), :confirm | :reject, String.t()) :: tuple()
  defp accept_decision(state, ref, decision, proof) do
    pending = Map.get(state.pending, state.foreground)

    if pending && get_in(pending, [:presentation, Access.key(:ref)]) == ref &&
         pending.status == :foreground do
      input = Spectre.Input.new(if decision == :confirm, do: "confermo", else: "annulla")
      accept_input(state, input, nil, nil, {pending.id, pending.revision}, proof)
    else
      {:reply, {:error, :stale_presentation}, state}
    end
  end

  @spec textual_consent_proof(map(), Spectre.Input.t(), pid()) :: String.t() | nil
  defp textual_consent_proof(%{gam: {Managed, _}} = state, input, caller) do
    with true <- caller == state.consumer,
         %{kind: :consent, presentation: %{ref: ref}} <- Map.get(state.pending, state.foreground),
         {:ok, proof} <- authorize_reply(state, ref, input.text, caller) do
      proof
    else
      _ -> nil
    end
  end

  defp textual_consent_proof(_state, _input, _caller), do: nil

  @spec authorize_reply(map(), binary(), binary(), pid()) :: {:ok, binary()} | {:error, term()}
  defp authorize_reply(state, ref, text, caller) do
    case decision_from_text(text) do
      nil -> managed_call(state, :authorize_input, [ref, text, caller])
      decision -> managed_call(state, :authorize_decision, [ref, decision, caller])
    end
  end

  @spec decision_from_text(String.t()) :: :confirm | :reject | nil
  defp decision_from_text(text) do
    case String.downcase(String.trim(text)) do
      answer when answer in ["yes", "confirm", "confermo", "si", "sì"] -> :confirm
      answer when answer in ["no", "cancel", "annulla"] -> :reject
      _ -> nil
    end
  end

  @spec dispatch_decision(map(), term(), binary(), atom(), GenServer.from()) :: tuple()
  defp dispatch_decision(state, skill, ref, decision, {caller, _}) when skill in [nil, :agent] do
    with true <- valid_decision_target?(Map.get(state.pending, state.foreground), ref),
         {:ok, proof} <- managed_call(state, :authorize_decision, [ref, decision, caller]) do
      accept_decision(state, ref, decision, proof)
    else
      false -> {:reply, {:error, :stale_presentation}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp dispatch_decision(state, skill, ref, decision, from) do
    case Skills.lookup(state.skill_supervisor, skill) do
      {:ok, child} ->
        start_decision_query(state, child, from, ref, decision)
        {:noreply, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @spec start_decision_query(map(), pid(), GenServer.from(), binary(), atom()) :: {:ok, pid()}
  defp start_decision_query(state, child, from, ref, decision) do
    owner = self()
    token = state.control

    Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
      result = Failure.capture(fn -> foreground_skill_pending(child) end)
      send(owner, {__MODULE__, token, :decision_ready, from, child, ref, decision, result})
    end)
  end

  @spec valid_decision_target?(map() | nil, binary()) :: boolean()
  defp valid_decision_target?(
         %{kind: :consent, status: :foreground, presentation: %{ref: ref}},
         ref
       ),
       do: true

  defp valid_decision_target?(_pending, _ref), do: false

  @spec start_transport_query(map(), pid(), GenServer.from(), term(), keyword()) :: {:ok, pid()}
  defp start_transport_query(state, child, from, value, opts) do
    owner = self()
    token = state.control

    Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
      result = Failure.capture(fn -> foreground_skill_pending(child) end)
      send(owner, {__MODULE__, token, :transport_ready, from, child, value, opts, result})
    end)
  end

  @spec foreground_skill_pending(pid()) :: map() | nil
  defp foreground_skill_pending(child) do
    status = GenServer.call(child, {__MODULE__, :status}, 1_500)
    Enum.find(status.pending, &(Map.get(&1, :status) == :foreground))
  end

  @spec relay_request(map(), pid(), GenServer.from(), tuple()) :: {:ok, pid()}
  defp relay_request(state, child, from, request) do
    token = state.control

    Task.Supervisor.start_child(Spectre.Server.TaskSupervisor, fn ->
      reply =
        case Failure.capture(fn ->
               GenServer.call(child, {__MODULE__, :relay, token, request}, 2_000)
             end) do
          {:ok, reply} -> reply
          {:error, reason} -> {:error, {:skill_unavailable, reason}}
        end

      GenServer.reply(from, reply)
    end)
  end

  @spec accept_relay_input(map(), term(), keyword(), binary() | nil) :: tuple()
  defp accept_relay_input(state, value, opts, proof) do
    input = Spectre.Input.new(value)

    with :ok <- Spectre.Input.validate(input),
         :ok <- validate_input_options(opts),
         :ok <- validate_pending_target(state, Keyword.get(opts, :pending)) do
      accept_input(state, input, nil, nil, Keyword.get(opts, :pending), proof)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @spec input_event(map(), Spectre.Input.t(), map() | nil, binary() | nil) :: map()
  defp input_event(state, input, dispatch, invocation) do
    id = invocation || Spectre.Identity.uuid7()

    event = %{
      id: id,
      input: input,
      routing: %{},
      steps: 0,
      phase: :preparing,
      sequence: state.sequence + 1,
      received_at: System.system_time(:millisecond)
    }

    event =
      if is_map(dispatch),
        do:
          event
          |> Map.put(:skill_dispatch, dispatch.key)
          |> Map.put(:routing, dispatch.routing)
          |> Map.put(:memory, Map.get(dispatch, :memory))
          |> Map.put(:received_at, Map.get(dispatch, :received_at, event.received_at)),
        else: event

    if invocation, do: Map.put(event, :delegated, true), else: event
  end

  defp server_binding(agent) do
    cond do
      function_exported?(agent, :__spectre_server__, 0) ->
        agent.__spectre_server__()

      function_exported?(agent, :__spectre_config__, 0) ->
        Keyword.fetch!(agent.__spectre_config__(), :server)

      true ->
        raise ArgumentError, "Agent has no Server binding; configure server:"
    end
  end

  defp validate_input_options([]), do: :ok

  defp validate_input_options(pending: {id, revision})
       when not is_nil(id) and is_integer(revision) and revision > 0, do: :ok

  defp validate_input_options(_opts), do: {:error, :unsupported_input_options}

  @spec validate_pending_target(map(), nil | {term(), pos_integer()}) :: :ok | {:error, atom()}
  defp validate_pending_target(_state, nil), do: :ok

  defp validate_pending_target(state, {id, revision}) do
    case Map.get(state.pending, id) do
      %{revision: ^revision, status: :foreground} when state.foreground == id -> :ok
      _ -> {:error, :stale_pending}
    end
  end

  defp begin_input(state, event) do
    history =
      Enum.take(
        state.history ++ [%{id: event.id, user: event.input.text, assistant: ""}],
        -Keyword.get(state.opts, :history_limit, 50)
      )

    state = %{state | current: event, history: history}

    if Map.has_key?(event, :skill_dispatch),
      do: prepared_input(state, event),
      else: start_input_preparation(state, event)
  end

  defp prepared_input(state, %{skill_dispatch: key} = event) do
    apply_worker_result(state, %{kind: :route, event: event}, {:ok, key, event.routing})
  end

  defp prepared_input(state, %{delegated: true} = event), do: route(state, event)

  defp prepared_input(state, %{target_pending: {_id, _revision}} = event),
    do: after_interrupt(state, event)

  defp prepared_input(state, event) do
    worker(state, :interrupt, nil, event, [], fn ->
      Spectre.Server.PreRoute.interrupt(state.agent, event.input, service_context(state, event))
    end)
  end

  defp after_interrupt(state, event) do
    case validate_pending_target(state, Map.get(event, :target_pending)) do
      :ok ->
        dispatch_pending_input(state, event)

      {:error, :stale_pending} ->
        conversation(state, :handle_result, [:pending, {:consent, :stale_input}], event)
        |> finish()
    end
  end

  @spec dispatch_pending_input(map(), map()) :: map()
  defp dispatch_pending_input(state, event) do
    case Map.get(state.pending, state.foreground) do
      nil ->
        route(state, event)

      pending ->
        event =
          Map.put(event, :pending_snapshot, %{
            id: pending.id,
            revision: Map.get(pending, :revision, 1)
          })

        conversation(state, :handle_pending, [pending, event.input], event)
    end
    |> finish()
  end

  defp route(state, %{pre_route_done: true} = event) do
    worker(state, :route, nil, event, [], fn ->
      opts = [
        assigns: state.assigns,
        runtime_scope: Keyword.get(state.opts, :runtime_scope),
        current_flow: state.current_flow,
        current_scope: state.current_scope,
        state_data: %{chat_history: Enum.reject(state.history, &(&1.id == event.id))},
        stack_runtime: Keyword.get(state.opts, :stack_runtime)
      ]

      case Map.get(state.services, :router) do
        nil -> Spectre.Server.Router.route(state.agent, event.input, opts)
        binding -> invoke(binding, :route, [state.agent, event.input, opts])
      end
    end)
  end

  defp route(state, event) do
    worker(state, :pre_route, nil, event, [], fn ->
      Spectre.Server.PreRoute.handle(state.agent, event.input, service_context(state, event))
    end)
  end

  defp worker_result(state, %{pending_id: id} = worker, result) when not is_nil(id) do
    if Map.has_key?(state.pending, id),
      do: apply_worker_result(state, worker, result),
      else: state
  end

  defp worker_result(state, worker, result), do: apply_worker_result(state, worker, result)

  defp apply_worker_result(state, %{kind: :interrupt, event: event}, :cont),
    do: after_interrupt(state, event)

  defp apply_worker_result(state, %{kind: :interrupt, event: event}, {:interrupt, key, metadata}) do
    if not is_nil(state.foreground) and PendingLifecycle.configured?(state) do
      event = %{event | routing: Map.put(metadata, :route_key, key)}

      commands = [
        %Command{
          kind: :route_current_input,
          args: [],
          opts: [suspend: state.foreground, lifecycle_interrupt: true]
        },
        %Command{kind: :dispatch_interrupt, args: [], opts: []}
      ]

      enqueue_runtime_commands(state, commands, event)
    else
      state = if state.foreground, do: suspend_pending(state, state.foreground), else: state
      apply_worker_result(state, %{kind: :route, event: event}, {:ok, key, metadata})
    end
  end

  defp apply_worker_result(state, %{kind: :pre_route, event: event}, :cont) do
    event = Map.put(event, :pre_route_done, true)
    route(update_current(state, event), event)
  end

  defp apply_worker_result(state, %{kind: :pre_route, event: event}, {:handled, text}) do
    conversation(
      state,
      :handle_result,
      [:pre_route, {:generated, %{text: text, proposals: []}}],
      event
    )
  end

  defp apply_worker_result(state, %{kind: :interrupt, event: event}, {:error, reason}) do
    notify(state, {:routing_evidence_error, event_id(event), :interrupt, reason})
    after_interrupt(state, event)
  end

  defp apply_worker_result(state, %{kind: kind, event: event}, {:error, reason})
       when kind in [:interrupt, :pre_route],
       do: conversation(state, :handle_result, [kind, {:error, reason}], event)

  defp apply_worker_result(state, %{kind: :prepare_input, event: event}, {:ok, input, memory}) do
    event =
      event |> Map.put(:input, input) |> Map.put(:memory, memory) |> Map.put(:phase, :routing)

    state = update_current(state, event)
    prepared_input(state, event)
  end

  defp apply_worker_result(state, %{kind: :prepare_input, event: event}, {:error, reason}) do
    conversation(state, :handle_result, [:input, {:error, reason}], event)
  end

  defp apply_worker_result(state, %{kind: :release_command}, result) do
    if not match?({:ok, _}, result) and result != :ok,
      do: notify(state, {:journal_cleanup_error, result})

    state
  end

  defp apply_worker_result(state, %{kind: :remember, event: event}, result) do
    if result != :ok, do: notify(state, {:memory_error, event_id(event), result})
    state
  end

  defp apply_worker_result(state, %{kind: :route, event: event}, result) do
    case result do
      {:ok, key, routing} when is_map(routing) ->
        event = %{
          event
          | routing: Map.put(routing, :route_key, key),
            input: Map.get(routing, :input, event.input)
        }

        state = update_current(state, event)
        selected = Map.get(routing, :route)

        state =
          if selected,
            do: %{state | current_flow: selected.flow, current_scope: selected.scope},
            else: state

        dispatch_flow(state, key, event)

      {:unmatched, routing} when is_map(routing) ->
        event = %{event | routing: routing}
        state = update_current(state, event)
        conversation(state, :handle_flow, [:unmatched, event.input], event)

      {:error, reason} ->
        event = %{event | routing: %{reason: {:classifier_error, reason}}}
        state = update_current(state, event)
        conversation(state, :handle_flow, [:unmatched, event.input], event)

      other ->
        worker_result(
          state,
          %{kind: :route, event: event},
          {:error, {:invalid_router_result, other}}
        )
    end
  end

  defp apply_worker_result(state, %{kind: :delegate_route, event: event}, {:delegated, details}) do
    notify(state, {:delegated, event_id(event), details})
    state
  end

  defp apply_worker_result(state, %{kind: :respond, event: event} = worker, {:rendered, text})
       when is_binary(text) do
    command = %Command{kind: :respond, args: [text], opts: Map.get(worker, :opts, [])}
    state = execute(%{state | active_command: Map.get(worker, :command_id)}, command, event)
    %{state | active_command: nil}
  end

  defp apply_worker_result(
         state,
         %{kind: kind, tag: tag, event: event} = worker,
         {:pending, data}
       )
       when kind in [:propose, :confirm_pending, :explain_pending, :resume_pending] and
              is_map(data) do
    id = Map.get(worker, :pending_id) || make_pending_id()
    previous = Map.get(state.pending, id, %{})

    pending =
      Map.merge(Map.delete(data, :close_schedule), %{
        id: id,
        kind: :consent,
        status: shown_pending_status(state, worker, id),
        revision: Map.get(previous, :revision, 0) + 1,
        shown_at_sequence: state.sequence,
        on_result: Map.get(previous, :on_result, tag),
        explicit_on_result:
          Map.get(previous, :explicit_on_result, Map.get(worker, :explicit_on_result, false)),
        command_id: Map.get(previous, :command_id, Map.get(worker, :command_id)),
        origin: Map.get(previous, :origin, event)
      })

    foreground =
      if pending.status == :foreground,
        do: id,
        else: if(state.foreground == id, do: nil, else: state.foreground)

    state = %{state | pending: Map.put(state.pending, id, pending), foreground: foreground}
    notify(state, {:pending, event_id(event), id})
    state |> arm_pending_timer(pending) |> reconcile_close_timers()
  end

  defp apply_worker_result(
         state,
         %{kind: :lifecycle_completion} = completion,
         {:pending_lifecycle, result}
       ),
       do: lifecycle_callback(state, completion, result)

  defp apply_worker_result(state, %{tag: tag, event: event} = worker, result) do
    state =
      case Map.get(worker, :pending_id) do
        nil ->
          state

        id ->
          # A bridge error leaves the unresolved consent available for retry
          # or explanation. A terminal result resolves it.
          pending = Map.get(state.pending, id)

          if (match?({:error, _}, result) and pending) && pending.kind == :consent do
            restore_failed_pending(state, worker, pending)
          else
            delete_pending(state, id)
          end
      end

    conversation(state, :handle_result, [tag, result], event)
  end

  @spec dispatch_flow(map(), term(), map()) :: map()
  defp dispatch_flow(state, {{{:skill, id}, _flow}, _label} = key, event)
       when not is_nil(state.skill_supervisor) do
    if Enum.any?(Skills.mounts(state.agent), &(&1.id == id)) do
      command = %Command{kind: :delegate_route, args: [id], opts: [on_result: :delegate]}
      event = %{event | phase: :commands}
      state = state |> acquire_result() |> update_current(event)
      enqueue_runtime_commands(state, [command], event)
    else
      conversation(state, :handle_flow, [key, event.input], event)
    end
  end

  defp dispatch_flow(state, key, event) do
    scope = Keyword.get(state.opts, :runtime_scope)

    if is_nil(scope) or event.routing[:scope] == scope do
      conversation(state, :handle_flow, [Skills.local_key(key, state.opts), event.input], event)
    else
      conversation(
        state,
        :handle_result,
        [:delegate, {:error, :skill_route_scope_mismatch}],
        event
      )
    end
  end

  defp shown_pending_status(state, worker, id) do
    if Map.get(worker, :recovered, false) or Map.get(worker, :uncertain, false) or
         state.foreground not in [nil, id],
       do: :suspended,
       else: :foreground
  end

  defp restore_failed_pending(state, worker, pending) do
    previous = Map.get(pending, :previous_status, :suspended)

    status =
      if Map.get(worker, :recovered, false) or pending.status == :uncertain or
           (previous == :foreground and state.foreground != pending.id),
         do: :suspended,
         else: previous

    restored = pending |> Map.put(:status, status) |> Map.delete(:previous_status)
    state = %{state | pending: Map.put(state.pending, pending.id, restored)}

    state
    |> arm_pending_timer(restored)
    |> reconcile_close_timers()
    |> close_deferred_pending(worker, restored)
  end

  defp close_deferred_pending(
         state,
         worker,
         %{close_schedule: %{fired: true} = schedule} = pending
       ) do
    if pending.status not in [:resolving, :uncertain] and
         not Map.get(worker, :recovered, false) and not Map.get(worker, :uncertain, false) and
         schedule.deadline <= System.system_time(:millisecond) do
      timer = %{
        id: pending.id,
        schedule_id: schedule.command_id,
        revision: schedule.revision,
        deadline: schedule.deadline,
        reason: schedule.reason,
        policy_ref: schedule.policy_ref
      }

      id = schedule.command_id <> ":after:" <> Map.fetch!(worker, :command_id)
      timed_close(state, timer, id)
    else
      state
    end
  end

  defp close_deferred_pending(state, _worker, _pending), do: state

  defp update_current(%{current: %{id: id}} = state, %{id: id} = event),
    do: %{state | current: event}

  defp update_current(state, _event), do: state

  defp conversation(state, callback, args, event) do
    event = if event, do: %{event | steps: event.steps + 1}, else: nil
    state = update_current(state, event)
    {ctx, dispatch} = context(state, event)

    case Failure.capture(fn ->
           prepare_conversation(state, callback, args, event, ctx, dispatch)
           |> prepare_conversation_acquisition(state, dispatch)
         end) do
      {:ok, {:stale_consent, on_result}} ->
        conversation(state, :handle_result, [on_result, {:consent, :stale_input}], event)

      {:ok, prepared} ->
        commit_acquisition(prepared)

      {:error, reason} ->
        quarantine_callback(state, callback, event, reason)
    end
  end

  defp prepare_conversation_acquisition({:stale_consent, _} = stale, _state, _dispatch), do: stale

  defp prepare_conversation_acquisition(returned, state, dispatch),
    do: prepare_acquisition(state, returned, dispatch)

  defp prepare_conversation(state, callback, args, event, ctx, dispatch) do
    if event && event.steps > state.max_steps,
      do: raise(ArgumentError, "Server interaction step limit exceeded")

    if callback == :handle_result do
      [tag, result] = args

      Spectre.Server.Contracts.validate_result!(state.server, tag, result, %{
        interaction_id: event_id(event),
        command_id: get_in(state.inbox, [state.processing_result, :worker, :command_id])
      })
    end

    returned = apply(state.server, callback, args ++ [ctx])
    validate_context!(returned, dispatch)

    case expired_schedule(state, returned.commands) do
      nil -> prepare_current_conversation(state, returned, event)
      _pending -> returned
    end
  end

  defp prepare_current_conversation(state, returned, event) do
    case stale_confirmation(state, returned.commands, event) do
      nil -> validate_conversation_commands(state, returned, event)
      pending -> {:stale_consent, pending.on_result}
    end
  end

  defp expired_schedule(state, commands) do
    Enum.find_value(commands, fn
      %Command{kind: kind, args: [id]}
      when kind in [:confirm_pending, :reject_pending, :resume_pending, :explain_pending] ->
        expired_pending(state, Map.get(state.pending, id))

      _ ->
        nil
    end)
  end

  defp expired_pending(state, %{close_schedule: %{deadline: deadline}} = pending) do
    if deadline <= System.system_time(:millisecond) and PendingLifecycle.configured?(state),
      do: pending
  end

  defp expired_pending(_state, _pending), do: nil

  defp validate_conversation_commands(state, returned, event) do
    validate_stateful_commands!(state, returned.commands, event)

    if event && returned.commands == [],
      do: raise(ArgumentError, "foreground callback must choose a next step")

    returned
  end

  defp stale_confirmation(_state, _commands, nil), do: nil

  defp stale_confirmation(state, commands, event) do
    Enum.find_value(commands, fn
      %Command{kind: kind, args: [id]} when kind in [:confirm_pending, :reject_pending] ->
        stale_pending(state, Map.get(state.pending, id), event)

      _ ->
        nil
    end)
  end

  defp stale_pending(state, %{kind: :consent} = pending, event) do
    if pending.status != :foreground or state.foreground != pending.id or
         not confirmation_event?(pending, event),
       do: pending
  end

  defp stale_pending(_state, _pending, _event), do: nil

  defp quarantine_callback(state, callback, event, reason) do
    state = discard_quarantined_following(state)
    {state, failure} = Failure.quarantine(state, callback, event, reason)
    state = if event, do: update_current(state, Map.put(event, :phase, :commands)), else: state
    state = Checkpoint.save(state)
    notify(state, {:callback_error, event_id(event), callback, reason})
    state |> callback_error_handler(failure, event) |> drain_released_commands()
  end

  defp discard_quarantined_following(state) do
    case Map.get(state.inbox, state.processing_result) do
      %{worker: %{kind: :lifecycle_completion}, result: {:pending_lifecycle, result}} = entry ->
        release_lifecycle_following(state, %{
          entry
          | result: {:pending_lifecycle, Map.put(result, :status, :ignored)}
        })

      _ ->
        state
    end
  end

  defp drain_released_commands(state) do
    entries = state.released_commands
    execute_entries(%{state | released_commands: []}, entries)
  end

  defp callback_error_handler(state, failure, event) do
    attempts =
      Enum.count(state.dead_letters, fn {_id, entry} ->
        if is_nil(failure.interaction),
          do: entry.id == failure.id,
          else: entry.interaction == failure.interaction
      end)

    if attempts <= Keyword.get(state.opts, :max_callback_error_attempts, 1) do
      dispatch_error_handler(state, failure, event, Keyword.get(state.opts, :on_callback_error))
    else
      state
    end
  end

  defp dispatch_error_handler(state, failure, event, {module, function})
       when is_atom(module) and is_atom(function),
       do: invoke_error_handler(state, failure, event, module, function)

  defp dispatch_error_handler(state, _failure, _event, nil), do: state

  defp dispatch_error_handler(state, failure, _event, _invalid) do
    notify(state, {:callback_error_handler_failed, failure.id, :invalid_handler})
    state
  end

  defp invoke_error_handler(state, failure, event, module, function) do
    {ctx, dispatch} = context(state, event)

    result =
      Failure.capture(fn ->
        returned = apply(module, function, [failure, ctx])
        validate_context!(returned, dispatch)
        validate_stateful_commands!(state, returned.commands, event)
        prepare_acquisition(state, returned, dispatch)
      end)

    case result do
      {:ok, prepared} ->
        commit_acquisition(prepared)

      {:error, reason} ->
        notify(state, {:callback_error_handler_failed, failure.id, reason})
        state
    end
  end

  defp delegate_otp(callback, args, state) do
    {ctx, dispatch} = context(state, nil)
    result = apply(state.server, callback, args ++ [ctx])

    case result do
      {:reply, reply, returned} ->
        {:reply, reply, acquire(state, returned, dispatch) |> finish()}

      {:reply, reply, returned, action} ->
        {:reply, reply, acquire(state, returned, dispatch) |> finish(), otp_action(action)}

      {:noreply, returned} ->
        {:noreply, acquire(state, returned, dispatch) |> finish()}

      {:noreply, returned, action} ->
        {:noreply, acquire(state, returned, dispatch) |> finish(), otp_action(action)}

      {:stop, reason, returned} ->
        {:stop, reason, acquire(state, returned, dispatch)}

      {:stop, reason, reply, returned} ->
        {:stop, reason, reply, acquire(state, returned, dispatch)}

      other ->
        raise ArgumentError, "invalid #{callback} return: #{inspect(other)}"
    end
  end

  defp otp_action({:continue, value}), do: {:continue, {__MODULE__, value}}
  defp otp_action(:hibernate), do: :hibernate
  defp otp_action(:infinity), do: :infinity
  defp otp_action(n) when is_integer(n) and n >= 0, do: n
  defp otp_action(other), do: raise(ArgumentError, "invalid OTP action: #{inspect(other)}")

  defp context(state, event) do
    token = make_ref()

    ctx = %Context{
      agent: state.agent,
      assigns: state.assigns,
      private: state.private,
      identity: state.identity,
      skill: Keyword.get(state.opts, :skill),
      interaction: if(event, do: event.id),
      input: if(event, do: event.input),
      routing: Skills.routing(state, event),
      memory: if(event, do: Map.get(event, :memory)),
      pending: Map.get(state.pending, state.foreground),
      pending_by_id: state.pending,
      dispatch_token: token
    }

    {ctx, %{token: token, event: event}}
  end

  defp validate_context!(
         %Context{dispatch_token: token, assigns: assigns, private: private, commands: commands},
         %{
           token: token
         }
       )
       when is_map(assigns) and is_map(private) and is_list(commands) do
    Enum.each(commands, fn command ->
      case Command.validate(command) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, "invalid Server command: #{inspect(reason)}"
      end
    end)
  end

  defp validate_context!(_, _), do: raise(ArgumentError, "invalid or stale Server context")

  defp acquire(state, returned, dispatch),
    do: state |> prepare_acquisition(returned, dispatch) |> commit_acquisition()

  defp prepare_acquisition(state, returned, dispatch) do
    validate_context!(returned, dispatch)
    Spectre.Server.Contracts.validate_assigns!(state.server, returned.assigns)
    Spectre.Server.Contracts.validate_commands!(state.server, returned.commands)

    case expired_schedule(state, returned.commands) do
      nil ->
        prepare_acquisition_commands(state, returned, dispatch, %{})

      pending ->
        command = %Command{
          kind: :close_pending,
          args: [pending.id],
          opts: [
            reason: pending.close_schedule.reason,
            if_revision: Map.get(pending, :revision, 1),
            if_schedule: pending.close_schedule.command_id
          ]
        }

        prepare_acquisition_commands(state, %{returned | commands: [command]}, dispatch, %{
          expiry_result: pending.on_result,
          policy_closed: true
        })
    end
  end

  defp prepare_acquisition_commands(state, returned, dispatch, extra) do
    tool_event =
      if Keyword.has_key?(state.opts, :skill),
        do: %{routing: Skills.routing(state, dispatch.event)},
        else: dispatch.event

    normalized =
      Enum.map(returned.commands, fn command ->
        command
        |> then(&Tool.normalize(state, &1, tool_event))
        |> Skills.authorize(state)
        |> action_policy(state, returned)
      end)

    commands = Enum.map(normalized, &elem(&1, 0))

    Enum.each(commands, fn command ->
      case Command.validate_internal(command) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError, "invalid normalized Server command: #{inspect(reason)}"
      end
    end)

    validate_stateful_commands!(state, commands, dispatch.event)

    if dispatch.event && returned.commands == [],
      do: raise(ArgumentError, "foreground callback must choose a next step")

    state = %{state | assigns: returned.assigns, private: returned.private}

    state =
      if dispatch.event,
        do: update_current(state, Map.put(dispatch.event, :phase, :commands)),
        else: state

    state = acquire_result(state)
    released = state.released_commands
    state = %{state | released_commands: []}

    entries =
      Enum.zip(normalized, returned.commands)
      |> Enum.map(fn {{command, origin}, original} ->
        entry =
          Map.merge(
            %{
              command: command,
              event: dispatch.event,
              execution_started: false,
              explicit_on_result: Keyword.has_key?(original.opts, :on_result)
            },
            extra
          )

        entry = if origin, do: Map.put(entry, :tool_origin, origin), else: entry
        {Spectre.Identity.uuid7(), entry}
      end)

    state = %{state | outbox: Map.merge(state.outbox, Map.new(entries))}
    validate_tool_state!(state)
    {:prepared, state, entries ++ released}
  end

  defp commit_acquisition({:prepared, state, entries}),
    do: execute_entries(Checkpoint.save(state), entries)

  @spec action_policy({Command.t(), term()}, map(), Context.t()) :: {Command.t(), term()}
  defp action_policy(
         {%Command{kind: :propose, args: [operation, args]} = command, origin},
         state,
         ctx
       ) do
    action = %{
      operation: operation,
      args: args,
      metadata: Keyword.get(command.opts, :proposal_metadata, %{})
    }

    result =
      if function_exported?(state.server, :handle_action, 2),
        do: state.server.handle_action(action, ctx),
        else: :default

    case result do
      :default ->
        {command, origin}

      :confirm ->
        {put_action_policy(command, %{confirm: true}), origin}

      {:confirm, policy} when is_map(policy) ->
        {put_action_policy(command, Map.put(policy, :confirm, true)), origin}

      {:reject, reason} ->
        case state.gam do
          {Managed, _} ->
            {put_action_policy(command, %{reject: reason}), origin}

          _ ->
            {%Command{
               kind: :tool_rejected,
               args: [{:error, {:action_rejected, reason}}],
               opts: command.opts
             }, origin}
        end

      other ->
        raise ArgumentError, "invalid handle_action return: #{inspect(other)}"
    end
  end

  defp action_policy(command, _state, _ctx), do: command

  @spec put_action_policy(Command.t(), map()) :: Command.t()
  defp put_action_policy(command, policy) do
    if Checkpoint.validate_value(policy) != :ok,
      do: raise(ArgumentError, "handle_action policy must be portable")

    %{command | opts: Keyword.put(command.opts, :action_policy, policy)}
  end

  defp validate_tool_state!(state) do
    if map_size(state.tool_bindings) > 0 do
      case Checkpoint.validate_state(state) do
        :ok -> :ok
        {:error, reason} -> raise ArgumentError, "Server state not portable: #{inspect(reason)}"
      end
    end
  end

  defp validate_stateful_commands!(state, commands, event) do
    validate_unique_waits!(state, commands)
    validate_foreground_waits!(state, commands)
    Enum.each(commands, &validate_stateful_command!(state, &1, event))
  end

  defp validate_foreground_waits!(state, commands) do
    foreground =
      Enum.count(commands, fn command ->
        command.kind == :await_reply and Keyword.get(command.opts, :foreground, false)
      end)

    if foreground > 1 or (foreground > 0 and not is_nil(state.foreground)),
      do: raise(ArgumentError, "foreground wait cannot replace an active pending")
  end

  defp validate_unique_waits!(state, commands) do
    ids = for %Command{kind: :await_reply, args: [id]} <- commands, do: id
    duplicate? = length(ids) != MapSet.size(MapSet.new(ids))
    existing? = Enum.any?(ids, &Map.has_key?(state.pending, &1))
    if duplicate? or existing?, do: raise(ArgumentError, "duplicate pending id")
  end

  defp validate_stateful_command!(state, %Command{kind: kind, args: [id]}, event)
       when kind in [:confirm_pending, :reject_pending, :explain_pending, :resume_pending] do
    pending =
      case Map.fetch(state.pending, id) do
        {:ok, pending} -> pending
        :error -> raise ArgumentError, "unknown pending id"
      end

    assert_pending_available!(state, pending, kind, id)
    validate_pending_input!(state, pending, kind, id, event)
    validate_consent_input!(pending, kind, event)
  end

  defp validate_stateful_command!(_state, %Command{kind: :route_current_input}, nil),
    do: raise(ArgumentError, "re-routing requires an input interaction")

  defp validate_stateful_command!(state, %Command{kind: :route_current_input, opts: opts}, _event) do
    if Keyword.has_key?(opts, :suspend) and not Map.has_key?(state.pending, opts[:suspend]),
      do: raise(ArgumentError, "unknown pending id to suspend")
  end

  defp validate_stateful_command!(_state, _command, _event), do: :ok

  defp assert_pending_available!(_state, %{status: status}, _kind, _id)
       when status in [:resolving, :uncertain],
       do: raise(ArgumentError, "pending is already resolving or under reconciliation")

  defp assert_pending_available!(state, %{kind: :reply}, :resume_pending, id) do
    if state.foreground not in [nil, id],
      do: raise(ArgumentError, "foreground wait cannot replace an active pending")
  end

  defp assert_pending_available!(_state, _pending, _kind, _id), do: :ok

  defp validate_pending_input!(_state, _pending, :resume_pending, _id, _event), do: :ok

  defp validate_pending_input!(state, pending, _kind, id, event) do
    unless not is_nil(event) and pending.status == :foreground and state.foreground == id,
      do: raise(ArgumentError, "pending resolution requires its foreground input")
  end

  defp validate_consent_input!(%{kind: :consent} = pending, kind, event)
       when kind in [:confirm_pending, :reject_pending],
       do: validate_confirmation_event!(pending, event)

  defp validate_consent_input!(_pending, _kind, _event), do: :ok

  defp validate_confirmation_event!(pending, event) do
    unless confirmation_event?(pending, event),
      do: raise(ArgumentError, "confirmation input does not belong to this presentation revision")
  end

  defp confirmation_event?(pending, event) do
    expected = %{id: pending.id, revision: Map.get(pending, :revision, 1)}
    snapshot_valid? = Map.get(event, :pending_snapshot) == expected
    newer? = Map.get(event, :sequence, 0) > Map.get(pending, :shown_at_sequence, 0)
    different? = event.id != event_id(pending.origin)

    snapshot_valid? and newer? and different? and not Map.get(event, :delegated, false)
  end

  defp execute(state, %Command{kind: :no_response}, _event), do: state

  defp execute(state, %Command{kind: :respond, args: [content], opts: opts}, event)
       when is_atom(content) do
    worker(state, :respond, Keyword.get(opts, :on_result, :respond), event, opts, fn ->
      Spectre.Server.Services.respond(content, service_context(state, event), opts)
    end)
  end

  defp execute(state, %Command{kind: :respond, args: [content], opts: opts}, event) do
    notify(
      state,
      {:response, event_id(event), content,
       if(Keyword.get(state.opts, :checkpoint),
         do: Keyword.put_new(opts, :message_id, state.active_command),
         else: opts
       )}
    )

    history =
      Enum.map(state.history, fn turn ->
        if turn.id == event_id(event),
          do: Map.update!(turn, :assistant, &(&1 <> to_string(content))),
          else: turn
      end)

    state = %{state | history: history}

    if event do
      text =
        case Enum.find(history, &(&1.id == event.id)) do
          nil -> content
          turn -> turn.assistant
        end

      %{state | memory_dirty: Map.put(state.memory_dirty, event.id, %{event: event, text: text})}
    else
      state
    end
  end

  defp execute(state, %Command{kind: kind, args: args, opts: opts}, event)
       when kind in [:generate, :classify, :propose, :call_actor, :delegate, :delegate_route] do
    worker(state, kind, Keyword.get(opts, :on_result, kind), event, opts, fn ->
      run_command(state, kind, args, opts, event)
    end)
  end

  defp execute(state, %Command{kind: :tool_call, args: [identity, args], opts: opts}, event) do
    worker(
      state,
      :tool_call,
      Keyword.fetch!(opts, :on_result),
      event,
      opts,
      fn ->
        Tool.invoke(state, identity, args, service_context(state, event))
      end,
      tool_identity: identity
    )
  end

  defp execute(state, %Command{kind: :tool_rejected, args: [result], opts: opts}, event) do
    worker = %{
      kind: :tool_rejected,
      tag: Keyword.fetch!(opts, :on_result),
      event: event,
      command_id: state.active_command
    }

    receive_result(state, worker, result)
  end

  defp execute(state, %Command{kind: :await_reply, args: [id], opts: opts}, event) do
    if Map.has_key?(state.pending, id), do: raise(ArgumentError, "duplicate pending id")
    timeout = Keyword.get(opts, :timeout, 30_000)

    pending = %{
      id: id,
      kind: :reply,
      status: if(Keyword.get(opts, :foreground, false), do: :foreground, else: :background),
      origin: event,
      on_result: Keyword.get(opts, :on_result, id),
      explicit_on_result: Keyword.has_key?(opts, :on_result),
      deadline:
        if(timeout == :infinity, do: nil, else: System.system_time(:millisecond) + timeout)
    }

    ref = make_ref()

    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(self(), {__MODULE__, ref, :timeout}, timeout)

    worker = %{
      kind: :await_reply,
      pid: nil,
      monitor: nil,
      timer: timer,
      tag: pending.on_result,
      explicit_on_result: pending.explicit_on_result,
      event: event,
      pending_id: id,
      command_id: state.active_command
    }

    %{
      state
      | pending: Map.put(state.pending, id, pending),
        foreground: if(pending.status == :foreground, do: id, else: state.foreground),
        workers: Map.put(state.workers, ref, worker)
    }
  end

  defp execute(state, %Command{kind: :resolve_await, args: [id, result]}, event) do
    case Enum.find(state.workers, fn {_ref, worker} ->
           worker.kind == :await_reply and worker.pending_id == id
         end) do
      nil ->
        state

      {ref, worker} ->
        cancel_timer(worker.timer)
        state = %{state | workers: Map.delete(state.workers, ref)}
        worker = if event, do: %{worker | event: event}, else: worker
        receive_result(state, worker, result)
    end
  end

  defp execute(state, %Command{kind: :route_current_input, opts: opts}, event) do
    state =
      case Keyword.get(opts, :suspend) do
        nil -> state
        id -> suspend_pending(state, id)
      end

    if opts[:lifecycle_interrupt], do: state, else: route(state, event)
  end

  defp execute(state, %Command{kind: :dispatch_interrupt}, event),
    do:
      apply_worker_result(
        state,
        %{kind: :route, event: event},
        {:ok, event.routing.route_key, event.routing}
      )

  defp execute(state, %Command{kind: kind, args: [id], opts: opts}, event)
       when kind in [:confirm_pending, :reject_pending, :explain_pending, :resume_pending] do
    pending = Map.fetch!(state.pending, id)

    if kind == :resume_pending and pending.kind == :reply do
      %{
        state
        | pending: Map.put(state.pending, id, %{pending | status: :foreground}),
          foreground: id
      }
    else
      locked =
        pending |> Map.put(:previous_status, pending.status) |> Map.put(:status, :resolving)

      state = %{state | pending: Map.put(state.pending, id, locked)}

      worker(
        state,
        kind,
        pending.on_result,
        event,
        opts,
        fn -> run_pending(state, kind, pending, event, opts) end,
        pending_id: id
      )
    end
  end

  defp run_command(state, :delegate, [id, input], _opts, _event),
    do: Skills.dispatch(state.skill_supervisor, id, state.active_command, input, nil)

  defp run_command(state, :delegate_route, [id], _opts, event) do
    dispatch = %{
      key: event.routing.route_key,
      routing: event.routing,
      memory: Map.get(event, :memory),
      received_at: event.received_at
    }

    Skills.dispatch(state.skill_supervisor, id, state.active_command, event.input, dispatch)
  end

  defp run_command(_state, :call_actor, [actor, request], opts, _event) do
    GenServer.call(actor, request, Keyword.get(opts, :timeout, 30_000))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:actor_exit, reason}}
  end

  defp run_command(state, :propose, [operation, args], opts, event) do
    context =
      state
      |> service_context(event)
      |> Map.put(:external_submission, Keyword.get(opts, :external_submission))

    bridge(state, :propose, [operation, args, context, opts])
  end

  defp run_command(state, kind, [value], opts, event) do
    request =
      case kind do
        :generate ->
          %{
            prompt: value,
            input: Keyword.get(opts, :input, if(event, do: event.input)),
            planning: Keyword.get(opts, :planning, false),
            stream: Keyword.get(opts, :stream, false),
            preview: Keyword.get(opts, :preview, :auto),
            assigns: Keyword.get(opts, :assigns, %{})
          }

        :classify ->
          %{
            input: value,
            choices: Keyword.get(opts, :choices),
            context: Keyword.get(opts, :context)
          }
      end

    binding = Map.get(state.services, kind, Spectre.Server.Services)
    invoke(binding, kind, [request, service_context(state, event), opts])
  end

  defp run_pending(state, kind, pending, event, opts) do
    action =
      Map.fetch!(
        %{
          confirm_pending: :confirm,
          reject_pending: :reject,
          explain_pending: :explain,
          resume_pending: :resume
        },
        kind
      )

    bridge(state, action, [
      pending,
      if(event, do: event.input),
      Map.merge(service_context(state, event), %{
        consent_proof: if(event, do: Map.get(event, :consent_proof)),
        consent_source_digest: if(event, do: Map.get(event, :consent_source_digest))
      }),
      opts
    ])
  end

  defp bridge(%{gam: nil}, _action, _args), do: {:error, :gam_not_configured}

  defp bridge(%{gam: {module, bridge_opts}}, action, args) when is_list(bridge_opts) do
    args = List.update_at(args, -1, &Keyword.put(&1, :bridge_config, bridge_opts))
    apply(module, action, args)
  end

  defp bridge(%{gam: module}, action, args) when is_atom(module), do: apply(module, action, args)

  defp invoke({module, function}, _default, args), do: apply(module, function, args)
  defp invoke(module, function, args) when is_atom(module), do: apply(module, function, args)

  defp service_context(state, event) do
    %{
      agent: state.agent,
      server: state.server,
      runtime: state.runtime_pid,
      identity: state.identity,
      skill: Keyword.get(state.opts, :skill),
      assigns: state.assigns,
      input: if(event, do: event.input),
      interaction: event_id(event),
      received_at: if(event, do: Map.get(event, :received_at)),
      event_sequence: if(event, do: Map.get(event, :sequence)),
      routing: Skills.routing(state, event),
      history: state.history,
      memory: if(event, do: Map.get(event, :memory)),
      current_flow: state.current_flow,
      current_scope: state.current_scope,
      command_id: state.active_command,
      options:
        Keyword.drop(state.opts, [
          :agent,
          :server,
          :skill_parent,
          :skill_options,
          :identity,
          :assigns,
          :gam,
          :checkpoint,
          :consumer,
          :submitters,
          :services,
          :name,
          :debug,
          :init_arg,
          :queue_limit,
          :max_steps,
          :worker_timeout,
          :hibernate_after,
          :spawn_opt
        ]),
      consumer: state.consumer
    }
  end

  defp worker(state, kind, tag, event, opts, function, extra \\ []) do
    owner = self()
    ref = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(
        Spectre.Server.TaskSupervisor,
        fn -> send(owner, {__MODULE__, ref, :result, function.()}) end
      )

    monitor = Process.monitor(pid)
    timeout = Keyword.get(opts, :timeout, Keyword.get(state.opts, :worker_timeout, 30_000))

    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(owner, {__MODULE__, ref, :timeout}, timeout)

    worker =
      Map.merge(
        %{
          kind: kind,
          tag: tag,
          event: event,
          pid: pid,
          monitor: monitor,
          timer: timer,
          opts: opts
        },
        Map.new(extra)
      )

    worker = Map.put(worker, :command_id, state.active_command)
    entry = Map.get(state.outbox, state.active_command, %{})

    worker =
      Map.put(
        worker,
        :explicit_on_result,
        Map.get(entry, :explicit_on_result, Keyword.has_key?(opts, :on_result))
      )

    %{state | workers: Map.put(state.workers, ref, worker)}
  end

  defp finish(%{current: nil} = state) do
    state = flush_memory(state)

    if not :queue.is_empty(state.queue) and not resolving_pending?(state),
      do: send(self(), {__MODULE__, state.control, :pump})

    state
  end

  defp finish(state) do
    id = state.current.id

    busy =
      Enum.any?(state.workers, fn {_ref, worker} ->
        worker.kind != :await_reply and not Map.get(worker, :detached, false) and
          event_id(worker.event) == id
      end)

    if busy do
      state
    else
      send(self(), {__MODULE__, state.control, :pump})
      state |> flush_memory() |> Map.put(:current, nil) |> Checkpoint.save()
    end
  end

  defp flush_memory(state) do
    entries = state.memory_dirty
    state = %{state | memory_dirty: %{}}

    Enum.reduce(entries, state, fn {id, entry}, state ->
      worker(
        %{state | active_command: nil},
        :remember,
        nil,
        entry.event,
        [],
        fn ->
          Spectre.Server.Memory.remember(
            state.agent,
            entry.event.input,
            entry.text,
            service_context(state, entry.event),
            memory_event_id: id
          )
        end,
        detached: true
      )
    end)
  end

  defp pump(%{current: nil} = state) do
    if resolving_pending?(state), do: state, else: pump_next(state)
  end

  defp pump(state), do: state

  defp pump_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} -> state
      {{:value, event}, queue} -> begin_input(%{state | queue: queue}, event)
    end
  end

  defp cancel_current(state) do
    id = event_id(state.current)

    {cancelled, keep} =
      Enum.split_with(state.workers, fn {_ref, worker} ->
        not is_nil(id) and event_id(worker.event) == id and
          worker.kind not in [
            :propose,
            :confirm_pending,
            :explain_pending,
            :resume_pending,
            :pending_lifecycle,
            :remember
          ]
      end)

    keep =
      Enum.map(keep, fn {ref, worker} ->
        {ref,
         if(event_id(worker.event) == id, do: Map.put(worker, :detached, true), else: worker)}
      end)

    Enum.each(cancelled, &stop_cancelled_worker/1)

    notify(state, {:cancelled, id})

    outbox =
      Enum.reduce(cancelled, state.outbox, fn {_ref, worker}, acc ->
        if match?(%{tool_identity: %{retry: :never}}, worker),
          do: acc,
          else: Map.delete(acc, Map.get(worker, :command_id))
      end)

    state =
      Enum.reduce(cancelled, state, fn {_ref, worker}, state ->
        if worker.kind == :await_reply, do: delete_pending(state, worker.pending_id), else: state
      end)

    state = %{state | workers: Map.new(keep), outbox: outbox} |> Checkpoint.save()

    Enum.reduce(cancelled, state, fn {_ref, worker}, current ->
      case worker do
        %{tool_identity: %{retry: :never}} ->
          receive_result(current, worker, tool_failure(worker, :cancelled))

        _ ->
          current
      end
    end)
  end

  defp stop_cancelled_worker({_ref, worker}) do
    if worker.pid, do: Process.exit(worker.pid, :kill)
    if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])
    cancel_timer(worker.timer)
  end

  defp suspend_pending(state, id) do
    pending = Map.fetch!(state.pending, id)

    %{
      state
      | pending: Map.put(state.pending, id, %{pending | status: :suspended}),
        foreground: if(state.foreground == id, do: nil, else: state.foreground)
    }
  end

  defp delete_pending(state, id) do
    state = cancel_pending_timer(state, id)
    state = cancel_close_timer(state, id)

    %{
      state
      | pending: Map.delete(state.pending, id),
        foreground: if(state.foreground == id, do: nil, else: state.foreground)
    }
  end

  defp arm_pending_timer(state, %{kind: :consent, expires_at: deadline} = pending)
       when is_integer(deadline) do
    state = cancel_pending_timer(state, pending.id)
    ref = make_ref()

    timer =
      Process.send_after(
        self(),
        {__MODULE__, ref, :expire_pending, pending.id},
        max(0, deadline - System.system_time(:millisecond))
      )

    entry = %{id: pending.id, revision: Map.get(pending, :revision, 1), timer: timer}
    %{state | pending_timers: Map.put(state.pending_timers, ref, entry)}
  end

  defp arm_pending_timer(state, _pending), do: state

  defp cancel_pending_timer(state, id) do
    {cancelled, keep} =
      Enum.split_with(state.pending_timers, fn {_ref, entry} -> entry.id == id end)

    Enum.each(cancelled, fn {_ref, entry} -> cancel_timer(entry.timer) end)
    %{state | pending_timers: Map.new(keep)}
  end

  defp expire_pending(state, id, revision) do
    case Map.get(state.pending, id) do
      %{status: status} when status in [:resolving, :uncertain] ->
        state

      %{kind: :consent, expires_at: deadline} = pending when is_integer(deadline) ->
        if Map.get(pending, :revision, 1) == revision and
             deadline <= System.system_time(:millisecond) do
          expire_current_pending(state, pending, revision)
        else
          state
        end

      _ ->
        state
    end
  end

  defp expire_current_pending(state, pending, revision) do
    if PendingLifecycle.configured?(state) do
      command = %Command{
        kind: :close_pending,
        args: [pending.id],
        opts: [reason: :consent_expired, if_revision: revision]
      }

      enqueue_runtime_commands(state, [command], pending.origin, %{
        expiry_result: pending.on_result
      })
    else
      worker = %{
        kind: :consent_expiry,
        tag: pending.on_result,
        event: pending.origin,
        pending_id: pending.id
      }

      event_id = "consent-expired:" <> Spectre.GAM.Canonical.Value.digest!({pending.id, revision})
      receive_result(state, worker, {:consent, :expired}, event_id)
    end
  end

  defp execute_entry(state, id, %{tool_contract_changed: true} = entry),
    do: recover_changed_tool(state, id, entry)

  defp execute_entry(state, id, entry) do
    if lifecycle_entry?(state, entry),
      do: execute_lifecycle_entry(state, id, entry),
      else: execute_regular_entry(state, id, entry)
  end

  defp enqueue_runtime_commands(state, commands, event, extra \\ %{}) do
    entries =
      Enum.map(commands, fn command ->
        {Spectre.Identity.uuid7(),
         Map.merge(%{command: command, event: event, execution_started: false}, extra)}
      end)

    state = %{state | outbox: Map.merge(state.outbox, Map.new(entries))} |> Checkpoint.save()
    execute_entries(state, entries)
  end

  defp execute_entries(state, []), do: state

  defp execute_entries(state, [{id, entry} | remaining]) do
    case expired_schedule(state, [entry.command]) do
      nil ->
        execute_current_entry(state, id, entry, remaining)

      pending ->
        ids = [id | Enum.map(remaining, &elem(&1, 0))]
        state = %{state | outbox: Map.drop(state.outbox, ids)} |> Checkpoint.save()

        command = %Command{
          kind: :close_pending,
          args: [pending.id],
          opts: [
            reason: :deadline_elapsed,
            if_revision: Map.get(pending, :revision, 1),
            if_schedule: pending.close_schedule.command_id
          ]
        }

        enqueue_runtime_commands(state, [command], entry.event, %{
          expiry_result: pending.on_result,
          policy_closed: true
        })
    end
  end

  defp execute_current_entry(state, id, entry, remaining) do
    if lifecycle_entry?(state, entry) do
      {state, entry} = block_lifecycle_following(state, id, entry, remaining)
      execute_lifecycle_entry(state, id, entry)
    else
      state = execute_entry(state, id, entry)
      execute_entries(state, remaining)
    end
  end

  defp block_lifecycle_following(state, id, entry, remaining) do
    continuation = PendingLifecycle.continuation(entry.command)

    following =
      if continuation,
        do: [
          {Spectre.Identity.uuid7(),
           %{
             command: continuation,
             event: entry.event,
             lifecycle_authorized: true,
             execution_started: false
           }}
          | remaining
        ],
        else: remaining

    blocked =
      Map.new(following, fn {next_id, next} -> {next_id, Map.put(next, :blocked_by, id)} end)

    entry = Map.put(entry, :following, Enum.map(following, &elem(&1, 0)))
    outbox = state.outbox |> Map.merge(blocked) |> Map.put(id, entry)
    {%{state | outbox: outbox} |> Checkpoint.save(), entry}
  end

  defp lifecycle_entry?(state, entry),
    do:
      not Map.get(entry, :lifecycle_authorized, false) and
        PendingLifecycle.command?(state, entry.command)

  defp execute_lifecycle_entry(state, id, %{lifecycle: lifecycle} = entry) do
    worker(
      %{state | active_command: id},
      :pending_lifecycle,
      id,
      entry.event,
      [],
      fn ->
        bridge(state, :record_lifecycle, [
          lifecycle.event,
          service_context(state, entry.event),
          []
        ])
      end,
      lifecycle_event_id: lifecycle.event.id
    )
    |> Map.put(:active_command, nil)
  end

  defp execute_lifecycle_entry(state, id, entry) do
    case PendingLifecycle.prepare(state, id, entry) do
      {:ok, lifecycle} ->
        entry = Map.put(entry, :lifecycle, lifecycle)
        state = %{state | outbox: Map.put(state.outbox, id, entry)} |> Checkpoint.save()
        execute_lifecycle_entry(state, id, entry)

      {:ignored, result} ->
        complete_lifecycle(state, id, entry, result)

      {:error, reason} ->
        reject_lifecycle_start(state, id, entry, reason)
    end
  end

  defp reject_lifecycle_start(state, id, entry, reason) do
    cancelled = [id | Map.get(entry, :following, [])]
    state = %{state | outbox: Map.drop(state.outbox, cancelled)} |> Checkpoint.save()
    lifecycle_error(state, entry, reason)
  end

  defp lifecycle_result(state, worker, result) do
    case Map.get(state.outbox, worker.command_id) do
      %{lifecycle: lifecycle} = entry ->
        cond do
          Map.get(worker, :lifecycle_event_id) != lifecycle.event.id ->
            state

          PendingLifecycle.receipt?(lifecycle, result) ->
            acquire_lifecycle_receipt(state, worker.command_id, entry, result)

          true ->
            lifecycle_error(state, entry, {:recording_failed, result})
        end

      _ ->
        state
    end
  end

  defp acquire_lifecycle_receipt(
         state,
         id,
         %{lifecycle: %{stage: :requested}} = entry,
         {:lifecycle_recorded, receipt}
       ) do
    {state, lifecycle, _report} = PendingLifecycle.apply_transition(state, entry.lifecycle)
    state = cleanup_lifecycle_transition(state, lifecycle)
    entry = %{entry | lifecycle: Map.put(lifecycle, :requested_receipt, receipt)}
    state = %{state | outbox: Map.put(state.outbox, id, entry)} |> Checkpoint.save()
    state = reconcile_close_timers(state)
    execute_lifecycle_entry(state, id, entry)
  end

  defp acquire_lifecycle_receipt(state, id, entry, {:lifecycle_recorded, receipt}),
    do:
      complete_lifecycle(
        state,
        id,
        entry,
        Map.put(entry.lifecycle.event, :evidence_refs, receipt.evidence_refs)
      )

  defp complete_lifecycle(state, id, entry, result) do
    completion =
      entry
      |> Map.take([:command, :event, :following, :expiry_result, :policy_closed])
      |> Map.merge(%{kind: :lifecycle_completion, tag: :pending_lifecycle, command_id: id})

    inbox = Map.put(state.inbox, id, %{worker: completion, result: {:pending_lifecycle, result}})
    state = %{state | outbox: Map.delete(state.outbox, id), inbox: inbox} |> Checkpoint.save()

    state =
      worker_result(%{state | processing_result: id}, completion, {:pending_lifecycle, result})

    state |> acquire_result() |> Checkpoint.save() |> reconcile_close_timers()
  end

  defp lifecycle_callback(state, %{expiry_result: tag, policy_closed: true} = entry, %{
         status: :applied
       }),
       do: conversation(state, :handle_result, [tag, {:consent, :closed_by_policy}], entry.event)

  defp lifecycle_callback(state, %{expiry_result: tag} = entry, %{status: :applied}),
    do: conversation(state, :handle_result, [tag, {:consent, :expired}], entry.event)

  defp lifecycle_callback(state, entry, result) do
    tag = Keyword.get(entry.command.opts, :on_result, :pending_lifecycle)
    conversation(state, :handle_result, [tag, {:pending_lifecycle, result}], entry.event)
  end

  defp cleanup_lifecycle_transition(state, %{
         event: %{kind: :close, status: :applied, pending_id: id}
       }) do
    {closed, keep} =
      Enum.split_with(state.workers, fn {_ref, worker} ->
        worker.kind == :await_reply and Map.get(worker, :pending_id) == id
      end)

    Enum.each(closed, fn {_ref, worker} -> cancel_timer(worker.timer) end)

    outbox =
      Enum.reduce(closed, state.outbox, fn {_ref, worker}, acc ->
        Map.delete(acc, worker.command_id)
      end)

    %{state | workers: Map.new(keep), outbox: outbox}
    |> cancel_pending_timer(id)
    |> cancel_close_timer(id)
  end

  defp cleanup_lifecycle_transition(state, _lifecycle), do: state

  defp lifecycle_error(state, entry, reason) do
    notify(state, {:pending_lifecycle_error, event_id(entry.event), reason})
    tag = Keyword.get(entry.command.opts, :on_result, :pending_lifecycle)

    conversation(
      state,
      :handle_result,
      [tag, {:error, {:pending_lifecycle, reason}}],
      entry.event
    )
  end

  defp timed_close(state, timer, id \\ Spectre.Identity.uuid7()) do
    if Map.has_key?(state.outbox, id) or Map.has_key?(state.inbox, id) or
         Map.has_key?(state.seen_events, id),
       do: state,
       else: enqueue_timed_close(state, timer, id)
  end

  defp enqueue_timed_close(state, timer, id) do
    command = %Command{
      kind: :close_pending,
      args: [timer.id],
      opts: [
        reason: timer.reason,
        policy_ref: timer.policy_ref,
        if_revision: timer.revision,
        deadline: timer.deadline,
        source: %{schedule_id: timer.schedule_id}
      ]
    }

    entry = %{command: command, event: nil, execution_started: false}

    case Enum.find(state.outbox, fn {_id, existing} ->
           get_in(existing, [:lifecycle, :requested, :pending_id]) == timer.id
         end) do
      nil ->
        state = %{state | outbox: Map.put(state.outbox, id, entry)} |> Checkpoint.save()
        execute_lifecycle_entry(state, id, entry)

      {active_id, active} ->
        active = Map.update(active, :following, [id], &(&1 ++ [id]))

        outbox =
          state.outbox
          |> Map.put(active_id, active)
          |> Map.put(
            id,
            entry |> Map.put(:blocked_by, active_id) |> Map.put(:lifecycle_independent, true)
          )

        %{state | outbox: outbox} |> Checkpoint.save()
    end
  end

  defp reconcile_close_timers(state) do
    state =
      Enum.reduce(state.close_timers, state, fn {_ref, timer}, state ->
        if get_in(state.pending, [timer.id, :close_schedule, :command_id]) != timer.schedule_id,
          do: cancel_close_timer(state, timer.id),
          else: state
      end)

    Enum.reduce(state.pending, state, fn {_id, pending}, state ->
      arm_close_timer(state, pending)
    end)
  end

  defp arm_close_timer(state, %{close_schedule: %{fired: true}}), do: state
  defp arm_close_timer(state, %{close_schedule: %{timer_owner: :application}}), do: state

  defp arm_close_timer(state, %{close_schedule: schedule} = pending) do
    active =
      Enum.any?(state.close_timers, fn {_ref, timer} ->
        timer.schedule_id == schedule.command_id and not timer.cancelled
      end)

    if active or PendingLifecycle.active?(state, pending.id) do
      state
    else
      ref = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {__MODULE__, ref, :close_pending},
          max(0, schedule.deadline - System.system_time(:millisecond))
        )

      timer = %{
        id: pending.id,
        schedule_id: schedule.command_id,
        revision: schedule.revision,
        deadline: schedule.deadline,
        reason: schedule.reason,
        policy_ref: schedule.policy_ref,
        timer: timer_ref,
        cancelled: false,
        created_at: System.monotonic_time()
      }

      %{state | close_timers: Map.put(state.close_timers, ref, timer)}
    end
  end

  defp arm_close_timer(state, _pending), do: state

  defp cancel_close_timer(state, id) do
    timers =
      Map.new(state.close_timers, fn {ref, timer} ->
        if timer.id == id do
          cancel_timer(timer.timer)
          {ref, %{timer | timer: nil, cancelled: true}}
        else
          {ref, timer}
        end
      end)

    {cancelled, active} = Enum.split_with(timers, fn {_ref, timer} -> timer.cancelled end)

    retained =
      cancelled
      |> Enum.sort_by(fn {_ref, value} -> value.created_at end)
      |> Enum.take(-256)
      |> Kernel.++(active)
      |> Map.new()

    %{state | close_timers: retained}
  end

  defp execute_regular_entry(state, id, entry) do
    state = mark_execution_started(state, id, entry)
    state = execute(%{state | active_command: id}, entry.command, entry.event)

    outstanding? =
      Enum.any?(state.workers, fn {_ref, worker} -> Map.get(worker, :command_id) == id end)

    state = %{state | active_command: nil}

    if outstanding?,
      do: state,
      else: %{state | outbox: Map.delete(state.outbox, id)} |> Checkpoint.save()
  end

  defp mark_execution_started(state, id, entry) do
    if (governed?(entry.command.kind) and not local_reply_resume?(state, entry)) or
         Tool.never?(entry.command) or entry.command.kind in [:delegate, :delegate_route] do
      entry = Map.put(entry, :execution_started, true)
      %{state | outbox: Map.put(state.outbox, id, entry)} |> Checkpoint.save()
    else
      state
    end
  end

  defp local_reply_resume?(state, %{command: %{kind: :resume_pending, args: [id]}}),
    do: match?(%{kind: :reply}, Map.get(state.pending, id))

  defp local_reply_resume?(_state, _entry), do: false

  defp receive_result(state, worker, result, result_id \\ nil)

  defp receive_result(state, %{kind: :pending_lifecycle} = worker, result, _result_id),
    do: lifecycle_result(state, worker, result)

  defp receive_result(state, %{kind: :resolve_delivery} = worker, result, _result_id) do
    complete_delivery(state, worker, result)
  end

  defp receive_result(state, %{kind: :remember} = worker, result, _result_id) do
    state = %{state | outbox: Map.delete(state.outbox, Map.get(worker, :command_id))}
    state = worker_result(state, worker, result)
    Checkpoint.save(state)
  end

  defp receive_result(state, %{kind: :release_command} = worker, result, _result_id),
    do: worker_result(state, worker, result)

  defp receive_result(
         state,
         %{recovered: true, kind: kind} = worker,
         {:error, reason},
         _result_id
       )
       when kind in [:propose, :confirm_pending, :explain_pending, :resume_pending],
       do: uncertain_governed(state, nil, worker, {:reconciliation_unavailable, reason})

  defp receive_result(
         state,
         %{uncertain: true, kind: kind} = worker,
         {:error, reason},
         _result_id
       )
       when kind in [:propose, :confirm_pending, :explain_pending, :resume_pending],
       do: uncertain_governed(state, nil, worker, {:reconciliation_unavailable, reason})

  defp receive_result(state, worker, result, result_id) do
    source = Map.get(state.outbox, Map.get(worker, :command_id), %{})
    worker = Map.put_new(worker, :explicit_on_result, Map.get(source, :explicit_on_result, false))
    fallback_id = Map.get(worker, :command_id) || result_id || Spectre.Identity.uuid7()
    id = Delivery.result_key(result, fallback_id)
    worker = if result_id, do: Map.put(worker, :external_event_id, result_id), else: worker

    if Map.has_key?(state.seen_events, id) or
         Operations.seen_result?(state, Map.get(worker, :command_id), id) or
         settled_worker_result?(state, worker, result) do
      %{state | outbox: Map.delete(state.outbox, Map.get(worker, :command_id))}
      |> Checkpoint.save()
    else
      acquire_worker_result(state, worker, result, id)
    end
  end

  defp settled_worker_result?(state, %{command_id: id, kind: kind}, {:governed, _})
       when is_binary(id) do
    governed?(kind) and not Map.has_key?(state.outbox, id) and
      not Map.has_key?(state.operations, id)
  end

  defp settled_worker_result?(_state, _worker, _result), do: false

  defp acquire_worker_result(state, worker, result, id) do
    recorded = Operations.record(state, worker, result)

    safe_worker =
      Map.take(worker, [
        :explicit_on_result,
        :kind,
        :tag,
        :event,
        :pending_id,
        :command_id,
        :opts,
        :recovered,
        :uncertain,
        :external_event_id,
        :tool_identity
      ])

    case stage_worker_result(recorded, safe_worker, result, id) do
      {:deferred, reason} ->
        uncertain_governed(state, nil, worker, {:result_not_acquired, Tool.bounded(reason)})

      {staged, acquired_result} ->
        staged = Checkpoint.save(staged)
        staged = worker_result(%{staged | processing_result: id}, safe_worker, acquired_result)
        staged = staged |> acquire_result() |> Checkpoint.save()
        release_worker_journal(staged, worker)
    end
  end

  defp stage_worker_result(state, worker, result, id) do
    staged = %{
      state
      | outbox: Map.delete(state.outbox, Map.get(worker, :command_id)),
        inbox: Map.put(state.inbox, id, %{worker: worker, result: result})
    }

    validation =
      if map_size(state.tool_bindings) > 0, do: Checkpoint.validate_state(staged), else: :ok

    case {worker.kind, validation} do
      {kind, {:error, reason}} when kind in [:tool_call, :tool_rejected] ->
        replace_unportable_result(staged, worker, id, :tool_result_not_portable, reason)

      {kind, {:error, reason}}
      when kind in [:generate, :classify, :call_actor, :prepare_input] ->
        if map_size(state.tool_bindings) > 0,
          do: replace_unportable_result(staged, worker, id, :service_result_not_portable, reason),
          else: {staged, result}

      {kind, {:error, reason}}
      when kind in [:propose, :confirm_pending, :explain_pending, :resume_pending] ->
        if map_size(state.tool_bindings) > 0, do: {:deferred, reason}, else: {staged, result}

      _ ->
        {staged, result}
    end
  end

  defp replace_unportable_result(state, worker, id, type, reason) do
    replacement = tool_failure(worker, {type, Tool.bounded(reason)})

    {%{state | inbox: Map.put(state.inbox, id, %{worker: worker, result: replacement})},
     replacement}
  end

  defp tool_failure(%{tool_identity: %{retry: :never} = identity} = worker, reason),
    do: Tool.unknown(identity, worker.command_id, reason)

  defp tool_failure(%{kind: kind} = worker, reason) when kind in [:delegate, :delegate_route],
    do: {:skill_unknown, %{command_id: Map.get(worker, :command_id), reason: reason}}

  defp tool_failure(_worker, reason), do: {:error, reason}

  defp complete_delivery(state, worker, {:governed, _} = result) do
    id = Delivery.result_key(result, worker.external_event_id)

    command_id =
      case worker.delivery_tag do
        {:command, command_id} -> command_id
        _ -> nil
      end

    if Map.has_key?(state.seen_events, id) or Operations.seen_result?(state, command_id, id) do
      GenServer.reply(worker.reply_to, :ok)
      state
    else
      deliver_registered_result(state, worker, result)
    end
  end

  defp complete_delivery(state, worker, {:error, reason}) do
    GenServer.reply(worker.reply_to, {:error, reason})
    state
  end

  defp complete_delivery(state, worker, _invalid) do
    GenServer.reply(worker.reply_to, {:error, :invalid_result_resolution})
    state
  end

  defp deliver_registered_result(state, %{delivery_tag: {:pending, _}} = worker, result),
    do: deliver_resolved(state, worker, result)

  defp deliver_registered_result(
         state,
         %{delivery_tag: {:command, id}} = worker,
         {:governed, %{act: act}} = result
       ) do
    cond do
      Map.has_key?(state.operations, id) ->
        case Operations.matching(state, id, act) do
          :ok -> deliver_resolved(state, worker, result)
          {:error, reason} -> reject_delivery(state, worker, reason)
        end

      Map.get(worker, :command_verified, false) ->
        deliver_resolved(state, worker, result)

      Map.has_key?(state.outbox, id) ->
        verify_command_delivery(state, worker, result, id)

      true ->
        reject_delivery(state, worker, :unknown_command_continuation)
    end
  end

  defp deliver_registered_result(state, worker, _result) do
    GenServer.reply(worker.reply_to, {:error, :unregistered_governed_continuation})
    state
  end

  defp verify_command_delivery(state, worker, result, id) do
    {:ok, reference} = Spectre.Server.GAM.result_reference(result)

    worker(
      state,
      :resolve_delivery,
      nil,
      nil,
      [],
      fn ->
        bridge(state, :resolve_command_result, [id, reference, service_context(state, nil), []])
      end,
      reply_to: worker.reply_to,
      delivery_tag: worker.delivery_tag,
      external_event_id: worker.external_event_id,
      command_verified: true
    )
  end

  defp reject_delivery(state, worker, reason) do
    GenServer.reply(worker.reply_to, {:error, reason})
    state
  end

  defp release_worker_journal(state, worker) do
    if governed?(worker.kind),
      do: release_command_journal(state, Map.get(worker, :command_id)),
      else: state
  end

  defp release_command_journal(state, nil), do: state

  defp release_command_journal(state, id) do
    module =
      case state.gam do
        {module, _opts} -> module
        module -> module
      end

    if is_atom(module) and not is_nil(module) and Code.ensure_loaded?(module) and
         function_exported?(module, :release_command, 3) do
      worker(
        %{state | active_command: nil},
        :release_command,
        nil,
        nil,
        [],
        fn ->
          bridge(state, :release_command, [id, service_context(state, nil), []])
        end,
        detached: true
      )
    else
      state
    end
  end

  defp deliver_resolved(state, worker, result) do
    with :ok <- Delivery.matching_pending(state, worker.delivery_tag, result),
         {:ok, continuation} <- delivery_worker(state, worker.delivery_tag) do
      state = retire_delivered_worker(state, continuation)
      state = receive_result(state, continuation, result)
      GenServer.reply(worker.reply_to, :ok)
      state
    else
      {:error, reason} ->
        GenServer.reply(worker.reply_to, {:error, reason})
        state
    end
  end

  defp acquire_result(%{processing_result: nil} = state), do: state

  defp acquire_result(state) do
    id = state.processing_result
    entry = Map.get(state.inbox, id)
    external_id = get_in(state.inbox, [id, :worker, :external_event_id])

    state = %{state | inbox: Map.delete(state.inbox, id), processing_result: nil}
    state = Inbox.mark_seen(state, id)
    state = if external_id, do: Inbox.mark_seen(state, external_id), else: state
    release_lifecycle_following(state, entry)
  end

  defp release_lifecycle_following(state, %{
         worker: %{kind: :lifecycle_completion} = worker,
         result: {:pending_lifecycle, result}
       }) do
    ids = Map.get(worker, :following, [])

    following =
      for id <- ids,
          entry = Map.get(state.outbox, id),
          not is_nil(entry),
          result.status == :applied or Map.get(entry, :lifecycle_independent, false),
          do: {id, Map.delete(entry, :blocked_by)}

    outbox = state.outbox |> Map.drop(ids) |> Map.merge(Map.new(following))
    %{state | outbox: outbox, released_commands: state.released_commands ++ following}
  end

  defp release_lifecycle_following(state, _entry), do: state

  defp recover(state) do
    state = Enum.reduce(state.inbox, state, &recover_inbox_entry/2)
    state = Enum.reduce(state.outbox, state, &recover_outbox_entry/2)

    state =
      Enum.reduce(state.pending, state, fn {_id, pending}, state ->
        arm_pending_timer(state, pending)
      end)

    state |> reconcile_close_timers() |> recover_current()
  end

  defp recover_inbox_entry({id, entry}, state) do
    state = worker_result(%{state | processing_result: id}, entry.worker, entry.result)
    state = state |> acquire_result() |> Checkpoint.save()
    release_worker_journal(state, entry.worker)
  end

  defp recover_outbox_entry({id, entry}, state) do
    cond do
      recovery_blocked?(state, id, entry) ->
        state

      Map.get(entry, :tool_contract_changed) == true ->
        recover_changed_tool(state, id, entry)

      Map.has_key?(entry, :lifecycle) ->
        execute_lifecycle_entry(state, id, entry)

      entry.command.kind == :await_reply ->
        recover_reply_wait(state, id, entry)

      replayable_entry?(state, entry) ->
        execute_entries(state, [{id, entry}])

      true ->
        recover_started_entry(state, id, entry)
    end
  end

  @spec recover_started_entry(map(), binary(), map()) :: map()
  defp recover_started_entry(state, id, entry) do
    cond do
      entry.command.kind in [:delegate, :delegate_route] ->
        worker = %{
          kind: :delegate,
          tag: Keyword.get(entry.command.opts, :on_result, :delegate),
          event: entry.event,
          command_id: id
        }

        receive_result(state, worker, {:skill_unknown, %{command_id: id, reason: :interrupted}})

      Tool.never?(entry.command) ->
        [identity, _args] = entry.command.args

        worker = %{
          kind: :tool_call,
          tag: Keyword.fetch!(entry.command.opts, :on_result),
          event: entry.event,
          command_id: id,
          tool_identity: identity
        }

        receive_result(state, worker, Tool.unknown(identity, id, :interrupted))

      entry.command.kind in [:propose, :confirm_pending, :explain_pending, :resume_pending] ->
        recover_governed(state, id, entry)

      true ->
        execute_entry(state, id, entry)
    end
  end

  defp recover_changed_tool(
         state,
         id,
         %{command: %{kind: :propose}, execution_started: started} = entry
       )
       when started != false do
    notify(state, {:tool_contract_changed, id, :reconciliation_required})
    recover_governed(state, id, entry)
  end

  defp recover_changed_tool(state, id, %{command: %{kind: :propose}} = entry)
       when not is_map_key(entry, :execution_started) do
    notify(state, {:tool_contract_changed, id, :reconciliation_required})
    recover_governed(state, id, entry)
  end

  defp recover_changed_tool(state, id, entry) do
    command = entry.command

    worker = %{
      kind: :tool_rejected,
      tag: Keyword.fetch!(command.opts, :on_result),
      event: entry.event,
      command_id: id
    }

    result =
      case command do
        %Command{kind: :tool_call, args: [%{retry: :never} = identity, _]} ->
          Tool.unknown(identity, id, :tool_contract_changed)

        _ ->
          {:error, :tool_contract_changed}
      end

    receive_result(state, worker, result)
  end

  defp recovery_blocked?(state, id, entry),
    do: Map.has_key?(entry, :blocked_by) or active_command?(state, id)

  defp replayable_entry?(state, entry),
    do: local_reply_resume?(state, entry) or Map.get(entry, :execution_started) == false

  defp active_command?(state, id),
    do: Enum.any?(state.workers, fn {_ref, worker} -> Map.get(worker, :command_id) == id end)

  defp recover_reply_wait(state, id, entry) do
    [pending_id] = entry.command.args

    case Map.fetch(state.pending, pending_id) do
      {:ok, pending} -> restore_await(state, id, pending)
      :error -> execute_entry(state, id, entry)
    end
  end

  defp recover_current(%{current: nil} = state) do
    send(self(), {__MODULE__, state.control, :pump})
    state
  end

  defp recover_current(state) do
    id = state.current.id
    outstanding = Enum.any?(state.workers, fn {_ref, worker} -> event_id(worker.event) == id end)
    if outstanding, do: state, else: recover_idle_current(state, Map.get(state.current, :phase))
  end

  defp recover_idle_current(state, :commands), do: finish(state)
  defp recover_idle_current(state, _phase), do: start_input_preparation(state, state.current)

  defp start_input_preparation(state, %{skill_dispatch: _} = event),
    do: prepared_input(state, event)

  defp start_input_preparation(state, event) do
    worker(state, :prepare_input, nil, event, [], fn -> prepare_input_result(state, event) end)
  end

  defp prepare_input_result(state, event) do
    with {:ok, input} <- Spectre.Server.Router.prepare_input(state.agent, event.input),
         {:ok, memory} <-
           Spectre.Server.Memory.recall(state.agent, input, service_context(state, event), []) do
      {:ok, input, memory}
    end
  end

  defp recover_governed(state, id, entry) do
    if recoverable_bridge?(state.gam) do
      start_governed_recovery(state, id, entry)
    else
      # Missing receipts cannot establish absence of an external effect.
      notify(state, {:recovery_required, id, entry.command.kind})
      state
    end
  end

  defp recoverable_bridge?({module, _opts}), do: recoverable_bridge?(module)

  defp recoverable_bridge?(module) do
    is_atom(module) and not is_nil(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :recover_command, 3)
  end

  defp start_governed_recovery(state, id, entry) do
    {tag, extra} = recovery_continuation(state, entry)
    extra = Keyword.put(extra, :recovered, true)
    state = %{state | active_command: id}

    state =
      worker(
        state,
        entry.command.kind,
        tag,
        entry.event,
        entry.command.opts,
        fn ->
          bridge(state, :recover_command, [
            id,
            service_context(state, entry.event),
            entry.command.opts
          ])
        end,
        extra
      )

    %{state | active_command: nil}
  end

  defp recovery_continuation(state, %{command: command}) do
    pending_id =
      case {command.kind, command.args} do
        {kind, [pending_id]}
        when kind in [
               :await_reply,
               :confirm_pending,
               :reject_pending,
               :explain_pending,
               :resume_pending
             ] ->
          pending_id

        _ ->
          nil
      end

    tag =
      case Map.get(state.pending, pending_id) do
        %{on_result: on_result} -> on_result
        _ -> Keyword.get(command.opts, :on_result, command.kind)
      end

    {tag, if(pending_id, do: [pending_id: pending_id], else: [])}
  end

  defp restore_await(state, command_id, pending) do
    ref = make_ref()

    timer =
      case pending.deadline do
        nil ->
          nil

        deadline ->
          Process.send_after(
            self(),
            {__MODULE__, ref, :timeout},
            max(0, deadline - System.system_time(:millisecond))
          )
      end

    worker = %{
      kind: :await_reply,
      pid: nil,
      monitor: nil,
      timer: timer,
      tag: pending.on_result,
      event: pending.origin,
      pending_id: pending.id,
      command_id: command_id
    }

    %{state | workers: Map.put(state.workers, ref, worker)}
  end

  defp delivery_worker(state, {:command, id}) do
    case Operations.continuation(state, id) do
      {:ok, worker} -> {:ok, worker}
      {:error, _} -> outbox_continuation(state, id)
    end
  end

  defp delivery_worker(state, {:pending, id}) do
    case Map.fetch(state.pending, id) do
      {:ok, pending} ->
        pending_delivery_worker(state, pending)

      :error ->
        {:error, :unknown_pending_continuation}
    end
  end

  defp delivery_worker(_state, tag), do: {:ok, %{kind: :delivery, tag: tag, event: nil}}

  defp pending_delivery_worker(state, pending) do
    workers =
      for {_ref, worker} <- state.workers,
          Map.get(worker, :pending_id) == pending.id,
          do: worker

    commands =
      for {id, %{command: command}} <- state.outbox,
          governed?(command.kind) and command.args == [pending.id],
          do: id

    select_pending_continuation(state, pending, workers, commands)
  end

  defp select_pending_continuation(_state, _pending, [worker], []), do: {:ok, worker}

  defp select_pending_continuation(_state, _pending, [%{command_id: id} = worker], [id]),
    do: {:ok, worker}

  defp select_pending_continuation(state, pending, [], commands) do
    case commands do
      [id] ->
        outbox_continuation(state, id)

      [] ->
        {:ok,
         %{kind: :delivery, tag: pending.on_result, event: pending.origin, pending_id: pending.id}}

      _ ->
        {:error, :ambiguous_pending_continuation}
    end
  end

  defp select_pending_continuation(_state, _pending, _workers, _commands),
    do: {:error, :ambiguous_pending_continuation}

  defp retire_delivered_worker(state, continuation) do
    command_id = Map.get(continuation, :command_id)

    {retired, retained} =
      Enum.split_with(state.workers, fn {_ref, worker} ->
        not is_nil(command_id) and Map.get(worker, :command_id) == command_id
      end)

    Enum.each(retired, fn {_ref, worker} ->
      cancel_timer(worker.timer)
      if worker.monitor, do: Process.demonitor(worker.monitor, [:flush])
      if worker.pid && not governed?(worker.kind), do: Process.exit(worker.pid, :kill)
    end)

    %{state | workers: Map.new(retained)}
  end

  defp outbox_continuation(state, id) do
    case Map.fetch(state.outbox, id) do
      {:ok, entry} ->
        {tag, extra} = recovery_continuation(state, entry)
        worker = %{kind: entry.command.kind, tag: tag, event: entry.event, command_id: id}
        {:ok, Map.merge(worker, Map.new(extra))}

      :error ->
        {:error, :unknown_command_continuation}
    end
  end

  defp governed?(kind),
    do: kind in [:propose, :confirm_pending, :explain_pending, :resume_pending]

  defp resolving_pending?(state) do
    case Map.get(state.pending, state.foreground) do
      %{status: :resolving} -> true
      _ -> false
    end
  end

  defp uncertain_governed(state, ref, worker, reason) do
    notify(state, {:recovery_required, Map.get(worker, :command_id), worker.kind})

    if Map.get(worker, :uncertain, false) do
      state
    else
      workers =
        if Map.has_key?(state.workers, ref),
          do: Map.put(state.workers, ref, Map.put(worker, :uncertain, true)),
          else: state.workers

      state =
        %{state | workers: workers} |> suspend_uncertain_pending(worker) |> Checkpoint.save()

      conversation(
        state,
        :handle_result,
        [
          worker.tag,
          {:governed_unknown,
           %{command_id: Map.get(worker, :command_id), reason: inspect(reason, limit: 10)}}
        ],
        worker.event
      )
    end
  end

  defp suspend_uncertain_pending(state, worker) do
    case Map.get(state.pending, Map.get(worker, :pending_id)) do
      %{kind: :consent} = pending ->
        pending = %{pending | status: :uncertain}

        %{
          state
          | pending: Map.put(state.pending, pending.id, pending),
            foreground: if(state.foreground == pending.id, do: nil, else: state.foreground)
        }

      _ ->
        state
    end
  end

  defp event_id(nil), do: nil
  defp event_id(event), do: event.id
  defp make_pending_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp notify(%{consumer: pid}, event) when is_pid(pid),
    do: send(pid, {Spectre.Server, self(), event})

  defp notify(_, _), do: :ok
end
