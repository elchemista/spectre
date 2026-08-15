# Actions

## `policy` And `protect`

Actions can be staged by deterministic DSL handlers or by an optional planner
mounted on the Agent. Either way, dangerous actions should not execute just
because text matched or a model proposed a tool instruction.

`protect` connects an action to a policy. In real agents, keep this next to the
action module with the block form:

```elixir
actions MyApp.SupportActions do
  protect(:delete_account, with: :delete_account_confirmation)
end
```

The policy is a tiny deterministic router that is used only while that action
effect is waiting:

```elixir
policy :delete_account_confirmation do
  request(:confirm_delete_account)
  accept(:confirmed_delete, regex: ~r/^yes, delete it$/i)
  reject(:cancel_delete, regex: ~r/^no|cancel$/i)
  otherwise(ask: :confirm_delete_account_retry)
  attempts(3, then: :cancel_pending)
end
```

While a policy is active, the next user turn bypasses the normal agent router.
That matters: a short answer like `"yes"` should approve the open policy
awaitable, not accidentally route to some generic conversation intent.

Approved actions still do not run automatically inside normal routing. A matching
policy response produces an `:approved` effect and the runtime persists that
state before returning:

```elixir
{:ok, approved} =
  Spectre.ask(MyApp.SupportAgent, "yes, delete it", state: staged.state)

[%Spectre.Effect{status: :approved}] = approved.state.pending_effects

{:ok, executed} =
  Spectre.execute(approved.state, %{agent: MyApp.SupportAgent})
```

A host may already know that a policy is satisfied—for example, terms were
accepted in account settings or another channel. Resolve the policy through its
declared label instead of synthesizing a user reply:

```elixir
{:ok, approved} =
  Spectre.resolve_policy(
    MyApp.SupportAgent,
    staged,
    {:accept, :confirmed_delete},
    conversation_id: conversation.id,
    assigns: %{user: user}
  )
```

The state adapter is called before this function returns. The result contains
the accepted awaitable, the `:approved` effect, and a
`:policy_resolved` audit event with `source: :host`. An unknown label is
rejected, so external resolution cannot bypass the policy declaration. With a
live session, the session state advances in the same operation.

`Spectre.execute/3` rejects `:waiting_policy` effects. It also injects
`:effect_id` and `:idempotency_key` into `ctx.opts`, so application code can
deduplicate a retry at its durable side-effect boundary.

That boundary is intentional. It gives the host application a clear place to
control transactions, permissions, audit logs, delivery, and retries. Spectre
accepts one action effect per turn; multi-action chains belong in
`spectre_directive` rather than being partially executed by the conversation
runtime.

## `actions` And Hooks

An action module is ordinary Elixir:

```elixir
defmodule MyApp.SupportActions do
  def delete_account(args, ctx) do
    MyApp.Accounts.delete_user(ctx.assigns.user_id, args)
  end
end
```

Declare it in the agent:

```elixir
actions MyApp.SupportActions do
  protect(:delete_account, with: :delete_account_confirmation)

  after_action(:delete_account,
    on: :delivered,
    run: {MyApp.AuditLog, :record_action}
  )
end
```

The bare form also exists for simple agents that only need to register an action
module:

```elixir
actions(MyApp.SupportActions)
```

Hooks run after a completed action effect exists. They are useful for audit
trails, notifications, and delivery bookkeeping.

## `before_action` Guards

Guards are the pre-execution veto point. They run right before the capability
is invoked — after routing, planning, and any policy approval — so they can
stop an action because of host state no route or policy can see: an open
draft, a role restriction, a quota.

```elixir
before_action :create_project, run: {MyApp.Guards, :no_duplicate_draft}
```

```elixir
defmodule MyApp.Guards do
  def no_duplicate_draft(_action, ctx) do
    if MyApp.Projects.open_draft?(ctx.assigns.user_id) do
      {:suppress, "You already have an open draft. Finish or cancel it first."}
    else
      :allow
    end
  end
end
```

A guard receives `(action, ctx)` and returns:

- `:allow` (or `:ok`) — execution proceeds
- `{:suppress, reply_text}` — the pending effect is cancelled without invoking
  the capability; the turn resolves as a normal reply carrying that text and
  an `:effect_suppressed` event
- `{:error, reason}` — the effect fails closed

`:all` guards every action. Guards run in declaration order and the first
non-`:allow` outcome wins. They are Agent-owned infrastructure: Skills cannot
declare them. An invalid guard reply fails the effect instead of allowing it.

## Generic Action Providers

`action` is provider-neutral. Spectre owns staging, policy, persistence,
idempotency, journal events, and terminal outcomes; a registered provider owns
discovery and execution.

The existing `actions MyApp.SupportActions` declaration is compatibility
shorthand for the built-in `:local` provider and its map/context callback
convention. It does not select Kinetic. Companion libraries mount their own
providers on demand.

Provider authors can use the low-level port directly:

```elixir
defmodule MyApp.GitHubProvider do
  @behaviour Spectre.Action.Provider

  def actions(_opts) do
    [
      Spectre.Action.Spec.new(
        name: :create_issue,
        via: {:mcp, :github},
        description: "Creates a GitHub issue",
        mode: :write,
        schema: %{
          type: "object",
          required: ["title"],
          properties: %{
            "title" => %{type: "string"},
            "body" => %{type: "string"}
          }
        }
      )
    ]
  end

  def execute(%Spectre.Action{name: :create_issue, args: args}, ctx, opts) do
    MyApp.GitHubMCP.create_issue(args, ctx, opts)
  end
end
```

