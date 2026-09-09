# Build an agent

An Agent is an Elixir module with callbacks. You describe how to handle input
and what to request next. Spectre checks permission before a requested governed
operation runs.

You can start with one module. A model, Router, Stack and Skills are all
optional.

This guide builds up the pieces in that order. Keep the
[configuration reference](configuration.md) nearby when you need an exact
default; you do not need to read every option first.

## A small Agent

This agent understands “order 42” and “help with orders.” It proposes an order
lookup or a help action; it does not call either service directly.

<!-- spectre:example guide_agent -->
```elixir
defmodule MyApp.Orders do
  use Spectre.Agent, namespace: "shop", name: "orders"

  flow :orders do
    router via: [:regex, :string_bag], accept: 0.85, margin: 0.05
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
    route :help, match: [string_bag: ["help with orders"]]
  end

  @impl true
  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn({:orders, :help, _match}, _turn, state),
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

  def handle_turn({:orders, :no_match, _input}, _turn, state),
    do: {:error, :clarification_needed, state}

  def handle_turn({_flow, :ambiguous, _refs}, _turn, state),
    do: {:error, :ambiguous_route, state}

  def handle_turn({_flow, :error, reason}, _turn, state),
    do: {:error, reason, state}

  @impl true
  def handle_result(_operation, result, _turn, state),
    do: {:ok, Map.put(state, :last_status, result.status)}
end

definition = MyApp.Orders.definition(revision: 1, declared_at: published_at)
```

### Read the example from top to bottom

- `namespace: "shop", name: "orders"` identifies this agent's published
  definition. These are not login credentials or process names.
- `flow :orders` names a group of interactions.
- `router via: ...` chooses the matching methods to try, in order.
- `route :lookup` names the handler branch. The regex captures the order ID.
- `handle_turn` receives the selected flow, branch and captures.
- `{:request, "orders.lookup", data, state}` proposes an application action.
- `handle_result` receives the result after a submitted request is resolved.

There are two different names in the lookup handler: `:lookup` is the local
route; `"orders.lookup"` is the action class declared by your application.
You may rename a route without inventing a new kind of permission.

`state` is your local value. In this example it starts as a map and later
holds `:last_status`. It is not the ledger or a spend budget. `_turn` means
the callback does not need to inspect the authenticated input/context.

The routing scores are only about choosing a handler. With `accept: 0.85`,
a score below 0.85 is not enough. With `margin: 0.05`, the winner must also
lead the second result by at least 0.05. Neither setting grants authority.

### Start it after host setup

The last line constructs a Definition: versioned data describing the agent.
`published_at` is an explicit timestamp supplied by the application.

Before starting an Instance, the host must activate that Definition in a
Domain and open an authenticated Scope. If those words are new, follow
[host setup](host-setup.md). That guide supplies the `scope`, `definition`
and `class_bindings` used here:

<!-- spectre:example guide_instance -->
```elixir
{:ok, instance} = MyApp.Orders.start_link(
  scope: scope,
  definition: definition,
  state: %{},
  bindings: class_bindings
)
{:ok, turn} = MyApp.Orders.turn(instance, "order 42", flow: :orders)
[request] = turn.requests

case Spectre.Instance.advance(instance, request, wait: 1_000) do
  {:ok, next_turn} -> {:completed, next_turn.result}
  {:pending, ref} -> {:watch, ref}
  {:error, reason} -> {:failed, reason}
end
```

Read these calls as:

1. **Start:** bind this Instance to its Scope, Definition and local state.
2. **Turn:** process “order 42” and get a prepared request.
3. **Advance:** choose that request and submit it for permission and execution.
4. **Inspect:** handle a completed result, a pending ticket, or an error.

