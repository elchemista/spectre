# Spectre

Spectre is an OTP-native conversational runtime for Elixir agents.

It gives an agent a small, explicit surface:

- `flow` groups conversational routes.
- `on` matches a user turn and chooses a handler.
- `ask` renders a prompt, calls the LLM, asks SpectreKinetic to extract/plan Action Language, and stages planned actions.
- `run` calls Elixir code.
- `policy` gates pending actions.
- `protect` connects an action to a policy, independent of the prompt that produced it.
- `interrupt` matches globally before normal flow routing.

Spectre intentionally does not execute planned actions magically. `ask` can plan
an action, and a policy can approve it, but the execution boundary stays inside
`Spectre.execute/3`.

## Public API

- `Spectre.ask/3` sends a turn to an agent module or a supervised session.
- `Spectre.summon/1` starts one session directly.
- `Spectre.summon/3` starts one session under `Spectre.Supervisor`.
- `Spectre.dismiss/2` stops a supervised session.
- `Spectre.state/1` reads a session's in-memory `%Spectre.State{}`.
- `Spectre.reset/2` replaces a session's in-memory state.
- `Spectre.cancel/2` cancels the current pending action/policy.
- `Spectre.execute/3` executes the approved pending action.

Compatibility aliases such as `handle/3`, `call/3`, `start_session/1`,
`start_session/3`, `cancel_current/2`, and `execute_pending/3` remain available.

## Agent DSL

```elixir
defmodule MyApp.Agents.ProjectAgent do
  use Spectre.Agent,
    prompt_root: "priv/agents/project_agent/prompts"

  complete MyApp.LLM
  actions MyApp.ProjectActions
  state MyApp.AgentStateStore
  memory MyApp.AgentMemory
  shutdown :timer.minutes(10)

  router via: [:regex, :semantic_cache, :classifier, :llm],
         artifact_dir: "priv/spectre/project_agent"

  protect :create_project, with: :terms

  policy :terms do
    request :accept_terms

    accept :accepted_terms,
      regex: ~r/^\s*accetto\s*$/i,
      train: "training/policies/terms/accept.jsonl"

    reject :rejected_terms,
      regex: ~r/^\s*(non accetto|rifiuto|no)\b/i,
      train: "training/policies/terms/reject.jsonl"

    otherwise ask: :accept_terms_retry
    attempts 3, then: :cancel_pending
  end

  flow :project_create do
    on :wants_project_create,
      regex: ~r/\b(crea|creare|nuovo)\b.*\b(progetto|project)\b/i,
      train: "training/project_create/wants_project_create.jsonl" do
      ask :project_create
    end
  end

  interrupt :cancel,
    regex: ~r/\b(annulla|ferma|stop)\b/i,
    train: "training/shared/cancel.jsonl" do
    run :cancel_current
  end

  def cancel_current(input, ctx) do
    Spectre.cancel(input, ctx)
  end
end
```

## Prompt Resolution

With:

```elixir
use Spectre.Agent, prompt_root: "priv/agents/project_agent/prompts"
```

`ask :project_create` resolves:

```text
priv/agents/project_agent/prompts/project_create.text.heex
```

Policy prompts resolve under the policy name:

```text
priv/agents/project_agent/prompts/policies/terms/accept_terms.text.heex
priv/agents/project_agent/prompts/policies/terms/accept_terms_retry.text.heex
```

Templates can use HEEx-style assigns such as:

```heex
Messaggio utente:
<%= @input.text %>

Stato corrente:
<%= inspect(@state) %>
```

## Runtime

```elixir
{:ok, result} =
  Spectre.ask(MyApp.Agents.ProjectAgent, "crea nuovo progetto",
    conversation_id: "chat-1"
  )
```

`complete MyApp.LLM` calls `MyApp.LLM.complete/2`. You can also use
`complete MyApp.LLM, function: :chat` or override per call with `complete: fun`
when needed.

If the LLM reply contains:

```text
Perfetto, preparo il progetto.

<al>
CREATE PROJECT title="ciao"
</al>
```

Spectre delegates extraction and planning to `SpectreKinetic.extract_al_scan/1`
and `SpectreKinetic.plan_chain/3`. It returns the visible text from Kinetic's
scan and stages the planned actions. If an action is protected, Spectre starts
the configured policy and stores `%Spectre.Awaiting{kind: :policy}` in state.
While a policy is active, the next turn bypasses normal routing and is matched
only against the policy.

Spectre does not ship a second AL parser. Your action modules should use
`use SpectreKinetic` and `@al` annotations so Kinetic owns tool registration,
AL extraction, registry loading, planning, slot mapping, and classifier results.

## Router Pipeline

The `router via:` declaration controls the optimized routing pipeline:

```elixir
router via: [:regex, :semantic_cache, :classifier, :llm],
       semantic_lookup: &MyApp.SemanticCache.lookup/2,
       classify: &MyApp.IntentClassifier.classify/2,
       llm_fallback?: true
```

