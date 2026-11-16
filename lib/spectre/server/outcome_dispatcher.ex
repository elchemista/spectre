defmodule Spectre.Server.OutcomeDispatcher do
  @moduledoc """
  Durable operation-to-continuation mapping with at-least-once result delivery.

  Tracking persists only portable host references. The adapter recovers results
  from GAM and locates the live Server; no Scope, capability or worker reference
  is checkpointed. Before delivery the dispatcher durably pins a result revision
  and event id. A restart recovers that revision and delivers the same event id.

  Configure a supervised `Spectre.Server.Store.Disk` and an explicit host adapter.
  `store_module:` can select another `Spectre.Server.Store` implementation.
  `status/1` exposes sanitized, transient `last_errors` by operation id. Adapter
  payloads and exception messages are never copied into that diagnostic view.
  Cognitive results need not pass through this service. A refresh checks for a
  later durable observation after the previous revision has been acknowledged.
  Exactly-once callback execution is not promised.

  `max_entries` defaults to 10,000 and rejects new tracking at capacity.
  `forget/2` and `compact/2` remove only entries acknowledged by the durable
  receiver, never unacquired work. Compaction retains the requested number of
  acknowledged entries in stable key order; it is an explicit host retention
  decision, not permission to repeat their application callbacks.

  Worker slots refill immediately. Errors use exponential backoff starting at
  `backoff_ms` (1,000), capped by `max_backoff_ms` (60,000). After `max_attempts`
  failures (5), an entry remains durably dead-lettered until `retry/2`; its
  reference and pinned result remain available for reconciliation.
  """
  use GenServer

  alias Spectre.GAM.Adapter
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Server.Store.Disk

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def track(server, operation_id, binding),
    do: GenServer.call(server, {:track, operation_id, binding})

  def refresh(server, operation_id), do: GenServer.call(server, {:refresh, operation_id})
  def retry(server, operation_id), do: GenServer.call(server, {:retry, operation_id})
  def forget(server, operation_id), do: GenServer.call(server, {:forget, operation_id})

  def compact(server, keep_delivered \\ 1_000),
    do: GenServer.call(server, {:compact, keep_delivered})

  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    store = Keyword.fetch!(opts, :store)
    store_module = Keyword.get(opts, :store_module, Disk)
    key = Keyword.get(opts, :key, "outcome_dispatcher")
    interval = Keyword.get(opts, :interval, 1_000)
    timeout = Keyword.get(opts, :worker_timeout, 30_000)
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    max_entries = Keyword.get(opts, :max_entries, 10_000)
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    backoff = Keyword.get(opts, :backoff_ms, 1_000)
    max_backoff = Keyword.get(opts, :max_backoff_ms, 60_000)

    with :ok <- Adapter.validate(adapter, recover: 3, deliver: 4),
         :ok <- Adapter.validate(store_module, fetch: 2, put_new: 3, compare_and_swap: 4),
         true <-
           Enum.all?(
             [interval, timeout, concurrency, max_entries, max_attempts, backoff, max_backoff],
             &(is_integer(&1) and &1 > 0)
           ),
         {:ok, revision, entries, retries} <- load(store_module, store, key) do
      state = %{
        store: store,
        store_module: store_module,
        key: key,
        revision: revision,
        entries: entries,
        adapter: adapter,
        adapter_options: Keyword.get(opts, :adapter_options, []),
        interval: interval,
        timeout: timeout,
        concurrency: concurrency,
        max_entries: max_entries,
        max_attempts: max_attempts,
        backoff: backoff,
        max_backoff: max_backoff,
        retries: retries,
        cooldowns: %{},
        cursor: nil,
        last_errors: %{},
        workers: %{}
      }

      send(self(), :poll)
      schedule_recovered_retry(state)
      {:ok, state}
    else
      false -> {:stop, :invalid_dispatcher_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:track, id, binding}, _from, state) do
    with true <- is_binary(id) and byte_size(id) > 0,
         true <- is_map(binding) and not is_struct(binding),
         true <- Enum.all?([:agent_ref, :tag, :recovery], &Map.has_key?(binding, &1)),
         :ok <- Value.validate(binding) do
      case Map.get(state.entries, id) do
        nil when map_size(state.entries) >= state.max_entries ->
          {:reply, {:error, :dispatcher_capacity_exceeded}, state}

        nil ->
          entry = %{binding: binding, event_ref: nil, delivered: false, last_event_ref: nil}
          acquire_tracking(state, Map.put(state.entries, id, entry))

        %{binding: ^binding} ->
          {:reply, :ok, state}

        _ ->
          {:reply, {:error, :operation_binding_conflict}, state}
      end
    else
      _ -> {:reply, {:error, :invalid_operation_binding}, state}
    end
  end

  def handle_call({:retry, id}, _from, state) do
    if Map.has_key?(state.entries, id) do
      state = %{
        state
        | retries: Map.delete(state.retries, id),
          cooldowns: Map.delete(state.cooldowns, id)
      }

      {:reply, :ok, persist!(state, state.entries) |> launch_available()}
    else
      {:reply, {:error, :unknown_operation}, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    case Map.get(state.entries, id) do
      %{delivered: true} -> {:reply, :ok, prune(state, [id])}
      nil -> {:reply, {:error, :unknown_operation}, state}
      _ -> {:reply, {:error, :operation_not_acquired}, state}
    end
  end

  def handle_call({:compact, keep}, _from, state) when is_integer(keep) and keep >= 0 do
    ids =
      state.entries
      |> Enum.filter(fn {_id, entry} -> entry.delivered end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.drop(keep)

    {:reply, {:ok, length(ids)}, prune(state, ids)}
  end

  def handle_call({:compact, _keep}, _from, state),
    do: {:reply, {:error, :invalid_retention_limit}, state}

  def handle_call({:refresh, id}, _from, state) do
    case Map.get(state.entries, id) do
      %{delivered: true} = entry ->
        entry = %{entry | delivered: false, event_ref: nil}
        {:reply, :ok, persist!(state, Map.put(state.entries, id, entry)) |> launch_available()}

      nil ->
        {:reply, {:error, :unknown_operation}, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       entries: state.entries,
       workers: map_size(state.workers),
       last_errors: state.last_errors,
       retries: state.retries
     }, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.interval)
    {:noreply, launch_available(state)}
  end

  def handle_info(:wake, state), do: {:noreply, launch_available(state)}

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {work, workers} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(work.timer)
        state = %{state | workers: workers}
        {:noreply, complete(state, work, result) |> launch_available()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, launch_available(state)}

      {work, workers} ->
        Process.cancel_timer(work.timer)

        state =
          record_error(%{state | workers: workers}, work, {:worker_exit, safe_reason(reason)})

        {:noreply, launch_available(state)}
    end
  end

  def handle_info({__MODULE__, ref, :timeout}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _} ->
        {:noreply, state}

      {work, workers} ->
        Process.exit(work.pid, :kill)
        Process.demonitor(ref, [:flush])

        {:noreply,
         record_error(%{state | workers: workers}, work, :timeout) |> launch_available()}
    end
  end

  defp launch_available(state) do
    active = MapSet.new(state.workers, fn {_ref, work} -> work.id end)
    available = max(state.concurrency - map_size(state.workers), 0)

    candidates =
      state.entries
      |> Enum.filter(fn {id, entry} -> eligible?(state, id, entry, active) end)
      |> Enum.sort_by(&elem(&1, 0))

    {later, earlier} =
      Enum.split_with(candidates, fn {id, _} -> is_nil(state.cursor) or id > state.cursor end)

    (later ++ earlier)
    |> Enum.take(available)
    |> Enum.reduce(state, fn {id, entry}, current ->
      launch(%{current | cursor: id}, id, entry, :recover)
    end)
  end

  defp launch(state, id, entry, mode, result \\ nil) do
    adapter = state.adapter
    opts = state.adapter_options
    event_id = event_id(id, entry.event_ref)

    task =
      Task.Supervisor.async_nolink(Spectre.Server.TaskSupervisor, fn ->
        case mode do
          :recover -> Adapter.invoke(adapter, :recover, [entry.binding, entry.event_ref, opts])
          :deliver -> Adapter.invoke(adapter, :deliver, [entry.binding, event_id, result, opts])
        end
      end)

    timer = Process.send_after(self(), {__MODULE__, task.ref, :timeout}, state.timeout)
    work = %{id: id, mode: mode, pid: task.pid, timer: timer}
    %{state | workers: Map.put(state.workers, task.ref, work)}
  end

  defp complete(state, %{id: id, mode: :recover}, {:ok, {:ok, event_ref, result}})
       when is_binary(event_ref) and byte_size(event_ref) > 0 do
    entry = Map.fetch!(state.entries, id)

    cond do
      entry.event_ref != nil and entry.event_ref != event_ref ->
        record_error(state, %{id: id, mode: :recover}, :pinned_result_revision_mismatch)

      entry.event_ref == nil and entry.last_event_ref == event_ref ->
        state
        |> clear_error(id)
        |> persist!(Map.put(state.entries, id, %{entry | delivered: true}))

      true ->
        entry = %{entry | event_ref: event_ref}

        state =
          if state.entries[id] == entry,
            do: state,
            else: persist!(state, Map.put(state.entries, id, entry))

        launch(clear_error(state, id), id, entry, :deliver, result)
    end
  end

  defp complete(state, %{id: id, mode: :deliver}, {:ok, :ok}) do
    entry = Map.fetch!(state.entries, id)
    entry = %{entry | delivered: true, last_event_ref: entry.event_ref}

    state = %{
      state
      | retries: Map.delete(state.retries, id),
        cooldowns: Map.delete(state.cooldowns, id)
    }

    state |> clear_error(id) |> persist!(Map.put(state.entries, id, entry))
  end

  defp complete(state, %{id: id, mode: :recover}, {:ok, :pending}) do
    Process.send_after(self(), :wake, state.interval)

    %{
      clear_error(state, id)
      | cooldowns:
          Map.put(state.cooldowns, id, System.monotonic_time(:millisecond) + state.interval)
    }
  end

  defp complete(state, work, {:ok, {:error, reason}}),
    do: record_error(state, work, safe_reason(reason))

  defp complete(state, work, {:error, reason}), do: record_error(state, work, safe_reason(reason))
  defp complete(state, work, _result), do: record_error(state, work, :invalid_adapter_reply)

  defp clear_error(state, id), do: %{state | last_errors: Map.delete(state.last_errors, id)}

  defp record_error(state, work, reason) do
    failures = Map.get(state.retries, work.id, %{failures: 0}).failures + 1
    delay = min(state.backoff * Integer.pow(2, min(failures - 1, 30)), state.max_backoff)

    retry = %{
      failures: failures,
      next_at: System.system_time(:millisecond) + delay,
      dead_letter: failures >= state.max_attempts
    }

    state = %{
      state
      | last_errors: Map.put(state.last_errors, work.id, %{stage: work.mode, reason: reason}),
        retries: Map.put(state.retries, work.id, retry)
    }

    if not retry.dead_letter, do: Process.send_after(self(), :wake, delay)
    persist!(state, state.entries)
  end

  defp schedule_recovered_retry(state) do
    due = state.retries |> Map.values() |> Enum.reject(& &1.dead_letter) |> Enum.map(& &1.next_at)

    case due do
      [] ->
        :ok

      _ ->
        Process.send_after(
          self(),
          :wake,
          max(Enum.min(due) - System.system_time(:millisecond), 0)
        )
    end
  end

  defp eligible?(state, id, entry, active) do
    not entry.delivered and not MapSet.member?(active, id) and
      retry_ready?(Map.get(state.retries, id)) and
      cooldown_ready?(Map.get(state.cooldowns, id))
  end

  defp cooldown_ready?(nil), do: true
  defp cooldown_ready?(deadline), do: deadline <= System.monotonic_time(:millisecond)

  defp retry_ready?(nil), do: true
  defp retry_ready?(%{dead_letter: true}), do: false
  defp retry_ready?(%{next_at: next_at}), do: next_at <= System.system_time(:millisecond)

  defp prune(state, ids) do
    state = %{
      state
      | retries: Map.drop(state.retries, ids),
        cooldowns: Map.drop(state.cooldowns, ids),
        last_errors: Map.drop(state.last_errors, ids)
    }

    persist!(state, Map.drop(state.entries, ids))
  end

  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _ -> :opaque_error
    end
  end

  defp safe_reason(_reason), do: :opaque_error

  defp event_id(id, ref), do: "outcome:" <> Value.digest!({id, ref})

  defp persist!(state, entries) do
    case save_entries(state, entries) do
      {:ok, next} -> next
      {:error, reason} -> exit({:dispatcher_store_failed, reason})
    end
  end

  defp acquire_tracking(state, entries) do
    case save_entries(state, entries) do
      {:ok, next} -> {:reply, :ok, launch_available(next)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp save_entries(state, entries) do
    case state.store_module.compare_and_swap(state.store, state.key, state.revision, %{
           version: 2,
           entries: entries,
           retries: state.retries
         }) do
      {:ok, revision} -> {:ok, %{state | entries: entries, revision: revision}}
      {:error, _} = error -> error
    end
  end

  defp load(module, store, key) do
    case module.fetch(store, key) do
      :not_found ->
        create_store(module, store, key)

      {:ok, %{revision: revision, value: snapshot}} ->
        restore_entries(revision, snapshot)

      _ ->
        {:error, :invalid_dispatcher_checkpoint}
    end
  end

  defp create_store(module, store, key) do
    case module.put_new(store, key, %{version: 2, entries: %{}, retries: %{}}) do
      {:ok, revision} -> {:ok, revision, %{}, %{}}
      {:error, :exists} -> load(module, store, key)
      error -> error
    end
  end

  defp restore_entries(revision, %{version: 1, entries: entries}),
    do: restore_entries(revision, %{version: 2, entries: entries, retries: %{}})

  defp restore_entries(revision, %{version: 2, entries: entries, retries: retries})
       when is_map(entries) and is_map(retries) do
    if Enum.all?(entries, &valid_entry?/1) and Enum.all?(retries, &valid_retry?/1),
      do: {:ok, revision, entries, retries},
      else: {:error, :invalid_dispatcher_checkpoint}
  end

  defp restore_entries(_revision, _snapshot), do: {:error, :invalid_dispatcher_checkpoint}

  defp valid_entry?(
         {id,
          %{binding: binding, event_ref: ref, delivered: delivered, last_event_ref: last} = entry}
       ) do
    is_binary(id) and byte_size(id) > 0 and is_map(binding) and map_size(entry) == 4 and
      is_boolean(delivered) and optional_event_ref?(ref) and optional_event_ref?(last) and
      Enum.all?([:agent_ref, :tag, :recovery], &Map.has_key?(binding, &1))
  end

  defp valid_entry?(_), do: false

  defp optional_event_ref?(nil), do: true
  defp optional_event_ref?(value) when is_binary(value), do: true
  defp optional_event_ref?(_value), do: false

  defp valid_retry?({_id, %{failures: count, next_at: time, dead_letter: dead}}),
    do: is_integer(count) and count >= 0 and is_integer(time) and is_boolean(dead)

  defp valid_retry?(_), do: false
end
