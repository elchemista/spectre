# Spectre

Spectre is an OTP-native Elixir runtime for building agents without turning the
agent itself into a pile of callbacks, prompt glue, and ad hoc routing code.

The goal is simple: describe the shape of an agent in one readable place, keep
dangerous side effects behind explicit boundaries, and let normal Elixir modules
do the real work.

There is a thin line here. If a DSL becomes too abstract, you stop seeing what
the system actually does. If it is too small, every project rebuilds the same
agent plumbing by hand. Spectre tries to stay in the middle: declarative where
the structure is repetitive, plain Elixir where your application needs judgment.
That philosophy is inspired by the good parts of the Elixir ecosystem: Phoenix
routers, Ecto schemas, Oban workers, Ash resources, Broadway pipelines, and OTP
supervision trees. A Spectre agent should feel like a map, not a magic trick.

> This is still work in progress and I don't even know it i will keep it public.
> I integrated this library in different products and shaping it base on feedback
> and on what is really useful in real world.

## A Small Agent

This is the kind of module Spectre is designed to make easy:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM,
    purpose: :smart,
    fallback: MyApp.FallbackLLM
  )

  embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

  router(
    via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier],
    artifact_dir: "priv/spectre/support",
    terminal_labels: [:PRICING, :TECHNICAL_SUPPORT, :DELETE_ACCOUNT]
  )

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText, case: :downcase)
  end

  actions MyApp.SupportActions do
    protect(:delete_account, with: :delete_account_confirmation)

    after_action(:delete_account,
      on: :delivered,
      run: {MyApp.SupportSideEffects, :after_delivery}
    )
  end

  policy :delete_account_confirmation do
    request(:confirm_delete_account)

    accept(:confirmed_delete,
      regex: ~r/^yes, delete it$/i,
      train: ["yes delete my account"]
    )

    reject(:cancel_delete,
      regex: ~r/^no|cancel$/i,
      train: ["cancel", "do not delete"]
    )

    otherwise(ask: :confirm_delete_account_retry)
    attempts(3, then: :cancel_pending)
  end

  interrupt :HELP, regex: ~r/\b(help|menu|what can you do)\b/i do
    reply(:help, renderer: {MyApp.SupportReplies, :route_reply})
  end

  flow :support do
    on :PRICING,
      regex: ~r/\b(price|pricing|cost)\b/i,
      embedding: ["how much does it cost?", "pricing plans"],
      train: "training/support/pricing.jsonl",
      via: [:regex, :embedding, :classifier] do
      reply(:pricing, renderer: {MyApp.SupportReplies, :route_reply})
    end

    on :TECHNICAL_SUPPORT,
      embedding: ["my integration is failing", "the API returns an error"],
      train: true,
      via: [:embedding, :classifier, :semantic_cache, :llm_classifier] do
      ask(:technical_support)
    end

    on :DELETE_ACCOUNT, regex: ~r/\bdelete my account\b/i do
      action(:delete_account) do
        reply(:delete_confirmation_started, renderer: {MyApp.SupportReplies, :route_reply})
      end
    end
  end
end
```

The module says:

- how input is normalized
- which model adapter is used
- which routing strategies are allowed
- which intents exist
- which routes are deterministic
- which routes may use embedding or classifier evidence
- which actions require policy approval
- which prompts are rendered
- which replies avoid the LLM entirely

The application still owns `MyApp.LLM`, `MyApp.SupportActions`,
`MyApp.Embeddings`, state storage, semantic cache storage, and the actual
business logic.

## How A Turn Runs

A normal turn looks like this:

```elixir
{:ok, result} =
  Spectre.ask(MyApp.SupportAgent, "How much does it cost?",
    conversation_id: "chat-123"
  )
