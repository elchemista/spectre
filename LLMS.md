# Spectre 0.3.1 guide for LLMs and coding agents

This file is the compact, machine-oriented entry point for using Spectre
correctly. It is written for coding assistants, autonomous development agents,
and retrieval systems that need the library's contracts without guessing from
module names.

It describes Spectre `0.3.1` and Elixir `~> 1.19`. When this guide and the
library disagree, prefer the compiled API and the following sources, in order:

1. [Public API manifest](docs/PUBLIC_API.md) for the supported compatibility
   surface.
2. Generated module documentation on
   [HexDocs](https://hexdocs.pm/spectre/0.3.1) for function contracts.
3. [Getting Started](docs/GETTING_STARTED.md) for the complete host lifecycle.
4. [Architecture](docs/ARCHITECTURE.md) and
   [Production Operations](docs/PRODUCTION.md) for ownership and deployment.

Do not infer a public contract from an exported function that is absent from
the public API manifest.

## Install

Use the stable Hex package unless the user explicitly requests a development
snapshot:

```elixir
def deps do
  [
    {:spectre, "~> 0.3.1"}
  ]
end
```

For an unreleased snapshot, use an exact Git commit with `ref:`. Never suggest
tracking a moving branch for production. Spectre satellite packages are
versioned independently; do not assume an existing `spectre_*` `0.2.x` package
is compatible with core `0.3.1`.

## The non-negotiable model

Keep these rules intact in generated designs and code:

- **The model proposes; the host executes.** A route, model response, runtime
  Skill, or Forge proposal cannot directly perform a side effect.
- **Approval is not execution.** Approval changes governed state. A separate
  explicit host call crosses the execution boundary.
- **Runtime data never becomes code.** Runtime-authored Definitions may contain
  closed data and references to host-registered operations, never arbitrary
  modules, callbacks, EEx, evaluated Elixir, or dynamically created atoms.
- **Definitions are immutable and content-addressed.** Runs and continuations
  stay pinned to the exact Definition that admitted them. Never fall back to a
  newer active Definition for convenience.
- **One Instance owns canonical mutation.** State, activation, events, and
  Skill state pass through the Instance sequencer with revision, generation,
  and fencing checks.
- **Governance is rechecked at commit.** Evaluation, approval, and activation
  are distinct stages. Durable Candidates and receipts are reread and verified
  before activation and recovery.
- **Failure is closed.** Missing refs, ambiguous routes, stale generations,
  malformed data, drift, and absent evidence are errors, not fallback signals.

See [System Overview](SYSTEM.md) for the design rationale.

## Minimal deterministic Agent

A compiled Agent declares its routes. Ordinary Elixir modules retain business
logic and deterministic rendering:

```elixir
defmodule MyApp.GreeterRenderer do
  def render(:hello, input, _context), do: "Hello, #{input.text}!"
end

defmodule MyApp.GreeterAgent do
  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false)

  flow :greeting do
    on :HELLO, regex: ~r/^hello$/i, cache: false do
      reply(:hello, renderer: {MyApp.GreeterRenderer, :render})
    end
  end
end
```

The host requests one normalized decision:

```elixir
{:ok, turn} = Spectre.turn(MyApp.GreeterAgent, "hello")

case turn.decision do
  {:reply, result} -> deliver(result.reply_text)
  {:awaiting, awaitable, result} -> present(awaitable, result)
  {:needs, effect, result} -> enqueue_or_execute(effect, result)
  {:completed, completion, result} -> acknowledge(completion, result)
  {:no_response, _result} -> :ok
end
```

Use `Spectre.ask/2,3` when the application needs the raw `Spectre.Result`. Use
`Spectre.turn/2,3` for the closed host-facing decision vocabulary above. Carry
the returned state into the next stateless call, or use a supervised Instance
with configured durable stores.

## Side effects and policy

An action handler is host code. The Agent can stage it, and a policy can approve
it, but only the host executes it:

```elixir
{:ok, turn} = Spectre.turn(MyApp.Agent, user_input, state: current_state)

case turn.decision do
  {:needs, %Spectre.Effect{status: :approved}, result} ->
    Spectre.execute(result.state, %{
      agent: MyApp.Agent,
      input: result.input,
      state: result.state,
      opts: host_execution_options
    })

  {:awaiting, _policy, result} ->
    {:ok, result.state}

  _other ->
    {:ok, turn}
end
```

Never generate code that calls an action solely because an LLM emitted its
name. Follow [Actions and Effects](docs/ACTIONS.md) for protection, retries,
idempotency, and delivery.

## Routing

Choose only the evidence providers the application actually supplies:

```elixir
router(via: [:regex])
router(via: [:regex, :embedding, :classifier])
router(via: [:regex, :embedding, :classifier, :semantic_cache, :llm_classifier])
```

Regex routing is deterministic. Embedding, classifier, cache, and LLM routing
require their documented host adapters and still select only declared routes.
Do not claim that an LLM may invent a route or bypass the normal lifecycle.
Read [Routing](docs/ROUTING.md) before adding a provider.

## Durable Instances and operations

Use an Instance when identity, state, activation, operations, or recovery must
survive beyond one stateless call. The identity is the Agent plus a stable
`Spectre.Subject`; the host supplies stores and supervision.

Use the narrowest operational abstraction:

| Need | Public boundary |
| --- | --- |
| One host-facing conversational step | `Spectre.turn/2,3` |
| Raw runtime result | `Spectre.ask/2,3` |
| Explicit Effect execution | `Spectre.execute/2,3` |
| Supervised Agent/Subject owner | `Spectre.summon/1,3`, `ensure_instance/3,4` |
| Bounded durable procedure | `Spectre.start_work/3,4` |
| Durable observation loop | `Spectre.register_vigil/3,4` |
| Continue a pinned Run | `Spectre.resume/3,4` |
| Inspect or control an operation | `loop/2,3`, `pause_loop/2,3`, `update_and_resume_loop/3,4` |

Read [Instances](docs/INSTANCES.md), [Runs](docs/RUNS.md), and
[Operations](docs/OPERATIONS.md) before implementing durable adapters. A real
deployment needs durable checkpoint and Definition stores plus an owner/lease
implementation appropriate for its topology.

## Governed Agent evolution with Morph

Morph is a host-facing facade over the normal governance pipeline. It is not an
autonomous permission system. The compiled Agent first declares a canonical
ceiling:

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:support], prompt_tokens: 512],
    approval: :human
  )

  # compiled routes and handlers
