defmodule Spectre.Instance.InferenceSteering do
  @moduledoc false

  # Owns restart-based steering for a live inference stream. It validates the
  # bearer stream handle, commits control revisions, fences the old session,
  # settles the superseded budget, and constructs the successor attempt. The
  # current Enumerable always terminates; a successful steer returns a new
  # stream rather than joining two epochs.

  alias Spectre.Inference.Budget
  alias Spectre.Inference.Failure, as: InferenceFailure
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Selection, as: InferenceSelection
  alias Spectre.Inference.Stream, as: InferenceStream
  alias Spectre.Inference.Usage, as: InferenceUsage
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceControl
  alias Spectre.Instance.InferenceCoordinator
  alias Spectre.Instance.InferenceStreamControl
  alias Spectre.Instance.Owner
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Invocation
  alias Spectre.Operation.Control.Command, as: ControlCommand
  alias Spectre.Prompt.Plan, as: PromptPlan
  alias Spectre.Run
  alias Spectre.Run.Value

  @doc false
  def resume_stream(data, %InferenceStream{} = old_stream, from) do
    with :ok <- owner_guard(data, :inference_resume),
         %Run{
           status: :awaiting,
           cursor: :inference,
           inference_continuation: %{stream_recovery: recovery}
         } = run <- Map.get(data.runs, old_stream.run_id),
         :ok <- InferenceStreamControl.validate_resume(run, recovery, old_stream) do
      case RunQueue.stream_session(data, run.id) do
        {_invocation_id, %{stream: %InferenceStream{} = stream}} ->
          {:reply, {:ok, stream}, data}

        nil when is_map_key(data.callers, run.id) ->
          {:reply, {:error, :stream_resume_already_waiting}, data}

        nil ->
          {:noreply, RunQueue.put_caller(data, run.id, from)}
      end
    else
      nil -> {:reply, {:error, :stream_resume_unavailable}, data}
      {:error, reason} -> {:reply, {:error, reason}, data}
      _mismatch -> {:reply, {:error, :stream_resume_unavailable}, data}
    end
  end

  @doc false
  def cancel_stream(data, %InferenceStream{} = stream, reason, opts) do
    with :ok <- owner_guard(data, :inference_cancel),
         {:ok, ownership, run} <- InferenceStreamControl.current_ownership(data, stream),
         {:ok, command} <- InferenceStreamControl.cancel_command(run, stream, reason, opts),
         {:ok, committed} <- commit_stream_cancel(data, run, command) do
      send(
        ownership.pid,
        {:spectre, :stream_cancel_committed, ownership.invocation.id, portable_failure(reason),
         command.id}
      )

      {:ok, committed}
    else
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp commit_stream_cancel(data, run, command) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         control <-
           Map.get(
             controls,
             command.loop_id,
             InferenceControl.new(run.inference_continuation.control_revision)
           ) do
      case InferenceControl.apply_cancel(control, command) do
        :duplicate ->
          {:ok, data}

        {:ok, next_control} ->
          Commit.canonical_sections(
            data,
            %{inference_control: Map.put(controls, command.loop_id, next_control)},
            correlation_id: run.id,
            causation_id: command.id,
            provenance: %{source: :inference_control, command_id: command.id},
            metadata: %{transition: :inference_cancel_applied}
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc false
  def steer_stream(data, %InferenceStream{} = stream, input, opts, from) do
    with :ok <- owner_guard(data, :inference_steer),
         {:ok, ownership, run} <- InferenceStreamControl.current_ownership(data, stream),
         {:ok, steer_input} <- InferenceStreamControl.normalize_steer_input(input, opts, data),
         {:ok, command} <- InferenceStreamControl.steer_command(run, stream, steer_input, opts),
         {:ok, committed, control} <- commit_pending_steer(data, run, command),
         {:ok, next} <-
           apply_committed_steer(
             committed,
             ownership,
             run,
             steer_input,
             command,
             control,
             opts,
             from
           ) do
      {:ok, next}
    else
      {:error, reason, next} -> {:error, reason, next}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp commit_pending_steer(data, run, command) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         control <-
           Map.get(
             controls,
             run.inference_continuation.inference_id,
             InferenceControl.new(run.inference_continuation.control_revision)
           ),
         {:ok, next_control} <- InferenceControl.begin_steer(control, command),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{inference_control: Map.put(controls, command.loop_id, next_control)},
             correlation_id: run.id,
             causation_id: command.id,
             provenance: %{source: :inference_control, command_id: command.id},
             metadata: %{transition: :inference_steer_committed}
           ) do
      {:ok, committed, next_control}
    end
  end

  defp apply_committed_steer(
         data,
         ownership,
         run,
         steer_input,
         command,
         control,
         opts,
         from
       ) do
    with {:ok, successor, invocation, prepared, entry} <-
           build_steer_successor(data, ownership, run, steer_input, control, opts),
         {:ok, writes} <- Commit.run_writes(data, data.state, successor),
         applied_command <- ControlCommand.applied(control.pending),
         applied_control <- InferenceControl.finish(control, applied_command),
         {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         writes <-
           Map.put(
             writes,
             :inference_control,
             Map.put(controls, invocation.inference_id, applied_control)
           ),
         successor_reservation <- {data.ref.key, run.id, invocation.attempt_id},
         :ok <-
           InferenceCapacity.replace(
             data,
             ownership.capacity_reservation,
             successor_reservation,
             self()
           ) do
      case Commit.canonical_sections(data, writes,
             correlation_id: run.id,
             causation_id: command.id,
             provenance: %{source: :inference_control, command_id: command.id},
             metadata: %{transition: :inference_steer_applied}
           ) do
        {:ok, committed} ->
          send(
            ownership.pid,
            {:spectre, :stream_superseded, ownership.invocation.id,
             %{
               successor_invocation_digest: id_digest(invocation.id),
               provider_cancel: :best_effort
             }}
          )

          Process.demonitor(ownership.monitor, [:flush])

          next = %{
            committed
            | runs: Map.put(committed.runs, successor.id, successor),
              invocations: Map.delete(committed.invocations, ownership.invocation.id),
              stream_sessions: Map.delete(committed.stream_sessions, ownership.invocation.id),
              stream_monitors: Map.delete(committed.stream_monitors, ownership.pid),
              stream_reservations:
                Map.put(committed.stream_reservations, run.id, successor_reservation),
              inference_liveness_clock:
                Map.delete(committed.inference_liveness_clock, ownership.invocation.id),
              state_lock: %{run_id: run.id, invocation_id: invocation.id}
          }

          next = RunQueue.put_caller(next, run.id, from)

          {:ok,
           commit_inference_supersession_receipt(
             next,
             successor,
             ownership.invocation,
             invocation,
             prepared,
             entry,
             command
           )}

        {:error, reason} ->
          # Capacity changes before the canonical commit so a session crash
          # cannot leave a committed successor without an admission slot.
          _ =
            InferenceCapacity.replace(
              data,
              successor_reservation,
              ownership.capacity_reservation,
              ownership.pid
            )

          rejected = reject_pending_steer(data, run, control, reason)
          {:error, reason, rejected}
      end
    else
      {:error, reason} ->
        rejected = reject_pending_steer(data, run, control, reason)
        {:error, reason, rejected}
    end
  end

  defp build_steer_successor(data, ownership, run, steer_input, control, opts) do
    current = run.inference_continuation
    attempt = current.attempt + 1

    plan =
      PromptPlan.append_context_data(current.descriptor.plan, steer_input.text,
        id: Value.token("steer-context", {current.inference_id, control.generation}),
        provenance: %{source: :steering, command_id: control.pending.id}
      )

    descriptor = %{current.descriptor | plan: plan}

    %InferenceSelection{} = current_selection = ownership.prepared.selection

    selection = %InferenceSelection{
      current_selection
      | attempt: attempt,
        reason: :steering_restart,
        metadata:
          Map.put(
            current_selection.metadata,
            :steering_command_id,
            control.pending.id
          )
    }

    frozen = FrozenSelection.from_selection(selection)

    case settle_superseded_attempt(data, current, ownership.invocation) do
      {:ok, budget, previous} ->
        continuation = %{
          current
          | descriptor: descriptor,
            frozen_selection: frozen,
            invocation: nil,
            stream_epoch: nil,
            attempt: attempt,
            previous_attempts: Enum.take([previous | current.previous_attempts], 32),
            control_revision: control.generation,
            provider_status: :selected,
            provider_request_id: nil,
            provider_request_digest: nil,
            resume_cursor: nil,
            consumer_token_digest: nil,
            stream_recovery: nil,
            stream_provider_sequence: nil,
            stream_usage: %InferenceUsage{},
            stream_usage_quality: :unavailable,
            stream_output_bytes: 0,
            budget: budget,
            recovery: %{status: :steer_successor_selected, command_id: control.pending.id},
            last_response: nil
        }

        successor = %{
          run
          | revision: run.revision + 1,
            step_id: Value.token("inference-steer-step", {run.id, control.generation}),
            waiting: nil,
            inference_continuation: continuation,
            last_error: nil
        }

        invocation = Invocation.from_inference(successor, continuation, streaming?: true)

        continuation = %{
          continuation
          | invocation: invocation,
            stream_epoch: invocation.stream_epoch
        }

        successor = %{successor | waiting: invocation, inference_continuation: continuation}

        prepared = %{
          ownership.prepared
          | descriptor: descriptor,
            selection: selection,
            frozen_selection: frozen
        }

        entry = %{
          ownership.entry
          | opts: ownership.entry.opts |> Keyword.merge(opts) |> Keyword.put(:streaming?, true),
            state_revision: data.state.revision,
            stream_capacity_reservation: nil,
            admitted?: false
        }

        {:ok, successor, invocation, prepared, entry}

      {:error, reason} ->
        {:error, {:inference_budget_settlement_failed, portable_failure(reason)}}
    end
  end

  defp commit_inference_supersession_receipt(
         data,
         successor,
         previous_invocation,
         successor_invocation,
         prepared,
         entry,
         command
       ) do
    previous = hd(successor.inference_continuation.previous_attempts)

    continuation = %{
      successor.inference_continuation
      | recovery: %{
          status: :supersession_receipted,
          command_id: command.id,
          previous_invocation_id: previous_invocation.id
        }
    }

    receipted = %{successor | inference_continuation: continuation}

    payload = %{
      outcome: :superseded,
      previous_attempt: previous,
      successor_invocation_id: successor_invocation.id,
      provider_cancel: if(previous.settlement == :confirmed, do: :not_started, else: :ambiguous)
    }

    receipt_opts =
      InferenceCoordinator.receipt_opts(
        previous_invocation,
        "spectre.inference.attempt-superseded/1"
      )

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
          {:inference_superseded, successor_invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        RunExecution.fail(%{data | state_lock: nil}, receipted, reason)
    end
  end

  defp settle_superseded_attempt(data, continuation, invocation) do
    liveness = Map.get(data.inference_liveness_clock, invocation.id, %{})
    usage = Map.get(liveness, :usage, %InferenceUsage{})
    status = if Map.get(liveness, :state) == :awaiting_consumer, do: :confirmed, else: :ambiguous

    previous = %{
      attempt: continuation.attempt,
      attempt_id: invocation.attempt_id,
      invocation_id: invocation.id,
      stream_epoch: invocation.stream_epoch,
      control_revision: invocation.control_revision,
      outcome: :superseded,
      usage: usage,
      settlement: status
    }

    case continuation.budget do
      %Budget{} = budget ->
        case Budget.settle(budget, invocation.attempt_id, usage, status) do
          {:ok, settled} -> {:ok, settled, previous}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:ok, nil, previous}
    end
  end

  defp reject_pending_steer(data, run, control, reason) do
    rejected = ControlCommand.rejected(control.pending, portable_failure(reason))
    next_control = InferenceControl.finish(control, rejected)

    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{inference_control: Map.put(controls, control.pending.loop_id, next_control)},
             correlation_id: run.id,
             causation_id: control.pending.id,
             provenance: %{source: :inference_control, command_id: control.pending.id},
             metadata: %{transition: :inference_steer_rejected}
           ) do
      committed
    else
      _error -> data
    end
  end

  defp portable_failure(reason), do: InferenceFailure.sanitize(reason)

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)
end