```

Spectre then:

1. Builds a `%Spectre.Input{}`.
2. Runs the optional input pipeline.
3. Loads state and memory adapters if configured.
4. If a policy is active, routes only inside that policy.
5. Otherwise runs the router pipeline and arbitrator.
6. Runs the selected handler.
7. Records chat history.
8. Persists state and memory if adapters exist.

The result contains the selected route, the normalized input, the updated state,
visible reply text, staged actions, and runtime events.

## How Options Flow

The DSL compiles metadata into functions such as `__spectre_config__/0`,
`__spectre_router__/0`, `__spectre_rules__/0`, and
`__spectre_policies__/0`. Runtime does not re-evaluate DSL blocks. It reads that
compiled metadata for each turn.

Options come from three places:

1. Agent config, declared with DSL macros such as `model/2`, `embedding/2`,
   `input_pipeline/1`, `history/1`, `state/1`, and `memory/1`.
2. Router config, declared with `router/1` or `arbitrator/2`.
3. Per-call opts passed to `Spectre.ask/3`, `Spectre.summon/1`, or a session
   turn.

Per-call opts win over compiled defaults:

```elixir
Spectre.ask(MyApp.SupportAgent, "price?",
  conversation_id: "chat-123",
  via: [:regex],
  assigns: %{tenant: tenant},
  classify: &MyApp.TestClassifier.classify/2
)
```

That call can temporarily override router strategy, add prompt assigns, or swap
an adapter for a test. This is deliberate: the DSL gives a stable default shape,
while runtime opts let hosts and tests inject context without recompiling an
agent.

Common option families:

- model opts: `model`, `adapter`, `fallback`, `llm_opts`, `classifier_prompt`,
  `recent_chat`
- classifier opts: `classify`, `classifier`, `artifact_dir`,
  `local_accept_threshold`, `local_margin_threshold`,
  `local_high_confidence_threshold`
- semantic cache opts: `semantic_lookup`, `semantic_cache`,
  `semantic_cache?`, `semantic_after_classifier?`
- embedding opts: `embedding`
- routing opts: `via`, `pipeline`, `arbitrator`, `terminal_labels`,
  `high_confidence_threshold`, `classification_log?`
- runtime opts: `conversation_id`, `state`, `memory`, `assigns`,
  `chat_history_limit`
- Kinetic/action planning opts: `runtime`, `encoder_model_dir`,
  `tool_threshold`, `mapping_threshold`, `tool_selection_fallback`,
  `fallback_top_k`, `fallback_margin`, `top_k`, `slots`, `classifiers`

## DSL Pieces

### `use Spectre.Agent`

```elixir
use Spectre.Agent,
  prompt_root: "priv/agents/support/prompts",
  history: 20,
  shutdown: :timer.minutes(10)
```

`prompt_root` tells Spectre where prompt templates live. If you do not set it,
Spectre uses `priv/spectre/prompts`.

`use Spectre.Agent` also accepts normal config keys. The built-in ones are:

- `:prompt_root`
- `:shutdown`
- `:history`
- `:fail`
- `:arbitrator`

Unknown keys are kept in `__spectre_config__/0`, so host applications can attach
their own metadata. `:arbitrator` is copied into router config; the other keys
stay in runtime config.

### `model`

```elixir
model(MyApp.LLM)
model(MyApp.LLM, with: :chat, temperature: 0)
```

By default Spectre calls `MyApp.LLM.complete(prompt, opts)`. Use `with:` or
`function:` if your adapter exposes a different function.

Minimal adapter:

```elixir
defmodule MyApp.LLM do
  def complete(prompt, opts) do
    MyApp.OpenAI.complete(prompt, opts)
  end
end
```

`model/2` stores `{module, function, opts}` under the runtime `:model` option.
Those opts are merged into every `ask` call. `fallback:` is special: if the
primary model returns `{:error, reason}`, Spectre calls the fallback model with
`primary_error: reason`.

The LLM classifier also uses the configured model. It builds a small prompt from
the current labels unless you pass `classifier_prompt: fun`, and it sends
`llm_opts` with defaults:

```elixir
[purpose: :classifier, temperature: 0.0, max_tokens: 8]
```

### Runtime Boundaries

These macros configure runtime adapters:

```elixir
state(MyApp.AgentStateStore)
memory(MyApp.AgentMemory)
embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

actions MyApp.SupportActions, namespace: :support do
  protect(:delete_account, with: :delete_account_confirmation)
end

shutdown(:timer.minutes(10))
idle(:timer.minutes(5))
history(50)
fail(:agent_failure_reply, locale: :en)
```

What they mean:

- `state/1` module may implement `load/3`, `load/2`, `persist/4`, or
  `persist/2`.
- `memory/1` module may implement `recall/2`, then `remember/4`, `persist/4`,
  `remember/2`, or `persist/2`.
- `embedding/2` provides the adapter used by embedding routing.
- `actions/2` stores `{module, opts}`. Those opts are also merged into
  SpectreKinetic planning opts and receive `actions_module: module`.
- `shutdown/1` and `idle/1` affect supervised sessions.
- `history/1` controls chat history stored under `state.data.chat_history`.
- `fail/2` configures monitor fallback prompt rendering.

Per-call options such as `state: %Spectre.State{}` or `memory: value` can bypass
adapters for tests or host-controlled replay.

### `flow` And `on`

`flow` groups related routes. `on` declares one route:

```elixir
flow :sales do
  on :QUOTE_REQUEST,
    regex: ~r/\b(quote|estimate|proposal)\b/i,
    embedding: ["can you estimate this project?", "send me a proposal"],
    train: "training/sales/quote_request.jsonl" do
    ask(:quote_request)
  end
end
```

A route can include:

- `regex:` one regex or a list of regexes
- `bag:` simple phrase examples for bag-distance routing
- `jaro:` phrase examples for Jaro string similarity
- `embedding:` semantic examples compared with vectors
- `train:` or `training:` examples or files used to build classifier datasets
- `check:` or `checks:` metadata guards such as language or role
- `via:` per-route strategy visibility
- custom options kept on the compiled rule

Routes are evaluated in this order:

1. interrupts
2. rules from the current flow, if `state.current_flow` is set
3. every other rule

Every router strategy also calls the same visibility helper: a rule with no
`via:` is visible to all strategies; a rule with `via: [:classifier]` is visible
only to classifier plugs. `check:` and `checks:` are applied before a strategy
can see the rule.

Checks read from `input.text` or `input.meta`:

```elixir
on :ITALIAN_INFO,
  regex: ~r/^info$/i,
  check: {:language, ["it", "italian"]} do
  reply(:platform_info_it)
