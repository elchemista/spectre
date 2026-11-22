# Stack and package integration

`Spectre.Stack` compiles the packages and services available to an Agent into
one immutable environment. It replaces implicit global extension discovery
with explicit installation and logical references.

For release and umbrella integration tests, pass the complete package set to
`Spectre.Stack.Conformance.run/2`. It invokes the same compiler invariants as
an Agent Stack and catches compatibility, dependency, conflict, ordering, and
ownership failures that isolated manifest checks cannot see. See
[Foundation Conformance](https://github.com/elchemista/spectre/blob/0.4.0/docs/legacy/FOUNDATION_CONFORMANCE.md).

An Agent with application routes, a model or OTP callbacks can start with
`use Spectre.Agent, server: MyApp.SupportServer` and plain `use Spectre.Server`.
Add a Stack when you install a package or declare an Activity. Set `stack:`
on the Agent to make scoped `call_tool` calls available. Set `tools:` on a
Server module when its callbacks use generated helper names. [Build an
invoice tool from start to finish](CUSTOM_STACK_TOOLS.md).

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

The host supplies both package modules. `provider` and `model` in the block are
forms implemented by `MyApp.Inference`. Spectre passes that block to the
package's compiler. `use Spectre.Stack` defaults the Stack ID to its module and
its definition version to `1`. `install Package, as: :billing` gives the
installation a local ID. Use that ID in scoped calls and runtime configuration.
Other keyword options belong to the package and reach its `compile/3` callback.

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

The compiled Agent stores the Stack module and immutable installation
references. Package-declared `agent_extensions:` can connect capabilities
such as Prism's selector or Kinetic's planner as soon as the Agent selects
the Stack. Use the package's runtime configuration for clients, credentials
and connections.

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

## Tool registration with descriptor maps

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
positive integers no larger than `Spectre.Server.Checkpoint.max_bytes/0`.

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

Use `use Spectre.Server, tools: MyApp.AI` to generate named helpers from these
descriptors. With the same Stack bound to an Agent, an unambiguous operation can
also be called by its scoped reference. Generated helpers validate their
compiled binding at startup. Scoped calls validate the selected adapter
when the command is acquired. [Installed tools](STACK_TOOLS.md).

## Typed package integrations

`integration/1` receives the compiled installation configuration. Use
`Spectre.Integration` to declare service providers, tools, flows and on-demand
Activity types. Existing `tools/1`, `effects/1` and `child_specs/2` declarations
can contribute additional capabilities to the same installation.

| Builder | Caller and result | Authority and lifetime |
| --- | --- | --- |
| `service/4` | The owning call site calls the provider's behaviour with its runtime request and installation options. | Agent binding chooses the provider. Provider callbacks obey the host's policy for access and external calls. |
| `tool/4` | Server workers prepare arguments and project results to the initiating callback. | Cognitive adapters enforce access scope. A governed tool stages a proposal and GAM admits its registered effect before execution. |
| `flow/3` | An exposed route calls the flow with its label, normalized input and Context. Commands return to that flow's result callback. | The Agent exposes eligible routes. Flow callbacks run in the conversation owner. |
| `activity/4` | An explicit start invokes `handle_start/2` with application arguments and a Context. Lifecycle events carry the execution ref. | The host selects allowed types. Each execution has its own supervised process and a narrowed tool scope within the Root's GAM Domain. |

```elixir
defmodule MyApp.Documents do
  use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

  @impl true
  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:read, MyApp.Documents.Read,
      args: [id: :string],
      description: "Read a document owned by the current subject",
      access: :subject_scoped,
      retry: :safe)
    |> Spectre.Integration.flow(:lookup, MyApp.Documents.Flow)
    |> Spectre.Integration.activity(:research, MyApp.Research,
      tools: [{:documents, :read}],
      requires: [{:documents, :read}]
    )
  end
end
```

The example names adapter modules provided by your library. Use an atom for
each operation, flow scope and Activity type. Define each name once per
installation and kind. The application decides which routes and capabilities
to use. [Runnable Documents example](EXAMPLES.md#chat-and-reusable-documents-flow).

### Tools and generated aliases

Call `call_tool(ctx, {:documents, :read}, %{id: "D12"}, on_result: :loaded)`
from a Server, Flow or allowed Activity. `:documents` is the local
installation ID and `:read` is the operation declared by the package.
The argument map goes straight to `prepare/3`. The runtime delivers the
result to `handle_result(:loaded, result, ctx)` on the caller. Omitting
`on_result:` uses the operation name for a scoped call.

| `Integration.tool/4` option | Meaning |
| --- | --- |
| `args:` | A keyword list of required fields for public JSON Schema. Defaults to `[]`. Types are `:string`, `:integer`, `:number`, `:boolean`, `:object`, `:array` and `{:array, item_type}`. `prepare/3` validates the actual payload. |
| `description:` | Optional text for callers that display or expose public tool metadata. |
| `access:` | Optional `:subject_scoped` metadata. Enforce that scope in the adapter, using authenticated identity. |
| `governed:` | Names the host GAM operation for a consequential tool. Register the executor with `effects/1` and enable the operation in the host's GAM configuration. |
| `helper:` | Optional helper name. `helper: :read_document` generates `read_document(ctx, args, opts)` and its two-argument form in a Server with `tools: MyApp.Stack`. Both call paths use the same adapter. |
| `retry:` | Cognitive execution only. Defaults to `:never`. `:safe` allows replay of interrupted work. GAM owns governed execution and recovery. |
| `max_bytes:` | Positive byte budget for encoded prepared arguments and projected results. Defaults to the largest allowed value, `Spectre.Server.Checkpoint.max_bytes/0`. |

`Spectre.Stack.tool_metadata(MyApp.Stack, {:documents, :read})` returns
`{:ok, metadata}` for a typed tool or `{:error, reason}`. Public metadata has
its own digest, separate from the execution binding. The host can use it to
describe selected tools to an application or model. [Adapter and command
contracts](STACK_TOOLS.md#scoped-tool-calls).

### Flows and Activities

Expose a package's only flow with `expose :documents` inside the Agent.
If the installation declares more than one, choose the scope with
`expose flows: [{:documents, :lookup}]`. A Flow Port implements `routes/0`
and `handle_flow/3`. `use Spectre.Flow.Port` imports the Server helpers and
provides fallthrough to the default result handler. Its own `handle_result/3`
clauses customize results. Keep exposed route labels unique within the Agent.
[Reusable flows and replies](AGENT_SERVER.md#reusable-flows-and-targeted-answers).

`start_activity(ctx, {:documents, :research}, %{id: "D12"})` queues a new
execution of the installed type. An application can declare
`activity(:research, MyApp.Research)` directly inside its Stack and start
that type by the atom `:research`. Both declarations accept the same options.

| Activity declaration option | Meaning |
| --- | --- |
| `tools:` | The permitted scoped tool refs. Defaults to `:all` within the host's allowed scope. Use `[]` for an Activity with no tools. |
| `requires:` | Tools that must resolve in the Stack and survive the effective scope before an execution can start. Defaults to `[]`. |
| `allow_children:` | Defaults to `false`. Use `true` or a list of Activity types to enable child starts, subject to host policy and the parent's scope. |

The host can narrow types and tools further at startup and narrow tools for
an individual start. Lifecycle events report the allocated execution reference.
[Activity start, signals and lifecycle](AGENT_SERVER.md#run-a-background-activity).

### Services

`Integration.service(builder, behaviour, module, opts)` supplies a provider
implementing the behaviour's required callbacks. `opts` defaults to `[]`.
The provider receives these portable installation options. The Agent binds one
matching provider automatically. If two packages provide the same behaviour,
select an installation with
`use Spectre.Agent, stack: MyApp.Stack, services: %{Spectre.Inference.Selector => :library}`.
The values are installation IDs. Invalid or ambiguous selections fail at
compilation.

Spectre already calls the selected `Spectre.Inference.Selector` and
`Spectre.Action.Planner` through the generation and planning services.
Application code can look up its own role with
`Spectre.Stack.service(agent_module, MyApp.Retriever)`, which returns
`{provider, opts}` or `nil`. The application implements the call site for
a new behaviour. [Provider contracts](BEHAVIOURS.md).

Run `mix spectre.gen.installable MyApp.Documents` to scaffold an Installable and
its compiled Stack test. Run `mix spectre.doctor --agent MyApp.Agent` to inspect
the application's compiled bindings. [Doctor and runtime diagnostics](DIAGNOSTICS.md).

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

`use Spectre.Stack.Installable` supplies `manifest/0` and a default compiler
that returns install options for an installation without a block.
`compile(options, block_ast, caller)` is optional. Return
`{:ok, map_or_keyword}` or `{:error, reason}`. The compiler and
`integration/1`, `tools/1`, and `effects/1` receive and return immutable
configuration. PIDs, ports, refs and functions are rejected. Package manifests
and compiled installations receive deterministic SHA-256 digests.

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

`stack:` selects the compiled definition and `name:` registers the resource
supervisor. `packages:` supplies runtime options keyed by local installation
ID. For this package `runtime_client_options()` is the host function that
returns the client's runtime configuration. The `{:client, child_spec}`
entry in `child_specs/2` makes `:client` resolvable by the Stack's declared
resource reference.

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
