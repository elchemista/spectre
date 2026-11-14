defmodule Spectre.Server.NativeApplicationStateTest do
  use ExUnit.Case, async: true

  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.
  alias Spectre.Server.{Command, Context}
  alias Spectre.Server.Store.Disk

  defmodule Probe do
    def generate(_request, context, _opts) do
      send(context.options[:test_pid], {:service_context, context})
      {:generated, %{text: "probe complete", proposals: []}}
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:support, :probe}, _input, ctx),
      do: ctx |> put_private(:local_secret, make_ref()) |> generate(:probe)

    def handle_flow(route, input, ctx), do: super(route, input, ctx)

    def handle_call(:install_timer, _from, ctx) do
      timer = Process.send_after(self(), :application_tick, 10)

      ctx =
        ctx
        |> put_private(:timer, timer)
        |> put_private(%{owner: self(), native_marker: make_ref()})

      {:reply, {self(), timer}, ctx}
    end

    def handle_call(:local_state, _from, ctx) do
      {:reply, {ctx.private, ctx.assigns}, ctx}
    end

    def handle_call(:remove_timer, _from, ctx) do
      {:reply, get_private(ctx, :timer), delete_private(ctx, :timer)}
    end

    def handle_call(message, from, ctx), do: super(message, from, ctx)

    def handle_info(:application_tick, ctx),
      do: {:noreply, assign(ctx, :ticks, Map.get(ctx.assigns, :ticks, 0) + 1)}

    def handle_info(message, ctx), do: super(message, ctx)
  end

  defmodule Definition do
    use Spectre.Agent, server: App

    flow :support do
      on(:probe, regex: ~r/^probe$/)
    end
  end

  @tag :tmp_dir
  test "native OTP timers and handles stay process-local while application assigns survive restart",
       %{tmp_dir: dir} do
    store = start_supervised!({Disk, path: Path.join(dir, "native.snapshot")})
    opts = [agent: Definition, checkpoint: {store, "native"}]
    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    assert {^server, timer} = GenServer.call(server, :install_timer)
    assert is_reference(timer)
    eventually(fn -> elem(GenServer.call(server, :local_state), 1)[:ticks] == 1 end)

    assert {%{owner: ^server, timer: ^timer, native_marker: marker}, %{ticks: 1}} =
             GenServer.call(server, :local_state)

    assert is_reference(marker)
    assert ^timer = GenServer.call(server, :remove_timer)
    assert {%{owner: ^server}, %{ticks: 1}} = GenServer.call(server, :local_state)

    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert {%{}, %{ticks: 1}} = GenServer.call(restored, :local_state)
  end

  test "pending views can be inspected without granting a state mutation channel" do
    pending = %{id: "intent:one", revision: 2, status: :suspended}
    ctx = %Context{pending_by_id: %{pending.id => pending}}
    assert Server.get_pending(ctx, pending.id) == pending
    assert Server.get_pending(ctx, "absent") == nil
  end

  @tag :tmp_dir
  test "process-local data and reserved private startup options stay out of cognitive service context",
       %{tmp_dir: dir} do
    store = start_supervised!({Disk, path: Path.join(dir, "probe.snapshot")})

    {:ok, server} =
      Spectre.Server.Runtime.start_link(
        agent: Definition,
        checkpoint: {store, "probe"},
        consumer: self(),
        test_pid: self(),
        private: %{startup_secret: make_ref()},
        services: [generate: Probe]
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert {:ok, interaction} = Server.input(server, "probe")
    assert_receive {:service_context, context}, 2_000
    refute Map.has_key?(context, :private)
    refute Keyword.has_key?(context.options, :private)
    refute inspect(context) =~ "local_secret"
    assert_receive {Server, ^server, {:response, ^interaction, "probe complete", _}}, 2_000
    assert {%{local_secret: secret}, %{}} = GenServer.call(server, :local_state)
    assert is_reference(secret)
  end

  test "lifecycle helpers retain explicit timer guards and reject invalid policies before I/O" do
    ctx =
      %Context{}
      |> Server.close_pending_after("intent:one", 0,
        if_revision: 2,
        reason: :topic_changed,
        policy_ref: "policy:idle",
        timer: :application
      )
      |> Server.cancel_pending_close("intent:one", if_revision: 2)
      |> Server.close_pending("intent:one", if_revision: 2, reason: :idle_timeout)

    assert Enum.map(ctx.commands, & &1.kind) ==
             [:close_pending_after, :cancel_pending_close, :close_pending]

    assert Enum.all?(ctx.commands, &(Command.validate(&1) == :ok))

    for command <- [
          %Command{kind: :close_pending_after, args: ["one", -1]},
          %Command{kind: :close_pending_after, args: ["one", :infinity]},
          %Command{kind: :close_pending, args: ["one"], opts: [if_revision: 0]},
          %Command{kind: :close_pending, args: ["one"], opts: [policy_ref: ""]},
          %Command{kind: :close_pending, args: ["one"], opts: [if_schedule: ""]},
          %Command{kind: :close_pending_after, args: ["one", 5], opts: [timer: :unknown]},
          %Command{kind: :route_current_input, args: [], opts: [lifecycle_recorded: true]},
          %Command{kind: :resume_pending, args: ["one"], opts: [lifecycle_authorized: true]},
          %Command{kind: :close_pending, args: ["one"], opts: [reason: %{unportable: self()}]}
        ] do
      assert {:error, _} = Command.validate(command)
    end
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