end
```

Input plugs are the usual place to add that metadata.

### Handlers

Spectre has four route handlers:

```elixir
ask(:prompt_name)
reply(:prompt_name)
run(:local_function)
action(:dangerous_or_external_action)
```

`ask` renders a prompt, calls the model, strips Action Language from the visible
reply, and asks SpectreKinetic to plan staged actions if AL blocks exist.

`reply` renders a deterministic response without calling the model. This is good
for help, health checks, canned answers, and policy confirmations.

`run` calls a function on the agent module:

```elixir
def cancel_current(input, ctx), do: Spectre.cancel(input, ctx)
```

`action` stages an application action without calling the model:

```elixir
on :DELETE_ACCOUNT, regex: ~r/^delete my account$/i do
  action(:delete_account) do
    reply(:delete_confirmation_started)
  end
end
```

Handlers also accept options:

```elixir
on :PRICING, regex: ~r/\bprice\b/i do
  reply(:pricing, renderer: {MyApp.Replies, :route_reply}, key: :price)
end

on :SMART_TURN, training: true do
  ask(:smart_turn_prompt, temperature: 0.2)
end

on :CREATE_PROJECT, regex: ~r/\bstart project\b/i do
  action(:create_project, args: %{source: "chat"}) do
    reply(:project_policy_started, renderer: {MyApp.Replies, :route_reply})
  end
end
```

`reply` can render a prompt file, or use a renderer. Renderers may be
`{Module, :function}` or functions. Spectre supports arity 3
(`prompt, input, ctx`), arity 2 (`prompt, assigns`), and arity 1 (`assigns`).

`action` options become pending-action fields: `args`, `status`, `al`, and
`hooks`. If the action block includes `reply`, that reply is used for the policy
request path without calling the model.

### `interrupt`

Interrupts are global routes. They are checked before normal flow routes, so
commands like help, cancel, handoff, or stop work even when a conversation is in
the middle of a different flow.

```elixir
interrupt :CANCEL, regex: ~r/\b(cancel|stop|nevermind)\b/i do
  run(:cancel_current)
end
```

### `policy` And `protect`

Actions can be staged by deterministic DSL handlers or by Action Language in an
LLM reply. Either way, dangerous actions should not execute just because text
matched or a model emitted a tool instruction.

`protect` connects an action to a policy. In real agents, keep this next to the
action module with the block form:

```elixir
actions MyApp.SupportActions do
  protect(:delete_account, with: :delete_account_confirmation)
end
```

The policy is a tiny deterministic router that is used only while that action is
waiting:

```elixir
policy :delete_account_confirmation do
  request(:confirm_delete_account)
  accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
  reject(:cancel_delete, regex: ~r/^no|cancel$/i)
  otherwise(ask: :confirm_delete_account_retry)
  attempts(3, then: :cancel_pending)
end
```

While a policy is active, the next user turn bypasses the normal agent router.
That matters: a short answer like `"yes"` should approve the pending action, not
accidentally route to some generic conversation intent.

Approved actions still do not run automatically inside routing. Execution stays
behind:

```elixir
{:ok, executed} = Spectre.execute(result.state, %{agent: MyApp.SupportAgent})
```

That boundary is intentional. It gives the host application a clear place to
control transactions, permissions, audit logs, delivery, and retries.

### `actions` And Hooks

An action module is ordinary Elixir:

```elixir
defmodule MyApp.SupportActions do
  def delete_account(args, ctx) do
    MyApp.Accounts.delete_user(ctx.assigns.user_id, args)
  end
end
```

Declare it in the agent:

```elixir
actions MyApp.SupportActions do
  protect(:delete_account, with: :delete_account_confirmation)

  after_action(:delete_account,
    on: :delivered,
    run: {MyApp.AuditLog, :record_action}
  )
end
```

The bare form also exists for simple agents that only need to register an action
module:

```elixir
actions(MyApp.SupportActions)
```

Hooks run after an action result exists. They are useful for audit trails,
notifications, and delivery bookkeeping.

## Input Pipeline

The input pipeline runs before state loading, memory recall, policy matching,
routing, prompt rendering, and action execution. It receives a normalized
`%Spectre.Input{text, meta, raw}` and returns another `%Spectre.Input{}`.

Use it for things that should become true for the whole turn:

- trim/case/unicode normalization
- language detection
- tenant, channel, role, or locale enrichment
- mapping host payload fields into `input.meta`
- early rejection of malformed input

Block form:

```elixir
input_pipeline do
  plug(Spectre.Input.Plugs.NormalizeText,
    unicode: :nfc,
    case: :downcase,
    collapse_whitespace: true,
    trim: true
  )

  plug(MyApp.InputPlugs.Language)
  plug(MyApp.InputPlugs.AuthContext, required?: true)
