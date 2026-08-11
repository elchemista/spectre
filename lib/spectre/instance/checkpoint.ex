defmodule Spectre.Instance.Checkpoint do
  @moduledoc false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Canonical.Validator, as: CanonicalValidator
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.State

  @doc """
  Restores the initial canonical state and Flow state for a starting Instance.

  Prefers an explicitly supplied `:canonical_checkpoint`, then the configured
  checkpoint store, and finally builds a fresh canonical state around the
  restored Flow state.
  """
  @spec restore_canonical(keyword(), State.t(), CheckpointStore.config() | nil, keyword()) ::
          {:ok, State.t(), Canonical.t(), non_neg_integer()} | {:error, term()}
  def restore_canonical(opts, state, checkpoint_store, base_opts) do
    case Keyword.fetch(opts, :canonical_checkpoint) do
      {:ok, checkpoint} ->
        with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
             :ok <- validate_canonical_instance(canonical, Keyword.fetch!(opts, :instance_ref)),
             {:ok, %State{} = flow_state} <- Canonical.fetch(canonical, :flow) do
          expected = Keyword.get(opts, :checkpoint_expected_revision, 0)
          {:ok, flow_state, canonical, expected}
        else
          {:ok, value} -> {:error, {:invalid_canonical_flow_state, value}}
          {:error, _reason} = error -> error
        end

      :error ->
        restore_stored_or_new_canonical(opts, state, checkpoint_store, base_opts)
    end
  end

  @doc "Resolves the configured checkpoint store for an Agent Instance."
  @spec store_config(module(), keyword(), keyword()) ::
          {:ok, CheckpointStore.config() | nil} | {:error, term()}
  def store_config(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    value =
      first_configured([
        {opts, :checkpoint_store},
        {base_opts, :checkpoint_store},
        {config, :checkpoint_store}
      ])

    CheckpointStore.normalize(value)
  end

  @doc "Resolves the checkpoint mode, defaulting to `:async` when a store exists."
  @spec mode(keyword(), CheckpointStore.config() | nil) ::
          {:ok, :async | :manual} | {:error, term()}
  def mode(opts, checkpoint_store) do
    default = if checkpoint_store, do: :async, else: :manual
    value = Keyword.get(opts, :checkpoint_mode, default)

    if value in [:async, :manual],
      do: {:ok, value},
      else: {:error, {:invalid_checkpoint_mode, value}}
  end

  @doc "Enqueues an async checkpoint of the current canonical state, if configured."
  @spec maybe_enqueue(InstanceState.t()) :: InstanceState.t()
  def maybe_enqueue(%InstanceState{checkpoint_store: nil} = data), do: data
  def maybe_enqueue(%InstanceState{checkpoint_mode: :manual} = data), do: data
  def maybe_enqueue(%InstanceState{} = data), do: enqueue_checkpoint(data, data.canonical)

  @doc "Forces a checkpoint of the current canonical state regardless of mode."
  @spec force(InstanceState.t()) :: InstanceState.t()
  def force(%InstanceState{} = data), do: enqueue_checkpoint(data, data.canonical, true)

  @doc "Demonitors and clears the inflight checkpoint task."
  @spec finish_task(InstanceState.t()) :: InstanceState.t()
  def finish_task(%InstanceState{checkpoint_inflight: %{monitor: monitor}} = data) do
    Process.demonitor(monitor, [:flush])
    %{data | checkpoint_inflight: nil}
  end

  @doc "Applies a durably committed checkpoint result and starts any pending write."
  @spec persisted(InstanceState.t(), map(), non_neg_integer()) :: InstanceState.t()
  def persisted(%InstanceState{} = data, inflight, revision) do
    data
    |> Map.put(:checkpoint_revision, revision)
    |> Map.put(:checkpoint_persisted, inflight.canonical)
    |> Map.put(:checkpoint_reconciliation, nil)
    |> Map.put(:checkpoint_error, nil)
    |> reply_checkpoint_waiters()
    |> start_pending_checkpoint()
  end

  @doc "Records a failed persist, requiring reconciliation for ambiguous outcomes."
  @spec persist_failed(InstanceState.t(), map(), term()) :: InstanceState.t()
  def persist_failed(%InstanceState{} = data, inflight, reason) do
    if checkpoint_reconciliation_required?(reason) do
      mark_checkpoint_reconciliation(data, inflight, reason)
    else
      data
      |> Map.put(:checkpoint_error, reason)
      |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, data.canonical))
      |> fail_checkpoint_waiters(reason)
    end
  end

  @doc """
  Handles an abnormal checkpoint task DOWN.

  A normal task sends its result before terminating, so the caller keeps the
  fence until that message is reduced; an abnormal DOWN has no trustworthy
  commit outcome and marks reconciliation instead.
  """
  @spec task_down(InstanceState.t(), term()) :: InstanceState.t()
  def task_down(%InstanceState{} = data, reason) do
    failure = {:checkpoint_task_down, reason}
    inflight = data.checkpoint_inflight

    data
    |> finish_task()
    |> mark_checkpoint_reconciliation(inflight, failure)
  end

  @doc "Starts the reconciliation load task for an ambiguous checkpoint write."
  @spec start_reconciliation(InstanceState.t(), GenServer.from()) :: InstanceState.t()
  def start_reconciliation(%InstanceState{} = data, from) do
    owner = self()
    token = Spectre.Identity.uuid7()
    store = data.checkpoint_store
    ref = data.ref

    opts =
      Keyword.put(data.base_opts, :owner_fencing_token, data.owner_lease.fencing_token)

    callback = fn ->
      result = CheckpointStore.load(store, ref, opts)
      send(owner, {:spectre, :checkpoint_reconcile_result, token, result})
    end

    case Task.Supervisor.start_child(Spectre.Instance.CheckpointTaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        %{
          data
          | checkpoint_reconcile_inflight: %{
              token: token,
              pid: pid,
              monitor: monitor,
              from: from
            }
        }

      {:error, reason} ->
        failure = {:checkpoint_reconciliation_task_start_failed, reason}
        GenServer.reply(from, {:error, failure})
        %{data | checkpoint_error: failure}
    end
  end

  @doc "Demonitors and clears the inflight reconciliation task."
  @spec finish_reconciliation_task(InstanceState.t()) :: InstanceState.t()
  def finish_reconciliation_task(
        %InstanceState{checkpoint_reconcile_inflight: %{monitor: monitor}} = data
      ) do
    Process.demonitor(monitor, [:flush])
    %{data | checkpoint_reconcile_inflight: nil}
  end

  @doc "Handles an abnormal reconciliation task DOWN, replying to the waiter."
  @spec reconciliation_task_down(InstanceState.t(), term()) :: InstanceState.t()
  def reconciliation_task_down(%InstanceState{} = data, reason) do
    %{from: from} = data.checkpoint_reconcile_inflight
    failure = {:checkpoint_reconciliation_task_down, reason}
    GenServer.reply(from, {:error, failure})

    data
    |> finish_reconciliation_task()
    |> Map.put(:checkpoint_error, failure)
  end

  @doc "Reduces a reconciliation load result against the recorded ambiguity."
  @spec apply_reconciliation(InstanceState.t(), term()) ::
          {:ok, InstanceState.t(), non_neg_integer()} | {:error, InstanceState.t(), term()}
  def apply_reconciliation(%InstanceState{} = data, result) do
    reconciliation = data.checkpoint_reconciliation

    case decode_reconciled_checkpoint(result, data.ref) do
      :not_found when reconciliation.expected_revision == 0 ->
        checkpoint_not_committed(data)

      {:ok, stored} when stored == reconciliation.canonical ->
        checkpoint_committed(data, stored)

      {:ok, stored} when not is_nil(reconciliation.base) and stored == reconciliation.base ->
        checkpoint_not_committed(data)

      {:ok, stored} ->
        reason =
          {:checkpoint_reconciliation_conflict, reconciliation.expected_revision,
           reconciliation.revision, stored.revision}

        {:error, %{data | checkpoint_error: reason}, reason}

      :not_found ->
        reason = {:checkpoint_reconciliation_missing_base, reconciliation.expected_revision}
        {:error, %{data | checkpoint_error: reason}, reason}

      {:error, reason} ->
        {:error, %{data | checkpoint_error: reason}, reason}
    end
  end

  @doc "Returns the redacted reconciliation status for the public checkpoint view."
  @spec reconciliation_status(map() | nil) :: map() | nil
  def reconciliation_status(nil), do: nil

  def reconciliation_status(reconciliation) do
    %{
      revision: reconciliation.revision,
      expected_revision: reconciliation.expected_revision,
      reason: InstanceTelemetry.reason_class(reconciliation.reason)
    }
  end

  @doc "Returns the error surfaced to callers while reconciliation is required."
  @spec reconciliation_error(InstanceState.t()) :: term()
  def reconciliation_error(%InstanceState{} = data) do
    reconciliation = data.checkpoint_reconciliation

    {:checkpoint_reconciliation_required, reconciliation.revision,
     InstanceTelemetry.reason_class(reconciliation.reason)}
  end

  defp restore_stored_or_new_canonical(opts, state, checkpoint_store, base_opts) do
    instance_ref = Keyword.fetch!(opts, :instance_ref)

    case CheckpointStore.load(checkpoint_store, instance_ref, base_opts) do
      {:ok, checkpoint} ->
        restore_stable_with_legacy_conflict_check(
          checkpoint_store,
          checkpoint,
          instance_ref,
          base_opts
        )

      :not_found ->
        reject_legacy_checkpoint_or_initialize(checkpoint_store, instance_ref, state, base_opts)

      {:error, reason} ->
        {:error, {:canonical_checkpoint_load_failed, :stable, reason}}
    end
  end

  defp restore_stable_with_legacy_conflict_check(store, checkpoint, instance_ref, opts) do
    case InstanceRef.legacy(instance_ref) do
      {:ok, legacy_ref} ->
        restore_stable_with_legacy_ref(store, checkpoint, instance_ref, legacy_ref, opts)

      {:error, :legacy_agent_ref_source_unavailable} ->
        restore_stable_checkpoint(checkpoint, instance_ref)
    end
  end

  defp restore_stable_with_legacy_ref(store, checkpoint, instance_ref, legacy_ref, opts) do
    case CheckpointStore.load(store, legacy_ref, opts) do
      :not_found ->
        restore_stable_checkpoint(checkpoint, instance_ref)

      {:ok, ^checkpoint} ->
        restore_stable_checkpoint(checkpoint, instance_ref)

      {:ok, _different} ->
        {:error, {:divergent_instance_key_histories, legacy_ref.key, instance_ref.key}}

      {:error, reason} ->
        {:error, {:canonical_checkpoint_load_failed, :legacy_detection, reason}}
    end
  end

  defp reject_legacy_checkpoint_or_initialize(store, instance_ref, state, opts) do
    case InstanceRef.legacy(instance_ref) do
      {:ok, legacy_ref} ->
        case CheckpointStore.load(store, legacy_ref, opts) do
          {:ok, _checkpoint} ->
            {:error,
             {:legacy_instance_checkpoint_requires_offline_migration, legacy_ref.key,
              instance_ref.key}}

          :not_found ->
            new_canonical_state(instance_ref, state)

          {:error, reason} ->
            {:error, {:canonical_checkpoint_load_failed, :legacy_detection, reason}}
        end

      {:error, :legacy_agent_ref_source_unavailable} ->
        new_canonical_state(instance_ref, state)
    end
  end

  defp restore_stable_checkpoint(checkpoint, instance_ref) do
    with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
         :ok <- validate_canonical_instance(canonical, instance_ref),
         {:ok, %State{} = flow_state} <- Canonical.fetch(canonical, :flow) do
      {:ok, flow_state, canonical, canonical.revision}
    else
      {:ok, value} -> {:error, {:invalid_canonical_flow_state, value}}
      {:error, _reason} = error -> error
    end
  end

  defp new_canonical_state(instance_ref, state) do
    Canonical.new(%{
      flow: state,
      work: %{},
      vigil: %{},
      directive: %{},
      control: %{},
      correlations: %{instance_key: instance_ref.key},
      events: %{records: [], ids: %{}}
    })
    |> case do
      {:ok, canonical} -> {:ok, state, canonical, 0}
      {:error, _reason} = error -> error
    end
  end

  defp enqueue_checkpoint(data, canonical, force? \\ false) do
    cond do
      canonical.revision <= data.checkpoint_revision ->
        reply_checkpoint_waiters(data)

      not is_nil(data.checkpoint_reconciliation) ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      not is_nil(data.checkpoint_inflight) ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      not force? and data.checkpoint_mode == :manual ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      true ->
        start_checkpoint_task(%{data | checkpoint_error: nil}, canonical)
    end
  end

  defp newest_checkpoint(nil, canonical), do: canonical

  defp newest_checkpoint(current, canonical) do
    if current.revision >= canonical.revision, do: current, else: canonical
  end

  defp start_checkpoint_task(data, canonical) do
    owner = self()
    token = Spectre.Identity.uuid7()
    revision = canonical.revision
    expected = data.checkpoint_revision
    store = data.checkpoint_store
    ref = data.ref

    opts =
      Keyword.put(data.base_opts, :owner_fencing_token, data.owner_lease.fencing_token)

    callback = fn ->
      result =
        with {:ok, encoded} <- CanonicalCodec.encode_json(canonical) do
          CheckpointStore.persist(store, ref, encoded, expected, revision, opts)
        end

      send(owner, {:spectre, :checkpoint_result, token, revision, result})
    end

    case Task.Supervisor.start_child(Spectre.Instance.CheckpointTaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        %{
          data
          | checkpoint_inflight: %{
              token: token,
              revision: revision,
              expected_revision: expected,
              canonical: canonical,
              pid: pid,
              monitor: monitor
            },
            checkpoint_pending: nil
        }

      {:error, reason} ->
        failure = {:checkpoint_task_start_failed, reason}

        data
        |> Map.put(:checkpoint_error, failure)
        |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, canonical))
        |> fail_checkpoint_waiters(failure)
    end
  end

  defp start_pending_checkpoint(%{checkpoint_reconciliation: reconciliation} = data)
       when not is_nil(reconciliation),
       do: data

  defp start_pending_checkpoint(%{checkpoint_pending: nil} = data), do: data

  defp start_pending_checkpoint(data) do
    pending = data.checkpoint_pending

    if pending.revision <= data.checkpoint_revision do
      %{data | checkpoint_pending: nil}
    else
      start_checkpoint_task(data, pending)
    end
  end

  defp reply_checkpoint_waiters(data) do
    {ready, waiting} =
      Enum.split_with(data.checkpoint_waiters, fn {_from, target} ->
        target <= data.checkpoint_revision
      end)

    Enum.each(ready, fn {from, _target} ->
      GenServer.reply(from, {:ok, data.checkpoint_revision})
    end)

    %{data | checkpoint_waiters: waiting}
  end

  defp fail_checkpoint_waiters(data, reason) do
    Enum.each(data.checkpoint_waiters, fn {from, _target} ->
      GenServer.reply(from, {:error, reason})
    end)

    %{data | checkpoint_waiters: []}
  end

  defp mark_checkpoint_reconciliation(data, inflight, reason) do
    reconciliation = %{
      revision: inflight.revision,
      expected_revision: inflight.expected_revision,
      canonical: inflight.canonical,
      base: data.checkpoint_persisted,
      reason: reason
    }

    error = {:checkpoint_reconciliation_required, inflight.revision, reason}

    data
    |> Map.put(:checkpoint_reconciliation, reconciliation)
    |> Map.put(:checkpoint_error, error)
    |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, data.canonical))
    |> fail_checkpoint_waiters(error)
  end

  defp checkpoint_reconciliation_required?({:ambiguous, _reason}), do: true
  defp checkpoint_reconciliation_required?(:conflict), do: true

  defp checkpoint_reconciliation_required?({kind, _reason})
       when kind in [:conflict, :stale],
       do: true

  defp checkpoint_reconciliation_required?({kind, _a, _b})
       when kind in [:conflict, :stale],
       do: true

  defp checkpoint_reconciliation_required?(_reason), do: false

  defp decode_reconciled_checkpoint(:not_found, _instance_ref), do: :not_found

  defp decode_reconciled_checkpoint({:ok, checkpoint}, instance_ref) do
    with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
         :ok <- validate_canonical_instance(canonical, instance_ref) do
      {:ok, canonical}
    end
  end

  defp decode_reconciled_checkpoint({:error, reason}, _instance_ref),
    do: {:error, {:checkpoint_reconciliation_load_failed, reason}}

  defp checkpoint_committed(data, stored) do
    revision = stored.revision

    next =
      data
      |> Map.put(:checkpoint_revision, revision)
      |> Map.put(:checkpoint_persisted, stored)
      |> Map.put(:checkpoint_reconciliation, nil)
      |> Map.put(:checkpoint_error, nil)
      |> reply_checkpoint_waiters()
      |> start_pending_checkpoint()

    {:ok, next, revision}
  end

  defp checkpoint_not_committed(data) do
    revision = data.checkpoint_revision

    next =
      data
      |> Map.put(:checkpoint_reconciliation, nil)
      |> Map.put(:checkpoint_error, nil)
      |> start_pending_checkpoint()

    {:ok, next, revision}
  end

  defp validate_canonical_instance(canonical, instance_ref) do
    CanonicalValidator.validate(canonical, instance_ref,
      event_limit: Spectre.Instance.operation_event_limit()
    )
  end

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end
end
