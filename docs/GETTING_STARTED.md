# Getting Started

This is the kind of module Spectre is designed to make easy:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM,
    purpose: :smart,
    fallback: MyApp.FallbackLLM
  )

  classifier(MyApp.SmallLLM,
    model: "small",
    artifact_dir: "priv/spectre/support"
  )

  embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

  router(
    via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier],
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
      train: true
    )

    reject(:cancel_delete,
      regex: ~r/^no|cancel$/i,
      train: true
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
      train: true,
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

Runtime does not re-evaluate DSL blocks. It reads that
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

- model opts: `model`, `adapter`, `fallback`, `recent_chat`
- classifier opts: `classifier`, `classify`, `classifier_local`, `artifact_dir`,
  `local_accept_threshold`, `local_margin_threshold`,
  `local_high_confidence_threshold`
- semantic cache opts: `semantic_lookup`, `semantic_cache`,
  `semantic_cache?`, `semantic_after_classifier?`,
  `semantic_cache_threshold`, `semantic_cache_top_k`,
  `semantic_cache_capacity`
- embedding opts: `embedding`
- routing opts: `via`, `pipeline`, `arbitrator`, `terminal_labels`,
  `high_confidence_threshold`, `classification_log?`
- runtime opts: `conversation_id`, `state`, `memory`, `assigns`,
  `chat_history_limit`
- Kinetic/action planning opts: `runtime`, `encoder_model_dir`,
  `tool_threshold`, `mapping_threshold`, `tool_selection_fallback`,
  `fallback_top_k`, `fallback_margin`, `top_k`, `slots`, `classifiers`


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