end
```

List form:

```elixir
input_pipeline([
  {Spectre.Input.Plugs.NormalizeText, [case: :downcase]},
  MyApp.InputPlugs.Language
])
```

An input plug implements `Spectre.Input.Plug`:

```elixir
defmodule MyApp.InputPlugs.Language do
  @behaviour Spectre.Input.Plug

  def init(opts), do: opts

  def call(input, _context, _opts) do
    language = MyApp.Language.detect(input.text)
    {:cont, Spectre.Input.put_meta(input, :language, language)}
  end
end
```

Return values:

- `{:cont, input}` continues the pipeline
- `{:halt, input}` stops the pipeline and uses that input
- `{:error, reason}` stops the turn with an error

The built-in `Spectre.Input.Plugs.NormalizeText` supports:

- `:trim` default `true`
- `:collapse_whitespace` default `true`
- `:case` as `:downcase`, `:upcase`, or `nil`
- `:unicode` as `:nfc`, `:nfd`, `:nfkc`, `:nfkd`, `false`, or `nil`

## Prompt Files

With:

```elixir
use Spectre.Agent, prompt_root: "priv/agents/support/prompts"
```

`ask(:technical_support)` resolves:

```text
priv/agents/support/prompts/technical_support.text.heex
```

Policy prompts resolve under the policy name:

```text
priv/agents/support/prompts/policies/delete_account_confirmation/confirm_delete_account.text.heex
priv/agents/support/prompts/policies/delete_account_confirmation/confirm_delete_account_retry.text.heex
```

Prompt templates receive assigns:

```heex
User message:
<%= @input.text %>

Conversation state:
<%= inspect(@state.data) %>

Memory:
<%= inspect(@memory) %>
```

## Routing And Precedence

Spectre routing is evidence-first. Router plugs collect candidates, then an
arbitrator decides which candidate becomes the route.

The common configuration is `via:`:

```elixir
router(
  via: [:regex, :semantic_cache, :bag, :jaro, :embedding, :classifier, :llm_classifier]
)
```

`via:` expands into router plugs and appends arbitration and terminalization for
you. The mapping is:

- `:regex` -> `Spectre.Router.Plugs.Regex`
- `:bag` -> `Spectre.Router.Plugs.BagDistance`
- `:jaro` -> `Spectre.Router.Plugs.JaroDistance`
- `:embedding` -> `Spectre.Router.Plugs.EmbeddingSimilarity`
- `:semantic_cache` -> `SemanticCacheExact` and `SemanticCacheSearch`
- `:classifier` -> `Spectre.Router.Plugs.LocalClassifier`
- `:llm_classifier` -> no evidence plug; the arbitrator can ask it when needed
- `:arbitrate` -> `Spectre.Router.Plugs.Arbitrate`
- `:terminalize` -> `Spectre.Router.Plugs.Terminalize`

`Spectre.Router.Plugs.LLMFallback` also exists for legacy or fully custom
pipelines. It is not inserted by modern `via:` expansion; normally the default
arbitrator is the place that asks the LLM classifier. If you add the fallback
plug yourself, enable it with `llm_fallback?: true`.

If you set `pipeline:`, Spectre uses that pipeline instead of expanding `via:`.
That is the escape hatch for advanced agents:

```elixir
router(
  pipeline: [
    Spectre.Router.Plugs.Regex,
    {MyApp.Router.Plugs.BusinessHours, [timezone: "Europe/Rome"]},
    Spectre.Router.Plugs.LocalClassifier,
    Spectre.Router.Plugs.Arbitrate,
    Spectre.Router.Plugs.Terminalize
  ]
)
```

When you provide a custom `pipeline:`, include `Arbitrate` if you want collected
candidates to become a route, and include `Terminalize` if you want terminal
metadata. `via:` adds those automatically; `pipeline:` is explicit.

You can also package a custom router pipeline as a module:

```elixir
defmodule MyApp.RouterPipeline do
  use Spectre.Pipeline

  pipeline do
    plug(Spectre.Router.Plugs.Regex)
    plug(MyApp.Router.Plugs.BusinessHours, timezone: "Europe/Rome")
    plug(Spectre.Router.Plugs.LocalClassifier)
    plug(Spectre.Router.Plugs.Arbitrate)
    plug(Spectre.Router.Plugs.Terminalize)
  end
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent

  router(pipeline: MyApp.RouterPipeline)
end
```

Router plugs implement `Spectre.Router.Plug`:

```elixir
defmodule MyApp.Router.Plugs.BusinessHours do
  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context

  def init(opts), do: opts

  def call(%Context{} = context, opts) do
    if MyApp.Calendar.open?(opts[:timezone]) do
      {:cont, context}
    else
      route =
        Spectre.Route.new(
          label: :AFTER_HOURS,
          handler: {:reply, :after_hours, []},
          strategy: :business_hours,
          accepted?: true,
          raw: context.input.text,
          labels: context.labels
        )

      {:halt, Context.put_route(context, route)}
    end
  end
