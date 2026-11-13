defmodule Spectre.Server.StartupTest do
  use ExUnit.Case, async: true

  defmodule Callback do
    use Spectre.Server
    def handle_flow({:support, :hello}, _, ctx), do: respond(ctx, "hello")
    def handle_flow(route, input, ctx), do: super(route, input, ctx)
  end

  defmodule Definition do
    use Spectre.Agent, server: Callback
    router(strategies: [:regex])

    flow :support do
      on(:hello, regex: ~r/^hi$/)
    end
  end

  test "both public summon forms select the new owner from the Agent binding" do
    {:ok, supervisor} = start_supervised({DynamicSupervisor, strategy: :one_for_one})
    assert {:ok, server} = Spectre.summon(supervisor, Definition, consumer: self())
    assert {:ok, id} = Spectre.Server.input(server, "hi")
    assert_receive {Spectre.Server, ^server, {:response, ^id, "hello", _}}, 2_000
    assert :sys.get_state(server).server == Callback

    assert {:ok, direct} = Spectre.summon(agent: Definition, consumer: self())
    on_exit(fn -> if Process.alive?(direct), do: GenServer.stop(direct) end)
    assert :sys.get_state(direct).server == Callback
  end
end
