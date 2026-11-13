defmodule Spectre.Server.RuntimeBoundariesTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Actor do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, %{test: test, waiting: []}}

    def handle_call(:hold, from, state) do
      send(state.test, {:actor_called, elem(from, 0)})
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end

    def handle_call(:quote, _from, state), do: {:reply, {:ok, 42}, state}

    def handle_cast(:release, state) do
      Enum.each(state.waiting, &GenServer.reply(&1, {:ok, 42}))
      {:noreply, %{state | waiting: []}}
    end
  end

  defmodule Router do
    def route(agent, input, _opts) do
      route = %Spectre.Route{
        flow: :test,
        label: input.text,
        owner: agent,
        handler: {:server, {[:test], input.text}, []},
        accepted?: true
      }

      {:ok, {:test, input.text}, %{route: route, reason: nil}}
    end
  end

  defmodule App do
    use Spectre.Server
    def init(:ignore, _ctx), do: :ignore
    def init(:stop, _ctx), do: {:stop, :initialization_refused}
    def init(:invalid, _ctx), do: :invalid
    def init(:continue, ctx), do: {:ok, ctx, {:continue, :initialized}}
    def init(arg, ctx), do: {:ok, assign(ctx, :init_arg, arg)}
    def handle_continue(:initialized, ctx), do: {:noreply, assign(ctx, :continued, true)}

    def handle_flow({:test, "quote"}, _input, ctx),
      do: call_actor(ctx, ctx.assigns.actor, :quote, on_result: :quote)

    def handle_flow({:test, "hold"}, _input, ctx),
      do: call_actor(ctx, ctx.assigns.actor, :hold, on_result: :quote)

    def handle_flow({:test, "timeout"}, _input, ctx),
      do: call_actor(ctx, ctx.assigns.actor, :hold, timeout: 20, on_result: :timed)

    def handle_flow({:test, "missing_actor"}, _input, ctx),
      do: call_actor(ctx, :spectre_missing_actor_boundary_fixture, :quote, on_result: :missing)

    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")

    def handle_flow({:test, "wait"}, _input, ctx),
      do: await_input(ctx, "wait", on_result: :waited, timeout: 5_000)

    def handle_flow({:test, "combined"}, _input, ctx),
      do:
        ctx
        |> await_reply("combined", timeout: 5_000)
        |> call_actor(ctx.assigns.actor, :hold, on_result: :combined)

    def handle_flow({:test, "duplicate"}, _input, ctx),
      do: ctx |> await_reply("same") |> await_reply("same")

    def handle_flow({:test, "bad_suspend"}, _input, ctx),
      do: route_current_input(ctx, suspend: "missing")

    def handle_flow(route, input, ctx), do: super(route, input, ctx)

    def handle_pending(%{kind: :reply, id: id}, %{text: "resolve"}, ctx),
      do: resolve_await(ctx, id, {:ok, :resolved})

    def handle_pending(pending, _input, ctx), do: route_current_input(ctx, suspend: pending.id)

    def handle_result(tag, result, ctx) do
      if test = ctx.identity[:test],
        do: send(test, {:result_context, tag, result, ctx.interaction, ctx.input, self()})

      ctx
      |> assign(:results, Map.update(Map.get(ctx.assigns, :results, %{}), tag, 1, &(&1 + 1)))
      |> no_response()
    end

    def handle_call(:deferred, from, ctx) do
      send(self(), {:deferred_reply, from})
      {:noreply, ctx}
    end

    def handle_call(:infinity, _from, ctx), do: {:reply, :okay, ctx, :infinity}
    def handle_call(:stop_reply, _from, ctx), do: {:stop, :normal, :goodbye, ctx}
    def handle_call(:invalid_return, _from, _ctx), do: :invalid
    def handle_call(:invalid_action, _from, ctx), do: {:reply, :invalid, ctx, :unsupported_action}
    def handle_call({:resume, id}, _from, ctx), do: {:reply, :requested, resume_pending(ctx, id)}

    def handle_call({:confirm, id}, _from, ctx),
      do: {:reply, :requested, confirm_pending(ctx, id)}

    def handle_call(request, from, ctx), do: super(request, from, ctx)
    def handle_cast(:stop, ctx), do: {:stop, :normal, ctx}

    def handle_cast({:background_quote, actor}, ctx),
      do: {:noreply, call_actor(ctx, actor, :quote, on_result: :background)}

    def handle_cast({:resolve, id, result}, ctx), do: {:noreply, resolve_await(ctx, id, result)}

    def handle_info({:deferred_reply, from}, ctx) do
      GenServer.reply(from, :deferred)
      {:noreply, ctx}
    end

    def handle_info({:actor_event, value}, ctx), do: {:noreply, assign(ctx, :actor_event, value)}
    def handle_info(_message, ctx), do: {:noreply, ctx}
    def code_change(_old, _ctx, :refuse), do: {:error, :migration_refused}
    def code_change(_old, ctx, :upgrade), do: {:ok, assign(ctx, :upgraded, true)}
    def code_change(_old, ctx, :commands), do: {:ok, respond(ctx, "must not appear")}

    def terminate(reason, ctx) do
      if test = ctx.identity[:test], do: send(test, {:terminated, self(), reason})
      :ok
    end

    def format_status(status),
      do: Map.update!(status, :state, &Map.put(&1, :application_status, :redacted))
  end

  # The callback behaviour also works without the `use` convenience macro.
  defmodule PlainServer do
    defdelegate init(arg, ctx), to: App
    defdelegate handle_call(message, from, ctx), to: App
    defdelegate handle_cast(message, ctx), to: App
    defdelegate handle_info(message, ctx), to: App
    defdelegate handle_continue(message, ctx), to: App
    defdelegate terminate(reason, ctx), to: App
    defdelegate code_change(old, ctx, extra), to: App
    defdelegate format_status(status), to: App
    defdelegate handle_flow(route, input, ctx), to: App
    defdelegate handle_pending(pending, input, ctx), to: App
    defdelegate handle_result(tag, result, ctx), to: App
  end

  defmodule ConfigAgent do
    def __spectre_config__, do: [server: Spectre.Server.RuntimeBoundariesTest.PlainServer]
  end

  defmodule MissingBindingAgent do
    def identity, do: :no_binding
  end

  defmodule SubjectAgent do
    use Spectre.Agent, server: App
  end

  defp start(opts \\ []) do
    opts =
      Keyword.merge(
        [
          agent: ConfigAgent,
          server: App,
          identity: %{test: self()},
          consumer: self(),
          services: [router: Router]
        ],
        opts
      )

    start_supervised!({Server, opts})
  end

  defp actor, do: start_supervised!({Actor, self()})
  defp wait(check, retries \\ 400)
  defp wait(_check, 0), do: flunk("runtime did not reach expected state")

  defp wait(check, retries) do
    unless check.() do
      Process.sleep(5)
      wait(check, retries - 1)
    end
  end

  test "actor call result belongs to the original input while ordinary messages remain live" do
    actor = actor()
    server = start(assigns: %{actor: actor})
    {:ok, id} = Server.input(server, "hold")
    assert_receive {:actor_called, worker}, 2_000
    assert worker != server
    send(server, {:actor_event, :prices_changed})
    wait(fn -> Server.status(server).assigns[:actor_event] == :prices_changed end)
    GenServer.cast(actor, :release)
    assert_receive {:result_context, :quote, {:ok, 42}, ^id, %{text: "hold"}, ^server}, 2_000
  end

  test "background callbacks do not acquire the most recent conversation input" do
    actor = actor()
    server = start(assigns: %{actor: actor})
    {:ok, id} = Server.input(server, "echo")
    assert_receive {Server, ^server, {:response, ^id, "echo", _}}, 2_000
    GenServer.cast(server, {:background_quote, actor})
    assert_receive {:result_context, :background, {:ok, 42}, nil, nil, ^server}, 2_000
  end

  test "actor timeouts and unavailable actors preserve distinct typed failures" do
    server = start(assigns: %{actor: actor()})
    {:ok, id} = Server.input(server, "timeout")
    assert_receive {:result_context, :timed, {:error, :timeout}, ^id, _, ^server}, 2_000
    {:ok, missing_id} = Server.input(server, "missing_actor")

    assert_receive {:result_context, :missing, {:error, {:actor_exit, _}}, ^missing_id, _,
                    ^server},
                   2_000
  end

  test "cancel abandons local work and drains queued input without applying its late result" do
    actor = actor()
    server = start(assigns: %{actor: actor})
    {:ok, first} = Server.input(server, "hold")
    assert_receive {:actor_called, _worker}, 2_000
    {:ok, second} = Server.input(server, "echo")
    assert :ok = Server.cancel(server)
    assert_receive {Server, ^server, {:cancelled, ^first}}, 2_000
    assert_receive {Server, ^server, {:response, ^second, "echo", _}}, 2_000
    GenServer.cast(actor, :release)
    refute_receive {:result_context, :quote, _, ^first, _, _}, 30
  end

  test "native deferred replies, infinity timeout, terminate and stop-with-reply work" do
    server = start()
    assert :deferred = GenServer.call(server, :deferred)
    assert :okay = GenServer.call(server, :infinity)
    monitor = Process.monitor(server)
    assert :goodbye = GenServer.call(server, :stop_reply)
    assert_receive {:terminated, ^server, :normal}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
  end

  test "init continuation and a plain callback module work without extra macros" do
    Process.flag(:trap_exit, true)
    {:ok, server} = Server.start_link(agent: ConfigAgent, init_arg: :continue)
    assert Server.status(server).assigns.continued
    GenServer.stop(server)
    assert :ignore = Server.start_link(agent: ConfigAgent, init_arg: :ignore)

    assert {:error, :initialization_refused} =
             Server.start_link(agent: ConfigAgent, init_arg: :stop)

    assert {:error, {:invalid_init_return, :invalid}} =
             Server.start_link(agent: ConfigAgent, init_arg: :invalid)
  end

  @tag :capture_log
  test "invalid configuration and a missing Agent binding fail during initialization" do
    Process.flag(:trap_exit, true)

    for opts <- [[identity: []], [assigns: nil], [queue_limit: -1], [max_steps: 0]] do
      assert {:error, {%ArgumentError{}, _}} =
               Server.start_link(Keyword.merge([agent: ConfigAgent], opts))
    end

    assert {:error, {%ArgumentError{}, _}} = Server.start_link(agent: MissingBindingAgent)
  end

  test "invalid user input and unsupported boundary options are rejected before dispatch" do
    server = start()
    assert {:error, :invalid_input_text} = Server.input(server, <<0>>)
    assert {:error, :unsupported_input_options} = Server.input(server, "echo", unsupported: true)
    assert {:error, :invalid_event_id} = Server.deliver(server, "", :event, :result)
    assert Server.status(server).workers == 0
    send(server, {Spectre.Server.Runtime, make_ref(), :unknown})
    send(server, {Spectre.Server.Runtime, make_ref(), :unknown, :payload})
    send(server, {Spectre.Server.Runtime, make_ref(), :timeout})
    assert Server.status(server).workers == 0
  end

  test "code_change migrates application state and can refuse an upgrade" do
    server = start()
    :ok = :sys.suspend(server)
    assert :ok = :sys.change_code(server, Spectre.Server.Runtime, :old, :upgrade)
    assert {:error, _} = :sys.change_code(server, Spectre.Server.Runtime, :old, :refuse)
    :ok = :sys.resume(server)
    assert Server.status(server).assigns.upgraded
    status = :sys.get_status(server) |> inspect()
    assert status =~ "application_status"
    refute status =~ "test: #PID"
  end

  @tag :capture_log
  test "invalid OTP return/action and invalid command groups stop without a successful reply" do
    for request <- [:invalid_return, :invalid_action, {:resume, "missing"}, {:confirm, "missing"}] do
      {:ok, server} = Server.start_link(agent: ConfigAgent, server: App)
      Process.unlink(server)
      monitor = Process.monitor(server)
      catch_exit(GenServer.call(server, request))
      assert_receive {:DOWN, ^monitor, :process, ^server, _}, 2_000
    end

    for input <- ["duplicate", "bad_suspend"] do
      {:ok, server} =
        Server.start_link(
          agent: ConfigAgent,
          server: App,
          consumer: self(),
          services: [router: Router]
        )

      assert {:ok, id} = Server.input(server, input)
      assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _reason}}, 2_000
      assert Process.alive?(server)
      GenServer.stop(server)
    end
  end

  test "a reply wait resolves through its original continuation even after another topic" do
    server = start()
    {:ok, original} = Server.input(server, "wait")
    wait(fn -> Server.status(server).pending != [] end)
    {:ok, topic} = Server.input(server, "echo")
    assert_receive {Server, ^server, {:response, ^topic, "echo", _}}, 2_000
    assert [%{status: :suspended}] = Server.status(server).pending
    GenServer.cast(server, {:resolve, "wait", {:ok, :actor_reply}})

    assert_receive {:result_context, :waited, {:ok, :actor_reply}, ^original, %{text: "wait"},
                    ^server},
                   2_000

    assert Server.status(server).pending == []
  end

  test "durable delivery consumes a registered continuation before a live late reply" do
    path =
      Path.join(System.tmp_dir!(), "spectre-live-delivery-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    store = start_supervised!({Spectre.Server.Store.Disk, path: path})
    server = start(identity: %{}, checkpoint: {store, "live"})
    Server.input(server, "wait")
    wait(fn -> Server.status(server).pending != [] end)
    assert :ok = Server.deliver(server, "outcome-one", {:pending, "wait"}, {:ok, :delivered})
    assert Server.status(server).assigns.results == %{waited: 1}
    GenServer.cast(server, {:resolve, "wait", {:ok, :late_reply}})
    wait(fn -> Server.status(server).workers == 0 end)
    assert Server.status(server).assigns.results == %{waited: 1}
    assert :ok = Server.deliver(server, "outcome-one", {:pending, "wait"}, {:ok, :duplicate})

    assert {:error, :unknown_pending_continuation} =
             Server.deliver(server, "outcome-two", {:pending, "wait"}, :result)
  end

  test "the user-answer helper correlates the resolving input rather than the original question" do
    server = start()
    {:ok, original} = Server.input(server, "wait")
    wait(fn -> Server.status(server).pending != [] end)
    {:ok, answer} = Server.input(server, "resolve")
    assert answer != original

    assert_receive {:result_context, :waited, {:ok, :resolved}, ^answer, %{text: "resolve"},
                    ^server},
                   2_000

    assert Server.status(server).pending == []
  end

  test "cancelling a group of actor wait and slow work removes the cancelled reply registration" do
    server = start(assigns: %{actor: actor()})
    Server.input(server, "combined")
    assert_receive {:actor_called, _worker}, 2_000
    assert length(Server.status(server).pending) == 1
    assert :ok = Server.cancel(server)
    assert Server.status(server).pending == []
    {:ok, id} = Server.input(server, "echo")
    assert_receive {Server, ^server, {:response, ^id, "echo", _}}, 2_000
  end

  test "direct start_link observes canonical subject ownership as well as summon" do
    registry = __MODULE__.DirectOwners
    start_supervised!({Registry, keys: :unique, name: registry})
    options = [agent: SubjectAgent, subject: "account", server_registry: registry]
    assert {:ok, server} = Server.start_link(options)
    assert {:error, {:already_started, ^server}} = Server.start_link(options)

    assert {:error, :subject_server_name_conflict} =
             Server.start_link(options ++ [name: :wrong_owner])

    assert {:ok, ^server} = Spectre.Server.Registry.lookup(SubjectAgent, "account", registry)
    GenServer.stop(server)
  end
end
