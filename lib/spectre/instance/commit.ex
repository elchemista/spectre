defmodule Spectre.Instance.Commit do
  @moduledoc """
  Canonical commit machinery for `Spectre.Instance`.

  Applies validated section writes through `Spectre.Instance.Canonical`
  snapshots, appends bounded operation events, records journal entries and
  enqueues checkpoints. Committed events are returned to the caller, which
  owns routing them into the Run scheduler.
  """

  alias Spectre.AgentRef
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Loops
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Control
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

    with {:ok, snapshot} <-
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

  @doc "Commits the Flow state advanced by a Run, raising on canonical failure."
  @spec flow_state(InstanceState.t(), State.t(), Run.t()) :: InstanceState.t()
  def flow_state(%InstanceState{} = data, %State{} = state, %Run{} = run) do
    case canonical_sections(data, %{flow: state},
           correlation_id: run.id,
           causation_id: run.trace_id,
           provenance: %{source: :flow, run_id: run.id},
           metadata: %{transition: :flow_state_committed}
         ) do
      {:ok, next} -> next
      {:error, reason} -> raise "canonical Flow commit failed: #{inspect(reason)}"
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
      end)
    end
  end

  defp validate_operational_batch(entries) when is_list(entries) and entries != [] do
    ids = Enum.map(entries, & &1.loop.id)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operational_loop_in_transition}
    else
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        with :ok <- OperationLoop.validate(entry.loop),
             :ok <- Control.validate(entry.control) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_operational_batch(_entries), do: {:error, :empty_operational_transition}

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
end
