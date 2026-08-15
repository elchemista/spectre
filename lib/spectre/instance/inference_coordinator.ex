defmodule Spectre.Instance.InferenceCoordinator do
  @moduledoc false

  # Coordinates one inference lifecycle inside the Instance owner process. The
  # module owns stream control, dispatch intent, provider worker/session
  # ownership, terminal settlement, retry, and failure projection. Canonical
  # state still changes only through Commit or the receipt coordinator, and all
  # asynchronous input is checked against the Invocation fences before use.

  alias Spectre.Inference
  alias Spectre.Inference.Failure, as: InferenceFailure
  alias Spectre.Inference.Prepared, as: PreparedInference
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Inference.Stream, as: InferenceStream
  alias Spectre.Inference.Usage, as: InferenceUsage
  alias Spectre.Inference.UsageAccounting
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Idle
  alias Spectre.Instance.InferenceAttempt
  alias Spectre.Instance.InferenceBudget
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceControl
  alias Spectre.Instance.InferenceStreamControl
  alias Spectre.Instance.Owner
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.RuntimeRecovery
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt, as: Receipt
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Receipt.Envelope, as: ReceiptEnvelope
  alias Spectre.Run
  alias Spectre.Run.Value

  @doc false
  def dispatch_intent(data, run, invocation, prepared, entry) do
    with {:ok, run, budget_snapshot} <-
           InferenceBudget.reserve(run, invocation, prepared, entry),
         {run, entry} <- prepare_stream_consumer_token(run, invocation, entry) do
      continuation = %{
        run.inference_continuation
        | provider_status: :dispatching,
          recovery: %{status: :dispatch_intent_committed}
      }

      dispatching = %{run | inference_continuation: continuation}

      payload = %{
        idempotency_key: invocation.idempotency_key,
        selection: dispatching.inference_continuation.frozen_selection,
        streaming?: invocation.metadata.streaming?,
        consumer_token_digest: continuation.consumer_token_digest,
        resume?: Map.has_key?(entry, :stream_resume_from),
        resume_cursor_digest: provider_cursor_digest(continuation.resume_cursor),
        budget: budget_snapshot
      }

      receipt_opts = receipt_opts(invocation, "spectre.inference.attempt-started/1")

      case Receipts.prepare_run(
             data,
             data.state,
             dispatching,
             :inference_attempt_started,
             payload,
             receipt_opts
           ) do
        {:ok, prepared_receipt} ->
          ReceiptCoordinator.commit_run(
            data,
            dispatching,
            {:inference_attempt_started, invocation, prepared, entry, budget_snapshot},
            prepared_receipt
          )

        {:error, reason} ->
          RunExecution.fail(%{data | state_lock: nil}, dispatching, reason)
      end
    else
      {:error, reason} -> RunExecution.fail(%{data | state_lock: nil}, run, reason)
    end
  end

  # Only a digest crosses the canonical boundary. The bearer token itself is
  # held by the caller/session and authorizes attach and control operations.
  defp prepare_stream_consumer_token(run, %{metadata: %{streaming?: true}}, entry) do
    token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())

    continuation = %{
      run.inference_continuation
      | consumer_token_digest: InferenceStreamControl.token_digest(token)
    }

    {%{run | inference_continuation: continuation}, Map.put(entry, :stream_consumer_token, token)}
  end

  defp prepare_stream_consumer_token(run, _invocation, entry), do: {run, entry}

  @doc false
  @spec commit_selection(
          InstanceState.t(),
          Invocation.t(),
          Run.t(),
          PreparedInference.t(),
          map()
        ) :: InstanceState.t()
  def commit_selection(data, invocation, run, prepared, entry) do
    with :ok <- owner_guard(data, :commit),
         selected <- mark_selection_receipted(run),
         projected <- RunExecution.project(data, selected, entry),
         {:ok, prepared_receipt} <-
           prepare_selection_receipt(projected, selected, invocation, entry) do
      ReceiptCoordinator.commit_run(
        projected,
        selected,
        {:inference_selected, invocation, prepared, entry},
        prepared_receipt
      )
    else
      {:error, reason} -> RunExecution.fail(data, run, reason)
    end
  end

  @doc false
  def prepare_selection_receipt(data, run, invocation, entry) do
    payload = %{
      purpose: run.inference_continuation.purpose,
      attempt: run.inference_continuation.attempt,
      selection: run.inference_continuation.frozen_selection,
      recoverable?: run.inference_continuation.recoverable?,
      nondeterminism_samples: Map.get(entry, :nondeterminism_samples, [])
    }

    Receipts.prepare_run(
      data,
      data.state,
      run,
      :inference_selected,
      payload,
      receipt_opts(invocation, "spectre.inference.selected/1")
    )
  end

  @doc false
  @spec mark_selection_receipted(Run.t()) :: Run.t()
  def mark_selection_receipted(run) do
    continuation = %{
      run.inference_continuation
      | recovery: %{status: :selection_receipted}
    }

    %{run | inference_continuation: continuation}
  end

  @doc false
  def receipt_opts(invocation, schema_ref) do
    [
      inference_id: invocation.inference_id,
      invocation_id: invocation.id,
      attempt_id: invocation.attempt_id,
      control_revision: invocation.control_revision,
      stream_epoch: invocation.stream_epoch,
      causation_id: invocation.id,
      payload_schema_ref: schema_ref,
      privacy: :confidential
    ]
  end

  @doc false
  def start_worker(data, run, invocation, prepared, entry, budget_snapshot) do
    if invocation.metadata.streaming? do
      start_inference_stream(data, run, invocation, prepared, entry, budget_snapshot)
    else
      start_one_shot_inference(data, run, invocation, prepared, entry, budget_snapshot)
    end
  end

  defp start_one_shot_inference(data, run, invocation, prepared, entry, budget_snapshot) do
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()

    {pid, monitor} =
      RunExecution.spawn_worker(fn ->
        {outcome, samples} =
          Spectre.Determinism.capture(entry.opts, fn ->
            Inference.execute(prepared, entry.opts)
          end)

        outcome = InferenceFailure.sanitize_outcome(outcome)

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
          provider_started: true,
          outcome: outcome,
          usage: usage,
          usage_quality: usage_quality,
          metadata: %{remote_status: :confirmed, nondeterminism_samples: samples}
        }

        send(owner, {:spectre, :invocation_result, invocation.id, receipt})
      end)

    ownership = %{
      mode: :one_shot,
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
    |> InferenceAttempt.arm_timer(ownership, budget_snapshot)
    |> Idle.disarm()
    |> tap(fn next ->
      emit(
        :invocation_dispatched,
        next,
        %{count: 1},
        %{run_id: id_digest(run.id), invocation_id: id_digest(invocation.id), kind: :inference}
      )
    end)
  end

  defp start_inference_stream(data, run, invocation, prepared, entry, budget_snapshot) do
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    consumer_token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())
    reservation = Map.get(data.stream_reservations, run.id)

    stream =
      InferenceStream.new(
        inference_id: invocation.inference_id,
        invocation_id: invocation.id,
        attempt_id: invocation.attempt_id,
        run_id: run.id,
        run_revision: run.revision,
        generation: data.generation,
        dispatch_id: dispatch_id,
        control_revision: invocation.control_revision,
        stream_epoch: invocation.stream_epoch,
        consumer_token: consumer_token,
        instance_ref: data.ref,
        registry: data.stream_registry,
        instance_registry: data.registry,
        demand: Keyword.get(entry.opts, :stream_demand, 8),
        next_timeout: Keyword.get(entry.opts, :stream_next_timeout, 30_000)
      )

    session_opts = [
      instance: self(),
      invocation: invocation,
      prepared: prepared,
      generation: data.generation,
      dispatch_id: dispatch_id,
      capability: capability,
      consumer_token: consumer_token,
      registry: data.stream_registry,
      capacity_reservation: reservation,
      capacity_server: data.stream_capacity,
      budget_snapshot: budget_snapshot,
      resume_from: Map.get(entry, :stream_resume_from),
      determinism_opts: entry.opts
    ]

    case RunnerSupervisor.start_stream_session(data.runner_supervisor, session_opts) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        ownership = %{
          mode: :stream,
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
          stream: stream,
          prepared: prepared,
          budget_snapshot: budget_snapshot,
          capacity_reservation: reservation
        }

        data
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
        |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
        |> Map.put(:stream_sessions, Map.put(data.stream_sessions, invocation.id, ownership))
        |> Map.put(:stream_monitors, Map.put(data.stream_monitors, pid, invocation.id))
        |> Map.put(:stream_reservations, Map.delete(data.stream_reservations, run.id))
        |> RunQueue.reply_stream_caller(run.id, stream)
        |> Idle.disarm()
        |> tap(fn next ->
          emit(
            :inference_stream_reserved,
            next,
            %{count: 1},
            %{
              run_id: id_digest(run.id),
              invocation_id: id_digest(invocation.id),
              stream_epoch: id_digest(invocation.stream_epoch)
            }
          )
        end)

      {:error, reason} ->
        data
        |> InferenceCapacity.release(run.id)
        |> Map.put(:state_lock, nil)
        |> RunExecution.fail(run, {:stream_session_start_failed, reason})
    end
  end

  @doc false
  def accept_receipt(data, ownership, receipt) do
    data =
      data
      |> InferenceAttempt.clear_timer(receipt.invocation_id)
      |> maybe_finish_inference_worker(ownership)
      |> Map.put(:invocations, Map.delete(data.invocations, receipt.invocation_id))

    case receipt.outcome do
      {:ok, %InferenceResponse{} = response} ->
        case InferenceBudget.enforce(ownership, receipt.usage) do
          :ok ->
            commit_inference_terminal(data, ownership, receipt, response)

          {:error, field} ->
            reason = {:inference_budget_exceeded, field}
            failed_receipt = %{receipt | outcome: {:error, reason}}
            fail_attempt(data, ownership, failed_receipt, reason)
        end

      {:error, reason} ->
        fail_attempt(data, ownership, receipt, reason)
    end
  end

  @doc false
  @spec handle_receipt(InstanceState.t(), map(), Receipt.t()) :: InstanceState.t()
  def handle_receipt(data, ownership, %Receipt{} = receipt) do
    case inference_receipt_disposition(data, ownership, receipt) do
      :accept ->
        accept_receipt(data, ownership, receipt)

      {:cancel, reason} ->
        accept_receipt(data, ownership, cancelled_race_receipt(receipt, reason))

      :stale ->
        emit(
          :stale_invocation_result,
          data,
          %{count: 1},
          %{invocation_id: id_digest(receipt.invocation_id), reason_class: :control_revision}
        )

        data
    end
  end

  @doc false
  @spec deadline(InstanceState.t(), String.t(), non_neg_integer(), String.t()) ::
          InstanceState.t()
  def deadline(data, invocation_id, generation, dispatch_id) do
    case {Map.get(data.inference_attempt_timers, invocation_id),
          Map.get(data.invocations, invocation_id)} do
      {%{generation: ^generation, dispatch_id: ^dispatch_id, deadline_at: deadline},
       %{mode: :one_shot, generation: ^generation, dispatch_id: ^dispatch_id} = ownership} ->
        apply_deadline(data, ownership, invocation_id, deadline)

      _stale ->
        data
    end
  end

  defp apply_deadline(data, ownership, invocation_id, deadline) do
    if Spectre.Determinism.system_time(:millisecond) < deadline,
      do: InferenceAttempt.rearm_timer(data, ownership, deadline),
      else: expire_inference_attempt(data, ownership, invocation_id)
  end

  defp expire_inference_attempt(data, ownership, invocation_id) do
    if Process.alive?(ownership.pid), do: Process.exit(ownership.pid, :kill)

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
      outcome: {:error, :inference_deadline_exceeded},
      metadata: %{remote_status: :ambiguous}
    }

    data
    |> InferenceAttempt.clear_timer(invocation_id)
    |> accept_receipt(ownership, receipt)
  end

  defp inference_receipt_disposition(data, ownership, receipt) do
    invocation = ownership.invocation

    case Canonical.fetch(data.canonical, :inference_control) do
      {:ok, controls} ->
        controls
        |> Map.get(invocation.inference_id)
        |> InferenceControl.receipt_disposition(invocation, receipt.outcome)

      {:error, _reason} ->
        :stale
    end
  end

  defp cancelled_race_receipt(receipt, reason) do
    metadata =
      receipt.metadata
      |> Map.put(:semantic, :cancelled)
      |> Map.put(:remote_status, :ambiguous)

    %{receipt | outcome: {:error, {:cancelled, reason}}, metadata: metadata}
  end

  defp maybe_finish_inference_worker(data, %{mode: :stream}), do: data

  defp maybe_finish_inference_worker(data, ownership),
    do: RunExecution.finish_worker(data, ownership.pid)

  defp commit_inference_terminal(data, ownership, receipt, response) do
    run = Map.fetch!(data.runs, ownership.run_id)

    case InferenceBudget.settle(
           run.inference_continuation,
           ownership.invocation.attempt_id,
           receipt.usage,
           :confirmed
         ) do
      {:ok, continuation} ->
        commit_settled_inference_terminal(
          data,
          run,
          continuation,
          ownership,
          receipt,
          response
        )

      {:error, continuation, reason} ->
        commit_budget_settlement_failure(
          data,
          run,
          continuation,
          ownership,
          receipt,
          reason
        )
    end
  end

  defp commit_settled_inference_terminal(
         data,
         run,
         continuation,
         ownership,
         receipt,
         response
       ) do
    portable_response = %{
      response
      | selection: continuation.frozen_selection,
        usage: if(map_size(receipt.usage) > 0, do: receipt.usage, else: response.usage),
        provider_request_id: provider_request_digest(response.provider_request_id),
        metadata: portable_response_metadata(response.metadata)
    }

    accepted_continuation = %{
      continuation
      | provider_status: :terminal,
        stream_usage_quality: receipt.usage_quality,
        last_response: portable_response,
        recovery: %{status: :terminal_receipt_committed}
    }

    accepted = %{run | inference_continuation: accepted_continuation}

    payload = %{
      outcome: :completed,
      provider_started: true,
      response: portable_response,
      usage: portable_response.usage,
      usage_quality: receipt.usage_quality,
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }

    receipt_opts = [
      inference_id: accepted_continuation.inference_id,
      invocation_id: ownership.invocation.id,
      attempt_id: ownership.invocation.attempt_id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      causation_id: ownership.invocation.id,
      payload_schema_ref: "spectre.inference.attempt-terminal/1",
      privacy: :confidential
    ]

    case Receipts.prepare_run(
           data,
           data.state,
           accepted,
           :inference_attempt_terminal,
           payload,
           receipt_opts
         ) do
      {:ok, prepared} ->
        commit_or_stage_inference_receipt(
          data,
          accepted,
          ownership,
          {:success, portable_response},
          prepared
        )

      {:error, reason} ->
        RunExecution.fail(%{data | state_lock: nil}, accepted, reason)
    end
  end

  @doc false
  def stream_session_down(data, invocation_id, pid, monitor, reason) do
    case Map.get(data.stream_sessions, invocation_id) do
      %{pid: ^pid, monitor: ^monitor, run_id: run_id} = ownership ->
        data = %{
          data
          | stream_sessions: Map.delete(data.stream_sessions, invocation_id),
            stream_monitors: Map.delete(data.stream_monitors, pid)
        }

        case {Map.has_key?(data.invocations, invocation_id), Map.get(data.runs, run_id)} do
          {true, %Run{status: status}} when status not in [:complete, :failed] ->
            liveness = Map.get(data.inference_liveness_clock, invocation_id, %{})

            receipt = %Receipt{
              invocation_id: invocation_id,
              run_id: run_id,
              run_revision: ownership.run_revision,
              generation: ownership.generation,
              dispatch_id: ownership.dispatch_id,
              capability: ownership.capability,
              kind: :inference,
              attempt_id: ownership.invocation.attempt_id,
              control_revision: ownership.invocation.control_revision,
              stream_epoch: ownership.invocation.stream_epoch,
              provider_started: Map.get(liveness, :state) != :awaiting_consumer,
              usage: Map.get(liveness, :usage, %{}),
              outcome: {:error, {:stream_interrupted, reason_class(reason)}},
              metadata: %{semantic: :interrupted, remote_status: :ambiguous}
            }

            accept_receipt(data, ownership, receipt)

          _consumed_terminal_or_missing ->
            # A terminal receipt consumes the invocation before the enclosing
            # Run necessarily replies. A later session DOWN belongs to that
            # already-settled attempt and must only release transient ownership.
            data |> RunQueue.schedule() |> Idle.arm()
        end

      _stale ->
        data
    end
  end

  @doc false
  @spec resume_receipt(InstanceState.t(), Run.t(), tuple()) :: InstanceState.t()
  def resume_receipt(data, run, {:inference_terminal, ownership, resume}),
    do: resume_boundary(data, run, ownership, resume)

  def resume_receipt(
        data,
        run,
        {:inference_superseded, invocation, prepared, entry}
      ) do
    data =
      InferenceAttempt.publish(
        data,
        :attempt_superseded,
        run.inference_continuation.inference_id,
        Map.get(run.inference_continuation.recovery, :previous_invocation_id),
        hd(run.inference_continuation.previous_attempts),
        %{successor_invocation_digest: id_digest(invocation.id)}
      )

    selected = mark_selection_receipted(run)
    projected = Runs.put_run(data, selected)

    case prepare_selection_receipt(projected, selected, invocation, entry) do
      {:ok, prepared_receipt} ->
        ReceiptCoordinator.commit_run(
          projected,
          selected,
          {:inference_selected, invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        RunExecution.fail(%{data | state_lock: nil}, selected, reason)
    end
  end

  def resume_receipt(data, run, {:inference_selected, invocation, prepared, entry}) do
    data
    |> RunExecution.record_started_conversation(entry, run)
    |> dispatch_intent(run, invocation, prepared, entry)
  end

  def resume_receipt(
        data,
        run,
        {:inference_stream_restarted, invocation, prepared, entry}
      ) do
    data
    |> InferenceAttempt.publish(
      :stream_interrupted,
      invocation.inference_id,
      Map.get(run.inference_continuation.stream_recovery, :previous_invocation_id),
      hd(run.inference_continuation.previous_attempts),
      %{outcome: :resuming, successor_invocation_digest: id_digest(invocation.id)}
    )
    |> dispatch_intent(run, invocation, prepared, entry)
  end

  def resume_receipt(
        data,
        run,
        {:inference_attempt_started, invocation, prepared, entry, budget_snapshot}
      ),
      do: start_worker(data, run, invocation, prepared, entry, budget_snapshot)

  @doc false
  @spec resume_recovered_receipt(InstanceState.t(), ReceiptEnvelope.t()) :: InstanceState.t()
  def resume_recovered_receipt(
        data,
        %ReceiptEnvelope{
          kind: :inference_attempt_terminal,
          run_id: run_id,
          invocation_id: receipt_invocation_id
        }
      ) do
    case Map.get(data.runs, run_id) do
      %Run{
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{kind: :inference} = invocation,
        inference_continuation: %{last_response: %InferenceResponse{} = response}
      } = run ->
        opts =
          data
          |> RuntimeOptions.build(
            Inference.Descriptor.options(run.inference_continuation.descriptor),
            run.input
          )
          |> RuntimeOptions.pin_run(run)

        entry = %{
          run_id: run.id,
          operation: :advance,
          projection: :result,
          input: run.input,
          opts: opts,
          state_revision: data.state.revision,
          internal?: not Map.has_key?(data.callers, run.id),
          admitted?: false
        }

        resume_worker(data, run, %{invocation: invocation, entry: entry}, response)

      %Run{status: :failed, last_error: failure} = run ->
        complete_recovered_failure(data, run, receipt_invocation_id, failure)

      _already_applied_or_missing ->
        data
    end
  end

  def resume_recovered_receipt(
        data,
        %ReceiptEnvelope{
          kind: :inference_consumer_never_attached,
          run_id: run_id,
          invocation_id: invocation_id
        }
      ) do
    case Map.get(data.runs, run_id) do
      %Run{status: :failed, last_error: failure} = run ->
        complete_recovered_failure(data, run, invocation_id, failure)

      _already_applied_or_missing ->
        data
    end
  end

  def resume_recovered_receipt(data, _envelope), do: data

  defp complete_recovered_failure(data, run, invocation_id, failure) do
    data
    |> Map.put(:state_lock, nil)
    |> InferenceAttempt.notify_failed(invocation_id, failure)
    |> RunQueue.reply_caller(run.id, {:error, failure})
    |> Runs.record_terminal(run)
    |> RunQueue.schedule()
    |> Idle.arm()
  end

  @doc false
  def resume_worker(data, run, ownership, response) do
    invocation = ownership.invocation
    data = InferenceAttempt.notify_committed(data, invocation.id, response)

    entry =
      Map.merge(ownership.entry, %{
        operation: {:resume, {:inference, invocation, response}},
        state_revision: data.state.revision,
        admitted?: false
      })

    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()

    {pid, monitor} =
      RunExecution.spawn_advance_worker(owner, run, entry, dispatch_id, capability)

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
    |> Map.put(:active, active)
    |> Map.put(:state_lock, nil)
    |> Map.put(:workers, Map.put(data.workers, pid, active))
    |> Idle.disarm()
  end

  @doc false
  def resume_boundary(data, run, ownership, {:success, response}) do
    data =
      InferenceAttempt.publish(
        data,
        :terminal_committed,
        ownership.invocation.inference_id,
        ownership.invocation.id,
        ownership.invocation,
        %{outcome: :completed}
      )

    resume_worker(data, run, ownership, response)
  end

  def resume_boundary(data, run, ownership, {:retry, reason}) do
    data =
      InferenceAttempt.publish(
        data,
        InferenceAttempt.failure_event_type(reason),
        ownership.invocation.inference_id,
        ownership.invocation.id,
        ownership.invocation,
        %{outcome: :failed, retrying?: true, reason_class: reason_class(reason)}
      )

    retry(data, run, ownership, reason)
  end

  def resume_boundary(data, run, ownership, {:failure, failure}) do
    data
    |> InferenceAttempt.publish(
      InferenceAttempt.failure_event_type(failure),
      ownership.invocation.inference_id,
      ownership.invocation.id,
      ownership.invocation,
      %{outcome: :failed, reason_class: reason_class(failure)}
    )
    |> Map.put(:state_lock, nil)
    |> InferenceAttempt.notify_failed(ownership.invocation.id, failure)
    |> RunQueue.reply_caller(run.id, {:error, failure})
    |> Runs.record_terminal(run)
    |> RunQueue.schedule()
    |> Idle.arm()
  end

  @doc false
  def retry(data, run, ownership, previous_reason) do
    continuation = run.inference_continuation
    attempt = continuation.attempt + 1

    entry =
      case Map.get(ownership, :entry) do
        %{opts: _opts} = entry ->
          Map.merge(entry, %{
            state_revision: data.state.revision,
            admitted?: false,
            recovered?: Map.get(entry, :recovered?, false)
          })

        _missing ->
          opts =
            data
            |> RuntimeOptions.build(
              Spectre.Inference.Descriptor.options(continuation.descriptor),
              run.input
            )
            |> RuntimeOptions.pin_run(run)

          RuntimeRecovery.inference_entry(data, run, opts)
      end

    retry_opts = Keyword.put(entry.opts, :inference_previous_errors, [previous_reason])
    entry = %{entry | opts: retry_opts}

    case Inference.prepare_attempt(
           data.agent,
           continuation.descriptor,
           attempt,
           run.input,
           data.state,
           retry_opts
         ) do
      {:ok, %PreparedInference{} = prepared} ->
        successor = build_retry_successor(run, continuation, prepared, attempt, previous_reason)
        invocation = successor.waiting
        selected = mark_selection_receipted(successor)
        retained = Runs.put_run(data, selected)

        case prepare_selection_receipt(retained, selected, invocation, entry) do
          {:ok, prepared_receipt} ->
            ReceiptCoordinator.commit_run(
              retained,
              selected,
              {:inference_selected, invocation, prepared, entry},
              prepared_receipt
            )

          {:error, reason} ->
            finalize_inference_retry_failure(data, run, attempt, reason)
        end

      {:error, reason} ->
        finalize_inference_retry_failure(data, run, attempt, reason)
    end
  end

  defp build_retry_successor(run, continuation, prepared, attempt, previous_reason) do
    recoverable? =
      continuation.recoverable? and not is_function(prepared.selection.model) and
        match?(:ok, Value.validate(prepared.selection.model))

    next_continuation = %{
      continuation
      | descriptor: prepared.descriptor,
        frozen_selection: prepared.frozen_selection,
        invocation: nil,
        stream_epoch: nil,
        attempt: attempt,
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
        recovery: %{
          status: :retry_selected,
          previous_reason: portable_failure(previous_reason)
        },
        last_response: nil,
        recoverable?: recoverable?
    }

    successor = %{
      run
      | revision: run.revision + 1,
        step_id: Value.token("inference-retry-step", {run.id, attempt}),
        waiting: nil,
        inference_continuation: next_continuation,
        last_error: nil
    }

    invocation = Invocation.from_inference(successor, next_continuation, streaming?: false)

    next_continuation = %{
      next_continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch
    }

    %{successor | waiting: invocation, inference_continuation: next_continuation}
  end

  defp finalize_inference_retry_failure(data, run, attempt, reason) do
    failure = {:inference_retry_selection_failed, attempt, portable_failure(reason)}
    failed = Runs.terminalize_failed_run(run, failure)
    retained = Runs.put_run(data, failed)

    case Commit.run_state(retained, data.state, failed) do
      {:ok, committed} ->
        committed
        |> Map.put(:state_lock, nil)
        |> RunQueue.reply_caller(run.id, {:error, failure})
        |> Runs.record_terminal(failed)
        |> RunQueue.schedule()
        |> Idle.arm()

      {:error, commit_reason} ->
        RunExecution.fail(%{data | state_lock: nil}, failed, commit_reason)
    end
  end

  @doc false
  def fail_attempt(data, ownership, receipt, reason) do
    # Provider errors may contain response bodies, credentials or request
    # identifiers. Only a bounded semantic class is allowed past this point.
    reason = portable_failure(reason)
    run = Map.fetch!(data.runs, ownership.run_id)

    settlement =
      if receipt.metadata[:remote_status] == :ambiguous, do: :ambiguous, else: :confirmed

    case InferenceBudget.settle(
           run.inference_continuation,
           ownership.invocation.attempt_id,
           receipt.usage,
           settlement
         ) do
      {:ok, continuation} ->
        if inference_retry_allowed?(run, continuation, ownership, reason, settlement) do
          commit_retryable_inference_failure(
            data,
            run,
            continuation,
            ownership,
            receipt,
            reason,
            settlement
          )
        else
          commit_terminal_inference_failure(
            data,
            run,
            continuation,
            ownership,
            receipt,
            reason
          )
        end

      {:error, continuation, settlement_reason} ->
        commit_budget_settlement_failure(
          data,
          run,
          continuation,
          ownership,
          receipt,
          settlement_reason
        )
    end
  end

  defp inference_retry_allowed?(run, continuation, ownership, reason, settlement) do
    retryable_reason? =
      reason != :consumer_never_attached and
        reason != :inference_deadline_exceeded and
        not match?({:cancelled, _reason}, reason) and
        not match?({:inference_budget_exceeded, _field}, reason)

    with true <- ownership.mode == :one_shot,
         true <- settlement == :confirmed,
         true <- retryable_reason?,
         false <- run.inference_continuation.descriptor.constraints.strict?,
         %{status: status} when status != :budget_settlement_failed <- continuation.recovery,
         {:ok, limit} <- InferenceBudget.attempt_limit(ownership.prepared, ownership.entry) do
      continuation.attempt < limit
    else
      _not_retryable -> false
    end
  end

  defp commit_retryable_inference_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         reason,
         settlement
       ) do
    attempt_record = %{
      attempt: continuation.attempt,
      attempt_id: ownership.invocation.attempt_id,
      invocation_id: ownership.invocation.id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      outcome: :failed,
      reason: portable_failure(reason),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :unknown),
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      settlement: settlement
    }

    retrying_continuation = %{
      continuation
      | provider_status: :terminal,
        previous_attempts: Enum.take([attempt_record | continuation.previous_attempts], 32),
        recovery: %{
          status: :retry_pending,
          reason: portable_failure(reason),
          next_attempt: continuation.attempt + 1
        },
        last_response: nil
    }

    retrying = %{run | inference_continuation: retrying_continuation}
    payload = failure_payload(receipt, reason)

    case Receipts.prepare_run(
           data,
           data.state,
           retrying,
           :inference_attempt_terminal,
           payload,
           receipt_opts(
             ownership.invocation,
             "spectre.inference.attempt-terminal/1"
           )
         ) do
      {:ok, prepared_receipt} ->
        commit_or_stage_inference_receipt(
          data,
          retrying,
          ownership,
          {:retry, portable_failure(reason)},
          prepared_receipt
        )

      {:error, commit_reason} ->
        RunExecution.fail(%{data | state_lock: nil}, retrying, commit_reason)
    end
  end

  defp commit_terminal_inference_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         reason
       ) do
    failure = {:inference_attempt_failed, run.inference_continuation.attempt, reason}

    failed =
      run
      |> Map.put(:inference_continuation, continuation)
      |> Runs.terminalize_failed_run(failure)
      |> put_terminal_metadata(continuation, ownership.invocation, receipt)

    payload = failure_payload(receipt, reason)

    kind =
      if reason == :consumer_never_attached,
        do: :inference_consumer_never_attached,
        else: :inference_attempt_terminal

    receipt_opts =
      receipt_opts(
        ownership.invocation,
        "spectre.inference.attempt-terminal/1"
      )

    case Receipts.prepare_run(data, data.state, failed, kind, payload, receipt_opts) do
      {:ok, prepared} ->
        commit_or_stage_inference_receipt(
          data,
          failed,
          ownership,
          {:failure, failure},
          prepared
        )

      {:error, commit_reason} ->
        RunExecution.fail(%{data | state_lock: nil}, failed, commit_reason)
    end
  end

  @doc false
  def failure_payload(receipt, reason) do
    %{
      outcome: failure_outcome(reason),
      reason: portable_failure(reason),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :unknown),
      control_command_digest: Map.get(receipt.metadata, :control_command_digest),
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }
  end

  defp commit_budget_settlement_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         settlement_reason
       ) do
    reason = {:inference_budget_settlement_failed, portable_failure(settlement_reason)}
    receipt = %{receipt | outcome: {:error, reason}}

    commit_terminal_inference_failure(
      data,
      run,
      continuation,
      ownership,
      receipt,
      reason
    )
  end

  @doc false
  def put_terminal_metadata(run, continuation, invocation, receipt) do
    terminal = %{
      inference_id: continuation.inference_id,
      invocation_id: invocation.id,
      attempt_id: invocation.attempt_id,
      control_revision: invocation.control_revision,
      stream_epoch: invocation.stream_epoch,
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      budget: continuation.budget
    }

    %{run | metadata: Map.put(run.metadata, :inference_terminal, terminal)}
  end

  defp failure_outcome(:consumer_never_attached), do: :cancelled_before_provider_start
  defp failure_outcome({:cancelled, _reason}), do: :cancelled
  defp failure_outcome(_reason), do: :failed

  defp portable_failure(reason) do
    InferenceFailure.sanitize(reason)
  end

  @doc false
  def provider_request_digest(nil), do: nil
  def provider_request_digest(value), do: Value.token("provider-request", value)

  @doc false
  def provider_cursor_digest(nil), do: nil
  def provider_cursor_digest(value), do: Value.token("provider", value)

  # Adapter response metadata has no core-owned schema and may duplicate raw
  # headers, provider request ids or credentials. Normalized fields live on
  # Response itself; untyped provider metadata therefore remains live-only.
  defp portable_response_metadata(_metadata), do: %{}

  defp commit_or_stage_inference_receipt(data, accepted, ownership, resume, prepared) do
    ReceiptCoordinator.commit_run(
      data,
      accepted,
      {:inference_terminal, ownership, resume},
      prepared
    )
  end

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

  defp emit(event, data, measurements, metadata),
    do: InstanceTelemetry.emit(event, data, measurements, metadata)

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)
  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)
end
