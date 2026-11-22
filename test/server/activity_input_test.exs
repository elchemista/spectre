defmodule Spectre.Server.ActivityInputTest do
  use ExUnit.Case, async: true

  alias Spectre.Server

  @timeout 5_000

  defmodule Report do
    use Spectre.Activity

    def handle_start(timeout, ctx) do
      await_input(ctx, :document,
        accept: ~r/^D\d+$/,
        prompt: "Which document?",
        timeout: timeout
      )
    end

    def handle_result(:document, {:ok, %Spectre.Input{text: id}}, ctx), do: complete(ctx, id)
    def handle_result(:document, {:error, reason}, ctx), do: fail(ctx, reason)

    def handle_signal({:effect, _}, ctx), do: fail(ctx, :unexpected_effect)
    def handle_signal(signal, ctx), do: super(signal, ctx)
  end

  defmodule Stack do
    use Spectre.Stack
    activity(:report, Report)
  end

  defmodule Root do
    use Spectre.Server

    def handle_call({:report, timeout}, _from, ctx),
      do: {:reply, :ok, start_activity(ctx, :report, timeout)}

    def handle_call(message, from, ctx), do: super(message, from, ctx)
    def handle_flow({:chat, :ping}, _input, ctx), do: respond(ctx, "pong")
    def handle_flow(flow, input, ctx), do: super(flow, input, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])

    flow :chat do
      on(:ping, regex: ~r/^ping$/)
    end
  end

  test "matching ordinary input resolves the focused Activity wait" do
    root = start_root()
    {ref, _target} = ask(root)

    assert {:ok, _} = Server.input(root, "D12")
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D12"}}}, @timeout
  end

  test "a waiter yields unrelated chat and accepts only an authorized targeted answer" do
    root = start_root()
    {ref, target} = ask(root)

    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout

    unauthorized =
      Task.async(fn -> Server.input(root, "D12", activity: ref, pending: target) end)

    assert Task.await(unauthorized) == {:error, :activity_input_not_authorized}

    assert {:error, :reserved_activity_signal} =
             Server.signal_activity(root, ref, {:effect, {:governed, %{}}})

    assert {:ok, _} = Server.input(root, "D34", activity: ref, pending: target)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D34"}}}, @timeout

    assert {:error, :stale_pending} =
             Server.input(root, "D56", activity: ref, pending: target)
  end

  test "an expired wait reaches its Activity and rejects the old target" do
    root = start_root()
    {ref, target} = ask(root, 100)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, :expired}}}, @timeout

    assert {:error, :stale_pending} =
             Server.input(root, "D12", activity: ref, pending: target)
  end

  defp start_root, do: start_supervised!({Server, agent: Agent, consumer: self()})

  defp ask(root, timeout \\ @timeout) do
    assert :ok = GenServer.call(root, {:report, timeout})

    assert_receive {Server, ^root,
                    {:activity, %{ref: ref},
                     {:waiting_input, %{id: id, revision: revision, prompt: "Which document?"}}}},
                   @timeout

    {ref, {id, revision}}
  end
end
