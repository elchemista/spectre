# Run from the Spectre repository with mix run docs/examples/core_agents/run.exs.
Code.require_file("core_agents.exs", __DIR__)

alias Spectre.Server

for {agent, messages} <- [
      {Example.HelloAgent, ["world", "simulate provider failure"]},
      {Example.DocumentsAgent, ["show document D12", "show document D99"]}
    ] do
  {:ok, server} = Server.start_link(agent: agent, consumer: self())

  for message <- messages do
    {:ok, interaction} = Server.input(server, message)

    receive do
      {Server, ^server, {:response, ^interaction, text, _metadata}} ->
        IO.puts("#{message} → #{text}")
    after
      5_000 -> raise "No response to #{inspect(message)}"
    end
  end

  GenServer.stop(server)
end
