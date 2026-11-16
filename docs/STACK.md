# Stack in 0.4

`Spectre.Stack` compiles the packages and services available to an Agent into
one immutable environment. It replaces implicit global extension discovery
with explicit installation and logical references.

For release and umbrella integration tests, pass the complete package set to
`Spectre.Stack.Conformance.run/2`. It invokes the same compiler invariants as
an Agent Stack and catches compatibility, dependency, conflict, ordering, and
ownership failures that isolated manifest checks cannot see. See
[Foundation Conformance](https://github.com/elchemista/spectre/blob/feature/agent-server-gam/docs/legacy/FOUNDATION_CONFORMANCE.md).

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

Select installed helpers in a Server and bind the same Stack to the Agent:

```elixir
defmodule MyApp.Server do
  use Spectre.Server, tools: MyApp.AI

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "How can I help?")
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.Server
end
```

Recognition remains declarative in the Agent. Application continuations live
in Server callbacks; the Runtime owns the actual GenServer. See
[AgentServer](AGENT_SERVER.md) and [DSL](DSL.md).

The compiled Agent stores the Stack module and immutable, digest-fenced
installation references. For each package that declares `agent_extensions`,
the Agent automatically registers the corresponding adapter with that
package's compiled Stack configuration. Selectors, memory adapters and action
catalogs can therefore be supplied without repeating `use Package` on every
Agent. The retained extension contract also supports legacy turn/flow/effect
hooks; their availability does not convert every old execution path into a
Server callback or a GAM-governed executor.

It does not copy runtime clients, credentials, processes, or connections into
the Agent definition.

## Installed Does Not Mean Authorized

Installation answers which capabilities exist in the environment. It does not
make every Operation or Action visible to a model, Flow, Work, or Skill.
Binding and policy remain separate:

- package manifests declare capabilities;
- Stack validates ownership and returns closed `Spectre.Stack.Ref` values;
- package-declared Agent extensions activate the installed implementation;
- the Server selects its generated tool surface with `tools: MyApp.AI`;
- a governed tool names a closed host operation binding;
- GAM and the host mediate the declared consequence before executor capability
  is released. Legacy Flow/Work/Skill policy bindings retain their separate API.

An installed package may intentionally contribute an Action provider, but that
does not make every operation planner-visible or bypass protection and host
authorization.

Process-based Skills select the same Stack with `use Spectre.Server, tools: ...`.
Their generated helpers reuse its supervised resources; no second installation
or package-specific Skill adapter is needed. Each Skill owns its runtime state
and checkpoint, but the root automatically passes the same GAM connection and
authority ledger. Mount `governed:` references restrict the root's configured
operations, not grant new permissions. Consent and provenance stay associated
with the exact Skill and presentation. See [Skills](SKILLS.md).

## Tool registration in 0.4

The optional `c:Spectre.Stack.Installable.tools/1` callback receives the compiled
package configuration and returns immutable tool descriptors. It is the same
installation contract; packages do not need a second registration behaviour.
The callback must perform no I/O and must not initialize adapters or resources.

```elixir
@impl Spectre.Stack.Installable
def tools(_config) do
  %{
    notes: %{
      contract: 1,
      adapter: MyApp.Notes.Adapter,
      default: :recall,
      operations: %{
        recall: %{path: :cognitive, retry: :safe, max_bytes: 1_048_576}
      }
    }
  }
end
```

Descriptors have exactly `contract`, `adapter`, `default` and `operations`.
Operations are a non-empty map. A cognitive operation requires `path`, `retry`
(`:safe` or `:never`) and `max_bytes`. A governed operation instead requires
`path: :governed`, `operation` (the host binding name) and `max_bytes`; it cannot
declare its own retry policy or execution authority. Byte budgets must be
positive integers no larger than the core codec's 16 MiB limit.

`default` is `nil` or a declared operation. Tool names are Elixir identifiers;
each name must be unique across the Stack. Installation `as:` changes only the
installation ID, never the declared tool names. Unknown descriptor keys and
unsupported versions are rejected. Adapter availability is deliberately not
checked during Stack compilation, so adapter modules can compile separately.

Descriptors are stored in `Installation.adapters[:tools]` and participate in
the installation and Stack digests. Serialized definitions are revalidated.
Packages without the callback, or returning `%{}`, retain their existing
installation representation. Late-bound packages can expose `tools/1` directly
without a compile-time dependency on the behaviour module.

`Stack.Conformance.run/2` checks these declarations for module entries, using
the compiled configuration supplied through `configs:`. Raw `{module, manifest}`
pairs remain data-only manifest checks and do not execute callbacks.

Server helpers and dispatch consume these descriptors with
`use Spectre.Server, tools: MyApp.AI`. Adapter availability, compiled installation
identity and governed host bindings are validated at Server startup. See
[Installed tools](STACK_TOOLS.md) for the lifecycle, package matrix and example.

## Installable Contract V1

A package implements `Spectre.Stack.Installable`:

```elixir
defmodule MyApp.Inference do
  use Spectre.Stack.Installable,
    id: :inference,
    version: "0.1.0",
    contract: 1,
    spectre: "~> 0.4.0",
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
[
  requires: [
    {:package, :inference, "~> 0.1.5"},
    {:service, :continuity},
    {:contract, :memory_store}
  ]
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

Start a runtime explicitly and pass secrets only at that boundary. For a
long-lived AgentServer integration, supervise it under a stable atom or `:via`
name:

```elixir
children = [
  {Spectre.Stack.Runtime,
   stack: MyApp.AI,
   name: MyApp.AIRuntime,
   packages: [inference: [client: runtime_client_options()]]}
]

{:ok, ref} = Spectre.Stack.resolve(MyApp.AI, :resource, :client)
{:ok, client_pid} = Spectre.Stack.Runtime.resolve(MyApp.AIRuntime, ref)
```

The runtime has no default registered name. Resource resolution is read-through
cached; a supervisor child scan occurs only on a cache miss. Runtime and
resource monitors invalidate stale entries, so restarting the named runtime or
one resource resolves the replacement process rather than retaining an old PID.
Child identifiers are fenced by the Stack, Installation, package version, and
digests, so stale Refs do not resolve.

Pass the named runtime as a top-level Server option:

```elixir
{:ok, server} = Spectre.summon(
  agent: MyApp.Agent,
  subject: "account-42",
  stack_runtime: MyApp.AIRuntime
)
```

Resources are resolved inside service/tool workers. Do not copy clients,
credentials or initialized library structs into `ctx.assigns` or compiled
configuration. For subject-isolated memory, the Server and admitted executor
must resolve the same named runtime and the executor must use the authenticated
partition frozen by the host candidate. See [Memory](MEMORY.md).

The retained Instance runtime also accepts `stack_runtime:`. Its older nested
options, metadata filtering and ownership rules are documented in the legacy
API/reference pages; they are not a Server checkpoint migration mechanism.

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

## Contracts and migration boundaries

The Stack manifest contract number, package version and Spectre requirement are
separate values. `contract: 1` does not mean Spectre 0.1, and a satellite does not
need to copy core's version. Check the package's actual compatible requirement.
The full nine-package example is [here](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md).

The optional tool descriptor contract is documented in [Stack tools](STACK_TOOLS.md).
Its startup check pins the Server's compiled helper snapshot to the actual Agent
Stack. Definition/config/adapter drift requires explicit checkpoint migration;
changing an installation does not authorize reinterpreting an in-flight effect.
See [migration](MIGRATING_TO_0_4.md) and [GAM](GAM.md).
