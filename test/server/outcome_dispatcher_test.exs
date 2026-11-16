defmodule Spectre.Server.OutcomeDispatcherTest do
  use ExUnit.Case, async: false

  alias Spectre.Server.OutcomeDispatcher
  alias Spectre.Server.Store.Disk

  defmodule Adapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter

    @impl true
    def recover(_binding, reference, opts) do
      state = Agent.get(Keyword.fetch!(opts, :control), & &1)
      reference = reference || state.current
      {:ok, reference, Map.fetch!(state.results, reference)}
    end

    @impl true
    def deliver(binding, event_id, result, opts) do
      state = Agent.get(Keyword.fetch!(opts, :control), & &1)
      send(state.recipient, {:delivery, binding.tag, event_id, result})
      if state.ack, do: :ok, else: {:error, :ack_lost}
    end
  end

  defmodule PendingFirstAdapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter

    def recover(%{recovery: "pending"}, _reference, _opts), do: :pending
    def recover(binding, reference, opts), do: Adapter.recover(binding, reference, opts)
    defdelegate deliver(binding, event_id, result, opts), to: Adapter
  end

  defmodule RecoveringAdapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter

    def recover(binding, reference, opts) do
      case Agent.get(Keyword.fetch!(opts, :control), &Map.get(&1, :recover_error)) do
        nil -> Adapter.recover(binding, reference, opts)
        reason -> {:error, reason}
      end
    end

    defdelegate deliver(binding, event_id, result, opts), to: Adapter
  end

  defmodule PoisonAdapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter
    def recover(binding, _ref, opts) do
      control = Keyword.fetch!(opts, :control)
      recipient = Agent.get(control, & &1.recipient)
      send(recipient, {:recover_attempt, binding.tag, System.monotonic_time(:millisecond)})
      {:error, :temporarily_unavailable}
    end

    defdelegate deliver(binding, event_id, result, opts), to: Adapter
  end

  setup %{tmp_dir: directory} do
    path = Path.join(directory, "dispatcher.snapshot")
    store = start_supervised!({Disk, path: path})

    recipient = self()

    control =
      start_supervised!(
        {Agent,
         fn ->
           %{
             recipient: recipient,
             ack: false,
             current: "observation:1",
             results: %{"observation:1" => :succeeded, "observation:2" => :reconciled}
           }
         end}
      )

    opts = [
      store: store,
      adapter: Adapter,
      adapter_options: [control: control],
      interval: 10_000,
      backoff_ms: 10,
      max_backoff_ms: 100
    ]

    %{store: store, control: control, opts: opts, path: path}
  end

  @tag :tmp_dir
  test "pins a durable revision and redelivers the same event after a lost ack and restart", c do
    dispatcher = start_supervised!({OutcomeDispatcher, c.opts}, id: :dispatcher)
    binding = %{agent_ref: "agent:customer", tag: :deleted, recovery: %{act_ref: "act:1"}}
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:1", binding)
    assert_receive {:delivery, :deleted, event_id, :succeeded}, 2_000
    assert :ok = stop_supervised(:dispatcher)

    Agent.update(c.control, &%{&1 | ack: true, current: "observation:2"})
    dispatcher = start_supervised!({OutcomeDispatcher, c.opts}, id: :dispatcher)
    assert_receive {:delivery, :deleted, ^event_id, :succeeded}, 2_000
    eventually(fn -> OutcomeDispatcher.status(dispatcher).entries["operation:1"].delivered end)

    assert :ok = OutcomeDispatcher.refresh(dispatcher, "operation:1")
    assert_receive {:delivery, :deleted, next_event_id, :reconciled}, 2_000
    refute next_event_id == event_id
  end

  @tag :tmp_dir
  test "tracking is idempotent and cannot change a saved operation binding", c do
    dispatcher = start_supervised!({OutcomeDispatcher, c.opts})
    binding = %{agent_ref: "agent:customer", tag: :deleted, recovery: %{act_ref: "act:1"}}
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:1", binding)
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:1", binding)

    assert {:error, :operation_binding_conflict} =
             OutcomeDispatcher.track(dispatcher, "operation:1", %{binding | tag: :other})

    assert {:error, :invalid_operation_binding} =
             OutcomeDispatcher.track(dispatcher, "operation:2", %{binding | recovery: self()})
  end

  @tag :tmp_dir
  test "a refresh of the same durable observation does not deliver it again", c do
    Agent.update(c.control, &%{&1 | ack: true})
    dispatcher = start_supervised!({OutcomeDispatcher, c.opts})
    binding = %{agent_ref: "agent:customer", tag: :deleted, recovery: "act:1"}
    :ok = OutcomeDispatcher.track(dispatcher, "operation:1", binding)
    assert_receive {:delivery, :deleted, _id, :succeeded}, 2_000
    eventually(fn -> OutcomeDispatcher.status(dispatcher).entries["operation:1"].delivered end)
    :ok = OutcomeDispatcher.refresh(dispatcher, "operation:1")
    eventually(fn -> OutcomeDispatcher.status(dispatcher).entries["operation:1"].delivered end)
    refute_receive {:delivery, _, _, _}, 100
  end

  @tag :tmp_dir
  test "a permanently pending operation cannot starve a later ready result", c do
    Agent.update(c.control, &%{&1 | ack: true})
    opts = Keyword.merge(c.opts, adapter: PendingFirstAdapter, max_concurrency: 1, interval: 10)
    dispatcher = start_supervised!({OutcomeDispatcher, opts})
    pending = %{agent_ref: "agent:customer", tag: :pending, recovery: "pending"}
    ready = %{agent_ref: "agent:customer", tag: :ready, recovery: "ready"}
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:a", pending)
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:b", ready)
    assert_receive {:delivery, :ready, _event_id, :succeeded}, 1_000
    assert not OutcomeDispatcher.status(dispatcher).entries["operation:a"].delivered
  end

  @tag :tmp_dir
  test "adapter failures are observable without exposing payloads and clear after recovery", c do
    Agent.update(
      c.control,
      &(&1 |> Map.put(:recover_error, %{secret: "do-not-expose"}) |> Map.put(:ack, true))
    )

    opts = Keyword.merge(c.opts, adapter: RecoveringAdapter, interval: 10)
    dispatcher = start_supervised!({OutcomeDispatcher, opts})
    binding = %{agent_ref: "agent:customer", tag: :recovered, recovery: "act:1"}
    assert :ok = OutcomeDispatcher.track(dispatcher, "operation:1", binding)
    eventually(fn -> map_size(OutcomeDispatcher.status(dispatcher).last_errors) == 1 end)
    status = OutcomeDispatcher.status(dispatcher)
    assert status.last_errors == %{"operation:1" => %{stage: :recover, reason: :opaque_error}}
    refute inspect(status) =~ "do-not-expose"

    Agent.update(c.control, &Map.delete(&1, :recover_error))
    assert_receive {:delivery, :recovered, _id, :succeeded}, 1_000
    eventually(fn -> OutcomeDispatcher.status(dispatcher).last_errors == %{} end)
  end

  @tag :tmp_dir
  test "ready results refill the single worker slot without waiting for the poll interval", c do
    Agent.update(c.control, &%{&1 | ack: true})
    dispatcher = start_supervised!({OutcomeDispatcher, Keyword.put(c.opts, :max_concurrency, 1)})

    for index <- 1..5 do
      :ok =
        OutcomeDispatcher.track(dispatcher, "operation:#{index}", %{
          agent_ref: "agent:customer",
          tag: index,
          recovery: "ready"
        })
    end

    for index <- 1..5, do: assert_receive({:delivery, ^index, _id, :succeeded}, 1_000)
    assert OutcomeDispatcher.status(dispatcher).workers <= 1
  end

  @tag :tmp_dir
  test "retry backoff and dead letters survive restart until explicitly retried", c do
    opts =
      Keyword.merge(c.opts, adapter: PoisonAdapter, interval: 10, backoff_ms: 30, max_attempts: 2)

    dispatcher = start_supervised!({OutcomeDispatcher, opts}, id: :dispatcher)

    :ok =
      OutcomeDispatcher.track(dispatcher, "operation:poison", %{
        agent_ref: "agent",
        tag: :poison,
        recovery: "act"
      })

    assert_receive {:recover_attempt, :poison, first}, 1_000
    assert_receive {:recover_attempt, :poison, second}, 1_000
    assert second - first >= 25

    eventually(fn ->
      OutcomeDispatcher.status(dispatcher).retries["operation:poison"].dead_letter
    end)

    :ok = stop_supervised(:dispatcher)
    dispatcher = start_supervised!({OutcomeDispatcher, opts}, id: :dispatcher)
    refute_receive {:recover_attempt, :poison, _}, 80
    assert :ok = OutcomeDispatcher.retry(dispatcher, "operation:poison")
    assert_receive {:recover_attempt, :poison, _}, 1_000
  end

  @tag :tmp_dir
  test "capacity and compaction preserve unacquired operations", c do
    Agent.update(c.control, &%{&1 | ack: true})
    opts = Keyword.merge(c.opts, adapter: PendingFirstAdapter, max_entries: 2, interval: 10)
    dispatcher = start_supervised!({OutcomeDispatcher, opts})

    :ok =
      OutcomeDispatcher.track(dispatcher, "pending", %{
        agent_ref: "agent",
        tag: :pending,
        recovery: "pending"
      })

    :ok =
      OutcomeDispatcher.track(dispatcher, "ready", %{
        agent_ref: "agent",
        tag: :ready,
        recovery: "ready"
      })

    assert_receive {:delivery, :ready, _id, :succeeded}, 1_000
    eventually(fn -> OutcomeDispatcher.status(dispatcher).entries["ready"].delivered end)

    assert {:error, :dispatcher_capacity_exceeded} =
             OutcomeDispatcher.track(dispatcher, "extra", %{
               agent_ref: "agent",
               tag: :extra,
               recovery: "ready"
             })

    assert {:error, :operation_not_acquired} = OutcomeDispatcher.forget(dispatcher, "pending")
    assert {:ok, 1} = OutcomeDispatcher.compact(dispatcher, 0)
    assert Map.keys(OutcomeDispatcher.status(dispatcher).entries) == ["pending"]

    assert :ok =
             OutcomeDispatcher.track(dispatcher, "extra", %{
               agent_ref: "agent",
               tag: :extra,
               recovery: "ready"
             })
  end

  @tag :tmp_dir
  test "snapshot byte capacity rejects tracking without crashing or acquiring the operation", c do
    store =
      start_supervised!(
        {Disk, path: Path.join(Path.dirname(c.path), "small.snapshot"), max_bytes: 512},
        id: :small_store
      )

    dispatcher = start_supervised!({OutcomeDispatcher, Keyword.put(c.opts, :store, store)})

    assert {:error, :store_capacity_exceeded} =
             OutcomeDispatcher.track(dispatcher, "large", %{
               agent_ref: "agent",
               tag: :large,
               recovery: String.duplicate("x", 1_000)
             })

    assert Process.alive?(dispatcher)
    assert OutcomeDispatcher.status(dispatcher).entries == %{}
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
