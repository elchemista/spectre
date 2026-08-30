# Installation

Spectre requires Elixir `~> 1.19` and includes Vettore as a required dependency.
JSON encoding and decoding use Elixir's standard `JSON` module. Spectre does
not expose a JSON-backend setting and does not include Jason as a direct
dependency; applications that call Jason themselves must declare it in their
own `deps/0`.

## Hex

Install the stable package from Hex:

```elixir
def deps do
  [
    {:spectre, "~> 0.3.4"}
  ]
end
```

Then fetch and compile dependencies:

```bash
mix deps.get
mix compile
```

## Optional Vettore GPU normalization

No Vettore configuration is required to install or run Spectre. Classifier
math and built-in Flat scans already use `gpu: :auto` with CPU fallback. An
eligible workload uses an available GPU; smaller workloads and hosts without a
GPU use CPU.

Without additional configuration, Vettore's internal collection-vector and
query normalization stays on CPU. To apply the same automatic selection to
those normalization steps too, optionally add:

```elixir
config :vettore,
  gpu: :auto,
  gpu_fallback: :cpu,
  gpu_min_size: 1_000_000
```

This is a performance option, not an installation requirement.

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

The generated module reference is available on
[HexDocs](https://hexdocs.pm/spectre/0.3.4). Verify the selected release with
`mix hex.info spectre` when preparing a production lockfile.

Run the read-only diagnostics after compilation:

```bash
mix spectre.doctor --strict
mix spectre.doctor --agent MyApp.Agent --strict
```

The first command verifies the running release and Foundation contract. The
second also checks the compiled Agent and Manifest plus its configured Stack
and Checkpoint Store callback shape. Doctor does not connect to the store or
start package resources. See [Production Operations](PRODUCTION.md) for the
host-owned health checks that remain necessary.

## GitHub snapshots

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
    {:spectre, "~> 0.3.4"},
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
    {:spectre, "~> 0.3.4"},
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
