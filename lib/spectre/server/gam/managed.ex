defmodule Spectre.Server.GAM.Managed do
  @moduledoc """
  Standard AgentServer integration with the existing GAM kernel.

  Its authenticated Scope stays private. The trusted application configuration
  declares authority for its represented principal; Agent, Skill and external
  actor provenance is recorded separately. The runtime owns the GAM protocol.

  Mounted Skill runtimes reuse this root-owned integration and its one Domain;
  they do not bootstrap another kernel or copy the authority ledger. Local
  checkpoints and pending intentions remain isolated, and mount restrictions
  cannot widen the root's configured operation authority.
  """
  use GenServer
  alias Spectre.GAM
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Server.GAM, as: Bridge
  alias Spectre.Server.GAM.Invocation
  alias Spectre.Server.GAM.Managed.{Binding, Bootstrap, Gate, Reviewer}
  alias Spectre.Server.GAM.Managed.Identity, as: ManagedIdentity
  alias Spectre.GAM.Domain.Recovery.Policy, as: RecoveryPolicy
  alias Spectre.Server.{Session, TaskGuard}

  @doc "Starts the standard private Domain integration for an AgentServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, identity} <- ManagedIdentity.normalize(Keyword.get(opts, :identity, %{})) do
      start_owner(Keyword.put(opts, :identity, identity))
    end
  end

  @spec start_owner(keyword()) :: GenServer.on_start()
  defp start_owner(opts) do
    # Allocation may fail after starting linked stores. Link the caller only
    # after bootstrap succeeds, so an expected startup error remains a result.
    case GenServer.start(__MODULE__, opts) do
      {:ok, server} ->
        Process.link(server)
        {:ok, server}

      {:error, _} = error ->
        error
    end
  end

  @doc "Stops intake and drains acquired bridge work before closing owned resources."
  @spec close(pid()) :: :ok | {:error, :shutdown_drain_timeout}
  def close(server) do
    monitor = Process.monitor(server)

    try do
      result = GenServer.call(server, :close, :infinity)

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> result
      end
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:normal, _} -> :ok
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc false
  @spec revoke(pid()) :: {:ok, GAM.Proposal.Result.t()} | {:error, term()}
  def revoke(server), do: GenServer.call(server, :revoke, :infinity)

  @doc false
  @spec dispose(pid(), binary(), GAM.Duty.Disposition.kind(), keyword(), pid()) ::
          {:ok, GAM.Proposal.Result.t()} | {:error, term()}
  def dispose(server, duty_ref, kind, options, caller),
    do: GenServer.call(server, {:dispose, duty_ref, kind, options, caller}, :infinity)

  @doc false
  @spec runtime_checkpoint(pid()) :: {module(), term(), {:managed_agent, binary()}}
  def runtime_checkpoint(server), do: GenServer.call(server, :runtime_checkpoint)

  @doc false
  @spec session(pid()) :: Session.t() | {:error, :untrusted_reset_transport}
  def session(server), do: GenServer.call(server, :session)

  @doc false
  @spec prepare_reset(pid(), reference() | nil) ::
          {:ok, %{session: Session.t(), domain: binary()}} | {:error, term()}
  def prepare_reset(server, control \\ nil),
    do: GenServer.call(server, {:prepare_reset, control}, :infinity)

  @doc false
  @spec resume_reset(pid(), reference() | nil) :: :ok | {:error, term()}
  def resume_reset(server, control \\ nil), do: GenServer.call(server, {:resume_reset, control})

  @doc false
  @spec adopt_reset(pid(), Session.t()) :: :ok | {:error, term()}
  def adopt_reset(server, session), do: GenServer.call(server, {:adopt_reset, session})

  @doc false
  def recover_storage(server, decision), do: GenServer.call(server, {:recover_storage, decision})
  @doc "Returns public Domain references."
  @spec info(pid()) :: map()
  def info(server), do: GenServer.call(server, :info)
  @doc "Queries authoritative GAM state without executing a command."
  @spec view(pid(), pid()) :: {:ok, map()} | {:error, term()}
  def view(server, caller \\ self()) do
    GenServer.call(server, {:view, caller})
  end

  @doc false
  @spec diagnostics(pid(), keyword(), pid()) :: {:ok, map()} | {:error, term()}
  def diagnostics(server, opts, caller), do: GenServer.call(server, {:diagnostics, opts, caller})

  @doc false
  @spec subscribe(pid(), pid()) :: :ok | {:error, atom()}
  def subscribe(server, caller), do: GenServer.call(server, {:subscribe, caller})

  @doc "Acknowledges rendering through the configured consumer."
  @spec presented(pid(), binary(), pid()) :: :ok | {:error, atom()}
  def presented(server, ref, caller),
    do: call_gate(server, :presented, [ref, caller])

  @doc "Issues one-use, presentation-bound proof of a consumer decision."
  @spec authorize_decision(pid(), binary(), :confirm | :reject, pid()) ::
          {:ok, binary()} | {:error, atom()}
  def authorize_decision(server, ref, decision, caller),
    do: call_gate(server, :authorize, [ref, decision, caller])

  @doc "Records authenticated transport provenance for a reply interpreted by the configured binding."
  @spec authorize_input(pid(), binary(), binary(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize_input(server, ref, text, caller),
    do: call_gate(server, :authorize_input, [ref, text, caller])

  @doc false
  def approval_message(server, message),
    do: call_gate(server, :receive_message, [message])

  @doc false
  def approval_reply(server, id, decision, caller),
    do: call_gate(server, :reply, [id, decision, caller])

  @doc false
  def approval_io(server, operation, client),
    do: call_gate(server, :io, [operation, client])

  @doc false
  def pending_approval(server, ref),
    do: call_gate(server, :pending_decision, [ref])

  defp call_gate(server, operation, args) do
    case GenServer.call(server, :gate) do
      gate when is_pid(gate) -> apply(Gate, operation, [gate | args])
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :managed_gate_unavailable}
  end

  @doc false
  def checkpoint_binding(server), do: GenServer.call(server, :checkpoint_binding, :infinity)

  @doc false
  @spec lifecycle_configured?(keyword()) :: boolean()
  def lifecycle_configured?(_), do: true
  @doc false
  @spec execution(pid(), GAM.Act.t()) :: {:ok, map(), map()} | {:error, atom()}
  def execution(server, act), do: GenServer.call(server, {:execution, act})
  @doc false
  @spec propose(term(), map(), map(), keyword()) :: term()
  def propose(operation, args, context, opts),
    do: invoke(:propose, [operation, args], context, opts, operation)

  @doc false
  @spec confirm(map(), Spectre.Input.t(), map(), keyword()) :: term()
  def confirm(pending, input, context, opts),
    do: invoke(:confirm, [pending, input], context, opts, pending.operation)

  @doc false
  @spec reject(map(), Spectre.Input.t(), map(), keyword()) :: term()
  def reject(pending, input, context, opts),
    do: invoke(:reject, [pending, input], context, opts, pending.operation)

  @doc false
  @spec resume(map(), Spectre.Input.t(), map(), keyword()) :: term()
  def resume(pending, input, context, opts),
    do: invoke(:resume, [pending, input], context, opts, pending.operation)

  @doc false
  @spec explain(map(), Spectre.Input.t(), map(), keyword()) :: term()
  def explain(pending, input, context, opts), do: resume(pending, input, context, opts)
  @doc false
  @spec record_lifecycle(map(), map(), keyword()) :: term()
  def record_lifecycle(event, context, opts),
    do: invoke(:record_lifecycle, [event], context, opts)

  @doc false
  @spec recover_command(binary(), map(), keyword()) :: term()
  def recover_command(id, context, opts), do: invoke(:recover_command, [id], context, opts)
  @doc false
  @spec release_command(binary(), map(), keyword()) :: term()
  def release_command(id, context, opts), do: invoke(:release_command, [id], context, opts)
  @doc false
  @spec resolve_result(map(), map(), keyword()) :: term()
  def resolve_result(reference, context, opts),
    do: invoke(:resolve_result, [reference], context, opts)

  @doc false
  @spec resolve_command_result(binary(), map(), map(), keyword()) :: term()
  def resolve_command_result(id, reference, context, opts),
    do: invoke(:resolve_command_result, [id, reference], context, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(Keyword.fetch!(opts, :runtime))
    {bootstrap_monitor, guardian} = monitor_bootstrap_owner(opts)
    result = Bootstrap.open(opts, self())
    TaskGuard.stop(guardian)

    case result do
      {:ok, state} ->
        {:ok,
         Map.merge(state, %{
           workers: %{},
           reset_token: nil,
           closing: false,
           close_waiters: [],
           owner_monitor: owner_monitor,
           bootstrap_monitor: bootstrap_monitor
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:session, {caller, _}, state) do
    if caller == state.options[:runtime],
      do: {:reply, state.session, state},
      else: {:reply, {:error, :untrusted_reset_transport}, state}
  end

  def handle_call({:prepare_reset, control}, {caller, _}, state) do
    if reset_authorized?(state, caller, control),
      do: reserve_reset(state),
      else: {:reply, {:error, :untrusted_reset_transport}, state}
  end

  def handle_call({:resume_reset, control}, {caller, _}, state) do
    if reset_authorized?(state, caller, control) do
      resume_reset_gates(state, state.reset_token)

      next =
        case Map.pop(%{state | reset_token: nil}, :reset_storage_recovery) do
          {{decision, delay}, next} -> schedule_storage_recovery(next, decision, delay)
          {nil, next} -> next
        end

      {:reply, :ok, next}
    else
      {:reply, {:error, :untrusted_reset_transport}, state}
    end
  end

  def handle_call({:adopt_reset, session}, {caller, _}, state) do
    cond do
      caller != state.options[:runtime] ->
        {:reply, {:error, :untrusted_reset_transport}, state}

      not match?(%Session{}, session) or session.domain != state.refs.domain ->
        {:reply, {:error, :invalid_server_session}, state}

      true ->
        if state.bootstrap_monitor, do: Process.demonitor(state.bootstrap_monitor, [:flush])
        session = %{session | base_options: state.session.base_options}
        {:reply, :ok, %{state | bootstrap_monitor: nil, session: session}}
    end
  end

  def handle_call({:recover_storage, :retry}, _, %{ephemeral: true} = state),
    do: {:reply, {:error, :ephemeral_history_cannot_be_recovered}, state}

  def handle_call({:recover_storage, decision}, {caller, _}, state) do
    if caller == state.options[:runtime] and decision in [:memory, :retry],
      do: {:reply, :ok, schedule_storage_recovery(state, decision, 0)},
      else: {:reply, {:error, :untrusted_storage_recovery}, state}
  end

  def handle_call(:checkpoint_binding, _, state) do
    if state.domain,
      do: {:reply, {:ok, state.refs.domain, checkpoint_reference(state)}, state},
      else: {:reply, {:error, :gam_storage_unavailable}, state}
  end

  def handle_call(request, _from, %{storage_unavailable: reason} = state)
      when request != :close and request != :info and request != :runtime_checkpoint,
      do: {:reply, {:error, {:gam_storage_unavailable, reason}}, state}

  def handle_call(:revoke, {caller, _}, state) do
    result =
      if caller == state.options[:runtime] do
        GAM.revoke_mandate(state.scope, state.mandate.ref, %{
          identity_key: "spectre:managed:revoke:" <> state.refs.domain
        })
      else
        {:error, :untrusted_governance_transport}
      end

    {:reply, result, state}
  end

  def handle_call({:dispose, duty_ref, kind, options, caller}, {runtime, _}, state) do
    result =
      if runtime == state.options[:runtime] and not state.closing,
        do: Reviewer.dispose(state, duty_ref, kind, options, caller),
        else: {:error, :untrusted_governance_transport}

    {:reply, result, state}
  end

  def handle_call(:runtime_checkpoint, _, state),
    do: {:reply, checkpoint_reference(state), state}

  def handle_call(:info, _, state), do: {:reply, state.refs, state}
  def handle_call(:gate, _, state), do: {:reply, state.gate, state}

  def handle_call({:view, caller}, {runtime, _} = from, state) do
    reviewer = if state.reviewer, do: state.reviewer.consumer

    if runtime == state.options[:runtime] and caller in [state.options[:consumer], reviewer],
      do: start_diagnostic_read(state, from, :view),
      else: {:reply, {:error, :untrusted_audit_transport}, state}
  end

  def handle_call({:diagnostics, opts, caller}, {runtime, _} = from, state) do
    if runtime == state.options[:runtime] and caller == state.options[:consumer] do
      start_diagnostic_read(state, from, {:diagnostics, opts})
    else
      {:reply, {:error, :untrusted_audit_transport}, state}
    end
  end

  def handle_call({:subscribe, caller}, {runtime, _}, state) do
    if runtime == state.options[:runtime] and caller == state.options[:consumer] do
      {result, state} = ensure_diagnostics_subscription(state)
      {:reply, result, state}
    else
      {:reply, {:error, :untrusted_audit_transport}, state}
    end
  end

  def handle_call(:close, from, state),
    do: begin_close(%{state | close_waiters: [from | state.close_waiters]})

  def handle_call(:checkout, _, %{storage_recovery: _} = state),
    do: {:reply, {:error, :managed_storage_recovering}, state}

  def handle_call(:checkout, _, %{reset_token: token} = state) when not is_nil(token),
    do: {:reply, {:error, :reset_busy}, state}

  def handle_call(:checkout, {worker, _}, %{closing: false} = state) do
    workers = Map.put_new_lazy(state.workers, worker, fn -> Process.monitor(worker) end)

    # Ordinary proposal workers receive only their own scope and bridge
    # configuration. The independent reviewer scope never leaves its owner.
    snapshot =
      state
      |> Map.take([:scope, :refs, :row, :mandate, :show_mandate, :effects, :journal, :gate])
      |> Map.put(
        :options,
        Keyword.take(state.options, [
          :bindings,
          :store,
          :consent_ttl_ms,
          :approvals,
          :payload_store
        ])
      )
      |> Map.update!(:options, fn options ->
        case options[:approvals] do
          nil -> options
          config -> Keyword.put(options, :approvals, Map.take(config, [:address, :approvers]))
        end
      end)

    {:reply, {:ok, snapshot}, %{state | workers: workers}}
  end

  def handle_call(:checkout, _, state), do: {:reply, {:error, :managed_domain_closing}, state}

  def handle_call({:execution, act}, _, state) do
    entry =
      Enum.find_value(state.effects, fn {_, value} -> if value.class == act.class, do: value end)

    reply =
      with %{effect: effect} <- entry,
           true <- act.consequence["effect_contract_ref"] == effect.contract_ref,
           identity when is_map(identity) <- act.consequence["execution_identity"],
           true <- identity == canonical_identity(state.options[:identity]) do
        frozen = Map.get(act.consequence, "execution_context", %{})

        options =
          Keyword.merge(
            Keyword.take(Keyword.get(state.options, :options, []), [:namespace]),
            Keyword.take(state.options, [:stack_runtime])
          )

        options =
          if frozen["namespace"],
            do: Keyword.put(options, :namespace, frozen["namespace"]),
            else: Keyword.delete(options, :namespace)

        {:ok, effect,
         %{
           agent: state.options[:agent],
           command_id: act.ref,
           identity: state.options[:identity],
           options: options,
           current_flow: frozen["current_flow"],
           current_scope: frozen["current_scope"],
           skill: frozen["skill"]
         }}
      else
        _ -> {:error, :managed_execution_binding_mismatch}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:checkin, worker}, state) do
    {monitor, workers} = Map.pop(state.workers, worker)
    if monitor, do: Process.demonitor(monitor, [:flush])
    finish_close(%{state | workers: workers})
  end

  @impl true
  def handle_info({__MODULE__.Recovery, token, decision}, %{token: token} = state) do
    case decision do
      :memory -> {:noreply, schedule_storage_recovery(state, :memory, 0)}
      {:retry, delay} -> {:noreply, schedule_storage_recovery(state, :retry, delay)}
      :wait -> {:noreply, state}
    end
  end

  # A replaced Domain (or a failed bootstrap) can finish its notification after
  # recovery. Its incident belongs to that previous storage generation.
  def handle_info({__MODULE__.Recovery, _token, _incident}, state), do: {:noreply, state}

  def handle_info({:recover_storage, token}, %{storage_recovery: {token, decision}} = state) do
    if state.closing do
      {:noreply, state}
    else
      if map_size(state.workers) == 0,
        do: recover_owned_storage(state, decision),
        else:
          {:noreply,
           schedule_storage_recovery(Map.delete(state, :storage_recovery), decision, 25)}
    end
  end

  def handle_info({:recover_storage, _token}, state), do: {:noreply, state}

  def handle_info({:diagnostic_read, token, result}, state),
    do: {:noreply, finish_diagnostic_read(state, token, result)}

  def handle_info({:diagnostic_read_timeout, token}, state),
    do: {:noreply, finish_diagnostic_read(state, token, {:error, :diagnostic_source_unavailable})}

  def handle_info({:diagnostics_revision, revision}, state) do
    unless Map.get(state, :diagnostics_timer),
      do: Process.send_after(self(), :diagnostics_flush, 50)

    {:noreply,
     state
     |> Map.put(:diagnostics_timer, true)
     |> Map.put(:diagnostics_revision, max(revision, Map.get(state, :diagnostics_revision, 0)))}
  end

  def handle_info(:diagnostics_flush, state) do
    if is_pid(state.options[:consumer]) do
      send(
        state.options[:consumer],
        {Spectre.Server, state.options[:runtime],
         {:diagnostics_changed,
          %{source: :gam, revision: Map.get(state, :diagnostics_revision, 0)}}}
      )
    end

    {:noreply, Map.put(state, :diagnostics_timer, false)}
  end

  def handle_info(:diagnostics_resubscribe, state) do
    state = Map.put(state, :diagnostics_retry, nil)

    if state.closing do
      {:noreply, state}
    else
      {_result, state} = ensure_diagnostics_subscription(state)
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _notifier, _},
        %{diagnostics_monitor: monitor} = state
      ) do
    state = Map.merge(state, %{diagnostics_notifier: nil, diagnostics_monitor: nil})
    {:noreply, retry_diagnostics_subscription(state)}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state),
    do: begin_close(state)

  def handle_info(
        {:DOWN, monitor, :process, _owner, _reason},
        %{bootstrap_monitor: monitor} = state
      ),
      do: begin_close(state)

  def handle_info({:DOWN, monitor, :process, worker, _}, state) do
    case Enum.find(Map.get(state, :diagnostic_reads, %{}), fn {_token, read} ->
           read.monitor == monitor
         end) do
      {token, _} ->
        {:noreply, finish_diagnostic_read(state, token, {:error, :diagnostic_source_unavailable})}

      nil ->
        if Map.get(state.workers, worker) == monitor,
          do: finish_close(%{state | workers: Map.delete(state.workers, worker)}),
          else: {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.options[:runtime] ->
        begin_close(state)

      pid == state.domain ->
        {:noreply, Map.put(state, :storage_unavailable, reason)}

      pid in [state.gate | state.owned] ->
        {:stop, {:managed_component_stopped, reason}, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:drain_timeout, state) do
    Enum.each(state.close_waiters, &GenServer.reply(&1, {:error, :shutdown_drain_timeout}))
    {:stop, :normal, %{state | close_waiters: []}}
  end

  defp schedule_storage_recovery(%{reset_token: token} = state, decision, delay)
       when not is_nil(token),
       do: Map.put_new(state, :reset_storage_recovery, {decision, delay})

  defp schedule_storage_recovery(state, decision, delay) do
    if Map.has_key?(state, :storage_recovery) do
      state
    else
      token = make_ref()
      Process.send_after(self(), {:recover_storage, token}, delay)
      Map.put(state, :storage_recovery, {token, decision})
    end
  end

  @spec reserve_reset(map()) :: {:reply, term(), map()}
  defp reserve_reset(state) do
    with :ok <- reset_available(state),
         token = make_ref(),
         :ok <- reserve_reset(state, token) do
      {:reply, {:ok, %{session: state.session, domain: state.refs.domain}},
       %{state | reset_token: token}}
    else
      error -> {:reply, error, state}
    end
  end

  @spec reserve_reset(map(), reference()) :: :ok | {:error, term()}
  defp reserve_reset(state, token) do
    with :ok <- pause_reset_gates(state, token),
         :ok <- reset_duties_idle(state.scope) do
      :ok
    else
      error ->
        resume_reset_gates(state, token)
        error
    end
  end

  @spec reset_available(map()) :: :ok | {:error, term()}
  defp reset_available(%{closing: true}), do: {:error, :reset_busy}

  defp reset_available(%{reset_token: token}) when not is_nil(token),
    do: {:error, :reset_busy}

  defp reset_available(%{workers: workers}) when map_size(workers) > 0,
    do: {:error, :reset_busy}

  defp reset_available(%{storage_recovery: _}), do: {:error, :reset_busy}

  defp reset_available(%{storage_unavailable: reason}),
    do: {:error, {:gam_storage_unavailable, reason}}

  defp reset_available(_state), do: :ok

  @spec reset_authorized?(map(), pid(), reference() | nil) :: boolean()
  defp reset_authorized?(state, caller, control) do
    runtime = state.options[:runtime]

    caller == runtime or
      (is_reference(control) and control == state.options[:runtime_control] and
         Process.alive?(runtime))
  end

  @spec reset_gates(map()) :: [pid()]
  defp reset_gates(state),
    do: [state.gate | if(state.reviewer, do: [state.reviewer.gate], else: [])]

  @spec pause_reset_gates(map(), reference()) :: :ok | {:error, term()}
  defp pause_reset_gates(state, token) do
    Enum.reduce_while(reset_gates(state), :ok, fn gate, :ok ->
      case Gate.pause_for_reset(gate, token) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  catch
    :exit, _ -> {:error, :managed_gate_unavailable}
  end

  @spec resume_reset_gates(map(), reference() | nil) :: :ok
  defp resume_reset_gates(_state, nil), do: :ok

  defp resume_reset_gates(state, token) do
    Enum.each(reset_gates(state), fn gate ->
      try do
        Gate.resume_reset(gate, token)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  @spec reset_duties_idle(GAM.Scope.t()) :: :ok | {:error, term()}
  defp reset_duties_idle(scope) do
    case GenServer.call(scope.domain.server, :unresolved_duties, 5_000) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :reconciliation_required}
      {:error, reason} -> {:error, {:gam_storage_unavailable, reason}}
    end
  catch
    :exit, _ -> {:error, :gam_storage_unavailable}
  end

  @spec monitor_bootstrap_owner(keyword()) :: {reference() | nil, pid() | nil}
  defp monitor_bootstrap_owner(opts) do
    owner = opts[:bootstrap_owner]

    if is_pid(owner) do
      # init cannot handle a monitor message while an adapter call is blocked.
      # Once bootstrap returns, the ordinary owner monitor handles cleanup.
      {:ok, guardian} = TaskGuard.start(owner, self())
      {Process.monitor(owner), guardian}
    else
      {nil, nil}
    end
  end

  defp recover_owned_storage(%{ephemeral: true} = state, :retry) do
    {:noreply, Map.delete(state, :storage_recovery)}
  end

  defp recover_owned_storage(state, decision) do
    {options, retained} = recovery_resources(state, decision)

    case Bootstrap.open(options, self()) do
      {:ok, recovered} ->
        recovered = %{recovered | owned: recovered.owned ++ retained}
        checkpoint = recovered_checkpoint(decision, recovered)

        send(
          state.options[:runtime],
          {Spectre.Server.Runtime, state.options[:runtime_control], :gam_storage_recovered,
           %{
             checkpoint: checkpoint,
             previous_domain: state.refs.domain,
             domain: recovered.refs.domain
           }}
        )

        next =
          recovered
          |> Map.merge(
            Map.take(state, [
              :workers,
              :closing,
              :close_waiters,
              :owner_monitor,
              :bootstrap_monitor,
              :reset_token
            ])
          )
          |> restore_diagnostics(state)

        {:noreply, next}

      {:error, reason} ->
        next =
          state
          |> Map.delete(:storage_recovery)
          |> Map.put(:storage_unavailable, reason)
          |> Map.merge(%{domain: nil, gate: nil, owned: retained, options: options})

        incident = %{
          domain_ref: state.refs.domain,
          phase: :runtime,
          reason: reason,
          last_verified: nil
        }

        case RecoveryPolicy.recover(
               state.options[:recovery_policy],
               incident,
               Keyword.get(state.options, :recovery_timeout, 5_000)
             ) do
          :memory when decision != :memory ->
            {:noreply, schedule_storage_recovery(next, :memory, 0)}

          {:retry, delay} ->
            {:noreply, schedule_storage_recovery(next, :retry, delay)}

          _ when decision == :retry ->
            {:noreply, schedule_storage_recovery(next, :retry, 1_000)}

          _ ->
            {:noreply, next}
        end
    end
  end

  defp recovery_resources(state, :memory) do
    terminate(:storage_recovery, state)
    {:ok, _candidate, options} = Session.prepare(state.session, :memory)
    {options, []}
  end

  defp recovery_resources(state, :retry) do
    # A local coordination Store belongs to the running Server, including its
    # Skill checkpoints. Keep that owner while replacing the Domain resources.
    journal = unwrap_journal(state.journal)
    {_, pid} = journal
    retained = Enum.filter(state.owned, &(&1 == pid))
    terminate(:storage_recovery, %{state | owned: state.owned -- retained})

    options =
      state.options |> Keyword.put(:store, journal) |> Keyword.put(:session, state.session)

    {options, retained}
  end

  defp unwrap_journal({Spectre.Server.Store.Payload, %{store: store}}), do: store
  defp unwrap_journal(store), do: store

  defp recovered_checkpoint(:memory, state), do: checkpoint_reference(state)
  defp recovered_checkpoint(:retry, _state), do: nil

  defp restore_diagnostics(next, previous) do
    if Map.get(previous, :diagnostics_registered),
      do: elem(ensure_diagnostics_subscription(next), 1),
      else: next
  end

  defp checkpoint_reference(state) do
    {module, reference} = state.journal
    {module, reference, {:managed_agent, state.refs.domain}}
  end

  @spec ensure_diagnostics_subscription(map()) :: {:ok | {:error, atom()}, map()}
  defp ensure_diagnostics_subscription(state) do
    notifier = Map.get(state, :diagnostics_notifier)

    if is_pid(notifier) and Process.alive?(notifier) do
      {:ok, state}
    else
      resubscribe_diagnostics(state)
    end
  end

  defp resubscribe_diagnostics(state) do
    if monitor = Map.get(state, :diagnostics_monitor), do: Process.demonitor(monitor, [:flush])

    case GAM.Domain.Notifications.subscribe(state.refs.domain) do
      {:ok, notifier} ->
        if timer = Map.get(state, :diagnostics_retry), do: Process.cancel_timer(timer)

        state =
          Map.merge(state, %{
            diagnostics_notifier: notifier,
            diagnostics_monitor: Process.monitor(notifier),
            diagnostics_retry: nil,
            diagnostics_registered: true
          })

        {:noreply, state} = start_diagnostic_read(state, :refresh, :head)
        {:ok, state}

      {:error, _} ->
        # Subscription is an accepted intent, even while its disposable
        # notification process is being replaced. Checkpoint delivery stays on.
        {:ok, retry_diagnostics_subscription(state)}
    end
  end

  @spec start_diagnostic_read(map(), GenServer.from() | :refresh, term()) :: tuple()
  defp start_diagnostic_read(state, from, request) do
    reads = Map.get(state, :diagnostic_reads, %{})

    if state.closing or map_size(reads) >= 4 do
      if from == :refresh do
        {:noreply, state}
      else
        {:reply, {:error, :diagnostic_source_unavailable}, state}
      end
    else
      owner = self()
      token = make_ref()
      domain = state.scope.domain.server
      query = if request == :head, do: :head, else: {:query, state.scope, request}

      {pid, monitor} =
        spawn_monitor(fn ->
          result =
            try do
              GenServer.call(domain, query, 3_500)
            catch
              :exit, _ -> {:error, :diagnostic_source_unavailable}
            end

          send(owner, {:diagnostic_read, token, result})
        end)

      timer = Process.send_after(self(), {:diagnostic_read_timeout, token}, 4_000)
      read = %{pid: pid, monitor: monitor, timer: timer, from: from}
      {:noreply, Map.put(state, :diagnostic_reads, Map.put(reads, token, read))}
    end
  end

  @spec finish_diagnostic_read(map(), reference(), term()) :: map()
  defp finish_diagnostic_read(state, token, result) do
    case Map.pop(Map.get(state, :diagnostic_reads, %{}), token) do
      {nil, _} ->
        state

      {read, remaining} ->
        Process.cancel_timer(read.timer)
        Process.demonitor(read.monitor, [:flush])
        if Process.alive?(read.pid), do: Process.exit(read.pid, :kill)

        case {read.from, result} do
          {:refresh, {:ok, %{revision: revision}}} ->
            send(self(), {:diagnostics_revision, revision})

          {:refresh, _} ->
            :ok

          {from, result} ->
            GenServer.reply(from, result)
        end

        Map.put(state, :diagnostic_reads, remaining)
    end
  end

  @spec retry_diagnostics_subscription(map()) :: map()
  defp retry_diagnostics_subscription(state) do
    if Map.get(state, :diagnostics_retry) || state.closing do
      state
    else
      Map.put(
        state,
        :diagnostics_retry,
        Process.send_after(self(), :diagnostics_resubscribe, 100)
      )
    end
  end

  @spec finish_close(map()) :: {:noreply, map()} | {:stop, :normal, map()}
  defp finish_close(%{closing: true, workers: workers} = state) when map_size(workers) == 0 do
    Enum.each(state.close_waiters, &GenServer.reply(&1, :ok))
    {:stop, :normal, %{state | close_waiters: []}}
  end

  defp finish_close(state), do: {:noreply, state}

  defp begin_close(state) do
    Process.send_after(
      self(),
      :drain_timeout,
      Keyword.get(state.options, :shutdown_timeout, 30_000)
    )

    finish_close(%{state | closing: true})
  end

  @impl true
  def format_status(status) do
    state = status.state

    %{
      status
      | state: %{
          domain_ref: state.refs.domain,
          closing: state.closing,
          active_workers: map_size(state.workers),
          operations: Map.keys(state.operations)
        }
    }
  end

  @impl true
  def terminate(_, state) do
    Enum.each(Map.get(state, :diagnostic_reads, %{}), fn {_token, read} ->
      Process.cancel_timer(read.timer)
      Process.exit(read.pid, :kill)

      if read.from != :refresh,
        do: GenServer.reply(read.from, {:error, :diagnostic_source_unavailable})
    end)

    Bootstrap.close_resources(state)

    :ok
  end

  @spec invoke(atom(), list(), map(), keyword(), term()) :: term()
  defp invoke(function, args, context, opts, operation \\ nil) do
    with config when is_list(config) <- opts[:bridge_config],
         server when is_pid(server) <- config[:server],
         {:ok, state} <- GenServer.call(server, :checkout) do
      try do
        invoke_bridge(function, args, context, opts, operation, state)
      after
        GenServer.cast(server, {:checkin, self()})
      end
    else
      _ -> {:error, :managed_gam_not_running}
    end
  end

  @spec invoke_bridge(atom(), list(), map(), keyword(), term(), map()) :: term()
  defp invoke_bridge(function, args, context, opts, operation, state) do
    with {:ok, policy} <- effective_policy(args, opts, context, state),
         :ok <- validate_policy(policy) do
      context =
        Map.merge(context, %{
          managed: binding_context(state),
          managed_operation: operation,
          managed_policy: policy,
          managed_revision: managed_revision(args)
        })

      bridge = [
        scope: state.scope,
        response_scope: response_scope(state, context),
        bindings: Binding.bindings(state, operation, policy),
        lifecycle: true,
        store: state.journal,
        consent_ttl_ms: ttl(state, policy, operation),
        ingress_opts: [
          gate: state.gate,
          consent_proof: Map.get(context, :consent_proof),
          source_digest: Map.get(context, :consent_source_digest),
          payload_store: state.options[:payload_store]
        ]
      ]

      case {function, Map.has_key?(state.effects, operation), Map.fetch(policy, :reject)} do
        {:propose, false, _} ->
          reject_preparation(state, context, operation, :operation_not_allowed)

        {:propose, true, {:ok, reason}} ->
          reject_preparation(state, context, operation, reason)

        _ ->
          result =
            apply(
              Bridge,
              function,
              args ++ [context, Keyword.put(opts, :bridge_config, bridge)]
            )

          cleanup_closed_show(state.gate, function, args, result)
          bound = bind_pending_deadline(state.gate, result)
          retire_previous_show(state.gate, args, bound)
          bound
      end
    end
  end

  defp managed_revision([%{kind: :consent, revision: revision} | _]), do: revision + 1
  defp managed_revision(_), do: 1

  defp response_scope(state, context) do
    proof = Map.get(context, :consent_proof)

    case Gate.external_auth(state.gate, proof) do
      {:ok, _} ->
        with {:ok, authenticated} <-
               GAM.Domain.Sequencer.authenticate(state.scope.domain.server, state.refs.scope, %{
                 gate: state.gate,
                 external_proof: proof
               }),
             {:ok, scope} <- GAM.Scope.new(state.scope.domain, authenticated) do
          scope
        else
          _ -> state.scope
        end

      _ ->
        state.scope
    end
  end

  @spec reject_preparation(map(), map(), term(), term()) :: term()
  defp reject_preparation(state, context, operation, reason) do
    with {:ok, _} <-
           Invocation.record(state.scope, context, operation,
             ingress_opts: [gate: state.gate, payload_store: state.options[:payload_store]]
           ),
         {:ok, _} <-
           GAM.observe(
             state.scope,
             %{
               kind: :spectre_action_rejected,
               operation: operation,
               reason: reason,
               command_id: context.command_id
             },
             ingress_opts: [gate: state.gate, payload_store: state.options[:payload_store]]
           ) do
      {:error, {:action_rejected, reason}}
    end
  end

  @spec cleanup_closed_show(pid(), atom(), list(), term()) :: :ok
  defp cleanup_closed_show(
         gate,
         :record_lifecycle,
         [%{phase: :applied, kind: kind, show_ref: show_ref}],
         {:lifecycle_recorded, _}
       )
       when kind in [:close, :suspend] and is_binary(show_ref),
       do: Gate.close_show(gate, show_ref)

  defp cleanup_closed_show(_gate, _function, _args, _result), do: :ok

  @spec retire_previous_show(pid(), list(), term()) :: :ok
  defp retire_previous_show(
         gate,
         [%{kind: :consent, show: %{primary: %{act: %{ref: old_ref}}}} | _],
         {:pending, %{kind: :consent, show: %{primary: %{act: %{ref: new_ref}}}}}
       )
       when old_ref != new_ref,
       do: Gate.close_show(gate, old_ref)

  defp retire_previous_show(_gate, _args, _result), do: :ok

  @spec binding_context(map()) :: map()
  defp binding_context(state) do
    effects =
      Map.new(state.effects, fn {operation, entry} ->
        {operation,
         %{
           class: entry.class,
           settings: entry.settings,
           effect: Map.take(entry.effect, [:contract_ref, :schema_hash])
         }}
      end)

    state
    |> Map.take([:refs, :row, :mandate, :show_mandate, :gate])
    |> Map.put(:effects, effects)
    |> Map.put(:options, Keyword.take(state.options, [:bindings, :approvals, :payload_store]))
  end

  @spec validate_policy(term()) :: :ok | {:error, atom()}
  defp validate_policy(policy) when is_map(policy) and not is_struct(policy) do
    allowed = [:confirm, :message, :expires_in, :bind, :reject]

    valid? =
      Map.keys(policy) -- allowed == [] and
        is_boolean(Map.get(policy, :confirm, false)) and
        is_binary(Map.get(policy, :message, "")) and
        is_map(Map.get(policy, :bind, %{})) and
        valid_ttl?(Map.get(policy, :expires_in, :infinity)) and Value.validate(policy) == :ok

    if valid?, do: :ok, else: {:error, :invalid_managed_action_policy}
  end

  defp validate_policy(_), do: {:error, :invalid_managed_action_policy}

  @spec valid_ttl?(term()) :: boolean()
  defp valid_ttl?(:infinity), do: true
  defp valid_ttl?(value), do: is_integer(value) and value > 0

  @spec bind_pending_deadline(pid(), term()) :: term()
  defp bind_pending_deadline(_gate, {:pending, %{status: :suspended}} = result), do: result

  defp bind_pending_deadline(
         gate,
         {:pending, %{kind: :consent, presentation: presentation} = pending} = result
       ) do
    show_ref = get_in(pending, [:show, Access.key(:primary), Access.key(:act), Access.key(:ref)])

    case Gate.bind_deadline(gate, presentation.ref, pending.expires_at, show_ref) do
      :ok -> result
      {:error, _} = error -> error
    end
  end

  defp bind_pending_deadline(_gate, result), do: result

  @spec ttl(map(), map(), term()) :: pos_integer() | :infinity
  defp ttl(state, policy, operation) do
    configured = Keyword.get(state.options, :consent_ttl_ms, 300_000)

    operation_ttl =
      case Map.get(state.effects, operation) do
        nil -> configured
        entry -> Keyword.get(entry.settings, :expires_in, configured)
      end

    configured =
      if configured == :infinity, do: operation_ttl, else: min(configured, operation_ttl)

    case Map.get(policy, :expires_in) do
      ttl when is_integer(ttl) and ttl > 0 ->
        if configured == :infinity, do: ttl, else: min(ttl, configured)

      _ ->
        configured
    end
  end

  @spec effective_policy(list(), keyword(), map(), map()) :: {:ok, map()} | {:error, term()}
  defp effective_policy(args, opts, context, state) do
    with {:ok, policy} <- requested_policy(args, opts, state) do
      if is_map(policy) and
           (get_in(context, [:routing, :protected]) not in [nil, false] or
              Keyword.get(opts, :confirmation) not in [nil, false]),
         do: {:ok, Map.put(policy, :confirm, true)},
         else: {:ok, policy}
    end
  end

  defp requested_policy(
         [%{candidate: %{consequence: %{"managed_policy" => frozen}}} | _],
         _,
         state
       ) do
    with {:ok, frozen} <- restore_policy(state, frozen) do
      policy =
        [:confirm, :message, :expires_in, :bind, :reject]
        |> Map.new(fn key ->
          {key, Map.get(frozen, Atom.to_string(key), Map.get(frozen, key))}
        end)
        |> Map.reject(fn {_, value} -> is_nil(value) end)

      {:ok, policy}
    end
  end

  defp requested_policy(_, opts, _), do: {:ok, Keyword.get(opts, :action_policy, %{})}

  defp restore_policy(state, frozen) do
    with {:ok, material} <-
           Spectre.Server.GAM.Managed.Payload.restore(
             state.options[:payload_store],
             frozen,
             %{kind: :operation, domain_ref: state.refs.domain}
           ) do
      policy = if is_map(material), do: Map.get(material, "managed_policy", material)
      if is_map(policy), do: {:ok, policy}, else: {:error, :invalid_operation_payload}
    end
  end

  @spec canonical_identity(map()) :: map()
  defp canonical_identity(identity),
    do: Map.new(identity, fn {key, value} -> {to_string(key), value} end)
end
