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

  defp store do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-server-checkpoint-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
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
