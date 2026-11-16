# Installed tools in AgentServer 0.4

AgentServer manages GAM automatically. For startup, application callbacks and
the boundary between application policy and kernel invariants, see
[Automatic GAM](MANAGED_GAM.md).

## Registered execution for managed GAM

`c:Spectre.Stack.Installable.effects/1` is an optional, immutable execution
catalog. It complements `tools/1`: helpers describe requests, while effects
register which adapter may execute a particular admitted operation. This is
the **effect catalog contract 1**, separate from tool descriptor version 1 and
`Spectre.Stack.Contract.V2`. AgentServer owns the GAM integration for registered effects.

A registration includes `adapter`, package-local `operation`, `side_effect`,
`material: :arguments`, identity `partition`, optional `schema_hash`, and portable
`config`. The adapter implements `c:Spectre.Server.GAM.EffectAdapter.execute_effect/3`.
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

The package's existing `Spectre.Stack.Installable` behaviour declares `tools/1`.
A Server selects a Stack with `use Spectre.Server, tools: MyApp.AI`. The core
creates private helpers named by the installed descriptors. No imports from
`Spectre.Kinetic`, `Spectre.Mnemonic` or `Spectre.Lens` are needed.

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

  def handle_result(operation, result, ctx), do: super(operation, result, ctx)
end

defmodule MyApp.Agent do
  use Spectre.Agent, stack: MyApp.AI, server: MyApp.Server
  flow :outreach do
    on :compose, regex: ~r/^compose$/i
  end
end
```

The host still supplies the ActionProvider implementation, model, prompt and
GAM bindings/executors. Kinetic reads **consolidated model output**. It prepares
candidate actions; a prepared action is not an admitted Act. `generate/3`
without automatic planning keeps `model_output` for this continuation while
its public `text` is cleaned. The runtime never dispatches partial AL tokens.
`planning: true` retains the existing automatic planner path; do not run the
explicit Kinetic helper a second time on that result.

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

A governed operation is normalized to the existing `propose` command **before**
the outbox is written. GAM then owns Candidate, admission, Presentation when
required, Act, Attempt and Outcome. `bind:` only selects a host operation; it
never grants a mandate. The Server refuses startup if that binding is missing
or the standard GAM bridge is absent. Consent may be suspended, resumed,
rejected or closed by a timer through the existing pending/lifecycle API.

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
| `directive` | Pure state reducer: new/next/respond/inform | Proposed effects handled by the application |
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
| `prepare(operation, payload, trusted)` | Pure validation/projection; returns `{:ok, args}` or `{:error, reason}`. Trusted fields are `agent`, routing hints and immutable installation `config`. |
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

The [public callable manifest](PUBLIC_API.md) already includes Server and GAM,
but does not yet list this complete tool adapter/descriptor addition. Its
manifest test must not be cited as coverage of generated helper contracts.
Use the source declarations and tool integration tests for that boundary.

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
or reveal secrets. See [Mnemonic's complete operation catalogue](https://github.com/elchemista/spectre_mnemonic/blob/feature/stack-tools-0.4/docs/AGENT_SERVER.md).
