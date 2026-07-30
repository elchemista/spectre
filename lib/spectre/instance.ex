defmodule Spectre.Instance do
  @moduledoc """
  Subject-scoped OTP owner and fair scheduler for Spectre Runs.

  An Instance is uniquely addressed by `Spectre.AgentRef + Spectre.Subject`.
  It retains every active Run, advances at most one Run move per mailbox
  scheduling message, and returns public calls at the first observable
  boundary. The legacy `Spectre.Session` remains available for
  conversation-scoped 0.1.x integrations.

  The 0.1.4 lifecycle still permits one active Effect boundary across the
  legacy `%Spectre.State{}`. Ready Runs remain queued behind that boundary
  until it is resumed; moving that constraint fully onto each Run is the next
  migration phase.
  """

  use GenServer

  alias Spectre.AgentRef
  alias Spectre.Input
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Value
  alias Spectre.Runtime
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @default_max_runs 256
  @default_max_tombstones 256

  @type option ::
          {:agent, module()}
          | {:agent_ref, AgentRef.t()}
          | {:subject, Subject.t() | term()}
          | {:state, State.t() | map() | keyword()}
          | {:opts, keyword()}
          | {:registry, atom()}
          | {:state_conversation_id, term()}
          | {:idle, timeout() | false | nil}
          | {:shutdown, timeout() | false | nil}
          | {:max_runs, pos_integer()}
          | {:max_tombstones, non_neg_integer()}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    ref = instance_ref!(opts)

    %{
      id: {__MODULE__, ref.key},
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }
  end

  @doc """
  Starts the unique local Instance for an Agent and Subject.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :name) do
      raise ArgumentError,
            "Spectre.Instance is always named by AgentRef + Subject; custom :name is not supported"
    end

    ref = instance_ref!(opts)
    registry = Keyword.get(opts, :registry, InstanceRegistry)
    name = InstanceRegistry.via(ref, registry)

    opts =
      opts
      |> Keyword.put(:agent, ref.agent_ref.definition)
      |> Keyword.put(:agent_ref, ref.agent_ref)
      |> Keyword.put(:subject, ref.subject)
      |> Keyword.put(:instance_ref, ref)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Handles one input and returns its raw Result at the first boundary.
  """
  @spec ask(GenServer.server(), term(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def ask(server, input, opts \\ []) do
    GenServer.call(server, {:handle, input, opts}, timeout(opts))
  end

  @doc """
  Handles one input and returns its public Turn projection.
  """
  @spec turn(GenServer.server(), term(), keyword()) :: {:ok, Turn.t()} | {:error, term()}
  def turn(server, input, opts \\ []) do
    GenServer.call(server, {:turn, input, opts}, timeout(opts))
  end

  @doc """
  Resumes an owned Run through a revision-fenced Runtime command.

  Effect execution is dispatched outside the actor and returns through the
  canonical `{:spectre, :invocation_result, invocation_id, receipt}` mailbox
  message before the actor applies the returned Run.
  """
  @spec resume(GenServer.server(), Ref.t(), term(), keyword()) ::
          {:ok, Turn.t()} | {:error, term()}
  def resume(server, %Ref{} = ref, command, opts \\ []) do
    GenServer.call(server, {:instance_resume, ref, command, opts}, timeout(opts))
  end

  @doc """
  Returns a privacy-safe operational view of the Instance scheduler.
  """
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :instance_info)

  @doc """
  Returns the logical Instance reference.
  """
  @spec ref(GenServer.server()) :: InstanceRef.t()
  def ref(server), do: GenServer.call(server, :instance_ref)

  @doc """
  Returns a compact view of one retained Run or tombstone.
  """
  @spec run(GenServer.server(), String.t() | Ref.t()) :: {:ok, map()} | {:error, term()}
  def run(server, %Ref{run_id: run_id}), do: run(server, run_id)
  def run(server, run_id), do: GenServer.call(server, {:instance_run, run_id})

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    agent = Keyword.fetch!(opts, :agent)
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    subject = Keyword.fetch!(opts, :subject)
    instance_ref = Keyword.fetch!(opts, :instance_ref)
    registry = Keyword.get(opts, :registry, InstanceRegistry)

    with {:ok, max_runs} <- positive_integer(Keyword.get(opts, :max_runs, @default_max_runs)),
         {:ok, max_tombstones} <-
           non_negative_integer(Keyword.get(opts, :max_tombstones, @default_max_tombstones)),
         base_opts <- base_opts(opts, instance_ref),
         {:ok, state} <- restore_initial_state(agent, opts, base_opts),
         {:ok, registry_monitor} <- monitor_registry(registry, instance_ref) do
      data = %InstanceState{
        agent: agent,
        agent_ref: agent_ref,
        subject: subject,
        ref: instance_ref,
        state: state,
        base_opts: base_opts,
        idle_timeout: idle_timeout(agent, opts, base_opts),
        max_runs: max_runs,
        max_tombstones: max_tombstones,
        generation: Spectre.Identity.uuid7(),
        registry: registry,
        registry_monitor: registry_monitor
      }

      emit(:started, data, %{count: 1})
      {:ok, arm_idle_timer(data)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:handle, input, opts}, from, data) do
    submit(input, opts, :result, from, data)
  end

  def handle_call({:turn, input, opts}, from, data) do
    submit(input, opts, :turn, from, data)
  end

  def handle_call(
        {:instance_resume, %Ref{} = supplied_ref, command, opts},
        from,
        data
      ) do
    case owned_run(data, supplied_ref) do
      {:ok, run} ->
        cond do
          run_active?(data, run.id) ->
            {:reply, {:error, {:run_already_active, run.id}}, data}

          execute_command?(command) ->
            dispatch_invocation(run, command, opts, :turn, from, data)

          true ->
            entry = %{
              run_id: run.id,
              operation: {:resume, command},
              projection: :turn,
              input: run.input,
              opts: runtime_opts(data, opts, run.input),
              state_revision: data.state.revision,
              internal?: false
            }

            {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  # Compatibility with Spectre.Session and Spectre.Turn.resolve_policy/3.
  def handle_call({:resolve_policy, %Result{} = supplied, resolution, opts}, from, data) do
    with {:ok, run} <- owned_result_run(data, supplied),
         false <- run_active?(data, run.id),
         %Boundary{kind: :needs, ref: boundary_ref} <- run.waiting do
      entry = %{
        run_id: run.id,
        operation: {:resume, {:policy, boundary_ref, resolution}},
        projection: :result,
        input: run.input,
        opts: runtime_opts(data, opts, run.input),
        state_revision: data.state.revision,
        internal?: false
      }

      {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
    else
      true -> {:reply, {:error, :run_already_active}, arm_idle_timer(data)}
      nil -> {:reply, {:error, :run_not_waiting_for_policy}, arm_idle_timer(data)}
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
      _other -> {:reply, {:error, :run_not_waiting_for_policy}, arm_idle_timer(data)}
    end
  end

  # Compatibility with Spectre.execute/3 for a live Instance.
  def handle_call({:execute, %Result{} = supplied, opts}, from, data) do
    case owned_result_run(data, supplied, true) do
      {:ok, %Run{waiting: %Invocation{} = invocation} = run} ->
        dispatch_invocation(
          run,
          {:execute, invocation},
          opts,
          :result,
          from,
          data
        )

      {:ok, %Run{result: %Result{} = result} = run} ->
        if terminal_result?(result) do
          {:reply, {:ok, result}, arm_idle_timer(data)}
        else
          {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, arm_idle_timer(data)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:state, _from, data), do: {:reply, data.state, arm_idle_timer(data)}
  def handle_call(:agent, _from, data), do: {:reply, data.agent, arm_idle_timer(data)}
  def handle_call(:instance_ref, _from, data), do: {:reply, data.ref, arm_idle_timer(data)}

  def handle_call(:instance_info, _from, data) do
    {:reply, info_projection(data), arm_idle_timer(data)}
  end

  def handle_call({:instance_run, run_id}, _from, data) do
    reply =
      case Map.get(data.runs, run_id) do
        %Run{} = run ->
          {:ok, run_projection(run)}

        nil ->
          case Map.fetch(data.tombstones, run_id) do
            {:ok, tombstone} -> {:ok, tombstone}
            :error -> {:error, :instance_run_not_found}
          end
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call({:reset, state}, _from, data) do
    if busy?(data) or live_runs?(data) do
      {:reply, {:error, :instance_busy}, arm_idle_timer(data)}
    else
      state =
        state
        |> State.new()
        |> put_conversation_id(Keyword.fetch!(data.base_opts, :conversation_id))

      next = %{data | state: state, last_result: nil}
      {:reply, :ok, arm_idle_timer(next)}
    end
  end

  @impl GenServer
  def handle_info({:spectre, :advance, run_id}, data) do
    data = %{data | scheduled: false}

    case pop_ready(data, run_id) do
      {:ok, entry, data} ->
        {:noreply, start_advance_worker(data, entry)}

      {:error, _reason, data} ->
        {:noreply, maybe_schedule(data)}
    end
  end

  def handle_info(
        {:spectre, :advance_result, run_id, dispatch_id, capability, outcome},
        data
      ) do
    case data.active do
      %{
        run_id: ^run_id,
        dispatch_id: ^dispatch_id,
        capability: ^capability
      } = active ->
        {:noreply, receive_advance_result(data, active, outcome)}

      _stale ->
        emit(:stale_move_result, data, %{count: 1, run_id: run_id})
        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :invocation_result, invocation_id, %Receipt{} = receipt},
        data
      ) do
    case validate_invocation_receipt(data, invocation_id, receipt) do
      {:ok, ownership} ->
        data =
          data
          |> finish_worker(ownership.pid)
          |> Map.put(:invocations, Map.delete(data.invocations, invocation_id))
          |> Map.put(:state_lock, nil)

        {:noreply, apply_step(receipt.outcome, ownership.entry, data)}

      {:error, _reason} ->
        emit(:stale_invocation_result, data, %{count: 1, invocation_id: invocation_id})
        {:noreply, data}
    end
  end

  def handle_info({:idle_shutdown, generation}, %{idle_generation: generation} = data) do
    if busy?(data) or live_runs?(data) do
      {:noreply, arm_idle_timer(%{data | idle_timer: nil})}
    else
      emit(:idle_shutdown, data, %{count: 1})
      {:stop, :normal, %{data | idle_timer: nil}}
    end
  end

  def handle_info({:idle_shutdown, _stale_generation}, data), do: {:noreply, data}

  def handle_info({:DOWN, monitor, :process, pid, reason}, data) do
    if monitor == data.registry_monitor do
      {:stop, :normal, data}
    else
      case Map.get(data.workers, pid) do
        %{monitor: ^monitor} = worker ->
          {:noreply, worker_down(data, pid, worker, reason)}

        _unknown ->
          {:noreply, data}
      end
    end
  end

  def handle_info({:EXIT, pid, :normal}, data) when is_map_key(data.workers, pid),
    do: {:noreply, data}

  def handle_info({:EXIT, pid, reason}, data) do
    case Map.get(data.workers, pid) do
      nil -> {:noreply, data}
      worker -> {:noreply, worker_down(data, pid, worker, reason)}
    end
  end

  def handle_info(_message, data), do: {:noreply, data}

  defp receive_advance_result(data, active, outcome) do
    with %Run{} = current <- Map.get(data.runs, active.run_id),
         :ok <- validate_move_outcome(outcome, current, active.entry) do
      data = finish_worker(data, active.pid)
      apply_step(outcome, active.entry, %{data | active: nil})
    else
      nil ->
        data

      {:error, _reason} ->
        emit(:invalid_move_result, data, %{count: 1, run_id: active.run_id})
        data
    end
  end

  @impl GenServer
  def terminate(_reason, data) do
    Enum.each(Map.keys(data.workers), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    :ok
  end

  defp submit(input, opts, projection, from, data) do
    data = prune_for_new_run(data)

    case lifecycle_owner(data) do
      nil ->
        if map_size(data.runs) >= data.max_runs do
          {:reply, {:error, :instance_run_capacity_reached}, arm_idle_timer(data)}
        else
          reserve_submitted_run(input, opts, projection, from, data)
        end

      owner ->
        submit_lifecycle_input(input, opts, projection, from, owner, data)
    end
  end

  defp submit_lifecycle_input(input, opts, projection, from, owner, data) do
    case Map.get(data.runs, owner) do
      %Run{status: :boundary, cursor: :policy, waiting: %Boundary{}} = run ->
        if run_active?(data, run.id) do
          {:reply, {:error, {:run_already_active, run.id}}, arm_idle_timer(data)}
        else
          entry = %{
            run_id: run.id,
            operation: {:resume, {:input, input}},
            projection: projection,
            input: input,
            opts: runtime_opts(data, opts, input),
            state_revision: data.state.revision,
            internal?: false
          }

          {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
        end

      _effect_or_invalid ->
        {:reply, {:error, {:instance_lifecycle_locked, owner}}, arm_idle_timer(data)}
    end
  end

  defp reserve_submitted_run(input, opts, projection, from, data) do
    runtime_opts = runtime_opts(data, opts, input)

    case Run.validate_options(runtime_opts) do
      :ok ->
        run = Run.new(data.agent, %Input{}, data.state, runtime_opts)

        if Map.has_key?(data.runs, run.id) or Map.has_key?(data.tombstones, run.id) do
          {:reply, {:error, {:duplicate_instance_run, run.id}}, arm_idle_timer(data)}
        else
          entry = %{
            run_id: run.id,
            operation: {:start, input},
            projection: projection,
            input: input,
            opts: opts,
            state_revision: data.state.revision,
            internal?: false
          }

          next =
            data
            |> Map.put(:runs, Map.put(data.runs, run.id, run))
            |> enqueue(entry)
            |> put_caller(run.id, from)

          {:noreply, next}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp dispatch_invocation(run, command, opts, projection, from, data) do
    with %Invocation{} = invocation <- run.waiting,
         false <- run_active?(data, run.id),
         nil <- data.state_lock,
         true <- run.state.revision == data.state.revision do
      runtime_opts = runtime_opts(data, opts, run.input)
      dispatch_id = Spectre.Identity.uuid7()
      capability = make_ref()
      owner = self()

      entry = %{
        run_id: run.id,
        operation: {:resume, command},
        projection: projection,
        input: run.input,
        opts: runtime_opts,
        state_revision: data.state.revision,
        internal?: false
      }

      {pid, monitor} =
        spawn_invocation_worker(
          owner,
          run,
          invocation,
          command,
          runtime_opts,
          data.generation,
          dispatch_id,
          capability
        )

      ownership = %{
        invocation_id: invocation.id,
        run_id: run.id,
        run_revision: run.revision,
        generation: data.generation,
        dispatch_id: dispatch_id,
        capability: capability,
        pid: pid,
        monitor: monitor,
        entry: entry
      }

      worker = Map.merge(ownership, %{kind: :invocation})

      next =
        data
        |> put_caller(run.id, from)
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
        |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
        |> Map.put(:workers, Map.put(data.workers, pid, worker))
        |> disarm_idle_timer()

      emit(:invocation_dispatched, next, %{
        count: 1,
        run_id: run.id,
        invocation_id: invocation.id
      })

      {:noreply, next}
    else
      nil ->
        {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, arm_idle_timer(data)}

      true ->
        {:reply, {:error, {:run_already_active, run.id}}, arm_idle_timer(data)}

      %{} ->
        {:reply, {:error, :instance_state_locked}, arm_idle_timer(data)}

      false ->
        {:reply, {:error, {:stale_instance_run, run.id, run.state.revision, data.state.revision}},
         arm_idle_timer(data)}
    end
  end

  defp spawn_invocation_worker(
         owner,
         run,
         invocation,
         command,
         runtime_opts,
         generation,
         dispatch_id,
         capability
       ) do
    spawn_worker(fn ->
      outcome = safe_step(run, fn -> Runtime.resume(run, command, runtime_opts) end)

      receipt = %Receipt{
        invocation_id: invocation.id,
        run_id: run.id,
        run_revision: run.revision,
        generation: generation,
        dispatch_id: dispatch_id,
        capability: capability,
        outcome: outcome
      }

      send(owner, {:spectre, :invocation_result, invocation.id, receipt})
    end)
  end

  defp validate_invocation_receipt(data, invocation_id, %Receipt{} = receipt) do
    ownership = Map.get(data.invocations, invocation_id)

    cond do
      is_nil(ownership) ->
        {:error, :unknown_invocation}

      receipt.invocation_id != invocation_id ->
        {:error, :invocation_id_mismatch}

      receipt.run_id != ownership.run_id or
          receipt.run_revision != ownership.run_revision ->
        {:error, :run_fence_mismatch}

      receipt.generation != ownership.generation or
          receipt.dispatch_id != ownership.dispatch_id ->
        {:error, :dispatch_fence_mismatch}

      receipt.capability !== ownership.capability ->
        {:error, :invalid_receipt_capability}

      true ->
        with %Run{} = current <- Map.get(data.runs, ownership.run_id),
             true <- current.revision == ownership.run_revision,
             %Invocation{id: ^invocation_id} <- current.waiting,
             :ok <- validate_receipt_outcome(receipt.outcome, current) do
          {:ok, ownership}
        else
          _invalid -> {:error, :invalid_receipt_outcome}
        end
    end
  end

  defp validate_receipt_outcome({:continue, %Run{} = returned}, current),
    do: validate_returned_run(returned, current, :advanced)

  defp validate_receipt_outcome(
         {:await, %Invocation{} = invocation, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == invocation,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_await_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:boundary, %Boundary{} = boundary, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == boundary,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_boundary_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:complete, %Result{} = result, %Run{} = returned},
         current
       ) do
    with true <- returned.result == result,
         true <- returned.status == :complete and is_nil(returned.waiting),
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_completion_receipt}
    end
  end

  defp validate_receipt_outcome({:error, _reason, %Run{} = returned}, current) do
    cond do
      returned == current ->
        :ok

      returned.revision == current.revision + 1 ->
        validate_returned_run(returned, current, :advanced)

      true ->
        {:error, :invalid_error_receipt}
    end
  end

  defp validate_receipt_outcome(_outcome, _current),
    do: {:error, :invalid_receipt_shape}

  defp validate_move_outcome(
         {:continue, %Run{} = returned},
         current,
         %{operation: {:start, _input}}
       ) do
    validate_started_run(returned, current)
  end

  defp validate_move_outcome(
         {:error, _reason, %Run{} = returned},
         current,
         %{operation: {:start, _input}}
       ) do
    if returned.status == :failed,
      do: validate_receipt_outcome({:error, nil, returned}, current),
      else: validate_started_run(returned, current)
  end

  defp validate_move_outcome(outcome, current, _entry),
    do: validate_receipt_outcome(outcome, current)

  defp validate_started_run(%Run{} = returned, %Run{} = current) do
    with :ok <- validate_run_identity(returned, current),
         :ok <- validate_started_shape(returned, current),
         true <- returned.state.revision == current.state.revision do
      :ok
    else
      false -> {:error, :state_revision_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_run_identity(returned, current) do
    if {returned.id, returned.agent, returned.trace_id} ==
         {current.id, current.agent, current.trace_id},
       do: :ok,
       else: {:error, :run_lineage_mismatch}
  end

  defp validate_started_shape(returned, current) do
    if {returned.revision, returned.status, returned.cursor, returned.waiting, returned.result} ==
         {current.revision, :ready, :turn, nil, nil},
       do: :ok,
       else: {:error, :invalid_started_run}
  end

  defp validate_returned_run(%Run{} = returned, %Run{} = current, :advanced) do
    cond do
      returned.id != current.id or returned.agent != current.agent or
          returned.trace_id != current.trace_id ->
        {:error, :run_lineage_mismatch}

      returned.revision != current.revision + 1 ->
        {:error, :run_revision_mismatch}

      returned.state.revision not in [current.state.revision, current.state.revision + 1] ->
        {:error, :state_revision_mismatch}

      not valid_result_lineage?(returned) ->
        {:error, :result_lineage_mismatch}

      true ->
        :ok
    end
  end

  defp valid_result_lineage?(%Run{result: nil}), do: true

  defp valid_result_lineage?(%Run{result: %Result{} = result} = run) do
    case get_in(result.metadata, [:run]) do
      %{
        id: id,
        revision: revision,
        status: status,
        cursor: cursor,
        ref: %Ref{run_id: ref_run_id, revision: ref_revision}
      } ->
        id == run.id and revision == run.revision and status == run.status and
          cursor == run.cursor and ref_run_id == run.id and ref_revision == run.revision

      _missing ->
        false
    end
  end

  defp valid_result_lineage?(_run), do: false

  defp start_advance_worker(data, entry) do
    run = Map.fetch!(data.runs, entry.run_id)

    run =
      if initial_move?(entry, run) do
        %{run | state: data.state}
      else
        run
      end

    entry = prepare_entry(entry, run, data)
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()

    {pid, monitor} =
      spawn_advance_worker(owner, run, entry, dispatch_id, capability)

    active = %{
      kind: :advance,
      run_id: run.id,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry
    }

    data
    |> Map.put(:runs, Map.put(data.runs, run.id, run))
    |> Map.put(:active, active)
    |> Map.put(:workers, Map.put(data.workers, pid, active))
    |> disarm_idle_timer()
  end

  defp initial_move?(%{operation: {:start, _input}}, %Run{}), do: true

  defp initial_move?(%{operation: :advance}, %Run{status: :ready, cursor: :turn}),
    do: true

  defp initial_move?(_entry, _run), do: false

  defp prepare_entry(%{operation: {:start, input}} = entry, run, data) do
    opts =
      data
      |> runtime_opts(entry.opts, input)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(%{operation: :advance} = entry, _run, data) do
    opts = Keyword.put(entry.opts, :state, data.state)
    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(entry, _run, data),
    do: %{entry | state_revision: data.state.revision}

  defp spawn_advance_worker(owner, run, entry, dispatch_id, capability) do
    spawn_worker(fn ->
      outcome = safe_step(run, fn -> run_operation(run, entry) end)

      send(
        owner,
        {:spectre, :advance_result, run.id, dispatch_id, capability, outcome}
      )
    end)
  end

  defp run_operation(run, %{operation: :advance, opts: opts}),
    do: Runtime.advance(run, opts)

  defp run_operation(run, %{operation: {:start, input}, opts: opts}) do
    case Runtime.start(run.agent, input, opts) do
      {:error, reason, %Run{} = failed} ->
        {:error, reason, %{failed | state: run.state}}

      step ->
        step
    end
  end

  defp run_operation(run, %{operation: {:resume, command}, opts: opts}),
    do: Runtime.resume(run, command, opts)

  defp apply_step(outcome, entry, data) do
    case outcome do
      {:error, reason, %Run{} = run} ->
        current = Map.get(data.runs, run.id)
        data = apply_returned_run(data, run, entry)

        cond do
          terminal_run?(run) ->
            data
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
            |> record_terminal(run)
            |> reject_lifecycle_blocked_ready()
            |> maybe_schedule()
            |> arm_idle_timer()

          start_operation?(entry) ->
            failed = terminalize_failed_run(run, reason)

            data
            |> put_run(failed)
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
            |> record_terminal(failed)
            |> reject_lifecycle_blocked_ready()
            |> maybe_schedule()
            |> arm_idle_timer()

          advanced_run?(current, run) ->
            degraded = %{run | last_error: reason}

            data
            |> put_run(degraded)
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_move_degraded, &1, %{count: 1, run_id: run.id}))
            |> maybe_finalize_degraded_run(degraded)
            |> reject_lifecycle_blocked_ready()
            |> maybe_schedule()
            |> arm_idle_timer()

          true ->
            data
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_resume_rejected, &1, %{count: 1, run_id: run.id}))
            |> maybe_schedule()
            |> arm_idle_timer()
        end

      step ->
        apply_successful_step(step, entry, data)
    end
  end

  defp start_operation?(%{operation: {:start, _input}}), do: true
  defp start_operation?(_entry), do: false

  defp advanced_run?(%Run{} = current, %Run{} = returned),
    do: returned.revision > current.revision

  defp advanced_run?(_current, _returned), do: true

  defp maybe_finalize_degraded_run(
         data,
         %Run{waiting: %Boundary{kind: :reply} = boundary} = run
       ) do
    maybe_finalize_reply(data, {:boundary, boundary, run})
  end

  defp maybe_finalize_degraded_run(data, _run), do: data

  defp apply_successful_step({:continue, %Run{} = run}, entry, data) do
    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      data =
        data
        |> apply_returned_run(run, entry)
        |> maybe_record_started_conversation(entry, run)

      continuation = %{
        entry
        | operation: :advance,
          input: run.input,
          state_revision: data.state.revision
      }

      data
      |> enqueue_continuation(continuation, start_operation?(entry))
      |> arm_idle_timer()
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(step, entry, data) do
    run = step_run(step)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      data = apply_returned_run(data, run, entry)
      data = reply_projection(data, entry, step)
      data = maybe_finalize_reply(data, step)
      data = if terminal_run?(run), do: record_terminal(data, run), else: data

      data
      |> reject_lifecycle_blocked_ready()
      |> maybe_schedule()
      |> arm_idle_timer()
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp reject_stale_step(data, entry, run) do
    reason =
      {:stale_instance_state, run.id, entry.state_revision, data.state.revision}

    failed = terminalize_failed_run(run, reason)
    data = data |> put_run(failed) |> reply_caller(run.id, {:error, reason})
    data |> record_terminal(failed) |> maybe_schedule() |> arm_idle_timer()
  end

  defp maybe_record_started_conversation(
         data,
         %{operation: {:start, _input}, opts: opts},
         run
       ),
       do: record_conversation(data, run, opts)

  defp maybe_record_started_conversation(data, _entry, _run), do: data

  defp apply_returned_run(data, %Run{} = run, entry) do
    next_state =
      if not entry.internal? and entry.state_revision == data.state.revision do
        run.state
      else
        data.state
      end

    last_result = if match?(%Result{}, run.result), do: run.result, else: data.last_result

    %{
      data
      | runs: Map.put(data.runs, run.id, run),
        state: next_state,
        last_result: last_result
    }
  end

  defp reply_projection(data, %{internal?: true}, _step), do: data

  defp reply_projection(data, entry, step) do
    reply =
      case entry.projection do
        :turn -> {:ok, Turn.from_step(self(), entry.input, entry.opts, step)}
        :result -> {:ok, step_result(step)}
      end

    reply_caller(data, entry.run_id, reply)
  end

  defp maybe_finalize_reply(data, {:boundary, %Boundary{kind: :reply}, %Run{} = run}) do
    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: runtime_opts(data, [], run.input),
      state_revision: data.state.revision,
      internal?: true
    }

    enqueue(data, entry)
  end

  defp maybe_finalize_reply(data, _step), do: data

  defp enqueue(data, entry, priority? \\ false) do
    if MapSet.member?(data.queued, entry.run_id) or run_active?(data, entry.run_id) do
      data
    else
      put_ready_entry(data, entry, priority?)
    end
  end

  # A closed `{:continue, run}` is the same public call advancing by another
  # mailbox move. Its caller remains registered while the Run returns to the
  # ready queue. Start is intentionally a bounded two-move sequence so another
  # Run cannot normalize against State and then wait behind the first Run's
  # commit.
  defp enqueue_continuation(data, entry, priority?),
    do: put_ready_entry(data, entry, priority?)

  defp put_ready_entry(data, entry, priority?) do
    ready =
      if priority?,
        do: :queue.in_r(entry.run_id, data.ready),
        else: :queue.in(entry.run_id, data.ready)

    data =
      %{
        data
        | ready: ready,
          queued: MapSet.put(data.queued, entry.run_id),
          entries: Map.put(data.entries, entry.run_id, entry)
      }

    maybe_schedule(data)
  end

  defp reject_lifecycle_blocked_ready(data) do
    case lifecycle_owner(data) do
      nil ->
        data

      owner ->
        {kept, blocked} =
          data.ready
          |> :queue.to_list()
          |> Enum.split_with(fn run_id ->
            run_id == owner or get_in(data.entries, [run_id, :internal?]) == true
          end)

        data = %{
          data
          | ready: Enum.reduce(kept, :queue.new(), &:queue.in(&1, &2)),
            queued: MapSet.new(kept),
            entries: Map.take(data.entries, kept)
        }

        Enum.reduce(blocked, data, &reject_lifecycle_run(&2, &1, owner))
    end
  end

  defp reject_lifecycle_run(data, run_id, owner) do
    reason = {:instance_lifecycle_locked, owner}

    case Map.get(data.runs, run_id) do
      %Run{} = run ->
        failed = terminalize_failed_run(run, reason)

        data
        |> put_run(failed)
        |> reply_caller(run_id, {:error, reason})
        |> record_terminal(failed)

      nil ->
        reply_caller(data, run_id, {:error, reason})
    end
  end

  defp maybe_schedule(%{scheduled: true} = data), do: data
  defp maybe_schedule(%{active: active} = data) when not is_nil(active), do: data
  defp maybe_schedule(%{state_lock: lock} = data) when not is_nil(lock), do: data

  defp maybe_schedule(data) do
    case :queue.peek(data.ready) do
      {:value, run_id} ->
        maybe_schedule_run(data, run_id)

      :empty ->
        data
    end
  end

  defp maybe_schedule_run(data, run_id) do
    if schedulable_run?(data, run_id) do
      send(self(), {:spectre, :advance, run_id})
      %{data | scheduled: true}
    else
      data
    end
  end

  defp schedulable_run?(data, run_id) do
    lifecycle_owner(data) in [nil, run_id] or
      match?(%{internal?: true}, Map.get(data.entries, run_id))
  end

  defp pop_ready(data, expected_run_id) do
    case :queue.out(data.ready) do
      {{:value, ^expected_run_id}, ready} ->
        entry = Map.fetch!(data.entries, expected_run_id)

        next = %{
          data
          | ready: ready,
            queued: MapSet.delete(data.queued, expected_run_id),
            entries: Map.delete(data.entries, expected_run_id)
        }

        {:ok, entry, next}

      {{:value, _other}, _ready} ->
        {:error, :out_of_order_advance, data}

      {:empty, _ready} ->
        {:error, :empty_ready_queue, data}
    end
  end

  defp put_caller(data, run_id, from) do
    %{data | callers: Map.put_new(data.callers, run_id, from)}
  end

  defp reply_caller(data, run_id, reply) do
    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, reply)
        %{data | callers: callers}
    end
  end

  defp owned_result_run(data, %Result{} = result, allow_terminal_replay? \\ false) do
    case get_in(result.metadata, [:run, :id]) do
      run_id when is_binary(run_id) ->
        owned_result_run_by_id(data, result, run_id, allow_terminal_replay?)

      _missing ->
        {:error, :result_has_no_run_reference}
    end
  end

  defp owned_result_run_by_id(data, result, run_id, allow_terminal_replay?) do
    case Map.get(data.runs, run_id) do
      %Run{} = run ->
        validate_owned_result(run, result, allow_terminal_replay?)

      nil ->
        {:error, {:unknown_instance_run, run_id}}
    end
  end

  defp validate_owned_result(run, result, allow_terminal_replay?) do
    supplied_ref = get_in(result.metadata, [:run, :ref])

    cond do
      run_ref_matches?(run, supplied_ref) ->
        {:ok, run}

      allow_terminal_replay? and terminal_replay?(result, run.result) ->
        {:ok, run}

      is_nil(supplied_ref) ->
        {:error, :result_has_no_run_reference}

      true ->
        {:error, {:stale_instance_run_reference, run.id}}
    end
  end

  defp owned_run(data, %Ref{} = supplied_ref) do
    case Map.get(data.runs, supplied_ref.run_id) do
      %Run{status: status} when status in [:complete, :failed] ->
        {:error, {:instance_run_terminal, supplied_ref.run_id, status}}

      %Run{} = run ->
        if run_ref_matches?(run, supplied_ref),
          do: {:ok, run},
          else:
            {:error,
             {:stale_instance_run_reference, supplied_ref.run_id, supplied_ref.revision,
              run.revision}}

      nil ->
        {:error, {:unknown_instance_run, supplied_ref.run_id}}
    end
  end

  defp run_ref_matches?(
         %Run{revision: revision, waiting: %{ref: %Ref{} = expected}},
         %Ref{} = supplied
       ),
       do: expected.revision == revision and expected == supplied

  defp run_ref_matches?(
         %Run{revision: revision, result: %Result{} = result},
         %Ref{} = supplied
       ) do
    case get_in(result.metadata, [:run, :ref]) do
      %Ref{revision: ^revision} = expected -> expected == supplied
      _missing_or_stale -> false
    end
  end

  defp run_ref_matches?(_run, _supplied), do: false

  defp lifecycle_owner(data) do
    Enum.find_value(data.runs, fn
      {run_id, %Run{status: :awaiting, cursor: :effect, waiting: %Invocation{}}} -> run_id
      {run_id, %Run{status: :boundary, cursor: :policy, waiting: %Boundary{}}} -> run_id
      _entry -> nil
    end)
  end

  defp run_active?(data, run_id) do
    match?(%{run_id: ^run_id}, data.active) or
      MapSet.member?(data.queued, run_id) or
      Map.has_key?(data.callers, run_id) or
      Enum.any?(data.invocations, fn {_id, ownership} -> ownership.run_id == run_id end)
  end

  defp execute_command?({:execute, _value}), do: true
  defp execute_command?(_command), do: false

  defp worker_down(data, pid, worker, reason) do
    data = finish_worker(data, pid)
    failure = {:instance_worker_down, worker.kind, reason}
    run = Map.get(data.runs, worker.run_id)

    failed = if run, do: terminalize_failed_run(run, failure), else: nil

    data =
      data
      |> Map.put(:active, if(match?(%{pid: ^pid}, data.active), do: nil, else: data.active))
      |> Map.put(:state_lock, nil)
      |> Map.put(
        :invocations,
        Enum.reject(data.invocations, fn {_id, value} -> value.pid == pid end) |> Map.new()
      )

    data = if failed, do: put_run(data, failed), else: data
    data = reply_caller(data, worker.run_id, {:error, failure})
    data = if failed, do: record_terminal(data, failed), else: data
    data |> maybe_schedule() |> arm_idle_timer()
  end

  defp spawn_worker(fun) do
    :erlang.spawn_opt(fun, [:link, :monitor])
  end

  defp safe_step(run, fun) do
    fun.()
  rescue
    exception ->
      failed =
        terminalize_failed_run(
          run,
          {:instance_worker_exception, exception.__struct__}
        )

      {:error, failed.last_error, failed}
  catch
    kind, reason ->
      failed = terminalize_failed_run(run, {:instance_worker_failure, kind, reason})

      {:error, failed.last_error, failed}
  end

  defp terminalize_failed_run(%Run{} = run, failure) do
    failed = %{
      run
      | status: :failed,
        cursor: :complete,
        revision: run.revision + 1,
        waiting: nil,
        last_error: failure
    }

    put_failure_lineage(failed)
  end

  defp put_failure_lineage(%Run{result: %Result{} = result} = run) do
    boundary_id = Value.token("instance-error", {run.id, run.revision})
    ref = Ref.new(run.id, run.revision, :error, boundary_id)

    lineage = %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      step_id: run.step_id,
      trace_id: run.trace_id,
      ref: ref
    }

    result = %{result | metadata: Map.put(result.metadata, :run, lineage)}
    %{run | result: result}
  end

  defp put_failure_lineage(%Run{} = run), do: run

  defp finish_worker(data, pid) do
    case Map.pop(data.workers, pid) do
      {nil, workers} ->
        %{data | workers: workers}

      {%{monitor: monitor}, workers} ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(pid)
        %{data | workers: workers}
    end
  end

  defp step_run({:await, %Invocation{}, %Run{} = run}), do: run
  defp step_run({:boundary, %Boundary{}, %Run{} = run}), do: run
  defp step_run({:complete, %Result{}, %Run{} = run}), do: run

  defp step_result({:await, %Invocation{}, %Run{result: result}}), do: result
  defp step_result({:boundary, %Boundary{}, %Run{result: result}}), do: result
  defp step_result({:complete, %Result{} = result, %Run{}}), do: result
  defp state_neutral_step?(%{internal?: true}, %Run{}), do: true
  defp state_neutral_step?(_entry, _run), do: false

  defp terminal_run?(%Run{status: status}), do: status in [:complete, :failed]

  defp terminal_result?(%Result{} = result) do
    is_nil(Spectre.Result.pending_effect(result)) and
      Enum.any?(result.effects, &Spectre.Effect.terminal?/1)
  end

  defp terminal_replay?(%Result{} = supplied, %Result{} = current) do
    terminal_result?(supplied) and terminal_result?(current) and
      terminal_effects(supplied) == terminal_effects(current)
  end

  defp terminal_replay?(_supplied, _current), do: false

  defp terminal_effects(%Result{} = result) do
    result.effects
    |> Enum.filter(&Spectre.Effect.terminal?/1)
    |> Enum.map(&{&1.id, &1.status})
    |> Enum.sort()
  end

  defp record_terminal(data, %Run{} = run) do
    if MapSet.member?(data.terminal_recorded, run.id) do
      data
    else
      completed = :queue.in(run.id, data.completed)

      %{
        data
        | completed: completed,
          terminal_recorded: MapSet.put(data.terminal_recorded, run.id)
      }
      |> prune_terminal()
    end
  end

  defp prune_terminal(data) when map_size(data.runs) <= data.max_runs, do: data

  defp prune_terminal(data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            tombstone = run_projection(run)

            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, tombstone)
            }

            next |> prune_tombstones() |> prune_terminal()

          nil ->
            prune_terminal(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  defp prune_for_new_run(data) when map_size(data.runs) < data.max_runs, do: data

  defp prune_for_new_run(data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, run_projection(run))
            }

            next |> prune_tombstones() |> prune_for_new_run()

          nil ->
            prune_for_new_run(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  defp prune_tombstones(%{max_tombstones: max} = data)
       when map_size(data.tombstones) <= max,
       do: data

  defp prune_tombstones(data) do
    {run_id, _value} =
      Enum.min_by(data.tombstones, fn {_id, tombstone} ->
        {Map.get(tombstone, :revision, 0), Map.get(tombstone, :id)}
      end)

    prune_tombstones(%{data | tombstones: Map.delete(data.tombstones, run_id)})
  end

  defp put_run(data, %Run{} = run), do: %{data | runs: Map.put(data.runs, run.id, run)}

  defp busy?(data) do
    not is_nil(data.active) or not is_nil(data.state_lock) or
      not :queue.is_empty(data.ready) or map_size(data.invocations) > 0
  end

  defp live_runs?(data) do
    Enum.any?(data.runs, fn {_id, run} -> not terminal_run?(run) end)
  end

  defp info_projection(data) do
    %{
      ref: data.ref.key,
      agent_ref: AgentRef.key(data.agent_ref),
      subject: Subject.key(data.subject),
      generation: data.generation,
      state_revision: data.state.revision,
      conversations: data.conversations,
      runs: Map.new(data.runs, fn {id, run} -> {id, run_projection(run)} end),
      ready: :queue.to_list(data.ready),
      active_run: data.active && data.active.run_id,
      invocations:
        Map.new(data.invocations, fn {id, ownership} ->
          {id,
           %{
             run_id: ownership.run_id,
             run_revision: ownership.run_revision
           }}
        end),
      tombstones: data.tombstones
    }
  end

  defp run_projection(%Run{} = run) do
    %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      waiting: waiting_kind(run.waiting),
      ref: run.result && get_in(run.result.metadata, [:run, :ref])
    }
  end

  defp waiting_kind(%Invocation{}), do: :invocation
  defp waiting_kind(%Boundary{kind: kind}), do: kind
  defp waiting_kind(nil), do: nil

  defp runtime_opts(data, opts, input) do
    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        input_conversation_id(input)
      ])

    opts =
      data.base_opts
      |> Keyword.merge(
        Keyword.drop(opts, [
          :timeout,
          :state,
          :conversation_id,
          :origin_conversation_id,
          :subject
        ])
      )
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:subject, data.subject)
      |> Keyword.put(:subject_id, data.subject.id)
      |> Keyword.put(:conversation_id, Keyword.fetch!(data.base_opts, :conversation_id))
      |> maybe_put(:origin_conversation_id, origin_conversation_id)

    metadata =
      case Keyword.get(opts, :run_metadata, %{}) do
        value when is_map(value) -> value
        _invalid -> %{}
      end
      |> Map.merge(%{
        instance_ref: data.ref,
        agent_ref: data.agent_ref,
        subject: data.subject,
        conversation_ref: conversation_key(input, origin_conversation_id)
      })

    Keyword.put(opts, :run_metadata, metadata)
  end

  defp base_opts(opts, instance_ref) do
    state_conversation_id =
      Keyword.get(opts, :state_conversation_id, instance_ref.key)
      |> validate_state_conversation_id!()

    opts
    |> Keyword.get(:opts, [])
    |> Keyword.put(:conversation_id, state_conversation_id)
    |> Keyword.put(:subject, instance_ref.subject)
    |> Keyword.put(:subject_id, instance_ref.subject.id)
  end

  defp validate_state_conversation_id!(value) do
    case Value.validate(value, [:instance, :state_conversation_id]) do
      :ok ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "invalid Instance state_conversation_id: #{inspect(reason)}"
    end
  end

  defp record_conversation(data, %Run{} = run, opts) do
    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        input_conversation_id(run.input)
      ])

    case conversation_key(run.input, origin_conversation_id) do
      nil ->
        data

      key ->
        source = input_source(run.input)
        current = Map.get(data.conversations, key, %{count: 0})

        conversation =
          current
          |> Map.put(:key, key)
          |> Map.put(:channel, source_field(source, :kind))
          |> Map.put(:mount, source_field(source, :mount))
          |> Map.put(:last_run_id, run.id)
          |> Map.update!(:count, &(&1 + 1))

        %{data | conversations: Map.put(data.conversations, key, conversation)}
    end
  end

  defp conversation_key(_input, nil), do: nil

  defp conversation_key(input, conversation_id) do
    source = input_source(input)

    value = {
      source_field(source, :kind),
      source_field(source, :mount),
      conversation_id
    }

    case Value.validate(value, [:instance, :conversation]) do
      :ok -> Value.token("conversation", value)
      {:error, _reason} -> nil
    end
  end

  defp input_conversation_id(input),
    do: input |> input_source() |> source_field(:conversation_id)

  defp input_source(input) when is_map(input),
    do: Map.get(input, :source, Map.get(input, "source"))

  defp input_source(_input), do: nil

  defp source_field(source, key) when is_map(source),
    do: Map.get(source, key, Map.get(source, Atom.to_string(key)))

  defp source_field(_source, _key), do: nil

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp restore_initial_state(agent, opts, base_opts) do
    if Keyword.has_key?(opts, :state) do
      state =
        opts
        |> Keyword.fetch!(:state)
        |> State.new()
        |> put_conversation_id(Keyword.fetch!(base_opts, :conversation_id))

      {:ok, state}
    else
      Runtime.restore_state(agent, base_opts)
    end
  end

  defp put_conversation_id(%State{} = state, nil), do: state
  defp put_conversation_id(%State{} = state, id), do: %{state | conversation_id: id}

  defp instance_ref!(opts) do
    agent_ref =
      case Keyword.get(opts, :agent_ref) do
        %AgentRef{} = ref ->
          AgentRef.new(ref)

        nil ->
          agent = Keyword.fetch!(opts, :agent)

          case Keyword.get(opts, :agent_id) do
            nil -> AgentRef.new(agent)
            id -> AgentRef.new(agent, id: id)
          end
      end

    subject =
      case Keyword.fetch(opts, :subject) do
        {:ok, %Subject{} = subject} -> Subject.new(subject)
        {:ok, subject} -> Subject.new(subject)
        :error -> raise ArgumentError, "Spectre.Instance requires an explicit :subject"
      end

    InstanceRef.new(agent_ref, subject)
  end

  defp idle_timeout(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    first_configured([
      {opts, :idle},
      {opts, :shutdown},
      {base_opts, :idle},
      {base_opts, :shutdown},
      {config, :idle},
      {config, :shutdown}
    ])
  end

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp arm_idle_timer(data) do
    data = disarm_idle_timer(data)
    generation = data.idle_generation + 1

    timer =
      case data.idle_timeout do
        timeout when is_integer(timeout) and timeout > 0 ->
          if busy?(data) or live_runs?(data),
            do: nil,
            else: Process.send_after(self(), {:idle_shutdown, generation}, timeout)

        _other ->
          nil
      end

    %{data | idle_timer: timer, idle_generation: generation}
  end

  defp disarm_idle_timer(data) do
    if is_reference(data.idle_timer), do: Process.cancel_timer(data.idle_timer)
    %{data | idle_timer: nil}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value), do: {:error, {:invalid_instance_max_runs, value}}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value),
    do: {:error, {:invalid_instance_max_tombstones, value}}

  defp timeout(opts), do: Keyword.get(opts, :timeout, :timer.minutes(5))

  defp monitor_registry(registry, instance_ref) when is_atom(registry) do
    case Process.whereis(registry) do
      pid when is_pid(pid) ->
        monitor_registry_pid(pid, registry, instance_ref)

      nil ->
        {:error, :instance_registry_unavailable}
    end
  catch
    :exit, _reason -> {:error, :instance_registry_unavailable}
  end

  defp monitor_registry_pid(pid, registry, instance_ref) do
    monitor = Process.monitor(pid)

    if registered_instance?(registry, instance_ref) do
      {:ok, monitor}
    else
      Process.demonitor(monitor, [:flush])
      {:error, :instance_registry_registration_lost}
    end
  end

  defp registered_instance?(registry, instance_ref) do
    Enum.any?(Registry.lookup(registry, instance_ref.key), fn
      {instance, _value} -> instance == self()
    end)
  end

  defp emit(event, data, measurements) do
    Spectre.Telemetry.emit(
      [:instance, event],
      measurements,
      %{
        agent: data.agent,
        agent_ref: AgentRef.key(data.agent_ref),
        subject: Subject.key(data.subject),
        generation: data.generation
      },
      data.base_opts
    )
  end
end
