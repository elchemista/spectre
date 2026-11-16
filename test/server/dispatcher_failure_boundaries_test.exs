defmodule Spectre.Server.DispatcherFailureBoundariesTest do
  use ExUnit.Case, async: false
  alias Spectre.Server.OutcomeDispatcher, as: Dispatcher
  alias Spectre.Server.Store.Disk

  defmodule Adapter do
    @behaviour Spectre.Server.OutcomeDispatcher.Adapter
    def recover(%{recovery: :blocked}, _ref, opts) do
      send(opts[:recipient], {:blocked, self()})

      receive do
        :release -> {:ok, "revision:1", :done}
      end
    end

    def recover(%{recovery: :raise}, _ref, _opts), do: raise("private failure payload")

    def recover(%{recovery: :tuple_error}, _ref, _opts),
      do: {:error, {:service_unavailable, "private payload"}}

    def recover(%{recovery: :invalid}, _ref, _opts), do: :invalid_reply
    def recover(%{recovery: :mismatch}, nil, _opts), do: {:ok, "revision:1", :done}
    def recover(%{recovery: :mismatch}, _ref, _opts), do: {:ok, "revision:2", :different}

    def deliver(binding, id, result, opts) do
      send(opts[:recipient], {:delivery, binding.tag, id, result})
      {:error, :receiver_unavailable}
    end
  end

  setup %{tmp_dir: directory} do
    store = start_supervised!({Disk, path: Path.join(directory, "dispatcher.snapshot")})

    opts = [
      store: store,
      adapter: Adapter,
      adapter_options: [recipient: self()],
      interval: 10,
      backoff_ms: 10,
      max_attempts: 1,
      worker_timeout: 20
    ]

    %{store: store, opts: opts}
  end

  @tag :tmp_dir
  test "hung and crashed workers preserve tracked work and surface sanitized dead letters", c do
    dispatcher = start_supervised!({Dispatcher, c.opts})
    track(dispatcher, "blocked", :blocked)
    assert_receive {:blocked, worker}, 1_000
    eventually(fn -> Map.has_key?(Dispatcher.status(dispatcher).last_errors, "blocked") end)
    refute Process.alive?(worker)
    assert Dispatcher.status(dispatcher).last_errors["blocked"].reason == :timeout
    assert Dispatcher.status(dispatcher).retries["blocked"].dead_letter
    assert {:error, :operation_not_acquired} = Dispatcher.forget(dispatcher, "blocked")

    for mode <- [:raise, :tuple_error, :invalid] do
      id = Atom.to_string(mode)
      track(dispatcher, id, mode)
      eventually(fn -> Map.has_key?(Dispatcher.status(dispatcher).last_errors, id) end)
      assert Dispatcher.status(dispatcher).retries[id].dead_letter
    end

    assert Dispatcher.status(dispatcher).last_errors["raise"].reason ==
             :adapter_callback_exception

    assert Dispatcher.status(dispatcher).last_errors["tuple_error"].reason == :service_unavailable
    assert Dispatcher.status(dispatcher).last_errors["invalid"].reason == :invalid_adapter_reply
    refute inspect(Dispatcher.status(dispatcher)) =~ "private payload"
  end

  @tag :tmp_dir
  test "a pinned result revision cannot silently change after failed delivery", c do
    dispatcher = start_supervised!({Dispatcher, c.opts})
    track(dispatcher, "mismatch", :mismatch)
    assert_receive {:delivery, :mismatch, _id, :done}, 1_000
    eventually(fn -> Map.has_key?(Dispatcher.status(dispatcher).retries, "mismatch") end)
    assert :ok = Dispatcher.retry(dispatcher, "mismatch")

    eventually(fn ->
      Dispatcher.status(dispatcher).last_errors["mismatch"].reason ==
        :pinned_result_revision_mismatch
    end)

    refute_receive {:delivery, :mismatch, _, :different}, 50
    assert :ok = Dispatcher.refresh(dispatcher, "mismatch")
    assert {:error, :unknown_operation} = Dispatcher.refresh(dispatcher, "unknown")
    assert {:error, :unknown_operation} = Dispatcher.retry(dispatcher, "unknown")
    assert {:error, :unknown_operation} = Dispatcher.forget(dispatcher, "unknown")
    assert {:error, :invalid_retention_limit} = Dispatcher.compact(dispatcher, -1)
  end

  @tag :tmp_dir
  test "unsupported checkpoint versions fail closed rather than losing pending entries", c do
    {:ok, _} = Disk.put_new(c.store, "outcome_dispatcher", %{version: 99, entries: %{}})
    Process.flag(:trap_exit, true)
    assert {:error, :invalid_dispatcher_checkpoint} = Dispatcher.start_link(c.opts)
  end

  defp track(dispatcher, id, recovery) do
    :ok =
      Dispatcher.track(dispatcher, id, %{agent_ref: "agent", tag: recovery, recovery: recovery})
  end

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