end
```

Return values:

- `{:cont, context}` continues the router pipeline
- `{:halt, context}` stops routing and marks the context halted
- `{:error, reason}` fails routing

Most custom router plugs should add candidates or metadata and continue.
Decision plugs should halt.

Built-in strategy names:

- `:regex` matches explicit DSL regexes.
- `:bag` scores simple phrase examples.
- `:jaro` scores string similarity examples.
- `:embedding` embeds the user text and route examples, then compares vectors.
- `:classifier` uses a local trained classifier artifact.
- `:semantic_cache` asks your semantic cache adapter for exact or search hits.
- `:llm_classifier` asks the model to choose from labels when configured.

Built-in plug mechanics:

- Regex checks visible regex rules in evaluation order and adds the first match
  as a candidate.
- Bag and Jaro score the best example per visible rule.
- Embedding embeds the user text and each route example, then uses cosine score
  and score margin.
- Semantic cache runs exact lookup early with `semantic_search?: false`, then
  broader search later with `semantic_search?: true`.
- Local classifier calls `classify`, `classifier`, or Spectre's own classifier
  artifact.
- Arbitrate turns candidates into a final route, LLM arbitration, clarification,
  or error.
- Terminalize adds `terminal?` and `escalation_reason` after a route exists.

Per-route `via:` limits which strategies can see a route:

```elixir
on :BILLING,
  regex: ~r/\b(invoice|billing)\b/i,
  embedding: ["question about an invoice"],
  via: [:regex, :embedding, :classifier] do
  ask(:billing)
end
```

The default arbitrator is conservative:

- hard/global evidence wins first
- agreement from multiple providers is strong
- confident classifier evidence can beat weak regex
- confident embedding evidence can route semantic phrasing
- bag and Jaro are useful for cheap approximate matching
- unresolved conflicts can fall back to LLM arbitration or clarification

Default thresholds include classifier acceptance, classifier margin, embedding
acceptance, embedding margin, bag acceptance, and Jaro acceptance. You can
replace the arbitrator if your product needs different behavior:

```elixir
arbitrator(MyApp.Router.Arbitrator, conflict: :best)
```

The important design point is that regex, embedding, classifier, and semantic
cache do not overwrite each other in secret. They produce evidence. The
arbitrator makes the final decision.

## Default Arbitrator

The default arbitrator lives in `Spectre.Router.Arbitrators.Default`. It receives
a `%Spectre.Router.Arbitration{}` with:

- the normalized input
- the current state
- the visible rules
- the visible labels
- the candidates collected by router plugs
- the full router context

Each candidate has a label, provider, score, margin, strength, handler, and the
rule that produced it. The default arbitrator first removes candidates that
cannot actually run a handler, then applies thresholds and sorts by strength,
provider rank, and score.

The default thresholds are:

```elixir
[
  classifier_accept: 0.93,
  classifier_margin: 0.08,
  embedding_accept: 0.84,
  embedding_margin: 0.05,
  bag_accept: 0.72,
  jaro_accept: 0.9,
  conflict: :llm,
  no_decision: :clarify
]
```

The decision order is:

1. Pick hard evidence first. Global interrupts are hard by default, so cancel,
   help, unsafe, spam, and similar commands can cut through normal routing.
2. If two or more providers agree on the same label, accept that agreement and
   keep the highest-scored candidate for that label.
3. Accept a confident local classifier candidate.
4. Accept a confident embedding candidate.
5. Accept a confident bag-distance candidate.
6. Accept a confident Jaro candidate.
7. If eligible candidates disagree and `conflict: :llm`, ask the LLM classifier
   to arbitrate among labels.
8. If there is still no decision and `no_decision: :clarify`, return a clarify
   route with `"Please rephrase your request."`.
9. Otherwise return `{:error, :no_route_candidate}`.

Provider rank only matters after eligibility. It is not a magic override; it is
how the default arbitrator sorts candidates once they have already cleared their
thresholds. The built-in rank is:

```elixir
llm_classifier > local_classifier > embedding > semantic_cache > bag/jaro > regex
```

That ordering is why a weak regex can be beaten by a strong classifier, while a
hard interrupt still wins immediately.

You can tune the default arbitrator without replacing it:

```elixir
router(
  via: [:regex, :embedding, :classifier, :llm_classifier],
  arbitrator:
    {Spectre.Router.Arbitrators.Default,
     [
       classifier_accept: 0.9,
       embedding_accept: 0.82,
       embedding_margin: 0.03,
       conflict: :llm,
       no_decision: :clarify
     ]}
)
```

You can also set rule strength when a route should carry more weight:

```elixir
on :LIST_MY_PROJECTS,
  bag: ["show my projects", "list my job posts"],
  strength: :strong,
  via: [:bag, :classifier, :llm_classifier] do
  action(:list_my_projects)
