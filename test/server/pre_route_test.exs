defmodule Spectre.Server.PreRouteTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.

  defmodule Handler do
    def handle_turn(request, _) do
      case request.input.text do
        "owned" -> {:reply, Spectre.Turn.Handler.Reply.new("owned by integration")}
        _ -> :cont
      end
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:support, :begin}, _, ctx),
      do: await_reply(ctx, "detail", on_result: :detail, foreground: true)

    def handle_flow({nil, :cancel}, _, ctx), do: respond(ctx, "interrupted")
    def handle_flow(:unmatched, _, ctx), do: respond(ctx, "no match")

    def handle_pending(pending, input, ctx) do
      send(ctx.identity.observer, {:pending_input, input.text})

      case input.text do
        "new topic" -> route_current_input(ctx, suspend: pending.id)
        _ -> respond(ctx, "still pending")
      end
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defmodule Definition do
    use Spectre.Agent, server: App
    pre_route_handler(Handler)
    router(strategies: [:regex])
    interrupt(:cancel, regex: ~r/^cancel$/)

    flow :support do
      on(:begin, regex: ~r/^begin$/)
    end
  end

  test "pre-route ownership remains available without creating another runtime" do
    pid =
      start_supervised!(
        {Spectre.Server.Runtime,
         agent: Definition, consumer: self(), identity: %{observer: self()}}
      )

    assert {:ok, id} = Server.input(pid, "owned")
    assert_receive {Server, ^pid, {:response, ^id, "owned by integration", _}}, 2_000
  end

  test "interrupt beats pending, while ordinary pre-route handlers do not steal its replies" do
    pid =
      start_supervised!(
        {Spectre.Server.Runtime,
         agent: Definition, consumer: self(), identity: %{observer: self()}}
      )

    assert {:ok, _} = Server.input(pid, "begin")
    assert {:ok, owned} = Server.input(pid, "owned")
    assert_receive {:pending_input, "owned"}, 2_000
    assert_receive {Server, ^pid, {:response, ^owned, "still pending", _}}, 2_000
    assert {:ok, cancel} = Server.input(pid, "cancel")
    assert_receive {Server, ^pid, {:response, ^cancel, "interrupted", _}}, 2_000
    refute_receive {:pending_input, "cancel"}
    assert [%{status: :suspended}] = Server.status(pid).pending
  end
end
