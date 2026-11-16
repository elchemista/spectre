# Declarative Agent DSL in 0.4

Use DSL for declarations and ordinary Elixir for behavior. The Stack declares
installed capabilities, the Agent declares recognition, and the Server contains
callbacks. This keeps a route readable without hiding application control flow.

```elixir
defmodule MyApp.SupportAgent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.SupportServer

  model MyApp.ResponseModel
  classifier :local, MyApp.LocalClassifier, artifact_dir: "priv/intents"
  classifier :llm, MyApp.IntentModel, timeout: 8_000

  router strategies: [:regex, :intent_dataset, :embedding,
                       :local_classifier, :llm_classifier]

  flow :support, defaults: [collect_intent: true] do
    on :pricing, semantic_examples: ["How much does it cost?", "Show prices"]
    on :delete_account, regex: ~r/^delete my account$/i,
      collect_intent: false, dataset_lookup: false, protected: true
  end
end
```

The referenced adapters and Stack are supplied by the application. A bodyless
`on` requires the Agent's `server:` binding. These routes dispatch to
`handle_flow({:support, :pricing}, input, ctx)` and the corresponding deletion
clause. The Server prompt root belongs in
`use Spectre.Server, prompt_root: "priv/support/prompts"`.

## Agent declarations

| Declaration | Role |
| --- | --- |
| `use Spectre.Agent, stack: Stack, server: Server` | Bind recognition to capabilities and its OTP callback module. |
| `model MyModel, opts` | Configure the response model. |
| `classifier :local, Adapter, opts` | Configure local intent recognition independently. |
| `classifier :llm, Model, opts` | Configure the intent model independently. |
| `embedding Adapter, opts` | Configure vector recognition. |
| `intent_dataset Adapter, opts` | Configure the example store/lookup contract. |
| `router strategies: [...]` | Select recognition strategies and arbitration options. |
| `flow name, defaults: [...] do ... end` | Group routes and inherit common declaration options. |
| `on label, opts` | Declare recognition and a Server dispatch destination. |
| `skill Module, as: mount, governed: refs` | Mount reusable scoped routes and, when the Skill declares `server:`, its own Server process under the root's shared GAM. |

The classifier may be another model or a host implementation. A named local
binding accepts `function:`/`with:` when needed; classifier options are not
permission grants. A missing model/adapter is not replaced by an invented API.

## Route options

| Preferred option | Meaning |
| --- | --- |
| `regex:` | One expression or a list of expressions. |
| `semantic_examples:` | Text examples used by embedding recognition. |
| `bag:`, `jaro:` | Examples for their string-similarity strategies. |
| `collect_intent:` | Opt into eligible runtime example collection. |
| `dataset_lookup:` | Explicitly allow/exclude this route from dataset recognition. |
| `match_with:` | Limit the strategies allowed to see this route. |
| `check:` / `checks:` | Input-text/metadata visibility checks. |
| `protected:` | Marks a sensitive route and requests standard bridge confirmation; not a mandate. |

Flow nesting retains the complete taxonomy. A single flow uses `{flow, label}`;
nested routes retain their path and mounted Skill routes retain scope. Labels
remain globally unique. Do not discard those keys in a catch-all dispatcher.
The input pipeline can normalize input and attach metadata before pending or
routing dispatch; it runs once for an admitted input.

## Skill declarations and shared authority

Declare `server: MyApp.ResearchServer` in `use Spectre.Skill`, then mount that
Skill in the Agent. Its Server uses ordinary callbacks and selects the existing
Stack with `use Spectre.Server, tools: MyApp.AI`. Each mount owns local state,
workers, streams, pending intentions and a checkpoint key.

The root automatically supplies its same GAM connection, Domain and authority
ledger. No Skill GAM DSL, extra Host or ingress implementation is required.
`governed:` restricts root-configured operations; it grants no additional
authority. Provenance identifies each Skill proposal, and consent targets the
exact mount and presentation. Parallel work and timer closure remain subject to
the shared kernel laws. See [Skills](SKILLS.md) for the complete example.

