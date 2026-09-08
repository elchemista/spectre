defmodule Spectre.Instance do
  @moduledoc """
  Minimal OTP owner for one live agent Scope.

  An Instance associates an authenticated Scope with one exact immutable
  `Spectre.Definition` revision and serializes application deliberation. The
  handler API verifies compiled code, declarations and mounted Skill revisions
  against that Definition before preparing/submitting a request and applying a
  result. The lower-level Mind API receives the reference as metadata only.
  Neither mode grants authority or silently follows a new Definition head.
  Every Candidate is still evaluated independently by the kernel.

  An Instance may retain an opaque application value, but it owns no authority,
  Grant, credential or durable execution fact. Durable facts live in the Domain
  ledger; ephemeral capabilities remain within the trusted execution boundary.

  Stateful minds may additionally implement `Spectre.Mind.deliberate/3`. The
  callback receives the current application value and may return its successor
  together with capability-free Candidates. A stateless Mind continues to use
  `deliberate/2`, in which case the Instance value is left unchanged.

  Instances are ordinary OTP children supervised by the host application. Each
  one monitors the Domain process that authenticated its Scope and shuts down
  when that process or the Scope fence becomes invalid, allowing the host to
  re-authenticate and create a fresh Instance. No global Instance registry or
  second persistence system is created here. Optional `checkpoint: {store, key}`
  loads application state only. `checkpoint/4` explicitly saves it through a
  host-configured `Spectre.Store`; it is never an execution checkpoint or a way
  to restore a Scope. Checkpointing is not automatic after external effects.

  Slow mutations run in one linked, monitored temporary worker at a time.
  Local reads remain responsive and return the last completed state, not a
  partial deliberation. At most `max_pending_operations` requests wait in FIFO
  order (default 32; zero rejects concurrent mutations with `:instance_busy`).
  This bounds accepted requests, not arbitrary BEAM mailbox traffic or bytes.

  `state/2`, `info/2` and `scope/2` accept a timeout in milliseconds or
  `:infinity`, defaulting to 5,000 ms. `definition/2` also accepts that timeout
  for its small Instance read, then verifies the Definition through the Domain.

  A caller timeout or death does not cancel accepted work. Worker failure is
  reported without retry; a failed proposal may already have a durable Attempt
  and external effects. Domain loss stops the Instance and its worker, but
  cannot undo such effects. Use ordinary late-observation/reconciliation paths.
  This lifecycle is not a provider streaming, steering or cancellation API.

  Detected Domain/Scope loss replies to active and queued callers with an error
  before shutdown. An unhandled process kill still has ordinary OTP call-exit
  semantics. Neither kind of failure certifies that no external effect occurred.
  """

  use GenServer

  alias Spectre.Agent.Observer
  alias Spectre.Agent.Runtime, as: AgentRuntime
  alias Spectre.{Candidate, Definition, Domain, Portable, Scope}
  alias Spectre.Instance.{Checkpoint, Operation, Request, State}

  @options [
    :scope,
    :definition_ref,
    :state,
    :checkpoint,
    :name,
    :max_pending_operations,
    :agent,
    :definition,
    :adapters,
    :bindings,
    :component_states
  ]
  @scope_fence_errors [
    :context_domain_mismatch,
    :definition_lookup_failed,
    :domain_not_found,
    :domain_registry_unavailable,
    :invalid_domain_registration,
    :invalid_scope_context,
    :scope_validation_failed,
    :submission_context_authentication_failed,
    :submission_context_domain_mismatch,
    :submission_context_generation_mismatch,
    :submission_context_ingress_mismatch
  ]

  @type server :: GenServer.server()
  @type info :: %{
          required(:ref) => String.t(),
          required(:domain_ref) => String.t(),
          required(:definition_ref) => String.t(),
          required(:state_revision) => non_neg_integer()
        }

  @doc "Starts an Instance around an already authenticated and durable Scope."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- configuration(opts) do
      GenServer.start_link(__MODULE__, Map.delete(config, :name), server_options(config))
    end
  end

  def start_link(_opts), do: {:error, :invalid_instance_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: child_id(opts),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Runs one serialized, capability-free deliberation for this Instance."
  @spec turn(server(), term(), keyword()) ::
          {:ok,
           %{
             turn: Spectre.Mind.Turn.t(),
             evidence: [Spectre.Evidence.t()],
             candidates: [Candidate.t()]
           }}
          | {:ok, Spectre.Agent.Turn.t()}
          | {:error, term()}
  def turn(server, input, opts \\ [])

  def turn(server, input, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:turn, input, opts}, :infinity),
      else: {:error, :invalid_instance_turn_options}
  end

  def turn(_server, _input, _opts), do: {:error, :invalid_instance_turn_options}

  @doc "Submits one Candidate through the bound Scope's normal governed path."
  @spec propose(server(), Candidate.t() | map() | keyword(), keyword()) ::
          {:ok, Spectre.Proposal.Result.t()} | {:error, term()}
  def propose(server, candidate, opts \\ [])

  def propose(server, candidate, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:propose, candidate, opts}, :infinity),
      else: {:error, :invalid_instance_proposal_options}
  end

  def propose(_server, _candidate, _opts),
    do: {:error, :invalid_instance_proposal_options}

  @doc """
  Reserves and submits one exact prepared request, never its alternatives.

  wait: milliseconds (default 5,000), or :infinity, bounds the wait for a
  completed continuation, not the lifetime of accepted work. A pending reply
  carries the known request ref. Once the proposal returns pending, the worker
  is released; operation/3 can refresh it without re-submission. No background
  polling is started. A slow executor still needs its host-configured timeout.
  A timeout is not cancellation. proposal_opts are the ordinary facade options.
  """
  @spec advance(server(), Request.t(), keyword()) ::
          {:ok, Spectre.Agent.Turn.t()} | {:pending, String.t()} | {:error, term()}
  def advance(server, request, opts \\ []) do
    with {:ok, options} <-
           Portable.normalize_attrs(opts, [:wait, :proposal_opts], :instance_advance),
         wait = Map.get(options, :wait, 5000),
         true <- wait == :infinity or (is_integer(wait) and wait >= 0),
         proposal_opts = Map.get(options, :proposal_opts, []),
         true <- Portable.keyword?(proposal_opts) do
      GenServer.call(server, {:advance, request, proposal_opts, wait}, :infinity)
    else
      false -> {:error, :invalid_instance_advance_options}
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads a retained operation without re-submitting it.

  A deferred proposal is refreshed once in the mutation worker when it is free;
  otherwise this returns `{:pending, ref}`, like `advance/3`. A completed result
  continues its original handler only if that exact turn and state revision remain current. Otherwise
  `{:error, {:instance_continuation_superseded, result}}` returns the durable
  facts without changing local state. Reading a completed operation is inert.

  The last 64 operations (completed or deferred), plus active/queued work, are
  retained. An expired ref does not prove no effect: the ledger remains the
  source of durable facts. `timeout` bounds the caller's wait, not accepted work.
  """
  @spec operation(server(), String.t(), timeout()) ::
          {:ok, Spectre.Agent.Turn.t()} | {:pending, String.t()} | {:error, term()}
  def operation(server, ref, timeout \\ 5000),
    do: GenServer.call(server, {:operation, ref}, timeout)

  @doc "Returns the last completed handler turn and its still-unsubmitted requests."
  @spec current_turn(server(), timeout()) :: Spectre.Agent.Turn.t() | nil
  def current_turn(server, timeout \\ 5000), do: GenServer.call(server, :current_turn, timeout)

  @doc false
  def component(server, kind, name), do: GenServer.call(server, {:component, kind, name})

  @doc """
  Returns the selected immutable Definition through the live Scope fence.

  Only the small binding is read from the Instance; the facade/Domain lookup
  runs in the caller, so it cannot block local state readers. `timeout` bounds
  the Instance binding lookup, not the separate Domain verification. A fenced
  result also notifies that exact Instance process to shut down.
  """
  @spec definition(server(), timeout()) :: {:ok, Definition.t()} | {:error, term()}
  def definition(server, timeout \\ 5_000) do
    {owner, scope, definition_ref} = GenServer.call(server, :definition_binding, timeout)
    result = Spectre.definition(scope, definition_ref)

    case result do
      {:error, reason} ->
        if scope_fence_error?(reason), do: GenServer.cast(owner, {:scope_fenced, scope, reason})

      {:ok, _definition} ->
        :ok
    end

    result
  end

  @doc "Returns the authenticated Scope owned by this Instance."
  @spec scope(server(), timeout()) :: Scope.t()
  def scope(server, timeout \\ 5_000), do: GenServer.call(server, :scope, timeout)

  @doc "Returns non-authoritative Instance identity and local state revision."
  @spec info(server(), timeout()) :: info()
  def info(server, timeout \\ 5_000), do: GenServer.call(server, :info, timeout)

  @doc "Returns the opaque, process-local application state and its revision."
  @spec state(server(), timeout()) ::
          %{required(:revision) => non_neg_integer(), required(:value) => term()}
  def state(server, timeout \\ 5_000), do: GenServer.call(server, :state, timeout)

  @doc "Saves portable Mind state, fencing concurrent writers with the store's revision."
  @spec checkpoint(server(), Spectre.Store.config(), String.t(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def checkpoint(server, store, key, expected_revision),
    do: GenServer.call(server, {:checkpoint, store, key, expected_revision}, :infinity)

  @impl GenServer
  def init(config) do
    # Linked tasks die with an abnormal owner exit; trapped task exits are
    # handled via their monitors instead of crashing this state owner.
    Process.flag(:trap_exit, true)

    with {:ok, scope} <- Operation.current_scope(Map.fetch!(config, :scope)),
         definition_ref = Map.fetch!(config, :definition_ref),
         {:ok, domain_monitor} <- monitor_domain(scope),
         {:ok, %Definition{}} <- Spectre.definition(scope, definition_ref),
         {:ok, application_state} <- initial_state(config, scope),
         {:ok, authoring, value} <- authoring(config, scope, application_state) do
      state = State.new(scope, definition_ref, value, domain_monitor)

      {:ok,
       %{
         state
         | revision: application_state.revision,
           authoring: authoring,
           max_pending_operations: Map.get(config, :max_pending_operations, 32)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:scope, _from, %State{} = state),
    do: {:reply, state.scope, state}

  def handle_call(:info, _from, %State{} = state),
    do: {:reply, State.info(state), state}

  def handle_call(:state, _from, %State{} = state),
    do: {:reply, local_state(state), state}

  def handle_call(:current_turn, _from, state),
    do: {:reply, if(state.authoring, do: state.authoring.current, else: nil), state}

  def handle_call({:operation, ref}, from, state) do
    case Map.fetch(state.operations, ref) do
      {:ok, %{resume: {request, proposal}} = entry} when is_nil(state.job) ->
        entry = entry |> Map.delete(:resume) |> Map.put(:from, from)
        state = retain_operation(state, ref, entry)
        enqueue({:recover_advance, request, proposal}, from, state)

      {:ok, %{result: :pending}} ->
        {:reply, {:pending, ref}, state}

      {:ok, %{result: result}} ->
        {:reply, result, state}

      :error ->
        {:reply, {:error, :instance_operation_not_retained}, state}
    end
  end

  def handle_call({:component, kind, name}, _from, state) do
    reply =
      with true <- is_atom(name) or is_binary(name),
           %{owners: owners, definition: definition} <- state.authoring,
           {:ok, %{kind: ^kind} = entry} <- Map.fetch(owners[""].plan.jobs, to_string(name)) do
        code_ref = definition.body["authoring"]["plan"].jobs[to_string(name)].code_ref
        {:ok, state.scope, entry.module, code_ref}
      else
        _missing -> {:error, {:unknown_agent_component, kind, name}}
      end

    {:reply, reply, state}
  end

  def handle_call({:advance, request, opts, wait}, from, state) do
    cond do
      is_nil(state.authoring) ->
        {:reply, {:error, :instance_has_no_agent_handlers}, state}

      not AgentRuntime.ready?(state.authoring, request, state.instance_ref, state.revision) ->
        {:reply, {:error, :invalid_or_superseded_instance_request}, state}

      state.job != nil and state.pending_count >= state.max_pending_operations ->
        {:reply, {:error, :instance_busy}, state}

      true ->
        case wait_timer(request.ref, from, wait) do
          {:ok, timer} ->
            state =
              retain_operation(state, request.ref, %{result: :pending, from: from, timer: timer})

            # Reserve only after the VM accepted the timer. An unsupported time
            # must neither kill this owner nor consume an otherwise valid ticket.
            authoring = AgentRuntime.discard_requests(state.authoring)
            enqueue({:advance, request, opts}, from, %{state | authoring: authoring})

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call(:definition_binding, _from, %State{} = state),
    do: {:reply, {self(), state.scope, state.definition_ref}, state}

  def handle_call({:turn, _input, _opts} = request, from, %State{} = state),
    do: enqueue(request, from, state)

  def handle_call({:propose, _candidate, _opts} = request, from, %State{} = state),
    do: enqueue(request, from, state)

  def handle_call({:checkpoint, _store, _key, _expected} = request, from, %State{} = state),
    do: enqueue(request, from, state)

  @impl GenServer
  def handle_cast({:scope_fenced, scope, reason}, %State{scope: scope} = state) do
    if scope_fence_error?(reason),
      do: shutdown({:scope_fenced, reason}, state),
      else: {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:advance_wait_elapsed, ref, caller}, state) do
    case Map.get(state.operations, ref) do
      %{result: :pending, from: ^caller} = entry when not is_nil(caller) ->
        # An advance timer must not time out a later recovery of the same ref.
        GenServer.reply(caller, {:pending, ref})
        entry = entry |> Map.put(:from, nil) |> Map.delete(:timer)
        {:noreply, %{state | operations: Map.put(state.operations, ref, entry)}}

      _completed ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _domain, reason},
        %State{domain_monitor: monitor} = state
      ) do
    shutdown({:domain_down, reason}, state)
  end

  def handle_info({ref, result}, %State{job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | job: nil}

    case result do
      {:deferred, request, proposal} ->
        entry = Map.fetch!(state.operations, request.ref)
        reply_operation(entry, {:pending, request.ref})

        entry = %{result: :pending, from: nil, resume: {request, proposal}}
        next_job(retain_operation(state, request.ref, entry))

      {:authoring, reply, value, authoring} ->
        state = %{state | value: value, authoring: authoring, revision: state.revision + 1}
        complete_job(reply, job, state)

      {:advance, reply, value} ->
        complete_job(reply, job, State.advance(state, value))

      {:reply, reply} ->
        complete_job(reply, job, state)
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _worker, _reason},
        %State{job: %{task: %Task{ref: ref}} = job} = state
      ) do
    complete_job({:error, {:instance_operation_stopped, job.operation}}, job, %{state | job: nil})
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %State{job: %{task: task}}) do
    Process.exit(task.pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp enqueue(request, from, %State{job: nil} = state),
    do: {:noreply, start_job(request, from, state)}

  defp enqueue(request, from, %State{pending_count: count, max_pending_operations: max} = state)
       when count < max do
    {:noreply,
     %{
       state
       | pending: :queue.in({request, from, System.monotonic_time()}, state.pending),
         pending_count: count + 1
     }}
  end

  defp enqueue(_request, _from, state), do: {:reply, {:error, :instance_busy}, state}

  defp start_job(request, from, state, enqueued_at \\ System.monotonic_time()) do
    # Proposing never uses Mind state: do not copy a potentially large local
    # value into a worker waiting on an external executor.
    fields =
      if elem(request, 0) == :propose,
        do: [:scope],
        else: [:scope, :definition_ref, :revision, :value, :authoring, :instance_ref]

    snapshot = Map.take(state, fields)

    task =
      Task.async(fn ->
        Observer.emit(
          Map.get(snapshot, :authoring),
          [:queue, :stop],
          %{duration: System.monotonic_time() - enqueued_at},
          %{
            instance_ref: snapshot[:instance_ref],
            definition_ref: snapshot[:definition_ref],
            operation: elem(request, 0)
          }
        )

        Operation.run(request, snapshot)
      end)

    ref =
      if elem(request, 0) in [:advance, :recover_advance], do: elem(request, 1).ref, else: nil

    %{state | job: %{task: task, from: from, operation: elem(request, 0), request_ref: ref}}
  end

  defp complete_job(reply, %{request_ref: nil} = job, state), do: complete(reply, job.from, state)

  defp complete_job(reply, %{request_ref: ref}, state) do
    entry = Map.fetch!(state.operations, ref)
    reply_operation(entry, reply)
    state = retain_operation(state, ref, %{result: reply, from: nil})
    after_complete(reply, state)
  end

  defp wait_timer(_ref, _from, :infinity), do: {:ok, nil}

  defp wait_timer(ref, from, wait) do
    {:ok, Process.send_after(self(), {:advance_wait_elapsed, ref, from}, wait)}
  rescue
    ArgumentError -> {:error, :invalid_instance_advance_options}
  end

  defp reply_operation(entry, reply) do
    # A wait timer belongs to this outstanding reply, not to the retained
    # operation. Release it on completion, failure and deferred handoff alike.
    if entry[:timer], do: Process.cancel_timer(entry.timer)
    if entry.from, do: GenServer.reply(entry.from, reply)
  end

  defp complete(reply, from, state) do
    GenServer.reply(from, reply)
    after_complete(reply, state)
  end

  defp after_complete(reply, state) do
    case reply do
      {:error, reason} ->
        if scope_fence_error?(reason),
          do: shutdown({:scope_fenced, reason}, state),
          else: next_job(state)

      {:ok, _} ->
        next_job(state)

      {:pending, _} ->
        next_job(state)
    end
  end

  defp shutdown(reason, state) do
    # Reply before stopping: otherwise a Domain failure races the worker's
    # error reply and turns a handled admission failure into a caller exit.
    # This says nothing about whether an in-flight world effect occurred.
    if state.job, do: GenServer.reply(state.job.from, {:error, reason})

    Enum.each(:queue.to_list(state.pending), fn {_request, from, _enqueued_at} ->
      GenServer.reply(from, {:error, reason})
    end)

    {:stop, {:shutdown, reason}, state}
  end

  defp next_job(state) do
    case :queue.out(state.pending) do
      {{:value, {request, from, enqueued_at}}, pending} ->
        state = %{state | pending: pending, pending_count: state.pending_count - 1}
        {:noreply, start_job(request, from, state, enqueued_at)}

      {:empty, _pending} ->
        {:noreply, state}
    end
  end

  defp configuration(opts) do
    with {:ok, config} <- Portable.normalize_attrs(opts, @options, :instance),
         {:ok, config} <- bind_definition(config),
         {:ok, %Scope{}} <- Map.fetch(config, :scope),
         {:ok, definition_ref} <- Map.fetch(config, :definition_ref),
         :ok <- Portable.validate_ref(definition_ref, :definition_ref),
         :ok <- validate_pending_limit(Map.get(config, :max_pending_operations, 32)) do
      {:ok, config}
    else
      :error -> {:error, :missing_instance_options}
      {:ok, _invalid_scope} -> {:error, :invalid_instance_scope}
      {:error, _reason} = error -> error
    end
  end

  defp bind_definition(%{agent: _agent, definition: %Definition{} = definition} = config) do
    case Map.fetch(config, :definition_ref) do
      :error -> {:ok, Map.put(config, :definition_ref, definition.ref)}
      {:ok, ref} when ref === definition.ref -> {:ok, config}
      _different -> {:error, :instance_definition_binding_mismatch}
    end
  end

  defp bind_definition(%{agent: _agent}), do: {:error, :agent_definition_required}
  defp bind_definition(config), do: {:ok, config}

  defp authoring(%{agent: module, definition: definition} = config, _scope, saved) do
    AgentRuntime.new(
      module,
      definition,
      Map.get(config, :adapters, []),
      Map.get(config, :bindings, %{}),
      saved.value,
      Map.get(saved, :components, Map.get(config, :component_states, %{})),
      Map.has_key?(config, :checkpoint)
    )
  end

  defp authoring(_config, _scope, saved), do: {:ok, nil, saved.value}

  defp local_state(%{authoring: nil} = state), do: %{revision: state.revision, value: state.value}

  defp local_state(state),
    do: %{
      revision: state.revision,
      value: state.value,
      components:
        Map.new(state.authoring.components, fn {name, value} ->
          {String.trim_trailing(name, "/"), value}
        end)
    }

  defp retain_operation(state, ref, entry) do
    # Only active/queued work is protected from eviction. Deferred proposals no
    # longer occupy a slot, so keeping all of them would leak memory forever.
    order =
      if Map.has_key?(state.operations, ref),
        do: state.operation_order,
        else: [ref | state.operation_order]

    operations = Map.put(state.operations, ref, entry)
    {recent, older} = Enum.split(order, 64)

    {keep, remove} =
      Enum.split_with(older, fn ref ->
        entry = operations[ref]
        entry.result == :pending and not Map.has_key?(entry, :resume)
      end)

    %{state | operations: Map.drop(operations, remove), operation_order: recent ++ keep}
  end

  defp validate_pending_limit(limit) when is_integer(limit) and limit >= 0, do: :ok
  defp validate_pending_limit(_limit), do: {:error, :invalid_instance_pending_limit}

  defp initial_state(%{checkpoint: _checkpoint, state: _state}, _scope),
    do: {:error, :instance_state_checkpoint_collision}

  defp initial_state(%{checkpoint: _checkpoint, component_states: _states}, _scope),
    do: {:error, :instance_state_checkpoint_collision}

  defp initial_state(%{checkpoint: {store, key}, definition_ref: ref}, scope),
    do: Checkpoint.load(store, key, Scope.domain_ref(scope), ref)

  defp initial_state(%{checkpoint: _invalid}, _scope), do: {:error, :invalid_instance_checkpoint}

  defp initial_state(config, _scope),
    do: {:ok, %{revision: 0, value: Map.get(config, :state, %{})}}

  defp monitor_domain(%Scope{domain: %Domain{server: server}}) when is_pid(server),
    do: {:ok, Process.monitor(server)}

  defp monitor_domain(_scope), do: {:error, :invalid_instance_domain}

  defp scope_fence_error?(reason) when reason in @scope_fence_errors, do: true
  defp scope_fence_error?({:scope_not_open, _scope_ref}), do: true
  defp scope_fence_error?({:scope_context_domain_mismatch, _scope_ref}), do: true
  defp scope_fence_error?({:scope_context_binding_mismatch, _scope_ref}), do: true
  defp scope_fence_error?(_reason), do: false

  defp server_options(config) do
    case Map.fetch(config, :name) do
      {:ok, name} -> [name: name]
      :error -> []
    end
  end

  defp child_id(opts) do
    case Keyword.get(opts, :scope) do
      %Scope{} = scope -> {__MODULE__, Scope.domain_ref(scope), Scope.ref(scope)}
      _invalid -> __MODULE__
    end
  end
end
