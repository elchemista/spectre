defmodule Spectre.Instance.Receipts do
  @moduledoc false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Receipt.Envelope
  alias Spectre.Receipt.OutboxEntry
  alias Spectre.Run
  alias Spectre.State

  defstruct [:envelope, :writes, base_sections: %{}]

  @type prepared :: %__MODULE__{
          envelope: Envelope.t(),
          writes: map(),
          base_sections: map()
        }

  @spec prepare_run(InstanceState.t(), State.t(), Run.t(), atom(), term(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_run(%InstanceState{} = data, %State{} = state, %Run{} = run, kind, payload, opts) do
    opts =
      opts
      |> Keyword.put_new(:run_id, run.id)
      |> Keyword.put_new(:run_revision, run.revision)
      |> Keyword.put_new(:correlation_id, run.id)
      |> Keyword.put_new(:causation_id, run.trace_id)
      |> Keyword.put_new(:definition_ref, to_string(run.definition_ref))
      |> Keyword.put_new(:manifest_digest, run_manifest_digest(data, run))
      |> Keyword.put_new(:closure_digest, run.closure_digest)

    with {:ok, writes} <- Commit.run_writes(data, state, run) do
      prepare_sections(data, writes, kind, payload, opts)
    end
  end

  @doc false
  @spec prepare_sections(InstanceState.t(), map(), atom(), term(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare_sections(%InstanceState{} = data, writes, kind, payload, opts)
      when is_map(writes) and not is_struct(writes) and is_list(opts) do
    writes = Commit.prepare_writes(data, writes)

    with {:ok, base_sections} <- capture_base_sections(data, writes),
         {:ok, %{root: pre_digest}} <- Canonical.state_digest(data.canonical),
         {:ok, %{root: post_digest}} <- Canonical.preview_state_digest(data.canonical, writes),
         {:ok, envelope} <-
           Envelope.new(
             kind: kind,
             instance_ref: data.ref.key,
             run_id: Keyword.get(opts, :run_id),
             run_revision: Keyword.get(opts, :run_revision),
             inference_id: Keyword.get(opts, :inference_id),
             invocation_id: Keyword.get(opts, :invocation_id),
             attempt_id: Keyword.get(opts, :attempt_id),
             control_revision: Keyword.get(opts, :control_revision),
             stream_epoch: Keyword.get(opts, :stream_epoch),
             canonical_revision: data.canonical.revision + 1,
             correlation_id: Keyword.fetch!(opts, :correlation_id),
             causation_id: Keyword.get(opts, :causation_id),
             definition_ref: Keyword.get(opts, :definition_ref),
             manifest_digest: Keyword.get(opts, :manifest_digest),
             closure_digest: Keyword.get(opts, :closure_digest),
             pre_state_digest: pre_digest,
             post_state_digest: post_digest,
             payload_schema_ref: Keyword.fetch!(opts, :payload_schema_ref),
             payload: payload,
             privacy: Keyword.get(opts, :privacy, :confidential),
             recorded_at: data.canonical.revision + 1,
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      {:ok, %__MODULE__{envelope: envelope, writes: writes, base_sections: base_sections}}
    end
  end

  @doc false
  @spec refresh(InstanceState.t(), prepared()) :: {:ok, prepared()} | {:error, term()}
  def refresh(%InstanceState{} = data, %__MODULE__{} = prepared) do
    # Required delivery stages the content-addressed payload outside the
    # Instance mailbox. Unrelated canonical work may advance the state root in
    # that interval, so the envelope must be re-fenced immediately before its
    # outbox entry is committed. Aggregate maps are rebased by boundary key to
    # avoid overwriting unrelated Runs or Definition lifecycles.
    with {:ok, writes} <- refresh_writes(data, prepared),
         {:ok, base_sections} <- capture_base_sections(data, writes),
         {:ok, %{root: pre_digest}} <- Canonical.state_digest(data.canonical),
         {:ok, %{root: post_digest}} <- Canonical.preview_state_digest(data.canonical, writes),
         {:ok, envelope} <-
           prepared.envelope
           |> Map.from_struct()
           |> Map.merge(%{
             id: nil,
             canonical_revision: data.canonical.revision + 1,
             pre_state_digest: pre_digest,
             post_state_digest: post_digest,
             recorded_at: data.canonical.revision + 1
           })
           |> Envelope.new() do
      {:ok,
       %__MODULE__{
         prepared
         | envelope: envelope,
           writes: writes,
           base_sections: base_sections
       }}
    end
  end

  @spec commit(
          InstanceState.t(),
          prepared(),
          :disabled | :observational | :required,
          String.t() | nil
        ) ::
          {:ok, InstanceState.t(), Envelope.t()} | {:error, term()}
  def commit(data, %__MODULE__{} = prepared, mode, payload_ref \\ nil) do
    with {:ok, writes} <- maybe_put_outbox(data, prepared, mode, payload_ref),
         {:ok, committed} <-
           Commit.canonical_sections(data, writes,
             correlation_id: prepared.envelope.correlation_id,
             causation_id: prepared.envelope.causation_id,
             provenance: %{source: :receipt, receipt_id: prepared.envelope.id},
             metadata: %{
               transition: :receipted_boundary_committed,
               receipt_kind: prepared.envelope.kind
             }
           ),
         :ok <- verify_post_digest(committed, prepared.envelope) do
      {:ok, committed, prepared.envelope}
    end
  end

  @spec acknowledge(InstanceState.t(), String.t(), map()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def acknowledge(%InstanceState{} = data, receipt_id, writes \\ %{})
      when is_map(writes) and not is_struct(writes) do
    with {:ok, outbox} <- Canonical.fetch(data.canonical, :receipt_outbox) do
      entries = Enum.reject(outbox.entries, &(&1.id == receipt_id))
      ids = Map.delete(outbox.ids, receipt_id)

      writes =
        Map.put(writes, :receipt_outbox, %{entries: entries, ids: ids})

      Commit.canonical_sections(data, writes,
        correlation_id: receipt_id,
        causation_id: receipt_id,
        provenance: %{source: :receipt_delivery, receipt_id: receipt_id},
        metadata: %{transition: :receipt_delivery_acknowledged}
      )
    end
  end

  @doc false
  @spec mark_delivery_failure(InstanceState.t(), String.t(), atom()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def mark_delivery_failure(%InstanceState{} = data, receipt_id, reason_class)
      when is_binary(receipt_id) and is_atom(reason_class) do
    with {:ok, outbox} <- Canonical.fetch(data.canonical, :receipt_outbox),
         {entry, index} when not is_nil(entry) <-
           outbox.entries
           |> Enum.with_index()
           |> Enum.find(fn {entry, _index} -> entry.id == receipt_id end) do
      updated = %{
        entry
        | status: :ambiguous,
          attempts: entry.attempts + 1,
          last_error_class: reason_class
      }

      entries = List.replace_at(outbox.entries, index, updated)

      Commit.canonical_sections(data, %{receipt_outbox: %{outbox | entries: entries}},
        correlation_id: receipt_id,
        causation_id: receipt_id,
        provenance: %{source: :receipt_delivery, receipt_id: receipt_id},
        metadata: %{transition: :receipt_delivery_retry_recorded}
      )
    else
      nil -> {:error, :receipt_outbox_entry_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec admission_available?(InstanceState.t()) ::
          :ok | {:error, :receipt_outbox_full | :receipt_outbox_pending}
  def admission_available?(%InstanceState{receipt_mode: :required} = data) do
    with {:ok, %{entries: entries}} <- Canonical.fetch(data.canonical, :receipt_outbox) do
      case entries do
        [] ->
          :ok

        entries when length(entries) >= data.max_receipt_outbox ->
          {:error, :receipt_outbox_full}

        _pending ->
          {:error, :receipt_outbox_pending}
      end
    end
  end

  def admission_available?(%InstanceState{}), do: :ok

  defp maybe_put_outbox(_data, prepared, mode, _payload_ref)
       when mode in [:disabled, :observational],
       do: {:ok, prepared.writes}

  defp maybe_put_outbox(data, prepared, :required, payload_ref)
       when is_binary(payload_ref) and payload_ref != "" do
    with {:ok, outbox} <- Canonical.fetch(data.canonical, :receipt_outbox),
         :ok <- ensure_capacity(outbox.entries, data.max_receipt_outbox) do
      entry = OutboxEntry.new(prepared.envelope, payload_ref, data.canonical.revision + 1)

      value = %{
        entries: outbox.entries ++ [entry],
        ids: Map.put(outbox.ids, entry.id, entry.digest)
      }

      {:ok, Map.put(prepared.writes, :receipt_outbox, value)}
    end
  end

  defp maybe_put_outbox(_data, _prepared, :required, _payload_ref),
    do: {:error, :required_receipt_payload_not_staged}

  defp ensure_capacity(entries, limit) when length(entries) < limit, do: :ok
  defp ensure_capacity(_entries, _limit), do: {:error, :receipt_outbox_full}

  defp verify_post_digest(data, envelope) do
    case Canonical.state_digest(data.canonical) do
      {:ok, %{root: digest}} when digest == envelope.post_state_digest -> :ok
      {:ok, %{root: digest}} -> {:error, {:receipt_post_state_digest_mismatch, digest}}
      {:error, _reason} = error -> error
    end
  end

  defp refresh_writes(data, prepared) do
    writes = Map.delete(prepared.writes, :correlations)

    with {:ok, writes} <-
           rebase_entry_write(data, writes, :runs, prepared.envelope.run_id, prepared),
         {:ok, writes} <-
           rebase_entry_write(
             data,
             writes,
             :lifecycles,
             prepared.envelope.definition_ref,
             prepared
           ),
         {:ok, writes} <-
           rebase_entry_write(
             data,
             writes,
             :inference_control,
             prepared.envelope.inference_id,
             prepared
           ),
         :ok <- validate_unchanged_writes(data, writes, prepared) do
      {:ok, Commit.prepare_writes(data, writes)}
    end
  end

  defp rebase_entry_write(_data, writes, _section, nil, _prepared), do: {:ok, writes}

  defp rebase_entry_write(data, writes, section, key, prepared) do
    case Map.fetch(writes, section) do
      :error ->
        {:ok, writes}

      {:ok, staged} when is_map(staged) and not is_struct(staged) ->
        with {:ok, current} <- Canonical.fetch(data.canonical, section),
             {:ok, base} <- base_section(prepared, data, section),
             {:ok, value} <- Map.fetch(staged, key),
             :ok <- unchanged_target(base, current, staged, key, section) do
          {:ok, Map.put(writes, section, Map.put(current, key, value))}
        else
          :error -> {:error, {:receipt_refresh_target_missing, section, key}}
          {:error, _reason} = error -> error
        end

      {:ok, _invalid} ->
        {:error, {:invalid_receipt_refresh_section, section}}
    end
  end

  # Aggregate sections are rebased by target above. Every other staged write
  # is scalar from the receipt's perspective and must still be based on the
  # value that was inspected when the boundary was prepared. This prevents a
  # control or Flow commit during payload staging from being overwritten.
  defp validate_unchanged_writes(data, writes, prepared) do
    rebased =
      [
        :correlations,
        if(prepared.envelope.run_id, do: :runs),
        if(prepared.envelope.definition_ref, do: :lifecycles),
        if(prepared.envelope.inference_id, do: :inference_control)
      ]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    writes
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(rebased, &1))
    |> Enum.reduce_while(:ok, fn section, :ok ->
      case unchanged_write(data, writes, prepared, section) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp unchanged_write(data, writes, prepared, section) do
    with {:ok, current} <- Canonical.fetch(data.canonical, section),
         {:ok, base} <- base_section(prepared, data, section),
         {:ok, staged} <- Map.fetch(writes, section) do
      unchanged_scalar_section(current, base, staged, section)
    else
      :error -> {:error, {:receipt_refresh_section_missing, section}}
      {:error, _reason} = error -> error
    end
  end

  defp unchanged_scalar_section(current, base, staged, _section)
       when current == base or current == staged,
       do: :ok

  defp unchanged_scalar_section(_current, _base, _staged, section),
    do: {:error, {:receipt_refresh_conflict, section}}

  defp unchanged_target(base, current, staged, key, section) do
    base_target = Map.fetch(base, key)
    current_target = Map.fetch(current, key)
    staged_target = Map.fetch(staged, key)

    if current_target == base_target or current_target == staged_target,
      do: :ok,
      else: {:error, {:receipt_refresh_conflict, section, key}}
  end

  defp capture_base_sections(data, writes) do
    Enum.reduce_while(Map.keys(writes), {:ok, %{}}, fn section, {:ok, captured} ->
      case Canonical.fetch(data.canonical, section) do
        {:ok, value} -> {:cont, {:ok, Map.put(captured, section, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp base_section(%__MODULE__{base_sections: base_sections}, _data, section)
       when is_map(base_sections) do
    case Map.fetch(base_sections, section) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:receipt_refresh_base_missing, section}}
    end
  end

  defp base_section(_prepared, _data, section),
    do: {:error, {:receipt_refresh_base_missing, section}}

  defp run_manifest_digest(
         %InstanceState{activation: %{definition_ref: definition_ref, manifest_digest: digest}},
         %Run{definition_ref: definition_ref}
       ),
       do: digest

  defp run_manifest_digest(_data, _run), do: nil
end
