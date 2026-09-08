# Compile-only authoring example. Loading this file starts no process, performs
# no I/O and creates no authority. The host provisions the Domain separately.
defmodule Spectre.Example.BinaryMatcher do
  use Spectre.Router.Adapter

  @impl true
  def evaluate(request, _options) do
    {:ok, for(rule <- request.rules, rule.data === request.input, do: result(rule, 1.0))}
  end
end

defmodule Spectre.Example.Shared do
  use Spectre.Stack

  adapter(:router, :binary, Spectre.Example.BinaryMatcher)
  prompt(:safety, "Propose only. A request or draft is not proof of delivery.")
  inject(:safety, position: :start)
end

defmodule Spectre.Example.OrdersRouter do
  use Spectre.Router

  flow :orders do
    pipe_through(:normalize)
    router(via: [:regex, :string_bag, :binary], accept: 0.85, margin: 0.05)
    route(:lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u])
    route(:help, match: [string_bag: ["help with orders"], binary: "help"])
  end
end

defmodule Spectre.Example.Faq do
  use Spectre.Skill, namespace: "example", name: "faq"

  flow :questions do
    router(via: [:string_bag], accept: 0.9)
    route(:hours, match: [string_bag: ["opening hours"]])
  end

  @impl true
  def handle_turn({:questions, :hours, _match}, _turn, state),
    do: {:request, "support.hours", %{}, state}

  def handle_turn({:questions, :no_match, _input}, _turn, state), do: {:ok, state}

  def handle_turn({_flow, :ambiguous, _refs}, _turn, state),
    do: {:error, :clarification_needed, state}

  def handle_turn({_flow, :error, reason}, _turn, state), do: {:error, reason, state}

  @impl true
  def handle_result({:request, "support.hours"}, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.OrderWorker do
  use Spectre.Worker, namespace: "example", name: "order_worker"

  @impl true
  def handle_work(%{"order_id" => id}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.QueueVigil do
  use Spectre.Vigil, namespace: "example", name: "queue_vigil"

  @impl true
  def handle_vigil(%{"tick_ref" => ref}, _turn, state),
    do: {:request, "queue.inspect", %{"tick_ref" => ref}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.Support do
  use Spectre.Agent, namespace: "example", name: "support", stack: Spectre.Example.Shared

  router(Spectre.Example.OrdersRouter)
  skill(Spectre.Example.Faq, as: :faq)
  worker(:lookup, Spectre.Example.OrderWorker)
  vigil(:queue, Spectre.Example.QueueVigil)

  prompt_root(Path.join(__DIR__, "prompts"))
  prompt(:answer, file: "answer.text.eex")
  prompt(:question, "Order <%= @order_id %>: <%= @question %>")

  ask(:answer,
    class: "model.generate",
    prompt: :answer,
    task: :question,
    via: :inference,
    max_tokens: 300
  )

  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, Map.put(state, :order_id, id)}

  def handle_turn({:orders, :help, _match}, _turn, state),
    do: {:ask, :answer, %{order_id: "none", question: "Explain order lookup."}, state}

  def handle_turn({:orders, :no_match, _input}, _turn, state),
    do: {:error, :clarification_needed, state}

  def handle_turn({_flow, :ambiguous, _refs}, _turn, state),
    do: {:error, :ambiguous_route, state}

  def handle_turn({_flow, :error, reason}, _turn, state), do: {:error, reason, state}
  def handle_turn({_flow, :halted, _input}, _turn, state), do: {:ok, state}
  def handle_turn({_flow, :unrouted, _input}, _turn, state), do: {:ok, state}

  @impl true
  def handle_result({:request, "orders.lookup"}, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}

  def handle_result({:ask, :answer}, %{status: :done, data: data}, _turn, state),
    do: {:ok, Map.put(state, :draft, data)}

  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.Publication do
  @moduledoc "Publication is explicit and does not activate any of these Definitions."

  def definitions(at) do
    faq = Spectre.Example.Faq.definition(revision: 1, declared_at: at)

    %{
      agent:
        Spectre.Example.Support.definition(revision: 1, declared_at: at, components: %{faq: faq}),
      worker: Spectre.Example.OrderWorker.definition(revision: 1, declared_at: at),
      vigil: Spectre.Example.QueueVigil.definition(revision: 1, declared_at: at)
    }
  end
end
