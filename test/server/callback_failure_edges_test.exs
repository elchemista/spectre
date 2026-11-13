defmodule Spectre.Server.CallbackFailureEdgesTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

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

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.CallbackFailureEdgesTest.App
  end

  defmodule Service do
    def generate(%{prompt: :held}, context, _opts) do
      send(context.identity.test, {:held_generation, self()})

      receive do
        :release -> {:generated, %{text: "hold", proposals: []}}
      end
    end

    def generate(%{prompt: :error_fallback}, context, _opts) do
      send(context.identity.test, :fallback_requested)
      {:generated, %{text: "fallback", proposals: []}}
    end
  end

  defmodule ErrorHandler do
    def reply(_failure, ctx), do: Server.respond(ctx, "Please try again.")
    def throw(_failure, _ctx), do: Kernel.throw(:error_handler_failed)
    def malformed(_failure, _ctx), do: :invalid_context

    def retry(_failure, ctx),
      do: Server.generate(ctx, :error_fallback, on_result: :error_fallback)
  end

  defmodule App do
    use Spectre.Server
    def handle_flow({:test, "throw"}, _input, _ctx), do: throw(:application_throw)
    def handle_flow({:test, "exit"}, _input, _ctx), do: exit(:application_exit)
    def handle_flow({:test, "raise"}, _input, _ctx), do: raise("application raised")

    def handle_flow({:test, "invalid_timeout"}, _input, ctx),
      do: await_reply(ctx, "invalid", timeout: 0)

    def handle_flow({:test, "hold"}, _input, ctx), do: generate(ctx, :held, on_result: :held)
    def handle_flow({:test, text}, _input, ctx), do: respond(ctx, text)
    def handle_result(:error_fallback, _result, _ctx), do: throw(:fallback_failed)
    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defp start(opts \\ []) do
    defaults = [
      agent: Agent,
      consumer: self(),
      identity: %{test: self()},
      services: [router: Router, generate: Service]
    ]

    start_supervised!({Server, Keyword.merge(defaults, opts)})
  end

  defp wait(check, tries \\ 400)
  defp wait(_check, 0), do: flunk("condition was not reached")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end

  test "throws and exits from conversational callbacks are contained and quarantine stays bounded" do
    server = start(max_dead_letters: 2)

    for {text, kind} <- [{"throw", :throw}, {"exit", :exit}, {"raise", :exception}] do
      {:ok, id} = Server.input(server, text)

      assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, %{kind: ^kind}}},
                     2_000

      assert Process.alive?(server)
    end

    assert map_size(Server.status(server).dead_letters) == 2
    {:ok, id} = Server.input(server, "healthy")
    assert_receive {Server, ^server, {:response, ^id, "healthy", _}}, 2_000
  end

  test "a configured error handler can return a normal response without reclassifying input" do
    server = start(on_callback_error: {ErrorHandler, :reply})
    {:ok, id} = Server.input(server, "throw")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2_000
    assert_receive {Server, ^server, {:response, ^id, "Please try again.", _}}, 2_000
    assert map_size(Server.status(server).dead_letters) == 1
  end

  test "a failing error handler cannot replace the original quarantine with a crash loop" do
    for function <- [:throw, :malformed] do
      {:ok, server} =
        Server.start_link(
          agent: Agent,
          consumer: self(),
          services: [router: Router],
          on_callback_error: {ErrorHandler, function}
        )

      {:ok, id} = Server.input(server, "exit")
      assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2_000

      assert_receive {Server, ^server, {:callback_error_handler_failed, _failure_id, _reason}},
                     2_000

      assert Process.alive?(server)
      assert map_size(Server.status(server).dead_letters) == 1
      GenServer.stop(server)
    end
  end

  test "an error-handler inference is bounded when its own continuation also fails" do
    server = start(on_callback_error: {ErrorHandler, :retry})
    {:ok, id} = Server.input(server, "raise")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2_000
    assert_receive :fallback_requested, 2_000
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_result, _}}, 2_000
    wait(fn -> not Server.status(server).busy and Server.status(server).workers == 0 end)
    refute_receive :fallback_requested, 30
    assert map_size(Server.status(server).dead_letters) == 2
  end

  test "invalid callback commands are rejected before starting the requested wait" do
    server = start()
    {:ok, id} = Server.input(server, "invalid_timeout")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, reason}}, 2_000
    assert reason.message =~ "invalid_timeout"
    assert Server.status(server).pending == []
    assert Process.alive?(server)
  end

  test "a new input already in the mailbox cannot overtake the existing input queue" do
    server = start()
    {:ok, _} = Server.input(server, "hold")
    assert_receive {:held_generation, worker}, 2_000
    {:ok, _} = Server.input(server, "queued")
    :ok = :sys.suspend(server)
    send(worker, :release)

    wait(fn ->
      {:messages, messages} = Process.info(server, :messages)
      Enum.any?(messages, &match?({Spectre.Server.Runtime, _ref, :result, _result}, &1))
    end)

    caller = Task.async(fn -> Server.input(server, "new") end)

    wait(fn ->
      {:messages, messages} = Process.info(server, :messages)

      Enum.any?(
        messages,
        &match?({:"$gen_call", _from, {Spectre.Server.Runtime, :input, "new", []}}, &1)
      )
    end)

    :ok = :sys.resume(server)
    assert {:ok, _} = Task.await(caller)

    responses =
      for _ <- 1..3 do
        assert_receive {Server, ^server, {:response, _id, text, _opts}}, 2_000
        text
      end

    assert responses == ["hold", "queued", "new"]
  end
end

defmodule Spectre.Server.InterruptEvidenceFailureTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Pipeline do
    def call(context) do
      if Keyword.get(context.opts, :policy_interrupt_only?, false) and
           context.input.text == "answer" do
        {:error, :interrupt_source_unavailable}
      else
        modules = [
          Spectre.Router.Plugs.Regex,
          Spectre.Router.Plugs.Arbitrate,
          Spectre.Router.Plugs.Terminalize
        ]

        with {:ok, specs} <- Spectre.Pipeline.init_specs(modules),
             do: Spectre.Pipeline.run(context, specs)
      end
    end
  end

  defmodule Bridge do
    def propose(_operation, _args, _context, _opts), do: {:pending, %{operation: :operation}}
  end

  defmodule App do
    use Spectre.Server
    def handle_flow({:test, :operate}, _input, ctx), do: propose(ctx, :operation, %{})
    def handle_pending(_pending, input, ctx), do: respond(ctx, "Pending saw: #{input.text}")
  end

  defmodule Agent do
    use Spectre.Agent, server: App
    router(strategies: [:regex], pipeline: Pipeline)

    interrupt :cancel, regex: ~r/^cancel$/ do
      reply(:cancelled)
    end

    flow :test do
      on(:operate, regex: ~r/^operate$/)
    end
  end

  test "unavailable interrupt evidence preserves the active pending and its original input" do
    server = start_supervised!({Server, agent: Agent, consumer: self(), gam: Bridge})
    {:ok, _} = Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [before] = Server.status(server).pending
    {:ok, id} = Server.input(server, "answer")
    assert_receive {Server, ^server, {:routing_evidence_error, ^id, :interrupt, _}}, 2_000
    assert_receive {Server, ^server, {:response, ^id, "Pending saw: answer", _}}, 2_000
    assert [%{id: pending_id, status: :foreground}] = Server.status(server).pending
    assert pending_id == before.id
    assert Process.alive?(server)
  end

  defp wait(check, tries \\ 400)
  defp wait(_check, 0), do: flunk("pending was not registered")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end
end
