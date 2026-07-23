# DSL

## `use Spectre.Agent`

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
- `:journal`
- `:turn_handlers`

Unknown keys are kept in `__spectre_config__/0`, so host applications can attach
their own metadata. `:arbitrator` is copied into router config; the other keys
stay in runtime config.

## `model`

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
`primary_error: reason`. `llm_timeout:` controls Spectre's isolated completion
deadline and defaults to 60 seconds.

## `classifier`

```elixir
# Main model: used for normal `ask/2` responses.
model(MyApp.MainLLM, model: "large")

# Classifier model: used only when `:llm_classifier` arbitrates routing.
classifier MyApp.SmallLLM,
  model: "small",
  fallback: MyApp.SmallFallbackLLM,
  prompt: &MyApp.ClassifierPrompt.build/1,
  llm_opts: [temperature: 0.0, max_tokens: 8, llm_timeout: 12_000],

  # Optional local classifier used by the `:classifier` router strategy.
  local: MyApp.LocalClassifier,
  artifact_dir: "priv/spectre/support",
  local_classifier_timeout: 2_000
```

The first argument configures the LLM adapter used only by `:llm_classifier`
arbitration. If it is not configured, the LLM classifier falls back to
`model/2`. `prompt:` customizes the classifier prompt, and `llm_opts:` are
merged with these defaults:

```elixir
[purpose: :classifier, temperature: 0.0, max_tokens: 8]
```

`local:` configures the adapter used by the `:classifier` router strategy.
Local classifier runtime overrides use `classifier_local:`.
`local_classifier_timeout:` controls the local adapter deadline.

The built-in arbitrator uses an enabled `:llm_classifier` after local and other
cheap evidence cannot make a decision. A custom `prompt:` callback receives at
least `text`, `labels`, `recent_chat`, and structured `evidence`; router calls
also add `input`, `state`, `candidates`, and `local_result` assigns. The model
must return exactly one configured label.

Timeouts, crashes, and malformed provider replies use the shared
`Spectre.Provider.Failure` contract. See [Provider Resilience](PROVIDERS.md).

## `journal`

```elixir
journal MyApp.SpectreJournal,
  events: [:routing],
  mode: :async,
  on_error: :warn,
  include_input: false,
  sample_rate: 1.0,
  buffer_size: 1_000,
  overflow: :drop_newest
```

`journal/2` stores an opt-in `{Store, opts}` configuration. The store implements
`c:Spectre.Journal.Store.append/2`. Routing records exclude input and reply
content by default and are delivered through a supervised bounded buffer.

Use `journal(false)` to disable an application-level default. Use
`mode: :sync, on_error: :error` only when an append must succeed before the
turn continues. See [Journal](JOURNAL.md) for the record schema, privacy model,
sampling, and delivery semantics.

## Runtime Boundaries

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
- `classifier/2` provides classifier-specific LLM and local adapters.
- `journal/2` configures structured decision recording.
- `turn_handler/2` appends an optional owner of a complete normal turn.
- `actions/2` stores `{module, opts}`. Those opts are also merged into
  SpectreKinetic planning opts and receive `actions_module: module`.
- `shutdown/1` and `idle/1` affect supervised sessions.
- `history/1` controls chat history stored under `state.data.chat_history`.
- `fail/2` configures monitor fallback prompt rendering.

Per-call options such as `state: %Spectre.State{}` or `memory: value` can bypass
adapters for tests or host-controlled replay.

## `turn_handler` and `turn_handlers`

```elixir
turn_handler MyApp.ActiveWorkflow, namespace: :support

turn_handlers [
  {MyApp.ActiveWorkflow, namespace: :support}
]
```

Handlers execute in declaration order after any already-open policy and before
routing. Each implements `Spectre.Turn.Handler` and returns `:cont` or
`{:reply, %Spectre.Turn.Handler.Reply{}}`. The first reply owns the turn.
Failures and timeouts stop the turn rather than allowing another route to
reinterpret the input.

`turn_handlers/1` replaces the full list. Pass `false` to disable it in an
Agent or in trusted per-call options. Skills cannot configure this Agent-wide
infrastructure. A handler is a pre-route ownership hook, not the canonical
host result or a protocol envelope. Use the narrower input, memory, Skill,
action, journal, or transport boundary when an integration does not own the
complete turn. See [Turn semantics and integration boundaries](INTEGRATIONS.md).

## `flow` And `on`

`flow` groups related routes. `on` declares one route:

```elixir
flow :sales do
  on :QUOTE_REQUEST,
    regex: ~r/\b(quote|estimate|proposal)\b/i,
    embedding: ["can you estimate this project?", "send me a proposal"],
    learn: true do
    ask(:quote_request)
  end
end
```

A route can include:

- `regex:` one regex or a list of regexes
- `bag:` simple phrase examples for bag-distance routing
- `jaro:` phrase examples for Jaro string similarity
- `embedding:` semantic examples compared with vectors
- `cache: false` excludes this route from semantic-cache rows and lookup
- `learn: true` lets accepted LLM fallback classifications add online examples
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

## Handlers

Spectre has four route handlers:

```elixir
ask(:prompt_name)
reply(:prompt_name)
run(:local_function)
action(:dangerous_or_external_action)
```

`ask` renders a prompt, calls the model, strips Action Language from the visible
reply, and asks SpectreKinetic to plan staged action effects if AL blocks exist.

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

on :SMART_TURN, learn: true do
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

## `interrupt`

Interrupts are global routes. They are checked before normal flow routes, so
commands like help, cancel, handoff, or stop work even when a conversation is in
the middle of a different flow.

```elixir
interrupt :CANCEL, regex: ~r/\b(cancel|stop|nevermind)\b/i do
  run(:cancel_current)
end
```

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
