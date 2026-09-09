# Agent recipes: choose the pieces you need

Do not start with the largest example. Pick the row that matches your input:

| You already have… | Use |
| --- | --- |
| Structured application data | [A direct handler](#structured-input-no-router-no-model) |
| Text commands | [A Router and handler](#text-commands-router-then-handler) |
| A question that needs generation | [A prompt and ask](#asking-a-model-handler-prompt-governed-inference) |
| Text that needs intent classification | [A classifier followed by a handler](#a-classifier-before-the-business-handler) |
| Approved routing examples | [A cache](#semantic-cache-without-hidden-model-calls) |
| Behavior shared by several agents | [Skills, Workers or Vigils](#reusable-skills-workers-and-vigils) |

All use the same runtime. A prepared request still needs the host's
`advance` before it can run. The host may automate that choice; GAM does not
require a human click for every step.

The examples declare behavior. [Host setup](host-setup.md) supplies the
authenticated Scope, activated Definition and action bindings.

## The Router / Controller / Template analogy

If you know Phoenix, the analogy is useful—but optional pieces stay optional.

- **Router:** chooses a handler branch.
- **Controller:** your Agent's `handle_turn` and `handle_result` callbacks.
- **Template:** prompt text used when that handler asks a model.
- **Model:** an optional provider service, not a compulsory layer.

There is no required `Spectre.Controller` module.
A template does not deliver an answer, and a route does not execute an action.

In the simplest case, structured input goes straight to a handler.
In the model-assisted case, a handler prepares an ask, then handles its result.

## Structured input: no Router, no model

Use this when your app already knows what it is sending. For example, a form
submission can provide an order ID directly.

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

### Try it

Start the Instance with the normal host prerequisites, then call
`Instance.turn(instance, %{"order_id" => "42"})` without `flow:`.

### What to expect

- `order_id` produces an unsubmitted lookup request.
- `note` only changes local state.
- another input shape returns `:unsupported_input`.

Input still passes through the configured ingress. Omitting the Router does
not skip authentication or authorize the lookup.

## Text commands: Router then handler

Use this for commands such as “order 42.”

The [Orders example](agents-and-dsl.md#a-small-agent) routes it to
`{:orders, :lookup, %{"id" => "42"}}`.
The handler prepares an `"orders.lookup"` request.

The names have different jobs:

| Name | Job |
| --- | --- |
| `:orders` | Flow chosen by your application |
| `:lookup` | Handler branch chosen by the Router |
| `"orders.lookup"` | Action class checked by the kernel |
| `"42"` | Order targeted by this particular request |

If the Mandate does not cover order 42, the request is refused even when the
regex matches perfectly.

Keep routes inline while the Agent is small. Use
[an extracted Router](agents-and-dsl.md#flow-router-and-custom-methods) when
several modules share the logic or the file becomes hard to follow.
Each flow keeps its own pipeline and matching policy.

## Asking a model: handler, prompt, governed inference

Use this when you want a model-generated draft. The example stores the draft
locally; it does not send it to a customer.

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

### What to connect

The host supplies a `model.generate` Surface class, permission, executor and
broker.

`:inference` is a preparation port. The default builder passes along the
rendered plan; your executor must understand that plan, or a custom builder
must translate it.

`model_ref: "support-writer"` is an example application identifier.
Spectre does not download a model or infer a provider from it.
Likewise, `max_tokens: 300` is an integration setting, not an automatic
Meter reservation.

### What happens when the input arrives?

1. The turn renders `:policy` and `:question`.
2. It returns an ask ticket.
3. Your application advances that ticket.
4. An admitted request reaches the model executor.
5. The result handler saves the observed data as `:draft`.

The rendered plan preserves ordered `parts`, `configuration`,
`definition_ref` and `turn_ref`. Your request/executor contract decides how
those become a real provider request and how the response is recorded.

### What if I want to send the draft?

Prepare another request for your delivery class and advance it separately
when delivery is governed. Generating text and delivering it are different
operations.

`result.data` is determined by the observed-result contract; it is not always
a string. Pattern-match your integration's shape.

For files, shared instructions and conversation context, see
[prompts and injection](agents-and-dsl.md#prompts-and-injection).

## A classifier before the business handler

Use this when exact commands are useful, but other input needs a model to
identify intent.

There are potentially two requests: classification first, then a business
operation. The initial Router does not make a remote model call.

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

### Follow two inputs

For `"help"`, the regex selects the help handler immediately. No classifier
request is needed.

For `"I need to speak to someone"`, a miss prepares a classification request.
After its admitted execution returns labels, `route_result` selects a handler
message in the original flow.

That handler can prepare `support.contact`. It is still a new request with
its own permission check and advance.

### What must the classifier return?

Its observed result contains `"labels"`: up to 32 maps, each with exactly
`"label"` and `"score"`.

For example, the label is `"support/help"` with a numeric score such as
`0.95`. Labels must be unique and allowed; scores must be between 0 and 1.

The input to the classifier includes `input`, allowed `labels`,
`configuration`, `turn_ref` and `definition_ref`.
The bridge checks that the result belongs to the current classification turn.

A route label such as `"support/help"` is not the action class
`"support.help"`.

Low scores or ambiguity ask for clarification in this example. They do not
start an unbounded classifier retry loop.

### What about a local classifier?

Use `:local_classifier` and an adapter implementing
`c:Spectre.Router.Adapter.evaluate/2` for an already available local model.
One flow chooses one classifier mode.

Optional packages can supply preparation/provider adapters. Check the selected
package's 0.4 compatibility and integration tests; this example does not
install one.

## Semantic cache without hidden model calls

Use a cache to reuse reviewed input-to-route examples.
The [Exact/Vettore walkthrough](agents-and-dsl.md#semantic-cache-and-classification)
shows the wiring.

Choose:

- **Exact:** text lookup without embeddings.
- **Vettore:** vector search using embeddings obtained beforehand.

The vector's `profile_ref` must match the cache's encoder contract.
A missing vector skips the native method rather than calling an encoder.
A cache hit nominates a route, not an old authorization; current permissions
and facts are checked when the new request is submitted.

`learn: :review` may save a quarantined example after a confirmed result.
A separate review approves it. Training remains outside the library.

### Be explicit about Router input

Built-in text matchers take a string. The cache bridge can also take
`%{"text" => text, "embedding" => vector, "profile_ref" => ref}`.

If you combine these forms, connect local adapters/pipelines that preserve the
needed data. Do not assume the Router unwraps an envelope for every matcher,
or discard the vector by converting everything to text.

## Reusable Skills, Workers and Vigils

Choose based on ownership:

- **Skill:** behavior and substate inside the same Instance.
- **Worker:** separate work under an explicit promise.
- **Vigil:** a separate watch under an explicit promise; the host supplies ticks
  or events.
- **Stack:** shared declarations, with no state-owning process.

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

### Use the Skill

`as: :faq` creates the path `"faq/questions"`.
Call that flow on the parent Instance; the Skill receives its own substate.

`components: %{faq: faq}` binds the exact Skill Definition. It does not
create another process or budget.

The parent here delegates its input through the selected Skill flow, so it
does not need a root handler for those interactions.

### Connect the observer

`stack: MyApp.SharedDefaults` reuses the observer declaration.
The application supervises `MyApp.Metrics`; `to:` only says where to send
events. It neither starts the collector nor makes it a durable log.

### Start the Worker or Vigil

Declaring the module does not start it.
`SupportTeam.start_worker(parent, :orders, options)` needs:

| Option | Supply |
| --- | --- |
| `input` | The actual job input |
| `definition` | The Worker's separately activated Definition |
| `supervisor` | Your running DynamicSupervisor |
| `opening.context` | Authenticated child Scope context |
| `opening.attributes` | The finite promise, timing and fulfillment condition |
| `opening.candidate` | Permission/accountability for the parent's opening action |
| `opening.options` | Optional facade call options |
| `bindings`, `adapters`, `state` | Child wiring and initial local value |

The helper governs the opening, starts the child and runs its initial turn.
It returns `{:ok, child_pid}`, not confirmation that the child's requested
work has run.

Read `Instance.current_turn(child_pid)` and choose what to advance.
`start_vigil` uses the same pattern; the host supplies later inputs.
Child authority must already be provided.

If startup fails after the opening was committed, the error retains the
durable Scope reference. The promise remains; killing a process does not
fulfill it.

## Streaming, observability, upgrades and storage

These use the same pieces rather than a second agent runtime.

| You want… | Where to continue |
| --- | --- |
| Streaming, voice or TTS | [Input and streaming](integration-and-streaming.md) |
| UI progress | Instance reads, `operation`, and [observer wiring](configuration.md#connecting-adapters) |
| Chat and retrieved knowledge | [History and Memory](agents-and-dsl.md#history-and-memory) |
| A revised agent | [Morph and publication](agents-and-dsl.md#change-a-definition-with-morph) |
| Durable storage or local checkpoints | [Storage and recovery](storage-and-recovery.md) |

For a new integration, answer two questions separately:
“what request data should the handler prepare?” and
“which governed class covers the actual effect?”

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


Translate known error codes in your application. Do not expose arbitrary
provider messages or private prompt data in user-facing errors.

## A complete modular authoring example

Use this as a reference after trying the smaller recipes.

It combines a Stack, custom binary matcher, extracted Router, Skill, Worker,
Vigil, file prompt, injection and model ask. It declares an agent; it does
not configure a payment service, create authority or start a model.

### Read the modules in this order

1. `Shared`: safety text and a shared matcher.
2. `OrdersRouter`: normalization and route choices.
3. `Faq`, `OrderWorker`, `QueueVigil`: reusable behaviors.
4. `Support`: composition and result handling.
5. `Publication`: explicit versions for the Agent and its components.

To run it, supply the prepared `normalize` pipeline, the
`request/inference` adapter, action classes and bindings. Activate the
Definitions and open the authenticated Scope before starting the Instance.

### Inspect it without starting an agent

From the source checkout:

```sh
mix run --no-start -r examples/authoring.exs \
  -e 'Mix.Task.run("spectre.routes", ["Spectre.Example.Support"])'
```

This prints flows, handler messages and ports. It does not run handlers,
advance requests or start jobs.

### Full listing

The listing is checked against the shipped `examples/authoring.exs`.
Keep `prompts/answer.text.eex` beside it. When splitting modules into your
application, adjust `prompt_root` relative to the source file.

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
