# Stack

`Spectre.Stack` compiles the packages and services available to an Agent into
one immutable environment. It replaces implicit global extension discovery
with explicit installation and logical references.

## Define a Stack

```elixir
defmodule MyApp.AI do
  use Spectre.Stack

  install MyApp.Inference do
    provider :openrouter, MyApp.OpenRouter
    model :fast, id: "small-model"
  end

  install MyApp.JobActions
end
```

Package blocks are kept as raw AST until the package compiler receives them.
`provider` and `model` in this example are local forms understood by
`MyApp.Inference`; Stack does not import those names as macros.

Bind the resolved Stack to an Agent:

```elixir
defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI
end
```

The compiled Agent stores the Stack module and immutable, digest-fenced
installation references. For each package that declares `agent_extensions`,
the Agent automatically registers the corresponding adapter with that
package's compiled Stack configuration. A package can therefore activate its
selector, memory adapter, turn handler, action provider, flow handler, or
effect executor without asking the application to repeat `use Package`.

It does not copy runtime clients, credentials, processes, or connections into
the Agent definition.

## Installed Does Not Mean Authorized

Installation answers which capabilities exist in the environment. It does not
make every Operation or Action visible to a model, Flow, Work, or Skill.
Binding and policy remain separate:

- package manifests declare capabilities;
- Stack validates ownership and returns closed `Spectre.Stack.Ref` values;
- package-declared Agent extensions activate the installed implementation;
- a later Flow, Work, Skill, or policy binding selects which Refs are usable;
- policy and the host still decide whether a staged effect may execute.

An installed package may intentionally contribute an Action provider, but that
does not make every operation planner-visible or bypass protection and host
authorization.

## Installable Contract V1

A package implements `Spectre.Stack.Installable`:

```elixir
defmodule MyApp.Inference do
  use Spectre.Stack.Installable,
    id: :inference,
    version: "0.1.3",
    contract: 1,
    spectre: "~> 0.1.3",
    provides: [{:service, :inference}],
    operations: [{:inference, :complete}],
    resources: [:client],
    agent_extensions: [MyApp.Inference.Extension],
    dsl: __MODULE__

  alias Spectre.Stack.DSL

  @impl Spectre.Stack.Installable
  def compile(opts, block, caller) do
    declarations = DSL.compile!(block, caller, provider: 2, model: 2)
    {:ok, %{options: opts, declarations: declarations}}
  end
end
```

The manifest fields are:

- `id` and semantic `version`;
- Stack contract version and compatible Spectre requirement;
- provided contracts or uniquely owned services;
- required packages, contracts, or services;
- conflicts;
- namespaced Operation and canonical `{provider, action}` refs;
- runtime resource identifiers;
- Agent extensions that adapt the installation into executable Agent behavior;
- the optional package-local DSL module and portable metadata.

`compile/3` is optional. Its result must be a map or keyword list containing
only immutable data. PID, ports, references, and functions are rejected.
Package manifests and compiled installations receive deterministic SHA-256
digests.

Satellite package tests can execute the versioned contract directly:

```elixir
assert {:ok, package} =
         Spectre.Stack.Contract.V1.verify_installable(MyApp.Inference)
```

## Dependencies And Resolution

Package dependencies use closed descriptors:

```elixir
requires: [
  {:package, :inference, "~> 0.1.3"},
  {:service, :continuity},
  {:contract, :memory_store}
]
```

Stack validates missing and incompatible dependencies, cycles, conflicts,
duplicate packages, and duplicate ownership. Declaration order does not need
to be dependency order.

Resolve capabilities without obtaining their runtime handle:

```elixir
{:ok, ref} =
  Spectre.Stack.resolve(MyApp.AI, :operation, {:inference, :complete})

ref.package
ref.version
ref.stack_digest
```

Supported Ref kinds are `:package`, `:contract`, `:service`, `:operation`,
`:action`, and `:resource`.

## Caller-Owned Runtime

An installable may optionally return supervised resources:

```elixir
@impl Spectre.Stack.Installable
def child_specs(_installation, runtime_opts) do
  client_opts = Keyword.fetch!(runtime_opts, :client)
  [{:client, {MyApp.Client, client_opts}}]
end
```

Start a runtime explicitly and pass secrets only at that boundary:

```elixir
{:ok, runtime} =
  Spectre.Stack.start_link(MyApp.AI,
    packages: [inference: [client: runtime_client_options()]]
  )

{:ok, ref} = Spectre.Stack.resolve(MyApp.AI, :resource, :client)
{:ok, client_pid} = Spectre.Stack.Runtime.resolve(runtime, ref)
```

The runtime has no default registered name. Child identifiers are fenced by
the Stack, Installation, package version, and digests, so stale Refs do not
resolve. Existing core application children are not yet claimed to be
per-Stack; their migration belongs to the Agent Instance and runtime phases.

## Journal identity

When a Journal recorder is configured, routing, runtime, persistence, and
extension records include the authoritative Stack id, owner, digest, and the
id/version/digest of every installation. Package configuration, credentials,
PIDs, connections, and runtime handles are never copied into Journal metadata.

## Legacy Adapters

`Spectre.Stack.Installation.from_extension_mount/1` and
`from_provider_mount/1` materialize legacy mounts as explicit immutable
installations. This keeps existing Extension, provider, and Kinetic integrations
source-compatible while packages adopt the V1 manifest.
