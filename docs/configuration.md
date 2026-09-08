# Configuration: what each option means

Use this as a reference while reading the [small Agent](agents-and-dsl.md#a-small-agent)
or the [worked recipes](agent-recipes.md). You do not need every option to
write an agent. Start with a handler, then add the pieces your app needs.

## Four places for configuration

| Place | Put here | Do not put here |
| --- | --- | --- |
| Agent/Skill/Stack declarations | Flow names, route rules, prompt templates, fixed adapter choices | Live PIDs, credentials or permission invented by the agent |
| Definition publication | Revision, publication time and exact component Definitions | A running process or automatic activation |
| Instance startup | Authenticated Scope, local state, live service addresses and class bindings | A replacement kernel or an automatic provider loop |
| Domain startup | Ledger, authenticated ingress, execution boundary and governed foundation | Per-message overrides of authority or executor wiring |

A **port** is a named connection point, not a TCP port. For example,
`request/inference` connects a prepared model request to a preparation adapter;
`history/chat` connects the chat window to a backend you supervise.

Local DSL names are atoms written in source: `:support`, `:lookup`, `:answer`.
Action classes are strings: `"orders.lookup"`. Mounted paths are strings:
`"faq/questions"`. Do not convert user-provided text into atoms.

## Agent identity and publication

`use Spectre.Agent` and `use Spectre.Skill/Worker/Vigil` accept:

| Option | Required/default | Meaning |
| --- | --- | --- |
| `namespace` | Required nonempty string | Groups related published definitions, such as `"shop"`; not tenant authentication |
| `name` | Required nonempty string | Logical name of this definition, such as `"orders"`; not an OTP process name |
| `stack` | Omitted | Module using `Spectre.Stack` whose declarations are reused |

Use `MyAgent.definition(...)` to construct a Definition:

| Option | Meaning |
| --- | --- |
| `revision` | Explicit positive integer; first publication is normally `1` |
| `declared_at` | Explicit nonnegative Unix timestamp in milliseconds; compilation does not choose it |
| `previous_ref` | Exact predecessor for a later revision; absent for the first |
| `components` | Map from each Skill mount name to its exact Definition; defaults to `%{}` when there are no Skills |

`definition/1` returns the Definition directly and raises on an invalid
declaration. `Spectre.Agent.Publication.definition/2` is the tuple-returning
alternative. Construction is not governed activation: see
[publishing and starting](host-setup.md#authenticate-open-and-use-a-scope).

## Flow and Router

`flow :support do ... end` groups one routing policy and its handlers.
There is no process per flow and no nested flow block. Select a flow on each
`turn`; the library does not guess even when only one flow is declared.

`router MyApp.Routes` at module level imports a `use Spectre.Router` plan.
Inside a flow, `router ...` configures matching:

| Option | Default | Meaning |
| --- | --- | --- |
| `via` | `[:regex, :string_bag]` | Nonempty ordered list of matching methods |
| `accept` | `0.85` | Minimum score for selection; number from 0 to 1, not an authority threshold |
| `margin` | `0.0` | Minimum lead over the second nomination from that method; number from 0 to 1 |
| `cache` | Omitted | Name of a semantic-cache port used by the supplied bridge |
| `classifier` | Omitted | Name of a classifier declaration/port used by this flow |

Each method gets a chance in order. A unique accepted result stops the search;
a miss, skip or ambiguity lets the next method try. A callback error stops
with an error. If no later method decides, an earlier ambiguity is retained.
An exact tie is ambiguous even with `margin: 0.0`. Scores are **not combined
across methods** and are not calibrated probabilities.

For example, with `accept: 0.85, margin: 0.05`, scores `0.94` and `0.87`
select the first rule; `0.94` and `0.92` are ambiguous. This tunes routing,
not who may read an order or spend money.

`route :lookup, ...` accepts:

| Option | Default | Meaning |
| --- | --- | --- |
| `match` | `[]` | Method-specific examples/rules, e.g. `[regex: ~r/^order (?<id>[0-9]+)$/u]` |
| `cache` | `false` | Allow this route to be nominated by `:semantic_cache` |
| `classify` | `false` | Allow this route to be nominated by the configured classifier |
| `inject` | Omitted | Add this named prompt to asks reached through this route |

There is no `to:` or `row:` option in the handler DSL. The route's name is
the handler branch. `:error`, `:no_match`, `:ambiguous`, `:halted` and `:unrouted`
are reserved branch names. Each flow owns its policy; a Skill or another flow
does not inherit it. See [routing messages](agents-and-dsl.md#flow-router-and-custom-methods).

### Built-in and supplied matching methods

| Method | Input/rule data | Behavior |
| --- | --- | --- |
| `:regex` | Text / Elixir regex | Score 1 on a match; named captures become the handler's map |
| `:string_bag`, `:bag_distance` | Text / string or list of example strings | Same character-bag similarity algorithm; this is not token semantics or an embedding |
| `:jaro` | Text / example strings | Jaro string similarity |
| `:semantic_cache` | Text or text/vector envelope / `cache: true` | Supplied bridge queries approved examples; backend determines exact/vector search |
| `:local_classifier` | Adapter-specific input / `classify: true` | Host's local `Router.Adapter`; no built-in classifier model |
| `:llm_classifier` | A later governed classifier result / `classify: true` | Supplied bridge; does not call a model during initial routing |
| Your name, e.g. `:binary` | Adapter-specific | Implement `Spectre.Router.Adapter` and declare its port |

String matchers normalize Unicode, case and whitespace for fuzzy comparison.
Regex keeps its declared behavior. Built-in text matchers skip non-string
input; they do not automatically extract a `"text"` field from a map.
For vector envelopes plus regex, the host needs an explicit local matcher or
pipeline design that preserves the data each method needs. Converting the
whole envelope to text before the cache would discard its vector.

## Pipelines

`pipe_through :normalize` or `pipe_through [:decode, :normalize]` references
host-prepared `Spectre.Input.Pipeline` objects. Supply them in Instance
`adapters: [pipelines: [normalize: pipeline]]`; a name is not an automatic module
lookup. Each pipeline runs in list order before routing.

`Pipeline.new(stages, options)` accepts these bounds:

| Option | Default | Meaning |
| --- | --- | --- |
| `max_bytes` | `65_536` | Maximum canonical bytes of input and each stage's returned value |
| `max_depth` | `32` | Maximum nesting depth |
| `max_collection_size` | `1_024` | Maximum items in each collection |

There are at most 64 stages. A stage is a module or `{module, options}` with
`call/2` and optional `init/1`. It returns `{:cont, value}`, `{:halt, value}` or
`{:error, reason}`. The shipped NormalizeText supports `trim` (default `true`)
and `collapse_whitespace` (both default `true`), `case` (`nil`, default,
preserves case; or `:downcase` / `:upcase`), and `unicode` (`:nfc`, default;
also `:nfd`, `:nfkc`, `:nfkd` or `false`). See the
[running pipeline example](integration-and-streaming.md#a-reusable-local-pipeline).
Bounds on returned data do not sandbox allocations, time or I/O inside a callback.

## Requests, prompts and model selection

`{:request, "orders.lookup", data, state}` prepares that action class directly.
`request :lookup, class: "orders.lookup"` gives it a reusable local name, so the
handler can return `{:request, :lookup, data, state}`. Named templates can fix
Candidate fields; fixed values cannot be overwritten later. They cannot set
`row` or `identity_key`. See [bindings](host-setup.md#connect-a-handler-to-a-governed-action)
for the meaning of the remaining fields.

Template-only `disclosure_to` restricts exact destination references; `meter`
maps friendly names to exact Meter refs and restricts which Meters may be used.
Neither creates a destination, a budget or a resource request.

### Prompt declarations

| Declaration/option | Meaning |
| --- | --- |
| `prompt_root path` | Build-time directory for subsequent file declarations; set it explicitly relative to the source file |
| `prompt :name, "..."` | Inline EEx template, not a model invocation |
| `prompt :name, file: "answer.txt.eex"` | Compile a file under the root; `.txt.eex` and `.text.eex` are supported, **not `.txt.heex`** |
| `inject :policy` | Include the named prompt in asks at Agent or flow scope |
| `into: :system` | Apply this injection only when that base prompt is selected; omitted means all base prompts |
| `position: :start` / `:end` | Before/after the base prompt; default `:end` |

Templates are developer-owned Elixir/EEx source, not safe evaluation of user
templates. User text passed as an assign is not evaluated again as EEx.
Within each start/end group, injections are ordered Agent → flow → route.
Then come the task and separately tagged history/memory parts. `@history` and
`@memory` are reserved context assigns. Files are build inputs, not runtime
hot-reloadable prompts. See [rendering example](agents-and-dsl.md#prompts-and-injection).

### Ask and classifier declarations

| Field | Used by | Meaning |
| --- | --- | --- |
| `class` | `ask`, governed `classifier` | Host Surface action class; it must actually cover this inference |
| `prompt` | `ask` | Required base prompt name |
| `task` | `ask` | Optional task prompt name, rendered with the same assigns |
| `via` | `ask`, governed `classifier` | Name of a `request/...` preparation port, **not a provider name** |
| Additional settings, e.g. `model_ref`, `temperature`, `max_tokens` | Adapter/provider contract | Portable configuration passed along; Spectre does not interpret or enforce their business meaning |

Use `via: :inference` plus a port declaration to choose the preparation adapter.
That adapter builds consequence data; the **Domain's executor** makes the actual
model call after admission. The provider and model ID must be chosen explicitly
by your integration and bound in its governed contract when material.
The legacy `ask` field `model` can act as a port-name fallback when `via` is
absent; prefer `via` to avoid confusing a port with a model ID.

Writing `max_tokens: 300` does not create a 300-token Meter or guarantee a
provider will comply. Your executor and Surface contract must implement that
limit. A provider option is not a kernel policy. Unknown adapter-specific
settings are not universally validated by the generic DSL.

A flow chooses **one** classifier mode: local or governed, not both.
For governed classification, `classifier :intent, class: "model.classify",
via: :inference` links its port to `request/inference`. On no match the handler
may request classification; after its confirmed result, `route_result/2` only
accepts that turn's declared labels. See [classifier recipe](agent-recipes.md#a-classifier-before-the-business-handler).

## Connecting adapters

`adapter :kind, :name, Module, options` declares an implementation and fixed
options. It does **not** start it. At Instance startup, `adapters` supplies
missing resources such as `server`, a tenant binding or a prepared pipeline.
Options with the same fixed key must agree exactly; changing a published choice
requires a new declaration/Definition, not an unannounced runtime override.

| Group | Contract | Typical runtime resource |
| --- | --- | --- |
| `router` | `Spectre.Router.Adapter` | Local matcher options |
| `pipelines` | Prepared `Spectre.Input.Pipeline` | Pipeline object, not `{module, opts}` |
| `request` | `Spectre.Agent.RequestBuilder.prepare/4` | Host-local preparation configuration |
| `classifier` | Local Router adapter or governed request adapter | Model artifact/configuration selected by the host |
| `semantic_cache` | `Spectre.Router.SemanticCache` | Backend address and partition/profile identity |
| `history` | `Spectre.History` | Store address, `tenant_id`, `conversation_id` |
| `memory` | `Spectre.Memory` | Retrieval service and `tenant_id` |
| `observer` | `Spectre.Agent.Observer.handle_event/4` | `events` port; default adapter accepts `to: collector` |

An undeclared runtime port is an error, not a new dependency. Mounted Skill
names are qualified: `history: %{"faq/chat" => {MyHistory, options}}` fills
`faq/history/chat`. An alias such as a classifier's `via` is wired at the target
request port, not independently replaced at both ends.

Stack merges configuration without starting resources. `override: true` is
supported by `adapter` and the `ask/history/memory/classifier/semantic_cache`
declarations to replace an inherited entry; it is **not** a universal option on
`flow`, `route`, `prompt` or `request`. Duplicate names otherwise fail.
Extension `install` blocks use the extension's own vocabulary and return data
and ports. There is no dependency resolver, training service or sandbox.

## History, Memory and cache limits

| Declaration/option | Default | Meaning |
| --- | --- | --- |
| `history :chat, keep: ...` | `30` | Maximum loaded chat messages; not automatic saving |
| History `max_bytes` | `24_000` | Canonical message budget for the loaded window |
| History binding `tenant_id`, `conversation_id` | Required | Exact partition the backend must enforce and report |
| `memory :knowledge, limit: ...` | `5` | Maximum retrieved items |
| Memory `max_bytes` | `8_000` | Canonical budget for returned items |
| Memory binding `tenant_id` | Required | Retrieval tenant, not an authority grant |
| `semantic_cache :routing, learn: ...` | `false` | `:review` may save a quarantined example after a confirmed result; it never auto-approves |

History `keep` accepts 1–1,000; Memory `limit` accepts 1–100. Each per-window
`max_bytes` accepts 1–1,048,576. Direct `History.load/2` also accepts `before`,
a backend cursor/message ref for paging; the Agent declaration currently loads
the latest window, not a cursor chosen by a handler.

History/Memory load into `turn.context`; each item must cite available Evidence
in the authenticated Turn. Both together have a 65,536-byte context budget.
These limits do not erase ledger records or relax authority checks.
See [explicit chat persistence](agents-and-dsl.md#history-and-memory).

For the supplied Exact/Vettore cache processes:

| Startup option | Required/default | Meaning |
| --- | --- | --- |
| `namespace` | Required | Explicit partition, e.g. `"tenant-a/support"` |
| `definition_ref` | Required | Exact published Definition this partition belongs to |
| `flow` | Required | Flow path such as `"support"` |
| `profile_ref` | `nil` for exact-only | Identity of the encoder/model/preprocessing contract; required for native vector search |
| `labels` | Required list | Allowed route references, e.g. `["support/lookup"]`, not action classes |
| `name` | Omitted | OTP process registration; callers may use the returned PID instead |
| `max_entries` | `1_000` | Maximum retained examples, 1–100,000; edits/review use revisions |
| `max_text_bytes` | `8_192` | Maximum example/query text size, 1–65,536 |
| `dimensions` | `nil` for exact-only | Vector length, 1–8,192; native search requires it |
| Vettore `index` | `:flat` | `:flat` or `:hnsw`; derived native index, not authority storage |
| Vettore `index_options` | `[]` | Backend index tuning forwarded to Vettore; consult your installed version |
| Memory/Exact `search` | `nil` | Advanced `{IndexAdapter, opts}` with `build/2`, `search/3`, `close/1`; Vettore selects this internally |

Instance cache wiring adds `server` and the same `namespace/profile_ref`.
Definition and flow bindings are derived from the published plan. A map from
complete bindings to server addresses can select explicitly created partitions.
The adapter does not create them automatically.

Direct `SemanticCache.lookup` uses `text`, `vector`, `profile_ref`, `labels`
and optional `limit` (default 5, range 1–32). Router input instead uses the
envelope `%{"text" => text, "embedding" => vector, "profile_ref" => ref}`;
the bridge performs that field mapping and requests up to 32 nominations.
Plain text works for Exact. Native lookup needs a previously obtained vector;
missing embeddings skip that method rather than trigger a model call.

Example writes use `text`, `label` and, for vector search, `embedding` with its
`profile_ref`. `verify` approves one exact revision; editing an approved example
removes its approval. `examples` paging accepts `limit` (100, range 1–500),
`after` (last ID) and `verified` (`nil`, `true` or `false`). Snapshot restore
requires a fresh destination and preserves review state. These are cache
snapshots, not authority checkpoints. [Cache examples](agents-and-dsl.md#semantic-cache-and-classification)
show actual wiring. The application owns review, embeddings and training.

## Instance startup and calls

| Startup field | Default/meaning |
| --- | --- |
| `agent` | Handler module; generated `MyAgent.start_link/1` fills this for you |
| `scope` | Required live authenticated, opened Scope |
| `definition` | Exact governed Definition for the handler module |
| `definition_ref` | Lower-level Mind mode's selected Definition reference; handler mode also checks consistency |
| `state` | Local initial value, default `%{}` |
| `component_states` | Initial Skill values by owner prefix, e.g. `%{"faq/" => %{}}` (trailing slash), default `%{}`; separate from the parent's value |
| `adapters` | Grouped runtime port wiring, default `[]` |
| `bindings` | Class-to-occurrence map, default `%{}` only sufficient if another explicit builder supplies all required fields |
| `checkpoint` | Optional `{application_store, key}` to load local state; not authentication or an execution log |
| `max_pending_operations` | `32` waiting mutations; `0` rejects concurrent work instead of queuing |
| `name` | Optional ordinary GenServer name |

One persistent Instance process owns state. One monitored worker at a time does
slow work; the FIFO stores waiting mutations. Local reads see the last completed
value, not a partly updated value. The limit counts jobs, not arbitrary mailbox
bytes or provider allocations.

Do not supply `state` or `component_states` together with `checkpoint`: these
are conflicting sources of the initial value and startup rejects them.

| Call/options | Meaning |
| --- | --- |
| `turn(instance, input, flow: ...)` | Select the flow; omit only for an agent with no flows |
| Turn `ingress_opts` | Per-observation options passed to the Domain's fixed Ingress |
| Turn `sequencer_opts` | Domain call options; currently `timeout` only |
| Turn `context_evidence_refs` | Explicit contextual Evidence refs; they still need to be available and permitted |
| `advance(instance, request, wait: 5_000)` | Wait for a completed continuation, otherwise return a known pending ticket; `0` hands back promptly, `:infinity` waits |
| Advance `proposal_opts` | Ordinary proposal options; currently `[sequencer_opts: [...]]`, not executor/provider overrides |
| `operation(instance, ref, timeout)` | Observe completed work or refresh a deferred occurrence once; never re-submit it |
| `state/info/scope/current_turn(instance, timeout)` | Responsive reads; default caller timeout 5,000 ms, or `:infinity` |
| `definition(instance, timeout)` | Bound timeout for the local read, followed by a separate Domain fence/Definition check |
| `checkpoint(instance, store, key, expected_revision)` | Explicit CAS save of local state; not automatically called after effects |

`turn`, `propose` and `checkpoint` wait indefinitely at the Instance call level.
A provider needs its own timeout in its host executor. `wait:` does not stop
the provider and an OTP call timeout is not evidence of cancellation.
See [pending and steering](integration-and-streaming.md#a-host-owned-interaction-without-a-stream-runtime).

Worker/Vigil startup accepts `input`, `definition`, `supervisor`, `opening`,
plus optional `state`, `bindings`, `adapters`. The opening contains `context`,
`attributes`, `candidate` and optional `options`: authenticated child context,
finite promise, explicit authority for opening it, and facade call options.
See [reusable work](agent-recipes.md#reusable-skills-workers-and-vigils).

## Domain options

These configure the host boundary, not an individual model. Pass them in the
`Spectre.Domain` child spec or to `Spectre.start_domain(domain_ref, store, opts)`.
In the latter form `domain_ref` and `store` are arguments rather than options.

| Field | Default / required | Purpose |
| --- | --- | --- |
| `domain_ref` | Required | Stable identity for this authority/history boundary |
| `store` | Required | Ledger adapter, commonly `{Module, server: address}` |
| `ingress` | Required **module** | Fixed `Spectre.Ingress`; not a `{module, opts}` tuple |
| `mind` | Omitted | `Spectre.Agent` for handlers, or a custom Mind module for the lower-level API |
| `executors` | `[]` | List of modules or `{module, opts}`; each exposes executor and contract refs |
| `broker` | Required when executors exist | Module or `{module, opts}` implementing scoped capability checkout |
| `payload_store` | Omitted | Module/adapter configuration for external content verification |
| `late_observer` | Omitted | Module implementing `Spectre.Attempt.Observer`; authenticated later receipts |
| `clock` | Spectre.Clock.System | Module exposing trusted Unix milliseconds via `now/0` |
| `clock_tolerance_ms` | `60_000` | Allowed drift against monotonic elapsed time; `:infinity` disables this guard |
| `id_source` | Spectre.Id.UUIDv7 | Module exposing `generate/0` for occurrence IDs; not a replacement for canonical content hashes |
| `context` | Omitted | Optional recent-Evidence window, detailed below |
| `recovery_policy` | Omitted | Host witness/incident adapter; cannot override invalid core state |
| `recovery_timeout` | `5_000` ms | Positive callback time bound for recovery policy |
| `ingress_max_concurrency` | `32` | Maximum concurrent temporary authentication/observation jobs |
| `ingress_timeout` | `30_000` ms | Positive time bound for an ingress callback |
| `max_pending_submissions` | `1_024` | Submission queue bound, not uniform backpressure for every API |
| `batch_size` | `64` | Maximum proposals grouped by the sequencer |
| `batch_wait_ms` | `1` | Nonnegative batching delay |
| `grant_ttl_ms` | `30_000` | Internal dispatch grant lifetime; not provider timeout or Duty lifetime |
| `conflict_retries` | `8` | Ledger revision-conflict recovery attempts; **not executor retries** |
| `ambiguous_retries` | `2` | Ambiguous commit-resolution attempts; **not external-effect retries** |
| `ledger_opts` | `[]` | Host append/verification options; use the ledger adapter's documented contract |
| `registry` | Spectre.Domain.Registry | Advanced child-spec Registry selection; ordinary facade lookups use the default registry |

The foundation options are `genesis`, `principals`, `root_mandates`, `surface`,
`host_profile`, `constitution`, `genesis_verifier`. They name actual recognized
records, not model preferences. [Host setup](host-setup.md#prepare-the-foundation)
explains each and the optional Foundation builder. Constitution defaults are
validated, but the deployment must explicitly decide its Duty policy.

The sequencer also has an internal `name` option; `Domain.start_link` sets it
from `registry` and `domain_ref`. It is not an independent public naming option
to override alongside the Domain identity.

Advanced `generation`, `grant_secret`, `checkout_receipt_secret` exist for
controlled wiring/tests. Normally leave all three omitted: fresh values are
generated at boot. Hard-coding them risks weakening restart fences and seals.
They are not agent-facing configuration and must not enter a Definition.

When `context` is provided, its defaults are `max_events: 100`,
`max_evidence: 50`, `max_bytes: 256_000`. `max_events` counts recent ledger
positions; `max_evidence` counts selected contextual Evidence; `max_bytes`
bounds their canonical bytes. Each allows zero. With no configuration there is
no automatic recent-history selection. This window does not hide old revocations
from the kernel or bound the Domain's lifetime memory.

Storage has separate process/connection options: choose a backend in
[storage and recovery](storage-and-recovery.md#ledger-adapters-and-batch-reads)
and its API module documentation. A Disk `directory`, an ETS `server` and a
PostgreSQL `repo` are not interchangeable. A universal config map would hide
these different ownership and durability contracts.
