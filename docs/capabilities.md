# Current capabilities and completion boundaries

This inventory describes executable 0.4 APIs, not promises inferred from module
names or the previous runtime. "Implemented" does not mean production-qualified.
The checkout is unreleased. The [governed surface](../GOVERNED_SURFACE.md)
defines what the implementation actually guarantees.

## Available now

| Capability | Entry points | Important boundary |
| --- | --- | --- |
| Pure admission and shared replay/audit semantics | `Spectre.Kernel`, `Spectre.GovernedAct.Fold`, `Spectre.Audit` | Store/provider truth is not proven by deterministic replay |
| Authority attenuation, restriction, revocation | `Spectre.Mandate`, governance facade | No runtime root-authority creation |
| Meter accounting and independent Duty disposal | `Spectre.Kernel.Meter`, `Spectre.Duty`, `Spectre.dispose_duty/4` | No time-based auto-discharge or generic partial-stream refund |
| Durable Attempt, broker and executor | `Spectre.propose/3`, `Spectre.Attempt.Executor`, `Spectre.Secret.Broker` | No automatic retry of an uncertain effect |
| Consent, presentation and assumption graphs | `Spectre.Presentation`, prepare/show APIs | Exact material/occurrence binding, not future-output blanket approval |
| Labels, declassification and payload erasure | `Spectre.Evidence`, declassification/erasure APIs | Causal history and verifiability debt remain |
| Agent and Skill DSL | `Spectre.Agent`, `Spectre.Skill` | Immutable declarations, not a second runtime |
| Package extension ports | `Spectre.Extension`, `extend` | Explicit host wiring; not a Stack resolver |
| Regex, string-bag, Jaro and custom routing | `Spectre.Router`, `Spectre.Router.Adapter` | Zone M selection only; `via: [:binary]` remains supported |
| Independent named flows | `flow`, `pipe_through`, `Spectre.Agent.Flow` | Reusable host-prepared plans; no inherited routing, hidden handler policy or process per flow |
| Bounded prompt composition | `Spectre.Prompt` | Ordered sources and conservative labels, no code evaluation or implicit inference |
| Structured proposal status | `Spectre.Proposal.Result.status/1` | Admission, Attempt and Outcome remain separate; absence is not failure |
| Static authoring diagnostics | `Spectre.Surface.verify_definition/2`, `Spectre.Error.message/1` | Deferred fields remain explicit; no preauthorization or sensitive error serialization |
| Pure foundation assembly | `Spectre.Foundation.new/2` | Derives Genesis links and reuses bootstrap checks; no authority defaults, verifier callback or I/O |
| Input normalization and Evidence builders | `Spectre.Input.Pipeline`, Ingress/Mind/Executor builders | No prescribed audio/VoIP schema or media engine |
| Behaviour authoring helpers | `use Spectre.Mind`, `Ingress`, `Attempt.Executor`, `Secret.Broker` | Explicit identities and opt-in Mind bridge; no authentication, execution or routing policy generated |
| Pure Morph changesets, diff and forward rollback | `Spectre.Morph`, `Spectre.revise_definition/4` | Governed activation is separate; no hot code/state migration |
| Responsive agent state, serialized work and explicit checkpoints | `Spectre.Instance`, `Spectre.Instance.Checkpoint` | Bounded waiting FIFO and temporary worker; no restoration of Scope authentication or execution facts |
| Promised Work/Vigil scopes | `Spectre.Scope.Opening`, governed `open_scope` | Host schedules work; kernel records promise/debt |
| Pluggable ledger and application stores | Ledger ETS/Disk/Mnesia/Postgres/Mock; `Spectre.Store` | Backend deployment guarantees differ |
| Batch paging and optional lossless compression | `Spectre.Ledger.Reader`, native store callbacks | Not bounded total State or a durable projection checkpoint |
| Recovery hooks, clock guard, offline tools | Recovery Policy, `Spectre.Clock.Guard`, audit/doctor/migration tasks | Cannot override failed semantic verification |
| Scoped inspection and auditability | head/authority/acts/duties queries, export | Not a full live telemetry/event subscription integration |

## Deliberately supplied by the application

- Real authentication, channel security, webhook/receipt verification, credential
  custody, external witnesses and deployment isolation.
- Providers, network transports, text/voice/TTS/VoIP codecs and sessions.
- Media buffering, chunking, worker scheduling and when a material consequence
  should be proposed; see [streaming and control](integration-and-streaming.md).
- Task/Work/Vigil scheduling and operational UI progress.
- Library dependencies and resource startup: Mix, ordinary OTP supervision,
  `extend`, `ports/0` and explicit host wiring. No Stack installer or resolver
  is planned. Doctor checks declared port coverage, not automatic composition.
- Business-class contracts and trustworthy Evidence for business Conditions.
- Payload ingestion/deletion, backups and retention policy across external systems.

These are extension responsibilities, not missing codec features to put into the
kernel. The library must supply usable boundaries/builders and test that host
integrations cannot gain power through ordinary proposal data.

## Still missing or requiring consolidation

| Area | Current gap | Completion criterion |
| --- | --- | --- |
| Long-lived memory | Verified State/history still resides in the sequencer heap | Granular fenced reads/deltas and backend integration; measure both process and store memory |
| Durable projection checkpoints | Ledger suffix/paging exists, but no trusted persistent projection checkpoint | Validate prefix binding/version, refuse corruption and preserve independent audit |
| Public query/control load | No general revision-fenced pagination or uniform bounded queues/timeouts | Bounded work with explicit uncertainty behavior, not silent truncation |
| Higher-level authoring | No public `ask`, `stream`, `steer` or `cancel` API | Only add reusable blocks whose exact GAM semantics and host ownership are established |
| Skill planning | Templates, assets and flows compose; no dedicated applicability/state/budget helper | Reusable planning conventions without another runtime or a second authoritative Meter |
| Work/Vigil drivers | Governed Scope promises exist; reusable operational drivers remain open | Explicit host scheduling, with real pause/resume/failure and Duty tests |
| Advanced Morph | Changesets/diff/rollback and governed revision exist; no review/reflection/Forge workflow | Proposal-only review with governed activation, not arbitrary hot code or state replacement |
| Observability integrations | Inspection and audit exist; no general telemetry subscription contract | Operational events must remain distinct from authorization and observed world facts |
| Release qualification | Full long-history/backend/load/retention qualification still open | Adversarial lifecycle tests, current measurements and all release artifacts/checks |

Constitution revision is not an accidental hidden API: the Constitution is
immutable for a Domain. A new Domain and explicit treatment of old obligations
are required. No 0.3 checkpoint importer or compatibility runtime is promised.
The Governed Holon Model is a future direction, not an implemented 0.4 feature.

## What an honest readiness claim needs

Passing static checks does not show that no executor runs before commit, that
late receipts survive a restart, or that an agent can serve hundreds of users
for months. A test count does not show those things either.

Recent fixes reduce repeated full-history work through incremental Duty,
erasure, evidence and authority indexes, delta payload verification and reuse
of a verified prepared commit. They do not establish bounded memory or qualify
every workload. Historical benchmark failures remain evidence about those
revisions, not current throughput measurements or claims of a completed fix.

Keep this inventory aligned with actual public APIs and update it when a gap is
implemented and tested. Do not mark host-owned integration policy as a hidden
kernel feature just to declare the list complete.
