# Skills

A `Spectre.Skill` packages reusable conversation behavior that an Agent can
mount. It can own flows, route handlers, prompt injections, policies, and
action hooks, while the Agent continues to own the runtime infrastructure and
the real side-effect boundary.

Use a Skill when the same capability should be shared by multiple Agents, or
when a large Agent is easier to understand as several independently scoped
capabilities. Keep behavior that is specific to one small Agent directly in
that Agent.

## The Smallest Complete Example

Define the Skill with `use Spectre.Skill`:

```elixir
defmodule MyApp.Skills.Greeting do
  use Spectre.Skill, id: :greeting, version: 1

  flow :greeting do
    on :HELLO, regex: ~r/^hello$/i do
      run(:greet)
    end
  end

  def greet(%Spectre.Input{text: text}, _ctx) do
    {:ok, "The greeting skill received: #{text}"}
  end
end
```

Mount it in an Agent with `skill/2`:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  skill(MyApp.Skills.Greeting, as: :greeting)
end
```

Use the Agent normally. Spectre includes mounted Skill routes during routing
and invokes the callback on the module that owns the selected route:

```elixir
{:ok, result} = Spectre.ask(MyApp.Agent, "hello")

result.reply_text
#=> "The greeting skill received: hello"

result.route.scope
#=> {:skill, :greeting}
```

`as: :greeting` is the local mount identifier. It becomes the route, policy,
effect, and prompt scope, so two mounted Skills can reuse the same flow names
and route labels without losing ownership.

If `as:` is omitted, the Skill's `id:` is used. Mount identifiers must be
unique within an Agent.

## Binding Actions

A reusable Skill should not know the concrete action names used by every host
application. Declare a logical requirement in the Skill, use that logical name
in its handlers, and bind it when mounting the Skill.

```elixir
defmodule MyApp.Skills.DocumentSearch do
  use Spectre.Skill, id: :document_search, version: 1

  requires_action(:search, mode: :read)

  flow :document_search do
    on :SEARCH_DOCUMENTS, regex: ~r/\bsearch (the )?docs\b/i do
      action(:search, args: %{index: "help-center"})
    end
  end
end
```

The Agent owns the concrete action module and binds `:search` to an action in
that module:

```elixir
defmodule MyApp.Actions do
  def search_help_center(args, ctx) do
    MyApp.Search.run(args.index, ctx.input.text)
  end
end

defmodule MyApp.SupportAgent do
  use Spectre.Agent

  actions(MyApp.Actions)

  skill(MyApp.Skills.DocumentSearch,
    as: :docs,
    bind: [search: :search_help_center]
  )
end
```

The logical action is materialized as the concrete action while retaining its
Skill owner and scope:

```elixir
{:ok, turn} = Spectre.turn(MyApp.SupportAgent, "search the docs")

{:needs,
 %Spectre.Effect{
   name: :search_help_center,
   mode: :read,
   scope: {:skill, :docs},
   status: :pending
 } = effect, result} = turn.decision

{:ok, completed} = Spectre.execute(MyApp.SupportAgent, result)
```

`mode:` may be `:read`, `:write`, or `:destructive`. Every declared requirement
must have a binding, and a Skill cannot stage, protect, or attach hooks to an
action that it did not declare. These rules are checked while the Agent
compiles.

`requires_tool/2` is an alias for `requires_action/2` when tool terminology is
more natural for the capability.

## Skill Policies

Policies may live with the reusable behavior. Protect the logical action name;
Spectre applies the policy to the bound concrete action and keeps the policy in
the mount's scope.

```elixir
defmodule MyApp.Skills.Publisher do
  use Spectre.Skill,
    id: :publisher,
    version: 1,
    prompt_root: "priv/skills/publisher/prompts"

  requires_action(:publish, mode: :write)

  policy :confirm_publish do
    request(:confirm_publish)
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  protect(:publish, with: :confirm_publish)

  flow :publishing do
    on :PUBLISH, regex: ~r/^publish$/i do
      action(:publish)
    end
  end
end
```

Mount it just like the previous example:

```elixir
skill(MyApp.Skills.Publisher,
  as: :publisher,
  bind: [publish: :publish_article]
)
```

When `:PUBLISH` routes, the resulting effect is named `:publish_article`, its
status is `:waiting_policy`, and its open awaitable is named
`{{:skill, :publisher}, :confirm_publish}`. Approval still only changes state;
the host must explicitly call `Spectre.execute/3` afterward. If the Agent also
protects the bound concrete action, the Agent's protection takes precedence.

## Prompts And Injections

A Skill may set its own `prompt_root:` and use the same `ask`, `reply`, and
`inject` declarations as an Agent:

```elixir
defmodule MyApp.Skills.Answers do
  use Spectre.Skill,
    id: :answers,
    version: 1,
    prompt_root: "priv/skills/answers/prompts"

  inject(:answering_rules, into: :instructions, position: :end)

  flow :answers do
    on :ANSWER, regex: ~r/^answer:/i do
      ask(:answer)
    end
  end
end
```

For a selected Skill route, Agent-level injections are composed with that
Skill's injections. Prompt names declared by the Skill resolve below its own
prompt root. In this example, `ask(:answer)` resolves:

```text
priv/skills/answers/prompts/answer.text.heex
```

The model used for `ask` still comes from the mounting Agent.

## What A Skill Inherits

A Skill describes behavior; it does not create a session or establish a second
runtime. The mounting Agent supplies:

- the resolved Stack and capability bindings;
- the router and arbitrator;
- model, classifier, and embedding adapters;
- the action module;
- state, memory, and journal adapters;
- the input pipeline, history, failure behavior, and session lifecycle.

Consequently, do not declare `model`, `classifier`, `embedding`, `router`,
`actions`, `state`, `memory`, `journal`, `input_pipeline`, `history`, `idle`,
`shutdown`, `fail`, or `stack` inside a Skill. Invalid infrastructure
declarations are rejected at compile time.

A Skill cannot mount another Skill. Compose multiple Skills at the Agent level:

```elixir
defmodule MyApp.Assistant do
  use Spectre.Agent

  skill(MyApp.Skills.Greeting, as: :greeting)
  skill(MyApp.Skills.DocumentSearch,
    as: :docs,
    bind: [search: :search_help_center]
  )
end
```

The Agent's configured routing strategies decide among Agent-owned and
Skill-owned routes together. Route receipts expose `scope`, making the selected
owner explicit for logging, persistence, and tests.

## Checklist

To add a Skill:

1. Create a module with `use Spectre.Skill, id: ..., version: 1`.
2. Add flows, handlers, prompts, policies, injections, or hooks with the normal
   Spectre DSL.
3. Declare every logical action with `requires_action/2`.
4. Mount it in an Agent with `skill SkillModule, as: ...`.
5. Bind each required action with `bind: [logical_name: :concrete_name]`.
6. Call `Spectre.ask/3` or `Spectre.turn/3` on the Agent, not on the Skill.

See also [DSL](DSL.md), [Actions](ACTIONS.md), and
[`Spectre.Skill`](https://hexdocs.pm/spectre/Spectre.Skill.html).
