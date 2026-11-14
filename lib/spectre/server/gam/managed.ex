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
    GenServer.call(server, :close, :infinity)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @doc "Returns enabled operations without authenticated handles."
  @spec operations(pid()) :: map()
  def operations(server), do: GenServer.call(server, :operations)

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
    do: Gate.presented(GenServer.call(server, :gate), ref, caller)

  @doc "Issues one-use, presentation-bound proof of a consumer decision."
  @spec authorize_decision(pid(), binary(), :confirm | :reject, pid()) ::
          {:ok, binary()} | {:error, atom()}
  def authorize_decision(server, ref, decision, caller),
    do: Gate.authorize(GenServer.call(server, :gate), ref, decision, caller)

  @doc "Records authenticated transport provenance for a reply interpreted by the configured binding."
  @spec authorize_input(pid(), binary(), binary(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize_input(server, ref, text, caller),
    do: Gate.authorize_input(GenServer.call(server, :gate), ref, text, caller)

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

  @doc false
  @spec result_reference(term()) :: term()
  def result_reference(result), do: Bridge.result_reference(result)
  @doc false
  @spec result_key(term()) :: term()
  def result_key(result), do: Bridge.result_key(result)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(Keyword.fetch!(opts, :runtime))

    case Bootstrap.open(opts, self()) do
      {:ok, state} ->
        {:ok,
         Map.merge(state, %{
           workers: %{},
           closing: false,
           close_waiters: [],
           owner_monitor: owner_monitor
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:operations, _, state), do: {:reply, state.operations, state}

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

  def handle_call(:runtime_checkpoint, _, state) do
    {module, reference} = checkpoint_store(state)
    {:reply, {module, reference, {:managed_agent, state.refs.domain}}, state}
  end

  def handle_call(:info, _, state), do: {:reply, state.refs, state}
  def handle_call(:gate, _, state), do: {:reply, state.gate, state}

  def handle_call({:view, caller}, {runtime, _}, state) do
    reviewer = if state.reviewer, do: state.reviewer.consumer

    if runtime == state.options[:runtime] and caller in [state.options[:consumer], reviewer],
      do: {:reply, GAM.view(state.scope), state},
      else: {:reply, {:error, :untrusted_audit_transport}, state}
  end

  def handle_call({:diagnostics, opts, caller}, {runtime, _}, state) do
    if runtime == state.options[:runtime] and caller == state.options[:consumer] do
      result =
        GAM.Domain.Sequencer.query(state.scope.domain.server, state.scope, {:diagnostics, opts})

      {:reply, result, state}
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

  def handle_call(:close, from, state) do
    Process.send_after(
      self(),
      :drain_timeout,
      Keyword.get(state.options, :shutdown_timeout, 30_000)
    )

    finish_close(%{state | closing: true, close_waiters: [from | state.close_waiters]})
  end

  def handle_call(:checkout, {worker, _}, %{closing: false} = state) do
    workers = Map.put_new_lazy(state.workers, worker, fn -> Process.monitor(worker) end)

    # Ordinary proposal workers receive only their own scope and bridge
    # configuration. The independent reviewer scope never leaves its owner.
    snapshot =
      state
      |> Map.take([:scope, :refs, :row, :mandate, :effects, :journal, :gate])
      |> Map.put(:options, Keyword.take(state.options, [:bindings, :store, :consent_ttl_ms]))

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
  def handle_info({:diagnostics_revision, revision}, state) do
    unless Map.get(state, :diagnostics_timer),
      do: Process.send_after(self(), :diagnostics_flush, 50)

    {:noreply,
     state |> Map.put(:diagnostics_timer, true) |> Map.put(:diagnostics_revision, revision)}
  end

  def handle_info(:diagnostics_flush, state) do
    if is_pid(state.options[:consumer]) do
      send(
        state.options[:consumer],
        {Spectre.Server, state.options[:runtime],
         {:diagnostics_changed, %{source: :gam, revision: state.diagnostics_revision}}}
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

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    Process.send_after(
      self(),
      :drain_timeout,
      Keyword.get(state.options, :shutdown_timeout, 30_000)
    )

    finish_close(%{state | closing: true})
  end

  def handle_info({:DOWN, monitor, :process, worker, _}, state) do
    if Map.get(state.workers, worker) == monitor,
      do: finish_close(%{state | workers: Map.delete(state.workers, worker)}),
      else: {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.options[:runtime] ->
        Process.send_after(
          self(),
          :drain_timeout,
          Keyword.get(state.options, :shutdown_timeout, 30_000)
        )

        finish_close(%{state | closing: true})

      pid in [state.domain, state.gate | state.owned] ->
        {:stop, {:managed_component_stopped, reason}, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:drain_timeout, state) do
    Enum.each(state.close_waiters, &GenServer.reply(&1, {:error, :shutdown_drain_timeout}))
    {:stop, :normal, %{state | close_waiters: []}}
  end

  @spec ensure_diagnostics_subscription(map()) :: {:ok | {:error, atom()}, map()}
  defp ensure_diagnostics_subscription(state) do
    notifier = Map.get(state, :diagnostics_notifier)

    if is_pid(notifier) and Process.alive?(notifier) do
      {:ok, state}
    else
      if monitor = Map.get(state, :diagnostics_monitor), do: Process.demonitor(monitor, [:flush])

      case GAM.Domain.Notifications.subscribe(state.refs.domain) do
        {:ok, notifier} ->
          if timer = Map.get(state, :diagnostics_retry), do: Process.cancel_timer(timer)
          if Map.get(state, :diagnostics_registered), do: refresh_diagnostics(state)

          {:ok,
           Map.merge(state, %{
             diagnostics_notifier: notifier,
             diagnostics_monitor: Process.monitor(notifier),
             diagnostics_retry: nil,
             diagnostics_registered: true
           })}

        {:error, _} = error ->
          {error, retry_diagnostics_subscription(state)}
      end
    end
  end

  @spec refresh_diagnostics(map()) :: :ok
  defp refresh_diagnostics(state) do
    case GAM.Domain.Sequencer.head(state.scope.domain.server) do
      {:ok, %{revision: revision}} -> send(self(), {:diagnostics_revision, revision})
      _ -> :ok
    end

    :ok
  catch
    :exit, _ -> :ok
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
    Enum.each([state.domain, state.gate | state.owned], fn pid ->
      if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    end)

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
    policy = effective_policy(args, opts, context)

    with :ok <- validate_policy(policy) do
      context =
        Map.merge(context, %{
          managed: binding_context(state),
          managed_operation: operation,
          managed_policy: policy
        })

      bridge = [
        scope: state.scope,
        bindings: Binding.bindings(state, operation, policy),
        lifecycle: true,
        store: Keyword.get(state.options, :store, state.journal),
        consent_ttl_ms: ttl(state, policy, operation),
        ingress_opts: [
          gate: state.gate,
          consent_proof: Map.get(context, :consent_proof),
          source_digest: Map.get(context, :consent_source_digest)
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

  @spec reject_preparation(map(), map(), term(), term()) :: term()
  defp reject_preparation(state, context, operation, reason) do
    with {:ok, _} <-
           Invocation.record(state.scope, context, operation, ingress_opts: [gate: state.gate]),
         {:ok, _} <-
           GAM.observe(
             state.scope,
             %{
               kind: :spectre_action_rejected,
               operation: operation,
               reason: reason,
               command_id: context.command_id
             },
             ingress_opts: [gate: state.gate]
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
    |> Map.take([:refs, :row, :mandate])
    |> Map.put(:effects, effects)
    |> Map.put(:options, Keyword.take(state.options, [:bindings]))
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

  @spec effective_policy(list(), keyword(), map()) :: map()
  defp effective_policy(args, opts, context) do
    frozen =
      case args do
        [%{candidate: %{consequence: consequence}} | _] ->
          Map.get(consequence, "managed_policy", %{})

        _ ->
          %{}
      end

    policy =
      Map.new([:confirm, :message, :expires_in, :bind, :reject], fn key ->
        {key, Map.get(frozen, Atom.to_string(key), Map.get(frozen, key))}
      end)
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    policy =
      case args do
        [%{candidate: %{consequence: %{"managed_policy" => _}}} | _] -> policy
        _ -> Keyword.get(opts, :action_policy, %{})
      end

    if is_map(policy) and
         (get_in(context, [:routing, :protected]) not in [nil, false] or
            Keyword.get(opts, :confirmation) not in [nil, false]),
       do: Map.put(policy, :confirm, true),
       else: policy
  end

  @spec canonical_identity(map()) :: map()
  defp canonical_identity(identity),
    do: Map.new(identity, fn {key, value} -> {to_string(key), value} end)

  @spec checkpoint_store(map()) :: {module(), term()}
  defp checkpoint_store(state) do
    case Keyword.get(state.options, :store, state.journal) do
      {module, reference} when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2),
          do: {module, reference},
          else: state.journal

      _ ->
        state.journal
    end
  end
end
