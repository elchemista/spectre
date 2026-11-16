defmodule Spectre.Server.DispatcherRecoveryBoundariesTest do
  use ExUnit.Case, async: false
  alias Spectre.Server.OutcomeDispatcher, as: Dispatcher
  alias Spectre.Server.Store.Disk

  defmodule Adapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter
    def recover(%{recovery: :blocked}, _ref, opts) do
      send(opts[:recipient], {:worker_ready, self()})

      receive do
        :release -> {:ok, "observation:1", :done}
      end
    end

    def recover(_, _ref, _opts), do: {:ok, "observation:1", :done}

    def deliver(_, id, _, opts) do
      send(opts[:recipient], {:acquired, id})
      :ok
    end
  end

  setup %{tmp_dir: directory} do
    store = start_supervised!({Disk, path: Path.join(directory, "dispatcher.snapshot")})

    opts = [
      store: store,
      adapter: Adapter,
      adapter_options: [recipient: self()],
      interval: 10_000,
      worker_timeout: 2_000,
      max_attempts: 1
    ]

    %{store: store, opts: opts}
  end

  @tag :tmp_dir
  test "externally killed workers retain their obligation and stale mailbox messages are harmless",
       c do
    dispatcher = start_supervised!({Dispatcher, c.opts})
    assert :ok = Dispatcher.track(dispatcher, "killed", operation_binding(:blocked))
    assert_receive {:worker_ready, worker}, 1_000
    Process.exit(worker, :kill)

    eventually(fn ->
      get_in(Dispatcher.status(dispatcher), [:retries, "killed", :dead_letter])
    end)

    assert Dispatcher.status(dispatcher).last_errors["killed"].reason == {:worker_exit, :killed}
    assert Dispatcher.status(dispatcher).entries["killed"].delivered == false
    unknown = make_ref()
    send(dispatcher, {unknown, {:ok, :stale}})
    send(dispatcher, {:DOWN, unknown, :process, self(), :normal})
    send(dispatcher, {Dispatcher, unknown, :timeout})
    assert Dispatcher.status(dispatcher).workers == 0
    assert {:error, :operation_not_acquired} = Dispatcher.forget(dispatcher, "killed")
  end

  @tag :tmp_dir
  test "only acquired entries can be explicitly forgotten after a legacy checkpoint upgrade", c do
    entry = %{
      binding: operation_binding(:ready),
      event_ref: "observation:0",
      delivered: true,
      last_event_ref: "observation:0"
    }

    assert {:ok, _} =
             Disk.put_new(c.store, "outcome_dispatcher", %{version: 1, entries: %{"old" => entry}})

    dispatcher = start_supervised!({Dispatcher, c.opts})
    assert {:ok, 0} = Dispatcher.compact(dispatcher)
    assert :ok = Dispatcher.forget(dispatcher, "old")
    assert Dispatcher.status(dispatcher).entries == %{}

    assert {:ok, %{value: %{version: 2, entries: %{}}}} =
             Disk.fetch(c.store, "outcome_dispatcher")
  end

  @tag :tmp_dir
  test "malformed saved obligations and invalid runtime limits fail closed", c do
    Process.flag(:trap_exit, true)

    valid = %{
      binding: operation_binding(:ready),
      event_ref: nil,
      delivered: false,
      last_event_ref: nil
    }

    snapshots = [
      %{version: 2, entries: %{"bad" => %{}}, retries: %{}},
      %{version: 2, entries: %{"bad" => %{valid | event_ref: 42}}, retries: %{}},
      %{version: 2, entries: %{}, retries: %{"bad" => %{}}}
    ]

    for {snapshot, index} <- Enum.with_index(snapshots) do
      key = "bad:#{index}"
      assert {:ok, _} = Disk.put_new(c.store, key, snapshot)

      assert {:error, :invalid_dispatcher_checkpoint} =
               Dispatcher.start_link(Keyword.put(c.opts, :key, key))
    end

    assert {:error, :invalid_dispatcher_options} =
             Dispatcher.start_link(Keyword.put(c.opts, :max_concurrency, 0))
  end

  @tag :tmp_dir
  @tag capture_log: true
  test "a lost checkpoint revision stops dispatch before unacquired delivery", c do
    Process.flag(:trap_exit, true)
    {:ok, dispatcher} = Dispatcher.start_link(c.opts)
    monitor = Process.monitor(dispatcher)
    assert :ok = Dispatcher.track(dispatcher, "conflict", operation_binding(:blocked))
    assert_receive {:worker_ready, worker}, 1_000
    {:ok, %{revision: revision, value: snapshot}} = Disk.fetch(c.store, "outcome_dispatcher")
    assert {:ok, _} = Disk.compare_and_swap(c.store, "outcome_dispatcher", revision, snapshot)
    send(worker, :release)

    assert_receive {:DOWN, ^monitor, :process, ^dispatcher,
                    {:dispatcher_store_failed, :conflict}},
                   1_000

    refute_receive {:acquired, _}, 20

    assert {:ok, %{value: %{entries: %{"conflict" => %{delivered: false, event_ref: nil}}}}} =
             Disk.fetch(c.store, "outcome_dispatcher")
  end

  defp operation_binding(recovery),
    do: %{agent_ref: "agent:one", tag: :finished, recovery: recovery}

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(function, attempts - 1)
        )
  end
end