end
```

Strength can be general (`strength: :strong`) or provider-specific
(`regex_strength: :hard`, `embedding_strength: :medium`). Use this sparingly:
most routes should be decided by evidence quality, not manual force.

## Custom Arbitrator

If your product has different risk rules, replace the arbitrator instead of
rewriting router plugs.

```elixir
defmodule MyApp.Router.Arbitrator do
  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Candidate

  @impl Spectre.Router.Arbitrator
  def decide(arbitration, _opts) do
    candidates =
      Enum.filter(arbitration.candidates, fn candidate ->
        candidate.handler && candidate.accepted?
      end)

    cond do
      billing = Enum.find(candidates, &(&1.label == :BILLING_ESCALATION)) ->
        {:ok, Candidate.to_route(billing, arbitration.labels)}

      confident = Enum.find(candidates, &confident?/1) ->
        {:ok, Candidate.to_route(confident, arbitration.labels)}

      candidates != [] ->
        {:llm, %{arbitration | candidates: candidates}}

      true ->
        {:clarify, "Can you say that another way?"}
    end
  end

  defp confident?(%{provider: :local_classifier, score: score, margin: margin}) do
    is_number(score) and score >= 0.92 and is_number(margin) and margin >= 0.1
  end

  defp confident?(%{provider: :embedding, score: score}) do
    is_number(score) and score >= 0.88
  end

  defp confident?(_candidate), do: false
end
```

Then configure it in the agent:

```elixir
arbitrator(MyApp.Router.Arbitrator, product: :support)
```

or inside `router/1`:

```elixir
router(
  via: [:regex, :classifier, :embedding, :llm_classifier],
  arbitrator: {MyApp.Router.Arbitrator, [product: :support]}
)
```

An arbitrator may return:

- `{:ok, %Spectre.Route{}}` to accept a route
- `{:llm, arbitration}` to ask the LLM classifier to break a conflict
- `{:clarify, text}` to produce a clarification route
- `{:error, reason}` to fail routing

This keeps policy separate from evidence. Regex, embedding, semantic cache, and
classifier plugs explain what they found; the arbitrator decides what your
product trusts.

## Router Options And Adapters

Router opts are just keyword opts merged into the router context. The built-in
plugs look for a few well-known keys:

```elixir
router(
  via: [:regex, :semantic_cache, :classifier, :embedding, :llm_classifier],
  artifact_dir: "artifacts/spectre",
  semantic_cache: MyApp.SemanticCache,
  classifier: {MyApp.IntentClassifier, :classify},
  terminal_labels: [:PRICING, :SUPPORT],
  high_confidence_threshold: 0.9,
  classification_log?: true,
  semantic_after_classifier?: true
)
```

Important options:

- `:via` chooses built-in strategies and auto-appends arbitration/terminalize.
- `:pipeline` replaces `via` with an explicit plug list or pipeline module.
- `:arbitrator` sets `{Module, opts}` for final route selection.
- `:terminal_labels` or `:terminal_intents` marks labels that can end a flow.
- `:high_confidence_threshold` is used by terminalization.
- `:classification_log?` turns router/classifier logs on or off.
- `:llm_fallback?` enables the legacy `LLMFallback` plug if a custom pipeline
  uses it.
- `:semantic_cache?` disables semantic cache when false.
- `:semantic_after_classifier?` disables the later semantic-search pass when
  false.
- `:semantic_lookup` can be a function.
- `:semantic_cache` can be a module or `{module, function}`.
- `:classify` can be a function.
- `:classifier` can be a module or `{module, function}`.
- `:artifact_dir` points Spectre's local classifier to trained artifacts.
- `:classifier_prompt` customizes the LLM classifier prompt.
- `:llm_opts` are passed to the LLM classifier.
- `:recent_chat` is included in the default LLM classifier prompt.

Adapter shapes are intentionally simple:

```elixir
semantic_lookup = fn text, opts ->
  MyApp.SemanticCache.lookup(text, opts)
end

classify = fn text, opts ->
  MyApp.IntentClassifier.classify(text, opts)
end

Spectre.ask(MyApp.SupportAgent, "hello",
  semantic_lookup: semantic_lookup,
  classify: classify
)
```

Or use modules:

```elixir
defmodule MyApp.IntentClassifier do
  def classify(text, opts) do
    {:ok, %{label: :SUPPORT, accepted?: true, confidence: 0.95, margin: 0.2}}
  end
end

defmodule MyApp.SemanticCache do
  def lookup(text, opts) do
    {:error, :miss}
  end
end
```

Classifier and semantic-cache adapters should return route-like maps:

```elixir
%{
  label: :SUPPORT,
  accepted?: true,
  confidence: 0.95,
  margin: 0.2,
  strategy: :local_classifier
}
```

Spectre maps the returned label back onto a visible DSL rule. A good adapter
cannot route to labels that the current agent state, `via`, or `check` rules
hide.

## Embedding Routing

Embedding routing is useful when users say the right thing with different words.

```elixir
embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

flow :sales do
  on :PROJECT_PROPOSAL,
    regex: ~r/\b(proposal|quote|estimate)\b/i,
    embedding: [
      "scope an MVP build",
      "estimate a marketplace launch",
      "prepare a project proposal"
    ],
    via: [:regex, :embedding] do
    ask(:project_proposal)
  end
