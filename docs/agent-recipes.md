# Agent recipes: choose the pieces you need

These are combinations of the same API, not different runtimes. Start with the
smallest one that fits your input. You can keep declarations and handlers in
one module, then extract routing or shared configuration when it becomes useful.

If you are new to Spectre, read the [small Agent](agents-and-dsl.md#a-small-agent)
first. [Host setup](host-setup.md) supplies the authenticated Scope, activated
Definition and action bindings used to execute any request below.

## The Router / Controller / Template analogy

Think of the Controller as **your Agent's `handle_turn` and `handle_result`
callbacks**. It is not a separate required module or a web controller.
A prompt is an input template for inference, not a view that sends a response.
An LLM is an optional service; it is not the MVC “Model” of all agents.

| Combination | What happens | Does it need a model? |
| --- | --- | --- |
| Structured input → handler | Pattern matching in Elixir decides what to prepare | No |
| Router → handler | A flow chooses a branch using regex, examples or a local adapter | No |
| Handler → Template → model → result handler | `ask` prepares an inference request; host advances it | Yes, supplied by the host |
| Router miss → classifier → Router result → handler | `classify` obtains labels through a governed request, then resumes the original flow | Only for the governed model variant |
| Router → cache → handler | Approved examples nominate a branch; normal authority checks still follow | Not during lookup; vectors must already exist |
| Handler → Worker/Vigil | A governed promise is opened, then a separate Instance prepares work | Only if its own handlers use one |

In every row, **a prepared request still needs `advance`** before the kernel can
admit it. `handle_result` may prepare another request, but never auto-submits it.
The host can automate those choices within its policy; no human approval is
required unless the applicable governed policy requires it.

## Structured input: no Router, no model

When your app already knows what the input means, do not convert it to text
just to match it again. A handler can use normal Elixir patterns:

<!-- spectre:example direct_handler -->
```elixir
defmodule MyApp.DirectOrders do
  use Spectre.Agent, namespace: "shop", name: "direct-orders"

  @impl true
  def handle_turn(%{"order_id" => id}, _turn, state) when is_binary(id),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn(%{"note" => note}, _turn, state) when is_binary(note),
    do: {:ok, Map.put(state, :note, note)}

  def handle_turn(_input, _turn, state), do: {:error, :unsupported_input, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end
```

Start it with the same `scope`, `definition` and `bindings` as any other Agent,
then use `Instance.turn(instance, %{"order_id" => "42"})` **without `flow:`**.
The lookup becomes a request; the note branch only changes local state.
Neither branch sends a message to the customer. Even without an action request,
the input still passes through the configured Ingress and observation path.

## Text commands: Router then handler

The [Orders example](agents-and-dsl.md#a-small-agent) adds regex and string-bag
matching. It turns `"order 42"` into the message
`{:orders, :lookup, %{"id" => "42"}}`. The handler returns a request for
`"orders.lookup"` with the ID as data.

The names are deliberately separate:

- `:orders` is the flow selected by your application.
- `:lookup` is the route branch selected by the Router.
- `"orders.lookup"` is the action class checked by the kernel.
- `"42"` is the target order carried by this occurrence.

A different branch can propose the same class. A route is neither an endpoint
that executes a function nor a permission entry. If an order is outside the
Mandate, matching it perfectly still results in refusal.

Use [an extracted Router](agents-and-dsl.md#flow-router-and-custom-methods)
when several agents share routing logic. `router MyRoutes` imports the plan;
the Agent keeps its handlers. Flow-specific pipelines and matching policies
remain in that Router, not in a global singleton.

## Asking a model: handler, prompt, governed inference

This Agent prepares a draft. It does not send the draft to a customer:

<!-- spectre:example draft_agent -->
```elixir
defmodule MyApp.DraftAssistant do
  use Spectre.Agent, namespace: "shop", name: "draft-assistant"

  # The supplied preparation adapter builds data; it never calls a provider.
  adapter :request, :inference, Spectre.Agent.RequestBuilder

  prompt :policy, "Write a helpful draft. Do not claim any action has run."
  prompt :question, "Customer question: <%= @question %>"

  ask :reply,
    class: "model.generate",
    prompt: :policy,
    task: :question,
    via: :inference,
    model_ref: "support-writer",
    max_tokens: 300

  @impl true
  def handle_turn(question, _turn, state) when is_binary(question),
    do: {:ask, :reply, %{question: question}, state}

  def handle_turn(_input, _turn, state), do: {:error, :text_required, state}

  @impl true
  def handle_result({:ask, :reply}, %{status: :done, data: draft}, _turn, state),
    do: {:ok, Map.put(state, :draft, draft)}

  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end
```

Here `:reply` names an ask, `:policy`/`:question` name templates and `:inference`
names a preparation port. `"model.generate"` is a host-defined Surface class.
`model_ref: "support-writer"` is an **example application model identifier**;
the executor must resolve it. Spectre does not install or select a provider
from that string. `max_tokens` is also adapter-defined configuration, not an
automatic resource reservation. The host must enforce it in its contract.

The host still needs a `model.generate` consequence contract, Mandate and
executor/broker. The default builder preserves the rendered plan's ordered
`parts`, `configuration`, `definition_ref` and `turn_ref`. The executor must
understand that data, or a custom request adapter must translate it into the
host's exact consequence shape. Tokens/temperature/model restrictions that
matter to authority must be represented by that contract and accounting.

At runtime:

1. `turn` renders the chosen prompts and returns one unsubmitted ask ticket.
2. Your application calls `advance` on that ticket.
3. The kernel checks the inference request; only an admitted and recorded Act
   reaches the model executor.
4. The result handler stores the supported result data locally as `:draft`.
5. To deliver it, prepare and advance a **separate delivery request** if delivery
   is a governed effect. Saving a draft is not permission to publish it.

`result.data` is not universally a string. It comes from the observed result
contract. Define the shape in your model adapter and pattern-match it there.
For file templates, shared instructions and chat context, use
[prompts and injection](agents-and-dsl.md#prompts-and-injection).

## A classifier before the business handler

A model-assisted classifier is a two-request workflow: first classification,
then any business action the result leads to. The Router itself does no remote
inference. This example lets an exact regex avoid the classifier entirely:

<!-- spectre:example classifier_agent -->
```elixir
defmodule MyApp.IntentAssistant do
  use Spectre.Agent, namespace: "shop", name: "intent-assistant"
  adapter :request, :inference, Spectre.Agent.RequestBuilder
  classifier :intent, class: "model.classify", via: :inference

  flow :support do
    router via: [:regex, :llm_classifier], classifier: :intent,
      accept: 0.85, margin: 0.05

    route :help, match: [regex: ~r/^help$/u], classify: true
    route :contact, classify: true
  end

  @impl true
  def handle_turn({:support, :help, _match}, _turn, state),
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

  def handle_turn({:support, :contact, _match}, _turn, state),
    do: {:request, "support.contact", %{"target_ref" => "support:team"}, state}

  def handle_turn({:support, :no_match, input}, _turn, state),
    do: {:classify, :intent, input, state}

  def handle_turn(event, _turn, state), do: {:error, {:unhandled_route, event}, state}

  @impl true
  def handle_result({:classify, :intent}, %{status: :done} = result, turn, state) do
    case route_result(turn, result) do
      {:ok, message} -> handle_turn(message, turn, state)
      :no_match -> {:error, :clarification_needed, state}
      {:ambiguous, _labels} -> {:error, :clarification_needed, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end
```

The classifier receives `input`, the allowed `labels`, `configuration`,
`turn_ref` and `definition_ref`. Its observed result data must contain `"labels"`
as a list of maps with **exactly** `"label"` and `"score"`, such as a label
`"support/help"` and a numeric score `0.95`. There are at most 32 nominations;
scores must be between 0 and 1 and labels must be unique and allowed.

The route label is not the action class `"support.help"`. The bridge checks the
exact originating turn and result before selecting a handler. Low scores and
ties ask for clarification here; they do not recursively call the classifier.
The newly returned business request still needs its own `advance` and Mandate.

For a **local** classifier, use `:local_classifier` and a host adapter implementing
`c:Spectre.Router.Adapter.evaluate/2`. That returns nominations immediately with
no remote call. Use only one classifier mode per flow. Prism's separate 0.4
bridge is still pending; these examples do not claim a working Prism package.

## Semantic cache without hidden model calls

Use the [Exact and Vettore examples](agents-and-dsl.md#semantic-cache-and-classification)
to wire `cache: :routing` and `via: [:semantic_cache]`.

- Exact needs text and approved examples. It does not need embeddings.
- Vettore needs vectors produced earlier by your chosen encoder, and a matching
  `profile_ref`. Spectre ships the adapter, not its native dependency or encoder.
- Missing vectors cause the cache method to skip, allowing your next method or
  no-match handler to decide what to do. It never calls `embed` behind your back.
- A cache hit proposes a route, not a cached permission or a replayed Act.
  Current Mandates, revocations, Evidence and budgets are checked again.
- `learn: :review` saves only a candidate training example after a confirmed
  supported result. A separate explicit review approves it. Training itself is
  outside this library.

A vector envelope and a plain string are different Router inputs. Built-in
regex/string matchers consume a string; the semantic bridge can consume an
envelope with `"text"`, `"embedding"`, `"profile_ref"`. Use the method contracts
to compose your host's local adapters; do not assume the Router unwraps both
representations for every method.

## Reusable Skills, Workers and Vigils

Use a Skill for reusable behavior inside the same conversation/state owner.
Use a Worker or Vigil when it needs a separate supervised Instance and an
explicit durable promise. A Vigil does not install a timer automatically.

<!-- spectre:example reusable_components -->
```elixir
defmodule MyApp.HelpSkill do
  use Spectre.Skill, namespace: "shop", name: "help"
  flow :questions do
    router via: [:string_bag], accept: 0.9
    route :help, match: [string_bag: ["help with orders"]]
  end

  @impl true
  def handle_turn({:questions, :help, _match}, _turn, state),
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

  def handle_turn(event, _turn, state), do: {:error, {:unhandled_route, event}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule MyApp.OrderWorker do
  use Spectre.Worker, namespace: "shop", name: "order-worker"

  @impl true
  def handle_work(%{"order_id" => id}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule MyApp.QueueVigil do
  use Spectre.Vigil, namespace: "shop", name: "queue-vigil"

  @impl true
  def handle_vigil(%{"queue_ref" => ref}, _turn, state),
    do: {:request, "queue.inspect", %{"queue_ref" => ref}, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

defmodule MyApp.SharedDefaults do
  use Spectre.Stack
  adapter :observer, :events, Spectre.Agent.Observer, to: MyApp.Metrics
end

defmodule MyApp.SupportTeam do
  use Spectre.Agent, namespace: "shop", name: "support-team", stack: MyApp.SharedDefaults
  skill MyApp.HelpSkill, as: :faq
  worker :orders, MyApp.OrderWorker
  vigil :queue, MyApp.QueueVigil
end

faq = MyApp.HelpSkill.definition(revision: 1, declared_at: published_at)
definition = MyApp.SupportTeam.definition(
  revision: 1, declared_at: published_at, components: %{faq: faq}
)
```

`as: :faq` creates the Skill's state namespace and flow path `"faq/questions"`.
Call that flow on the parent Instance; the Skill's callbacks receive its own
state. The parent in this example has no root handler because it delegates all
input through the explicitly selected Skill flow. `components` pins the exact
Skill revision. It does not create another budget or process.

`stack` reuses the observer declaration. The application must supervise
`MyApp.Metrics`; `to:` only identifies where events are sent. It neither starts
the receiver nor makes it a durable log. Different agents may reuse the same
Stack while keeping their own Scope, Definition and state.

For separate work, `SupportTeam.start_worker(parent, :orders, options)` needs:

| Field | Example meaning |
| --- | --- |
| `input` | The actual work input, such as an order-ID map |
| `definition` | The separately published and governed Worker Definition |
| `supervisor` | Your running DynamicSupervisor, not one started by the declaration |
| `opening.context` | Authenticated child Scope context |
| `opening.attributes` | The finite work/vigil promise, time limits and fulfillment condition |
| `opening.candidate` | Explicit authority/accountability fields for the parent's `scope.open` action |
| `opening.options` | Optional facade call options |
| `bindings`, `adapters`, `state` | The child's explicit runtime wiring and local initial value |

The helper first governs the opening, starts the child, and runs its initial
turn. It returns `{:ok, child_pid}`; **it does not advance the child's prepared
requests**. Read `Instance.current_turn(child_pid)` to choose what to submit.
`start_vigil` follows the same pattern; your app provides authenticated ticks
or events through `turn`. Child authority must already be explicitly provided.

If startup fails after the opening committed, the error contains the durable
Scope reference; the promise remains. Killing a worker does not fulfill it.
See [Scope lifecycle](host-setup.md#authenticate-open-and-use-a-scope).

## A complete modular authoring example

The distributed `examples/authoring.exs` assembles a Stack, custom
binary matcher, extracted Router, Skill, Worker, Vigil, prompt file, injection
and model ask. It compiles without starting services or creating authority.

Read it in this order:

1. `Shared` contributes reusable safety text and the binary matcher port.
2. `OrdersRouter` owns flow-local normalization and route choices.
3. `Faq`, `OrderWorker` and `QueueVigil` own reusable handlers.
4. `Support` connects those pieces and handles lookup/model results.
5. `Publication.definitions(at)` builds the exact Definitions explicitly.

To run it in your app, supply the prepared `normalize` pipeline, the
`request/inference` preparation adapter, the declared governed classes and
their bindings. Activate the Definitions, authenticate/open the parent Scope,
then supervise its Instance. Workers/Vigils are started through the opening
path above, not just by installing their modules. The example is a complete
**authoring** composition, not a preconfigured payment/provider application.

The following is that same file, checked against the distributed source. Save
it with `prompts/answer.text.eex` beside it (the shipped file contains the
system instructions); when splitting modules into your application's `lib/`,
adjust `prompt_root` relative to that source file.

From a checkout, inspect the declarations without opening a Domain:

```sh
mix run --no-start -r examples/authoring.exs \
  -e 'Mix.Task.run("spectre.routes", ["Spectre.Example.Support"])'
```

This prints the available flows, handler messages and required ports. It does
not run `handle_turn`, call a model, start a Worker or publish a Definition.
For a smaller starting point that generates its own runnable routing test,
use [the Hello World generator](testing-and-release.md#scaffold-a-local-agent).

<!-- spectre:example complete_authoring -->
```elixir
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
```

## Streaming, observability, upgrades and storage

- **Streaming / voice / TTS:** the app chooses buffering, when content becomes
  a proposal and how bytes are delivered. A generated draft is not a delivery
  authorization. See [the streaming guide](integration-and-streaming.md).
- **UI progress:** use `info/state/current_turn` and `operation` to observe;
  never call `advance` again to poll. Optional observer events contain refs and
  timings, not prompt bodies. [Observer configuration](configuration.md#connecting-adapters)
  describes the default adapter.
- **Conversation history:** a `history` window loads chat; explicit append and
  delivery receipts save it. `memory` retrieves cited knowledge. Neither is the
  ledger. See [History and Memory](agents-and-dsl.md#history-and-memory).
- **Morph:** build a new Definition and activate it through governed revision.
  Code deployment and local-state migration remain separate host operations.
  Old Instances do not silently switch to the newest definition.
- **Persistence:** choose an authority ledger, an application checkpoint store
  and an external payload store for their distinct roles. See
  [storage and recovery](storage-and-recovery.md).

When adding an integration, ask two questions separately: “what data should this
handler prepare?” and “which existing governed class authorizes its effect?”.
That separation keeps new providers and routing methods out of the kernel.

## When an example does not run

| What you see | What to check |
| --- | --- |
| `:agent_flow_required` | Pass `flow:` when flows are declared; Spectre does not pick one implicitly |
| An unwired port error | Inspect `MyAgent.ports()` and provide the actual resource in `adapters`; declaring a port is not starting a service |
| `:unknown_class` during request preparation | The current Surface does not declare the requested class; this is not a Router miss |
| A request-binding conflict | A template, adapter or host map supplied a different value for the same fixed field; correct the disagreement |
| `:refused` | Inspect the Decision; matching a route or authenticating a user did not grant the required authority |
| `:undecidable` | Required facts could not establish admission; do not reinterpret this as denial or retry the effect |
| `{:pending, ref}` | Keep the ref and observe it with `operation`; do not create a new request for the same effect |
| A draft with no delivered message | Expected: generation is not delivery. Implement and govern your delivery boundary |
| Cache misses despite similar text | Check approval, exact Definition/flow/namespace, encoder profile/vector and Router threshold |
| An invalid/stale Scope after restart | Obtain fresh authentication and a properly authorized new Scope; a saved PID/checkpoint is not renewable authority |

Translate structured errors into your application's language. Do not expose
arbitrary exception data or private prompt/provider text to end users.
