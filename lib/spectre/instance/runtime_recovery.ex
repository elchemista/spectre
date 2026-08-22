defmodule Spectre.Instance.RuntimeRecovery do
  @moduledoc false

  # Reconstructs process-local execution after canonical state has been loaded.
  # Recovery never reuses dead PIDs, monitors, capabilities, or reservations:
  # it rebuilds them from durable continuations, revalidates every fence, and
  # either resumes through the normal dispatch APIs or writes an explicit
  # terminal/ambiguous outcome. Receipt recovery may defer this module until
  # the durable outbox is empty.

  alias Spectre.Inference
  alias Spectre.Inference.Budget
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Failure, as: InferenceFailure
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Inference.Usage, as: InferenceUsage
  alias Spectre.Inference.UsageAccounting
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Idle
  alias Spectre.Instance.InferenceBudget
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceControl
  alias Spectre.Instance.InferenceCoordinator
  alias Spectre.Instance.Operations
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt, as: Receipt
  alias Spectre.Operation.Control.Command, as: ControlCommand
  alias Spectre.Receipt.Envelope, as: ReceiptEnvelope
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.StartContinuation
  alias Spectre.Run.Value

  @doc false
  @spec recover(InstanceState.t()) :: {:ok, InstanceState.t()} | {:error, term()}
  def recover(data) do
    case recover_boot(data) do
      {:ok, recovered} -> {:ok, recovered}
      {:error, reason, _partial} -> {:error, reason}
    end
  end

  @doc false
  @spec recover_boot(InstanceState.t()) ::
          {:ok, InstanceState.t()} | {:error, term(), InstanceState.t()}
  def recover_boot(%{receipt_recovery_deferred: true} = data), do: {:ok, data}

  def recover_boot(data) do
    case recover_conversational_state(data) do
      {:ok, data} -> Operations.recover_with_state(data)
      {:error, _reason, _partial} = error -> error
    end
  end

  @doc false
  @spec required_receipts_pending?(atom(), Canonical.t()) :: boolean()
  def required_receipts_pending?(:required, canonical) do
    match?({:ok, %{entries: [_ | _]}}, Canonical.fetch(canonical, :receipt_outbox))
  end

  def required_receipts_pending?(_mode, _canonical), do: false

  @doc false
  @spec recover_receipted_inference_attempt(
          InstanceState.t(),
          ReceiptEnvelope.t(),
          String.t() | nil
        ) :: InstanceState.t()
  def recover_receipted_inference_attempt(data, envelope, consumer_token) do
    with %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{id: invocation_id} = invocation,
           inference_continuation: continuation
         } = run <- Map.get(data.runs, envelope.run_id),
         true <- invocation_id == envelope.invocation_id,
         opts <-
           data
           |> RuntimeOptions.build(
             Inference.Descriptor.options(continuation.descriptor),
             run.input
           )
           |> RuntimeOptions.pin_run(run),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         entry <- inference_entry(data, run, opts),
         {:ok, run, budget_snapshot} <-
           InferenceBudget.reserve(run, invocation, prepared, entry),
         {:ok, data, reservation} <- reserve_recovered_stream_capacity(data, run, invocation),
         entry <-
           entry
           |> Map.put(:stream_capacity_reservation, reservation)
           |> maybe_put_recovered_stream_token(consumer_token) do
      data
      |> Runs.put_run(run)
      |> InferenceCoordinator.start_worker(run, invocation, prepared, entry, budget_snapshot)
    else
      false ->
        terminalize_recovered_inference(data, envelope.run_id, :stale_attempt_start_receipt)

      nil ->
        terminalize_recovered_inference(data, envelope.run_id, :missing_attempt_start_run)

      {:error, reason} ->
        terminalize_recovered_inference(data, envelope.run_id, reason)
    end
  end

  defp reserve_recovered_stream_capacity(data, run, %{metadata: %{streaming?: true}}),
    do: InferenceCapacity.reserve(data, run.id, :stream)

  defp reserve_recovered_stream_capacity(data, _run, _invocation),
    do: {:ok, data, nil}

  defp maybe_put_recovered_stream_token(entry, token) when is_binary(token),
    do: Map.put(entry, :stream_consumer_token, token)

  defp maybe_put_recovered_stream_token(entry, _token), do: entry

  # Ready queue entries are process-local, so they must be reconstructed from
  # the durable admission continuation before operational recovery is allowed
  # to schedule competing work.
  defp recover_conversational_state(data) do
    data.runs
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, data}, fn run, {:ok, acc} ->
      case recover_conversational_run(acc, run) do
        {:ok, next} ->
          {:cont, {:ok, next}}

        {:error, reason} ->
          {:halt, {:error, {:run_recovery_failed, run.id, reason}, acc}}
      end
    end)
  end

  defp recover_conversational_run(
         %{invocations: invocations} = data,
         %Run{waiting: %Invocation{id: invocation_id}}
       )
       when is_map_key(invocations, invocation_id),
       do: {:ok, data}

  defp recover_conversational_run(
         data,
         %Run{
           status: :ready,
           cursor: :turn,
           start_continuation: %StartContinuation{recoverable?: true} = continuation
         } = run
       ) do
    restored_opts =
      data
      |> RuntimeOptions.build(StartContinuation.runtime_options(continuation), run.input)
      |> RuntimeOptions.pin_run(run)

    case recovered_start_entry(run, continuation, restored_opts, data.state.revision) do
      {:ok, entry} -> {:ok, RunQueue.enqueue(data, entry)}
      {:error, reason} -> terminalize_unrecoverable_run(data, run, reason)
    end
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation:
             %{provider_status: :selected, recoverable?: true} =
               continuation
         } = run
       ) do
    restored_opts =
      data
      |> RuntimeOptions.build(
        Spectre.Inference.Descriptor.options(continuation.descriptor),
        run.input
      )
      |> RuntimeOptions.pin_run(run)

    case Inference.rebind(
           data.agent,
           continuation.descriptor,
           continuation.frozen_selection,
           run.input,
           data.state,
           restored_opts
         ) do
      {:ok, prepared} ->
        entry = inference_entry(data, run, restored_opts)

        next =
          case get_in(continuation.recovery || %{}, [:status]) do
            :stream_restart_receipted ->
              entry =
                Map.put(entry, :stream_resume_from, %{
                  provider_request_id: continuation.provider_request_id,
                  resume_cursor: continuation.resume_cursor,
                  provider_sequence: continuation.stream_provider_sequence,
                  usage: continuation.stream_usage,
                  usage_quality: continuation.stream_usage_quality,
                  output_bytes: continuation.stream_output_bytes
                })

              resume_recovered_stream_dispatch(data, run, invocation, prepared, entry)

            recovery_status ->
              resume_recovered_selected_dispatch(
                data,
                run,
                invocation,
                prepared,
                entry,
                recovery_status
              )
          end

        {:ok, next}

      {:error, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:inference_rebind_failed, reason})}
    end
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation: %{
             provider_status: :terminal,
             recovery: %{status: :retry_pending, reason: reason}
           }
         } = run
       ) do
    opts =
      data
      |> RuntimeOptions.build(
        Spectre.Inference.Descriptor.options(run.inference_continuation.descriptor),
        run.input
      )
      |> RuntimeOptions.pin_run(run)

    entry = inference_entry(data, run, opts)
    ownership = %{mode: :one_shot, invocation: invocation, entry: entry}
    {:ok, InferenceCoordinator.retry(data, run, ownership, reason)}
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation: %{
             provider_status: :terminal,
             last_response: %InferenceResponse{} = response
           }
         } = run
       ) do
    opts =
      data
      |> RuntimeOptions.build(
        Spectre.Inference.Descriptor.options(run.inference_continuation.descriptor),
        run.input
      )
      |> RuntimeOptions.pin_run(run)

    entry = inference_entry(data, run, opts)
    ownership = %{invocation: invocation, entry: entry}
    {:ok, InferenceCoordinator.resume_worker(data, run, ownership, response)}
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference, metadata: %{streaming?: true}},
           inference_continuation: %{provider_status: status} = continuation
         } = run
       )
       when status in [:streaming, :interrupted] do
    recover_streaming_attempt(data, run, continuation)
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference, metadata: %{streaming?: true}},
           inference_continuation: %{provider_status: status}
         } = run
       )
       when status in [:dispatching, :ambiguous] do
    recover_uncertain_inference(data, run, status)
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           inference_continuation: %{provider_status: status}
         } = run
       )
       when status in [:dispatching, :streaming, :interrupted, :ambiguous] do
    {:ok, terminalize_recovered_inference(data, run.id, status)}
  end

  defp recover_conversational_run(
         data,
         %Run{status: :awaiting, cursor: :inference} = run
       ) do
    {:ok, terminalize_recovered_inference(data, run.id, :inference_recovery_unavailable)}
  end

  # An Effect worker may have crossed its external boundary before the owner
  # crashed. Re-dispatch would risk duplicating it, while leaving the Run
  # awaiting a dead worker leaks a retained slot forever. Record the explicit
  # ambiguous terminal through the normal effect/action receipt path.
  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :effect,
           waiting: %Invocation{kind: :effect} = invocation
         } = run
       ) do
    {:ok, terminalize_recovered_effect(data, run, invocation)}
  end

  # A reply boundary contains no external work. It is safe to advance the
  # already-committed Result to its terminal Run projection after restart.
  defp recover_conversational_run(
         data,
         %Run{status: :boundary, cursor: :complete, waiting: %Boundary{kind: :reply}} = run
       ) do
    opts =
      data
      |> RuntimeOptions.build([], run.input)
      |> RuntimeOptions.pin_run(run)

    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false,
      admitted?: false,
      recovered?: true
    }

    {:ok, RunQueue.enqueue(data, entry)}
  end

  # Policy boundaries are intentionally durable waits for a future host
  # command. They have no dead process ownership to reconstruct.
  defp recover_conversational_run(
         data,
         %Run{status: :boundary, cursor: :policy, waiting: %Boundary{kind: :needs}}
       ),
       do: {:ok, data}

  defp recover_conversational_run(
         data,
         %Run{status: :ready, cursor: :turn, start_continuation: continuation} = run
       ) do
    reason =
      case continuation do
        %StartContinuation{reason: reason} when not is_nil(reason) -> reason
        _missing -> :missing_start_continuation
      end

    terminalize_unrecoverable_run(data, run, reason)
  end

  defp recover_conversational_run(data, %Run{}), do: {:ok, data}

  defp recovered_start_entry(
         run,
         %StartContinuation{entrypoint: :turn},
         opts,
         state_revision
       ) do
    {:ok,
     %{
       run_id: run.id,
       operation: :advance,
       projection: :result,
       input: run.input,
       opts: opts,
       state_revision: state_revision,
       internal?: true,
       commit_state?: true,
       admitted?: true,
       recovered?: true
     }}
  end

  defp recovered_start_entry(
         run,
         %StartContinuation{
           entrypoint: :inference,
           inference_request: %InferenceRequest{} = request
         },
         opts,
         state_revision
       ) do
    {:ok,
     %{
       run_id: run.id,
       operation: {:inference, request},
       projection: :inference_response,
       input: run.input,
       opts: opts,
       state_revision: state_revision,
       internal?: true,
       commit_state?: false,
       admitted?: false,
       recovered?: true
     }}
  end

  defp recovered_start_entry(_run, _continuation, _opts, _state_revision),
    do: {:error, :invalid_start_continuation_entrypoint}

  @doc false
  def inference_entry(data, run, opts) do
    projection = recovered_inference_projection(run.inference_continuation)

    %{
      run_id: run.id,
      operation: :advance,
      projection: projection,
      input: run.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: projection != :inference_response,
      admitted?: false,
      recovered?: true
    }
  end

  defp recovered_inference_projection(%{postprocessor: :cognitive_operation}),
    do: :inference_response

  defp recovered_inference_projection(_continuation), do: :result

  # Capacity reservations are process-local leases. A checkpoint can retain a
  # selected streaming Invocation, but it cannot retain the reservation owned
  # by the crashed Instance. Reacquire that lease before releasing any recovered
  # selection receipt; otherwise the session would start with no capacity fence.
  defp resume_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         recovery_status
       ) do
    case reserve_recovered_stream_capacity(data, run, invocation) do
      {:ok, reserved, reservation} ->
        entry = Map.put(entry, :stream_capacity_reservation, reservation)

        continue_recovered_selected_dispatch(
          reserved,
          run,
          invocation,
          prepared,
          entry,
          recovery_status
        )

      {:error, reason} ->
        terminalize_recovered_inference(data, run.id, reason)
    end
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :selection_receipted
       ) do
    InferenceCoordinator.dispatch_intent(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :supersession_receipted
       ) do
    commit_recovered_selection_receipt(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :steer_successor_selected
       ) do
    commit_recovered_supersession_receipt(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         _unreceipted_selection
       ) do
    commit_recovered_selection_receipt(data, run, invocation, prepared, entry)
  end

  defp resume_recovered_stream_dispatch(data, run, invocation, prepared, entry) do
    case InferenceCapacity.reserve(data, run.id, :stream) do
      {:ok, reserved, reservation} ->
        entry = Map.put(entry, :stream_capacity_reservation, reservation)
        InferenceCoordinator.dispatch_intent(reserved, run, invocation, prepared, entry)

      {:error, reason} ->
        terminalize_recovered_inference(data, run.id, reason)
    end
  end

  defp recover_streaming_attempt(data, run, continuation) do
    opts =
      data
      |> RuntimeOptions.build(Inference.Descriptor.options(continuation.descriptor), run.input)
      |> RuntimeOptions.pin_run(run)

    with :continue <- recovered_inference_control(data, run),
         true <- continuation.recoverable?,
         true <- not is_nil(continuation.resume_cursor),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         true <- MapSet.member?(prepared.stream_capabilities, :resume),
         {:ok, reserved, reservation} <- InferenceCapacity.reserve(data, run.id, :stream),
         {:ok, successor, invocation, entry} <-
           build_recovered_stream_successor(
             reserved,
             run,
             opts,
             reservation
           ),
         {:ok, committed} <- Commit.run_state(reserved, data.state, successor) do
      retained =
        committed
        |> Runs.put_run(successor)
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})

      {:ok,
       commit_recovered_stream_restart_receipt(
         retained,
         successor,
         run.waiting,
         invocation,
         prepared,
         entry
       )}
    else
      {:cancelled, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:cancelled, reason})}

      {:error, :pending_inference_control_on_recovery} ->
        reject_interrupted_inference_control(data, run)

      false ->
        recover_uncertain_inference(data, run, :stream_resume_capability_unavailable)

      {:error, reason} ->
        :ok = InferenceCapacity.release_reservation(data, {data.ref.key, run.id})
        recover_uncertain_inference(data, run, {:stream_resume_unavailable, reason})
    end
  end

  defp recover_uncertain_inference(data, run, recovery_reason) do
    continuation = run.inference_continuation

    opts =
      data
      |> RuntimeOptions.build(Inference.Descriptor.options(continuation.descriptor), run.input)
      |> RuntimeOptions.pin_run(run)

    with :continue <- recovered_inference_control(data, run),
         true <- not is_nil(continuation.provider_request_id),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         true <- MapSet.member?(prepared.stream_capabilities, :reconcile) do
      entry = inference_entry(data, run, opts)
      {:ok, start_inference_reconciliation(data, run, prepared, entry)}
    else
      {:cancelled, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:cancelled, reason})}

      {:error, :pending_inference_control_on_recovery} ->
        reject_interrupted_inference_control(data, run)

      _unavailable ->
        {:ok, terminalize_recovered_inference(data, run.id, recovery_reason)}
    end
  end

  # A restart can land after the durable `:committed` steering command but
  # before the successor Run and `:applied` control are committed together.
  # The old provider is already fenced by the new Instance generation, but the
  # canonical command must not remain pending forever. Reject it explicitly,
  # then close the uncertain attempt through its normal terminal receipt path.
  defp reject_interrupted_inference_control(data, run) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         %{pending: %ControlCommand{} = pending} = control <-
           Map.get(controls, run.inference_continuation.inference_id),
         rejected <-
           ControlCommand.rejected(pending, :instance_restarted_before_control_apply),
         next_control <- InferenceControl.finish(control, rejected),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{
               inference_control:
                 Map.put(controls, run.inference_continuation.inference_id, next_control)
             },
             correlation_id: run.id,
             causation_id: pending.id,
             provenance: %{source: :agent_restart, command_id: pending.id},
             metadata: %{transition: :inference_control_rejected_on_recovery}
           ) do
      {:ok,
       terminalize_recovered_inference(
         committed,
         run.id,
         :pending_inference_control_interrupted
       )}
    else
      nil -> {:error, :missing_pending_inference_control}
      {:error, reason} -> {:error, {:inference_control_rejection_failed, reason}}
    end
  end

  # Control is canonical independently from the Run checkpoint. Recovery must
  # inspect it before touching the provider, otherwise a crash between a
  # committed cancel and its terminal receipt could resurrect the stream.
  defp recovered_inference_control(data, %Run{waiting: %Invocation{} = invocation}) do
    case Canonical.fetch(data.canonical, :inference_control) do
      {:ok, controls} ->
        controls
        |> Map.get(invocation.inference_id)
        |> InferenceControl.recover(invocation)

      {:error, reason} ->
        {:error, {:inference_control_recovery_failed, reason_class(reason)}}
    end
  end

  defp start_inference_reconciliation(data, run, prepared, entry) do
    invocation = run.waiting
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()
    budget_snapshot = recovered_inference_budget_snapshot(run, invocation.attempt_id)

    {pid, monitor} =
      RunExecution.spawn_worker(fn ->
        result =
          Inference.reconcile(
            prepared,
            run.inference_continuation.provider_request_id,
            entry.opts
          )

        {outcome, provider_started?, remote_status} = reconciliation_outcome(result)

        {usage, usage_quality} =
          UsageAccounting.complete_response_outcome(outcome, budget_snapshot)

        receipt = %Receipt{
          invocation_id: invocation.id,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: dispatch_id,
          capability: capability,
          kind: :inference,
          attempt_id: invocation.attempt_id,
          control_revision: invocation.control_revision,
          stream_epoch: invocation.stream_epoch,
          provider_started: provider_started?,
          outcome: outcome,
          usage: usage,
          usage_quality: usage_quality,
          metadata: %{remote_status: remote_status, reconciliation: true}
        }

        send(owner, {:spectre, :invocation_result, invocation.id, receipt})
      end)

    ownership = %{
      mode: :reconcile,
      invocation_id: invocation.id,
      invocation_kind: :inference,
      invocation: invocation,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry,
      prepared: prepared,
      budget_snapshot: budget_snapshot
    }

    worker = Map.put(ownership, :kind, :invocation)

    data
    |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
    |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
    |> Map.put(:workers, Map.put(data.workers, pid, worker))
    |> Idle.disarm()
  end

  defp recovered_inference_budget_snapshot(
         %Run{inference_continuation: %{budget: %Budget{} = budget}},
         attempt_id
       ) do
    case Budget.reserve(budget, attempt_id, %InferenceUsage{}) do
      {:ok, _unchanged, %BudgetSnapshot{} = snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp recovered_inference_budget_snapshot(_run, _attempt_id), do: nil

  defp reconciliation_outcome({:ok, %InferenceResponse{} = response}),
    do: {{:ok, response}, true, :confirmed}

  defp reconciliation_outcome(:not_found),
    do: {{:error, :inference_reconciliation_not_found}, false, :confirmed}

  defp reconciliation_outcome(:pending),
    do: {{:error, :inference_reconciliation_pending}, true, :ambiguous}

  defp reconciliation_outcome({:error, reason}),
    do:
      {{:error, {:inference_reconciliation_failed, InferenceFailure.sanitize(reason)}}, true,
       :ambiguous}

  defp build_recovered_stream_successor(data, run, opts, reservation) do
    current = run.inference_continuation
    previous_invocation = current.invocation
    # Restart changes the data-plane epoch, not the user control revision.
    # The new Run revision is enough to derive a distinct Invocation id.
    control_revision = current.control_revision

    previous = %{
      attempt: current.attempt,
      attempt_id: previous_invocation.attempt_id,
      invocation_id: previous_invocation.id,
      stream_epoch: previous_invocation.stream_epoch,
      control_revision: previous_invocation.control_revision,
      outcome: :superseded,
      reason: :instance_restart,
      usage: current.stream_usage,
      settlement: :ambiguous
    }

    stream_recovery = %{
      mode: :provider_resume,
      previous_invocation_id: previous_invocation.id,
      previous_stream_epoch: previous_invocation.stream_epoch,
      previous_consumer_token_digest: current.consumer_token_digest,
      provider_request_digest: current.provider_request_digest,
      resume_cursor_digest: InferenceCoordinator.provider_cursor_digest(current.resume_cursor),
      provider_sequence: current.stream_provider_sequence
    }

    continuation = %{
      current
      | invocation: nil,
        stream_epoch: nil,
        control_revision: control_revision,
        provider_status: :selected,
        consumer_token_digest: nil,
        stream_recovery: stream_recovery,
        previous_attempts: Enum.take([previous | current.previous_attempts], 32),
        recovery: %{status: :stream_restart_selected},
        last_response: nil
    }

    successor = %{
      run
      | revision: run.revision + 1,
        step_id:
          Value.token("inference-stream-restart", {
            run.id,
            previous_invocation.id,
            control_revision
          }),
        waiting: nil,
        inference_continuation: continuation,
        last_error: nil
    }

    invocation =
      Invocation.from_inference(successor, continuation,
        attempt_id: previous_invocation.attempt_id,
        streaming?: true
      )

    continuation = %{
      continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch
    }

    successor = %{successor | waiting: invocation, inference_continuation: continuation}

    entry =
      data
      |> inference_entry(successor, Keyword.put(opts, :streaming?, true))
      |> Map.put(:stream_capacity_reservation, reservation)
      |> Map.put(:stream_resume_from, %{
        provider_request_id: current.provider_request_id,
        resume_cursor: current.resume_cursor,
        provider_sequence: current.stream_provider_sequence,
        usage: current.stream_usage,
        usage_quality: current.stream_usage_quality,
        output_bytes: current.stream_output_bytes
      })

    {:ok, successor, invocation, entry}
  end

  defp commit_recovered_stream_restart_receipt(
         data,
         successor,
         previous_invocation,
         successor_invocation,
         prepared,
         entry
       ) do
    previous = hd(successor.inference_continuation.previous_attempts)

    continuation = %{
      successor.inference_continuation
      | recovery: %{
          status: :stream_restart_receipted,
          previous_invocation_id: previous_invocation.id
        }
    }

    receipted = %{successor | inference_continuation: continuation}

    payload = %{
      outcome: :superseded,
      reason: :instance_restart,
      previous_attempt: previous,
      successor_invocation_id: successor_invocation.id,
      provider_cancel: :ambiguous,
      resume_cursor_digest:
        InferenceCoordinator.provider_cursor_digest(continuation.resume_cursor)
    }

    case Receipts.prepare_run(
           data,
           data.state,
           receipted,
           :inference_attempt_superseded,
           payload,
           InferenceCoordinator.receipt_opts(
             previous_invocation,
             "spectre.inference.attempt-superseded/1"
           )
         ) do
      {:ok, prepared_receipt} ->
        ReceiptCoordinator.commit_run(
          data,
          receipted,
          {:inference_stream_restarted, successor_invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        data
        |> InferenceCapacity.release(successor.id)
        |> Map.put(:state_lock, nil)
        |> RunExecution.fail(receipted, reason)
    end
  end

  defp commit_recovered_selection_receipt(data, run, invocation, prepared, entry) do
    selected = InferenceCoordinator.mark_selection_receipted(run)
    retained = Runs.put_run(data, selected)

    case InferenceCoordinator.prepare_selection_receipt(retained, selected, invocation, entry) do
      {:ok, prepared_receipt} ->
        ReceiptCoordinator.commit_run(
          retained,
          selected,
          {:inference_selected, invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        RunExecution.fail(%{data | state_lock: nil}, selected, reason)
    end
  end

  defp commit_recovered_supersession_receipt(data, run, invocation, prepared, entry) do
    case run.inference_continuation.previous_attempts do
      [previous | _rest] ->
        continuation = %{
          run.inference_continuation
          | recovery: %{
              status: :supersession_receipted,
              recovered: true,
              previous_invocation_id: Map.get(previous, :invocation_id)
            }
        }

        receipted = %{run | inference_continuation: continuation}

        payload = %{
          outcome: :superseded,
          previous_attempt: previous,
          successor_invocation_id: invocation.id,
          provider_cancel:
            if(Map.get(previous, :settlement) == :confirmed,
              do: :not_started,
              else: :ambiguous
            )
        }

        receipt_opts = [
          inference_id: continuation.inference_id,
          invocation_id: Map.get(previous, :invocation_id),
          attempt_id: Map.get(previous, :attempt_id),
          control_revision: Map.get(previous, :control_revision),
          stream_epoch: Map.get(previous, :stream_epoch),
          causation_id: Map.get(previous, :invocation_id),
          payload_schema_ref: "spectre.inference.attempt-superseded/1",
          privacy: :confidential
        ]

        case Receipts.prepare_run(
               data,
               data.state,
               receipted,
               :inference_attempt_superseded,
               payload,
               receipt_opts
             ) do
          {:ok, prepared_receipt} ->
            ReceiptCoordinator.commit_run(
              data,
              receipted,
              {:inference_superseded, invocation, prepared, entry},
              prepared_receipt
            )

          {:error, reason} ->
            RunExecution.fail(%{data | state_lock: nil}, receipted, reason)
        end

      [] ->
        RunExecution.fail(
          %{data | state_lock: nil},
          run,
          :missing_recovered_superseded_attempt
        )
    end
  end

  defp terminalize_unrecoverable_run(data, run, reason) do
    failure = {:run_recovery_unavailable, reason}
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, failure)
    retained = Runs.put_run(data, failed)

    case Commit.run_state(retained, data.state, failed) do
      {:ok, committed} -> {:ok, Runs.record_terminal(committed, failed)}
      {:error, commit_reason} -> {:error, commit_reason}
    end
  end

  defp terminalize_recovered_effect(data, run, invocation) do
    failure = {:effect_outcome_ambiguous, :instance_restarted}
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, failure)

    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: [],
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false,
      admitted?: false,
      recovered?: true
    }

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: Value.token("recovered-effect-dispatch", invocation.id),
      capability: make_ref(),
      kind: :effect,
      provider_started: true,
      outcome: {:error, failure, failed},
      metadata: %{remote_status: :ambiguous, recovered: true}
    }

    RunExecution.commit_effect_terminal(data, %{invocation: invocation, entry: entry}, receipt)
  end

  defp terminalize_recovered_inference(data, run_id, reason) do
    case Map.get(data.runs, run_id) do
      %Run{
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{kind: :inference} = invocation,
        inference_continuation: continuation
      } = run ->
        usage = %InferenceUsage{}

        {continuation, failure_reason, semantic} =
          case InferenceBudget.settle(
                 continuation,
                 invocation.attempt_id,
                 usage,
                 :ambiguous
               ) do
            {:ok, settled} ->
              {failure_reason, semantic} = recovered_inference_failure(reason)
              {settled, failure_reason, semantic}

            {:error, failed, settlement_reason} ->
              failure_reason =
                {:inference_budget_settlement_failed,
                 InferenceFailure.sanitize(settlement_reason)}

              {failed, failure_reason, :failed}
          end

        failure = {:inference_attempt_failed, continuation.attempt, failure_reason}

        receipt = %Receipt{
          invocation_id: invocation.id,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: Value.token("recovered-dispatch", invocation.id),
          capability: make_ref(),
          kind: :inference,
          attempt_id: invocation.attempt_id,
          control_revision: invocation.control_revision,
          stream_epoch: invocation.stream_epoch,
          provider_started: continuation.provider_status not in [:not_started, :selected],
          usage: InferenceUsage.to_map(usage),
          outcome: {:error, failure_reason},
          metadata: %{semantic: semantic, remote_status: :ambiguous, recovered: true}
        }

        failed =
          run
          |> Map.put(:inference_continuation, continuation)
          |> Runs.terminalize_failed_run(failure)
          |> InferenceCoordinator.put_terminal_metadata(continuation, invocation, receipt)

        payload = InferenceCoordinator.failure_payload(receipt, failure_reason)
        ownership = %{mode: :recovery, invocation: invocation, run_id: run.id}

        case Receipts.prepare_run(
               data,
               data.state,
               failed,
               :inference_attempt_terminal,
               payload,
               InferenceCoordinator.receipt_opts(
                 invocation,
                 "spectre.inference.attempt-terminal/1"
               )
             ) do
          {:ok, prepared} ->
            data
            |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
            |> ReceiptCoordinator.commit_run(
              failed,
              {:inference_terminal, ownership, {:failure, failure}},
              prepared
            )

          {:error, commit_reason} ->
            %{data | checkpoint_error: {:inference_recovery_commit_failed, commit_reason}}
        end

      nil ->
        data

      _terminal ->
        data
    end
  end

  defp recovered_inference_failure({:cancelled, reason}),
    do: {{:cancelled, InferenceFailure.sanitize(reason)}, :cancelled}

  defp recovered_inference_failure(reason),
    do: {{:inference_recovery_ambiguous, InferenceFailure.sanitize(reason)}, :ambiguous}

  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)
end
