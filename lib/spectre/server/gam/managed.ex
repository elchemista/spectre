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
  alias Spectre.Server.{Activities, Session, TaskGuard}

  @typedoc false
  @type attachment :: {reference(), reference(), pid()}

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
  @spec reattach(pid(), attachment(), reference()) ::
          {:ok, Session.t()} | {:error, term()}
  def reattach(server, attachment, control),
    do: GenServer.call(server, {:reattach, attachment, control}, :infinity)

  @doc false
  @spec confirm_attachment(pid()) :: :ok | {:error, atom()}
  def confirm_attachment(server), do: GenServer.call(server, :confirm_attachment)

  @doc false
  @spec activity_owner(pid(), :existing | :start) ::
          {:ok, {pid(), reference()} | nil} | {:error, term()}
  def activity_owner(server, mode), do: GenServer.call(server, {:activity_owner, mode})

  @doc false
  @spec register_activity(pid(), reference(), binary()) :: :ok | {:error, term()}
  def register_activity(server, control, ref),
    do: activity_fence(server, control, {:register, ref})

  @doc false
  @spec retire_activity(pid(), reference(), binary()) :: :ok | {:error, term()}
  def retire_activity(server, control, ref),
    do: activity_fence(server, control, {:retire, ref})

  @doc false
  @spec close_activity_show(pid(), reference(), binary()) :: :ok | {:error, term()}
  def close_activity_show(server, control, show_ref) do
    with {:ok, gate} <- GenServer.call(server, {:activity_gate, control}) do
      Gate.close_show(gate, show_ref)
    end
  catch
    :exit, _ -> {:error, :activity_gate_unavailable}
  end

  @doc false
  @spec fence_activity(pid(), reference(), GAM.Domain.Admission.Fence.transition()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fence_activity(server, control, transition),
    do: activity_fence(server, control, {:advance, transition})

  defp activity_fence(server, control, command) do
    with {:ok, domain, token} <- GenServer.call(server, {:activity_fence, control}) do
      GAM.Domain.Sequencer.activity_fence(domain, token, command)
    end
  catch
    :exit, _ -> {:error, :activity_fence_unavailable}
  end

  @doc false
  @spec presentation_ready?(pid(), binary()) :: boolean()
  def presentation_ready?(server, ref), do: call_gate(server, :presentation_ready?, [ref]) == true

  @doc false
  @spec prepare_reset(pid(), reference() | nil) ::
          {:ok, %{session: Session.t(), domain: binary()}} | {:error, term()}
  def prepare_reset(server, control \\ nil),
    do: GenServer.call(server, {:prepare_reset, control}, :infinity)

  @doc false
  @spec mark_reset_activating(pid(), binary() | nil) :: :ok | {:error, atom()}
  def mark_reset_activating(_server, nil), do: :ok

  def mark_reset_activating(server, generation),
    do: GenServer.call(server, {:mark_reset_activating, generation})

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
  @spec bind_consent_event(pid(), binary(), binary()) :: :ok | {:error, term()}
  def bind_consent_event(server, proof, event_id),
    do: call_gate(server, :bind_consent_event, [proof, event_id])

  @doc false
  @spec consent_events(pid()) :: %{optional(binary()) => binary()}
  def consent_events(server) do
    case call_gate(server, :consent_events, []) do
      %{} = events -> events
      {:error, _} -> %{}
    end
  end

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

    with :ok <- register_initial_attachment(opts), do: open_owner(opts)
  end

  defp open_owner(opts) do
    owner_monitor = Process.monitor(Keyword.fetch!(opts, :runtime))
    host_monitor = monitor_attachment_host(opts)
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
           host_monitor: host_monitor,
           attachment_confirmed: false,
           pending_attachment: nil,
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

  def handle_call(:confirm_attachment, {caller, _}, state) do
    if caller == state.options[:runtime] and not state.closing,
      do: {:reply, :ok, %{state | attachment_confirmed: true}},
      else: {:reply, {:error, :untrusted_reattachment}, state}
  end

  def handle_call({:reattach, attachment, control}, from, state) do
    cond do
      not reattachment_authorized?(state, attachment, control) ->
        {:reply, {:error, :untrusted_reattachment}, state}

      state.closing or not state.attachment_confirmed ->
        {:reply, {:error, :managed_domain_closing}, state}

      state[:reset_activating] ->
        {:reply, {:error, {:reset_activation_unknown, state.reset_activating, state.session}},
         state}

      state.pending_attachment && Process.alive?(elem(state.pending_attachment.from, 0)) ->
        {:reply, {:error, :managed_reattachment_in_progress}, state}

      true ->
        # A call can arrive before the old runtime monitor notification. Wait
        # for its exit classification and for work using its control to finish.
        settle_workers(%{state | pending_attachment: %{from: from, control: control}})
    end
  end

  def handle_call({:prepare_reset, control}, {caller, _}, state) do
    if reset_authorized?(state, caller, control),
      do: reserve_reset(state),
      else: {:reply, {:error, :untrusted_reset_transport}, state}
  end

  def handle_call({:mark_reset_activating, generation}, {caller, _}, state) do
    if caller == state.options[:runtime] and is_reference(state.reset_token) and
         is_binary(generation),
       do: {:reply, :ok, Map.put(state, :reset_activating, generation)},
       else: {:reply, {:error, :untrusted_reset_transport}, state}
  end

  def handle_call({:resume_reset, control}, {caller, _}, state) do
    if reset_authorized?(state, caller, control) and not Map.has_key?(state, :reset_activating),
      do: {:reply, :ok, release_reset(state)},
      else: {:reply, {:error, :untrusted_reset_transport}, state}
  end

  def handle_call({:adopt_reset, session}, {caller, _}, state) do
    cond do
      caller != state.options[:runtime] ->
        {:reply, {:error, :untrusted_reset_transport}, state}

      not match?(%Session{}, session) or session.domain != state.refs.domain ->
        {:reply, {:error, :invalid_server_session}, state}

      true ->
        case register_attachment(state.options) do
          :ok ->
            if state.bootstrap_monitor, do: Process.demonitor(state.bootstrap_monitor, [:flush])
            session = %{session | base_options: state.session.base_options}

            {:reply, :ok,
             %{state | bootstrap_monitor: nil, session: session, attachment_confirmed: true}}

          {:stop, reason} ->
            {:reply, {:error, reason}, state}
        end
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

  def handle_call({:activity_owner, mode}, {caller, _}, state) when mode in [:existing, :start] do
    if caller == state.options[:runtime] and not state.closing and is_nil(state.reset_token) do
      {result, state} = obtain_activity_owner(state, mode)
      {:reply, result, state}
    else
      {:reply, {:error, :untrusted_activity_transport}, state}
    end
  end

  def handle_call({:activity_fence, control}, _, state) do
    if activity_control?(state, control) and not state.closing and
         is_nil(state.reset_token) and not is_map_key(state, :storage_recovery),
       do: {:reply, {:ok, state.domain, state.activity_fence_token}, state},
       else: {:reply, {:error, :activity_fence_unavailable}, state}
  end

  def handle_call({:activity_gate, control}, _, state) do
    if activity_control?(state, control) and is_pid(state.gate),
      do: {:reply, {:ok, state.gate}, state},
      else: {:reply, {:error, :untrusted_activity_transport}, state}
  end

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

  def handle_call(:checkout, from, state), do: handle_call({:checkout, nil}, from, state)

  def handle_call({:checkout, control}, from, state),
    do: handle_call({:checkout, control, nil}, from, state)

  def handle_call({:checkout, control, origin}, from, state),
    do: handle_call({:checkout, control, origin, nil}, from, state)

  def handle_call({:checkout, _, _, _}, _, %{storage_recovery: _} = state),
    do: {:reply, {:error, :managed_storage_recovering}, state}

  def handle_call({:checkout, _, _, _}, _, %{reset_token: token} = state) when not is_nil(token),
    do: {:reply, {:error, :reset_busy}, state}

  def handle_call(
        {:checkout, control, origin, command_id},
        {worker, _},
        %{closing: false} = state
      ) do
    if checkout_authorized?(state, control, origin),
      do: checkout(state, worker, origin, command_id),
      else: {:reply, {:error, :untrusted_governance_transport}, state}
  end

  def handle_call({:checkout, _, _, _}, _, state),
    do: {:reply, {:error, :managed_domain_closing}, state}

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

        context = %{
          agent: state.options[:agent],
          command_id: act.ref,
          identity: state.options[:identity],
          options: options,
          current_flow: frozen["current_flow"],
          current_scope: frozen["current_scope"],
          skill: frozen["skill"]
        }

        context =
          case frozen["activity"] do
            %{"ref" => ref, "revision" => revision} ->
              Map.put(context, :activity, %{ref: ref, revision: revision})

            nil ->
              context
          end

        {:ok, effect, context}
      else
        _ -> {:error, :managed_execution_binding_mismatch}
      end

    {:reply, reply, state}
  end

  defp checkout(state, worker, origin, command_id) do
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

    snapshot =
      if origin,
        do: Map.put(snapshot, :activity_fence, state.activity_fence_token),
        else: snapshot

    case track_activity_effect(state, snapshot, worker, origin, command_id) do
      {:ok, snapshot} ->
        workers =
          Map.put_new_lazy(state.workers, worker, fn ->
            %{monitor: Process.monitor(worker), origin: if(origin, do: :activity, else: :root)}
          end)

        {:reply, {:ok, snapshot}, %{state | workers: workers}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp track_activity_effect(%{activity_owner: owner}, snapshot, worker, %{ref: ref}, command_id)
       when is_binary(command_id) do
    with :ok <- Activities.track_effect(owner, ref, command_id, worker),
         do: {:ok, Map.put(snapshot, :effect_observer, owner)}
  end

  defp track_activity_effect(_state, snapshot, _worker, _origin, _command_id), do: {:ok, snapshot}

  @impl true
  def handle_cast({:checkin, worker}, state) do
    {checkout, workers} = Map.pop(state.workers, worker)
    if checkout, do: Process.demonitor(checkout.monitor, [:flush])
    settle_workers(%{state | workers: workers})
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

  def handle_info({:recover_storage, token}, %{storage_recovery: {token, decision}} = state)
      when is_reference(token),
      do: settle_workers(%{state | storage_recovery: {:awaiting_workers, decision}})

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

  def handle_info({:DOWN, monitor, :process, _host, _reason}, %{host_monitor: monitor} = state),
    do: begin_close(state)

  def handle_info({:DOWN, monitor, :process, _owner, reason}, %{owner_monitor: monitor} = state) do
    if state.host_monitor && state.attachment_confirmed && not intentional_stop?(reason) do
      schedule_reattach_timeout(state)
      settle_workers(%{state | owner_monitor: nil})
    else
      begin_close(state)
    end
  end

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
        if match?(%{monitor: ^monitor}, Map.get(state.workers, worker)),
          do: settle_workers(%{state | workers: Map.delete(state.workers, worker)}),
          else: {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      match?({^pid, _}, state[:activity_owner]) ->
        send(
          state.options[:runtime],
          {Spectre.Server.Runtime, state.options[:runtime_control], :activity_coordinator_down,
           pid}
        )

        {:noreply, Map.delete(state, :activity_owner)}

      pid == state.options[:runtime] and state.host_monitor ->
        {:noreply, state}

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

  def handle_info({:reattach_timeout, runtime}, %{owner_monitor: nil} = state) do
    cond do
      runtime != state.options[:runtime] ->
        {:noreply, state}

      state.pending_attachment ->
        schedule_reattach_timeout(state)
        {:noreply, reply_attachment(state, {:error, :managed_reattach_timeout})}

      true ->
        begin_close(state)
    end
  end

  def handle_info({:reattach_timeout, _token}, state), do: {:noreply, state}

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

  @spec reset_authorized?(map(), pid() | nil, reference() | nil) :: boolean()
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

  defp release_reset(state) do
    resume_reset_gates(state, state.reset_token)

    case Map.pop(%{state | reset_token: nil}, :reset_storage_recovery) do
      {{decision, delay}, next} -> schedule_storage_recovery(next, decision, delay)
      {nil, next} -> next
    end
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

  defp register_initial_attachment(opts) do
    if opts[:bootstrap_owner], do: :ok, else: register_attachment(opts)
  end

  defp register_attachment(opts) do
    case opts[:managed_attachment] do
      {slot, proof, host}
      when is_reference(slot) and is_reference(proof) and is_pid(host) and node(host) == node() ->
        case Registry.register(Spectre.Server.Registry, {__MODULE__, slot}, nil) do
          {:ok, _} -> :ok
          {:error, {:already_registered, _}} -> {:stop, :managed_attachment_in_use}
        end

      nil ->
        :ok

      _ ->
        {:stop, :invalid_managed_attachment}
    end
  end

  defp monitor_attachment_host(opts) do
    case opts[:managed_attachment] do
      {_slot, _proof, host} -> Process.monitor(host)
      nil -> nil
    end
  end

  defp reattachment_authorized?(state, {slot, proof, host} = attachment, control)
       when is_reference(slot) and is_reference(proof) and is_pid(host) and node(host) == node() and
              is_reference(control) do
    state.options[:managed_attachment] == attachment and Process.alive?(host) and
      not Process.alive?(state.options[:runtime])
  end

  defp reattachment_authorized?(_state, _attachment, _control), do: false

  defp checkout_authorized?(%{host_monitor: nil}, nil, nil), do: true

  defp checkout_authorized?(state, control, nil),
    do: reset_authorized?(state, nil, control)

  defp checkout_authorized?(state, control, %{ref: ref, revision: revision})
       when is_binary(ref) and byte_size(ref) > 0 and is_integer(revision) and revision >= 0,
       do: activity_control?(state, control)

  defp checkout_authorized?(_, _, _), do: false

  defp activity_control?(%{activity_owner: {owner, control}}, control),
    do: Process.alive?(owner)

  defp activity_control?(_state, _control), do: false

  defp obtain_activity_owner(%{activity_owner: {pid, control}} = state, mode) do
    if Process.alive?(pid) do
      send(
        pid,
        {Activities, control, :bind_root, state.options[:runtime],
         state.options[:runtime_control]}
      )

      {{:ok, {pid, control}}, state}
    else
      obtain_activity_owner(Map.delete(state, :activity_owner), mode)
    end
  end

  defp obtain_activity_owner(state, :existing), do: {{:ok, nil}, state}

  defp obtain_activity_owner(state, :start) do
    control = make_ref()
    limit = Keyword.get(state.options[:options] || [], :max_activities, :infinity)

    case Activities.start_link(managed: self(), activity_control: control, max_activities: limit) do
      {:ok, pid} ->
        obtain_activity_owner(Map.put(state, :activity_owner, {pid, control}), :existing)

      {:error, _} = error ->
        {error, state}
    end
  end

  defp intentional_stop?(reason),
    do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp schedule_reattach_timeout(state) do
    timeout = Keyword.get(state.options, :shutdown_timeout, 30_000)
    Process.send_after(self(), {:reattach_timeout, state.options[:runtime]}, timeout)
  end

  defp reply_attachment(%{pending_attachment: nil} = state, _reply), do: state

  defp reply_attachment(state, reply) do
    GenServer.reply(state.pending_attachment.from, reply)
    %{state | pending_attachment: nil}
  end

  defp settle_workers(%{closing: true} = state), do: finish_close(state)

  defp settle_workers(
         %{storage_recovery: {:awaiting_workers, decision}, workers: workers} = state
       )
       when map_size(workers) == 0 do
    case recover_owned_storage(state, decision) do
      {:noreply, next} when not is_map_key(next, :storage_recovery) -> settle_workers(next)
      result -> result
    end
  end

  defp settle_workers(
         %{owner_monitor: nil, workers: workers, pending_attachment: pending} = state
       )
       when not is_nil(pending) do
    if Enum.any?(workers, fn {_pid, checkout} -> checkout.origin == :root end),
      do: {:noreply, state},
      else: settle_attachment(state, pending)
  end

  defp settle_workers(state), do: {:noreply, state}

  defp settle_attachment(state, pending) do
    runtime = elem(pending.from, 0)

    {reply, state} =
      if Process.alive?(runtime) do
        bind_runtime(state, runtime, pending.control)
      else
        {{:error, :managed_reattachment_abandoned}, state}
      end

    {:noreply, reply_attachment(state, reply)}
  end

  defp bind_runtime(state, runtime, control) do
    # The old Root never released the reset worker to activate its candidate.
    # Its existing session and gates can be used again.
    state = if state.reset_token, do: release_reset(state), else: state

    case rewire_gates(state, runtime, control) do
      :ok ->
        owner_monitor = Process.monitor(runtime)
        Process.link(runtime)
        options = [runtime: runtime, runtime_control: control]

        session = %{
          state.session
          | base_options: Keyword.merge(state.session.base_options, options)
        }

        {{:ok, session},
         %{
           state
           | options: Keyword.merge(state.options, options),
             owner_monitor: owner_monitor,
             session: session
         }}

      error ->
        {error, state}
    end
  end

  defp rewire_gates(state, runtime, control) do
    Enum.reduce_while(reset_gates(state), :ok, fn gate, :ok ->
      case Gate.rebind(gate, runtime, control) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  catch
    :exit, _ -> {:error, :managed_gate_unavailable}
  end

  defp recover_owned_storage(%{ephemeral: true} = state, :retry) do
    {:noreply, Map.delete(state, :storage_recovery)}
  end

  defp recover_owned_storage(state, decision) do
    state = replace_activity_storage(state)
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
             domain: recovered.refs.domain,
             activity_generation: state[:activity_owner] && elem(state.activity_owner, 1)
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
              :host_monitor,
              :attachment_confirmed,
              :pending_attachment,
              :bootstrap_monitor,
              :reset_token,
              :activity_owner
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

  defp replace_activity_storage(%{activity_owner: {pid, _old_control}} = state) do
    control = make_ref()
    :ok = Activities.replace_storage(pid, control)
    %{state | activity_owner: {pid, control}}
  catch
    :exit, _ ->
      Process.exit(pid, :kill)
      Map.delete(state, :activity_owner)
  end

  defp replace_activity_storage(state), do: state

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

  defp begin_close(%{closing: true} = state), do: finish_close(state)

  defp begin_close(state) do
    Process.send_after(
      self(),
      :drain_timeout,
      Keyword.get(state.options, :shutdown_timeout, 30_000)
    )

    state
    |> reply_attachment({:error, :managed_domain_closing})
    |> Map.put(:closing, true)
    |> finish_close()
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
  def terminate(reason, state) do
    if reason != :storage_recovery do
      case state[:activity_owner] do
        {pid, _} -> Process.exit(pid, :shutdown)
        nil -> :ok
      end
    end

    Enum.each(Map.get(state, :diagnostic_reads, %{}), fn {_token, read} ->
      Process.cancel_timer(read.timer)
      Process.exit(read.pid, :kill)

      if read.from != :refresh,
        do: GenServer.reply(read.from, {:error, :diagnostic_source_unavailable})
    end)

    Bootstrap.close_resources(state)

    if reason != :storage_recovery do
      case state.options[:managed_attachment] do
        {slot, _proof, _host} -> Registry.unregister(Spectre.Server.Registry, {__MODULE__, slot})
        nil -> :ok
      end
    end

    :ok
  end

  @spec invoke(atom(), list(), map(), keyword(), term()) :: term()
  defp invoke(function, args, context, opts, operation \\ nil) do
    with config when is_list(config) <- opts[:bridge_config],
         server when is_pid(server) <- config[:server],
         {:ok, state} <-
           GenServer.call(
             server,
             {:checkout, config[:control], Map.get(context, :activity),
              effect_command(function, context)}
           ) do
      try do
        result = invoke_bridge(function, args, context, opts, operation, state)
        if observer = state[:effect_observer], do: Activities.settle_effect(observer, result)
        result
      after
        GenServer.cast(server, {:checkin, self()})
      end
    else
      _ -> {:error, :managed_gam_not_running}
    end
  end

  defp effect_command(function, context)
       when function in [:propose, :confirm, :explain, :resume, :recover_command],
       do: Map.get(context, :command_id)

  defp effect_command(_function, _context), do: nil

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
        activity_fence: state[:activity_fence],
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
