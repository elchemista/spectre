# Installation

Spectre requires Elixir `~> 1.19` and includes Vettore as a required dependency.

## Hex

Add Spectre to `mix.exs`:

```elixir
def deps do
  [
    {:spectre, "~> 0.1.0"}
  ]
end
```

Then fetch and compile dependencies:

```bash
mix deps.get
mix compile
```

Start with [Getting Started](GETTING_STARTED.md), then use the
[Production Operations](PRODUCTION.md) checklist before deploying.

## Git preview

To test unreleased changes directly from the repository:

```elixir
{:spectre, github: "elchemista/spectre", branch: "main"}
```

Pin a commit for production builds. Git `main` is not a compatibility promise.

## Optional SpectreKinetic integration

Spectre runs deterministic actions without SpectreKinetic. Add the companion
library when model replies use Action Language or tool planning:

```elixir
def deps do
  [
    {:spectre, "~> 0.1.0"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```

The host application owns the Kinetic action registry and business
capabilities. Spectre consumes planned effects but does not execute model output
as arbitrary Elixir code.

## Optional ExFastembed integration

The production adapter is dynamically detected. Add ExFastembed only in the
application that needs local embeddings:

```elixir
def deps do
  [
    {:spectre, "~> 0.1.0"},
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

The Spectre application starts its semantic-cache owner and journal buffer. Add
a dynamic session supervisor only when using conversation processes:

```elixir
children = [
  {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
]
```

Stateless `Spectre.ask/3` and `Spectre.turn/3` calls do not require that session
supervisor.
