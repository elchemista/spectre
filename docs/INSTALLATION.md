# Installation

Spectre requires Elixir `~> 1.19`. Vettore is a required dependency. JSON uses
Elixir's standard `JSON` module; applications using Jason directly must declare
Jason themselves.

Mounting a process-based Skill reuses the root AgentServer's Stack resources and
automatic GAM Domain. Install packages once in the selected Stack, select that
Stack with `use Spectre.Server, tools: MyApp.AI` in each callback module, and
declare the mount's permitted `governed:` operations. Each Skill has its own
runtime state and checkpoint; no second GAM installation, Domain or Host is
required. See [Skills](SKILLS.md).

## Dependencies

Add Spectre to your application's dependencies. If you are upgrading from 0.3,
follow [Migration](MIGRATING_TO_0_4.md) for the changes to Agents, Servers and tools.

```elixir
defp deps do
  [
    {:spectre, "~> 0.4.0"}
  ]
end
```

Companion libraries are optional: add only the packages your Stack installs,
using their Spectre 0.4-compatible versions. See [Stack tools](STACK_TOOLS.md)
and the package's own installation guide. Commit `mix.lock` to keep dependency
versions reproducible.

To depend on source instead, select an exact reviewed commit:

```elixir
{:spectre, github: "elchemista/spectre", ref: "COMMIT_SHA"}
```

Replace `COMMIT_SHA` with the commit you reviewed. The standalone
[demo manifest](https://github.com/elchemista/demo_spectre/blob/main/spectre.lock.exs)
pins a complete tested set of core and all nine companion packages.

```sh
mix deps.get
mix compile
```

This is an application dependency, not a Stack declaration. `install` then
connects that package's capabilities inside your compiled Stack. Follow its
README for configuration; most packages also retain a standalone API.

## First run

Use [Getting started](GETTING_STARTED.md) for the Lens/Kinetic email workflow
and its host configuration. For a separate model-free installation smoke check
from the core repository, run:

```sh
mix run docs/examples/agent_server_quickstart.exs
```

It requires no model API key. Generation, embedding and browser examples need
real provider adapters and host configuration; installing a package alone does
not provide those credentials.

## OTP supervision

Starting the Spectre application starts its shared registries, task supervisors
and GAM infrastructure. Your application owns Stack resources, conversation
owners and configured stores. Once `MyApp.AI` and `MyApp.SupportAgent` are
defined, a supervision tree can include:

```elixir
children = [
  {Spectre.Stack.Runtime, stack: MyApp.AI, name: MyApp.AIRuntime},
  {Spectre.Server,
   id: :support_agent,
   agent: MyApp.SupportAgent,
   stack_runtime: MyApp.AIRuntime}
]
```

For multiple Server children, use distinct `id:` values. For per-subject dynamic
ownership, `Spectre.summon(agent: MyApp.SupportAgent, subject: subject_id, ...)`
uses the Server registry when the Agent has a `server:` binding. Ownership is
local to the BEAM node; the subject identifier is not authentication.

Installed resources use a stable Stack runtime name, not a PID in portable
state. Credentials belong in runtime package configuration, not immutable
Stack definitions or conversational `assigns`. See [Stack tools](STACK_TOOLS.md).
For consequential operations, configure registered effects, authenticated identity
and `gam: [operations: ...]`. AgentServer automatically provisions its GAM Domain
and coherent default coordination stores. The default is ephemeral; select
`gam: [storage: {:disk, path}, ...]` for durable history and recovery. A minimal
startup grants no application effects. See [GAM](GAM.md) and
[Agent and Server](AGENT_SERVER.md).

## Formatter and diagnostics

```elixir
# .formatter.exs
[
  import_deps: [:spectre],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

`mix spectre.doctor --agent MyApp.SupportAgent --strict` checks compiled
contracts. It is not a live health check of providers, external executors or
stores. Run application-specific connection, authorization and recovery checks.

Vettore's classifier math and built-in Flat scans use automatic GPU selection
with CPU fallback. Optional normalization configuration remains:

```elixir
config :vettore, gpu: :auto, gpu_fallback: :cpu, gpu_min_size: 1_000_000
```

A GPU is not required. Embedding adapters and local training artifacts are
configured separately; see [Training](TRAINING.md).

## Remaining on 0.3

An existing application can keep its `{:spectre, "~> 0.3.4"}` dependency and
[0.3 tutorial](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/GETTING_STARTED_0_3.md). That API does not include the new
AgentServer/tool-helper contracts. Follow [Migration](MIGRATING_TO_0_4.md) before
changing runtime ownership or persisted state.
