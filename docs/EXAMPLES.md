# Two Realistic Agents

The support agent in the [README](../README.md) is deliberately minimal. These
two compositions show what a useful agent looks like with one satellite
package each.

## Answer questions from your database (core + Kinetic)

Each query is an ordinary function. The `@al` attribute, doc, and typespec are
all Kinetic needs to build its planning registry — no JSON schemas, no tool
catalog in the prompt:

```elixir
defmodule MyApp.Warehouse do
  use SpectreKinetic

  @al ~s(COUNT ORDERS WITH: ACCOUNT="acme" PERIOD="last_month")
  @doc "Counts orders placed by an account in a period."
  @spec count_orders(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def count_orders(account, period),
    do: MyApp.Reports.count_orders(account, period)

  @al ~s(TOP CUSTOMERS WITH: LIMIT="5")
  @doc "Lists the accounts with the most orders."
  @spec top_customers(String.t()) :: {:ok, [map()]} | {:error, term()}
  def top_customers(limit), do: MyApp.Reports.top_customers(limit)
end

defmodule MyApp.AnalyticsAgent do
  use Spectre.Agent

  use Spectre.Kinetic,
    actions: MyApp.Warehouse,
    modes: [count_orders: :read, top_customers: :read]

  model(MyApp.LLM, purpose: :smart)

  router(via: [:regex, :llm_classifier])

  flow :analytics do
    on :DATA_QUESTION,
      regex: ~r/\b(how many|orders|customers|revenue)\b/i do
      act(:data_question)
    end
  end
end
```

Ask a question:

```elixir
{:ok, turn} =
  Spectre.turn(MyApp.AnalyticsAgent,
    "how many orders did acme place last month?"
  )
```

`act` renders the prompt and calls the model; the model answers in compact
Action Language (`COUNT ORDERS WITH: ACCOUNT="acme" PERIOD="last_month"`);
Kinetic maps it onto `MyApp.Warehouse.count_orders/2` with validated, canonical
argument names. The planner never touches the database: the selected Action is
staged as a `:read` Effect, and the query runs only when the host executes the
`{:needs, effect, result}` decision. Add `protect(...)` to any function that
writes, and the same policy machinery from the support example guards it.

## Read a page and answer (core + Lens)

Lens gives the agent browser perception through a Stack, with browser
processes kept in an explicitly started runtime:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Lens, planner_exposure: [:look, :discover] do
    backend(SpectreLens.Browsers.Lightpanda,
      instances: 1,
      protocol: SpectreLens.Protocol.Lightpanda
    )
  end
end

defmodule MyApp.ResearchAgent do
  use Spectre.Agent, stack: MyApp.AI

  model(MyApp.LLM, purpose: :smart)

  router(via: [:regex])

  flow :research do
    on :CHECK_RELEASES, regex: ~r/\brelease page\b/i do
      action({:lens, :look},
        args: %{
          url: "https://github.com/elchemista/spectre/releases",
          opts: [include: [:markdown, :links]]
        },
        mode: :read
      )
    end
  end
end
```

Run it with the browser runtime supplied at the boundary, never stored in the
definition:

```elixir
{:ok, stack_runtime} =
  Spectre.Stack.start_link(MyApp.AI, packages: [lens: [binary: "/opt/lightpanda"]])

{:ok, turn} =
  Spectre.turn(MyApp.ResearchAgent, "check the release page",
    stack_runtime: stack_runtime
  )
```

The deterministic route stages the `:look` Action; executing it returns the
page as structured data marked `trust: :untrusted`, which the host converts
with `agent_context/2` before any model sees it. Because the Stack declares
`planner_exposure: [:look, :discover]`, an `act` route may also let the model
plan browsing — but only over those two operations, and every browser step
still passes through the same staged-Effect lifecycle.