end
```

Adapter example:

```elixir
defmodule MyApp.Embeddings do
  @behaviour Spectre.Classifier.Embedding

  def load(model, opts), do: Spectre.Classifier.Embeddings.ExFastembed.load(model, opts)
  def embed(text, opts), do: Spectre.Classifier.Embeddings.ExFastembed.embed(text, opts)
end
```

For tests, use a deterministic adapter instead of loading a real model. The
router only needs `embed/2` to return stable vectors.

## Semantic Search And Cache

Semantic cache is an adapter boundary. Spectre does not force a vector database,
embedding model, table shape, or cache strategy.

Configure one of:

```elixir
router(
  via: [:regex, :semantic_cache, :classifier],
  semantic_lookup: &MyApp.SemanticCache.lookup/2
)

# or
router(
  via: [:semantic_cache],
  semantic_cache: MyApp.SemanticCache
)

# or
router(
  via: [:semantic_cache],
  semantic_cache: {MyApp.SemanticCache, :lookup}
)
```

The adapter receives the text and opts:

```elixir
defmodule MyApp.SemanticCache do
  def lookup(text, opts) do
    if Keyword.get(opts, :semantic_search?) do
      search_similar(text, opts)
    else
      exact_lookup(text, opts)
    end
  end

  defp exact_lookup(text, _opts) do
    case MyApp.Cache.get(text) do
      nil -> {:error, :miss}
      route -> {:ok, route}
    end
  end

  defp search_similar(text, _opts) do
    case MyApp.VectorStore.search(text, top_k: 3) do
      %{label: label, score: score} when score > 0.88 ->
        {:ok, %{label: label, accepted?: true, confidence: score, strategy: :semantic_cache_search}}

      _ ->
        {:error, :miss}
    end
  end
end
```

There are two semantic-cache moments:

1. Exact lookup runs early, before classifier fallback. A trusted hot cache hit
   is cheap and stable.
2. Semantic search runs later, after local classifier evidence. That lets a
   broad vector search use classifier context without hiding deterministic or
   high-confidence local evidence.

Return a route-like map:

```elixir
%{
  label: :TECHNICAL_SUPPORT,
  accepted?: true,
  confidence: 0.91,
  strategy: :semantic_cache_search
}
```

Spectre maps the label back to the agent rule. If the label is not routeable for
the current rule set, the hit is ignored and traced.

## Training And Datasets

Training examples should live near the DSL because route labels and training
labels need to stay aligned.

You can put examples directly in routes:

```elixir
on :PRICING,
  train: [
    "how much does it cost?",
    "what are your plans?",
    "pricing for a team"
  ] do
  reply(:pricing)
end
```

Or point to files:

```elixir
on :PRICING, train: "training/support/pricing.jsonl" do
  reply(:pricing)
end
```

Or use `training: true` and provide source datasets when exporting:

```elixir
on :TECHNICAL_SUPPORT, training: true do
  ask(:technical_support)
end
```

Dataset files can be:

- `.json` list of objects
- `.jsonl` one object per line
- plain text, one example per non-empty non-comment line

Rows can use either `label` or `intent`:

```json
[
  {"text": "how much does it cost?", "label": "PRICING"},
  {"text": "my API key is failing", "intent": "TECHNICAL_SUPPORT"}
]
```

Export rows from an agent:

```bash
mix spectre.classifier.dataset MyApp.SupportAgent \
  training/support/dataset.json \
  --source training/raw/support.jsonl
```

Train a local classifier artifact:

```bash
mix spectre.classifier.download_model --model intfloat/multilingual-e5-small
mix spectre.classifier.train training/support/dataset.json priv/spectre/support
```

Configure the classifier:

```elixir
config :spectre, :classifier,
  artifact_dir: "priv/spectre/support",
  encoder_model: "intfloat/multilingual-e5-small",
  embedding_adapter: Spectre.Classifier.Embeddings.ExFastembed
```

Classifier artifacts use compact centroids by default. At runtime, Spectre
indexes centroids with Vettore, so only one vector per label is mirrored into
the native index.

For larger datasets, nearest-example routing can be worth the extra memory:

```elixir
config :spectre, :classifier,
  local_classifier_mode: :examples,
  local_classifier_index: :hnsw,
  local_classifier_index_options: [ef_search: 64],
  local_example_score: :max
```

Use `:mean` for `local_example_score` if you prefer averaging returned hits per
label.

## What You Need To Provide

Spectre gives you the runtime and DSL. A real app usually provides:

- an LLM adapter with `complete/2` or a configured function
- prompt templates under `prompt_root`
- action modules for side effects
- policies for dangerous actions
- optional state adapter for durable conversation state
- optional memory adapter for recalled context
- optional embedding adapter for embedding routes and classifier training
- optional semantic cache adapter
- optional classifier dataset and trained artifact
- optional SpectreKinetic tool definitions for Action Language planning

That split is deliberate. Spectre should not know your billing rules, user
permissions, vector database, audit requirements, or model vendor.

## SpectreKinetic Integration

Spectre works very well today with `spectre_kinetic`.

When an `ask` handler receives an LLM reply, Spectre scans visible text and AL
blocks through SpectreKinetic if it is loaded. For example, a model might return:

```text
I can create that project brief.

