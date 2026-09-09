# Configuration: find the option you need

This is a reference, not a checklist to complete before writing an Agent.

Choose the section for the thing you are configuring:

- [Agent identity](#agent-identity-and-publication) and published versions.
- [Flows and routing](#flow-and-router): matching and thresholds.
- [Prompts and model requests](#requests-prompts-and-model-selection).
- [Adapters](#connecting-adapters): connect your services.
- [History, Memory and cache limits](#history-memory-and-cache-limits).
- [Instance startup and calls](#instance-startup-and-calls).
- [Domain startup](#domain-options): authority, storage and execution.

For a walkthrough rather than a list of options, use
[the Agent guide](agents-and-dsl.md) or [host setup](host-setup.md).

## Four places for configuration

The simplest rule is: **declarations describe; startup connects.**

1. Put flow names, route rules, prompts and fixed adapter choices in the
   Agent/Skill/Stack module.
2. Supply revision, time and Skill Definitions when publishing a Definition.
3. Supply the authenticated Scope, local state and service addresses when
   starting an Instance.
4. Supply the ledger, authority and execution boundaries when starting a Domain.

Do not put live PIDs or credentials in a published Definition.

A **port** is a named connection point, not a TCP port.
`history/chat` connects a chat window to a backend.
`request/inference` connects an ask to its preparation adapter.

A **ref** identifies a particular record or resource. A **revision** is an
integer version used to detect stale reads/writes.

Local names are atoms written in source, such as `:support` and `:lookup`.
Action classes are strings, such as `"orders.lookup"`.
Mounted paths are strings, such as `"faq/questions"`.
Never turn arbitrary user input into atoms.

## Agent identity and publication

### Name the declaration

`use Spectre.Agent` and `use Spectre.Skill/Worker/Vigil` accept:

| Option | Required/default | Meaning |
| --- | --- | --- |
| `namespace` | Required nonempty string | Groups related published definitions, such as `"shop"`; not tenant authentication |
| `name` | Required nonempty string | Logical name of this definition, such as `"orders"`; not an OTP process name |
| `stack` | Omitted | Module using `Spectre.Stack` whose declarations are reused |

The name identifies the definition, not the running process. Several Instances
can use the same published Definition.

### Publish a particular version

`MyAgent.definition(...)` constructs the versioned record:

| Option | Meaning |
| --- | --- |
| `revision` | Explicit positive integer; first publication is normally `1` |
| `declared_at` | Explicit nonnegative Unix timestamp in milliseconds; compilation does not choose it |
| `previous_ref` | Exact predecessor for a later revision; absent for the first |
| `components` | Map from each Skill mount name to its exact Definition; defaults to `%{}` when there are no Skills |

Time is Unix milliseconds, not seconds. Compiling a file does not choose a new
publication time.

`definition/1` returns the Definition directly and raises on invalid input.
`Spectre.Agent.Publication.definition/2` returns a tagged tuple instead.

Construction does not activate the Definition. See
[publishing and starting](host-setup.md#authenticate-open-and-use-a-scope).

## Flow and Router

A flow names one interaction path. It creates no process.

For an Agent with declared flows, pass the chosen flow on each `turn`.
Even a single declared flow is not selected automatically.
An Agent without flows receives input directly.

Use `router MyApp.Routes` at module level to reuse an extracted Router.
Inside a flow, `router` accepts:

| Option | Default | Meaning |
| --- | --- | --- |
| `via` | `[:regex, :string_bag]` | Nonempty ordered list of matching methods |
| `accept` | `0.85` | Minimum score for selection; number from 0 to 1, not an authority threshold |
| `margin` | `0.0` | Minimum lead over the second nomination from that method; number from 0 to 1 |
| `cache` | Omitted | Name of a semantic-cache port used by the supplied bridge |
| `classifier` | Omitted | Name of a classifier declaration/port used by this flow |

### Read the scores with an example

With `accept: 0.85, margin: 0.05`:

- scores 0.94 and 0.87 select the first rule;
- scores 0.94 and 0.92 are ambiguous;
- a best score below 0.85 is not accepted.

A tie remains ambiguous even with zero margin. Scores are matching scores,
not calibrated probabilities or permission levels.

Each method tries in order. A unique accepted result wins. A miss, skip or
ambiguity allows the next method to try. An error stops routing.
If nothing later decides, an earlier ambiguity remains.
Scores from different methods are not combined.

### Configure a route

`route :lookup, ...` accepts:

| Option | Default | Meaning |
| --- | --- | --- |
| `match` | `[]` | Method-specific examples/rules, e.g. `[regex: ~r/^order (?<id>[0-9]+)$/u]` |
| `cache` | `false` | Allow this route to be nominated by `:semantic_cache` |
| `classify` | `false` | Allow this route to be nominated by the configured classifier |
| `inject` | Omitted | Add this named prompt to asks reached through this route |

The route name selects a handler branch. There is no `to:` or `row:`
option in the handler DSL.

`:error`, `:no_match`, `:ambiguous`, `:halted` and `:unrouted` are
reserved for routing results. A Skill or another flow does not inherit this
flow's policy.

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

For example, string-bag matching compares characters in example strings; it
does not understand their meaning through an embedding.

Fuzzy string matchers normalize Unicode, case and whitespace. Regex follows
the regex you declared. Built-in text matchers skip non-string input: they
do not automatically extract a map's `"text"` field.

If you combine vector-envelope input with text matching, provide adapters or
pipelines that preserve the input each method needs. Converting the whole
envelope to text would throw away the cache's vector.

## Pipelines

`pipe_through :normalize` names a pipeline prepared by the host.
It is not an automatic module lookup.

For several stages, use `pipe_through [:decode, :normalize]`. Connect the
prepared values at Instance startup through
`adapters: [pipelines: [normalize: pipeline]]`.

`Pipeline.new(stages, options)` accepts:

| Option | Default | Meaning |
| --- | --- | --- |
| `max_bytes` | `65_536` | Maximum canonical bytes of input and each stage's returned value |
| `max_depth` | `32` | Maximum nesting depth |
| `max_collection_size` | `1_024` | Maximum items in each collection |

“Canonical bytes” is the size of the encoded value. It includes structure,
not just visible text. A limit applies to input and each stage's returned value,
not arbitrary allocations inside the callback.

There are at most 64 stages. Each is a module or `{module, options}`, with
`call/2` and optional `init/1`. Returns are `{:cont, value}`,
`{:halt, value}` or `{:error, reason}`.

### NormalizeText options

- `trim: true`: remove surrounding whitespace.
- `collapse_whitespace: true`: collapse repeated whitespace.
- `case: nil`: preserve case; alternatives are `:downcase` and `:upcase`.
- `unicode: :nfc`: normalize Unicode; alternatives are `:nfd`, `:nfkc`,
  `:nfkd` and `false`.

See [the runnable pipeline](integration-and-streaming.md#a-reusable-local-pipeline).

## Requests, prompts and model selection

Use `{:request, "orders.lookup", data, state}` to propose a class directly.

Use `request :lookup, class: "orders.lookup"` when you want a reusable local
name, then return `{:request, :lookup, data, state}`.

Named request templates may fix Candidate fields. Later inputs cannot replace
those values. Templates cannot choose `row` or `identity_key`; the builder
supplies those. [Host bindings](host-setup.md#connect-a-handler-to-a-governed-action)
explains the remaining fields.

The template-only `disclosure_to` constrains exact recipients.
`meter` maps friendly names to allowed Meter references.
Neither option creates authority or a budget.

### Prompt declarations

| Declaration/option | Meaning |
| --- | --- |
| `prompt_root path` | Build-time directory for subsequent file declarations; set it explicitly relative to the source file |
| `prompt :name, "..."` | Inline EEx template, not a model invocation |
| `prompt :name, file: "answer.txt.eex"` | Compile a file under the root; `.txt.eex` and `.text.eex` are supported, **not `.txt.heex`** |
| `inject :policy` | Include the named prompt in asks at Agent or flow scope |
| `into: :system` | Apply this injection only when that base prompt is selected; omitted means all base prompts |
| `position: :start` / `:end` | Before/after the base prompt; default `:end` |

For inline text, pass the string directly:
`prompt :policy, "Be helpful."`.
The keyword form accepts `file:`, not `text:`.

Files are compiled with your code. They are not runtime hot-reloaded templates.
Use developer-owned EEx source; pass user text as assigns, not template source
to evaluate.

Within each start/end position, injection order is Agent → flow → route.
Task and separately tagged History/Memory parts follow.
`@history` and `@memory` are reserved context assigns.

See [the rendering example](agents-and-dsl.md#prompts-and-injection).

### Ask and classifier declarations

There are three names to keep apart:

- `prompt: :system` selects local template text;
- `via: :inference` selects a preparation connection;
- a model ID is interpreted by your provider integration.

| Field | Used by | Meaning |
| --- | --- | --- |
| `class` | `ask`, governed `classifier` | Host Surface action class; it must actually cover this inference |
| `prompt` | `ask` | Required base prompt name |
| `task` | `ask` | Optional task prompt name, rendered with the same assigns |
| `via` | `ask`, governed `classifier` | Name of a `request/...` preparation port, **not a provider name** |
| Additional settings, e.g. `model_ref`, `temperature`, `max_tokens` | Adapter/provider contract | Portable configuration passed along; Spectre does not interpret or enforce their business meaning |

The preparation adapter builds consequence data. The Domain's executor makes
the actual model call after admission.

For example, `max_tokens: 300` is an option the integration must honor.
It does not automatically create a 300-token Meter. If the value matters to
authorization or accounting, represent that in the contract.

Extra adapter settings are not all understood or validated by the generic DSL.
The legacy `model` field can name a port when `via` is absent; prefer `via`
to avoid confusing it with a concrete model ID.

A flow uses one classifier mode: local or governed.
`classifier :intent, class: "model.classify", via: :inference` connects governed
classification to `request/inference`.
The handler requests it on a miss, then uses the confirmed result to nominate
a declared route. See [the classifier recipe](agent-recipes.md#a-classifier-before-the-business-handler).

## Connecting adapters

`adapter :kind, :name, Module, options` declares an implementation.
It does not start the service.

At Instance startup, the `adapters` option supplies missing runtime resources:
server addresses, tenant bindings or prepared pipelines.

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

### Why is an option conflict an error?

Suppose a published declaration fixes one backend setting. Startup must not
quietly replace it with another value. Fixed keys must agree exactly; changing
the declaration requires a new Definition.

An undeclared runtime port is also an error. Use `MyAgent.ports()` to inspect
what is declared.

For a mounted Skill, `history: %{"faq/chat" => {MyHistory, options}}`
fills the qualified port `faq/history/chat`.
A classifier alias is wired at its target request port, not replaced
independently at both ends.

### Validate backend options at wiring

Adapter authors can opt into `@behaviour Spectre.Adapter.Options` and implement
`validate_options/1`. This catches mistakes at setup instead of first use.

The callback receives merged backend options after fixed-value checks.
Spectre-owned tenant/conversation/cache bindings are removed first.
History's observer is removed too. The runtime adds request `:declaration`
later; callers cannot supply it.

Valid responses are `:ok` or `{:error, reason}`, where reason is:

- `:invalid_options`;
- `{:missing_option, :repo}`;
- `{:invalid_option, :timeout}`;
- `{:unknown_options, [:misspelled_key]}`.

Use atom option names, not private values. Other reasons are replaced with
`:invalid_options`; malformed responses become `:invalid_validator_reply`.
Wiring adds the port name in `{:invalid_port, port, reason}`.
Exceptions are contained without exposing their messages.

This callback checks shape only. It must not connect to a database, call a
model, normalize options or add defaults. Runtime validation is still needed.

Declaring the behaviour is the opt-in; a same-named function alone is not.
Prepared pipelines use their own preparation API.
The default RequestBuilder accepts no host options.

### Reusing and overriding settings

Stack shares declarations without starting services.
`override: true` is supported on `adapter` and
`ask/history/memory/classifier/semantic_cache` to replace inherited entries.

It is not a universal option for `flow`, `route`, `prompt` or `request`.
Other duplicate names fail.

An Extension's `install` block uses the package's own vocabulary and returns
configuration and ports. It is not a dependency resolver.

## History, Memory and cache limits

### How much context should a turn load?

| Declaration/option | Default | Meaning |
| --- | --- | --- |
| `history :chat, keep: ...` | `30` | Maximum loaded chat messages; not automatic saving |
| History `max_bytes` | `24_000` | Canonical message budget for the loaded window |
| History binding `tenant_id`, `conversation_id` | Required | Exact partition the backend must enforce and report |
| `memory :knowledge, limit: ...` | `5` | Maximum retrieved items |
| Memory `max_bytes` | `8_000` | Canonical budget for returned items |
| Memory binding `tenant_id` | Required | Retrieval tenant, not an authority grant |
| `semantic_cache :routing, learn: ...` | `false` | `:review` may save a quarantined example after a confirmed result; it never auto-approves |

History `keep` accepts 1–1,000 messages; Memory `limit` accepts 1–100 items.
Each window's byte budget accepts 1–1,048,576. The combined Agent context is
also bounded to 65,536 bytes.

Loaded items must cite available Evidence in the authenticated Turn.
These limits reduce the context shown to the agent. They do not erase ledger
entries or hide relevant authority facts.

Direct `History.load/2` supports a `before` cursor for paging.
The Agent declaration loads the latest window; a handler does not supply
that cursor through `history`.

See [explicit chat persistence](agents-and-dsl.md#history-and-memory).

### Cache process settings

Start the cache with its exact identity and capacity:

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

`profile_ref` is especially important: equal vector lengths do not mean
the vectors came from compatible encoders.

Instance wiring adds `server` with the same namespace/profile.
Definition and flow come from the published plan.
For multiple partitions, pass a map from complete bindings to already-created
server addresses. Startup does not create partitions for you.

### Cache queries and review

Direct `SemanticCache.lookup` takes `text`, `vector`, `profile_ref`,
`labels` and optional `limit` (default 5; range 1–32).

Router input instead uses
`%{"text" => text, "embedding" => vector, "profile_ref" => ref}`.
The bridge translates that shape and requests up to 32 nominations.

Exact supports plain text. Native lookup needs an existing vector.
A missing vector skips the method; it does not trigger an encoder call.

Writes supply `text`, `label` and, for native search, `embedding` and
`profile_ref`. Approval applies to one exact revision. Editing removes
approval.

Example paging uses `limit` (default 100, range 1–500), `after` (last ID)
and `verified` (`nil`, `true`, `false`).
Snapshot restore needs a fresh destination and preserves review state.
It is a cache snapshot, not an authority checkpoint.

The application owns review, embedding generation and training.
See [cache wiring](agents-and-dsl.md#semantic-cache-and-classification).

## Instance startup and calls

### Start the state owner

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

Supply either initial `state/component_states` or a `checkpoint`, not both.
They are competing sources of initial state.

The Instance owns the last completed value. A monitored worker handles one
mutation at a time, with waiting work in a FIFO queue.
The job limit does not bound arbitrary provider allocations or mailbox bytes.

### Choose the call for your intention

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

There are three different waits:

1. An Instance call timeout controls how long a caller waits for a response.
2. `advance`'s `wait:` can return a known pending ticket.
3. The provider timeout is configured in your executor/integration.

None of these alone proves cancellation or no effect.
`turn`, `propose` and `checkpoint` wait indefinitely at the Instance call
level. See [pending work](integration-and-streaming.md#a-host-owned-interaction-without-a-stream-runtime).

Worker/Vigil startup adds `input`, `definition`, `supervisor` and
`opening`, with optional `state`, `bindings`, `adapters`.
The opening contains authenticated `context`, promise `attributes`,
authority `candidate` and optional call `options`.
See [reusable work](agent-recipes.md#reusable-skills-workers-and-vigils).

## Domain options

A Domain connects shared authority, storage and execution. These are host
options, not per-model settings.

Pass them to the `Spectre.Domain` child spec.
For `Spectre.start_domain(domain_ref, store, opts)`, the Domain and store are
arguments instead.

### Connect the boundaries

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

The foundation fields are `genesis`, `principals`, `root_mandates`,
`surface`, `host_profile`, `constitution`, `genesis_verifier`.
[Host setup](host-setup.md#prepare-the-foundation) explains them.
The host must choose its Duty policy; a model preference cannot supply it.

### Time, context and recovery

| Field | Default / required | Purpose |
| --- | --- | --- |
| `clock` | Spectre.Clock.System | Module exposing trusted Unix milliseconds via `now/0` |
| `clock_tolerance_ms` | `60_000` | Allowed drift against monotonic elapsed time; `:infinity` disables this guard |
| `id_source` | Spectre.Id.UUIDv7 | Module exposing `generate/0` for occurrence IDs; not a replacement for canonical content hashes |
| `context` | Omitted | Optional recent-Evidence window, detailed below |
| `recovery_policy` | Omitted | Host witness/incident adapter; cannot override invalid core state |
| `recovery_timeout` | `5_000` ms | Positive callback time bound for recovery policy |

With `context` configured, its defaults are `max_events: 100`,
`max_evidence: 50`, `max_bytes: 256_000`. Each accepts zero.

The first counts ledger positions, the second selected contextual Evidence,
and the third encoded bytes. With no `context` option, there is no automatic
recent-history selection. This window does not bound lifetime projection RAM.

### Queues, batching and advanced settings

| Field | Default / required | Purpose |
| --- | --- | --- |
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

The retry options here resolve ledger conflicts/uncertainty.
They do not repeat an executor's external action.

The Domain's internal process name comes from its Registry and `domain_ref`.
Do not override it as another independent identity.

Leave `generation`, `grant_secret` and `checkout_receipt_secret` omitted
in ordinary setup: fresh values are generated at boot. The overrides are for
controlled wiring/tests and must not enter a Definition.

Finally, backend settings belong to their own adapters.
A Disk `directory`, ETS `server` and PostgreSQL `repo` are different
resources. See [storage configuration](storage-and-recovery.md#ledger-adapters-and-batch-reads).
