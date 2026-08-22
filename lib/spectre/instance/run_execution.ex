defmodule Spectre.Instance.RunExecution do
  @moduledoc false

  # Owns the process-local execution of retained Runs. It starts and monitors
  # move workers, validates returned state revisions, commits Run projections,
  # and completes callers. Every function executes synchronously in the
  # Instance owner process; worker messages still cross the original mailbox
  # and are fenced by dispatch id plus an unforgeable capability.

  alias Spectre.Instance.DefinitionCompatibility
  alias Spectre.Effect
  alias Spectre.Inference.Failure, as: InferenceFailure
  alias Spectre.Inference.Prepared, as: PreparedInference
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Conversation
  alias Spectre.Instance.Events
  alias Spectre.Instance.Idle
  alias Spectre.Instance.InferenceCoordinator
  alias Spectre.Instance.Owner
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt, as: Receipt
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Value
  alias Spectre.Runtime
  alias Spectre.State
  alias Spectre.Turn

  @doc false
  @spec advance_result(InstanceState.t(), map(), term()) :: InstanceState.t()
  def advance_result(data, active, outcome) do
    with %Run{} = current <- Map.get(data.runs, active.run_id),
         :ok <- Runs.validate_move_outcome(outcome, current, active.entry) do
      data = finish_worker(data, active.pid)
      data = %{data | active: nil}

      apply_advance_outcome(data, current, outcome, active.entry)
    else
      nil ->
        data

      {:error, _reason} ->
        emit(:invalid_move_result, data, %{count: 1}, %{run_id: id_digest(active.run_id)})
        data
    end
  end

  defp apply_advance_outcome(data, current, outcome, entry) do
    if policy_resolution_entry?(entry) do
      apply_policy_outcome(data, current, outcome, entry)
    else
      apply_step(outcome, entry, data)
    end
  end

  defp apply_policy_outcome(data, current, outcome, entry) do
    if rejected_policy_outcome?(outcome, current),
      do: reject_policy_decision(data, outcome),
      else: commit_policy_decision(data, outcome, entry)
  end

  @doc false
  @spec dispatch(Run.t(), term(), keyword(), atom(), GenServer.from(), InstanceState.t()) ::
          {:reply, term(), InstanceState.t()} | {:noreply, InstanceState.t()}
  def dispatch(run, command, opts, projection, from, data) do
    with :ok <- owner_guard(data, :effect_dispatch),
         :ok <- Events.authorize(data, run.definition_ref, :dispatch),
         %Invocation{} = invocation <- run.waiting,
         false <- RunQueue.active?(data, run.id),
         nil <- other_active_run(data, run.id),
         nil <- data.state_lock do
      run = Runs.rebase_run(run, data.state)
      data = Runs.put_run(data, run)
      runtime_opts = RuntimeOptions.build(data, opts, run.input)
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
        invocation: invocation,
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
        |> RunQueue.put_caller(run.id, from)
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
        |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
        |> Map.put(:workers, Map.put(data.workers, pid, worker))
        |> Idle.disarm()

      emit(
        :invocation_dispatched,
        next,
        %{count: 1},
        %{
          run_id: id_digest(run.id),
          invocation_id: id_digest(invocation.id)
        }
      )

      {:noreply, next}
    else
      nil ->
        {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, Idle.arm(data)}

      %Boundary{} ->
        {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, Idle.arm(data)}

      true ->
        {:reply, {:error, {:run_already_active, run.id}}, Idle.arm(data)}

      {:instance_busy, active_run_id} ->
        {:reply, {:error, {:instance_busy, active_run_id}}, Idle.arm(data)}

      %{} ->
        {:reply, {:error, :instance_state_locked}, Idle.arm(data)}

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp other_active_run(%{active: nil}, _run_id), do: nil
  defp other_active_run(%{active: %{run_id: run_id}}, run_id), do: nil

  defp other_active_run(%{active: active}, _run_id),
    do: {:instance_busy, Map.get(active, :run_id)}

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
      run_invocation_worker(
        owner,
        run,
        invocation,
        command,
        runtime_opts,
        generation,
        dispatch_id,
        capability
      )
    end)
  end

  defp run_invocation_worker(
         owner,
         run,
         invocation,
         command,
         runtime_opts,
         generation,
         dispatch_id,
         capability
       ) do
    callback = fn -> resume_run(run, command, runtime_opts) end
    {outcome, samples} = Spectre.Determinism.capture(runtime_opts, callback)

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: run.id,
      run_revision: run.revision,
      generation: generation,
      dispatch_id: dispatch_id,
      capability: capability,
      kind: :effect,
      provider_started: true,
      outcome: outcome,
      metadata: %{remote_status: :confirmed, nondeterminism_samples: samples}
    }

    send(owner, {:spectre, :invocation_result, invocation.id, receipt})
  end

  defp resume_run(run, command, runtime_opts) do
    safe_step(run, fn -> Runtime.resume(run, command, runtime_opts) end)
  end

  @doc false
  @spec start(InstanceState.t(), map()) :: InstanceState.t()
  def start(data, entry) do
    run = Map.fetch!(data.runs, entry.run_id)

    # `submit_owned/5` already admitted a new Run against the then-active
    # Definition before persisting it. From this point the queued Run is a
    # pinned continuation: activation may move, while authority/revocation is
    # still re-checked at dispatch time.
    with :ok <-
           DefinitionCompatibility.verify_pinned_run(
             run,
             data.definition_store,
             data.checkpoint_store,
             data.base_opts
           ),
         :ok <- Events.authorize(data, run.definition_ref, :continuation) do
      do_start_advance_worker(data, entry, run)
    else
      {:error, reason} -> fail(data, run, reason)
    end
  end

  defp do_start_advance_worker(data, entry, run) do
    # Internal inference Runs are state-neutral and must not claim an unowned
    # Effect from the parent conversational lifecycle. Ordinary turns retain
    # the existing claim-before-execute behavior.
    state =
      if entry_commits_state?(entry),
        do: State.claim_run_lifecycle(data.state, run.id),
        else: data.state

    run = Runs.rebase_run(run, state)
    data = %{data | state: state}

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
    |> Idle.disarm()
  end

  defp prepare_entry(%{operation: {:start, input}} = entry, run, data) do
    opts =
      data
      |> RuntimeOptions.build(entry.opts, input)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)
      |> RuntimeOptions.pin_run(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(%{operation: :advance} = entry, run, data) do
    opts =
      entry.opts
      |> Keyword.put(:state, data.state)
      |> RuntimeOptions.pin_run(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(entry, run, data) do
    opts =
      entry.opts
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)
      |> RuntimeOptions.pin_run(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  @doc false
  def spawn_advance_worker(owner, run, entry, dispatch_id, capability) do
    spawn_worker(fn -> run_advance_worker(owner, run, entry, dispatch_id, capability) end)
  end

  defp run_advance_worker(owner, run, entry, dispatch_id, capability) do
    callback = fn -> safe_run_operation(run, entry) end
    {outcome, samples} = Spectre.Determinism.capture(entry.opts, callback)

    send(
      owner,
      {:spectre, :advance_result, run.id, dispatch_id, capability, outcome, samples}
    )
  end

  defp safe_run_operation(run, entry), do: safe_step(run, fn -> run_operation(run, entry) end)

  defp run_operation(run, %{operation: :advance, opts: opts}),
    do: Runtime.advance(run, opts)

  defp run_operation(
         run,
         %{operation: {:inference, %InferenceRequest{} = request}, opts: opts}
       ),
       do: Runtime.prepare_inference(run, request, opts)

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

        case apply_returned_run(data, run, entry) do
          {:ok, data} ->
            finish_committed_error_step(data, run, reason, entry, current)

          {:error, commit_reason} ->
            fail(data, run, commit_reason)
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
      case apply_returned_run(data, run, entry) do
        {:ok, data} ->
          finish_committed_continue_step(data, run, entry)

        {:error, reason} ->
          fail(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(
         {:dispatch, %Invocation{kind: :inference} = invocation, %Run{} = run,
          %PreparedInference{} = prepared},
         entry,
         data
       ) do
    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      InferenceCoordinator.commit_selection(data, invocation, run, prepared, entry)
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(step, entry, data) do
    run = Runs.step_run(step)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      case apply_returned_run(data, run, entry) do
        {:ok, data} ->
          finish_committed_successful_step(data, step, entry)

        {:error, reason} ->
          fail(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  # Receipt-gated boundaries commit their returned Run before delivery. These
  # helpers perform only the post-commit work, so acknowledging a receipt can
  # never apply the same state transition twice.
  @doc false
  def finish_committed_step(
        data,
        {:error, reason, %Run{} = run},
        entry,
        previous
      ) do
    finish_committed_error_step(data, run, reason, entry, previous)
  end

  def finish_committed_step(data, {:continue, %Run{} = run}, entry, _previous),
    do: finish_committed_continue_step(data, run, entry)

  def finish_committed_step(
        data,
        {:dispatch, %Invocation{kind: :inference}, %Run{}, %PreparedInference{}} = step,
        entry,
        _previous
      ) do
    # The effect or policy boundary is already durable, while inference
    # selection is a distinct nondeterministic boundary with its own receipt.
    apply_successful_step(step, %{entry | state_revision: data.state.revision}, data)
  end

  def finish_committed_step(data, step, entry, _previous),
    do: finish_committed_successful_step(data, step, entry)

  defp finish_committed_error_step(data, run, reason, entry, current) do
    cond do
      Runs.terminal_run?(run) ->
        data
        |> RunQueue.reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_failed, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> Runs.record_terminal(run)
        |> RunQueue.schedule()
        |> Idle.arm()

      start_operation?(entry) ->
        failed = Runs.terminalize_failed_run(run, reason)

        data
        |> Runs.put_run(failed)
        |> RunQueue.reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_failed, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> Runs.record_terminal(failed)
        |> RunQueue.schedule()
        |> Idle.arm()

      advanced_run?(current, run) ->
        degraded = %{run | last_error: reason}

        data
        |> Runs.put_run(degraded)
        |> RunQueue.reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_move_degraded, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> maybe_finalize_degraded_run(degraded)
        |> RunQueue.schedule()
        |> Idle.arm()

      true ->
        data
        |> RunQueue.reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_resume_rejected, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> RunQueue.schedule()
        |> Idle.arm()
    end
  end

  defp finish_committed_continue_step(data, run, entry) do
    data = record_started_conversation(data, entry, run)

    continuation = %{
      entry
      | operation: :advance,
        input: run.input,
        state_revision: data.state.revision
    }

    data
    |> RunQueue.enqueue_continuation(continuation, start_operation?(entry))
    |> Idle.arm()
  end

  defp finish_committed_successful_step(data, step, entry) do
    run = Runs.step_run(step)
    data = reply_projection(data, entry, step)
    data = maybe_finalize_reply(data, step)
    data = if Runs.terminal_run?(run), do: Runs.record_terminal(data, run), else: data

    data
    |> RunQueue.schedule()
    |> Idle.arm()
  end

  defp policy_resolution_entry?(%{operation: {:resume, {:policy, _ref, _resolution}}}),
    do: true

  defp policy_resolution_entry?(%{
         operation: {:resume, {:policy, _ref, _awaitable_id, _resolution}}
       }),
       do: true

  defp policy_resolution_entry?(_entry), do: false

  @spec rejected_policy_outcome?(term(), Run.t()) :: boolean()
  defp rejected_policy_outcome?({:error, _reason, %Run{} = returned}, %Run{} = current),
    do: returned == current

  defp rejected_policy_outcome?(_outcome, _current), do: false

  @spec reject_policy_decision(InstanceState.t(), term()) :: InstanceState.t()
  defp reject_policy_decision(data, {:error, reason, %Run{} = run}) do
    data
    |> RunQueue.reply_caller(run.id, {:error, reason})
    |> tap(
      &emit(:run_resume_rejected, &1, %{count: 1}, %{
        run_id: id_digest(run.id),
        reason_class: reason_class(reason)
      })
    )
    |> RunQueue.schedule()
    |> Idle.arm()
  end

  defp commit_policy_decision(data, outcome, entry) do
    {boundary_ref, resolution} = policy_resolution_command(entry.operation)

    outcome =
      map_returned_step_run(outcome, fn run ->
        marker = %{
          boundary_id: boundary_ref.boundary_id,
          decision: portable_value(resolution)
        }

        %{run | metadata: Map.put(run.metadata, :policy_decision, marker)}
      end)

    payload = %{
      boundary_id: boundary_ref.boundary_id,
      decision: portable_value(resolution),
      outcome: step_outcome(outcome),
      nondeterminism_samples: Map.get(entry, :nondeterminism_samples, [])
    }

    commit_receipted_step(
      data,
      outcome,
      entry,
      :policy_decision,
      payload,
      causation_id: boundary_ref.boundary_id,
      payload_schema_ref: "spectre.policy.decision/1",
      privacy: :confidential
    )
  end

  @spec policy_resolution_command(term()) :: {Spectre.Run.Ref.t(), term()}
  defp policy_resolution_command({:resume, {:policy, boundary_ref, resolution}}),
    do: {boundary_ref, resolution}

  defp policy_resolution_command({:resume, {:policy, boundary_ref, _awaitable_id, resolution}}),
    do: {boundary_ref, resolution}

  @doc false
  @spec commit_effect_terminal(InstanceState.t(), map(), Receipt.t()) :: InstanceState.t()
  def commit_effect_terminal(data, ownership, %Receipt{} = receipt) do
    invocation = Map.fetch!(ownership, :invocation)

    kind =
      if elem(invocation.operation, 0) == :action, do: :action_terminal, else: :effect_terminal

    outcome =
      map_returned_step_run(receipt.outcome, fn run ->
        marker = %{
          invocation_id: invocation.id,
          effect_id: invocation.subject_id,
          kind: kind,
          idempotency_key: invocation.idempotency_key
        }

        %{run | metadata: Map.put(run.metadata, :effect_terminal, marker)}
      end)

    receipt = %{receipt | outcome: outcome}
    effect = terminal_effect(outcome, invocation.subject_id)

    payload = %{
      effect: effect_receipt_projection(effect, invocation),
      idempotency_key: invocation.idempotency_key,
      operation: invocation.operation,
      outcome: step_outcome(receipt.outcome),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :confirmed),
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }

    commit_receipted_step(
      data,
      receipt.outcome,
      ownership.entry,
      kind,
      payload,
      invocation_id: invocation.id,
      causation_id: invocation.id,
      payload_schema_ref:
        if(kind == :action_terminal,
          do: "spectre.action.terminal/1",
          else: "spectre.effect.terminal/1"
        ),
      privacy: :confidential
    )
  end

  defp commit_receipted_step(data, outcome, entry, kind, payload, receipt_opts) do
    run = returned_step_run(outcome)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      previous = Map.get(data.runs, run.id)

      with :ok <- owner_guard(data, :commit),
           projected <- project(data, run, entry),
           {:ok, prepared} <-
             Receipts.prepare_run(
               data,
               projected.state,
               run,
               kind,
               payload,
               receipt_opts
             ) do
        ReceiptCoordinator.commit_run(
          projected,
          run,
          {:committed_step, outcome, entry, previous},
          prepared
        )
      else
        {:error, reason} -> fail(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp returned_step_run({:continue, %Run{} = run}), do: run
  defp returned_step_run({:error, _reason, %Run{} = run}), do: run
  defp returned_step_run(step), do: Runs.step_run(step)

  defp map_returned_step_run({:continue, %Run{} = run}, mapper),
    do: {:continue, mapper.(run)}

  defp map_returned_step_run({:await, invocation, %Run{} = run}, mapper),
    do: {:await, invocation, mapper.(run)}

  defp map_returned_step_run({:dispatch, invocation, %Run{} = run, prepared}, mapper),
    do: {:dispatch, invocation, mapper.(run), prepared}

  defp map_returned_step_run({:boundary, boundary, %Run{} = run}, mapper),
    do: {:boundary, boundary, mapper.(run)}

  defp map_returned_step_run({:complete, result, %Run{} = run}, mapper),
    do: {:complete, result, mapper.(run)}

  defp map_returned_step_run({:error, reason, %Run{} = run}, mapper),
    do: {:error, reason, mapper.(run)}

  defp step_outcome({:continue, %Run{}}), do: :continue
  defp step_outcome({:await, %Invocation{}, %Run{}}), do: :await
  defp step_outcome({:dispatch, %Invocation{}, %Run{}, %PreparedInference{}}), do: :dispatch
  defp step_outcome({:boundary, %Boundary{}, %Run{}}), do: :boundary
  defp step_outcome({:complete, %Result{}, %Run{}}), do: :complete

  defp step_outcome({:error, reason, %Run{}}),
    do: %{status: :error, reason: portable_failure(reason)}

  defp terminal_effect(outcome, effect_id) do
    run = returned_step_run(outcome)

    case run.result do
      %Result{effects: effects} ->
        Enum.find(Enum.reverse(effects), &(&1.id == effect_id and Effect.terminal?(&1))) ||
          State.resolved_effect(run.state, effect_id)

      _missing_result ->
        State.resolved_effect(run.state, effect_id)
    end
  end

  defp effect_receipt_projection(%Effect{} = effect, _invocation) do
    %{
      id: effect.id,
      kind: effect.kind,
      name: effect.name,
      status: effect.status,
      via: Effect.via(effect),
      schema_hash: Effect.schema_hash(effect),
      result: portable_value(effect.result),
      error: portable_value(effect.error),
      evidence: Effect.result_evidence(effect)
    }
  end

  defp effect_receipt_projection(nil, invocation) do
    %{
      id: invocation.subject_id,
      kind: elem(invocation.operation, 0),
      name: elem(invocation.operation, 1),
      status: :unresolved
    }
  end

  defp portable_value(value) do
    case Value.validate(value) do
      :ok -> value
      {:error, _reason} -> %{class: reason_class(value)}
    end
  end

  # The dispatch intent is a separate durable state from selection. Recovery
  # may safely dispatch `:selected`, while `:dispatching` is treated as an
  # uncertain external call unless the adapter can reconcile it.

  defp reject_stale_step(data, entry, run) do
    reason =
      {:stale_instance_state, run.id, entry.state_revision, data.state.revision}

    failed = Runs.terminalize_failed_run(run, reason)
    data = data |> Runs.put_run(failed) |> RunQueue.reply_caller(run.id, {:error, reason})
    data |> Runs.record_terminal(failed) |> RunQueue.schedule() |> Idle.arm()
  end

  @doc false
  def record_started_conversation(
        data,
        %{operation: {:start, _input}, opts: opts},
        run
      ),
      do: Conversation.record_conversation(data, run, opts)

  def record_started_conversation(
        data,
        %{admitted?: true, opts: opts},
        run
      ),
      do: Conversation.record_conversation(data, run, opts)

  def record_started_conversation(data, _entry, _run), do: data

  defp apply_returned_run(data, %Run{} = run, entry) do
    with :ok <- owner_guard(data, :commit) do
      next = project(data, run, entry)
      Commit.flow_state(next, next.state, run)
    end
  end

  # Builds the in-memory projection used by both ordinary Run commits and
  # receipted inference boundaries. Keeping this calculation in one place
  # prevents the receipt path from observing a different Flow state.
  @doc false
  @spec project(InstanceState.t(), Run.t(), map()) :: InstanceState.t()
  def project(data, %Run{} = run, entry) do
    next_state =
      if entry_commits_state?(entry) and entry.state_revision == data.state.revision do
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

  @doc false
  @spec fail(InstanceState.t(), Run.t(), term()) :: InstanceState.t()
  def fail(data, %Run{} = run, reason) do
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, reason)

    data
    |> Runs.put_run(failed)
    |> RunQueue.reply_caller(run.id, {:error, reason})
    |> tap(
      &emit(:run_failed, &1, %{count: 1}, %{
        run_id: id_digest(run.id),
        reason_class: reason_class(reason)
      })
    )
    |> Runs.record_terminal(failed)
    |> RunQueue.schedule()
    |> Idle.arm()
  end

  defp reply_projection(data, %{projection: :inference_response} = entry, step) do
    reply =
      step
      |> Runs.step_result()
      |> cognitive_response()

    RunQueue.reply_caller(data, entry.run_id, reply)
  end

  defp reply_projection(data, %{internal?: true, run_id: run_id}, step) do
    # Recovery has no live GenServer caller, but a resumed stream session is
    # still waiting for the canonical Run result. Treat that session as the
    # terminal projection consumer so a successful recovered Run cannot leave
    # its replacement Enumerable parked in `:awaiting_result`.
    if RunQueue.stream_session(data, run_id) do
      RunQueue.reply_caller(data, run_id, {:ok, Runs.step_result(step)})
    else
      data
    end
  end

  defp reply_projection(data, entry, step) do
    reply =
      case entry.projection do
        :turn -> {:ok, Turn.from_step(self(), entry.input, entry.opts, step)}
        :result -> {:ok, Runs.step_result(step)}
        :stream -> stream_projection(data, entry.run_id, step)
      end

    RunQueue.reply_caller(data, entry.run_id, reply)
  end

  @doc false
  def cognitive_response(%Result{
        metadata: %{cognitive_inference: %{response: %InferenceResponse{} = response}}
      }),
      do: {:ok, response}

  def cognitive_response(%Result{}),
    do: {:error, :cognitive_inference_response_missing}

  def cognitive_response(nil),
    do: {:error, :cognitive_inference_result_missing}

  defp stream_projection(data, run_id, step) do
    if RunQueue.stream_session(data, run_id) do
      {:ok, Runs.step_result(step)}
    else
      {:error, {:streaming_unsupported, :handler_did_not_start_inference}}
    end
  end

  defp maybe_finalize_reply(data, {:boundary, %Boundary{kind: :reply}, %Run{} = run}) do
    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: RuntimeOptions.build(data, [], run.input),
      state_revision: data.state.revision,
      internal?: true
    }

    RunQueue.enqueue(data, entry)
  end

  defp maybe_finalize_reply(data, _step), do: data

  @doc false
  def worker_down(
        data,
        pid,
        %{invocation_kind: :inference} = ownership,
        reason
      ) do
    data = finish_worker(data, pid)

    receipt = %Receipt{
      invocation_id: ownership.invocation.id,
      run_id: ownership.run_id,
      run_revision: ownership.run_revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: ownership.capability,
      kind: :inference,
      attempt_id: ownership.invocation.attempt_id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      provider_started: true,
      usage: %{},
      outcome: {:error, {:inference_worker_down, reason_class(reason)}},
      metadata: %{remote_status: :ambiguous}
    }

    InferenceCoordinator.accept_receipt(data, ownership, receipt)
  end

  def worker_down(
        data,
        pid,
        %{kind: :invocation, invocation: %Invocation{kind: :effect} = invocation} = ownership,
        reason
      ) do
    failure = {:effect_worker_down, reason_class(reason)}
    run = Map.fetch!(data.runs, ownership.run_id)
    failed = Runs.terminalize_failed_run(run, failure)

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: ownership.run_id,
      run_revision: ownership.run_revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: ownership.capability,
      kind: :effect,
      provider_started: true,
      outcome: {:error, failure, failed},
      metadata: %{remote_status: :ambiguous}
    }

    data =
      data
      |> finish_worker(pid)
      |> Map.put(:invocations, Map.delete(data.invocations, invocation.id))
      |> Map.put(:state_lock, nil)

    commit_effect_terminal(data, ownership, receipt)
  end

  def worker_down(data, pid, %{kind: :advance, entry: entry} = worker, reason) do
    if policy_resolution_entry?(entry) do
      failure = {:policy_worker_down, reason_class(reason)}
      run = Map.fetch!(data.runs, worker.run_id)
      failed = Runs.terminalize_failed_run(run, failure)

      data =
        data
        |> finish_worker(pid)
        |> Map.put(:active, nil)

      commit_policy_decision(data, {:error, failure, failed}, entry)
    else
      finish_failed_worker(data, pid, worker, reason)
    end
  end

  def worker_down(data, pid, worker, reason) do
    finish_failed_worker(data, pid, worker, reason)
  end

  defp finish_failed_worker(data, pid, worker, reason) do
    data = finish_worker(data, pid)
    failure = {:instance_worker_down, worker.kind, reason}
    run = Map.get(data.runs, worker.run_id)

    failed = if run, do: Runs.terminalize_failed_run(run, failure), else: nil

    data =
      data
      |> Map.put(:active, if(match?(%{pid: ^pid}, data.active), do: nil, else: data.active))
      |> Map.put(:state_lock, nil)
      |> Map.put(
        :invocations,
        Enum.reject(data.invocations, fn {_id, value} -> value.pid == pid end) |> Map.new()
      )

    data = if failed, do: Runs.put_run(data, failed), else: data
    data = RunQueue.reply_caller(data, worker.run_id, {:error, failure})
    data = if failed, do: Runs.record_terminal(data, failed), else: data
    data |> RunQueue.schedule() |> Idle.arm()
  end

  @doc false
  @spec spawn_worker((-> term())) :: {pid(), reference()}
  def spawn_worker(fun) do
    :erlang.spawn_opt(fun, [:link, :monitor])
  end

  @doc false
  @spec safe_step(Run.t(), (-> term())) :: term()
  def safe_step(run, fun) do
    fun.()
  rescue
    exception ->
      failed =
        Runs.terminalize_failed_run(
          run,
          {:instance_worker_exception, exception.__struct__}
        )

      {:error, failed.last_error, failed}
  catch
    kind, reason ->
      failed = Runs.terminalize_failed_run(run, {:instance_worker_failure, kind, reason})

      {:error, failed.last_error, failed}
  end

  @doc false
  @spec finish_worker(InstanceState.t(), pid()) :: InstanceState.t()
  def finish_worker(data, pid) do
    case Map.pop(data.workers, pid) do
      {nil, workers} ->
        %{data | workers: workers}

      {%{monitor: monitor}, workers} ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(pid)
        %{data | workers: workers}
    end
  end

  defp state_neutral_step?(entry, %Run{}), do: not entry_commits_state?(entry)

  defp entry_commits_state?(entry),
    do: Map.get(entry, :commit_state?, not Map.get(entry, :internal?, false))

  defp portable_failure(reason), do: InferenceFailure.sanitize(reason)

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

  defp emit(event, data, measurements, metadata),
    do: InstanceTelemetry.emit(event, data, measurements, metadata)

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)
  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)
end
