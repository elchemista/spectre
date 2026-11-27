defmodule Spectre.Server.CheckpointTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.

  defmodule App do
    use Spectre.Server
    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")
    def handle_flow({:test, "slow"}, _input, ctx), do: generate(ctx, :slow)

    def handle_flow({:test, "await"}, _input, ctx),
      do: await_reply(ctx, "wait", timeout: 500, on_result: :awaited)

    def handle_result(:awaited, {:error, :timeout}, ctx),
      do: ctx |> assign(:expired, true) |> no_response()

    def handle_result(:delivered, value, ctx),
      do: ctx |> assign(:count, Map.get(ctx.assigns, :count, 0) + value) |> no_response()

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_call(:bad_assign, _from, ctx),
      do: {:reply, :must_not_reply, assign(ctx, :bad, make_ref())}

    def handle_call(:remember, _from, ctx), do: {:reply, :ok, assign(ctx, :remembered, true)}
    def handle_call(request, from, ctx), do: super(request, from, ctx)
  end

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.CheckpointTest.App
  end

  defmodule Router do
    def route(agent, input, _opts) do
      route = %Spectre.Route{
        label: input.text,
        flow: :test,
        owner: agent,
        scope: :agent,
        handler: {:server, {[:test], input.text}, []},
        accepted?: true
      }

      {:ok, {:test, input.text}, %{reason: nil, route: route}}
    end
  end

  defmodule Service do
    def generate(_request, context, _opts) do
      send(context.options[:test_pid], {:checkpoint_worker, self()})

      receive do
        :release -> {:generated, %{text: "finished", proposals: []}}
      end
    end
  end

  defmodule Payloads do
    @behaviour Spectre.Payload.Store

    def put(bytes, context, opts) do
      send(opts[:owner], {:checkpoint_payload_put, self(), context})
      if opts[:kill], do: Process.exit(self(), :kill)

      if opts[:block] do
        receive do
          :release -> :ok
        end
      end

      reference =
        Elixir.Agent.get_and_update(opts[:store], fn state ->
          reference = %{"object" => Integer.to_string(map_size(state) + 1)}
          {reference, Map.put(state, reference, bytes)}
        end)

      {:ok, reference}
    end

    def fetch(reference, context, opts) do
      send(opts[:owner], {:checkpoint_payload_fetch, self(), context})

      Elixir.Agent.get(opts[:store], &Map.fetch(&1, reference))
      |> case do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule VersionedCheckpoints do
    def entries(history, key, limit), do: {:ok, history |> Map.fetch!(key) |> Enum.take(limit)}
  end

  defp store do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-server-checkpoint-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  test "checkpoints preserve the legacy wire tag for governed records" do
    row = %ExGAM.Row{attempt: true, write: true}
    new_tag = "Elixir.ExGAM.Row"
    old_tag = "Elixir.Spectre.GAM.Row"

    assert {:ok, <<"SPCV", 1, 0x23, 16::32, ^new_tag::binary-size(16), fields::binary>>} =
             ExGAM.Canonical.Value.encode(row, allowed_structs: [ExGAM.Row])

    old_bytes = <<"SPCV", 1, 0x23, byte_size(old_tag)::32, old_tag::binary, fields::binary>>

    assert {:ok, ^row} = Server.Checkpoint.decode_snapshot(old_bytes)
    assert {:ok, ^old_bytes} = Server.Checkpoint.encode_value(row)
  end

  test "a payload-backed checkpoint reader forwards the adapter's history bound" do
    entries = [%{revision: 2}, %{revision: 1}]
    reader = %{adapter: VersionedCheckpoints, store: %{agent: entries}}
    assert {:ok, [%{revision: 2}]} = Server.Checkpoint.entries(reader, :agent, 1)

    reader = %{reader | adapter: Server.Store.Disk}

    assert {:error, :checkpoint_history_unavailable} =
             Server.Checkpoint.entries(reader, :agent, 1)
  end

  test "acquired state and delivery inbox survive restart together" do
    store = store()
    opts = [agent: Agent, identity: %{account_id: "one"}, checkpoint: {store, "one"}]
    {:ok, first} = Spectre.Server.Runtime.start_link(opts)
    assert :ok = GenServer.call(first, :remember)
    assert :ok = Server.deliver(first, "event-one", :delivered, 2)
    assert :ok = Server.deliver(first, "event-one", :delivered, 2)
    assert Server.status(first).assigns == %{count: 2, remembered: true}
    GenServer.stop(first)
    {:ok, second} = Spectre.Server.Runtime.start_link(opts)
    assert Server.status(second).assigns == %{count: 2, remembered: true}
    assert :ok = Server.deliver(second, "event-one", :delivered, 2)
    assert :ok = Server.deliver(second, "event-two", :delivered, 3)
    assert Server.status(second).assigns.count == 5
    GenServer.stop(second)
  end

  test "delivery requires durable acquisition rather than an in-memory acknowledgement" do
    {:ok, server} = Spectre.Server.Runtime.start_link(agent: Agent)
    assert {:error, :checkpoint_required} = Server.deliver(server, "event-one", :delivered, 1)
    assert Server.status(server).assigns == %{}
    GenServer.stop(server)
  end

  test "external checkpoint stores only an opaque reference and restores private state" do
    store = store()
    payloads = start_supervised!({Elixir.Agent, fn -> %{} end})
    config = {Payloads, store: payloads, owner: self()}

    opts = [
      agent: Agent,
      checkpoint: {store, "private-checkpoint"},
      payload_store: config,
      assigns: %{private: "private-value-must-not-enter-checkpoint-db"}
    ]

    {:ok, first} = Server.Runtime.start_link(opts)
    assert :ok = GenServer.call(first, :remember)
    assert :ok = Server.deliver(first, "private-event", :delivered, 3)
    assert_receive {:checkpoint_payload_put, worker, %{kind: :server_checkpoint}}
    assert worker != first
    worker_monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
    GenServer.stop(first)

    {:ok, %{value: bytes}} = Server.Store.Disk.fetch(store, "private-checkpoint")
    refute String.contains?(bytes, "private-value-must-not-enter-checkpoint-db")

    assert {:ok, %{format: "spectre/payload-checkpoint", version: 1, reference: reference}} =
             Server.Checkpoint.decode_snapshot(bytes)

    assert is_map(reference)

    assert {:error, _} = Server.Checkpoint.decode_snapshot(<<255>>, payload_store: config)
    refute_received {:checkpoint_payload_fetch, _, _}

    assert {:ok, %{assigns: %{count: 3}}} =
             Server.Checkpoint.decode_snapshot(bytes, payload_store: config)

    assert_receive {:checkpoint_payload_fetch, _, %{key: nil, revision: nil}}

    assert {:ok, %{assigns: %{count: 3, remembered: true, private: _}}} =
             Server.Checkpoint.decode_snapshot(bytes, opts)

    assert {:ok, %{checkpoint: %{pending: 0, outbox: 0, inbox: 0}}} =
             Server.Diagnostics.read(%{opts: opts}, [])

    assert %{adapter: reader, store: reader_state, key: key} =
             Server.Checkpoint.tool_reference(%{opts: opts})

    assert {:ok, %{value: inspected}} = reader.fetch(reader_state, key)
    assert {:ok, %{assigns: %{count: 3}}} = Server.Checkpoint.decode_snapshot(inspected)

    {:ok, second} = Server.Runtime.start_link(opts)

    assert Server.status(second).assigns == %{
             count: 3,
             remembered: true,
             private: "private-value-must-not-enter-checkpoint-db"
           }

    assert :ok = Server.deliver(second, "private-event", :delivered, 3)
    assert Server.status(second).assigns.count == 3
    GenServer.stop(second)
  end

  @tag :capture_log
  test "missing external checkpoint content fails recovery without an inline fallback" do
    store = store()
    payloads = start_supervised!({Elixir.Agent, fn -> %{} end})

    opts = [
      agent: Agent,
      checkpoint: {store, "missing"},
      payload_store: {Payloads, store: payloads, owner: self()}
    ]

    {:ok, server} = Server.Runtime.start_link(opts)
    GenServer.stop(server)
    {:ok, %{value: bytes}} = Server.Store.Disk.fetch(store, "missing")
    Elixir.Agent.update(payloads, fn _ -> %{} end)

    assert {:error, _} = Server.Runtime.start_link(opts)
    assert {:error, :not_found} = Server.Checkpoint.decode_snapshot(bytes, opts)

    assert {:error, :checkpoint_payload_store_required} =
             Server.Checkpoint.decode_snapshot(bytes, [])

    assert {:ok, %{value: ^bytes}} = Server.Store.Disk.fetch(store, "missing")
  end

  @tag :capture_log
  test "a timed out payload worker is stopped before checkpoint acquisition" do
    store = store()
    payloads = start_supervised!({Elixir.Agent, fn -> %{} end})

    opts = [
      agent: Agent,
      checkpoint: {store, "timeout"},
      payload_timeout: 10,
      payload_store: {Payloads, store: payloads, owner: self(), block: true}
    ]

    assert {:error, _} = Server.Runtime.start_link(opts)
    assert_receive {:checkpoint_payload_put, worker, %{kind: :server_checkpoint}}
    worker_monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
    assert Server.Store.Disk.fetch(store, "timeout") == :not_found
    assert Elixir.Agent.get(payloads, & &1) == %{}
  end

  @tag :capture_log
  test "a killed callback returns a storage error and invalid deadlines do not launch workers" do
    store = store()
    payloads = start_supervised!({Elixir.Agent, fn -> %{} end})

    opts = [
      agent: Agent,
      checkpoint: {store, "killed"},
      payload_store: {Payloads, store: payloads, owner: self(), kill: true}
    ]

    assert {:error, {%ArgumentError{message: message}, _}} = Server.Runtime.start_link(opts)
    assert message =~ "checkpoint_payload_unavailable"
    assert_receive {:checkpoint_payload_put, worker, _}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert Server.Store.Disk.fetch(store, "killed") == :not_found

    assert {:error, {%ArgumentError{message: invalid}, _}} =
             Server.Runtime.start_link(Keyword.put(opts, :payload_timeout, -1))

    assert invalid =~ "invalid_checkpoint_payload_timeout"
    refute_received {:checkpoint_payload_put, _, _}
  end

  test "a payload worker is cancelled when its checkpoint owner dies before acquisition" do
    store = store()
    server = start_supervised!({Server.Runtime, agent: Agent, checkpoint: {store, "owner-loss"}})
    before = :sys.get_state(server)
    {:ok, original} = Server.Store.Disk.fetch(store, "owner-loss")
    payloads = start_supervised!({Elixir.Agent, fn -> %{} end})

    options =
      Keyword.put(
        before.opts,
        :payload_store,
        {Payloads, store: payloads, owner: self(), block: true}
      )

    task =
      Task.Supervisor.async_nolink(Spectre.Server.TaskSupervisor, fn ->
        Server.Checkpoint.save(%{before | opts: options})
      end)

    assert_receive {:checkpoint_payload_put, worker, _}, 2_000
    monitor = Process.monitor(worker)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    assert {:ok, ^original} = Server.Store.Disk.fetch(store, "owner-loss")
    assert Elixir.Agent.get(payloads, & &1) == %{}
    assert Server.status(server).assigns == %{}
  end

  test "a consent result staged before a crash restores suspended instead of reusing its old show" do
    store = store()
    opts = [agent: Agent, checkpoint: {store, "staged-consent"}]
    {:ok, first} = Server.Runtime.start_link(opts)
    GenServer.stop(first)
    {:ok, %{revision: revision, value: bytes}} = Server.Store.Disk.fetch(store, "staged-consent")
    {:ok, snapshot} = Server.Checkpoint.decode_snapshot(bytes)

    entry = %{
      worker: %{kind: :propose, tag: :delivered, event: nil, command_id: "operation"},
      result: {:pending, %{operation: :send, presentation: %{ref: "old-show"}}}
    }

    {:ok, bytes} = Server.Checkpoint.encode_value(%{snapshot | inbox: %{"result" => entry}})
    assert {:ok, _} = Server.Store.Disk.compare_and_swap(store, "staged-consent", revision, bytes)
    {:ok, restored} = Server.Runtime.start_link(opts)

    assert [%{status: :suspended, presentation: %{ref: "old-show"}}] =
             Server.status(restored).pending

    assert :sys.get_state(restored).foreground == nil
    assert :sys.get_state(restored).inbox == %{}
    GenServer.stop(restored)
  end

  test "accepted active and queued inputs survive restart without losing the queued event" do
    store = store()

    opts = [
      agent: Agent,
      checkpoint: {store, "queued"},
      consumer: self(),
      test_pid: self(),
      services: [router: Router, generate: Service]
    ]

    {:ok, first} = Spectre.Server.Runtime.start_link(opts)
    {:ok, first_id} = Server.input(first, "slow")
    assert_receive {:checkpoint_worker, _first_worker}, 2_000
    {:ok, second_id} = Server.input(first, "echo")
    GenServer.stop(first)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert_receive {:checkpoint_worker, worker}, 2_000
    send(worker, :release)
    assert_receive {Server, ^restored, {:response, ^first_id, "finished", _}}, 2_000
    assert_receive {Server, ^restored, {:response, ^second_id, "echo", _}}, 2_000
    GenServer.stop(restored)
  end

  test "a reply wait restores its absolute deadline and expires once" do
    store = store()
    opts = [agent: Agent, checkpoint: {store, "await"}, services: [router: Router]]
    {:ok, first} = Spectre.Server.Runtime.start_link(opts)
    {:ok, _id} = Server.input(first, "await")
    eventually(fn -> Server.status(first).pending != [] end)
    GenServer.stop(first)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    eventually(fn -> Server.status(restored).assigns[:expired] == true end)
    assert Server.status(restored).pending == []
    GenServer.stop(restored)
  end

  defp eventually(check, remaining \\ 400)
  defp eventually(_check, 0), do: flunk("condition not reached")

  defp eventually(check, remaining) do
    unless check.() do
      Process.sleep(5)
      eventually(check, remaining - 1)
    end
  end

  @tag :capture_log
  test "nonportable application data fails before a successful OTP reply" do
    store = store()
    {:ok, server} = Spectre.Server.Runtime.start_link(agent: Agent, checkpoint: {store, "bad"})
    Process.unlink(server)
    monitor = Process.monitor(server)
    catch_exit(GenServer.call(server, :bad_assign))
    assert_receive {:DOWN, ^monitor, :process, ^server, _}
    {:ok, restored} = Spectre.Server.Runtime.start_link(agent: Agent, checkpoint: {store, "bad"})
    assert Server.status(restored).assigns == %{}
    GenServer.stop(restored)
  end
end