Mount and use it without changing the engine:

```elixir
defmodule MyApp.ProjectAgent do
  use Spectre.Agent

  action_provider({:mcp, :github}, MyApp.GitHubProvider)

  protect({:mcp, :github, :create_issue},
    with: :confirm_issue_creation
  )

  flow :github do
    on :CREATE_ISSUE, regex: ~r/\bcreate.*\bissue\b/i do
      action({:mcp, :github, :create_issue},
        args: %{title: "Bug report"}
      )
    end
  end
end
```

A planner returns `%Spectre.Action{via: ..., name: ..., args: ...}`. It never
selects an implementation module directly: dispatch resolves `via` against the
providers compiled into the Agent. When a planned action carries a schema hash,
Spectre verifies the provider still exposes that schema before execution.

When `schema` declares a JSON-Schema validation keyword, Spectre validates both
the schema and the proposed arguments before staging and again at provider
execution. The closed subset covers primitive/object/array types, properties,
required/additional properties, enum/const, numeric and length bounds,
patterns, and bounded `allOf`/`anyOf`/`oneOf`/`not`. Unsupported constraint
keywords fail closed; discovery-only maps such as `%{arity: 2, version: 1}`
remain metadata for compatibility. Validation errors contain paths and rule
names, never rejected values.

Schema validation establishes shape, not authority. Providers must still
authenticate the caller, authorize the target resource, enforce tenancy and
make the real side effect idempotent.

Optional libraries should register providers or a planner through
`Spectre.Extension`. The public composition stays:

```elixir
use Spectre.Agent
use Spectre.Kinetic, actions: MyApp.Actions
```

There is no alternate Agent engine and no `use Spectre` facade.

## SpectreKinetic Planner

`spectre_kinetic` is an on-demand implementation of the action planner port.
Spectre does not detect or call it implicitly.

When an Agent that mounts `Spectre.Kinetic` receives an LLM reply, the Kinetic
adapter scans visible text and AL blocks. For example, a model might return:

```text
I can create that project brief.

<al>
CREATE PROJECT title="Marketplace MVP"
</al>
```

Spectre keeps the visible text for the user and delegates the AL block to
Kinetic for tool selection, slot mapping, and planning. The result is a
`%Spectre.Effect{kind: :action}`. If the action is protected, Spectre opens a
`%Spectre.Awaitable{kind: :policy}` before anything executes.

Define application actions with Kinetic's existing code-first DSL:

```elixir
defmodule MyApp.ProjectActions do
  use SpectreKinetic

  @al ~s(CREATE PROJECT WITH: TITLE="Marketplace MVP")
  @doc "Creates a project"
  @spec create_project(String.t()) :: {:ok, term()} | {:error, term()}
  def create_project(title), do: MyApp.Projects.create(%{title: title})
end
```

Mount that module through Kinetic on the Agent. This one `use` registers both
the Kinetic planner and its built-in action provider; the application does not
implement an adapter:

```elixir
defmodule MyApp.ProjectAgent do
  use Spectre.Agent, prompt_root: "priv/agents/project/prompts"
  use Spectre.Kinetic,
    actions: MyApp.ProjectActions,
    modes: [create_project: :write]

  model(MyApp.LLM)
  protect({:kinetic, :create_project}, with: :terms)

  policy :terms do
    request(:accept_terms)
    accept(:accepted_terms, regex: ~r/^yes$/i)
    reject(:rejected_terms, regex: ~r/^no$/i)
  end

  flow :project do
    on :CREATE_PROJECT, regex: ~r/\b(create|start).*\bproject\b/i do
      act(:create_project)
    end
  end
end
```

`Spectre.Kinetic.Actions` is the provider implementation supplied by the
companion package. It is mounted internally by `use Spectre.Kinetic`; do not
write `actions Spectre.Kinetic.Actions` in the Agent.

When MCP, Lens, or another extension already supplies action providers, mount
Kinetic without `:actions`:

```elixir
use Spectre.Agent
use Spectre.MCP, servers: [...]
use Spectre.Kinetic
```

Kinetic then plans against the providers registered by those extensions. If no
`:actions` module and no other providers are mounted, the planner has no
actions to select.

Kinetic can load runtime data from:

- the `runtime:` option passed to `use Spectre.Kinetic`
- `:spectre_kinetic, :runtime`
- `:spectre_kinetic, :compiled_registry`
- `:spectre_kinetic, :registry_json`
- `SPECTRE_KINETIC_COMPILED_REGISTRY`
- `SPECTRE_KINETIC_REGISTRY_JSON`
- action specs exposed by the Agent's registered providers

Before planning, Kinetic verifies that a borrowed or precompiled registry
matches exactly the providers mounted on that Agent. Missing, changed, or
unmounted registry entries are rejected.

Spectre does not maintain a second AL parser or registry. Kinetic owns AL
extraction, registry loading, tool selection, slot mapping, reranking, and
planning classifiers. Spectre owns providers, conversation routing, policy
gates, state, effects, awaitables, execution, and journal boundaries.
