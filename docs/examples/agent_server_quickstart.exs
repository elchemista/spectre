defmodule Quickstart.AI do
  use Spectre.Stack
end

defmodule Quickstart.SupportAgent do
  use Spectre.Agent, stack: Quickstart.AI, server: Quickstart.SupportServer

  router(strategies: [:regex, :bag, :jaro])

  flow :support do
    on(:pricing,
      regex: ~r/\b(price|pricing|cost)\b/i,
      bag: ["subscription plans"],
      jaro: ["monthly subscription"]
    )
  end
end

defmodule Quickstart.SupportServer do
  use Spectre.Server, tools: Quickstart.AI

  @impl true
  def handle_flow({:support, :pricing}, _input, ctx) do
    respond(ctx, "Plans start at EUR 20 per month.")
  end

  def handle_flow(:unmatched, _input, ctx) do
    respond(ctx, "Ask me about pricing.")
  end
end

{:ok, server} = Spectre.Server.start_link(agent: Quickstart.SupportAgent, consumer: self())
{:ok, interaction} = Spectre.Server.input(server, "What is the price?")

receive do
  {Spectre.Server, ^server, {:response, ^interaction, text, _metadata}} ->
    IO.puts(text)
after
  5_000 -> raise "No response from the agent"
end

GenServer.stop(server)
