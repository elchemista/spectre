# Installation

Spectre requires Elixir `~> 1.19` and includes Vettore as a required dependency.

## GitHub

Spectre is not published on Hex. Install it from GitHub, pinned to the
release tag:

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre", tag: "0.3.0"}
  ]
end
```

Then fetch and compile dependencies:

```bash
mix deps.get
mix compile
```

Import Spectre's formatter metadata so `mix format` preserves the documented
DSL style without parentheses:

```elixir
# .formatter.exs
[
  import_deps: [:spectre],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

Start with [Getting Started](GETTING_STARTED.md), then use the
[Production Operations](PRODUCTION.md) checklist before deploying.

For unreleased development snapshots, pin an exact commit with `ref:` instead
of a release tag. The repository's default branch is not a compatibility
promise:

```elixir
{:spectre, github: "elchemista/spectre", ref: "COMMIT_SHA"}
```

## Stack packages

Packages that implement `Spectre.Stack.Installable` are installed explicitly:

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install Spectre.Prism do
    provider(:openrouter, MyApp.OpenRouter)
    model(:fast, id: "small-model")
  end
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

The package remains a normal Git dependency. Stack validates its manifest and
compatibility while the application retains ownership of dependency pins and
runtime credentials. See [Stack](STACK.md).

## Optional SpectreKinetic integration

Spectre runs deterministic actions without SpectreKinetic. Add the companion
library when model replies use Action Language or tool planning:

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre", tag: "0.3.0"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```

Mount the planner explicitly on each Agent that needs it:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent
  use Spectre.Kinetic, actions: MyApp.Actions
end
```

`use Spectre.Agent` remains the Agent entry point. Kinetic owns planning and
registry mechanics and automatically mounts its provider for `MyApp.Actions`;
the application does not implement an adapter. Omit `:actions` only when
another extension, such as MCP or Lens, already registers the providers that
Kinetic should plan. Spectre keeps ownership of policy, persistence, execution,
and journal lifecycle.

## Optional ExFastembed integration

The production adapter is dynamically detected. Add ExFastembed only in the
application that needs local embeddings:

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre", tag: "0.3.0"},
    {:ex_fastembed, github: "elchemista/ex_fastembed", branch: "master"}
  ]
end
```

Configure it on the Agent:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent

  embedding Spectre.Classifier.Embeddings.ExFastembed,
    model: "BAAI/bge-small-en-v1.5"

  router via: [:regex, :embedding, :classifier]
end
```

Spectre does not download or load a model until the embedding adapter is used.
Production deployments should prefetch model files and use a persistent model
cache outside ephemeral release directories.

## Minimal supervision

The Spectre application starts its local Instance Registry, Subject Registry,
semantic-cache owner, and journal buffer. Add a dynamic supervisor when using
subject-scoped Instances or legacy conversation Sessions:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

Stateless `Spectre.ask/3` and `Spectre.turn/3` calls do not require that
supervisor. See [Agent Instances and Subjects](INSTANCES.md) before adapting an
authenticated channel identity.
