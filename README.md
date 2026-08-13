# Spectre

[![CI](https://github.com/elchemista/spectre/actions/workflows/ci.yml/badge.svg)](https://github.com/elchemista/spectre/actions/workflows/ci.yml)
[![Hex](https://img.shields.io/hexpm/v/spectre.svg)](https://hex.pm/packages/spectre)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/spectre/0.3.1)

**An OTP-native Elixir runtime for building agents whose routing, state,
policies, and side effects stay explicit.**

Spectre treats an agent the way OTP treats a system: a supervised set of
processes with one canonical owner for every piece of state, explicit messages
at every boundary, and recovery designed in from the start. If you know
GenServer, supervision trees, and "let it crash", you already have the mental
model - Spectre applies it to conversations, model calls, and tool execution.

A Spectre agent should read like a map, not a magic trick.

## Philosophy

Three ideas define Spectre. Everything else in the library is a consequence of
them.

### 1. The model proposes. It never executes.

Every side effect crosses a fixed safety boundary:

- models and routes may **propose** work;
- protected work must pass a **deterministic policy**;
- **approval changes state** — it does not run anything;
- **execution happens only through an explicit host call**;
- every outcome is returned as plain data.

No model output can skip a policy, invent a route, or trigger a side effect on
its own. Your application keeps owning business rules, permissions, storage,
and the actual operations. The whole lifecycle at a glance:

```text
input
  -> normalize
  -> restore state and memory
  -> resolve an open policy, or route the turn
  -> run handler
       -> reply / no response
       -> stage effect
            -> unprotected: pending -> execute -> completed / failed
            -> protected: waiting_policy
                 -> accepted -> approved -> execute -> completed / failed
                 -> rejected / attempts exceeded -> cancelled
```

### 2. Routing is a dial, not a dogma.

The lifecycle around a decision is always deterministic. How the agent
*decides* — which route handles this input — is exactly as deterministic as
you configure it to be:

```elixir
router(via: [:regex])                                # fully deterministic
router(via: [:regex, :embedding, :classifier])       # hybrid: patterns win, semantics cover paraphrases
router(via: [:regex, :embedding, :classifier,
             :semantic_cache, :llm_classifier])      # model-in-the-loop
```

With `:llm_classifier` in the chain, routing is genuinely model-driven — but
only between routes the agent declares, only after cheaper evidence was not
decisive, and always inside the same deterministic lifecycle. A refunds bot can
run pure regex; an open-ended assistant can lean on the LLM; both get the same
guarantees. See [Routing](docs/ROUTING.md).

### 3. Everything durable is data — and data never becomes code.

Agents compile to canonical, content-addressed **Definitions**. Runtime-authored
behavior (skills, work programs, change proposals) is portable data that can
only reference operations the host already registered — never callbacks, never
executable templates. An agent can even propose changes to *itself*, but only
through the same governance every change passes: evaluation, review, explicit
approval, activation, and rollback. See [Governance](docs/GOVERNANCE.md) and
the [Reflective Runtime](docs/REFLECTIVE_RUNTIME.md).

## Installation

```elixir
def deps do
  [
    {:spectre, "~> 0.3.1"}
  ]
end
```

See [Installation](docs/INSTALLATION.md) for release verification, snapshot
pinning, and the optional SpectreKinetic and ExFastembed integrations. The
complete API reference is published on [HexDocs](https://hexdocs.pm/spectre/0.3.1).
Spectre is `0.x`: documented APIs may still evolve in minor releases; the
normative compatibility surface is the [public API manifest](docs/PUBLIC_API.md).

## A Small Agent

One readable module declares the stable shape of the agent. The DSL covers the
repetitive structure; normal Elixir modules still own the business logic.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, prompt_root: "priv/agents/support/prompts"

  model(MyApp.LLM, purpose: :smart)

  router(via: [:regex, :embedding, :classifier])

  actions MyApp.SupportActions do
    protect(:delete_account, with: :delete_account_confirmation)
  end

  policy :delete_account_confirmation do
    request(:confirm_delete_account)
    accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
    reject(:cancel_delete, regex: ~r/^(no|cancel)$/i)
    otherwise(ask: :confirm_delete_account_retry)
    attempts(3, then: :cancel_pending)
  end

  interrupt :HELP, regex: ~r/^(help|menu)$/i do
    reply(:help)
  end

  flow :support do
    on :PRICING,
      regex: ~r/\b(price|pricing|cost)\b/i,
      embedding: ["how much does it cost?", "pricing plans"] do
      reply(:pricing)
    end

    on :DELETE_ACCOUNT, regex: ~r/\bdelete my account\b/i do
      action(:delete_account)
    end
  end
end
```

`Spectre.turn/3` is the host boundary. Every turn returns one decision as data:

```elixir
{:ok, turn} =
  Spectre.turn(MyApp.SupportAgent, "How much does it cost?",
    conversation_id: "chat-123"
  )

case turn.decision do
  {:reply, result} -> deliver(result.reply_text)
  {:awaiting, awaitable, result} -> present_policy(awaitable, result)
  {:needs, effect, result} -> enqueue_or_execute(effect, result)
  {:completed, completion, result} -> deliver_completion(completion, result)
  {:no_response, _result} -> :ok
end
```

The safety boundary in action — starting a protected action never executes it:

```elixir
# The model/route proposes; the effect waits for the policy.
{:ok, awaiting} = Spectre.turn(MyApp.SupportAgent, "delete my account")
{:awaiting, %Spectre.Awaitable{status: :open}, result} = awaiting.decision

# Approval changes state — still nothing has run.
{:ok, approved} =
  Spectre.turn(MyApp.SupportAgent, "yes, delete it", state: result.state)
{:needs, %Spectre.Effect{status: :approved}, approved_result} = approved.decision

# Only the host executes, explicitly.
{:ok, executed} =
  Spectre.execute(approved_result.state, %{
    agent: MyApp.SupportAgent,
    input: approved_result.input,
    state: approved_result.state,
    opts: [user_id: user.id]
  })
```

A full walkthrough — approval, rejection, retries, sessions, persistence — is
in [Getting Started](docs/GETTING_STARTED.md).

## Core Concepts

| Concept | In one sentence | Docs |
| --- | --- | --- |
| **Agent** | One module declaring routes, policies, actions, and prompts. | [DSL](docs/DSL.md) |
| **Route** | How one input is matched to one handler — via the routing dial. | [Routing](docs/ROUTING.md) |
| **Effect** | A described side effect with an explicit lifecycle; it never runs implicitly. | [Actions](docs/ACTIONS.md) |
| **Policy** | A deterministic confirmation gate in front of protected actions. | [Actions](docs/ACTIONS.md) |
| **Skill** | Reusable scoped behavior (flows, prompts, policies) an Agent mounts. | [Skills](docs/SKILLS.md) |
| **Subject / Instance** | Durable identity: one supervised owner per agent-and-subject pair. | [Instances](docs/INSTANCES.md) |
| **State / Run / Turn** | The conversation state machine, its checkpointable continuation, and the public projection of one step. | [Runs](docs/RUNS.md) |
| **Work / Vigil** | Precise terminating procedures and durable observation loops. | [Operations](docs/OPERATIONS.md) |
| **Stack** | Installable packages with immutable manifests; activation is not authorization. | [Stack](docs/STACK.md) |
| **Definition** | The canonical, content-addressed form of an agent. | [Canonical Definitions](docs/CANONICAL_DEFINITIONS.md) |
| **Governance** | How Definitions change: closed ChangeSets, review, approval, activation, rollback. | [Governance](docs/GOVERNANCE.md) |
| **Reflection / Forge** | The agent examining itself and proposing changes — under the same governance. | [Reflective Runtime](docs/REFLECTIVE_RUNTIME.md) |

## Documentation

**Start here**

- [Guide for LLMs and coding agents](LLMS.md) — machine-oriented contracts,
  safe usage patterns, and documentation routing for Spectre `0.3.1`.
- [Getting Started](docs/GETTING_STARTED.md) — a complete agent and host lifecycle.
- [Two Realistic Agents](docs/EXAMPLES.md) — database Q&A with Kinetic, browse-and-answer with Lens.
- [Architecture](docs/ARCHITECTURE.md) — ownership, lifecycle, trust, and host boundaries.
- [System Overview](SYSTEM.md) — small core, explicit satellite packages, design rationale.
- [DSL](docs/DSL.md) — agent macros, flows, handlers, policies, actions, prompts.

**Build**

- [Routing](docs/ROUTING.md) · [Routing Evaluation](docs/EVALUATION.md) · [Training](docs/TRAINING.md)
- [Actions](docs/ACTIONS.md) · [Skills](docs/SKILLS.md) · [Memory](docs/MEMORY.md)
- [Agent Instances and Subjects](docs/INSTANCES.md) · [Resumable Runs](docs/RUNS.md)
- [Stack](docs/STACK.md) · [Integration Boundaries](docs/INTEGRATIONS.md)

**Operate**

- [Production Operations](docs/PRODUCTION.md) — persistence, idempotency, supervision, deployment checklist.
- [Journal](docs/JOURNAL.md) · [Provider Resilience](docs/PROVIDERS.md) · [Testing](docs/TESTING.md)

**The reflective runtime**

- [Work, Vigil, and the Operational Runtime](docs/OPERATIONS.md)
- [Runtime Skills](docs/RUNTIME_SKILLS.md) · [Data-driven Execution](docs/DATA_DRIVEN_EXECUTION.md)
- [Governed Definition Changes](docs/GOVERNANCE.md) · [Reflective Runtime](docs/REFLECTIVE_RUNTIME.md)
- [Skill State](docs/SKILL_STATE.md) · [Event Lifecycle](docs/EVENT_LIFECYCLE.md) · [Identity and Activation](docs/IDENTITY_ACTIVATION.md)
- [Definition Store](docs/DEFINITION_STORE.md) · [Foundation Conformance](docs/FOUNDATION_CONFORMANCE.md)
- [Public API Manifest](docs/PUBLIC_API.md) — the exact normative compatibility surface.

**Releases**

- [Changelog](CHANGELOG.md) — release notes and compatibility changes.
- [Roadmap](docs/ROADMAP.md) — architectural hardening and package direction.
- Migration guides are versioned with the package; start with
  [Migrating to 0.3.0](docs/MIGRATING_TO_0_3.md).

## License

Spectre is released under the [Apache License 2.0](LICENSE).
