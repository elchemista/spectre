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

> This is still work in progress and I don't even know if i will keep it public.
> I integrated this library in different products and shaping it base on feedback
> and on what is really useful in real world.

## Documentation

- [Getting Started](https://github.com/elchemista/spectre/blob/main/docs/GETTING_STARTED.md) - a small agent, turn lifecycle, runtime options, and what host apps provide.
- [DSL](https://github.com/elchemista/spectre/blob/main/docs/DSL.md) - agent macros, flows, handlers, policies, actions, input pipeline, and prompts.
- [Routing](https://github.com/elchemista/spectre/blob/main/docs/ROUTING.md) - router strategies, precedence, arbitrators, embeddings, and semantic cache.
- [Training](https://github.com/elchemista/spectre/blob/main/docs/TRAINING.md) - datasets, classifier export, and local classifier artifacts.
- [Actions](https://github.com/elchemista/spectre/blob/main/docs/ACTIONS.md) - policies, protected actions, hooks, SpectreKinetic, and Action Language planning.
- [Memory](https://github.com/elchemista/spectre/blob/main/docs/MEMORY.md) - state adapters, memory adapters, and supervised sessions.
- [Public API](https://github.com/elchemista/spectre/blob/main/docs/API.md) - main runtime entry points.
- [Installation](https://github.com/elchemista/spectre/blob/main/docs/INSTALLATION.md) - dependencies and optional local classifier embeddings.
- [Roadmap](https://github.com/elchemista/spectre/blob/main/docs/ROADMAP.md) - package direction and future integration work.

## Tiny Example

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM, purpose: :smart)
  classifier(MyApp.SmallLLM, model: "small")
  embedding(MyApp.Embeddings, model: "intfloat/multilingual-e5-small")

  router(via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier])

  actions MyApp.SupportActions do
    protect(:delete_account, with: :delete_account_confirmation)
  end

  policy :delete_account_confirmation do
    request(:confirm_delete_account)
    accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
    reject(:cancel_delete, regex: ~r/^no|cancel$/i)
    otherwise(ask: :confirm_delete_account_retry)
  end

  flow :support do
    on :PRICING,
      regex: ~r/\b(price|pricing|cost)\b/i,
      embedding: ["how much does it cost?", "pricing plans"],
      learn: true do
      reply(:pricing)
    end

    on :DELETE_ACCOUNT,
      cache: false,
      learn: false do
      action(:delete_account)
    end
  end
end
```

Send a turn:

```elixir
{:ok, result} = Spectre.ask(MyApp.SupportAgent, "How much does it cost?", conversation_id: "chat-123")
```

Start with [Getting Started](https://github.com/elchemista/spectre/blob/main/docs/GETTING_STARTED.md) for the full example and runtime flow.