The built-in plugs are:

- `:regex` - deterministic DSL rule matching.
- `:semantic_cache` - exact hot cache lookup, then post-classifier semantic search.
- `:classifier` - local classifier adapter.
- `:llm` - one-label LLM fallback adapter.

Semantic cache and classifier are adapter boundaries. Spectre does not force a
specific vector store or encoder. Provide `semantic_lookup`, `semantic_cache`,
`classify`, or `classifier` options from your app. If no classifier adapter is
provided, `:classifier` uses Spectre's own local classifier artifact.

## Classifier Artifacts

Spectre includes a small centroid classifier path for optimized local routing.
It mirrors the example app flow: download/load the encoder model, train a local
artifact from JSON data, then let the router use that artifact before falling
back to semantic search or the LLM.

```bash
mix spectre.classifier.download_model --model intfloat/multilingual-e5-small
mix spectre.classifier.train training/dataset.json artifacts/spectre
```

Training rows can use either `label` or `intent`:

```json
[
  {"text": "crea un nuovo progetto", "label": "wants_project_create"},
  {"text": "annulla tutto", "intent": "cancel"}
]
```

Configure the runtime once if you do not want to pass `artifact_dir` in every
router declaration:

```elixir
config :spectre, :classifier,
  artifact_dir: "artifacts/spectre",
  encoder_model: "intfloat/multilingual-e5-small",
  embedding_adapter: Spectre.Classifier.Embeddings.ExFastembed
```

Classifier artifacts use compact centroids by default. At runtime, Spectre
indexes those centroids with Vettore, so only one vector per label is mirrored
into the native search resource.

For larger datasets where nearest-example routing is worth the extra memory,
you can opt into example indexing:

```elixir
config :spectre, :classifier,
  local_classifier_mode: :examples,
  local_classifier_index: :hnsw,
  local_classifier_index_options: [ef_search: 64]
```

Example indexing stores training examples in ETS and mirrors their ids/vectors
inside Vettore's native index. Labels are scored from nearest examples with
`local_example_score: :max` by default; use `:mean` to average the returned hits
per label. Older centroid artifacts still load as a fallback.

`Spectre.Classifier.Encoder` is an adapter boundary. The default adapter uses
the optional `:ex_fastembed` dependency, matching the example app:

```elixir
{:ex_fastembed, github: "elchemista/ex_fastembed", branch: "master"}
```

You can plug your own embedding service instead:

```elixir
defmodule MyApp.Embeddings do
  @behaviour Spectre.Classifier.Embedding

  def load(_model, _opts), do: {:ok, 384}

  def embed(text, _opts) do
    MyApp.EmbeddingClient.embed(text)
  end
end

config :spectre, :classifier,
  embedding_adapter: MyApp.Embeddings,
  encoder_model: "my-model"
```

For small cases you can pass functions directly:

```elixir
router via: [:regex, :classifier, :llm],
       embed: &MyApp.EmbeddingClient.embed/2,
       load_embedding: &MyApp.EmbeddingClient.load/2
```

## Supervision

For a single long-lived agent session, supervise `Spectre.Session` directly:

```elixir
children = [
  {Spectre.Session,
   agent: MyApp.Agents.ProjectAgent,
   name: MyApp.ProjectAgentSession,
   shutdown: :timer.minutes(10)}
]
```

Then send turns through the process:

```elixir
{:ok, result} = Spectre.ask(MyApp.ProjectAgentSession, "crea nuovo progetto")
```

For many conversation-scoped sessions, supervise `Spectre.Supervisor`:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

Start one session per conversation:

```elixir
{:ok, pid} =
  Spectre.summon(
    MyApp.SpectreSupervisor,
    MyApp.Agents.ProjectAgent,
    conversation_id: conversation.id,
    idle: :timer.minutes(10)
  )

{:ok, result} = Spectre.ask(pid, "accetto")
```

The session process keeps the latest `%Spectre.State{}` in memory between turns
and stops normally after `idle:` or `shutdown:` milliseconds of inactivity. On
start, if no explicit state is passed, `Spectre.Session` asks the configured
state adapter to restore the previous state for the conversation.

## State And Memory

State adapters can restore and persist durable conversation state:

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

Every successful turn records a compact chat entry in
`state.data[:chat_history]` before persistence. Set `history false` in the DSL
or pass `chat_history_limit: false` to disable it; pass an integer limit to keep
only the last N turns.

Memory adapters can recall context before prompt rendering and remember the
completed turn afterward:

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

## Integrations

Spectre keeps sibling packages optional:

- `spectre_kinetic` owns Action Language extraction, tool registration, registry loading, planning, slot mapping, and planning classifiers.
- `spectre_mnemonic` can serve as a memory adapter through `memory MyMemory`.
- `spectre_lens` can be used by action modules or higher-level agent tools.
- `spectre_directive` can orchestrate missions above the conversational runtime.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `spectre` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:spectre, "~> 0.1.0"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```
