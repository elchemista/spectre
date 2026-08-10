defmodule Spectre.Instance.Commit do
  @moduledoc false

  alias Spectre.AgentRef
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Owner
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Control
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Run
  alias Spectre.State

  @doc "Commits one operational loop transition; see `operational_batch/3`."
  @spec operational(InstanceState.t(), OperationLoop.t(), Control.t(), [map()], keyword()) ::
          {:ok, InstanceState.t(), [OperationEvent.t()]} | {:error, term()}
  def operational(%InstanceState{} = data, loop, control, event_specs, opts) do
    entry = %{loop: loop, control: control, event_specs: event_specs, opts: opts}
    operational_batch(data, [entry], opts)
  end

  @doc """
  Commits a batch of operational loop transitions as one canonical change.

  Validates every loop and Control, materializes the declared event specs at
  the next canonical revision and journals each transition. The committed
  events are returned unrouted.
  """
  @spec operational_batch(InstanceState.t(), [map()], keyword()) ::
          {:ok, InstanceState.t(), [OperationEvent.t()]} | {:error, term()}
  def operational_batch(%InstanceState{} = data, entries, commit_opts) do
    with :ok <- validate_operational_batch(entries) do
      do_commit_operational_batch(data, entries, commit_opts)
    end
  end

  @doc "Commits arbitrary canonical section writes and enqueues a checkpoint."
  @spec canonical_sections(InstanceState.t(), map(), keyword()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def canonical_sections(%InstanceState{} = data, writes, opts) do
    names = Map.keys(writes)

    with :ok <-
           Owner.assert_current(data.owner, data.ref, data.owner_lease, :commit, data.base_opts),
         {:ok, snapshot} <-
           Canonical.snapshot(data.canonical,
             read: names,
             write: names,
             correlation_id: Keyword.fetch!(opts, :correlation_id),
             causation_id: Keyword.get(opts, :causation_id)
           ),
         {:ok, change} <-
           Canonical.change(snapshot, writes,
             provenance: Keyword.get(opts, :provenance, %{}),
             metadata: Keyword.get(opts, :metadata, %{})
           ),
         {:ok, canonical, _transition} <- Canonical.commit(data.canonical, change) do
      next = %{data | canonical: canonical}

      case Map.fetch(writes, :flow) do
        {:ok, %State{} = state} -> {:ok, Checkpoint.maybe_enqueue(%{next | state: state})}
        :error -> {:ok, Checkpoint.maybe_enqueue(next)}
      end
    end
  end

  @doc "Commits the Flow state advanced by a Run without crashing the owning Instance."
  @spec flow_state(InstanceState.t(), State.t(), Run.t()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def flow_state(%InstanceState{} = data, %State{} = state, %Run{} = run) do
    case run_state(data, state, run) do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, {:canonical_flow_commit_failed, reason}}
    end
  end

  @doc "Commits one Run checkpoint and its observed Flow state atomically."
  @spec run_state(InstanceState.t(), State.t(), Run.t()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def run_state(%InstanceState{} = data, %State{} = state, %Run{} = run) do
    with {:ok, checkpoint} <- Run.checkpoint(run),
         {:ok, runs} <- Canonical.fetch(data.canonical, :runs) do
      canonical_sections(data, %{flow: state, runs: Map.put(runs, run.id, checkpoint)},
        correlation_id: run.id,
        causation_id: run.trace_id,
        provenance: %{source: :run, run_id: run.id},
        metadata: %{
          transition: :run_state_committed,
          definition_ref: to_string(run.definition_ref),
          activation_generation: run.activation_generation,
          authority_epoch: run.authority_epoch
        }
      )
    end
    |> case do
      {:ok, next} -> {:ok, next}
      {:error, reason} -> {:error, {:canonical_run_commit_failed, reason}}
    end
  end

  @doc "Prepends new events to the bounded canonical event window."
  @spec append_events(InstanceState.t(), [OperationEvent.t()]) :: map()
  def append_events(%InstanceState{} = data, events) do
    current = Loops.canonical_value!(data, :events)
    current_records = Map.get(current, :records, [])
    ids = Map.get(current, :ids, %{})
    existing_ids = MapSet.new(Enum.map(current_records, & &1.id))
    events = Enum.reject(events, &MapSet.member?(existing_ids, &1.id))
    records = Enum.take(events ++ current_records, Spectre.Instance.operation_event_limit())
    retained = MapSet.new(Enum.map(records, & &1.id))

    ids =
      ids
      |> Map.take(MapSet.to_list(retained))
      |> Map.merge(Map.new(events, &{&1.id, &1.revision}))

    %{records: records, ids: ids}
  end

  @doc "Validates event identity and revision fencing against committed events."
  @spec validate_operation_events(InstanceState.t(), [OperationEvent.t()]) ::
          :ok | {:error, term()}
  def validate_operation_events(%InstanceState{} = data, events) do
    existing = Map.get(Loops.canonical_value!(data, :events), :records, [])
    ids = Enum.map(events, & &1.id)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operation_event_id}
    else
      Enum.reduce_while(events, :ok, fn event, :ok ->
        validate_operation_event(data, existing, event)
      end)
    end
  end

  defp validate_operation_event(data, existing, event) do
    previous = Enum.find(existing, &(&1.id == event.id))

    case {OperationEvent.validate(event), previous} do
      {:ok, nil} when event.revision == data.canonical.revision + 1 ->
        {:cont, :ok}

      {:ok, ^event} ->
        {:cont, :ok}

      {:ok, nil} ->
        {:halt, {:error, {:invalid_operation_event_revision, event.revision}}}

      {:ok, _conflict} ->
        {:halt, {:error, {:operation_event_id_conflict, event.id}}}

      {{:error, _reason} = error, _previous} ->
        {:halt, error}
    end
  end

  defp validate_operational_batch(entries) when is_list(entries) and entries != [] do
    ids = Enum.map(entries, & &1.loop.id)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operational_loop_in_transition}
    else
      Enum.reduce_while(entries, :ok, &validate_operational_entry/2)
    end
  end

  defp validate_operational_batch(_entries), do: {:error, :empty_operational_transition}

  defp validate_operational_entry(entry, :ok) do
    with :ok <- OperationLoop.validate(entry.loop),
         :ok <- Control.validate(entry.control) do
      {:cont, :ok}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp do_commit_operational_batch(data, entries, commit_opts) do
    next_revision = data.canonical.revision + 1

    events =
      Enum.flat_map(entries, fn %{loop: loop, event_specs: event_specs, opts: opts} ->
        Enum.map(event_specs, fn spec ->
          OperationEvent.new(loop, Map.fetch!(spec, :type),
            agent_id: AgentRef.key(data.agent_ref),
            revision: next_revision,
            correlation_id: Keyword.get(opts, :correlation_id, loop.correlation_id),
            causation_id: Keyword.get(opts, :causation_id),
            provenance: Keyword.get(opts, :provenance, loop.provenance),
            payload: Map.get(spec, :payload),
            metadata: %{transition: Keyword.get(opts, :transition)}
          )
        end)
      end)

    writes = operational_batch_writes(data, entries, next_revision)

    writes =
      if events == [], do: writes, else: Map.put(writes, :events, append_events(data, events))

    writes = prune_operational_state(data, writes)

    primary = hd(entries).loop

    with :ok <- validate_operation_events(data, events),
         {:ok, next} <-
           canonical_sections(data, writes,
             correlation_id: Keyword.get(commit_opts, :correlation_id, primary.correlation_id),
             causation_id: Keyword.get(commit_opts, :causation_id),
             provenance: Keyword.get(commit_opts, :provenance, primary.provenance),
             metadata: %{
               transition: Keyword.get(commit_opts, :transition),
               loop_id: primary.id,
               loop_ids: Enum.map(entries, & &1.loop.id)
             }
           ) do
      Enum.each(entries, fn %{loop: loop, opts: opts} ->
        _ =
          Spectre.Journal.record(
            data.agent,
            :operational_transition,
            %{
              loop_id: loop.id,
              loop_kind: loop.kind,
              loop_revision: loop.revision,
              canonical_revision: next.canonical.revision,
              transition: Keyword.get(opts, :transition)
            },
            data.base_opts
          )
      end)

      {:ok, next, events}
    end
  end

  defp operational_batch_writes(data, entries, next_revision) do
    section_writes =
      Enum.reduce(entries, %{}, fn %{loop: loop}, acc ->
        section = Loops.operation_section(loop.kind)
        current = Map.get(acc, section, Loops.canonical_value!(data, section))
        Map.put(acc, section, Map.put(current, loop.id, loop))
      end)

    controls =
      Enum.reduce(entries, Loops.canonical_value!(data, :control), fn entry, acc ->
        Map.put(acc, entry.loop.id, entry.control)
      end)

    correlations =
      Enum.reduce(entries, Loops.canonical_value!(data, :correlations), fn entry, acc ->
        put_loop_correlation(acc, entry.loop, next_revision, entry.opts)
      end)

    section_writes
    |> Map.put(:control, controls)
    |> Map.put(:correlations, correlations)
  end

  defp put_loop_correlation(correlations, loop, revision, opts) do
    correlation_id = Keyword.get(opts, :correlation_id, loop.correlation_id)

    Map.put(correlations, correlation_id, %{
      loop_id: loop.id,
      loop_kind: loop.kind,
      revision: revision,
      causation_id: Keyword.get(opts, :causation_id)
    })
  end

  defp prune_operational_state(data, writes) do
    section_maps =
      Map.new([:work, :vigil, :directive], fn section ->
        {section, Map.get(writes, section, Loops.canonical_value!(data, section))}
      end)

    section_maps = prune_terminal_loops(section_maps, terminal_loop_retention(data.base_opts))

    retained_loops =
      section_maps
      |> Map.values()
      |> Enum.reduce(%{}, &Map.merge(&2, &1))

    retained_ids = retained_loops |> Map.keys() |> MapSet.new()

    controls =
      writes
      |> Map.get(:control, Loops.canonical_value!(data, :control))
      |> Map.take(MapSet.to_list(retained_ids))

    correlations =
      writes
      |> Map.get(:correlations, Loops.canonical_value!(data, :correlations))
      |> prune_correlations(retained_loops, correlation_retention(data.base_opts))

    events =
      writes
      |> Map.get(:events, Loops.canonical_value!(data, :events))
      |> prune_events(retained_ids)

    writes
    |> Map.merge(section_maps)
    |> Map.put(:control, controls)
    |> Map.put(:correlations, correlations)
    |> Map.put(:events, events)
  end

  defp prune_terminal_loops(section_maps, :unlimited), do: section_maps

  defp prune_terminal_loops(section_maps, limit) do
    retained_terminal_ids =
      section_maps
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.filter(&OperationLoop.terminal?/1)
      |> Enum.sort_by(&{&1.updated_at, &1.id}, :desc)
      |> Enum.take(limit)
      |> MapSet.new(& &1.id)

    Map.new(section_maps, fn {section, loops} ->
      retained =
        Map.reject(loops, fn {_id, loop} ->
          OperationLoop.terminal?(loop) and not MapSet.member?(retained_terminal_ids, loop.id)
        end)

      {section, retained}
    end)
  end

  defp prune_correlations(correlations, retained_loops, limit) do
    retained_ids = retained_loops |> Map.keys() |> MapSet.new()
    primary_correlation_ids = retained_loops |> Map.values() |> MapSet.new(& &1.correlation_id)

    {loop_entries, other_entries} =
      Enum.split_with(correlations, fn
        {_key, %{loop_id: loop_id, loop_kind: kind, revision: revision}}
        when is_binary(loop_id) and kind in [:work, :vigil, :directive] and
               is_integer(revision) ->
          true

        _other ->
          false
      end)

    {primary_entries, historical_entries} =
      loop_entries
      |> Enum.filter(fn {_key, correlation} ->
        MapSet.member?(retained_ids, correlation.loop_id)
      end)
      |> Enum.split_with(fn {key, _correlation} ->
        MapSet.member?(primary_correlation_ids, key)
      end)

    loop_entries = primary_entries ++ maybe_limit_correlations(historical_entries, limit)

    other_entries =
      Enum.reject(other_entries, fn
        {_key, %DeliveryReceipt{loop_id: loop_id}} ->
          not MapSet.member?(retained_ids, loop_id)

        _other ->
          false
      end)

    Map.new(other_entries ++ loop_entries)
  end

  defp maybe_limit_correlations(entries, :unlimited), do: entries

  defp maybe_limit_correlations(entries, limit) do
    entries
    |> Enum.sort_by(fn {key, correlation} -> {correlation.revision, key} end, :desc)
    |> Enum.take(limit)
  end

  defp prune_events(events, retained_ids) do
    records =
      events
      |> Map.get(:records, [])
      |> Enum.filter(&MapSet.member?(retained_ids, &1.loop_id))
      |> Enum.take(Spectre.Instance.operation_event_limit())

    record_ids = MapSet.new(records, & &1.id)
    ids = events |> Map.get(:ids, %{}) |> Map.take(MapSet.to_list(record_ids))
    %{records: records, ids: ids}
  end

  defp terminal_loop_retention(opts),
    do: retention_limit(opts, :operation_terminal_loop_retention, 256)

  defp correlation_retention(opts),
    do: retention_limit(opts, :operation_correlation_retention, 1_024)

  defp retention_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :unlimited -> :unlimited
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end
end
