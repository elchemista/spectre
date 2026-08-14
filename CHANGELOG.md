# Changelog

All notable changes to Spectre are documented in this file. The project follows
[Semantic Versioning](https://semver.org/); while the version is below `1.0`, a
minor release may contain documented breaking API changes. Patch releases
preserve the documented safe contract; they may tighten behavior that violated
an already-published security or privacy invariant, with the correction and
migration called out explicitly below.

## 0.3.1 — 2026-08-14

### Added

- Added `Spectre.Instance.CheckpointStore.Conformance`, an
  ExUnit-independent adapter contract that exercises canonical create and
  update writes, exact retry/readback, stale-write rejection, a concurrent
  compare-and-swap single-winner race, semantic validation, and restart
  readback through the public Checkpoint Store boundary.
- Added the read-only `Spectre.Doctor` contract, stable privacy-safe
  `Spectre.Doctor.Report`, and `mix spectre.doctor`. Doctor verifies the
  running versions and Foundation matrix and can inspect an Agent, Stack or
  package matrix, and Checkpoint Store callback shape without starting package
  resources or invoking store I/O. Text and JSON output share contract version
  1; strict mode turns warnings into a failing command result.
- Added guarded generators for a minimal Agent, Stack Installable, and
  process-local development Checkpoint Store, each with an executable public
  contract test. The generators support dry runs and explicit regular-file
  replacement while rejecting invalid module aliases and unsafe filesystem
  targets.

### Changed

- Canonicalized tagged map entries produced by `Spectre.Run.Value` and
  `Spectre.State.Codec` before they enter State, Run, or Instance checkpoints.
  The 0.3.0 writers preserved BEAM map enumeration order, which can depend on
  module and atom load order and could therefore give the same portable
  checkpoint different Foundation digests in separate VMs. Existing readers
  remain unchanged and accept the previously emitted entry order; 0.3.1
  writers now emit one stable order.
- Routed Definition activation through the existing Instance canonical commit
  seam before the established durable checkpoint barrier. Activation keeps the
  same owner, generation, authority, and persistence fences; no parallel state
  or history model was introduced.
- Hardened Instance observability so telemetry measurements remain numeric,
  Instance and event identifiers are represented by stable digests, and raw
  adapter failures are reduced to reason classes. The configured telemetry
  callback and optional `:telemetry` sink are failure-isolated from one another
  and from the runtime. This is a privacy and telemetry-contract correction:
  consumers that matched the unsafe 0.3.0 payload shape must read identifiers
  and reason classes from metadata instead of relying on raw terms or
  non-numeric measurements.
- Made `Spectre.Instance.info/1` and `Spectre.checkpoint_status/1` passive
  monitoring reads. Checkpoint status now exposes a redacted error class and
  reconciliation projection instead of raw adapter reasons; Monitor logs also
  classify failures and digest caller identifiers. Code that matched a raw
  `checkpoint_status().error` term must migrate to the stable error class; raw
  adapter reasons are deliberately no longer a public diagnostic value. Direct
  host-facing state and domain reads remain activity and re-arm the idle timer.
- Added `outcome: :failed | :ambiguous` to `:checkpoint_failed` telemetry so an
  abnormal checkpoint task exit or another reconciliation-fenced result is not
  mistaken for a proven terminal write failure. The event suffix remains
  unchanged for consumer compatibility. Healthy checkpoint status now also
  preserves `error: nil` instead of fabricating an `:error` class.
- Hardened sensitive-data inspection for canonical payloads whose map keys are
  arbitrary binary values. Non-UTF-8 keys use byte-safe ASCII normalization
  while their nested values remain recursively inspected, so sensitive ASCII
  markers are still recognized instead of raising inside Unicode regular
  expressions.
- Updated the Vettore runtime dependency to `~> 0.3.3`, including its latest
  correctness, concurrency, and native-index fixes. All other direct
  dependencies were already at their latest compatible releases.
- Raised the repository coverage floor from 93% to 95% with contract tests for
  durable Instance failures, Definition trust boundaries, governance,
  conformance runners, Morph/Reflection, and portable artifact corruption.
- Updated the normative public API manifest, operational guidance, testing
  guide, and release metadata for `0.3.1`. The patch retains the opt-in
  `:required` operation-trigger correlation policy; the default remains
  `:legacy` for patch-release compatibility.

### Compatibility correction

- The observability hardening above removes no public callable and enforces the
  privacy-safe telemetry promise already documented by 0.3.0. Raw identifiers,
  adapter errors, and non-numeric measurements were an implementation defect,
  not a supported observability contract. The patch intentionally stops
  exposing those values and documents the safe replacement fields.

- Corrected the Instance compatibility statement published with 0.3.0. The
  released 0.3.0 codec emits and accepts only the distinct
  `"spectre/instance-checkpoint"` format-tagged Instance checkpoint version 2;
  it does not read the retired untagged 0.2.x Instance schemas 1 through 4.
  Spectre 0.3.1 preserves that shipped behavior and freezes an actual 0.3.0
  version-2 fixture instead of claiming an unimplemented migration.
- State remains writer 5 with readers 2 through 5, and Run remains writer 2
  with readers 1 and 2. The append-only 0.2.x fixtures and the original 0.3.0
  release notes remain historical evidence; this erratum does not rewrite
  them, add an implicit legacy decoder, or add a second durable record format.
- Foundation digests are identities of the current-writer representation, not
  hashes of the source bytes. Re-verifying a 0.3.0 checkpoint under 0.3.1 can
  therefore produce the corrected canonical-map digest while preserving the
  decoded checkpoint and its revision.

## 0.3.0 — 2026-08-12

### Added

- Added `LLMS.md`, a machine-oriented guide shipped in the Hex package and
  included in ExDoc's generated `llms.txt`, covering the public entry points,
  host boundaries, Morph lifecycle, runtime-data rules, and test expectations.

- Added `Spectre.Morph`, a host-governed evolution API whose canonical Surface
  bounds runtime Skill mount, replacement, and disable proposals. Morph derives
  real replay obligations from immutable Definition diffs, requires independent
  evaluation and approval, and revalidates the exact Candidate at activation
  and recovery. Runtime data never becomes executable code or authority.

- Added the opt-in `Spectre.Experience` plane with deterministic redaction,
  explicit retention and expiry, immutable content-addressed evidence, a
  verified snapshot transport, a Store behaviour, and a volatile reference
  adapter. Experience remains observational and never becomes canonical
  Instance state or authorization evidence by itself.
- Added policy-gated `Spectre.Reflection` and the mechanical
  `Spectre.Projection.Reflection`. Declared, Effective and Observed facts are
  kept separate; Skill instructions are quoted data; missing evidence is
  reported as a limitation; transported projections are regenerated against
  exact Definition, Manifest, Activation and Experience inputs.
- Added `Spectre.Reflection.Operation`, a compiled no-side-effect operation
  whose stores, Activation and policy can only come from trusted host
  configuration.
- Added the propositional `Spectre.Forge` plane, compiled multi-model critic
  contract, content-bound critiques, independent oracle approvals, portable
  Proposal lineage, a fixed ChangeSet operation subset, and explicit rebase.
  Critic prose and model agreement never become evaluation evidence by
  themselves.
- Added full external-evidence binding to governed ChangeSets. Composer and
  activation now reject changed Reflection or Experience digests; a rebase
  always creates a new Proposal identity.
- Extended Foundation Conformance with exact Reflection and Forge verification
  and added the permanent `0.3.0/reflective-runtime-v1.json` identity
  fixture.

### Safety and compatibility

- Forge has no publication, approval or activation API. It cannot address
  authority, kernel policy, evaluator registration, projection generators, or
  executable code. Only the existing Store-backed governance chain can turn a
  Proposal's ChangeSet into an activated Candidate.
- Experience recording is denied unless the host passes `enabled?: true`.
  Built-in sensitive keys cannot be removed, non-retained evidence is purged
  only after explicit confirmation, and every load path revalidates full
  content identity.
- Reflection requires an explicit host policy, actor, purpose and observation
  time. Its generator never calls a model or assembles inspected prompt
  fragments as active instructions.
- Load and transport boundaries reject ambiguous atom/string fields, duplicate
  snapshot evidence, duplicate keyword options, mutated Proposal structs,
  oversized Forge collections, nonportable data and digest drift.
- State remains writer v5, Run writer v2 and canonical Instance checkpoints
  schema 4. All guaranteed 0.1.6–0.2.9 fixtures remain readable and unchanged;
  the module-first Agent/Skill path continues to lower into the single
  canonical runtime model.
- This branch changes only the `spectre` core. Satellite `spectre_*` packages
  retain ownership of their version constraints and adapter conformance.

## 0.2.9 — 2026-08-11

### Added

- Added portable, content-addressed `Spectre.Governance.ChangeSet` proposals
  bound to an exact active Candidate, Definition, authority epoch, activation
  receipt, and evidence digest. The built-in vocabulary covers runtime Skill
  mount/replace/disable, bounded mutable config and applicability, Candidate
  evaluation cases, and registered state migrations.
- Added the trusted `Spectre.Governance.Composer` and compiled handler Registry.
  Composition re-reads the parent, forbids authority expansion, derives the
  closure, publishes Definition/Manifest and gate receipts, and returns only a
  governed Candidate Ref.
- Added the governed Candidate state machine, content-addressed gate receipts,
  fixed checker-version policy, protected-corpus evaluation delta, deterministic
  Human Report projection, separate review and approval commits, and risk-based
  human approval.
- Added governed activation/recovery verification and ancestor-only
  `Spectre.rollback/3` through the existing owner fence and activation-generation
  CAS.
- Added conservative administered GC plans that retain by default, verify a
  complete ancestry-closed inventory, and leave deletion to a revalidated
  backend transaction or lease.
- Added the permanent 0.2.9 governance compatibility fixture and conformance
  matrix.

### Safety and scope

- ChangeSets and operation payloads are bounded JSON-shaped data and cannot
  carry code references, callbacks, structs, processes, authority grants, or
  arbitrary dispatch targets. Host-registered handlers are constrained to
  their declared component classes.
- Publication, review, approval, activation, rollback, and GC remain explicit
  host actions. Approval never activates a Candidate; rollback never claims to
  reverse external Effects; a GC plan never deletes artifacts.
- Candidate-authored evaluation cases have zero protected-score weight and
  must pass as additional obligations. Gate and approval receipts are re-read
  and rebound to exact Definition, closure, corpus, checker, validity-window,
  and proposal identities immediately before activation.
- Protected-corpus identity covers complete canonical evaluation cases rather
  than ids alone, and the portable delta carries those cases so JSON reload can
  recompute the binding independently.
- Required gate options can only add to the constitutional gate floor. The
  protected corpus is non-empty and digest-bound, evaluation thresholds cannot
  permit score loss or regressions, and every attached receipt is revalidated
  for status, time, and checker policy even when its class is optional.
  Semantic-live evidence requires profile, variability, and expiry.
- Prompt and applicability ceilings are sealed into Candidate identity and
  reverified during activation and recovery. Aggregate prompt reservations are
  capped, wildcard applicability cannot pass a finite scope ceiling, and a
  governed replacement cannot erase the mounted anti-hijack corpus. Every
  governed mount must carry a valid id and inline Definition snapshot.
- Added explicit host rejection for evaluated Candidates, exact transported GC
  lineage reasons and Candidate live-reference classes, plus linear Candidate
  parent verification for deep immutable lineages.
- Partial GC inventories remain conservative retain-only evidence. Expired
  semantic-live evidence still blocks new activation; recovery and rollback
  expose separate explicit host-only emergency flags that retain all other
  receipt verification.
- Evaluated Candidate state now persists the verified Human Report and complete
  evaluation delta, and activation binds the stored delta to its gate receipt,
  making the review evidence auditable from the Store alone.
- Candidate portable loads reject unknown fields, ambiguous keyword input,
  malformed governance state, and promotion chains that skip a review state.
- State remains writer v5, Run remains writer v2, and canonical Instance
  checkpoints remain schema 4. Existing bootstrap Candidates remain valid and
  all earlier compatibility fixtures are unchanged.
- Because 0.2.9 had not been tagged while these contracts were finalized,
  untagged development governance artifacts must be regenerated; schema 1 now
  denotes the release contract recorded by the permanent fixture.

## 0.2.8 — 2026-08-10

### Added

- Added `Spectre.Execution.Program` and `Spectre.Execution.Work`: compiled
  and JSON-shaped precise Work declarations now normalize into one portable,
  content-addressed IR with step, infer, decide, bounded repeat, completion,
  failure, explicit budgets, mutable paths, and registered migrations.
- Added Work components and handlers to canonical runtime Skills. Work,
  predicate, inference, and migration refs resolve only against the host
  Agent's existing operation registry and effective authority.
- Added `Spectre.Execution.Materializer`,
  `Spectre.Execution.Materialization`, and
  `Spectre.Projection.Execution` to seal exact Definition, Program, input,
  route, continuation, plan, receipt, and budget lineage before execution.
- Added effective `Spectre.Prompt.Receipt` evidence and safe scalar-only
  `Spectre.Prompt.Materializer` rendering for inference nodes.
- Added `Spectre.start_execution/3` and Instance integration on the existing
  fenced operation runtime, including normal pause/amend/resume/stop, query,
  checkpoint, retry, and recovery behavior.
- Added typed Flow ↔ Work and Work → Work handoffs, pure registered state
  migration preparation/commit receipts, and deterministic rehearsal/replay
  that cannot dispatch real Effects.
- Added the permanent 0.2.8 data-driven Program and no-Effect rehearsal
  compatibility fixture.

### Migration and safety

- Authored execution data cannot contain modules, Erlang/Elixir MFAs,
  callbacks, AST, functions, PIDs, references, executors, authority grants, or
  security policy. Ambiguous atom/string fields and non-portable values fail
  closed.
- Programs require reachable terminating graphs, positive step/attempt
  limits, and bounded repeats. Pure predicates and migrations are verified
  against registered operation contracts; inference requires a registered
  cognitive operation.
- Work cost and duration are capped by the current Authority Envelope.
  Amendments can change only declared state paths and retain exact Program,
  input, history, Definition, materialization, prompt receipts, and projection
  pins across resume and recovery.
- Canonical object expressions reload idempotently; negative list indices are
  rejected. Materialization, projection, prompt, handoff, migration, and
  rehearsal digests are recomputed at their load/admission boundaries.
- Program inference enums, authored literals, metadata, and migration
  operation refs now have one JSON-stable canonical form, so
  `to_data -> JSON -> from_data` preserves exact Program/receipt identity.
  Authored expression depth is capped before digesting and constructors return
  errors instead of raising on hostile nesting.
- Materialization verification now rebinds projection mount, route,
  continuation, input, and mandatory input evidence exactly as construction
  does. Prompt placeholders are rendered in one pass, so resolved values are
  never reinterpreted as template syntax.
- Prompt materialization now revalidates the canonical fragment digest,
  rejects dynamic fragments with a typed error, and reserves the `input`
  namespace so context data cannot spoof input evidence. Malformed prompt
  plans fail closed instead of reaching hashing code with invalid bytes.
- Rehearsal uses the canonical evidence-digest domain whenever its values are
  canonical, matching Execution projections and materializations. Structured
  portable operation receipts use a deterministic tagged fallback in both
  rehearsal and migration instead of raising during receipt construction.
- Execution Closure and migration-receipt load paths now require exact durable
  fields and valid version identities. Malformed keyword input is rejected
  without raising, while inert ids such as `timer` and `queue` remain stable
  even when an Erlang module with the same name is loaded.
- Raw canonical Skill mounts require `origin: :runtime`; compiled Skills must
  enter through their trusted module/Definition path and cannot use origin
  data to skip runtime load policy.
- Fixed retry-budget accounting so `retries: 0` permits the initial attempt
  and an authorized retry is not denied after its counter is consumed.
- State remains writer v5, Run remains writer v2, and canonical Instance
  checkpoints remain schema 4. All prior conformance and runtime Skill gates
  remain in the release suite.

### Scope

- Data Work reuses `Spectre.Operation.Runtime`; no parallel executor or
  checkpoint model was added. Publication, Activation, Skill lifecycle, and
  Effect execution remain explicit host actions.
- Generated callbacks, goal hierarchies, autonomous Forge behavior,
  reflection, and governance remain outside this gate.

## 0.2.7 — 2026-08-10

### Added

- Added `Spectre.Skill.Definition`, a single canonical wrapper for compiled and
  runtime-authored Skills. Equivalent origins expose equal semantic IR while
  exact Refs retain origin and publisher provenance.
- Added data-only runtime Flows with exact routing, closed reply fragments, and
  references to operations already registered by the host Agent. The compiled
  DSL gains `requires_operation/2` and `call_operation/2` over the same IR.
- Added structured `Spectre.Skill.Applicability`, executable positive/negative
  anti-hijack examples, and fail-closed conflict and ambiguity handling.
- Added versioned per-Skill prompt budgets and
  `Spectre.Router.IndexProfile`. Runtime mount reserves the kernel window,
  checks granted budget classes, and accounts for retained draining
  generations.
- Added `Spectre.Projection.Routing`, a deterministic non-executable projection
  with a profile-bound disposable cache key.
- Added immutable `Spectre.Skill.Runtime` mount, replace, and disable lifecycle
  with authority capabilities, revision CAS, exact Definition-pinned
  continuations, and drain completion.
- Added the permanent 0.2.7 runtime Skill and Routing projection fixture.

### Migration and safety

- Runtime Definitions reject code references, AST, executable prompt
  templates, uncapped fragments, undeclared or unregistered operations,
  ambiguous routes, failed anti-hijack examples, and authority gaps.
- Runtime operation handlers return a portable `Spectre.Operation.Request`;
  Spectre does not execute it or widen authority. Publication, activation, and
  lifecycle changes remain explicit host actions.
- Canonical runtime Skill loads rederive prompt usage from the restored
  fragments, require every fragment cap, and reject declared budget counters
  that do not exactly match the derived evidence.
- Runtime fragment placement, trust, provenance, and granted priority are
  assigned by Spectre rather than accepted from authored data. Composite
  placeholder values fail closed instead of invoking arbitrary string
  protocols.
- JSON string operation references resolve only to matching IDs already in the
  host Agent registry, without creating atoms. Forbidden applicability tags
  remain exclusion filters and cannot increase routing specificity.
- Canonical Skill structs and prebuilt `Spectre.Skill.Definition` values are
  revalidated at load and mount. Malformed route, requirement, prompt, or
  Routing-projection collections return indexed errors instead of protocol or
  function-clause exceptions.
- Negative anti-hijack examples now fail when one or several routes match.
  Inputs that cannot be normalized return `{:invalid_skill_input, shape}` from
  Skill routing and response boundaries instead of crashing `String.Chars`.
- State remains writer v5, Run remains writer v2, and canonical Instance
  checkpoints remain schema 4. All 0.2.6 foundation and Stack gates remain in
  the release suite.
- Generated callbacks, goal-driven Work, autonomous Forge behavior, empirical
  reflection, and governance remain outside this gate.

## 0.2.6 — 2026-08-10

### Added

- Added `Spectre.Foundation.Conformance`, an ExUnit-independent public gate
  that performs real decode, migration, current validation, and re-encoding
  for State, Run, and canonical Instance checkpoints.
- Added Definition/Manifest conformance for canonical bytes and compiled
  module-first values, including stable Definition, authority, closure, and
  Manifest evidence.
- Added `Spectre.Stack.Conformance`, which compiles a complete satellite
  package matrix through the real Stack invariants and rejects incompatible
  versions, missing requirements, conflicts, duplicate packages, and
  capability ownership collisions.
- Added a permanent 0.2.6 golden fixture that pins every core compatibility
  artifact from 0.1.6 through 0.2.5 and the complete schema/contract matrix.

### Migration and safety

- No durable writer changed: State remains v5, Run remains v2, and canonical
  Instance checkpoints remain schema 4. Definition, Manifest, Candidate, and
  Stack contracts are unchanged.
- Added integrated compiled Agent+Skill, legacy migration, corruption, and
  Stack composition coverage. Existing restart, activation-race, owner-fence,
  and ambiguous persistence suites remain part of the same release gate.
- Added migration documentation for 0.2.6 and an explicit 0.2-to-0.3 ledger.
  Runtime-authored values must lower into the existing canonical models, and
  publication or activation remains an explicit host action.

## 0.2.5 — 2026-08-10

### Added

- Added first-class `Spectre.Skill.StateBinding` values with stable Skill id,
  state schema Ref, generation, branch and parent ids, owning Definition Ref,
  revision CAS, owner fence, active/dormant status, retention, provenance, and
  a deterministic binding receipt.
- Added canonical per-Skill state with one selected branch and retained branch
  history. Public APIs inspect branches, update active state through schema,
  generation, revision, authority, and owner fences, and transition dormant
  branches through conservative retention.
- Added activation-time `:skill_state_transitions`. `:resume`, `:fork`,
  `:migrate`, and `:abandon` are explicit choices whenever a target Definition
  already owns a dormant branch; `:init` is accepted only when no such branch
  exists.
- Added a permanent 0.2.5 compatibility fixture with dormant A and selected B
  branches bound to a schema-4 Activation.

### Migration and safety

- Canonical checkpoint writers now emit schema 4. Readers accept schemas 1
  through 4; schema-3 checkpoints gain an empty Skill-state section in memory.
- Definition A → B → A never merges private Skill state. A rollback with a
  dormant target branch fails until the host explicitly resumes, forks,
  migrates, or abandons it. Branch identity and parent lineage remain distinct
  even when schemas match.
- Writes outside the selected Skill id, branch, owner Definition, or exact
  state schema are rejected before commit. A saved generation or owner fence
  cannot authorize a stale write.
- GC is conservative. Active or Activation-referenced branches cannot become
  eligible; retained Runs, operations, and child branches also block
  collection. Purge retains a receipt-bearing tombstone and clears only state.
- Definition artifact purge now treats every non-purged Skill-state binding as
  a live reference.

### Scope

- State migration data is supplied by trusted host code; this release does not
  run migration callbacks or copy/merge state implicitly. Shared Memory,
  artifacts, external Effects, and experience evidence are not private Skill
  state and are never rolled back by this mechanism.

## 0.2.4 — 2026-08-10

### Added

- Added portable `Spectre.Event.Envelope` values for input, reply, policy,
  Flow, Work, Vigil, and global events. Admission records the continuation,
  origin evidence, selected Definition owner, activation generation, current
  authority epoch, owner fence, canonical revision, and deterministic receipt.
- Added same-sequencer event admission. Run and operation continuations retain
  their pinned Definition owner across activation; unowned input uses the
  active Definition. Missing, mismatched, expired, ambiguous, or incompatible
  events are durably quarantined instead of rebound.
- Added `Spectre.Instance.Lifecycle` with independent admission, authority,
  retention, and activation axes plus revision CAS and monotonic transitions.
  Public helpers expose drain, revoke, explicit transitions, and inspection.
- Added bounded admitted and quarantine windows to canonical Instance state,
  and pinned Definition metadata to operation loops.

### Migration and safety

- Canonical checkpoint writers now emit schema 3. Readers accept schemas 1,
  2, and 3; a schema-2 Activation is migrated to an equivalent active
  lifecycle record in memory.
- Draining blocks new Turns and operations but preserves already-owned
  continuations. Closing blocks continuations. Revocation advances the current
  authority epoch and blocks admission, continuation, commit, retry, Effect
  dispatch, and operation dispatch.
- A Run's stored authority epoch is lineage only. Runtime authorization always
  consults the current lifecycle and current Instance owner fence.
- Added a permanent 0.2.4 compatibility fixture covering schema-3 event
  admission, quarantine, and Definition lifecycle recovery.

### Scope

- First-class Skill state generations, branches, rollback, and retention are
  intentionally deferred to 0.2.5. Event delivery and transport authenticity
  remain host-owned; this release records their portable evidence.

## 0.2.3 — 2026-08-10

### Added

- Added stable AgentRef/Instance identity. Compiled module, declared Definition
  version, and Stack digest are resolver hints rather than parts of the durable
  key; the former key remains available only for controlled migration.
- Added immutable bootstrap `Spectre.Definition.Candidate` artifacts and
  content-addressed Candidate Refs. Activation always re-reads Candidate,
  Definition, Manifest, and publication receipt from the trusted Definition
  Store.
- Added canonical `Spectre.Instance.Activation` snapshots with generation CAS,
  authority epoch, execution closure, state bindings, owner fencing token,
  provenance, and deterministic activation receipt.
- Added the `Spectre.Instance.Owner` lease/fencing host contract. The bundled
  local adapter is explicitly single-owner; distributed ownership remains a
  host responsibility.
- Added Definition pins to Runs and durable retention of all live Run
  continuations in canonical Instance checkpoints. New Runs use the current
  Activation while open Runs preserve their original Definition across
  activation and restart.
- Added a permanent 0.2.3 compatibility fixture containing checkpoint schema
  2, an Activation, and its pinned Run.

### Migration and safety

- Run checkpoint and canonical checkpoint writers now emit schema 2. Readers
  accept schemas 1 and 2 and immediately migrate legacy values to the current
  in-memory representation.
- `Spectre.Instance.CheckpointStore.migrate_instance_key/6` lets core invoke an
  adapter's `migrate_instance_key/5` callback to atomically move an exact
  legacy checkpoint to its stable key. Core verifies the migrated target
  byte-for-byte and rejects divergent old/new histories.
- Activation is committed synchronously when durable checkpointing is enabled.
  Stale generations, authority/fencing rollback, ambiguous writes, missing
  artifacts, or closure drift fail closed.
- Owner-fence loss blocks admission, canonical commit, activation, and Effect
  or operation dispatch before the external boundary.

### Scope

- The Candidate is a trusted-host bootstrap record, not a governed promotion
  state machine. Runtime-authored ChangeSets, gate receipts, self-activation,
  event ownership across Definition versions, first-class Skill state, and
  distributed consensus remain outside this release.

## 0.2.2 — 2026-08-10

### Added

- Added Manifest Contract V2, which seals one canonical Definition Ref with a
  fail-closed `Spectre.Authority.Envelope`, a complete
  `Spectre.Execution.Closure`, publisher/provenance Refs, lineage, and the exact
  component-contract registry snapshot used during composition.
- Added the trusted component contract registry. Unknown
  `must_understand` schemas are rejected; opaque advisory and descriptive
  components are preserved without acquiring semantics.
- Added `Spectre.Definition.Store`, the volatile in-memory reference adapter,
  and an adapter-neutral conformance contract. Publication is immutable,
  idempotent, parent-aware, receipt-bearing, and verified by read-back.
- Added `Spectre.Definition.Resolver`. Resolution revalidates Definition,
  Manifest, receipt, component contracts, and caller-supplied build
  observations; missing or changed code is blocked by default and never hidden.
- Added Stack Contract V2 plus a read-only V1 adapter. V1 declarations remain
  authority requests and receive grants only through an explicit host ceiling.
- Added a Manifest V2 compatibility fixture exercised on both supported
  OTP/Elixir CI combinations.

### Safety

- Durable checkpoint configuration is rejected when paired with a volatile
  Definition Store.
- Activation preparation must re-read a published Definition, Manifest, and
  receipt from the Store. A crash after publish and before the future activation
  CAS can therefore leave only an immutable orphan artifact.
- Manifest schema maps use textual keys and closed enum decoding, preserving
  atom-safe decode before implementation modules have been loaded.

### Scope

- This release does not yet change Agent identity, activate Definitions, write
  checkpoint schema 2, promote Candidates, or execute runtime-authored Skills.
  Those remain separate gated milestones.

## 0.2.1 — 2026-08-10

### Added

- Added `Spectre.Canonical.Value`, a versioned portable binary codec with
  explicit value tags, canonical map-key ordering, atom-safe decode, bounded
  collections/depth/size, and opt-in struct allowlists. Definition identity no
  longer depends on Erlang external-term encoding.
- Added typed `Spectre.Definition.Canonical` envelopes,
  `Spectre.Definition.Component`, and content-addressed
  `Spectre.Definition.Ref` values. Compiled Agents and mounted Skills lower into
  one IR through `Spectre.Definition.canonical/2`.
- Compiled prompt assets now lower into governed canonical fragments carrying
  closed placeholder schemas, provenance, visibility, trust, priority, budget,
  token cap, condition Ref, and digest metadata.
- Added the deterministic projection interface and exact
  `Spectre.Projection.Audit` generator. Projection digests bind Definition Ref,
  generator ID/version, optional evidence digest, and content.
- Added a canonical Definition compatibility fixture exercised by both OTP 28
  and OTP 29 CI jobs, plus property coverage for map order and cross-process
  digest stability.

### Safety

- Canonical data rejects PID, port, reference, function, improper-list,
  non-byte-aligned bitstring, non-finite float, unknown atom, noncanonical map,
  executable EEx, and known secret-bearing configuration boundaries.
- Executable compiled callbacks and modules lower to explicit `compiled_only`
  code Refs. Runtime Definition data contains neither callback functions nor
  quoted AST.
- Definition and projection digests attest integrity only; they do not imply
  publisher trust, approval, or current authority.

### Compatibility

- Existing module-first Agents, Skills, Instance identity, Runs, checkpoints,
  and execution semantics remain unchanged. Definition Store, Manifest V2,
  activation, and runtime-authored Skills are not part of this release.

## 0.2.0 — 2026-08-08

### Fixed

- Reply sanitization now uses Unicode-safe, case-insensitive matching without
  applying byte offsets from a transformed string to the original reply.
- `before_action` suppression is scoped to the owning Run, provider-qualified
  guard references no longer raise, and `protect`/`after_action` declarations
  retain source order.
- Canonical checkpoints, Run values, and journal JSON maps now encode every
  JSONB-hostile binary consistently and restore journal phase/time values.
- Semantic-cache candidates retain their intended arbitration precedence;
  post-LLM clarification results remain clarifications; unloaded custom
  arbitrators are loaded before capability checks.
- The bounded Turn dispatcher delivers a terminal decision reached by its
  final allowed transition instead of reporting a loop overflow after effects
  have committed.
- Invalid Flow state and malformed Instance intents now fail only their owning
  Run/intent instead of terminating the whole Instance. Concurrent `execute/3`
  calls also reject while another Run advances without staling the waiting Run.
- Recovery now honors retry policy and budget for crashed attempts, journal
  buffering preserves FIFO order within a partition, and deferred/digest
  delivery receipts can be re-authorized after their delivery window opens.
- Terminal operation loops, correlations, Subject link intents, semantic-cache
  online examples, and rule-example embeddings now have bounded retention or
  bounded reusable caches with explicit configuration.
- History limits and summarizer callbacks are validated, operational budgets
  reject unknown keys, and stable term digests use deterministic encoding.
- Instance idle shutdown is re-armed after operational/checkpoint activity;
  malformed optional offline semantic-cache sources degrade at runtime with a
  warning instead of disabling routing.
- Nested-flow prompt injections now retain the flow path where each injection
  was declared. Parent and child `start`/`end` operations therefore compose as
  proper nested scopes, and repeated inner-flow names under different parents
  no longer collapse onto the same runtime scope.
- A warm `Spectre.Classifier` now accepts every GenServer name form (including
  `{:via, ...}`), retains its startup embedding/configuration options for later
  calls, and still lets explicit per-call options override them.
- Training and semantic-cache datasets skip unsupported label shapes instead
  of raising. JSONL and multi-source accumulation is now linear, and semantic
  cache imports index cacheable rules by label once instead of scanning every
  rule for every row.
- `classifier ..., context: ...` and `label_examples: ...` now remain in the
  classifier configuration instead of leaking into adapter options, so both
  settings reach default and custom classifier prompts. Flow-taxonomy prompt
  rendering now builds an ordered tree in one pass, avoiding quadratic work
  across large sets of sibling flows.
- A failed probabilistic strategy (LLM classifier error, arbitration failure)
  now recovers to the agent's declared `:UNKNOWN` rule when it has a handler
  whose checks match the input, so the agent's explicit fallback behavior runs
  instead of returning an unroutable lowercase `:unknown` route and an empty
  reply. The recovered route uses strategy `:unknown_fallback` and preserves
  the failure metadata (`local`, `fallback_error`).
- `Spectre.State.Codec` output is now safe for JSON database columns:
  binaries that JSONB cannot store verbatim (invalid UTF-8 or embedded zero
  bytes, e.g. compact lifecycle ids) are encoded as tagged Base64 values and
  decoded transparently. Legacy payloads still decode.
- `Spectre.Classifier` interns its artifact schema atoms when the module
  loads, so release VMs decode classifier artifacts with `binary_to_term/2`
  in `:safe` mode without the host pre-loading internal Spectre atoms.

### Added

- `Spectre.Reply.Sanitizer` strips Spectre control tokens (`<al>`,
  `<intent>`, `<reply>` wrappers, `INTENT:`/`AL:` control lines, `<think>`
  blocks, HTML comments) from model output before it becomes `reply_text`.
  It is the runtime default wherever LLM text turns into a visible reply;
  pass `sanitize_reply: false` to opt out, or mount an action planner with
  `clean_reply/3` to own the cleanup entirely.
- `Spectre.LLM.provider_opts/2` strips every runtime-context key the core
  attaches to adapter calls (plus any `spectre_*`-prefixed key), so LLM
  adapters forward provider options without maintaining hand-written
  allowlists. `Spectre.LLM.runtime_opt_keys/0` exposes the list.
- `Spectre.Router.SemanticCache.learn_eligibility/2` and `learnable?/2` own
  the learn-safety rules hosts used to re-implement: routes served from the
  cache itself, rules without `learn: true`, and routes staging
  policy-protected actions are skipped with an explaining reason.
- `Spectre.Router.SemanticCache.update_example/4` edits an online learned
  example in place (`:text` re-embeds through the configured adapter,
  `:label` must stay cacheable, `:verified` toggles review state), replacing
  the snapshot round-trip hosts used for edits. Custom cache adapters may
  implement the new optional `update_example/4` callback.
- `Spectre.Journal.Record.to_json_map/1` renders a journal record as a
  JSON-safe, string-keyed map (atoms→strings, tuples→lists, calendar types→
  ISO-8601, fallback `inspect/2`) for direct persistence by store adapters.
- `Spectre.ensure_instance/4` starts or reuses an Instance and always returns
  `{:ok, pid}` or `{:error, reason}`, normalizing the supervisor's richer
  start shapes. `Spectre.Instance.trace_id/1` exposes the per-generation
  trace identifier without reaching into `info/1`.

- `Spectre.Turn.Dispatcher` drives a `%Spectre.Turn{}` decision to a delivered
  outcome so hosts stop hand-writing the decision switch: it delivers replies,
  auto-resolves policies the host can already satisfy
  (`satisfied_resolution/2`), executes pending effects, and falls back to
  `fallback_reply/2`/`no_response/2` for empty outcomes. `deliver_reply/3` is
  the only required callback and the loop is bounded.
- `before_action :action, run: {M, :f}` registers a pre-execution guard on the
  action lifecycle. Guards run after routing, planning, and policy approval,
  and can return `{:suppress, reply_text}` to cancel the pending effect and
  answer with a normal reply (emitting `:effect_suppressed`), or `{:error,
  reason}` to fail closed. `:all` matches every action; Skills cannot declare
  guards; invalid guard replies fail the effect instead of allowing it.
- `history limit, summary: {M, :f}` folds chat-history entries evicted from
  the window into a rolling summary under `state.data.chat_summary` instead
  of dropping them. The default LLM classifier prompt shows the summary as
  "Conversation summary (older turns)" next to the recent chat, and custom
  classifier prompts receive it as the `chat_summary` assign. A crashing
  summarizer keeps the previous summary and never blocks the turn.

- `flow` declarations now nest. A nested flow is a taxonomy grouping: rules
  keep the full path in the new `Spectre.Rule.flow_path` field while `flow`
  stays the innermost name, labels stay globally unique, and `inject`
  declarations plus flow options are inherited by nested flows.
  `state.current_flow` now prioritizes by membership in `flow_path`, so
  setting a parent flow prioritizes its whole subtree. String flows passed to
  `Spectre.Router.evaluate/3` resolve nested flow names as well.
- The default LLM fallback classifier prompt groups visible labels by flow
  taxonomy (indented, one `flow/` header per group) instead of a flat list.
  Each label carries up to two example phrases from its `embedding:`/`bag:`/
  `jaro:` declarations (`classifier ..., label_examples: n` tunes the cap,
  `0` disables). The prompt now also states the routed agent module, an
  optional agent description (`classifier ..., context: "..."`), and the
  active `state.current_flow` rendered as its full nested path. Custom
  classifier prompt functions receive the new `label_tree`, `agent`,
  `agent_context`, and `active_flow` assigns, and the tree rendering is
  exposed as `Spectre.Router.LLMClassifier.label_tree/3`. Agents with no
  flows keep the flat label list.

- Added `SYSTEM.md`, documenting the 0.2.0 package compatibility matrix,
  composition patterns, complete Stack examples, library responsibilities,
  and the architectural rationale for a small core with explicit satellites.
- Directive Definitions can declare `can_start: [:work]` and return stable
  `start_loops` intents from `apply_result/4`; the parent Result, child Work,
  controls, correlations, and events commit atomically at one canonical
  revision. Re-proposing an intent whose Work already exists with the same
  parent and intent provenance is a committed no-op reported as
  `already_started: true`; only an id collision with different provenance
  rejects the transition.
- Definition security can opt into exact external-trigger fencing with
  `trigger_correlation: :required` or the compatible
  `require_trigger_correlation: true` spelling. Public loop views now expose
  `wait_ref`, and committed trigger events distinguish `:exact` from
  compatible `:legacy` correlation.
- Publication policy now controls progress and blocker projection
  independently with `publish_progress` and `publish_blocker`.

### Fixed

- A terminal outcome (failure, crash, completion, budget, expiry) that races a
  pending safe pause/update command now rejects that command with
  `:loop_terminal` inside the same committed transition, instead of leaving
  the loop permanently wedged behind an uncommittable control plane.
- Checkpoints taken between a committed Result and the advancement of a
  pending safe pause/update command are accepted on restart; recovery resumes
  the control sequence instead of stopping the Instance with
  `:operational_recovery_failed`.
- A retry allowed by policy but denied by an exhausted budget or a passed
  expiry now produces the typed `:budget_exhausted`/`:expired` outcome with
  limit and consumption, instead of a generic `:failed` outcome.
- Duplicate control commands re-arm the Instance idle timer like every other
  control reply.

### Changed

- Accepted uncorrelated 0.2.x triggers emit
  `[:spectre, :instance, :uncorrelated_operation_trigger]` telemetry so hosts
  can migrate before correlation becomes strict by default in 0.3.0. The
  telemetry now also covers legacy triggers delivered through durable
  `:trigger` control commands, not only direct trigger calls.
- Documented the fixed replay and retention windows: 512 canonical journal
  transitions, 1,024 applied change ids, 128 completed control commands per
  loop, and 512 committed operational events.
- Cognitive operations must declare a closed `domain` or an `output`
  validator; a spec with neither is rejected as
  `{:unbounded_cognitive_operation, id}`.
- Documented the `reason`, `act` and `work` Flow verbs and the deprecation
  path of the legacy `ask` verb in the DSL and migration guides.

### Safety

- Work starts attempted directly by any operational Runner, including through
  the isolated executor call boundary, are rejected; only Agent-side Directive
  reducer intents can create Work from an operational transition.

### Added

- Added versioned `Spectre.Work` and `Spectre.Vigil` Definitions on one shared
  operational runtime, plus support for authorized external controllers.
- Added a closed operation catalog for registered functions, Actions, Effects,
  planners, and finite-domain cognitive operations.
- Added temporary one-attempt Runners under dynamic supervision, with Agent
  ownership, epoch and fencing validation, progress throttling, timeout,
  retry, crash recovery, and side-effect reconciliation.
- Added durable pause, update, update-and-resume, resume, renew, stop, and
  trigger commands with revision, provenance, and idempotency checks.
- Added typed budgets and terminal outcomes for completion, cancellation,
  expiry, failure, budget exhaustion, and ambiguous external outcomes.
- Added read-only loop views, deterministic selectors, visibility checks,
  committed operational events, local subscriptions, and optional routing of
  selected events through normal Flow handling.
- Added selective post-commit operation memory and artifact publication
  policies.
- Added consent, revocation, destination policy, deduplication, rate limits,
  quiet hours, digest decisions, and durable delivery receipts without moving
  transport I/O into core.
- Added typed canonical sections for Flow, Work, Vigil, external controllers,
  loop control, correlations, and committed events.
- Added authorized read/write snapshots, section-fenced change sets,
  monotonic commits, deterministic stale-conflict rejection, idempotent change
  identifiers, and a bounded transition journal.
- Added a strict portable checkpoint codec that preserves canonical and
  per-section revisions, correlations, transition history, and applied-change
  receipts across restart.
- Added a compare-and-swap checkpoint store boundary, asynchronous coalesced
  persistence, flush/status APIs, and explicit reconciliation after an
  ambiguous write outcome.
- Added an executable full-system Agent fixture covering Flow-started Work,
  conversational inspection and update, Vigil registration and control,
  operational-event routing, failure isolation, and joint checkpoint recovery.

### Changed

- `Spectre.Instance` is now the sole local owner of both conversational and
  operational canonical state for one `AgentRef + Subject`.
- Explicit operation idempotency keys now survive Action and Effect dispatcher
  boundaries.
- Generic map input without a `text` field is retained as raw structured input
  with empty text instead of raising through `String.Chars`.
- Agent Definitions can register application operations and opt selected
  committed operation events back into the normal Flow router.
- Agent Definition validation now accepts every public route handler supported
  by the DSL and Runner, including `reason/2`, `act/2`, and `work/2`.

### Safety

- Canonical restore validates loop/control correspondence, Definition
  compatibility, event revisions, Subject ownership, correlations, consent,
  delivery receipts, and portable values before the Instance starts.
- Stale, duplicate, foreign-epoch, wrong-fence, wrong-generation, and
  semantically invalid Runner messages are rejected before commit.
- Unknown non-idempotent side-effect outcomes are never retried automatically.
- Runtime values never create atoms from untrusted strings; closed decoders use
  existing atoms only. Ordinary atom serialization continues to use
  `Atom.to_string/1`.

### Compatibility

- `Spectre.State`, `Spectre.Run`, Flow, Effect, Invocation, Session, and Turn
  keep their 0.1.6 roles. Work is a separate operational domain and does not
  rename Run.
- State v5 and Run v1 recovery fixtures remain permanent compatibility tests.
- See `docs/MIGRATING_TO_0_2.md` for canonical checkpoint adapters and
  incremental operational adoption.

## 0.1.6 — 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and uniform release documentation.
- Added no runtime functionality and made no intentional breaking API change.

## 0.1.5 — 2026-07-30

### Added

- Per-Run lifecycle ownership inside `Spectre.Instance`: staged Effects and
  policy Awaitables now carry their owning `run_id`, allowing several retained
  Runs to wait independently on policy or execution boundaries.
- Conversation-aware policy resumption selects the matching Run from channel
  origin metadata. The legacy no-origin shortcut remains available when
  exactly one policy boundary is open; ambiguous input fails closed.
- State schema v5 persists Run ownership and supports bounded collections of
  independent pending Effects and Awaitables. Schema v2-v4 snapshots remain
  readable and legacy unowned lifecycle is claimed by its first Instance Run.
- `Spectre.Context.lifecycle_run_id/1` and `Spectre.Effect.bind_run/2` give
  extension-owned Effect builders the same per-Run lifecycle contract used by
  core Actions.

### Compatibility

- Stateless calls and conversation-scoped `Spectre.Session` keep their
  single-lifecycle behavior; Run ownership is enabled only by
  `Spectre.Instance`.
- Capability execution remains serialized by the Instance state lock. Calls
  arriving during an Invocation stay queued and continue from the latest
  committed State after the capability returns.
- Prism and ordinary provider callbacks remain synchronous inside one bounded
  Move worker. Generic provider Invocations still require a later serializable
  mid-turn continuation.

### Fixed

- A policy or Effect boundary owned by one Run no longer rejects unrelated
  Runs with `:instance_lifecycle_locked`.
- Resuming a retained Run rebases it onto the latest shared Instance State
  without losing other Runs' pending lifecycle or rolling persistence
  revisions backward.
- Policy acceptance, rejection, retry exhaustion, and Effect execution now
  mutate only the explicitly owned lifecycle entries.

## 0.1.4 — 2026-07-30

### Added

- Subject-scoped `Spectre.Instance` processes keyed by the portable
  `Spectre.AgentRef + Spectre.Subject` pair, with race-safe lookup and
  get-or-start through the application Registry.
- An Instance-owned multi-Run scheduler with a deduplicated FIFO ready queue,
  one mailbox-scheduled Move at a time, retained Run projections, bounded
  terminal tombstones, and first-boundary `Spectre.Turn` replies.
- A stable opaque `AgentRef + Subject` state scope plus privacy-safe tracking
  of multiple channel conversation origins within the same Instance.
- Correlated in-flight Effect/Action Invocation workers and internal
  `Spectre.Invocation.Receipt` fencing across Instance generation, Run
  revision, Invocation id, and dispatch id. Foreign, stale, duplicate, and
  late receipts cannot mutate Instance state.
- `Spectre.ExternalIdentity`, `Spectre.LinkIntent`, `Spectre.SubjectLink`, and
  `Spectre.Subject.Registry` for explicit Agent-scoped identity resolution,
  bounded one-time challenges, optional source confirmation, conflict
  rejection, revocation, and privacy-safe Journal commits.
- Public `Spectre.instance/4`, `lookup_instance/3`, and `resume/4` APIs.
  `Spectre.summon/1,3` select the Instance runtime when an explicit `:subject`
  is supplied.

### Compatibility

- Conversation-scoped `Spectre.Session` remains available unchanged when
  `:subject` is omitted.
- Ordinary user input resumes the exact policy-owning Run. Effect execution
  remains an explicit Invocation boundary.
- The single active Effect constraint remains on global `Spectre.State` in
  this release. Instance serializes that lifecycle boundary; moving it onto
  each Run is the next lifecycle phase.
- Prism and ordinary provider calls remain synchronous inside one bounded Move
  worker. The Instance mailbox stays responsive, but ready Runs wait for that
  Move or its provider timeout; generic provider Invocations require a later
  serializable mid-turn continuation.

### Fixed

- Run start, normalization, and initial scheduling no longer block the
  Instance GenServer or observe stale committed State.
- Duplicate and failed Run starts cannot overwrite retained Runs or exhaust
  bounded capacity; terminal history and tombstones remain bounded.
- Internal reply completion cannot roll shared Instance State back after
  another Run commits.
- Queued callers are released if another Run opens the global lifecycle lock,
  and abnormal workers fail only their fenced Run.
- Portable-value validation rejects improper lists without crashing the
  Subject Registry.

## 0.1.3 — 2026-07-29

### Added

- A serializable `%Spectre.Run{}` continuation and the closed
  `Runtime.start/3 -> advance/2 -> resume/3` protocol.
- Revision-fenced `Spectre.Run.Ref`, `Spectre.Run.Boundary`, and
  `Spectre.Invocation` values, plus transport-safe `Spectre.Run.Request`
  policy projections.
- Versioned, atom-free Run checkpoint/restore with raw-envelope stripping,
  typed logical Route projection, lifecycle validation, encoded-size limits,
  and fail-closed rejection of PID, Port, reference, and function values in
  authoritative data.
- A public `Spectre.Turn` projection with `ref`, `boundary`, and `observable`
  fields using the closed reply/awaiting/needs vocabulary; transport
  idempotency can use `Spectre.Run.Ref.token/1`.
- Privacy-safe Run lifecycle journal events, selectable with `events: [:run]`.
- An ordered, optional `Spectre.Turn.Handler` boundary for external
  conversational runtimes. Open Spectre policies retain precedence; typed
  replies cannot replace state, routes, effects, or awaitables; failures and
  timeouts fail closed.
- Integration guidance that defines `Spectre.turn/3` as the canonical local
  host contract while keeping input decoding, Skills, memory, actions,
  pre-route ownership, telemetry/journaling, durable workflows, and
  agent-protocol transport on separate extension surfaces.

### Fixed

- Semantic-cache collection cleanup now follows Vettore 0.3.2's dedicated
  supervised ETS ownership model.
- Accepted exact semantic-cache hits now skip later vector search, and built-in
  semantic search loads persisted row embeddings instead of issuing one remote
  embedding request per cached row. Classifier training and cache snapshots
  persist the vectors needed for request-time lookup, and online learning
  reuses the query vector instead of embedding the same input twice.
- Semantic-cache index processes now terminate with their cache owner, so an
  owner restart cannot leave orphaned Vettore collections behind.
- Invoked state callbacks that crash, exit, throw, are killed, time out, or
  return malformed results are now treated as ambiguous writes. Sessions retain
  the candidate state until durable reconciliation instead of silently moving
  back to the previous revision.
- Strict persistence-journal failures now carry the already committed result,
  and Sessions retain it so an audit outage after compare-and-set cannot cause
  state rollback or duplicate work on the old revision.
- The application supervisor now tolerates a bounded burst across cache and
  journal children instead of stopping the whole `:spectre` application while
  those independent workers are being restarted.

## 0.1.2 — 2026-07-28

### Added

- `Spectre.Stack` with package-local install DSL, immutable compiled
  definitions, dependency ordering, compatibility/conflict validation, and
  deterministic manifest digests.
- Versioned `Spectre.Stack.Installable` and
  `Spectre.Stack.Contract.V1` contracts for ecosystem packages.
- Logical, version-fenced `Spectre.Stack.Ref` values and caller-owned runtime
  supervision for explicitly declared resources.
- Logical `stack:` references on Agent definitions, resolved only when the
  Stack is used, with compile-time rejection of Skill-owned infrastructure.
- Explicit legacy adapters for `Spectre.Extension.Mount` and
  `Spectre.Action.Provider.Mount`.

### Security and behavior guarantees

- Package manifests and compiled configuration reject PID, port, reference,
  and function values.
- Installed Actions are not automatically exposed to the Agent planner or
  authorized for execution.
- Stack runtimes have no default global name, and stale resource Refs cannot
  resolve against another definition.

## 0.1.0 — 2026-07-20

First public preview.

### Added

- OTP-native Agent and Skill DSL with flows, interrupts, input pipelines,
  prompt injection, actions, policies, mounted skills, state, memory, journal,
  classifier, embedding, and session configuration.
- Evidence-based routing through regex, bag distance, Jaro distance,
  embeddings, local classifiers, exact and vector semantic cache, LLM
  classification, and deterministic arbitration.
- A canonical lifecycle kernel for staging, approving, rejecting, cancelling,
  expiring, completing, failing, and replaying effects and awaitables.
- Explicit two-boundary action execution: policy approval changes state;
  `Spectre.Execution` invokes the host capability only after the approved state
  can be committed.
- Optimistic state revisions, versioned state codecs, stale-session protection,
  idempotent terminal replay, and explicit ambiguous-persistence results.
- Pure policy matching shared by user input and trusted host resolutions.
- Structured prompt plans that preserve instruction, context-data, and task
  trust through capable model adapters, with a marked legacy string format.
- Built-in learned semantic cache backed by Vettore, including online review,
  verification, relabel, deletion, snapshot, restore, bounded index ownership,
  and optional local FastEmbed integration.
- Versioned, privacy-safe journal records for arbitration, policies, lifecycle,
  execution, and persistence, with redaction, sampling, retention metadata,
  synchronous or buffered delivery, and configurable failure policy.
- Privacy-safe provider boundaries with timeouts, worker cancellation,
  normalized failures, fallback models, telemetry, and route-evaluation
  receipts.
- Routing evaluation APIs and Mix tasks for datasets, classifier training,
  model download, and CI evaluation reports.
- Ten-agent strategy matrix covering 800 routing scenarios, including 600
  malformed, unmatched, invalid-flow, invalid-pipeline, and corrupted-state
  cases. The full suite contains 1,177 passing tests and exceeds 90% line
  coverage.

### Security and behavior guarantees

- Policy acceptance cannot be supplied by an ordinary classifier route while a
  policy awaitable is open.
- A `:waiting_policy` effect is never executable.
- Dynamic prompt providers may write only trusted-as-data context fragments.
- Prompt and state deserialization reject unknown or unsafe runtime values.
- Journal, telemetry, evaluation receipts, and provider failures omit raw
  prompts, model output, effect arguments, and stack traces by default.

### Compatibility

- Requires Elixir `~> 1.19`.
- Vettore is a required dependency.
- ExFastembed and SpectreKinetic integrations are optional and detected or
  configured by the host application.
