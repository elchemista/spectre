# Runtime Skills and Routing Projections

Spectre 0.2.7 lets trusted host code mount declarative Skills without compiling
a new BEAM module. Compiled and runtime-authored Skills both enter
`Spectre.Definition.Canonical`; `Spectre.Skill.Definition.semantic_ir/1`
provides the origin-neutral view used to prove behavioral equivalence.

Runtime input is data, not code. It may contain:

- structured applicability and positive/negative anti-hijack examples;
- exact text routes grouped in declarative Flows;
- closed `Spectre.Prompt.Fragment` values with explicit token caps;
- stable references to operations already registered by the host Agent; and
- reply or operation handlers.

It cannot contain callbacks, modules, AST, generated handlers, dynamic prompt
providers, publication authority, or activation authority. A runtime canonical
Definition containing a compiled `code_ref` is rejected.

JSON operation names remain strings in Definition identity. At mount and
response time Spectre may resolve such a string only to an identically named
ID already present in the host Agent registry; resolution never creates an
atom or registers an executor.

## Equivalent compiled and runtime definitions

A compiled Skill can refer to a closed Agent operation:

```elixir
defmodule MyApp.LookupSkill do
  use Spectre.Skill,
    id: :lookup,
    applicability: %{
      scopes: [:support],
      positive: ["lookup"],
      negative: ["admin"]
    }

  requires_operation :lookup

  flow :support do
    on :LOOKUP, check: {:text, "lookup"} do
      call_operation :lookup, input: :text
    end
  end
end
```

The equivalent runtime value is ordinary portable data:

```elixir
{:ok, runtime_skill} =
  Spectre.Skill.Definition.new(%{
    id: :lookup,
    declared_version: 1,
    publisher_ref: "host:my-app",
    applicability: %{
      scopes: [:support],
      positive: ["lookup"],
      negative: ["admin"]
    },
    operation_refs: [:lookup],
    flows: [
      %{
        id: :support,
        routes: [
          %{
            label: :LOOKUP,
            match: {:exact, "lookup"},
            handler: {:operation, :lookup},
            input: :text
          }
        ]
      }
    ]
  })

{:ok, compiled_skill} =
  Spectre.Skill.Definition.from_compiled(MyApp.LookupSkill)

true = Spectre.Skill.Definition.equivalent?(compiled_skill, runtime_skill)
```

Their exact Definition Refs remain different because origin and publisher
provenance are observable. Their semantic IR is equal.

An operation-backed compiled Skill is consumed through
`Spectre.Skill.Definition.from_compiled/2` and `Spectre.Skill.Runtime`; the
legacy static `skill/2` mount path rejects it because that runner has no
operation-request boundary.

## Host-governed lifecycle

The Agent owns the operation implementation:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  operation :lookup, {MyApp.Operations, :lookup},
    input: :any,
    output: :any
end
```

Create an effective Authority Envelope and reserve the kernel prompt window
before mounting Skills:

```elixir
authority =
  Spectre.Authority.Envelope.new!(
    operations: [:lookup],
    prompt_budget_classes: [:small, :standard],
    open_capabilities: [
      Spectre.Skill.Runtime.capability(:mount),
      Spectre.Skill.Runtime.capability(:replace),
      Spectre.Skill.Runtime.capability(:disable)
    ],
    limits: %{max_tokens: 4_096}
  )

runtime =
  Spectre.Skill.Runtime.new!(MyApp.Agent, authority,
    kernel_prompt_tokens: 1_024,
    per_skill_prompt_cap: 512
  )

{:ok, runtime} =
  Spectre.Skill.Runtime.mount(runtime, :lookup, runtime_skill,
    expected_revision: 0
  )
```

Mount, replace, disable, continuation claim, and continuation release use
revision compare-and-swap. Applicability conflicts, missing operation grants,
unregistered operations, unsupported prompt classes, failed anti-hijack
examples, and prompt-window overflow all fail before the revision changes.

Routing evaluates only active mounts. If equally specific Skills both match,
`route/3` returns `{:ambiguous_skill_applicability, ...}` rather than choosing
one by map order. Specificity counts positive eligibility constraints (scope
and required tags). Forbidden tags only exclude matching contexts and cannot
be added to manufacture routing priority.

## Operation boundary and draining

`respond/4` does not execute an operation. It returns a portable request and
pins a continuation to the exact Skill Definition Ref:

```elixir
{:ok, response, runtime} =
  Spectre.Skill.Runtime.respond(
    runtime,
    "lookup",
    %{scope: :support},
    expected_revision: 1
  )

%Spectre.Operation.Request{} = response.operation_request
```

The host executes or schedules that request through its normal trusted
boundary. Disabling a Skill with live continuations moves it to `:draining`:
new routes stop immediately, while `continuation/2` still resolves the pinned
Definition. Releasing the last continuation completes the transition to
`:disabled`. Replacement uses the same rule and retains an old generation only
while a continuation still owns it.

## Closed prompt budgets

Runtime fragments require a positive `token_cap`; the sum of fragment caps must
fit the Skill budget. Mount additionally checks the per-Skill ceiling, granted
budget classes, every retained draining generation, and the total window after
the kernel reserve. Loading a runtime Definition from canonical bytes restores
the fragments and rederives estimated tokens, fragment count, and reserved
tokens; mismatched declared counters or uncapped fragments are rejected. A
large Skill can therefore never evict the kernel prompt through either the
authoring or load path.

Runtime-authored fragment data may request a priority, but Spectre assigns the
effective scope, target, position, trust class, provenance, and granted
priority. Closed placeholders render only scalar values. Missing or composite
values return an error and never crash the host through `String.Chars`.

## Routing projection and cache identity

`Spectre.Projection.Routing` derives a non-executable routing view from the
canonical Definition and a `Spectre.Router.IndexProfile`. Projection identity
binds the Definition Ref, generator version, profile, and cache key. Prompt
content and compiled callback descriptors are not copied into the routing
view. Derived indexes are disposable and may be rebuilt from these inputs.

The compatibility fixture at
`test/fixtures/compatibility/0.2.7/runtime-skill-routing-v1.json` pins the
runtime Definition, semantic IR, Routing projection, and cache identities.

## Scope of 0.2.7

Publication and activation remain explicit host actions. This release does not
add model self-publication, self-activation, generated callbacks, goal-driven
Work, autonomous Forge behavior, empirical reflection, or governance. Those
remain separate gates toward 0.3.