## Router ergonomics and retained aliases

| 0.4 spelling | Retained spelling |
| --- | --- |
| `router strategies:` | `router via:` |
| `:intent_dataset` | `:semantic_cache` |
| `:local_classifier` | `:classifier` |
| `semantic_examples:` | `embedding:` on a route |
| `collect_intent:` | `learn:` |
| `match_with:` | `via:` on a route |
| `log_decisions:` | `classification_log?:` |
| `hard_short_circuit:` | `hard_short_circuit?:` |

Conflicting old/new spellings raise instead of silently selecting one. Prefer
one vocabulary in new code. `dataset_lookup: false` is an explicit recognition
opt-out; legacy `cache: false` has narrower compatibility behavior for custom
adapters and is not a completely interchangeable promise.

```elixir
router strategies: [:regex, :embedding, :local_classifier, :llm_classifier],
  embedding: [min_score: 0.85, min_margin: 0.05],
  local_classifier: [min_score: 0.90, min_margin: 0.05],
  log_decisions: true
```

Custom `pipeline:` remains an escape hatch. Include arbitration and
terminalization explicitly when supplying your own pipeline. See
[Routing](ROUTING.md) for arbitration, custom adapters and failure handling.

## Dataset configuration is separate from training

```elixir
# Optional: MyApp.Dataset implements the custom dataset adapter contract.
intent_dataset MyApp.Dataset,
  lookup: [exact: true, semantic: true],
  search: [min_score: 0.90, limit: 5],
  collect: [enabled: true, include_protected: false]
```

This binds an application-supplied dataset adapter. For the built-in store, omit
this declaration and use `:intent_dataset` in the router strategy list.
`Spectre.Router.SemanticCache` is the dispatcher, not an adapter to bind to itself.
`collect_intent: true` on a route enables eligible collection; it does not train
a model or make an online example verified. Text-only examples may support exact
lookup/training; vector lookup only includes valid compatible embeddings.
`train:` and inline training DSL forms are not supported. See [Training](TRAINING.md).

## Server behavior uses functions and callbacks

```elixir
defmodule MyApp.SupportServer do
  use Spectre.Server, tools: MyApp.AI, prompt_root: "priv/support/prompts"

  def handle_flow({:support, :pricing}, _input, ctx),
    do: generate(ctx, :pricing, on_result: :answer)

  def handle_flow(:unmatched, input, ctx),
    do: generate(ctx, :understand, input: input, on_result: :answer)

  def handle_result(:answer, {:generated, response}, ctx),
    do: respond(ctx, response.text)

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end
```

This fragment illustrates response handling; a real Server must implement each
route it declares, including deletion when using the Agent above. `:understand`
is a prompt chosen by the application. It is not an implicit framework callback.
The unmatched clause can inspect `ctx.routing.reason` and distinguish ambiguity,
no match and recognition failure.

The Server has no policy DSL requirement. Implement pending policy in
`handle_pending/3` and continuations in `handle_result/3`; use native OTP callbacks
for actor messages and timers. Installed tool helpers are generated from Stack
descriptors, not imported from satellite modules. See [AgentServer](AGENT_SERVER.md),
[Stack tools](STACK_TOOLS.md) and [Pending lifecycle](PENDING_LIFECYCLE.md).

## Legacy handler DSL

The 0.3 `reply`, `reason`, `act`, `action`, `policy`, `protect`, `turn_handler`
and Instance/Run handler forms remain compatibility APIs. A bodyful route is
not automatically converted into a new GAM-governed Server callback.
The [archived DSL reference](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/DSL_0_3.md) documents those forms and their
input/prompt machinery. Use [migration](MIGRATING_TO_0_4.md) when moving an
existing flow; do not combine both continuation protocols in one example.
