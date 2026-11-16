# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
defmodule Spectre.Server.ActionPolicyTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.ActionPolicyTest.App
  end

  defmodule Router do
    def route(_agent, input, _opts), do: {:ok, {:test, input.text}, %{}}
  end

  defmodule Bridge do
    def propose(operation, args, context, opts) do
      send(context.identity.observer, {:bridge, operation, args, opts})
      {:error, :test_boundary}
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:test, operation}, _input, ctx),
      do: propose(ctx, operation, %{value: 7}, on_result: :result)

    def handle_action(%{operation: "reject"}, _ctx), do: {:reject, :business_rule}

    def handle_action(%{operation: "confirm"} = action, ctx) do
      send(ctx.identity.observer, {:policy, self(), action.args})
      {:confirm, %{expires_in: 30_000, bind: %{selected_text: "reviewed"}}}
    end

    def handle_action(action, ctx), do: super(action, ctx)

    def handle_info(:perform, ctx),
      do: {:noreply, propose(ctx, "confirm", %{value: 7}, on_result: :result)}

    def handle_info(message, ctx), do: super(message, ctx)

    def handle_result(:result, result, ctx) do
      send(ctx.identity.observer, {:completed, result})
      no_response(ctx)
    end
  end

  defp start do
    start_supervised!(
      {Spectre.Server.Runtime,
       agent: Agent,
       consumer: self(),
       identity: %{observer: self()},
       services: [router: Router],
       gam: Bridge}
    )
  end

  test "a business rejection never reaches the execution bridge" do
    pid = start()
    assert {:ok, _} = Server.input(pid, "reject")
    assert_receive {:completed, {:error, {:action_rejected, :business_rule}}}, 2_000
    refute_receive {:bridge, _, _, _}
  end

  test "a policy runs in the Server and its portable result reaches the bridge once" do
    pid = start()
    assert {:ok, _} = Server.input(pid, "confirm")
    assert_receive {:policy, ^pid, %{value: 7}}, 2_000
    assert_receive {:bridge, "confirm", %{value: 7}, opts}, 2_000

    assert opts[:action_policy] == %{
             confirm: true,
             expires_in: 30_000,
             bind: %{selected_text: "reviewed"}
           }

    assert_receive {:completed, {:error, :test_boundary}}, 2_000
    refute_receive {:policy, _, _}
  end

  test "ordinary OTP callbacks use the same acquisition and policy path" do
    pid = start()
    send(pid, :perform)
    assert_receive {:policy, ^pid, %{value: 7}}, 2_000
    assert_receive {:bridge, "confirm", _, _}, 2_000
    assert_receive {:completed, {:error, :test_boundary}}, 2_000
  end
end
