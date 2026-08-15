defmodule Spectre.Instance.ReceiptCoordinator do
  @moduledoc false

  # Owns the live side of receipt staging and delivery. Payload tasks, durable
  # outbox acknowledgements, retry timers, and boundary continuations all run
  # under the Instance owner's state. The sink work itself runs in supervised
  # tasks, while every result re-enters through the owner mailbox before it can
  # mutate canonical state or release provider work.

  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Events
  alias Spectre.Instance.Idle
  alias Spectre.Instance.InferenceCoordinator
  alias Spectre.Instance.InferenceStreamControl
  alias Spectre.Instance.Operations
  alias Spectre.Instance.ReceiptRecovery
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeRecovery
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Receipt.Envelope, as: ReceiptEnvelope
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Run

  @max_timer_delay 4_294_967_295

  @doc false
  @spec payload_staged(InstanceState.t(), String.t(), term()) ::
          {:noreply, InstanceState.t()}
  def payload_staged(data, token, result) do
    case Map.pop(data.receipt_staging, token) do
      {nil, _staging} ->
        {:noreply, data}

      {staging, remaining} ->
        Process.demonitor(staging.monitor, [:flush])
        data = %{data | receipt_staging: remaining}
        {:noreply, finish_payload_staging(data, staging, result)}
    end
  end

  defp finish_payload_staging(data, staging, {:ok, payload_ref}) do
    case Receipts.refresh(data, staging.prepared) do
      {:ok, %{envelope: envelope} = prepared} when envelope == staging.prepared.envelope ->
        retained = maybe_retain_staged_run(data, staging.run)

        case Receipts.commit(retained, prepared, :required, payload_ref) do
          {:ok, committed, envelope} ->
            committed
            |> Map.put(
              :receipt_resumes,
              Map.put(committed.receipt_resumes, envelope.id, staging.resume)
            )
            |> Checkpoint.force()
            |> start_deliveries()

          {:error, reason} ->
            fail_receipt_staging(data, staging, reason)
        end

      {:ok, refreshed} ->
        restage_required_receipt(data, staging, refreshed)

      {:error, reason} ->
        fail_receipt_staging(data, staging, reason)
    end
  end

  defp finish_payload_staging(data, staging, {:error, reason}) do
    fail_receipt_staging(data, staging, {:required_receipt_payload_failed, reason})
  end

  @doc false
  @spec delivery_result(InstanceState.t(), String.t(), term()) ::
          {:noreply, InstanceState.t()}
  def delivery_result(data, receipt_id, result) do
    case Map.pop(data.receipt_deliveries, receipt_id) do
      {nil, _deliveries} ->
        {:noreply, data}

      {delivery, remaining} ->
        Process.demonitor(delivery.monitor, [:flush])
        data = %{data | receipt_deliveries: remaining}
        {:noreply, apply_receipt_delivery_result(data, delivery, result)}
    end
  end

  @doc false
  @spec delivery_retry(InstanceState.t(), String.t()) :: {:noreply, InstanceState.t()}
  def delivery_retry(data, receipt_id) do
    {_timer, timers} = Map.pop(data.receipt_retry_timers, receipt_id)
    data = %{data | receipt_retry_timers: timers}

    next =
      if Map.has_key?(data.receipt_deliveries, receipt_id),
        do: data,
        else: maybe_start_receipt_delivery(data, receipt_id)

    {:noreply, next}
  end

  @doc false
  @spec task_down(InstanceState.t(), pid(), reference(), term()) ::
          InstanceState.t() | nil
  def task_down(data, pid, monitor, reason) do
    cond do
      staging = receipt_staging_by_pid(data, pid, monitor) ->
        receipt_staging_down(data, staging, reason)

      delivery = receipt_delivery_by_pid(data, pid, monitor) ->
        receipt_delivery_down(data, delivery, reason)

      true ->
        nil
    end
  end

  @doc false
  def prepare_authority(
        data,
        definition_ref,
        axis,
        value,
        lifecycle,
        writes,
        commit_opts
      ) do
    previous = Events.lifecycle(data, definition_ref)
    {manifest_digest, closure_digest} = receipt_definition_digests(data, definition_ref)

    payload = %{
      definition_ref: to_string(definition_ref),
      axis: axis,
      from: Map.fetch!(previous, axis),
      to: value,
      lifecycle_revision: lifecycle.revision,
      authority_epoch: lifecycle.authority_epoch,
      changed_at: lifecycle.changed_at
    }

    Receipts.prepare_sections(
      data,
      writes,
      :authority_decision,
      payload,
      correlation_id: Keyword.fetch!(commit_opts, :correlation_id),
      causation_id: Keyword.get(commit_opts, :causation_id),
      definition_ref: to_string(definition_ref),
      manifest_digest: manifest_digest,
      closure_digest: closure_digest,
      payload_schema_ref: "spectre.authority.decision/1",
      privacy: :internal
    )
  end

  defp receipt_definition_digests(
         %{activation: %Activation{definition_ref: definition_ref} = activation},
         definition_ref
       ),
       do: {activation.manifest_digest, activation.closure_digest}

  defp receipt_definition_digests(_data, _definition_ref), do: {nil, nil}

  @doc false
  @spec commit_run(InstanceState.t(), Run.t(), term(), Receipts.prepared()) ::
          InstanceState.t()
  def commit_run(%{receipt_mode: :required} = data, run, resume, prepared),
    do: start_required_receipt_staging(data, run, resume, prepared)

  def commit_run(%{receipt_mode: mode} = data, run, resume, prepared)
      when mode in [:disabled, :observational] do
    retained = Runs.put_run(data, run)

    case Receipts.commit(retained, prepared, mode) do
      {:ok, committed, envelope} ->
        committed
        |> maybe_start_observational_delivery(mode, envelope)
        |> resume_live_receipted_boundary(run, resume, envelope)

      {:error, reason} ->
        RunExecution.fail(%{data | state_lock: nil}, run, reason)
    end
  end

  @doc false
  @spec commit_sections(InstanceState.t(), term(), Receipts.prepared()) :: InstanceState.t()
  def commit_sections(%{receipt_mode: :required} = data, resume, prepared),
    do: start_required_sections_receipt_staging(data, resume, prepared)

  def commit_sections(%{receipt_mode: mode} = data, resume, prepared)
      when mode in [:disabled, :observational] do
    case Receipts.commit(data, prepared, mode) do
      {:ok, committed, envelope} ->
        committed
        |> maybe_start_observational_delivery(mode, envelope)
        |> resume_live_receipted_boundary(nil, resume, envelope)

      {:error, reason} ->
        fail_receipted_boundary(data, resume, reason)
    end
  end

  defp maybe_start_observational_delivery(data, :observational, envelope),
    do: start_observational_receipt_delivery(data, envelope)

  defp maybe_start_observational_delivery(data, :disabled, _envelope), do: data

  defp start_required_receipt_staging(data, run, resume, prepared) do
    do_start_required_receipt_staging(data, run, resume, prepared)
  end

  defp start_required_sections_receipt_staging(data, resume, prepared) do
    do_start_required_receipt_staging(data, nil, resume, prepared)
  end

  defp do_start_required_receipt_staging(data, run, resume, prepared, attempt \\ 0) do
    owner = self()
    token = Spectre.Identity.uuid7()
    sink = data.receipt_sink
    opts = receipt_sink_opts(data)

    callback = fn ->
      result = ReceiptSink.put_payload(sink, prepared.envelope, opts)
      send(owner, {:spectre, :receipt_payload_staged, token, result})
    end

    case Task.Supervisor.start_child(Spectre.Receipt.TaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        staging = %{
          token: token,
          pid: pid,
          monitor: monitor,
          run: run,
          resume: resume,
          prepared: prepared,
          attempt: attempt
        }

        data
        |> Map.put(
          :state_lock,
          data.state_lock ||
            %{
              run_id: run && run.id,
              receipt_id: prepared.envelope.id,
              receipt_kind: prepared.envelope.kind
            }
        )
        |> Map.put(:receipt_staging, Map.put(data.receipt_staging, token, staging))
        |> Idle.disarm()

      {:error, reason} ->
        fail_receipted_boundary(
          %{data | state_lock: nil},
          resume,
          {:receipt_payload_task_start_failed, reason},
          run
        )
    end
  end

  defp maybe_retain_staged_run(data, %Run{} = run), do: Runs.put_run(data, run)
  defp maybe_retain_staged_run(data, nil), do: data

  defp fail_receipt_staging(data, staging, reason) do
    fail_receipted_boundary(
      %{data | state_lock: nil},
      staging.resume,
      reason,
      staging.run
    )
  end

  defp restage_required_receipt(data, staging, prepared) do
    limit = Keyword.get(data.base_opts, :receipt_staging_rebase_limit, 16)

    if is_integer(limit) and limit > 0 and staging.attempt < limit do
      do_start_required_receipt_staging(
        data,
        staging.run,
        staging.resume,
        prepared,
        staging.attempt + 1
      )
    else
      fail_receipt_staging(data, staging, :required_receipt_staging_starved)
    end
  end

  defp fail_receipted_boundary(data, _resume, reason, %Run{} = run),
    do: RunExecution.fail(data, run, reason)

  defp fail_receipted_boundary(data, resume, reason, nil),
    do: fail_receipted_boundary(data, resume, reason)

  defp fail_receipted_boundary(data, {:authority_decision, from, _lifecycle}, reason) do
    GenServer.reply(from, {:error, reason})
    data |> Map.put(:state_lock, nil) |> Idle.arm()
  end

  defp start_observational_receipt_delivery(data, envelope) do
    start_receipt_delivery_task(data, envelope.id, %{envelope: envelope, mode: :observational})
  end

  @doc false
  @spec start_deliveries(InstanceState.t()) :: InstanceState.t()
  def start_deliveries(%{receipt_mode: :required} = data) do
    case Canonical.fetch(data.canonical, :receipt_outbox) do
      {:ok, %{entries: entries}} ->
        Enum.reduce(entries, data, &maybe_start_durable_delivery/2)

      {:error, _reason} ->
        data
    end
  end

  def start_deliveries(data), do: data

  defp maybe_start_durable_delivery(entry, data) do
    durable? = entry.inserted_revision <= data.checkpoint_revision
    available? = not Map.has_key?(data.receipt_deliveries, entry.id)

    if durable? and available?,
      do: start_receipt_delivery_task(data, entry.id, %{entry: entry, mode: :required}),
      else: data
  end

  defp maybe_start_receipt_delivery(%{receipt_mode: :required} = data, receipt_id) do
    with {:ok, %{entries: entries}} <- Canonical.fetch(data.canonical, :receipt_outbox),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.id == receipt_id)),
         true <- entry.inserted_revision <= data.checkpoint_revision do
      start_receipt_delivery_task(data, receipt_id, %{entry: entry, mode: :required})
    else
      _missing_or_not_durable -> data
    end
  end

  defp maybe_start_receipt_delivery(data, _receipt_id), do: data

  defp start_receipt_delivery_task(data, receipt_id, delivery) do
    owner = self()
    sink = data.receipt_sink
    opts = receipt_sink_opts(data)

    callback = fn ->
      result = deliver_receipt(sink, delivery, opts)
      send(owner, {:spectre, :receipt_delivery_result, receipt_id, result})
    end

    case Task.Supervisor.start_child(Spectre.Receipt.TaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        ownership = Map.merge(delivery, %{id: receipt_id, pid: pid, monitor: monitor})

        data
        |> clear_receipt_retry(receipt_id)
        |> Map.put(
          :receipt_deliveries,
          Map.put(data.receipt_deliveries, receipt_id, ownership)
        )
        |> Idle.disarm()

      {:error, reason} ->
        emit(
          :receipt_delivery_failed,
          data,
          %{count: 1},
          %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
        )

        if delivery.mode == :required do
          data
          |> mark_required_receipt_delivery_failure(receipt_id, reason)
          |> schedule_receipt_retry(receipt_id)
        else
          data
        end
    end
  end

  defp deliver_receipt(sink, %{mode: :observational, envelope: envelope}, opts) do
    case ReceiptSink.append(sink, envelope, opts) do
      {:ok, status} -> {:ok, status, envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_receipt(sink, %{mode: :required, entry: entry}, opts) do
    with {:ok, %ReceiptEnvelope{id: id} = envelope} <-
           ReceiptSink.get_payload(sink, entry.payload_ref, opts),
         true <- id == entry.id,
         true <- ReceiptEnvelope.digest(envelope) == entry.digest do
      case ReceiptSink.append(sink, envelope, opts) do
        {:ok, status} -> {:ok, status, envelope}
        {:error, reason} -> reconcile_receipt_append(sink, envelope, reason, opts)
      end
    else
      :not_found -> {:error, :required_receipt_payload_missing}
      false -> {:error, :required_receipt_payload_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_receipt_append(sink, envelope, append_reason, opts) do
    case ReceiptSink.lookup(sink, envelope.id, opts) do
      {:ok, ^envelope} -> {:ok, :idempotent, envelope}
      {:ok, _different} -> {:error, :receipt_append_reconciliation_conflict}
      :not_found -> {:error, append_reason}
      {:error, reason} -> {:error, {:receipt_append_reconciliation_failed, reason}}
    end
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :observational, id: receipt_id},
         result
       ) do
    outcome = if match?({:ok, _, _}, result), do: :ok, else: :error

    emit(
      :receipt_observed,
      data,
      %{count: 1},
      %{receipt_id: id_digest(receipt_id), outcome: outcome}
    )

    data
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :required, id: receipt_id, entry: entry},
         {:ok, _status, %ReceiptEnvelope{} = envelope}
       ) do
    {resume, remaining_resumes} = Map.pop(data.receipt_resumes, receipt_id)

    with :ok <- ReceiptRecovery.validate(data, entry, envelope),
         {:ok, writes, resume} <- prepare_required_receipt_ack(data, envelope, resume),
         {:ok, committed} <- Receipts.acknowledge(data, receipt_id, writes) do
      committed =
        committed
        |> clear_receipt_retry(receipt_id)
        |> Map.put(:receipt_resumes, remaining_resumes)

      committed
      |> continue_required_receipted_boundary(envelope, resume)
      |> maybe_complete_receipt_recovery()
      |> start_deliveries()
    else
      {:error, reason} ->
        emit(
          :receipt_delivery_failed,
          data,
          %{count: 1},
          %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
        )

        data
        |> mark_required_receipt_delivery_failure(receipt_id, reason)
        |> schedule_receipt_retry(receipt_id)
    end
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :required, id: receipt_id},
         {:error, reason}
       ) do
    emit(
      :receipt_delivery_failed,
      data,
      %{count: 1},
      %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
    )

    data
    |> mark_required_receipt_delivery_failure(receipt_id, reason)
    |> schedule_receipt_retry(receipt_id)
  end

  defp prepare_required_receipt_ack(
         data,
         %ReceiptEnvelope{kind: :inference_attempt_started, run_id: run_id},
         resume
       ) do
    with %Run{inference_continuation: continuation} = run <- Map.get(data.runs, run_id),
         {:ok, token, resume} <- required_stream_token(continuation, resume),
         next_continuation <- %{
           continuation
           | consumer_token_digest:
               if(is_binary(token), do: InferenceStreamControl.token_digest(token), else: nil),
             recovery: %{status: :provider_dispatch_released}
         },
         next_run <- %{run | inference_continuation: next_continuation},
         {:ok, writes} <- Commit.run_writes(data, data.state, next_run) do
      {:ok, writes, resume}
    else
      nil -> {:error, :required_receipt_run_missing}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_required_receipt_ack(_data, _envelope, resume),
    do: {:ok, %{}, resume}

  defp required_stream_token(
         %{invocation: %{metadata: %{streaming?: true}}},
         {:inference_attempt_started, invocation, prepared, entry, budget_snapshot}
       ) do
    token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())
    entry = Map.put(entry, :stream_consumer_token, token)

    {:ok, token, {:inference_attempt_started, invocation, prepared, entry, budget_snapshot}}
  end

  defp required_stream_token(%{invocation: %{metadata: %{streaming?: true}}}, nil) do
    token = Spectre.Identity.uuid7()
    {:ok, token, {:recover_inference_attempt_started, token}}
  end

  defp required_stream_token(_continuation, nil),
    do: {:ok, nil, {:recover_inference_attempt_started, nil}}

  defp required_stream_token(_continuation, resume), do: {:ok, nil, resume}

  defp continue_required_receipted_boundary(
         data,
         %ReceiptEnvelope{kind: :inference_attempt_started} = envelope,
         resume
       ) do
    revision = data.canonical.revision
    action = {envelope, resume}
    actions = Map.update(data.durability_resumes, revision, [action], &[action | &1])

    data
    |> Map.put(:durability_resumes, actions)
    |> Checkpoint.force()
  end

  defp continue_required_receipted_boundary(data, envelope, resume),
    do: resume_required_receipted_boundary(data, envelope, resume)

  # Receipt delivery is the durable gate for a non-deterministic boundary. The
  # continuation is intentionally kept outside canonical state while the
  # process is alive; after recovery it is reconstructed from the envelope and
  # the committed Run by `resume_receipted_boundary/2` instead.
  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_terminal, _ownership, _outcome} = resume,
         _envelope
       ) do
    InferenceCoordinator.resume_receipt(data, run, resume)
  end

  defp resume_live_receipted_boundary(
         data,
         _run,
         {:committed_step, outcome, entry, previous},
         _envelope
       ) do
    data
    |> Map.put(:state_lock, nil)
    |> RunExecution.finish_committed_step(outcome, entry, previous)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:run_input_admitted, entry},
         _envelope
       ) do
    # Admission has already reserved the Run and its caller before the receipt
    # commit.  The general enqueue guard treats that caller as active, so this
    # continuation must enter the ready queue directly after the durable gate.
    # An unrelated Run may still own the global state lock; only release the
    # receipt lock created for this admission.
    data
    |> release_admission_receipt_lock(run.id)
    |> RunQueue.enqueue_continuation(entry, false)
  end

  defp resume_live_receipted_boundary(
         data,
         _run,
         {:authority_decision, from, lifecycle},
         _envelope
       ) do
    GenServer.reply(from, {:ok, lifecycle})
    data |> Map.put(:state_lock, nil) |> Idle.arm()
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_superseded, _invocation, _prepared, _entry} = resume,
         _envelope
       ) do
    InferenceCoordinator.resume_receipt(data, run, resume)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_selected, _invocation, _prepared, _entry} = resume,
         _envelope
       ) do
    InferenceCoordinator.resume_receipt(data, run, resume)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_stream_restarted, _invocation, _prepared, _entry} = resume,
         _envelope
       ) do
    InferenceCoordinator.resume_receipt(data, run, resume)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_attempt_started, _invocation, _prepared, _entry, _budget_snapshot} = resume,
         _envelope
       ) do
    InferenceCoordinator.resume_receipt(data, run, resume)
  end

  defp release_admission_receipt_lock(
         %{state_lock: %{run_id: run_id, receipt_kind: :run_input_admitted}} = data,
         run_id
       ),
       do: %{data | state_lock: nil}

  defp release_admission_receipt_lock(data, _run_id), do: data

  defp resume_required_receipted_boundary(
         %{receipt_recovery_deferred: true} = data,
         _envelope,
         _resume
       ),
       do: data

  defp resume_required_receipted_boundary(data, envelope, nil),
    do: resume_receipted_boundary(data, envelope)

  defp resume_required_receipted_boundary(data, envelope, resume) do
    run = if envelope.run_id, do: Map.get(data.runs, envelope.run_id)
    resume_live_receipted_boundary(data, run, resume, envelope)
  end

  # Provider work is released only after the receipt acknowledgement marker
  # itself is durable. A crash before this callback restores the outbox; a
  # crash after it restores `:provider_dispatch_released` and is reconciled as
  # an uncertain external dispatch instead of being repeated blindly.
  @doc false
  @spec resume_durable(InstanceState.t(), non_neg_integer()) :: InstanceState.t()
  def resume_durable(data, persisted_revision) do
    {ready, pending} =
      Enum.split_with(data.durability_resumes, fn {revision, _actions} ->
        revision <= persisted_revision
      end)

    data = %{data | durability_resumes: Map.new(pending)}

    ready
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(data, fn {_revision, actions}, acc ->
      actions
      |> Enum.reverse()
      |> Enum.reduce(acc, fn {envelope, resume}, next ->
        resume_durable_boundary(next, envelope, resume)
      end)
    end)
  end

  defp resume_durable_boundary(data, envelope, {:recover_inference_attempt_started, token}) do
    data
    |> recover_receipted_inference_attempt(envelope, token)
    |> maybe_complete_receipt_recovery()
  end

  defp resume_durable_boundary(data, envelope, resume) do
    run = if envelope.run_id, do: Map.get(data.runs, envelope.run_id)
    next = resume_live_receipted_boundary(data, run, resume, envelope)

    maybe_complete_receipt_recovery(next)
  end

  defp recover_receipted_inference_attempt(data, envelope, consumer_token),
    do: RuntimeRecovery.recover_receipted_inference_attempt(data, envelope, consumer_token)

  defp maybe_complete_receipt_recovery(%{receipt_recovery_deferred: true} = data) do
    case Canonical.fetch(data.canonical, :receipt_outbox) do
      {:ok, %{entries: []}} when map_size(data.durability_resumes) > 0 ->
        data

      {:ok, %{entries: []}} ->
        candidate = %{data | receipt_recovery_deferred: false, state_lock: nil}

        case RuntimeRecovery.recover(candidate) do
          {:ok, recovered} ->
            recovered
            |> RunQueue.schedule()
            |> Operations.schedule()

          {:error, reason} ->
            emit(
              :receipt_recovery_failed,
              candidate,
              %{count: 1},
              %{reason_class: reason_class(reason)}
            )

            %{
              candidate
              | checkpoint_error: {:required_receipt_recovery_failed, reason},
                state_lock: %{receipt_recovery_failed: true}
            }
        end

      _pending_or_invalid ->
        data
    end
  end

  defp maybe_complete_receipt_recovery(data), do: data

  defp resume_receipted_boundary(data, envelope),
    do: InferenceCoordinator.resume_recovered_receipt(data, envelope)

  defp schedule_receipt_retry(data, receipt_id) do
    if Map.has_key?(data.receipt_retry_timers, receipt_id) do
      data
    else
      delay = positive_timeout(data.base_opts, :receipt_retry_interval, 1_000)
      timer = Process.send_after(self(), {:spectre, :receipt_delivery_retry, receipt_id}, delay)

      %{data | receipt_retry_timers: Map.put(data.receipt_retry_timers, receipt_id, timer)}
    end
  end

  defp clear_receipt_retry(data, receipt_id) do
    case Map.pop(data.receipt_retry_timers, receipt_id) do
      {nil, timers} ->
        %{data | receipt_retry_timers: timers}

      {timer, timers} ->
        _cancelled = Process.cancel_timer(timer)
        %{data | receipt_retry_timers: timers}
    end
  end

  defp positive_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> min(value, @max_timer_delay)
      _invalid -> default
    end
  end

  defp receipt_staging_by_pid(data, pid, monitor) do
    Enum.find_value(data.receipt_staging, fn {_token, staging} ->
      if staging.pid == pid and staging.monitor == monitor, do: staging
    end)
  end

  defp receipt_delivery_by_pid(data, pid, monitor) do
    Enum.find_value(data.receipt_deliveries, fn {_id, delivery} ->
      if delivery.pid == pid and delivery.monitor == monitor, do: delivery
    end)
  end

  defp receipt_staging_down(data, _staging, :normal), do: data

  defp receipt_staging_down(data, staging, reason) do
    remaining = Map.delete(data.receipt_staging, staging.token)
    failure = {:required_receipt_payload_task_down, reason}

    fail_receipt_staging(
      %{data | receipt_staging: remaining, state_lock: nil},
      staging,
      failure
    )
  end

  defp receipt_delivery_down(data, _delivery, :normal), do: data

  defp receipt_delivery_down(data, delivery, reason) do
    remaining = Map.delete(data.receipt_deliveries, delivery.id)
    data = %{data | receipt_deliveries: remaining}

    if delivery.mode == :required do
      emit(
        :receipt_delivery_failed,
        data,
        %{count: 1},
        %{receipt_id: id_digest(delivery.id), reason_class: reason_class(reason)}
      )

      data
      |> mark_required_receipt_delivery_failure(delivery.id, reason)
      |> schedule_receipt_retry(delivery.id)
    else
      data
    end
  end

  defp receipt_sink_opts(data) do
    [
      instance_ref: data.ref,
      owner_fencing_token: data.owner_lease.fencing_token
    ]
  end

  defp mark_required_receipt_delivery_failure(data, receipt_id, reason) do
    case Receipts.mark_delivery_failure(data, receipt_id, reason_class(reason)) do
      {:ok, committed} -> committed
      {:error, _reason} -> data
    end
  end

  defp emit(event, data, measurements, metadata),
    do: InstanceTelemetry.emit(event, data, measurements, metadata)

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)
  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)
end