`class_bindings` tells Spectre which existing Mandate, executor, accountable
actor and purpose apply to each action class. The
[lookup binding example](host-setup.md#connect-a-handler-to-a-governed-action)
explains every field.

The host configures the Domain with `mind: Spectre.Agent` for this API.
A custom `Spectre.Mind` is a separate lower-level option; you do not run both
paths for the same turn.

## Handler contract

### What can a handler return?

| Return | Use it when you want to… |
| --- | --- |
| `{:ok, state}` | Update local state without proposing an operation |
| `{:request, "class", data, state}` | Propose an application action directly |
| `{:request, :name, data, state}` | Use a named `request` template |
| `{:ask, :name, assigns, state}` | Render a prompt and prepare a model request |
| `{:classify, :name, input, state}` | Prepare a governed classification request |
| `{:error, reason, state}` | Return an application error |
| `{:request, candidate_or_list, state}` | Supply complete Candidates through the lower-level path |

A list contains up to 32 **alternatives**, not a sequence to execute.
Choosing one ticket with `advance` invalidates its siblings.

The default `init/1` accepts the initial state. Define the input branches you
need, including misses and errors. Spectre does not invent a helpful reply
for an unhandled message.

### What does submitting a request mean?

Returning a request does not submit it. The host calls `advance` when its
workflow is ready. It can do that automatically; human approval is only needed
where your declared rules require it.

After submission, `handle_result/4` receives the operation name, result,
corresponding Turn and component state. It can return another prepared request.
The host decides whether to advance that next request too.

Do not perform a governed provider call inside `handle_turn` or a request
preparation callback. Those callbacks prepare the proposal; an executor performs
the admitted operation.

### What does the result mean?

| `result.status` | Meaning |
| --- | --- |
| `:done` | The operation succeeded, or a ledger-only change was committed |
| `:refused` | Permission was refused |
| `:undecidable` | The available Evidence did not establish a decision |
| `:unknown_class` | The action class is not recognized |
| `:not_attempted` | A durable record confirms dispatch cancellation |
| `:failed` | An Outcome records failure |
| `:no_effect` | An Outcome establishes that no effect occurred |
| `:unclear` | The Outcome is ambiguous: the effect may have happened |

A successful API return is not automatically `:done`. Inspect the status.

The result also retains the original facts in `details`, any separate
`fallback` result, and the operation/request/turn references. A successful
fallback does not turn the original refusal into an approval.

Still running? `advance` returns `{:pending, ref}`. Keep that reference and
use `Instance.operation(instance, ref)` later. Pending work is not an
ambiguous Outcome; `handle_result` is not called merely because time passed.
An expired or forgotten local ticket also does not prove that nothing happened.

## Flow, Router and custom methods

Keep the Router inline for a small agent. Extract it when the routes make the
handler module hard to read. The declarations behave the same in either form:

<!-- spectre:example extracted_router -->
```elixir
defmodule MyApp.OrderRoutes do
  use Spectre.Router
  flow :orders do
    pipe_through :normalize
    router via: [:regex, :binary], accept: 0.9
    route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
    route :help, match: [binary: "help"]
  end
end

defmodule MyApp.BinaryMatcher do
  use Spectre.Router.Adapter
  @impl true
  def evaluate(request, _opts) do
    {:ok, for(rule <- request.rules, rule.data === request.input,
      do: result(rule, 1.0))}
  end
end

defmodule MyApp.RoutedOrders do
  use Spectre.Agent, namespace: "shop", name: "routed-orders"
  router MyApp.OrderRoutes
  adapter :router, :binary, MyApp.BinaryMatcher

  @impl true
  def handle_turn({:orders, :help, _captures}, _turn, state),
    do: {:request, "support.help", %{"target_ref" => "support:help"}, state}

  def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
    do: {:request, "orders.lookup", %{"order_id" => id}, state}

  def handle_turn(event, _turn, state), do: {:error, {:unhandled_route, event}, state}
end
```

There are three pieces here:

1. `OrderRoutes` declares where input should go.
2. `BinaryMatcher` implements an additional matching method. Its `result`
   helper returns a nomination with a score.
3. `RoutedOrders` connects that method and implements the chosen handlers.

`pipe_through :normalize` names a prepared local pipeline. The host creates
it once with `Spectre.Input.Pipeline.new/2` and supplies
`adapters: [pipelines: [normalize: pipeline]]`.

A flow does not inherit another flow's routing policy. Choose the flow in
`turn(..., flow: :orders)`. When mounting a Skill, use its qualified flow path,
such as `"faq/questions"`.

### Messages your handler can receive

| Message | What happened |
| --- | --- |
| `{flow, route, captures}` | A route won |
| `{flow, :no_match, input}` | No rule won |
| `{flow, :ambiguous, refs}` | More than one nomination remained plausible |
| `{flow, :error, reason}` | Routing failed |
| `{flow, :halted, input}` | A pipeline stopped processing |
| `{flow, :unrouted, input}` | The flow has no Router |

Methods try in order. A miss, skip or ambiguity can fall through to a later
method; an adapter error stops routing. Scores are not averaged across methods.
See [routing options](configuration.md#flow-and-router) for the exact rules.

The runtime records the selected route's provenance as derived Evidence.
That makes the choice traceable; it does not authorize the chosen action.

## Stack and Extension

Use a **Stack** to share configuration. Use a **Skill** to share behavior.

A Stack might contain common prompts, cache settings and adapter declarations.
An Agent chooses it with `stack: MyApp.Shared`. It does not start a process,
download dependencies or create permission.

An optional package can support `install Package do ... end`.
The package's `c:Spectre.Extension.configure/1` callback turns that block into
configuration and named adapter connections. The host still adds the package
to Mix dependencies and supervises its services.

`ports/0` lists those connection points. For example, `history/chat` means
“the chat-history backend named chat,” not a network port.

A fixed adapter module/options pair is already a declaration of wiring.
At startup, supply its missing runtime resources, such as a server address.
Do not repeat empty bindings just to make the declaration look connected.
Conflicting fixed values are errors, not “last option wins.”

Some inherited declarations support `override: true`; see
[configuration](configuration.md#connecting-adapters) for which ones.
The [component recipe](agent-recipes.md#reusable-skills-workers-and-vigils)
shows Stack and Skill used together.

## Prompts and injection

A **prompt** is a named text template. An **injection** adds another template
before or after it. An **ask** chooses the templates for a model request.

For a plain string, write `prompt :system, "Be helpful."`. You do not need a
file or an `asset` declaration.

Here is the file-based form with an extra instruction:

<!-- spectre:example prompts -->
```elixir
# Inside Agent or Stack:
prompt_root Path.expand("../examples/prompts", __DIR__)
prompt :system, file: "answer.text.eex"
prompt :question, "Order <%= @order_id %>: <%= @question %>"
prompt :safety, "A draft is not a delivered answer."
inject :safety, into: :system, position: :start

ask :answer,
  class: "model.generate",
  prompt: :system,
  task: :question,
  via: :inference,
  max_tokens: 300
```

Read the settings as follows:

- `prompt_root`: where the compiler finds prompt files.
- `file:`: the template file to compile.
- `@order_id` and `@question`: values supplied by the handler.
- `inject`: include the safety text before the system template.
- `prompt:` and `task:`: which named templates this ask uses.
- `via: :inference`: which request-preparation adapter is connected.
- `class: "model.generate"`: which governed action the host must define.
- `max_tokens:`: an option for the integration to implement, not an
  automatically created kernel budget.

These are EEx text templates (`.txt.eex` or `.text.eex`), not Phoenix
`.heex` templates. Files are compiled with your code, not reread on every
turn. In your app, a typical root is `Path.join(__DIR__, "prompts")`.

Injections can be declared at Agent, flow or route level. Within the selected
start/end position, that is also their ordering. An `into:` option restricts
the injection to one base prompt.

Rendering preserves separate system, task, history and memory parts. It
rejects missing assigns, invalid UTF-8 and output beyond 64 parts / 65,536
text bytes. User-supplied text is an assign, not template code to evaluate.

### Where is the model call?

The adapter implementing `Spectre.Agent.RequestBuilder.prepare/4` prepares
the consequence. The Domain's executor makes the actual provider call after
admission. An optional package such as Prism can supply that integration;
Spectre itself has no required provider dependency.

If private prompt text is put inline in the consequence, it becomes part of
the durable history. For separately erasable text, use a request/executor
integration with protected payload references. Deleting chat does not remove
copies already stored in an Act.

## History and Memory

Use **History** for “what was said in this conversation.”
Use **Memory** for “what relevant knowledge should this turn see.”

Neither is the authority ledger.

### Load a small chat window

`history :chat, keep: 30, max_bytes: 24_000` asks for up to 30 messages
within a byte budget. The host connects its backend through Instance adapters:

`history: [chat: {YourHistoryBackend, tenant_id: tenant, conversation_id: conversation}]`

The backend should limit its query before returning the data. Spectre supplies
the contract, not a bundled chat database.

Each message has a stable `ref`, a revision for concurrent-update checks,
UTF-8 `content`, a `role` (`:user`, `:assistant`, `:tool`), a status and
supporting `evidence_refs`.

### Saving is a separate choice

Loading a window does not automatically save new messages. The usual host flow is:

1. Observe input and append a `:received` message with `History.append/2`.
2. Complete inference and save the answer as a `:draft`.
3. Complete a delivery action and record its actual delivery receipt with
   `History.record_delivery/2`.

The other message statuses are `:failed` and `:unclear`. A generated answer
must not be marked `:delivered` just because the model returned it.

The backend implements `load/3`, `append/3` and `record_delivery/3`.
Summary and erasure callbacks are optional. The public helpers include
`load_summary/1`, `save_summary/3` and `erase/2`.
Summary generation, when needed, is a separate model request—not a hidden
call inside the store.

### Retrieve relevant knowledge

`memory :knowledge, limit: 5, max_bytes: 8_000` loads a small result set from
a `Spectre.Memory` adapter.

History and Memory items must cite Evidence available to the authenticated
Turn. This is how retrieved content stays connected to its sources. If old
records have no such references, the host integration must establish them;
the adapter cannot turn arbitrary stored text into an observed fact.

These context limits neither erase ledger entries nor hide old revocations
or Duties from the kernel.

## Semantic cache and classification

A routing cache remembers approved input-to-route examples. It helps choose
a handler; it does not cache permission to run an action.

### Start with Exact when you do not need vectors

<!-- spectre:example exact_cache_declaration -->
```elixir
# Inside Agent/Stack:
adapter :semantic_cache, :routing, Spectre.Router.SemanticCache.Exact,
  max_entries: 2_000
semantic_cache :routing, learn: :review

flow :support do
  router via: [:regex, :semantic_cache], cache: :routing, accept: 0.9
  route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u], cache: true
end
```

`cache: true` lets that route be nominated by the cache.
`learn: :review` may save a new example after a confirmed result, but leaves
it unapproved until review.

The host supervises the cache and supplies its address:

<!-- spectre:example cache_wiring -->
```elixir
adapters = [
  semantic_cache: [
    routing: [server: MyApp.Cache, namespace: "tenant-a/support", profile_ref: nil]
  ]
]
```

The cache belongs to an exact combination of namespace, Definition, flow and
encoder profile. This prevents examples for one agent version or tenant
partition being silently reused for another.

The built-in Router bridge handles `via: [:semantic_cache]`; you do not need
to write a matcher just to connect a cache backend.

### Use Vettore for vector search

The Vettore adapter is included in Spectre. Add `{:vettore, "~> 0.3.5"}` to
your application's dependencies if you choose it; Spectre does not require it.

Replace the Exact declaration:

<!-- spectre:example native_cache_declaration -->
```elixir
# Inside Agent/Stack: replace Exact with the supplied native-index adapter.
adapter :semantic_cache, :routing, Spectre.SemanticCache.Vettore,
  max_entries: 2_000, dimensions: 384
```

Then supervise the corresponding process:

<!-- spectre:example native_cache_child -->
```elixir
{Spectre.SemanticCache.Vettore,
 name: MyApp.Cache,
 namespace: "tenant-a/support",
 definition_ref: published_definition.ref,
 flow: "support",
 labels: ["support/lookup"],
 profile_ref: encoder_profile.ref,
 dimensions: 384,
 max_entries: 2_000,
 index: :flat}
```

`dimensions` is the vector length. `profile_ref` identifies the encoder
and preprocessing contract, not just that length. Two encoders producing
384 values are not necessarily interchangeable.

Wire the same namespace and profile to the Instance. The host can create
separate partitions for several flows and pass a map from complete bindings
to server addresses. Spectre does not create those partitions implicitly.

### Who computes the embedding?

Your integration does, before lookup. Native lookup expects text, a vector
and the matching profile. It does not accept an `embed:` callback.

Without a vector, the default bridge skips that cache method. A binding error
or corrupted response is an error, not an ordinary cache miss.

Both `:flat` and `:hnsw` indexes use normalized cosine vectors. Without the
Vettore dependency, startup returns `{:error, {:adapter_module_not_loaded, Vettore}}`.
The library's tests use real Vettore and ExFastembed; those are test-only
dependencies.

### Review and classification

Cache edits use revision checks. Editing an approved example removes its
approval; `verify` approves the exact new revision. Restoring a cache snapshot
requires a fresh destination. Backups and deletion policy belong to the host.

Automatic review collection does not promote examples, learn from ambiguous
effects, or learn again from a cache hit. A failed cache write does not retry
the original business action.

For a model-based classifier, the handler can return
`{:classify, :intent, input, state}`. After the governed result,
`route_result(turn, result)` checks nominations against the originating flow's
allowed labels. It chooses a handler message, not permission to execute.

Local classifiers use `Router.Adapter` and `:local_classifier`; governed
classifiers use `:llm_classifier`. See the
[complete classifier recipe](agent-recipes.md#a-classifier-before-the-business-handler).

## Skills, Worker/Vigil and Morph

### Share a behavior with a Skill

`skill MyApp.Faq, as: :faq` adds a component with its own substate in the same
Instance. Publish its exact Definition in
`components: %{faq: faq_definition}`, then select `flow: "faq/questions"`.

Callbacks return to the owning Skill. It does not get an extra process or a
second independent copy of the Domain's budget.

### Run a separate job or watch

A Worker implements `handle_work/3`; a Vigil implements `handle_vigil/3`.
Both can use `handle_result/4`.

Declare them with `worker :name, Module` or `vigil :name, Module`.
The host starts them with an input, published Definition, DynamicSupervisor
and a governed opening describing the promised work. Declaring one does not
schedule it.

If process startup fails after the opening was committed, the promise still
exists. The application must handle it rather than pretending the opening
never happened. See [reusable work](agent-recipes.md#reusable-skills-workers-and-vigils).

### Change a Definition with Morph

Morph prepares a new Definition for review. `Spectre.revise_definition/4`
handles its governed activation.

A changeset uses `:test` for an exact precondition, `:put` to write a value
and `:delete` to remove one. Paths address maps or zero-based list positions.
`prepare/3` accepts the whole changeset or rejects it.
`rollback/3` creates a new forward revision; it does not rewind history.

Deployment and state migration remain host work. Existing Instances stay bound
to their original Definition and code identity; they do not automatically
follow the newest version.

## Instance lifecycle and checkpoint

### What stays responsive?

One persistent Instance holds the last completed state. A monitored worker
performs slow work; by default, up to 32 mutations can wait in its queue.

State/info/scope/current-turn reads remain responsive. They accept an explicit
timeout, including `:infinity`. They return completed local state, not partial
provider output or proof that an external action succeeded.

### What happens when advance takes longer?

`advance` waits up to five seconds by default. After the chosen `wait:`,
it can return `{:pending, ref}`. This stops the caller waiting; it does not
cancel the executor.

When a proposal returns deferred, the worker slot is released. There is no
infinite background polling. `operation/3` can refresh that occurrence once
and continue its handler without submitting the effect again.

The Instance retains 64 recent completed/deferred operations plus active and
queued work. Tickets are not an archive: use durable records for older facts.

New input invalidates unsubmitted tickets. If an old submitted result arrives
after a newer turn, it is still a fact, but its old handler must not overwrite
the newer state. The API reports
`{:error, {:instance_continuation_superseded, result}}`.

### What survives a restart?

A checkpoint saves portable local state and Skill substates through the
application store. It does not save authentication, request tickets, Grants
or the Domain projection.

Domain loss stops its Instances. Startup needs fresh authentication and a
suitable Scope; restoring the old checkpoint does not renew the old Scope.

## Check fixed declarations against a Surface

Use `Spectre.Surface.verify_definition/2` to check fixed declarations and see
which facts still need to be supplied for an actual request.

Use `mix spectre.routes MyApp.Agent` to inspect flows, routes, prompts and
ports. Doctor can check actual `port_wiring`.

These checks catch setup mistakes. They do not execute an action or prove
that a remote identity, credential service or backend is trustworthy.

Next: [connect the agent to your host application](host-setup.md), or choose
a [complete recipe](agent-recipes.md).
