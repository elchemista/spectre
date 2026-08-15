defmodule Spectre.Instance.Operations do
  @moduledoc false

  # Executes the operational-loop state machine inside the Instance owner
  # process. It owns queueing, runner monitors, progress commits, result
  # materialization, and post-commit event routing. No function here starts a
  # second authority: all state transitions are synchronous transformations of
  # the owner state, and messages or monitors deliberately use the caller's
  # process identity.

  alias Spectre.Execution.Admission, as: ExecutionAdmission
  alias Spectre.Execution.Materialization, as: ExecutionMaterialization
  alias Spectre.Execution.Runtime, as: DataExecutionRuntime
  alias Spectre.Identity
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Configuration
  alias Spectre.Instance.Deliveries
  alias Spectre.Instance.Events
  alias Spectre.Instance.Idle
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Owner
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Instance.Timers
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Operation.Memory
  alias Spectre.Operation.Progress, as: OperationProgress
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Operation.Result, as: OperationResult
  alias Spectre.Operation.Runner
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Operation.Runtime, as: OperationRuntime
  alias Spectre.Operation.View, as: OperationView
  alias Spectre.Run
  alias Spectre.Run.Value
  alias Spectre.Runtime

  @type call_reply :: {:reply, term(), InstanceState.t()}
  @type info_reply :: {:noreply, InstanceState.t()}

  @doc false
  @spec callers() :: [pid()]
  def callers, do: operation_callers()

  @doc false
  @spec control(GenServer.server(), term(), atom(), term(), keyword()) :: term()
  def control(server, loop, action, payload, opts),
    do: control_loop(server, loop, action, payload, opts)

  @doc false
  @spec start(atom(), module(), term(), keyword(), GenServer.from(), InstanceState.t()) ::
          call_reply()
  def start(kind, controller, input, opts, from, %InstanceState{} = data) do
    caller = elem(from, 0)
    callers = Enum.uniq([caller | Keyword.get(opts, :__spectre_callers__, [])])
    opts = Keyword.delete(opts, :__spectre_callers__)
    active_definition_ref = Events.active_definition_ref(data)

    if nested_work?(data, callers, kind) do
      {:reply, {:error, :work_cannot_start_work}, Idle.arm(data)}
    else
      with :ok <- Events.authorize(data, active_definition_ref, :new_admission),
           env <- Loops.operation_env(data),
           {:ok, loop, loop_control, event_specs} <-
             OperationRuntime.start(kind, controller, input, opts, env) do
        reply_started_loop(data, loop, loop_control, event_specs, :loop_started)
      else
        {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
      end
    end
  end

  @doc false
  @spec start_execution(
          ExecutionMaterialization.t(),
          keyword(),
          GenServer.from(),
          InstanceState.t()
        ) :: call_reply()
  def start_execution(materialization, opts, from, %InstanceState{} = data) do
    caller = elem(from, 0)
    callers = Enum.uniq([caller | Keyword.get(opts, :__spectre_callers__, [])])
    opts = Keyword.delete(opts, :__spectre_callers__)
    active_definition_ref = Events.active_definition_ref(data)

    if nested_work?(data, callers, :work) do
      {:reply, {:error, :work_cannot_start_work}, Idle.arm(data)}
    else
      with :ok <- Events.authorize(data, active_definition_ref, :new_admission),
           :ok <-
             ExecutionAdmission.verify(
               materialization,
               data.definition_store,
               data.activation,
               data.base_opts
             ),
           env <- Loops.operation_env(data),
           {:ok, loop, loop_control, event_specs} <-
             DataExecutionRuntime.start(materialization, opts, env) do
        reply_started_loop(
          data,
          loop,
          loop_control,
          event_specs,
          :data_driven_work_started
        )
      else
        {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
      end
    end
  end

  @doc false
  @spec view(String.t(), keyword(), InstanceState.t()) :: call_reply()
  def view(loop_id, opts, %InstanceState{} = data) do
    reply =
      with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
           :ok <- Loops.authorize_loop(loop, opts) do
        {:ok, OperationView.from_loop(loop, control)}
      end

    {:reply, reply, Idle.arm(data)}
  end

  @doc false
  @spec views(keyword(), InstanceState.t()) :: call_reply()
  def views(opts, %InstanceState{} = data) do
    views =
      data
      |> Loops.all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, Loops.authorize_loop(loop, opts)) and Loops.loop_filter?(loop, opts)
      end)
      |> Enum.map(fn {loop, control} -> OperationView.from_loop(loop, control) end)

    {:reply, {:ok, views}, Idle.arm(data)}
  end

  @doc false
  @spec resolve(term(), keyword(), InstanceState.t()) :: call_reply()
  def resolve(selector, opts, %InstanceState{} = data) do
    matches =
      data
      |> Loops.all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, Loops.authorize_loop(loop, opts)) and
          Loops.selector_matches?(loop, selector)
      end)

    reply =
      case matches do
        [{loop, control}] ->
          {:ok, OperationView.from_loop(loop, control)}

        [] ->
          {:error, :operation_loop_not_found}

        many ->
          candidates =
            Enum.map(many, fn {loop, control} ->
              view = OperationView.from_loop(loop, control)
              Map.take(view, [:id, :kind, :definition, :status, :phase, :updated_at])
            end)

          {:error, {:ambiguous_operation_loops, candidates}}
      end

    {:reply, reply, Idle.arm(data)}
  end

  @doc false
  @spec request_control(String.t(), atom(), term(), keyword(), InstanceState.t()) :: call_reply()
  def request_control(loop_id, action, payload, opts, %InstanceState{} = data) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, command} <- Loops.control_command(loop, action, payload, opts),
         result <-
           OperationRuntime.request_control(loop, control, command, Loops.operation_env(data)) do
      reply_control_result(data, action, command, result)
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  @doc false
  @spec trigger(String.t(), term(), keyword(), InstanceState.t()) :: call_reply()
  def trigger(loop_id, trigger, opts, %InstanceState{} = data) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, operation_definition_ref} <- Events.operation_definition_ref(data, loop),
         :ok <- Events.authorize(data, operation_definition_ref, :continuation),
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.trigger(loop, control, trigger, opts, Loops.operation_env(data)),
         {:ok, next, committed_events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: Keyword.get(opts, :correlation_id, Identity.uuid7()),
             causation_id: Keyword.get(opts, :causation_id),
             provenance: Keyword.get(opts, :provenance, %{}),
             transition: :loop_triggered
           ) do
      next =
        next
        |> maybe_emit_uncorrelated_operation_trigger(committed_events)
        |> Timers.maybe_schedule_wait_timer(next_loop)
        |> queue_operation(next_loop)
        |> maybe_schedule_operations()

      {:reply, {:ok, OperationView.from_loop(next_loop, next_control)}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp reply_started_loop(data, loop, control, event_specs, transition) do
    case Loops.operation_loop(data, loop.id) do
      {:ok, existing, existing_control} ->
        if Loops.same_loop_request?(existing, loop) do
          view = OperationView.from_loop(existing, existing_control)
          {:reply, {:ok, OperationRef.from_loop(existing), view}, Idle.arm(data)}
        else
          {:reply, {:error, {:duplicate_operational_loop, loop.id}}, Idle.arm(data)}
        end

      {:error, :operation_loop_not_found} ->
        case commit_operational(data, loop, control, event_specs,
               correlation_id: loop.correlation_id,
               provenance: loop.provenance,
               transition: transition
             ) do
          {:ok, next, _events} ->
            next = next |> queue_operation(loop) |> maybe_schedule_operations()
            view = OperationView.from_loop(loop, control)
            {:reply, {:ok, OperationRef.from_loop(loop), view}, Idle.disarm(next)}

          {:error, reason} ->
            {:reply, {:error, reason}, Idle.arm(data)}
        end
    end
  end

  defp reply_control_result(data, _action, _command, {:duplicate, loop, control}) do
    {:reply, {:ok, OperationView.from_loop(loop, control)}, Idle.arm(data)}
  end

  defp reply_control_result(
         data,
         action,
         command,
         {:ok, next_loop, next_control, runner_action, event_specs}
       ) do
    case commit_operational(data, next_loop, next_control, event_specs,
           correlation_id: command.correlation_id,
           causation_id: command.causation_id,
           provenance: command.provenance,
           transition: {:loop_control, action}
         ) do
      {:ok, next, committed_events} ->
        next =
          next
          |> maybe_emit_uncorrelated_operation_trigger(committed_events)
          |> apply_runner_action(runner_action)
          |> maybe_queue_after_transition(next_loop, next_control)
          |> Timers.maybe_schedule_wait_timer(next_loop)
          |> maybe_schedule_operations()

        {:reply, {:ok, OperationView.from_loop(next_loop, next_control)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, data}
    end
  end

  defp reply_control_result(data, _action, _command, {:error, reason}),
    do: {:reply, {:error, reason}, data}

  @doc false
  @spec scheduled(InstanceState.t()) :: info_reply()
  def scheduled(%InstanceState{} = data) do
    data = %{data | operation_scheduled: false}

    case pop_operation(data) do
      {:ok, loop_key, next} ->
        {:noreply, next |> advance_operation(loop_key) |> maybe_schedule_operations()}

      {:empty, next} ->
        {:noreply, Idle.arm(next)}
    end
  end

  @doc false
  @spec result(OperationResult.t(), InstanceState.t()) :: info_reply()
  def result(%OperationResult{} = result, %InstanceState{} = data) do
    case Map.get(data.operation_runners, result.attempt_id) do
      nil ->
        emit(
          :stale_operation_result,
          data,
          %{count: 1},
          %{loop_id: id_digest(result.loop_id)}
        )

        {:noreply, data}

      ownership ->
        apply_operation_result(data, ownership, result)
    end
  end

  defp apply_operation_result(data, ownership, result) do
    with {:ok, loop, control} <- Loops.operation_loop(data, result.loop_id),
         {:ok, next_loop, next_control, event_specs, start_loop_intents} <-
           normalize_operation_result(
             OperationRuntime.apply_result_with_start_loops(
               loop,
               control,
               result,
               Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
             )
           ),
         {:ok, started_loops, already_started} <-
           materialize_start_loop_intents(data, next_loop, result, start_loop_intents),
         {:ok, next, _events} <-
           commit_operation_result_with_started_loops(
             data,
             next_loop,
             next_control,
             event_specs,
             result,
             started_loops,
             already_started
           ) do
      next =
        next
        |> finish_operation_runner(ownership)
        |> maybe_remember_operation_result(next_loop, result, ownership.spec)
        |> maybe_queue_after_transition(next_loop, next_control)
        |> Timers.maybe_schedule_wait_timer(next_loop)
        |> queue_started_loops(started_loops)
        |> maybe_schedule_operations()

      {:noreply, next}
    else
      {:duplicate, _loop} ->
        next = data |> finish_operation_runner(ownership) |> maybe_schedule_operations()
        {:noreply, next}

      {:error, reason} ->
        emit(
          :rejected_operation_result,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(result.loop_id),
            reason_class: reason_class(reason)
          }
        )

        {:noreply, reject_operation_result(data, ownership, result, reason)}
    end
  end

  @doc false
  @spec progress(OperationProgress.t(), InstanceState.t()) :: info_reply()
  def progress(%OperationProgress{} = progress, %InstanceState{} = data) do
    case accept_operation_progress(data, progress) do
      {:ok, loop, control, next} ->
        loop =
          loop
          |> Map.put(:last_progress, progress.value)
          |> Map.put(:progress_sequence, progress.sequence)
          |> OperationLoop.touch(at: progress.at)

        case commit_operational(next, loop, control, [],
               correlation_id: loop.correlation_id,
               causation_id: progress.id,
               provenance: %{runner_attempt: progress.attempt_id},
               transition: :operation_progress
             ) do
          {:ok, committed, _events} -> {:noreply, committed}
          {:error, _reason} -> {:noreply, next}
        end

      {:throttled, next} ->
        {:noreply, next}

      :drop ->
        {:noreply, data}
    end
  end

  @doc false
  @spec timer(String.t(), String.t(), non_neg_integer(), InstanceState.t()) :: info_reply()
  def timer(loop_id, wait_id, generation, %InstanceState{} = data) do
    case Timers.consume_wait_timer(data, loop_id, wait_id, generation) do
      {:ok, data} ->
        with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.trigger(
                 loop,
                 control,
                 {:timer, wait_id},
                 [wait_id: wait_id, generation: generation],
                 Loops.operation_env(data)
               ),
             {:ok, next, _events} <-
               commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 causation_id: wait_id,
                 provenance: %{trigger: :timer},
                 transition: :operation_timer
               ) do
          next = next |> queue_operation(next_loop) |> maybe_schedule_operations()
          {:noreply, next}
        else
          {:error, _reason} -> {:noreply, data}
        end

      :stale ->
        {:noreply, data}
    end
  end

  @doc false
  @spec attempt_timeout(String.t(), String.t(), term(), InstanceState.t()) :: info_reply()
  def attempt_timeout(loop_id, attempt_id, fencing_token, %InstanceState{} = data) do
    case Timers.consume_attempt_timer(data, loop_id, attempt_id, fencing_token) do
      {:ok, ownership, next} ->
        _ = RunnerSupervisor.stop_runner(next.runner_supervisor, ownership.pid)
        next = finish_operation_runner(next, ownership)

        with {:ok, loop, control} <- Loops.operation_loop(next, loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id, fencing_token: ^fencing_token}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 :timeout,
                 Loops.operation_env(next, snapshot_id: ownership.snapshot_id)
               ),
             {:ok, committed, _events} <-
               commit_operational(next, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 causation_id: attempt_id,
                 provenance: %{source: :attempt_watchdog, attempt_id: attempt_id},
                 transition: :operation_timeout
               ) do
          committed =
            committed
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)
            |> maybe_schedule_operations()

          {:noreply, committed}
        else
          _stale_or_invalid -> {:noreply, maybe_schedule_operations(next)}
        end

      :stale ->
        {:noreply, data}
    end
  end

  @doc false
  @spec memory_result(String.t(), String.t(), term(), InstanceState.t()) :: info_reply()
  def memory_result(loop_id, result_id, outcome, %InstanceState{} = data) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         true <- operation_result_committed?(data, loop, result_id),
         event_type <- if(outcome == :ok, do: :memory_committed, else: :memory_commit_failed),
         {:ok, next, _events} <-
           commit_operational(
             data,
             loop,
             control,
             [
               %{
                 type: event_type,
                 payload: %{result_id: result_id, status: memory_status(outcome)}
               }
             ],
             correlation_id: loop.correlation_id,
             causation_id: result_id,
             provenance: %{source: :operation_memory},
             transition: :operation_memory
           ) do
      {:noreply, Idle.arm(next)}
    else
      _stale -> {:noreply, Idle.arm(data)}
    end
  end

  @doc false
  @spec runner_down(InstanceState.t(), pid(), reference(), String.t(), term()) ::
          InstanceState.t()
  def runner_down(%InstanceState{} = data, pid, monitor, attempt_id, reason),
    do: operation_runner_down(data, pid, monitor, attempt_id, reason)

  @doc false
  @spec schedule(InstanceState.t()) :: InstanceState.t()
  def schedule(%InstanceState{} = data), do: maybe_schedule_operations(data)

  @doc false
  @spec recover(InstanceState.t()) :: {:ok, InstanceState.t()} | {:error, term()}
  def recover(%InstanceState{} = data), do: recover_operational_state(data)

  defp control_loop(server, loop, action, payload, opts) do
    GenServer.call(
      server,
      {:operation_control, Loops.operation_id(loop), action, payload, opts},
      Configuration.timeout(opts)
    )
  end

  defp commit_operational(data, loop, control, event_specs, opts) do
    with {:ok, next, events} <- Commit.operational(data, loop, control, event_specs, opts) do
      {:ok, route_committed_events(next, events), events}
    end
  end

  defp commit_operational_batch(data, entries, commit_opts) do
    with {:ok, next, events} <- Commit.operational_batch(data, entries, commit_opts) do
      {:ok, route_committed_events(next, events), events}
    end
  end

  defp route_committed_events(data, []), do: data

  defp route_committed_events(data, events) do
    configured = Keyword.get(data.agent.__spectre_config__(), :route_operation_events, false)

    Enum.each(events, &Spectre.Operation.Events.publish(data.ref, &1))

    events
    |> Enum.filter(&route_operation_event?(&1, configured))
    |> Enum.reduce(data, &enqueue_operation_event/2)
    |> RunQueue.schedule()
  end

  defp route_operation_event?(_event, false), do: false
  defp route_operation_event?(_event, :all), do: true
  defp route_operation_event?(event, types) when is_list(types), do: event.type in types
  defp route_operation_event?(_event, _invalid), do: false

  defp enqueue_operation_event(event, data) do
    data = Runs.prune_for_new_run(data)

    if map_size(data.runs) >= data.max_runs do
      drop_operation_event(data, event)
    else
      admit_operation_event(data, event)
    end
  end

  defp drop_operation_event(data, event) do
    emit(
      :operation_event_route_dropped,
      data,
      %{count: 1},
      %{event_id: id_digest(event.id)}
    )

    data
  end

  defp admit_operation_event(data, event) do
    input = OperationEvent.to_input(event)
    opts = operation_event_run_opts(event)
    runtime_opts = RuntimeOptions.build(data, opts, input)

    case Runtime.admit(data.agent, input, data.state, runtime_opts, opts) do
      {:ok, %Run{} = run} -> enqueue_admitted_operation_event(data, run, input, opts)
      {:error, reason} -> reject_operation_event(data, event, reason)
    end
  end

  defp operation_event_run_opts(event) do
    [
      run_id: Value.token("operation-event-run", event.id),
      trace_id: event.correlation_id,
      correlation_id: event.correlation_id,
      causation_id: event.id,
      run_metadata: %{
        internal_event: true,
        operation_event_id: event.id,
        operation_loop_id: event.loop_id,
        operation_loop_kind: event.loop_kind
      }
    ]
  end

  defp enqueue_admitted_operation_event(data, run, input, opts) do
    if known_run?(data, run.id) do
      data
    else
      entry = operation_event_run_entry(data, run, input, opts)
      retained = %{data | runs: Map.put(data.runs, run.id, run)}

      case Commit.run_state(retained, data.state, run) do
        {:ok, committed} -> RunQueue.enqueue(committed, entry)
        {:error, _reason} -> data
      end
    end
  end

  defp known_run?(data, run_id),
    do: Map.has_key?(data.runs, run_id) or Map.has_key?(data.tombstones, run_id)

  defp operation_event_run_entry(data, run, input, opts) do
    %{
      run_id: run.id,
      operation: {:start, input},
      projection: :result,
      input: input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: true,
      admitted?: true
    }
  end

  defp reject_operation_event(data, event, reason) do
    emit(
      :operation_event_route_rejected,
      data,
      %{count: 1},
      %{event_id: id_digest(event.id), reason_class: reason_class(reason)}
    )

    data
  end

  @doc false
  @spec commit_delivery_receipt(InstanceState.t(), OperationLoop.t(), term(), keyword()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def commit_delivery_receipt(data, loop, receipt, opts) do
    with {:ok, next, events} <- Deliveries.commit_receipt(data, loop, receipt, opts) do
      {:ok, route_committed_events(next, events)}
    end
  end

  defp nested_work?(data, callers, :work) do
    Enum.any?(data.operation_runners, fn {_attempt_id, ownership} ->
      ownership.pid in callers
    end)
  end

  defp nested_work?(_data, _caller, _kind), do: false

  defp operation_callers do
    [self() | List.wrap(Process.get(:"$callers"))]
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp queue_operation(data, %OperationLoop{} = loop) do
    key = {loop.kind, loop.id}

    if MapSet.member?(data.operation_queued, key) do
      data
    else
      %{
        data
        | operation_ready: :queue.in(key, data.operation_ready),
          operation_queued: MapSet.put(data.operation_queued, key)
      }
    end
  end

  defp pop_operation(data) do
    case :queue.out(data.operation_ready) do
      {{:value, key}, ready} ->
        {:ok, key,
         %{
           data
           | operation_ready: ready,
             operation_queued: MapSet.delete(data.operation_queued, key)
         }}

      {:empty, _ready} ->
        {:empty, data}
    end
  end

  defp maybe_schedule_operations(data) do
    capacity? = map_size(data.operation_runners) < data.max_operation_runners

    next =
      if not data.operation_scheduled and not :queue.is_empty(data.operation_ready) and capacity? do
        send(self(), {:spectre, :operation_schedule})
        %{data | operation_scheduled: true}
      else
        data
      end

    Idle.arm(next)
  end

  defp maybe_queue_after_transition(data, loop, control) do
    cond do
      OperationLoop.terminal?(loop) ->
        data

      not is_nil(control.pending) and OperationLoop.quiescent?(loop) ->
        queue_operation(data, loop)

      OperationLoop.runnable?(loop) and control.state == :active ->
        queue_operation(data, loop)

      true ->
        data
    end
  end

  defp advance_operation(data, {_kind, loop_id}) do
    case Loops.operation_loop(data, loop_id) do
      {:ok, loop, control} ->
        apply_operation_action(operation_action(loop, control), data, loop, control)

      {:error, _reason} ->
        data
    end
  end

  defp operation_action(loop, control) do
    cond do
      not is_nil(control.pending) and OperationLoop.quiescent?(loop) -> :control
      loop.status == :evaluating -> :evaluate
      OperationLoop.runnable?(loop) and control.state == :active -> :prepare
      loop.status == :waiting -> :wait
      true -> :idle
    end
  end

  defp apply_operation_action(:control, data, loop, control),
    do: advance_operation_control(data, loop, control)

  defp apply_operation_action(:evaluate, data, loop, control),
    do: evaluate_operation(data, loop, control)

  defp apply_operation_action(:prepare, data, loop, control),
    do: prepare_operation(data, loop, control)

  defp apply_operation_action(:wait, data, loop, _control),
    do: Timers.maybe_schedule_wait_timer(data, loop)

  defp apply_operation_action(:idle, data, _loop, _control), do: data

  defp advance_operation_control(data, loop, control) do
    command = control.pending

    with {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.advance_control(loop, control, Loops.operation_env(data)),
         {:ok, next, committed_events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: command.correlation_id,
             causation_id: command.causation_id,
             provenance: command.provenance,
             transition: {:control_advanced, command.action}
           ) do
      next
      |> maybe_emit_uncorrelated_operation_trigger(committed_events)
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
    else
      {:error, reason} ->
        emit(
          :operation_control_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp evaluate_operation(data, loop, control) do
    with {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.evaluate(loop, control, Loops.operation_env(data)),
         {:ok, next, _events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: loop.correlation_id,
             causation_id: loop.last_result && loop.last_result.id,
             provenance: %{source: :completion_reducer},
             transition: :loop_evaluated
           ) do
      next
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
    else
      {:error, reason} ->
        emit(
          :operation_evaluation_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp prepare_operation(data, loop, control) do
    env = Loops.operation_snapshot_env(data, loop)

    case OperationRuntime.prepare(loop, control, env) do
      {:run, next_loop, attempt, spec, request, reconcile?, event_specs} ->
        case commit_operational(data, next_loop, control, event_specs,
               correlation_id: loop.correlation_id,
               causation_id: request.id,
               provenance: %{source: :operation_scheduler},
               transition: :attempt_committed
             ) do
          {:ok, committed, _events} ->
            committed
            |> Timers.maybe_schedule_wait_timer(next_loop)
            |> start_operation_runner(
              next_loop,
              control,
              attempt,
              spec,
              request,
              reconcile?
            )

          {:error, reason} ->
            emit(
              :operation_prepare_failed,
              data,
              %{count: 1},
              %{
                loop_id: id_digest(loop.id),
                reason_class: reason_class(reason)
              }
            )

            data
        end

      {:transition, next_loop, next_control, event_specs} ->
        case commit_operational(data, next_loop, next_control, event_specs,
               correlation_id: loop.correlation_id,
               provenance: %{source: :operation_scheduler},
               transition: :loop_boundary
             ) do
          {:ok, next, _events} ->
            next
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)

          {:error, _reason} ->
            data
        end

      {:error, reason} ->
        emit(
          :operation_prepare_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp start_operation_runner(data, loop, control, attempt, spec, request, reconcile?) do
    with :ok <- owner_guard(data, :effect_dispatch),
         {:ok, operation_definition_ref} <- Events.operation_definition_ref(data, loop),
         :ok <- Events.authorize(data, operation_definition_ref, :dispatch) do
      do_start_operation_runner(data, loop, control, attempt, spec, request, reconcile?)
    else
      {:error, reason} ->
        emit(
          :operation_dispatch_blocked,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp do_start_operation_runner(data, loop, control, attempt, spec, request, reconcile?) do
    runner_opts = [
      owner: self(),
      attempt: attempt,
      spec: spec,
      request: request,
      agent: data.agent,
      subject: data.subject,
      controller: loop.controller,
      input: loop.effective_input,
      agent_state: data.state,
      cognitive: loop.cognitive,
      reconcile?: reconcile?,
      defer_execute: true,
      opts: operation_runner_opts(data, loop, attempt),
      metadata: %{instance_ref: data.ref.key}
    ]

    case RunnerSupervisor.start_runner(data.runner_supervisor, runner_opts) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        ownership = %{
          attempt_id: attempt.id,
          loop_id: loop.id,
          loop_kind: loop.kind,
          operation: attempt.operation,
          snapshot_id: attempt.snapshot_id,
          fencing_token: attempt.fencing_token,
          pid: pid,
          monitor: monitor,
          control_generation: control.generation,
          context_revision: loop.context_revision,
          spec: spec
        }

        next =
          %{
            data
            | operation_runners: Map.put(data.operation_runners, attempt.id, ownership),
              operation_monitors: Map.put(data.operation_monitors, pid, attempt.id)
          }
          |> Timers.schedule_attempt_timeout(loop, attempt)
          |> Idle.disarm()

        :ok = Runner.execute(pid)
        next

      {:error, reason} ->
        handle_operation_start_failure(data, loop, control, spec, reason)
    end
  end

  defp handle_operation_start_failure(data, loop, control, spec, reason) do
    case OperationRuntime.runner_down(
           loop,
           control,
           spec,
           {:runner_start_failed, reason},
           Loops.operation_env(data)
         ) do
      {:ok, next_loop, next_control, event_specs} ->
        case commit_operational(data, next_loop, next_control, event_specs,
               correlation_id: loop.correlation_id,
               provenance: %{source: :runner_supervisor},
               transition: :runner_start_failed
             ) do
          {:ok, next, _events} ->
            next
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)

          {:error, _reason} ->
            data
        end

      {:error, _reason} ->
        data
    end
  end

  defp operation_runner_opts(data, loop, attempt) do
    data.base_opts
    |> Keyword.put(:instance_pid, self())
    |> Keyword.put(:operation_loop_id, loop.id)
    |> Keyword.put(:operation_loop_kind, loop.kind)
    |> Keyword.put(:operation_attempt_id, attempt.id)
    |> Keyword.put(:idempotency_key, attempt.idempotency_key)
    |> Keyword.put(:subject_id, data.subject.id)
  end

  defp operation_runner_down(data, pid, monitor, attempt_id, reason) do
    case Map.get(data.operation_runners, attempt_id) do
      %{pid: ^pid, monitor: ^monitor} = ownership ->
        data = drop_operation_runner(data, ownership)

        with {:ok, loop, control} <- Loops.operation_loop(data, ownership.loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 reason,
                 Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
               ),
             {:ok, next, _events} <-
               commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 provenance: %{source: :runner_monitor, attempt_id: attempt_id},
                 transition: :runner_down
               ) do
          next
          |> maybe_queue_after_transition(next_loop, next_control)
          |> Timers.maybe_schedule_wait_timer(next_loop)
          |> maybe_schedule_operations()
        else
          _stale_or_invalid -> maybe_schedule_operations(data)
        end

      _unknown ->
        data
    end
  end

  defp finish_operation_runner(data, ownership) do
    Process.demonitor(ownership.monitor, [:flush])
    drop_operation_runner(data, ownership)
  end

  defp reject_operation_result(data, ownership, result, reason) do
    data = finish_operation_runner(data, ownership)

    with {:ok, loop, control} <- Loops.operation_loop(data, result.loop_id),
         %OperationLoop{attempt: %{id: attempt_id}} when attempt_id == ownership.attempt_id <-
           loop,
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.runner_down(
             loop,
             control,
             ownership.spec,
             {:invalid_operation_result, reason},
             Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
           ),
         {:ok, next, _events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: loop.correlation_id,
             causation_id: result.id,
             provenance: %{source: :result_validator, attempt_id: ownership.attempt_id},
             transition: :operation_result_rejected
           ) do
      next
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
      |> maybe_schedule_operations()
    else
      _invalid -> maybe_schedule_operations(data)
    end
  end

  defp drop_operation_runner(data, ownership) do
    data = Timers.cancel_attempt_timer(data, ownership.attempt_id)

    %{
      data
      | operation_runners: Map.delete(data.operation_runners, ownership.attempt_id),
        operation_monitors: Map.delete(data.operation_monitors, ownership.pid),
        operation_progress_clock: Map.delete(data.operation_progress_clock, ownership.attempt_id),
        operation_liveness_clock: Map.delete(data.operation_liveness_clock, ownership.attempt_id)
    }
  end

  defp apply_runner_action(data, :keep_runner), do: data

  defp apply_runner_action(data, {:terminate_runner, attempt_id}) do
    case Map.get(data.operation_runners, attempt_id) do
      nil ->
        data

      ownership ->
        _ = RunnerSupervisor.stop_runner(data.runner_supervisor, ownership.pid)
        finish_operation_runner(data, ownership)
    end
  end

  defp normalize_operation_result({:ok, loop, control, events, start_loops}),
    do: {:ok, loop, control, events, start_loops}

  defp normalize_operation_result({:duplicate, loop}), do: {:duplicate, loop}
  defp normalize_operation_result({:error, _reason} = error), do: error

  defp materialize_start_loop_intents(_data, _parent, _result, []), do: {:ok, [], []}

  defp materialize_start_loop_intents(data, parent, result, intents) do
    reducer = fn intent, acc ->
      materialize_start_loop_intent_entry(data, parent, result, intent, acc)
    end

    Enum.reduce_while(intents, {:ok, [], []}, reducer)
    |> case do
      {:ok, started, already} -> {:ok, Enum.reverse(started), Enum.reverse(already)}
      {:error, _reason} = error -> error
    end
  end

  defp materialize_start_loop_intent_entry(data, parent, result, intent, acc) do
    case Keyword.fetch(intent.opts, :id) do
      {:ok, child_id} ->
        resolve_start_loop_intent(data, parent, result, intent, child_id, acc)

      :error ->
        {:halt, {:error, {:operation_start_loop_id_missing, intent.intent_id}}}
    end
  end

  defp resolve_start_loop_intent(data, parent, result, intent, child_id, acc) do
    case Loops.operation_loop(data, child_id) do
      {:ok, existing, _control} ->
        reuse_start_loop_intent(existing, parent, intent, child_id, acc)

      {:error, :operation_loop_not_found} ->
        create_start_loop_intent(data, parent, result, intent, acc)
    end
  end

  defp reuse_start_loop_intent(existing, parent, intent, child_id, {:ok, started, already}) do
    if started_by_same_intent?(existing, parent, intent) do
      entry = %{intent_id: intent.intent_id, loop: existing}
      {:cont, {:ok, started, [entry | already]}}
    else
      {:halt, {:error, {:duplicate_operational_loop, child_id}}}
    end
  end

  defp create_start_loop_intent(data, parent, result, intent, {:ok, started, already}) do
    case materialize_start_loop_intent(data, parent, result, intent) do
      {:ok, child} -> {:cont, {:ok, [child | started], already}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  # Start intents are idempotent: re-proposing an intent whose Work already
  # exists with the same parent and intent provenance is a committed no-op.
  # Only an id collision with different provenance rejects the transition.
  defp started_by_same_intent?(existing, parent, intent) do
    Map.get(existing.provenance, :parent_loop_id) == parent.id and
      Map.get(existing.provenance, :loop_start_intent_id) == intent.intent_id
  end

  defp materialize_start_loop_intent(data, parent, result, intent) do
    with {:ok, metadata} <- start_loop_intent_metadata(intent, parent) do
      provenance =
        parent.provenance
        |> Map.put(:source, :directive)
        |> Map.put(:parent_loop_id, parent.id)
        |> Map.put(:loop_start_intent_id, intent.intent_id)

      opts =
        intent.opts
        |> Keyword.put(:origin, parent.origin)
        |> Keyword.put(:provenance, provenance)
        |> Keyword.put(:turn_id, parent.source_turn_id)
        |> Keyword.put(:authorized_origins, parent.authorized_origins)
        |> Keyword.put(:visibility, parent.visibility)
        |> Keyword.put(:destinations, parent.destinations)
        |> Keyword.put(:causation_id, result.id)
        |> Keyword.put(:metadata, metadata)

      case OperationRuntime.start(
             :work,
             intent.controller,
             intent.input,
             opts,
             Loops.operation_env(data)
           ) do
        {:ok, loop, control, event_specs} ->
          commit_opts = [
            correlation_id: loop.correlation_id,
            causation_id: result.id,
            provenance: provenance,
            transition: {:loop_started_by, parent.id}
          ]

          {:ok,
           %{
             intent_id: intent.intent_id,
             loop: loop,
             control: control,
             event_specs: event_specs,
             opts: commit_opts
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp start_loop_intent_metadata(intent, parent) do
    case Keyword.get(intent.opts, :metadata, %{}) do
      metadata when is_map(metadata) ->
        {:ok,
         metadata
         |> Map.put(:parent_loop_id, parent.id)
         |> Map.put(:parent_loop_kind, parent.kind)
         |> Map.put(:loop_start_intent_id, intent.intent_id)}

      _invalid ->
        {:error, :invalid_operation_start_loop_metadata}
    end
  end

  defp commit_operation_result_with_started_loops(
         data,
         parent,
         parent_control,
         event_specs,
         result,
         started_loops,
         already_started
       ) do
    parent_events =
      case {started_loops, already_started} do
        {[], []} ->
          event_specs

        {started, already} ->
          event_specs ++
            [
              %{
                type: :loops_started,
                payload: %{
                  loops:
                    Enum.map(started, &start_loop_event_entry(&1, false)) ++
                      Enum.map(already, &start_loop_event_entry(&1, true))
                }
              }
            ]
      end

    parent_opts = [
      correlation_id: parent.correlation_id,
      causation_id: result.id,
      provenance: %{runner_attempt: result.attempt_id},
      transition: :operation_result
    ]

    parent_entry = %{
      loop: parent,
      control: parent_control,
      event_specs: parent_events,
      opts: parent_opts
    }

    child_entries =
      Enum.map(started_loops, fn child ->
        Map.take(child, [:loop, :control, :event_specs, :opts])
      end)

    commit_operational_batch(data, [parent_entry | child_entries], parent_opts)
  end

  defp start_loop_event_entry(child, already_started?) do
    %{
      intent_id: child.intent_id,
      id: child.loop.id,
      kind: child.loop.kind,
      already_started: already_started?
    }
  end

  defp queue_started_loops(data, started_loops) do
    Enum.reduce(started_loops, data, fn child, acc ->
      acc
      |> queue_operation(child.loop)
      |> Timers.maybe_schedule_wait_timer(child.loop)
    end)
  end

  defp accept_operation_progress(data, progress) do
    ownership = Map.get(data.operation_runners, progress.attempt_id)
    now = System.monotonic_time(:millisecond)
    minimum = Keyword.get(data.base_opts, :operation_progress_commit_interval, 500)
    previous_commit = Map.get(data.operation_progress_clock, progress.attempt_id)
    previous_liveness = Map.get(data.operation_liveness_clock, progress.attempt_id)

    with :ok <- OperationProgress.validate(progress),
         %{
           loop_id: loop_id,
           fencing_token: token,
           control_generation: control_generation,
           context_revision: context_revision
         } <- ownership,
         true <- loop_id == progress.loop_id and token == progress.fencing_token,
         true <- ownership.spec.id == ownership.operation,
         {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         %{id: attempt_id, epoch: epoch} <- loop.attempt,
         true <- attempt_id == progress.attempt_id and epoch == progress.epoch,
         true <- progress.context_revision == context_revision,
         true <- progress.context_revision == loop.context_revision,
         true <- progress.control_generation == control_generation,
         true <- progress.control_generation == control.generation,
         true <- progress.trigger_generation == loop.trigger_generation,
         true <- progress.sequence > loop.progress_sequence,
         true <-
           is_nil(previous_liveness) or progress.sequence > previous_liveness.sequence do
      next = %{
        data
        | operation_liveness_clock:
            Map.put(data.operation_liveness_clock, progress.attempt_id, %{
              at: now,
              sequence: progress.sequence
            })
      }

      if is_nil(previous_commit) or now - previous_commit >= minimum do
        committed_clock =
          Map.put(next.operation_progress_clock, progress.attempt_id, now)

        {:ok, loop, control, %{next | operation_progress_clock: committed_clock}}
      else
        {:throttled, next}
      end
    else
      _invalid_or_throttled -> :drop
    end
  end

  defp maybe_remember_operation_result(data, _loop, %OperationResult{status: status}, _spec)
       when status != :ok,
       do: data

  defp maybe_remember_operation_result(data, _loop, _result, %{remember: false}), do: data

  defp maybe_remember_operation_result(data, loop, result, spec) do
    policy = if spec.remember == true, do: %{}, else: spec.remember
    include = Map.get(policy, :include, Map.get(policy, "include", [:value, :artifacts]))

    payload =
      %{
        loop_id: loop.id,
        loop_kind: loop.kind,
        definition: loop.controller_id,
        definition_version: loop.controller_version,
        subject_id: loop.subject_id,
        result_id: result.id,
        operation: result.operation,
        committed_revision: data.canonical.revision,
        provenance: loop.provenance
      }
      |> maybe_put_memory_field(:value, result.value, include)
      |> maybe_put_memory_field(:artifacts, result.artifacts, include)
      |> maybe_put_memory_field(:receipt, result.receipt, include)

    owner = self()
    agent = data.agent

    memory_opts =
      data.base_opts
      |> Keyword.put(:idempotency_key, result.id)
      |> Keyword.put(:operation_loop_id, loop.id)
      |> Keyword.put(:operation_result_id, result.id)

    callback = fn ->
      outcome = Memory.persist(agent, payload, memory_opts)
      send(owner, {:spectre, :operation_memory_result, loop.id, result.id, outcome})
    end

    case Task.Supervisor.start_child(Spectre.Operation.TaskSupervisor, callback) do
      {:ok, _pid} ->
        Idle.disarm(data)

      {:error, reason} ->
        send(
          self(),
          {:spectre, :operation_memory_result, loop.id, result.id,
           {:error, {:memory_task_start_failed, reason}}}
        )

        Idle.disarm(data)
    end
  end

  defp maybe_put_memory_field(payload, key, value, include) do
    if key in List.wrap(include), do: Map.put(payload, key, value), else: payload
  end

  defp operation_result_committed?(data, loop, result_id) do
    match?(%OperationResult{id: ^result_id}, loop.last_result) or
      Enum.any?(Map.get(Loops.canonical_value!(data, :events), :records, []), fn event ->
        event.loop_id == loop.id and event.causation_id == result_id
      end)
  end

  defp memory_status(:ok), do: :committed
  defp memory_status({:error, _reason}), do: :failed
  defp memory_status(_outcome), do: :failed

  defp recover_operational_state(data) do
    reducer = fn {loop, control}, {:ok, acc} -> recover_operational_loop(acc, loop, control) end
    Enum.reduce_while(Loops.all_operation_loops(data), {:ok, data}, reducer)
  end

  defp recover_operational_loop(data, loop, control) do
    case OperationRuntime.recover(loop, control, Loops.operation_env(data)) do
      {:ok, ^loop, ^control, []} ->
        {:cont, {:ok, maybe_queue_after_transition(data, loop, control)}}

      {:ok, next_loop, next_control, event_specs} ->
        commit_recovered_operation(data, loop, next_loop, next_control, event_specs)

      {:error, reason} ->
        {:halt, {:error, {:operational_recovery_failed, loop.id, reason}}}
    end
  end

  defp commit_recovered_operation(data, previous, loop, control, event_specs) do
    result =
      commit_operational(data, loop, control, event_specs,
        correlation_id: previous.correlation_id,
        provenance: %{source: :agent_restart},
        transition: :loop_recovered
      )

    case result do
      {:ok, next, _events} ->
        {:cont, {:ok, maybe_queue_after_transition(next, loop, control)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

  defp emit(event, data, measurements, metadata \\ %{}),
    do: InstanceTelemetry.emit(event, data, measurements, metadata)

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)
  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)

  defp maybe_emit_uncorrelated_operation_trigger(data, events) do
    if Enum.any?(events, fn event ->
         event.type == :triggered and is_map(event.payload) and
           Map.get(event.payload, :correlation) == :legacy
       end) do
      emit(:uncorrelated_operation_trigger, data, %{count: 1})
    end

    data
  end
end
