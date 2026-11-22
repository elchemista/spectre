# Call installed tools

AgentServer manages GAM automatically. For startup, application callbacks and
the boundary between application policy and kernel invariants, see
[Automatic GAM](MANAGED_GAM.md).

[Build an invoice integration](CUSTOM_STACK_TOOLS.md) to try a scoped read,
a governed write and the corresponding human approval.

## Scoped tool calls

With the Agent's `stack:` bound to an installed package, add a command in a
Server, Flow Port or allowed Activity.

```elixir
call_tool(ctx, {:billing, :draft}, %{id: "D1"}, on_result: :loaded)
```

`ctx` is the Context passed to the current callback. The pair addresses
the local installation ID and a declared operation. The argument map is
the payload supplied to the adapter's `prepare/3`. `on_result: :loaded`
names the continuation. With no explicit tag this example calls
`handle_result(:draft, result, ctx)` on the command's owner. The route may
have a different label, and the GAM operation used by a governed tool may
have a separate name.

Tools registered through `Integration.tool/4` support scoped calls as soon as
the Agent binds the Stack. Descriptor-based tools can also be called this way
when the operation resolves unambiguously in its installation. With a scoped
call the payload is passed directly. With a generated helper's tagged tuple,
the remaining tuple elements form the payload list. Choose the shape your
adapter expects. [Package declaration and schema options](STACK.md#tools-and-generated-aliases).

| Call option | Meaning |
| --- | --- |
| `on_result:` | A portable term supplied as the first argument to `handle_result/3`. Defaults to the scoped operation or generated helper name. |
| `timeout:` | Cognitive tool deadline in milliseconds or `:infinity`. Omitting it uses the configured Server `worker_timeout:` or 30,000 ms. Governed execution uses the host's GAM settings. |
| `confirmation:` | Governed tool request for confirmation. Use `true` to request it. The host's existing policy still applies if this option is omitted or set to `false`. |

| Callback result | Interpretation |
| --- | --- |
| Adapter's projected value, such as `{:ok, draft}` | A cognitive result. The package controls its shape through `project/2`. |
| `{:error, {:tool_rejected, tool, operation, reason}}` | Preparation or binding rejected the operation. The execution worker has not run it. |
| `{:error, reason}` or `{:tool_unknown, details}` | A worker or projection failed. `:never` marks uncertain execution as unknown for reconciliation. |
| `{:governed, %{outcome: %{status: :succeeded}}}` | GAM observed success for the admitted effect. Check the status when reporting the result. |
| `{:consent, :rejected}` or `{:consent, :expired}` | The corresponding presentation did not receive usable consent. |
| `{:governed_unknown, details}` | The admitted effect needs reconciliation through its original identity. |

Programming errors such as invalid options or incompatible adapters can fail
the callback before acquisition. [Callback defaults and dispatch](SERVER_CALLBACKS.md).

## Registered execution for managed GAM

`c:Spectre.Stack.Installable.effects/1` is an optional, immutable execution
catalog. It complements `tools/1`: helpers describe requests, while effects
register which adapter may execute a particular admitted operation. This is
the **effect catalog contract 1**, separate from tool descriptor version 1 and
`Spectre.Stack.Contract.V2`. AgentServer owns the GAM integration for registered effects.

A registration is a map keyed by the host operation named by `governed:`.
Each descriptor contains these fields.

| Field | Meaning |
| --- | --- |
| `contract: 1` | Version of the effect descriptor format. |
| `adapter:` | Module implementing `c:Spectre.Server.GAM.EffectAdapter.execute_effect/3`. |
| `operation:` | Package-local name passed as the adapter's first argument. |
| `side_effect:` | Declares `:none`, `:idempotent`, `:reconcilable` or `:non_idempotent`. Use the semantics the external service actually supports. |
| `material: :arguments` | The prepared canonical argument map becomes effect material. |
| `partition:` | Identity fields frozen for execution. Allowed entries are `:subject`, `:conversation`, `:task` and `:flow`. |
| `schema_hash:` | A binary hash when pinning the argument schema, or `nil`. The optional adapter callback `effect_schema/2` returns `{:ok, binary_hash}` or error. |
| `config:` | Portable immutable adapter configuration. Put credentials and running clients in application-owned resources. |

The adapter receives the local operation, the admitted arguments and the
execution context. Use `context.identity` for the bound identity,
`context.command_id` for the Act reference and
`context.options[:stack_runtime]` when resolving a supervised resource.
The context also supplies the compiled `installation`, `effect_config`
and `effect_schema_hash`.
Its result distinguishes `{:ok, receipt}` from
`{:error, :failed | :definitive_no_effect | :ambiguous, reason}`. Only actual
observations justify those statuses; an unknown result must not trigger blind retry.

The compiled installation digest covers these registrations. The managed bridge
resolves the operation and validates that digest again before execution. The
adapter receives the frozen identity partition, Act correlation ID and required
Stack resource reference; it receives no GAM Scope or submission credentials.
Kinetic registers the configured action catalog; Mnemonic, Beam, Pulse and Lens
register only their explicitly bound writes. Registration grants no authority:
the application must enable the operation and GAM must admit its concrete effect.

## Generated helper contract

Why can a callback call `kinetic(ctx, response, on_result: :prepared)`?

1. Adding `spectre_kinetic` to your dependencies makes the package module available.
2. `install Spectre.Kinetic` adds its `tools/1` descriptor to the Stack. The key `:kinetic` names the helper and the descriptor selects `:interpret` as its default operation.
3. `stack: MyApp.AI` binds the Agent to that installation. In the Server, `use Spectre.Server, tools: MyApp.AI` reads the descriptors at compile time and defines private `kinetic/2` and `kinetic/3` functions in that module. Call them directly from a callback.

The helper returns the updated Context with a queued command. Once the worker interprets the consolidated model output, the runtime calls `handle_result(:prepared, {:prepared, data}, ctx)`. The first atom is the application’s `on_result:` tag (defaults to `:kinetic`). The second is the result type returned by the Kinetic adapter. The callback can then submit a concrete proposal to GAM.

```elixir
defmodule MyApp.AI do
  use Spectre.Stack
  install Spectre.Kinetic, mode: :closed_moves, actions: MyApp.Actions
  install Spectre.Mnemonic, automatic: false, bind: [remember: :save_report] do
    isolate_by [:agent, :subject]
  end
end

defmodule MyApp.Server do
  use Spectre.Server, tools: MyApp.AI, prompt_root: "priv/prompts"

  def handle_flow({:outreach, :compose}, _input, ctx) do
    generate(ctx, :compose, on_result: :composed)
  end

  def handle_result(:composed, {:generated, response}, ctx) do
    kinetic(ctx, response, on_result: :prepared)
  end

  def handle_result(:prepared, {:prepared, %{actions: [candidate]}}, ctx) do
    propose(ctx, candidate.operation, candidate.args,
      proposal_metadata: candidate.metadata, on_result: :sent)
  end

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: respond(ctx, "Message sent.")

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.Server
  model MyApp.WritingModel
  router strategies: [:regex]

  flow :outreach do
    on :compose, regex: ~r/^compose$/i
  end
end
```

The host supplies `MyApp.Actions` as its action catalog,
`MyApp.WritingModel` as its response provider, and a `:compose` prompt under
`priv/prompts`. In `:closed_moves` mode Kinetic maps model Action Language
to the application's registered actions. `:composed` carries generation,
`:prepared` carries the parsed and validated proposal, and `:sent` carries
the GAM result. `candidate.metadata` preserves the provenance of the
selected action. The single-candidate pattern illustrates explicit selection.
The final catch-all delegates other shapes to the Server default.

The host must enable the chosen `candidate.operation` under GAM.
Kinetic operates on consolidated `model_output`. The reply's public
`text` can be cleaned before display. For the automatic planner path,
use `generate(ctx, :compose, planning: true)` and inspect `proposals` in
the generation result. Choose either automatic planning or an explicit
Kinetic helper for a given generation. [Runnable integration](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md).

## Command lifecycle

A helper appends a command to the returned context. It does not call the
package synchronously. The Server normalizes and validates all returned
commands before committing the event, then persists outbox identities before
starting workers. This applies to flow, result, pending and native OTP callbacks.

A tagged tuple selects an operation: `mnemonic(ctx, {:recall, "Luca"},
on_result: :remembered)`. Remaining tuple elements become the adapter's payload
list. Non-tuple input selects the descriptor's declared default; an unknown
tag is rejected rather than falling back to that default.

The adapter implements `prepare/3`, `invoke/3` for cognitive operations and
`project/2`. Preparation is pure and receives the Agent, routing hints and
immutable installation configuration. Invocation receives resolved installation
and service context; live browser/memory/model handles remain in supervised
resources, outside durable assigns. Projection produces bounded portable data.

Cognitive work (classifying, generating, looking up, planning) does not require
an end user's consent merely because it calls a model. The host still declares
its governed surface: protected access, disclosure or consumption may require
mediation regardless of the callback or helper name. See [GAM](GAM.md) and the
[GAM manifesto](https://spectre.guide/en/governed-act-model). The descriptor chooses
`:safe` replay or `:never` replay. An uncertain nonrepeatable request returns
`{:tool_unknown, details}` instead of being blindly retried.

A governed operation is normalized to `propose` before the outbox is written.
GAM owns Candidate, admission, Presentation when required, Act, Attempt and
Outcome. Package-specific `bind:` selects the host operation. Managed GAM
validates enabled operations at startup and rejects proposals for operations
outside the application's configured authority. Use the presentation and
pending APIs for consent suspension, resumption, rejection or timer closure.

Package `ServerTool.execute` functions are technical APIs for an already
admitted host executor. Calling them directly in application callbacks bypasses
the framework boundary, just as calling an email client directly would. Use
helpers and proposal commands for consequential work in Server callbacks.

## Installed packages

| Helper | Cognitive operations | Governed operations when explicitly bound |
| --- | --- | --- |
| `kinetic` | Interpret model AL into portable candidates | Candidates later passed to `propose` |
| `mnemonic` | Search, recall, reflect, evidence/knowledge queries, status, atlas | Remember, signal, learn, forget, models/observations, graph edits and maintenance; explicit bindings only |
| `lens` | Open/read/close, using logical browser references | Browser action |
| `prism` | Select a model; ordinary generation also uses installed extension | — |
| `beam` | Inspect endpoints | Deliver |
| `directive` | Pure state reducer for explicit new/next/respond/inform calls. Directive 0.2 can also run as an on-demand Activity. | The Activity or host dispatches selected tool proposals through GAM when governed. |
| `pulse` | Inspect protocol/contacts | Send |
| `ledger` | Inspect Server checkpoint head/entry metadata | — |
| `lab` | Inspect canonical checkpoint data | — |

Mnemonic supports `automatic: false` to use only explicit memory helpers.
Use a **named** `Spectre.Stack.Runtime` and pass that name as `stack_runtime:`
to the Server; Spectre passes it to the admitted adapter so both resolve the same
isolated engine. Explicit memory tools fail if that named runtime is missing.
Spectre freezes the authenticated subject/conversation partition into the
Candidate and reconstructs execution context from the committed payload, rather
than later mutable state or model arguments. See [Automatic GAM](MANAGED_GAM.md).
Credentials and mutable resources belong in runtime options, not in compiled
Stack configuration or `ctx.assigns`.

Ledger supplies a durable CAS Server store. Both checkpoint and GAM journal can
use it: `checkpoint: {Spectre.Ledger.ServerStore, store, key}` and bridge option
`store: {Spectre.Ledger.ServerStore, store}`. The existing Disk forms
remain supported. `ledger(ctx, {:head})` and `{:entries}` inspect only metadata
for this Server's checkpoint key. An explicit different key is rejected. No
raw checkpoint is copied into the calling Server's inbox. Use
`lab(ctx, {:inspect, :checkpoint})` to decode the current snapshot inside its
worker and return a bounded summary. Lab cannot manufacture consent or replay
effects. Its binary input form remains available for explicit offline inspection.

Ledger compacts its coordination log atomically when append capacity is reached;
`Spectre.Ledger.ServerStore.compact(store)` also lets the host schedule compaction.
It preserves live values and a global revision watermark, then removes deleted
keys from memory and disk without allowing stale CAS revisions to match a newly
created key. Revisions are opaque monotonic tokens; a fresh key need not start
at 1. Reads wait through compaction instead of using the five-second default
GenServer timeout. This is a coordination store, not an immutable audit archive. Deleted old payloads
remain in the log until compaction; filesystem backups and physical erasure need
host retention controls. Corrupt or truncated records fail closed.

Bad input and adapter domain rejections arrive through `on_result` as bounded
`{:error, {:tool_rejected, tool, operation, reason}}` results. Invalid developer
options, incompatible compiled bindings and nonportable application state are
programming failures; they do not become successful callback acquisitions.
Checkpoint fingerprints include adapter code and installation descriptors.
A changed fingerprint still requires an explicit checkpoint migrator. If the
migrator preserves an older in-flight tool command, the runtime records contract
drift without rewriting its original facts: cognitive work completes as changed
or uncertain, an unstarted governed command is rejected, and started governed
work uses its original GAM journal for reconciliation. No changed adapter is
silently invoked with the old arguments.

The runnable [integration project](https://github.com/elchemista/spectre_ecosystem/blob/main/integration/stack_tools/README.md) uses
all nine packages with the real Server and GAM kernel. Its external browser,
model and email transports are deterministic fixtures, not production clients.

## Package descriptor and adapter contract

The optional `tools/1` callback belongs to the existing
`Spectre.Stack.Installable` behaviour. Packages without it retain their existing
installation surface; they do not gain invented helpers. A minimal declaration
looks like this inside an installable package:

```elixir
@impl Spectre.Stack.Installable
def tools(_config) do
  %{
    knowledge: %{
      contract: 1,
      adapter: MyApp.KnowledgeTool,
      default: :search,
      operations: %{
        search: %{path: :cognitive, retry: :safe, max_bytes: 65_536},
        save: %{path: :governed, operation: :save_knowledge, max_bytes: 65_536}
      }
    }
  }
end
```

This generates `knowledge(ctx, input)` and `knowledge(ctx, input, opts)` in a
Server selecting that Stack. A non-tuple input chooses `:search`;
`{:save, value}` chooses `:save` and passes `[value]` to preparation. Descriptors
have exact validated keys. Duplicate names and collisions with Server functions,
imports or special forms fail at compilation. Startup verifies the compiled
snapshot against the Agent's actual Stack before restoring a checkpoint.

| Adapter function | Contract |
| --- | --- |
| `prepare(operation, payload, trusted)` | Pure validation in the Server's acquisition path. Return `{:ok, args}` or `{:error, reason}`. Trusted fields are `agent`, `routing` with route/scope/protection when present, and immutable installation `config`. |
| `invoke(operation, args, context)` | Cognitive worker invocation. Context contains the resolved `installation`, `service_context`, `config` and trusted current `checkpoint_ref` when configured. |
| `project(operation, raw)` | Returns `{:ok, portable_result}` or a projection failure. A normal service error is a portable result, e.g. `{:ok, {:error, reason}}`. |

`invoke/3` is required only when the descriptor declares cognitive operations.
Governed operations require a map from preparation and become ordinary
`propose` commands; they do not invoke a generic tool effect worker. Concrete
execution belongs to the admitted host executor. Technical package `execute`
functions are not permissions or substitutes for this boundary.

The trusted checkpoint reference is resolved from Runtime configuration, not
model arguments or mutable Context. It is supplied only to the tool worker,
not to generation options or durable assigns. Ledger's current-key inspection
and Lab's `:checkpoint` inspection use this field to avoid cross-conversation
checkpoint reads or copying raw snapshots into the inbox.

The public helper options are `on_result:`, cognitive `timeout:` and governed
`confirmation:`. An unknown option, a nonportable result tag/confirmation or a
mismatched binding is a programming error. Unknown operation tags, bad domain
input and invalid projected arguments produce a durable bounded rejection.
All callback entrypoints follow the same validation/acquisition rules.

A `:safe` command may repeat with the same command identity after a crash.
A `:never` command records execution-start before invocation; interruption,
timeout or loss of a usable projected receipt preserves `tool_unknown`.
Neither choice supplies exactly-once external effects. Keep stable logical ids
when an application service implements its own idempotency contract.

Run the package's conformance tests and exercise tool calls through a
Server with the real Stack. Include preparation rejection, the projected
result, and consent rejection or expiry for governed paths.
[Testing](TESTING.md).

## The same helpers inside a Skill

A Skill's callback module selects `use Spectre.Server, tools: MyApp.AI`, exactly
like the root Server. No second package installation or invented import is
needed. Stack resources are resolved by the same host runtime; conversation
state and pending intentions belong to the calling Skill. A scoped Kinetic
proposal retains its mounted operation reference, for example
`{{:skill, :research}, :kinetic, :send_email}`. Declare that reference in both
the mount's `governed:` list and the root AgentServer's allowed operations.

The root passes its existing automatic GAM connection to each Skill. All
governed commands share one Domain and authority ledger; mounting a Skill
creates no new grant and requires no extra Host or ingress. The runtime records
the originating mount for each proposal. Independent workers may run concurrently
while the shared kernel orders admission. Consent identifies the exact Skill and
presentation, so a confirmation cannot authorize a different Skill's command.
Local checkpoints and timer state remain separate; lifecycle changes are recorded
in the shared Domain and do not erase Duties.

Bound Mnemonic/Beam/Pulse/Lens effects similarly need their host operation in
the mount's allowlist. Cognitive reads do not acquire authority. Ledger/Lab
inspect the calling runtime's checkpoint by default. See [Skills](SKILLS.md)
and the [LiveView showcase](DEMO.md).

## Mnemonic request ergonomics

A single generated helper exposes the package's declared operations:

```elixir
mnemonic(ctx, {:search, input.text, limit: 5}, on_result: :found)
mnemonic(ctx, {:recall, input.text, max_tokens: 1200}, on_result: :context)
mnemonic(ctx, {:reflect, input.text}, on_result: :evidence)
mnemonic(ctx, {:forget, memory_id}, on_result: :forgotten)
```

The tuple carries library operation arguments and options. `on_result` and
`timeout` outside the tuple belong to the Server. `search` returns flat portable
hits with source/id/record; `recall` returns a richer packet. Writes require their
own Stack `bind:` entries and allowed GAM operations; mounting a Skill also requires
the matching `governed:` allowance. Read helpers do not reinforce graph/attention
or reveal secrets. See [Mnemonic's complete operation catalogue](https://github.com/elchemista/spectre_mnemonic/blob/0.2.0/docs/AGENT_SERVER.md).
