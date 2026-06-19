# Actions

## `policy` And `protect`

Actions can be staged by deterministic DSL handlers or by Action Language in an
LLM reply. Either way, dangerous actions should not execute just because text
matched or a model emitted a tool instruction.

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

Approved actions still do not run automatically inside normal routing. Execution
stays behind the pending action effect:

```elixir
{:ok, executed} = Spectre.execute(result.state, %{agent: MyApp.SupportAgent})
```

That boundary is intentional. It gives the host application a clear place to
control transactions, permissions, audit logs, delivery, and retries.

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

## SpectreKinetic Integration

Spectre works very well today with `spectre_kinetic`.

When an `ask` handler receives an LLM reply, Spectre scans visible text and AL
blocks through SpectreKinetic if it is loaded. For example, a model might return:

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

Your action module can be a Kinetic tool module:

```elixir
defmodule MyApp.ProjectActions do
  use SpectreKinetic

  @al "CREATE PROJECT title=<title>"
  def create_project(%{"title" => title}, ctx) do
    MyApp.Projects.create(ctx.assigns.user_id, %{title: title})
  end
end
```

Then wire it into Spectre:

```elixir
defmodule MyApp.ProjectAgent do
  use Spectre.Agent, prompt_root: "priv/agents/project/prompts"

  model(MyApp.LLM)

  actions MyApp.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)
    accept(:accepted_terms, regex: ~r/^yes$/i)
    reject(:rejected_terms, regex: ~r/^no$/i)
  end

  flow :project do
    on :CREATE_PROJECT, regex: ~r/\b(create|start).*\bproject\b/i do
      ask(:create_project)
    end
  end
end
```

Kinetic can load runtime data from:

- `:spectre_kinetic_runtime` application config
- `:spectre_kinetic, :compiled_registry`
- `:spectre_kinetic, :registry_json`
- `SPECTRE_KINETIC_COMPILED_REGISTRY`
- `SPECTRE_KINETIC_REGISTRY_JSON`
- extracted tools from the configured `actions` module

Spectre does not maintain a second AL parser. Kinetic owns AL extraction, tool
registration, registry loading, planning, slot mapping, and planning
classifiers. Spectre owns conversation routing, policy gates, state, effects,
awaitables, and action execution boundaries.
