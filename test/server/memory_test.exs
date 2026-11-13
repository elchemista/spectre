defmodule Spectre.Server.MemoryTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Adapter do
    def recall(text, opts) do
      send(opts[:identity].test, {:recalled, text})
      {:ok, %{recalled: text}}
    end

    def remember(input, result, _agent, opts) do
      send(opts[:identity].test, {:remembered, input.text, result.reply_text})
      if opts[:identity][:fail_memory], do: {:error, :unavailable}, else: :ok
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:test, :waiting}, _input, ctx),
      do: await_reply(ctx, "waiting", foreground: true, timeout: 10_000)

    def handle_flow({:test, :topic}, _input, ctx) do
      send(ctx.identity.test, {:flow_memory, ctx.memory})
      respond(ctx, "topic response")
    end

    def handle_flow({:test, :double}, _input, ctx),
      do: ctx |> respond("first ") |> respond("second")

    def handle_pending(pending, _input, ctx), do: route_current_input(ctx, suspend: pending.id)
  end

  defmodule Agent do
    use Spectre.Agent, server: App
    memory(Adapter)
    router(strategies: [:regex])

    flow :test do
      on(:waiting, regex: ~r/^waiting$/)
      on(:topic, regex: ~r/^topic$/)
      on(:double, regex: ~r/^double$/)
    end
  end

  test "recall runs once per input before pending and is reused during rerouting" do
    pid = start_supervised!({Server, agent: Agent, identity: %{test: self()}, consumer: self()})
    Server.input(pid, "waiting")
    assert_receive {:recalled, "waiting"}, 2_000
    eventually(fn -> Server.status(pid).pending != [] end)
    {:ok, id} = Server.input(pid, "topic")
    assert_receive {:recalled, "topic"}, 2_000
    assert_receive {:flow_memory, %{recalled: "topic"}}, 2_000
    assert_receive {Server, ^pid, {:response, ^id, "topic response", []}}, 2_000
    assert_receive {:remembered, "topic", "topic response"}, 2_000
    refute_receive {:recalled, "topic"}, 30
  end

  test "a persistence failure is reported without rerunning the input" do
    pid =
      start_supervised!(
        {Server, agent: Agent, identity: %{test: self(), fail_memory: true}, consumer: self()}
      )

    {:ok, id} = Server.input(pid, "topic")
    assert_receive {:recalled, "topic"}, 2_000
    assert_receive {Server, ^pid, {:response, ^id, "topic response", []}}, 2_000
    assert_receive {Server, ^pid, {:memory_error, ^id, {:error, _reason}}}, 2_000
    refute_receive {:recalled, "topic"}, 30
  end

  test "multiple replies in one stable event produce one combined memory episode" do
    pid = start_supervised!({Server, agent: Agent, identity: %{test: self()}, consumer: self()})
    {:ok, id} = Server.input(pid, "double")
    assert_receive {Server, ^pid, {:response, ^id, "first ", _}}, 2_000
    assert_receive {Server, ^pid, {:response, ^id, "second", _}}, 2_000
    assert_receive {:remembered, "double", "first second"}, 2_000
    refute_receive {:remembered, "double", _}, 30
  end

  defp eventually(check, retries \\ 400)
  defp eventually(_check, 0), do: flunk("condition not reached")

  defp eventually(check, retries) do
    if not check.() do
      Process.sleep(5)
      eventually(check, retries - 1)
    end
  end
end
