Code.require_file("../../docs/examples/core_agents/core_agents.exs", __DIR__)

defmodule Spectre.Server.DeveloperExamplesTest do
  use ExUnit.Case, async: true

  alias Spectre.Server

  @timeout 5_000

  test "Hello Agent replies through the model and the default result handler without starting Activities" do
    server = start_agent(Example.HelloAgent)

    assert_reply(server, "world", "Hello, world!")
    assert_reply(server, "simulate provider failure", "The request could not be completed.")
    assert_reply(server, "again", "Hello, again!")
    assert {:ok, []} = Server.activities(server)
    refute_received {Server, ^server, {:activity, _identity, _event}}
  end

  test "Documents exposes its flow and uses the default handler for a tool error" do
    server = start_agent(Example.DocumentsAgent)

    assert_reply(server, "show document D12", "Project brief")
    assert_reply(server, "show document D99", "The request could not be completed.")
    assert_reply(server, "world", "Hello, world!")
    assert {:ok, []} = Server.activities(server)
  end

  defp start_agent(agent), do: start_supervised!({Server, agent: agent, consumer: self()})

  defp assert_reply(server, input, expected) do
    assert {:ok, interaction} = Server.input(server, input)
    assert_receive {Server, ^server, {:response, ^interaction, ^expected, _metadata}}, @timeout
  end
end
