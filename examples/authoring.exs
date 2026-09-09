# Start here: docs/agent-recipes.md explains how the pieces below fit together.
# This file DECLARES an agent; it does not start a Domain or call a provider.
# Compilation reads the prompt file. Runtime services, authenticated Scopes and
# authority are supplied explicitly by the host (see docs/host-setup.md).
#
# Reading path: Router chooses a handler -> handler prepares a request or ask ->
# kernel decides -> ledger records -> executor acts -> handle_result sees facts.
# A route match, a prompt and a local state update grant no authority.
defmodule Spectre.Example.BinaryMatcher do
  @moduledoc "An exact-text routing method, used as via: [:binary]. No provider I/O."
  use Spectre.Router.Adapter

  @impl true
  def evaluate(request, _options) do
    # rule.data is the text declared under match: [binary: ...]. A score of
    # 1.0 means an exact routing match, not permission to execute the request.
    {:ok, for(rule <- request.rules, rule.data === request.input, do: result(rule, 1.0))}
  end
end

defmodule Spectre.Example.Shared do
  @moduledoc "Reusable declarations; installing this Stack starts no services."
  use Spectre.Stack

  # Register a router port and its implementation. This does not install a
  # dependency or give the matcher access to an executor.
  adapter(:router, :binary, Spectre.Example.BinaryMatcher)
  prompt(:safety, "Propose only. A request or draft is not proof of delivery.")
  # Prepend this named text when composing model messages. It is guidance,
  # never a replacement for the kernel's authority checks.
  inject(:safety, position: :start)
end

defmodule Spectre.Example.OrdersRouter do
  @moduledoc "Flow-local input preparation and routing, separate from handlers."
  use Spectre.Router

  flow :orders do
    # The host supplies this prepared Pipeline (e.g. trim/downcase). Selecting
    # flow: :orders runs it before matching; other flows may use different ones.
    pipe_through(:normalize)
    # accept: minimum score; margin: required lead over a competing candidate.
    # These resolve routing confidence only. GAM admission happens afterwards.
    router(via: [:regex, :string_bag, :binary], accept: 0.85, margin: 0.05)
    # "order 42" becomes {:orders, :lookup, %{"id" => "42"}} for handle_turn.
    # :lookup is a local route name; "orders.lookup" below is a governed class.
    route(:lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u])
    route(:help, match: [string_bag: ["help with orders"], binary: "help"])
  end
end

defmodule Spectre.Example.Faq do
  @moduledoc """
  A reusable flow with its own callbacks, not another running agent.
  Mounted as :faq, its public flow name is "faq/questions"; callbacks still
  receive the local :questions name. The containing Instance owns local state.
  """
  use Spectre.Skill, namespace: "example", name: "faq"

  flow :questions do
    router(via: [:string_bag], accept: 0.9)
    route(:hours, match: [string_bag: ["opening hours"]])
  end

  # This tuple asks to prepare a governed request. It does not read opening
  # hours yet: the host must bind "support.hours" to authority and an executor.
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
  @moduledoc """
  Reusable finite-work handler. The host opens an authorized work Scope and
  starts its Instance; installing the worker declaration does neither.
  This input already has an order ID, so it needs no text router.
  """
  use Spectre.Worker, namespace: "example", name: "order_worker"

  @impl true
  def handle_work(%{"order_id" => id}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.QueueVigil do
  @moduledoc """
  Reusable watch handler. The host sends authenticated ticks/events and chooses
  their cadence. Spectre does not create a timer or an autonomous polling loop.
  Stopping the process does not discharge the governed watch promise.
  """
  use Spectre.Vigil, namespace: "example", name: "queue_vigil"

  @impl true
  def handle_vigil(%{"tick_ref" => ref}, _turn, state),
    do: {:request, "queue.inspect", %{"tick_ref" => ref}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.Support do
  @moduledoc """
  An order assistant assembled from reusable declarations.

  Start with map state, such as %{}. The app chooses flow: :orders or
  flow: "faq/questions" for each turn and decides which prepared request to
  advance. :order_id and :draft below are local working data, not ledger facts.
  """
  use Spectre.Agent, namespace: "example", name: "support", stack: Spectre.Example.Shared

  # The Router is extracted for reuse; its flow block could also live here.
  router(Spectre.Example.OrdersRouter)
  skill(Spectre.Example.Faq, as: :faq)
  worker(:lookup, Spectre.Example.OrderWorker)
  vigil(:queue, Spectre.Example.QueueVigil)

  # Relative to THIS source file. The default engine renders plain text EEx,
  # not HTML/HEEx; the assigns come from the {:ask, ...} callback result.
  prompt_root(Path.join(__DIR__, "prompts"))
  prompt(:answer, file: "answer.text.eex")
  prompt(:question, "Order <%= @order_id %>: <%= @question %>")

  # :answer names the ask; class names its governed model operation.
  # prompt/task select named system/task text. via selects the request
  # preparation port supplied by the host, NOT a model or a direct API call.
  # max_tokens is passed to that adapter; its contract must honor the limit.
  ask(:answer,
    class: "model.generate",
    prompt: :answer,
    task: :question,
    via: :inference,
    max_tokens: 300
  )

  # {:request, class, data, next_state}: prepare a proposal, remember the ID.
  # Surface owns the class's Row (effect dimensions); handlers do not invent it.
  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, Map.put(state, :order_id, id)}

  def handle_turn({:orders, :help, _match}, _turn, state),
    do: {:ask, :answer, %{order_id: "none", question: "Explain order lookup."}, state}

  # Routing failure is an application choice. Here we ask the host to clarify;
  # it could instead offer suggestions. No fallback route is chosen implicitly.
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

  # A successful generation yields a DRAFT. Sending it to a person is a
  # different effect and must cross the app's governed delivery boundary.
  def handle_result({:ask, :answer}, %{status: :done, data: data}, _turn, state),
    do: {:ok, Map.put(state, :draft, data)}

  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule Spectre.Example.Publication do
  @moduledoc "Build exact Definition revisions; no publication or activation happens here."

  @doc """
  Builds revision 1 using the host's chosen declaration time (Unix milliseconds).
  The parent's Definition pins the exact FAQ revision. Worker/Vigil Definitions
  are returned separately for their own governed activation and Scope opening.
  Submit these through the host's definition-revision workflow before use.
  """
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
