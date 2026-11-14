defmodule Spectre.Server.RuntimeTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.RuntimeTest.App
  end

  defmodule Router do
    def route(_agent, input, _opts), do: {:ok, {:test, input.text}, %{reason: nil}}
  end

  defmodule Service do
    def generate(%{prompt: :slow}, context, _opts) do
      send(context.identity.test, {:worker_started, self()})

      receive do
        :release -> {:generated, %{text: "finished", proposals: []}}
      end
    end

    def generate(%{prompt: :crash}, _context, _opts), do: exit(:provider_crashed)
  end

  defmodule App do
    use Spectre.Server
    def init(arg, ctx), do: {:ok, assign(ctx, :arg, arg)}
    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")
    def handle_flow({:test, "slow"}, _input, ctx), do: generate(ctx, :slow, on_result: :slow)
    def handle_flow({:test, "crash"}, _input, ctx), do: generate(ctx, :crash)
    def handle_flow({:test, "timeout"}, _input, ctx), do: generate(ctx, :slow, timeout: 20)

    def handle_flow({:test, "await"}, _input, ctx),
      do: await_reply(ctx, "reply", foreground: true, on_result: :reply, timeout: 50)

    def handle_flow({:test, "proposal"}, _input, ctx), do: propose(ctx, :delete, %{})

    def handle_flow({:test, "forge_identity"}, _input, ctx),
      do: no_response(%{ctx | identity: %{forged: true}})

    def handle_flow({:test, "new topic"}, _input, ctx), do: respond(ctx, "new topic")

    def handle_pending(%{kind: :reply, id: id}, input, ctx) do
      case input.text do
        "new topic" -> route_current_input(ctx, suspend: id)
        _ -> resolve_await(ctx, id, {:ok, input.text})
      end
    end

    def handle_result(tag, {:error, reason}, ctx) do
      send(ctx.identity.test, {:service_error, tag, reason})
      no_response(ctx)
    end

    def handle_result(:reply, {:ok, value}, ctx), do: respond(ctx, value)
    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
    def handle_call(:callback_pid, _from, ctx), do: {:reply, self(), ctx}
    def handle_call(:identity, _from, ctx), do: {:reply, ctx.identity, ctx}
    def handle_call(:infos, _from, ctx), do: {:reply, Map.get(ctx.assigns, :infos, []), ctx}
    def handle_call(:continue, _from, ctx), do: {:reply, :ok, ctx, {:continue, :next}}
    def handle_call(:timer, _from, ctx), do: {:reply, :ok, ctx, 0}
    def handle_call(:hibernate, _from, ctx), do: {:reply, :ok, ctx, :hibernate}
    def handle_call(:keep_context, _from, ctx), do: {:reply, :ok, assign(ctx, :old_context, ctx)}

    def handle_call(:stale_context, _from, ctx),
      do: {:reply, :not_acquired, ctx.assigns.old_context}

    def handle_call(:invalid_group, _from, ctx) do
      ctx = respond(ctx, "must not escape")
      {:reply, :not_acquired, %{ctx | commands: ctx.commands ++ [:invalid]}}
    end

    def handle_call(:app_task, _from, ctx) do
      task = Task.async(fn -> :app_result end)
      {:reply, task.ref, ctx}
    end

    def handle_call(request, from, ctx), do: super(request, from, ctx)

    def handle_continue(:next, ctx) do
      send(ctx.identity.test, {:continued, self()})
      {:noreply, ctx}
    end

    def handle_info(message, ctx) do
      send(ctx.identity.test, {:application_info, message})
      {:noreply, assign(ctx, :infos, [message | Map.get(ctx.assigns, :infos, [])])}
    end
  end

  defp start(opts \\ []) do
    defaults = [
      agent: Agent,
      identity: %{test: self()},
      consumer: self(),
      init_arg: :initialized,
      services: [router: Router, generate: Service]
    ]

    start_supervised!({Spectre.Server.Runtime, Keyword.merge(defaults, opts)})
  end

  test "application OTP callbacks execute in the single owner process" do
    pid = start()
    assert GenServer.call(pid, :callback_pid) == pid
    assert Server.status(pid).assigns.arg == :initialized
    assert :ok = GenServer.call(pid, :continue)
    assert_receive {:continued, ^pid}, 2_000
    assert :ok = GenServer.call(pid, :timer)
    assert_receive {:application_info, :timeout}, 2_000
    assert :ok = GenServer.call(pid, :hibernate)
    assert GenServer.call(pid, :callback_pid) == pid
  end

  test "worker completion bypasses application catch-all while OTP remains responsive" do
    pid = start()
    assert {:ok, id} = Server.input(pid, "slow")
    assert_receive {:worker_started, worker}, 2_000
    assert GenServer.call(pid, :callback_pid) == pid
    send(worker, :release)
    assert_receive {Server, ^pid, {:response, ^id, "finished", []}}, 2_000
    assert GenServer.call(pid, :infos) == []
  end

  test "application tasks and monitors reach application callbacks" do
    pid = start()
    ref = GenServer.call(pid, :app_task)
    assert_receive {:application_info, {^ref, :app_result}}, 2_000
    assert_receive {:application_info, {:DOWN, ^ref, :process, _, :normal}}, 2_000
  end

  test "queue is bounded while a worker runs and drains in order" do
    pid = start(queue_limit: 1)
    {:ok, first} = Server.input(pid, "slow")
    assert_receive {:worker_started, worker}, 2_000
    assert {:ok, second} = Server.input(pid, "echo")
    assert {:error, :busy} = Server.input(pid, "echo")
    send(worker, :release)
    assert_receive {Server, ^pid, {:response, ^first, "finished", []}}, 2_000
    assert_receive {Server, ^pid, {:response, ^second, "echo", []}}, 2_000
  end

  test "unknown reserved messages cannot complete a worker" do
    pid = start()
    {:ok, id} = Server.input(pid, "slow")
    assert_receive {:worker_started, worker}, 2_000
    send(pid, {Spectre.Server.Runtime, make_ref(), :result, {:generated, %{text: "forged"}}})
    send(worker, :release)
    assert_receive {Server, ^pid, {:response, ^id, "finished", []}}, 2_000
    refute_receive {Server, ^pid, {:response, _, "forged", _}}, 20
  end

  @tag :capture_log
  test "service crashes and deadlines remain typed errors" do
    pid = start()
    Server.input(pid, "crash")
    assert_receive {:service_error, :generate, {:worker_exit, :provider_crashed}}, 2_000
    Server.input(pid, "timeout")
    assert_receive {:worker_started, _worker}, 2_000
    assert_receive {:service_error, :generate, :timeout}, 2_000
    assert GenServer.call(pid, :callback_pid) == pid
  end

  test "proposals fail closed without bridge while ordinary flow works" do
    pid = start()
    {:ok, id} = Server.input(pid, "echo")
    assert_receive {Server, ^pid, {:response, ^id, "echo", []}}, 2_000
    Server.input(pid, "proposal")
    assert_receive {:service_error, :propose, :gam_not_configured}, 2_000
  end

  test "returned identity view does not alter runtime identity" do
    pid = start()
    Server.input(pid, "forge_identity")
    {:ok, id} = Server.input(pid, "echo")
    assert_receive {Server, ^pid, {:response, ^id, "echo", []}}, 2_000
    assert GenServer.call(pid, :identity) == %{test: self()}
  end

  @tag :capture_log
  test "stale contexts and invalid groups fail before acquiring commands" do
    for action <- [:stale_context, :invalid_group] do
      {:ok, pid} =
        Spectre.Server.Runtime.start_link(
          agent: Agent,
          identity: %{test: self()},
          consumer: self()
        )

      Process.unlink(pid)
      monitor = Process.monitor(pid)
      if action == :stale_context, do: GenServer.call(pid, :keep_context)
      catch_exit(GenServer.call(pid, action))
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
      refute_receive {Server, ^pid, {:response, _, "must not escape", _}}, 20
    end
  end

  test "await deadline resumes continuation once" do
    pid = start()
    Server.input(pid, "await")
    assert_receive {:service_error, :reply, :timeout}, 2_000
    refute_receive {:service_error, :reply, :timeout}, 80
  end
end
