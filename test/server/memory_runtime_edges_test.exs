defmodule Spectre.Server.MemoryAdapterEdgesTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.Memory

  defmodule PersistFour do
    def persist(input, result, agent, opts) do
      send(opts[:identity].test, {:persisted_four, input, result, agent, opts})
      {:ok, :stored}
    end
  end

  defmodule RememberTwo do
    def remember(payload, opts) do
      send(opts[:identity].test, {:remembered_two, payload, opts})
      :ok
    end
  end

  defmodule PersistTwo do
    def persist(payload, opts) do
      send(opts[:identity].test, {:persisted_two, payload, opts})
      Keyword.get(opts, :adapter_reply, :ok)
    end
  end

  defmodule RecallOnly do
    def recall(_text, opts) do
      send(opts[:identity].test, :adapter_recalled)
      {:ok, :adapter_memory}
    end
  end

  defmodule FourAgent do
    use Spectre.Agent
    memory(PersistFour)
  end

  defmodule RememberAgent do
    use Spectre.Agent
    memory(RememberTwo)
  end

  defmodule PersistAgent do
    use Spectre.Agent
    memory(PersistTwo)
  end

  defmodule RecallAgent do
    use Spectre.Agent
    memory(RecallOnly)
  end

  defp context do
    %{
      identity: %{test: self()},
      current_flow: :support,
      current_scope: :agent,
      history: [%{user: "earlier", assistant: "answer"}],
      options: []
    }
  end

  test "legacy persist/4 receives the completed result and conversation state" do
    input = Spectre.Input.new("question")
    assert :ok = Memory.remember(FourAgent, input, "response", context(), [])
    assert_receive {:persisted_four, ^input, result, FourAgent, opts}, 2_000
    assert result.reply_text == "response"
    assert result.state.current_flow == :support
    assert result.state.current_scope == :agent
    assert result.state.data.chat_history == [%{user: "earlier", assistant: "answer"}]
    assert opts[:agent] == FourAgent
  end

  test "legacy two-argument adapters receive a completed episode without executable effects" do
    input = Spectre.Input.new("question")
    assert :ok = Memory.remember(RememberAgent, input, "response", context(), [])
    assert_receive {:remembered_two, payload, _opts}, 2_000
    assert payload.input == input
    assert payload.reply_text == "response"
    assert payload.effects == []
    assert payload.awaitables == []

    assert :ok =
             Memory.remember(PersistAgent, input, "response", context(), adapter_reply: {:ok, 17})

    assert_receive {:persisted_two, %{reply_text: "response"}, _opts}, 2_000
  end

  test "malformed persistence acknowledgments remain errors instead of successful memories" do
    assert {:error, _failure} =
             Memory.remember(PersistAgent, Spectre.Input.new("question"), "response", context(),
               adapter_reply: :unexpected_reply
             )

    assert_receive {:persisted_two, _payload, _opts}, 2_000
  end

  test "host-retrieved memory wins over configured recall and remains size bounded" do
    context = %{context() | options: [memory: :retrieved_in_context]}
    input = Spectre.Input.new("question")
    assert {:ok, :retrieved_in_context} = Memory.recall(RecallAgent, input, context, [])

    assert {:ok, :retrieved_for_input} =
             Memory.recall(RecallAgent, input, context, memory: :retrieved_for_input)

    assert {:error, {:payload_too_large, :memory_recall, _, 1}} =
             Memory.recall(RecallAgent, input, context, memory: "too large", memory_max_bytes: 1)

    refute_receive :adapter_recalled, 30
  end

  test "a recall-only memory adapter does not require a persistence callback" do
    assert :ok =
             Memory.remember(
               RecallAgent,
               Spectre.Input.new("question"),
               "response",
               context(),
               []
             )

    refute_receive :adapter_recalled, 30
  end
end

defmodule Spectre.Server.RenderingServiceEdgesTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.

  defmodule Bindings do
    def route(_agent, %{text: "bad_router"}, _opts), do: :invalid_router_return
    def route(_agent, %{text: "route_error"}, _opts), do: {:error, :classifier_unavailable}

    def route(agent, input, _opts) do
      route = %Spectre.Route{
        flow: :test,
        label: input.text,
        owner: agent,
        accepted?: true,
        handler: {:server, {[:test], input.text}, []}
      }

      {:ok, {:test, input.text}, %{route: route}}
    end

    def inference(request, context, _opts) do
      send(context.identity.test, {:inference_called, request.prompt, context.input.text})
      {:generated, %{text: "MFA result", proposals: []}}
    end
  end

  defmodule App do
    use Spectre.Server
    def handle_flow({:test, "symbol"}, _input, ctx), do: respond(ctx, :welcome)

    def handle_flow({:test, "generate"}, _input, ctx),
      do: generate(ctx, :welcome, timeout: :infinity)

    def handle_flow(:unmatched, _input, ctx) do
      send(ctx.identity.test, {:unmatched, ctx.routing.reason})
      respond(ctx, "Please explain your request.")
    end

    def handle_cast(:schedule, ctx), do: {:noreply, ctx, {:continue, :announce}}
    def handle_cast(:stop, ctx), do: {:stop, :normal, ctx}
    def handle_continue(:announce, ctx), do: {:noreply, respond(ctx, "Background announcement")}
  end

  defmodule Agent do
    use Spectre.Agent, server: App
  end

  defp start(opts \\ []) do
    defaults = [
      agent: Agent,
      consumer: self(),
      identity: %{test: self()},
      services: [router: {Bindings, :route}, generate: {Bindings, :inference}]
    ]

    start_supervised!({Spectre.Server.Runtime, Keyword.merge(defaults, opts)})
  end

  @tag :tmp_dir
  test "symbolic replies render their server prompt without invoking inference", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "welcome.text.heex"), "Welcome from the server.")
    server = start(prompt_root: dir)
    {:ok, id} = Server.input(server, "symbol")
    assert_receive {Server, ^server, {:response, ^id, "Welcome from the server.", _}}, 2_000
    refute_receive {:inference_called, _, _}, 30
  end

  test "an MFA cognitive binding runs through the same command continuation" do
    server = start()
    {:ok, id} = Server.input(server, "generate")
    assert_receive {:inference_called, :welcome, "generate"}, 2_000
    assert_receive {Server, ^server, {:response, ^id, "MFA result", _}}, 2_000
  end

  test "routing errors retain their reason while taking the ordinary unmatched path" do
    server = start()

    for {input, reason} <- [
          {"route_error", :classifier_unavailable},
          {"bad_router", {:invalid_router_result, :invalid_router_return}}
        ] do
      {:ok, id} = Server.input(server, input)
      assert_receive {:unmatched, {:classifier_error, ^reason}}, 2_000
      assert_receive {Server, ^server, {:response, ^id, "Please explain your request.", _}}, 2_000
      assert Process.alive?(server)
    end
  end

  test "native cast continuations can emit an uncorrelated announcement and stop normally" do
    server = start()
    GenServer.cast(server, :schedule)
    assert_receive {Server, ^server, {:response, nil, "Background announcement", _}}, 2_000
    monitor = Process.monitor(server)
    GenServer.cast(server, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
  end
end