<al>
CREATE PROJECT title="Marketplace MVP"
</al>
```

Spectre keeps the visible text for the user and delegates the AL block to
Kinetic for tool selection, slot mapping, and planning. The result is a
`%Spectre.PendingAction{}`. If the action is protected, Spectre starts the
policy flow before anything executes.

Your action module can be a Kinetic tool module:

```elixir
defmodule MyApp.ProjectActions do
  use SpectreKinetic

  @al "CREATE PROJECT title=<title>"
  def create_project(%{"title" => title}, ctx) do
    MyApp.Projects.create(ctx.assigns.user_id, %{title: title})
  end
end
```

Then wire it into Spectre:

```elixir
defmodule MyApp.ProjectAgent do
  use Spectre.Agent, prompt_root: "priv/agents/project/prompts"

  model(MyApp.LLM)

  actions MyApp.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)
    accept(:accepted_terms, regex: ~r/^yes$/i)
    reject(:rejected_terms, regex: ~r/^no$/i)
  end

  flow :project do
    on :CREATE_PROJECT, regex: ~r/\b(create|start).*\bproject\b/i do
      ask(:create_project)
    end
  end
end
```

Kinetic can load runtime data from:

- `:spectre_kinetic_runtime` application config
- `:spectre_kinetic, :compiled_registry`
- `:spectre_kinetic, :registry_json`
- `SPECTRE_KINETIC_COMPILED_REGISTRY`
- `SPECTRE_KINETIC_REGISTRY_JSON`
- extracted tools from the configured `actions` module

Spectre does not maintain a second AL parser. Kinetic owns AL extraction, tool
registration, registry loading, planning, slot mapping, and planning
classifiers. Spectre owns conversation routing, policy gates, state, and action
execution boundaries.

## State, Memory, And Sessions

For a single long-lived session:

```elixir
children = [
  {Spectre.Session,
   agent: MyApp.SupportAgent,
   name: MyApp.SupportSession,
   shutdown: :timer.minutes(10)}
]
```

For many conversation-scoped sessions:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]

{:ok, pid} =
  Spectre.summon(
    MyApp.SpectreSupervisor,
    MyApp.SupportAgent,
    conversation_id: conversation.id,
    idle: :timer.minutes(10)
  )
```

State adapter:

```elixir
defmodule MyApp.AgentStateStore do
  def load(_input, _agent, opts) do
    MyApp.Conversations.load_spectre_state(Keyword.fetch!(opts, :conversation_id))
  end

  def persist(state, _input, _agent, _opts) do
    MyApp.Conversations.save_spectre_state(state.conversation_id, state)
  end
end
```

Memory adapter:

```elixir
defmodule MyApp.AgentMemory do
  def recall(cue, opts) do
    SpectreMnemonic.recall(cue, scope: {:conversation, opts[:state].conversation_id})
  end

  def remember(turn, opts) do
    SpectreMnemonic.remember(turn,
      scope: {:conversation, opts[:state].conversation_id},
      persist?: true
    )
  end
end
```

Every successful turn records a compact chat entry in
`state.data[:chat_history]` before persistence. Use `history false` in the DSL
or pass `chat_history_limit: false` to disable it.

## Public API

- `Spectre.ask/3` sends a turn to an agent module or session.
- `Spectre.summon/1` starts one session directly.
- `Spectre.summon/3` starts one session under `Spectre.Supervisor`.
- `Spectre.dismiss/2` stops a supervised session.
- `Spectre.state/1` reads session state.
- `Spectre.reset/2` replaces session state.
- `Spectre.cancel/2` cancels the active policy or pending action.
- `Spectre.execute/3` executes the approved pending action.
- `Spectre.after_action/5` runs configured lifecycle hooks.

Compatibility aliases such as `handle/3`, `call/3`, `start_session/1`,
`start_session/3`, `cancel_current/2`, and `execute_pending/3` remain available.

## Installation

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```

For local classifier embeddings:

```elixir
def deps do
  [
    {:ex_fastembed, github: "elchemista/ex_fastembed", branch: "master"}
  ]
end
```

## Roadmap

Spectre is meant to sit in a small family of focused packages.

Works well today:

- `spectre_kinetic` integrates cleanly as the Action Language and tool-planning
  layer. Spectre delegates AL extraction and planning to Kinetic, receives
  staged pending actions, then applies policies and execution boundaries.

Future integration work:

- `spectre_lens` should become easier to plug into action modules and agent
  tools for browsing the web.
- `spectre_mnemonic` should become a smoother first-class memory adapter for
  recall, turn persistence, and long-running conversation context.
- `spectre_directive` should integrate above Spectre for mission-level
  orchestration: multi-step goals, delegated agents, and longer-running
  workflows.

The direction is not to make Spectre a giant framework. The direction is to keep
each package responsible for one layer, with clean Elixir boundaries between
them.