end
```

The host may then propose a reply-only runtime Skill within that Surface:

```elixir
change =
  instance
  |> Spectre.Morph.change(
    by: "actor:author",
    reason: "Teach the support Agent about refunds"
  )
  |> Spectre.Morph.mount_skill("refunds",
    match: {:exact, "refund"},
    reply: "Refund policy applies to: {{input.text}}",
    scopes: [:support],
    token_cap: 128
  )
  |> Spectre.Morph.evaluate(cases: protected_cases)

review = Spectre.Morph.explain(change)
approved = Spectre.Morph.approve(change, by: "actor:independent-reviewer")
{:ok, activation} = Spectre.Morph.activate(approved)
```

Always inspect `Spectre.Morph.status/1` or `change.error` between stages in
production code. Do not let the Agent choose its own approval actor or policy.
The protected corpus must represent existing behavior; Candidate-owned cases
may add obligations but cannot make regressions pass.

When a Surface has multiple scopes, pass an explicit subset while proposing a
Skill and a trusted host context while serving it:

```elixir
Spectre.turn(instance, input,
  skill_context: %{"scope" => "support"}
)
```

Never derive privileged Skill scope from untrusted user text or metadata. Read
[Governance](docs/GOVERNANCE.md), [Runtime Skills](docs/RUNTIME_SKILLS.md), and
[Reflective Runtime](docs/REFLECTIVE_RUNTIME.md) before changing this flow.

## Runtime data rules

When generating or consuming portable Spectre data:

- use strings and the documented closed enums at transport boundaries;
- use `Spectre.Canonical.Value` and the artifact-specific codecs;
- preserve schema versions, refs, digests, receipts, closure data, and
  must-understand components exactly;
- resolve operation references only through host registries;
- reject functions, PIDs, ports, refs, module values, and secret-bearing data;
- never use `String.to_atom/1`, `List.to_atom/1`, `Code.eval_*`,
  `:erlang.binary_to_term/1`, or executable templates on runtime input;
- do not recalculate or substitute a pinned ref with the active ref.

Use [Canonical Definitions](docs/CANONICAL_DEFINITIONS.md),
[Definition Store](docs/DEFINITION_STORE.md), and
[Data-driven Execution](docs/DATA_DRIVEN_EXECUTION.md) for artifact contracts.

## Testing generated integrations

Tests must assert observable behavior and failure boundaries, not only struct
construction or function availability. At minimum, cover:

- a real `Spectre.turn/2,3` for the positive route;
- no-match, ambiguity, malformed input, and unauthorized execution;
- protected Effect approval followed by explicit host execution;
- checkpoint/restart when the integration claims durability;
- Definition A/B pinning when activation or Morph is involved;
- stale generation, tampered ref/receipt, and missing-store failures;
- exact output mutation for behavior introduced by a runtime Skill.

Run the project gates relevant to the change:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --all
mix dialyzer
mix docs --warnings-as-errors
```

For a compiled application, run `mix spectre.doctor --strict`; add
`--agent MyApp.Agent` to inspect that Agent's Definition, Manifest, configured
Stack, and Checkpoint Store callback shape. Use
`Spectre.Instance.CheckpointStore.Conformance` in adapter tests. The core
generators `spectre.gen.agent`, `spectre.gen.installable`, and
`spectre.gen.checkpoint_store` create minimal modules with executable contract
tests; replay and live-I/O test harnesses belong outside the core.

Read [Testing](docs/TESTING.md) for adapter and conformance suites.

## Common incorrect suggestions

Do not recommend any of the following:

- executing model-produced tool names directly;
- treating approval as execution;
- storing PIDs, callbacks, credentials, or model clients in a Definition;
- generating atoms from runtime strings;
- silently using the active Definition for an older continuation;
- trusting an in-memory Candidate without rereading its Store artifacts;
- widening a Morph Surface through caller options;
- using Candidate-authored evaluation cases as positive score;
- assuming all `spectre_*` repositories share the core version;
- importing undocumented internal modules because they appear in generated
  source or stack traces.

If a requested shortcut conflicts with these rules, explain the boundary and
offer a host-owned, explicit alternative.
