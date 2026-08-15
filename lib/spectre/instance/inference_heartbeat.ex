defmodule Spectre.Instance.InferenceHeartbeat do
  @moduledoc false

  # Internal control-lane pipeline for stream liveness. Validation, throttled
  # canonical writes, and post-commit observer publication live together so a
  # caller cannot publish progress that was not first committed.

  alias Spectre.Inference.Event
  alias Spectre.Inference.Events
  alias Spectre.Inference.Progress
  alias Spectre.Inference.StreamCheckpoint
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Runs
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry
  alias Spectre.Invocation
  alias Spectre.Run
  alias Spectre.Run.Value

  @doc false
  @spec accept(InstanceState.t(), String.t(), Progress.t(), StreamCheckpoint.t() | nil) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def accept(%InstanceState{} = data, invocation_id, %Progress{} = progress, checkpoint)
      when is_binary(invocation_id) do
    with :ok <- validate(data, invocation_id, progress, checkpoint) do
      now = System.monotonic_time(:millisecond)

      liveness = %{
        at: now,
        sequence: progress.sequence,
        state: progress.state,
        usage: progress.usage,
        output_bytes: progress.output_bytes
      }

      data = %{
        data
        | inference_liveness_clock:
            Map.put(data.inference_liveness_clock, invocation_id, liveness)
      }

      {:ok, maybe_commit(data, progress, checkpoint, now)}
    end
  end

  defp validate(data, invocation_id, progress, checkpoint) do
    ownership = Map.get(data.stream_sessions, invocation_id)
    invocation = Map.get(data.invocations, invocation_id)
    previous = Map.get(data.inference_liveness_clock, invocation_id)

    with :ok <- validate_known(ownership, invocation),
         :ok <- validate_ownership(ownership, invocation),
         :ok <- validate_identity(ownership, invocation_id, progress),
         :ok <- validate_dispatch_fence(ownership, progress),
         :ok <- validate_control_fence(ownership, progress),
         :ok <- validate_sequence(previous, progress),
         :ok <- Progress.validate(progress) do
      validate_checkpoint(progress, checkpoint)
    end
  end

  defp validate_known(nil, _invocation), do: {:error, :unknown_inference_stream}
  defp validate_known(_ownership, nil), do: {:error, :unknown_inference_stream}
  defp validate_known(_ownership, _invocation), do: :ok

  defp validate_ownership(ownership, ownership), do: :ok

  defp validate_ownership(_ownership, _invocation),
    do: {:error, :inference_heartbeat_ownership_mismatch}

  defp validate_identity(ownership, invocation_id, progress) do
    if progress.invocation_id == invocation_id and
         progress.inference_id == ownership.invocation.inference_id and
         progress.attempt_id == ownership.invocation.attempt_id,
       do: :ok,
       else: {:error, :inference_heartbeat_identity_mismatch}
  end

  defp validate_dispatch_fence(ownership, progress) do
    if progress.run_revision == ownership.run_revision and
         progress.generation == ownership.generation and
         progress.dispatch_id == ownership.dispatch_id,
       do: :ok,
       else: {:error, :inference_heartbeat_dispatch_fence_mismatch}
  end

  defp validate_control_fence(ownership, progress) do
    if progress.control_revision == ownership.invocation.control_revision and
         progress.stream_epoch == ownership.invocation.stream_epoch,
       do: :ok,
       else: {:error, :inference_heartbeat_control_fence_mismatch}
  end

  defp validate_sequence(previous, progress)
       when is_map(previous) and progress.sequence < previous.sequence,
       do: {:error, :inference_heartbeat_sequence_regressed}

  defp validate_sequence(_previous, _progress), do: :ok

  defp validate_checkpoint(_progress, nil), do: :ok

  defp validate_checkpoint(progress, %StreamCheckpoint{} = checkpoint) do
    with :ok <- StreamCheckpoint.validate(checkpoint),
         true <- checkpoint.provider_request_digest == progress.provider_request_digest,
         true <- checkpoint.resume_cursor_digest == progress.provider_cursor_digest,
         true <- checkpoint.usage == progress.usage,
         true <- checkpoint.usage_quality == progress.usage_quality,
         true <- checkpoint.output_bytes == progress.output_bytes do
      :ok
    else
      false -> {:error, :inference_stream_checkpoint_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_checkpoint(_progress, _checkpoint),
    do: {:error, :invalid_inference_stream_checkpoint}

  defp maybe_commit(data, progress, checkpoint, now) do
    checkpoint? = checkpoint_commit_due?(data, progress, checkpoint, now)
    progress? = progress_commit_due?(data, progress, now)

    if checkpoint? or progress? do
      commit(data, progress, checkpoint, now, checkpoint?, progress?)
    else
      data
    end
  end

  defp checkpoint_commit_due?(data, progress, %StreamCheckpoint{} = checkpoint, now) do
    interval = Keyword.get(data.base_opts, :inference_stream_checkpoint_interval, 5_000)
    last = Map.get(data.inference_checkpoint_clock, progress.invocation_id)

    StreamCheckpoint.meaningful?(checkpoint) and interval_due?(last, now, interval) and
      checkpoint_changed?(data, progress.invocation_id, checkpoint)
  end

  defp checkpoint_commit_due?(_data, _progress, _checkpoint, _now), do: false

  defp progress_commit_due?(data, progress, now) do
    enabled? = Keyword.get(data.base_opts, :inference_observer_lane, false)
    interval = Keyword.get(data.base_opts, :inference_progress_commit_interval, 5_000)
    last = Map.get(data.inference_progress_commit_clock, progress.invocation_id)

    enabled? and interval_due?(last, now, interval)
  end

  # Monotonic clocks may have any origin, including a negative one. `nil` is
  # the only safe sentinel for the first periodic commit.
  defp interval_due?(nil, _now, _interval), do: true
  defp interval_due?(last, now, interval), do: now - last >= interval

  defp checkpoint_changed?(data, invocation_id, checkpoint) do
    with %{run_id: run_id} <- Map.get(data.stream_sessions, invocation_id),
         %Run{inference_continuation: continuation} <- Map.get(data.runs, run_id) do
      continuation.provider_request_digest != checkpoint.provider_request_digest or
        cursor_digest(continuation.resume_cursor) != checkpoint.resume_cursor_digest or
        continuation.stream_provider_sequence != checkpoint.provider_sequence or
        continuation.stream_usage != checkpoint.usage or
        continuation.stream_usage_quality != checkpoint.usage_quality or
        continuation.stream_output_bytes != checkpoint.output_bytes
    else
      _missing -> false
    end
  end

  defp commit(data, progress, checkpoint, now, checkpoint?, progress?) do
    revision = data.canonical.revision + 1

    with {:ok, writes, run} <-
           checkpoint_writes(data, progress, checkpoint, checkpoint?, progress?, revision),
         {:ok, committed} <-
           Commit.canonical_sections(data, writes,
             correlation_id: progress.inference_id,
             causation_id: progress.invocation_id,
             provenance: %{source: :inference_checkpoint, invocation_id: progress.invocation_id},
             metadata: %{
               transition: :inference_checkpoint_committed,
               progress: progress?,
               recovery_cursor: checkpoint?
             }
           ) do
      committed = if run, do: Runs.put_run(committed, run), else: committed
      committed = update_clocks(committed, progress, now, checkpoint?, progress?)

      if progress? do
        publish(committed, %{progress | canonical_revision: revision})
      else
        committed
      end
    else
      {:error, reason} ->
        Telemetry.emit(
          :inference_progress_commit_failed,
          data,
          %{count: 1},
          %{reason_class: Telemetry.reason_class(reason)}
        )

        data
    end
  end

  defp checkpoint_writes(data, progress, checkpoint, checkpoint?, progress?, revision) do
    with {:ok, writes, run} <- maybe_put_checkpoint(data, progress, checkpoint, checkpoint?),
         {:ok, writes} <- maybe_put_progress(data, writes, progress, progress?, revision) do
      {:ok, writes, run}
    end
  end

  defp maybe_put_checkpoint(data, progress, checkpoint, true) do
    with %{run_id: run_id} <- Map.get(data.stream_sessions, progress.invocation_id),
         %Run{
           inference_continuation: %{invocation: %Invocation{id: invocation_id}} = continuation
         } = run <- Map.get(data.runs, run_id),
         true <- invocation_id == progress.invocation_id,
         next_continuation <- %{
           continuation
           | provider_status: :streaming,
             provider_request_id: checkpoint.provider_request_id,
             provider_request_digest: checkpoint.provider_request_digest,
             resume_cursor: checkpoint.resume_cursor,
             stream_provider_sequence: checkpoint.provider_sequence,
             stream_usage: checkpoint.usage,
             stream_usage_quality: checkpoint.usage_quality,
             stream_output_bytes: checkpoint.output_bytes,
             recovery: %{status: :stream_checkpointed}
         },
         next_run <- %{run | inference_continuation: next_continuation},
         {:ok, writes} <- Commit.run_writes(data, data.state, next_run) do
      {:ok, writes, next_run}
    else
      false -> {:error, :stale_inference_stream_checkpoint}
      nil -> {:error, :missing_inference_stream_checkpoint_owner}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_checkpoint(_data, _progress, _checkpoint, false),
    do: {:ok, %{}, nil}

  defp maybe_put_progress(data, writes, progress, true, revision) do
    with {:ok, snapshots} <- Canonical.fetch(data.canonical, :inference_progress) do
      committed_progress = %{progress | canonical_revision: revision}
      limit = Keyword.get(data.base_opts, :inference_progress_limit, 256)

      snapshots =
        snapshots
        |> Map.put(progress.inference_id, committed_progress)
        |> Enum.sort_by(fn {_id, snapshot} -> snapshot.at end, :desc)
        |> Enum.take(limit)
        |> Map.new()

      {:ok, Map.put(writes, :inference_progress, snapshots)}
    end
  end

  defp maybe_put_progress(_data, writes, _progress, false, _revision),
    do: {:ok, writes}

  defp update_clocks(data, progress, now, checkpoint?, progress?) do
    data =
      if checkpoint? do
        %{
          data
          | inference_checkpoint_clock:
              Map.put(data.inference_checkpoint_clock, progress.invocation_id, now)
        }
      else
        data
      end

    if progress? do
      %{
        data
        | inference_progress_commit_clock:
            Map.put(data.inference_progress_commit_clock, progress.invocation_id, now)
      }
    else
      data
    end
  end

  defp publish(data, committed_progress) do
    event =
      Event.new(:progress_committed, committed_progress,
        instance_key: data.ref.key,
        canonical_revision: committed_progress.canonical_revision
      )

    _ = Events.publish(data.ref, event)
    data
  end

  defp cursor_digest(nil), do: nil
  defp cursor_digest(value), do: Value.token("provider", value)
end
