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
`primary_error: reason`.

The LLM classifier also uses the configured model. It builds a small prompt from
the current labels unless you pass `classifier_prompt: fun`, and it sends
`llm_opts` with defaults:

```elixir
[purpose: :classifier, temperature: 0.0, max_tokens: 8]
```

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
- `actions/2` stores `{module, opts}`. Those opts are also merged into
  SpectreKinetic planning opts and receive `actions_module: module`.
- `shutdown/1` and `idle/1` affect supervised sessions.
- `history/1` controls chat history stored under `state.data.chat_history`.
- `fail/2` configures monitor fallback prompt rendering.

Per-call options such as `state: %Spectre.State{}` or `memory: value` can bypass
adapters for tests or host-controlled replay.

## `flow` And `on`

`flow` groups related routes. `on` declares one route:

```elixir
flow :sales do
  on :QUOTE_REQUEST,
    regex: ~r/\b(quote|estimate|proposal)\b/i,
    embedding: ["can you estimate this project?", "send me a proposal"],
    train: true do
    ask(:quote_request)
  end
end
```

A route can include:

- `regex:` one regex or a list of regexes
- `bag:` simple phrase examples for bag-distance routing
- `jaro:` phrase examples for Jaro string similarity
- `embedding:` semantic examples compared with vectors
- `train: true` marks routes or policy branches for classifier dataset use
- `learn: true` to mirror the route's training examples into the built-in
  learned semantic cache
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

on :SMART_TURN, train: true do
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
