# Architecture and the GAM boundary

This guide describes the current 0.4 runtime, not the removed 0.3 runtime.
Read [the governed surface](../GOVERNED_SURFACE.md) for the deployment assumptions
and [the capability inventory](capabilities.md) for what is not implemented.
The [Governed Act Model](../GOVERNED_ACT_MODEL.md) is the normative model;
this guide maps its concepts to code.

## Start with the problem, not the implementation

An agent proposes a €50 refund. Three different questions follow:

1. **Is it a sensible suggestion?** Your handlers, Router and optional models
   help answer this. They may still be wrong.
2. **May this exact refund be attempted?** The kernel checks the declared
   class, Mandate, evidence, recipients, purpose, consent and available budget.
3. **Did the refund happen?** The executor's observations answer this after
   the recorded authorization. A lost response may leave it unresolved.

The new kernel keeps these questions separate. It is not an LLM safety prompt,
Router, provider SDK or background agent loop. It is a deterministic function
over an exact proposal and verified facts; the surrounding Domain makes the
result durable before any governed capability is released.

The host defines `refund.issue` as its own action class. That name has no magic
meaning to the kernel. Its Surface explains the action's payload and powers;
its Mandate limits who may propose it. The executor implements the actual
payment-service contract. Changing a model or Router does not require changing
those core admission rules.

## What is a Row?

A `Spectre.Row` is a **small boolean summary of the types of power an action
uses**. It is not a database row, a route, an ACL or a permission granted by the
Agent. The name comes from an effect row: a set of declared effects.

For an external order lookup, `attempt: true, read: true` means “attempt an
external operation that reads a resource”. The Mandate must allow both powers
and also cover the exact class, order, proposer, time and purpose. An allowed
power type is not permission to act on every resource of that type.

| Dimension | Meaning in an application |
| --- | --- |
| `attempt` | Carry out an external attempt through dispatch/executor |
| `observe` | Establish an observation through a declared boundary |
| `read` | Read a resource |
| `write` | Change a resource |
| `disclose` | Release information to specified destinations |
| `spend` | Consume a declared resource budget |
| `delegate` | Transfer narrower authority, not duplicate it |
| `govern` | Change governed authority/configuration through a recorded action |
| `present` | Present material relevant to consent |

Omitted dimensions are false. Rows do not contain money amounts, order IDs or
provider credentials. Those belong to the consequence, its exact bindings,
the Mandate and Meter accounting. The kernel checks that the Candidate's Row
matches its Surface class and fits within the Mandate's ceiling.

You normally declare the Row in host setup, **not in Agent handlers**.
`RequestBuilder` obtains it from the actual Surface. The
[lookup example](host-setup.md#connect-a-handler-to-a-governed-action) shows the
Row, a closed consequence contract and the host binding map together.

## A few names worth keeping separate

| Name | Plain meaning |
| --- | --- |
| Surface | The versioned catalog of actions the application governs |
| Consequence | The exact proposed payload: which order, recipient, amount or model request |
| Condition | A fact that must be established from appropriate Evidence, not simply asserted by the model |
| Meter | Accounting for a limited quantity; a reservation is not yet settled spending |
| Candidate | A complete proposal before authorization; contains no execution credential |
| Decision | The kernel's answer: admitted, refused, undecidable or unknown class |
| Attempt | The recorded beginning of an admitted external operation; distinct from success |
| Outcome | What the observed result supports: success, failure, definite no effect or ambiguity |
| Grant | An internal short-lived execution capability, not a value handlers should hold |
| Definition | Immutable agent code/configuration publication; not an active process |
| Constitution | The Domain's pinned Duty/disposition rules, not the agent's system prompt |

The four GAM records below connect those concepts. Ordinary authoring does not
require constructing each record manually for every turn.

## Four different kinds of fact

| Concept | Question answered | Main modules |
| --- | --- | --- |
| Mandate | Who may exercise which authority, for whom, with what limits? | `Spectre.Mandate`, `Spectre.Kernel.Authority`, `Spectre.Mandate.Ancestry` |
| Evidence | What supports or contradicts a proposition, from which sources? | `Spectre.Evidence`, `Spectre.Condition`, `Spectre.Kernel.Recognition` |
| Act | Which exact consequence was admitted and durably authorized? | `Spectre.Candidate`, `Spectre.Decision`, `Spectre.Act`, `Spectre.Kernel.Commit` |
| Duty | What causal debt remains, and who can independently dispose of it? | `Spectre.Duty`, `Spectre.Duty.Derive`, `Spectre.Duty.Disposition`; internal checks in `lib/spectre/core/duty/authority.ex` |

A Candidate is not an Act. Evidence that a user wants something is not a
Mandate to do it. A successful function return is not proof of an external
effect. An expired timer is not proof that a Duty has been discharged.

## From input to an external effect

```text
Application intake / fixed Ingress
  → authenticated Scope + observed Evidence
  → Mind / local Router → Candidate                     Zone M
  → Kernel evaluation → Decision                       pure boundary
  → atomic commit: Act + accounting + dispatch facts    Domain / store
  → internal Grant consumption → durable Attempt
  → Broker → Executor → external system                effect boundary
  → bound Evidence + Outcome → accounting / Duty
```

For the handler DSL, `Instance.turn/3` opens an authenticated Turn, runs the
selected flow and prepares requests; `Instance.advance/3` submits one choice.
The optional model is itself reached through a request, not called by the
kernel. See [the combinations](agent-recipes.md).

For the lower-level custom-Mind path, `Spectre.turn/3` records observations before invoking the Mind. The Mind runs
outside the Domain sequencer, receives a capability-free `Spectre.Mind.Turn`,
and returns proposals. Routing happens here, before kernel evaluation.

`Spectre.propose/3` takes one proposal through admission and, where applicable,
execution. The sequencer orders it against the current verified prefix.
`Spectre.Kernel.evaluate/4` performs no I/O: it checks the Surface, authenticated
claims, authority, Conditions, consent, information flow and Meter availability.

An admitted world Act does not immediately call the executor. Its commit must
be confirmed first. Grant consumption records an Attempt before the broker
releases a capability. `Spectre.Attempt.Runner` invokes the selected executor;
it does not retry an uncertain external effect. Intrinsic governance Acts can
complete through their recorded transitions without an external Attempt.

Finally, bound observations support an Outcome. Settlement, release and
suspension are different accounting transitions. Ambiguity can retain a Meter
reservation and derive a Duty. Late observations remain recordable after
revocation: revocation prevents future authority, not historical truth.

## One semantics, two drivers

`Spectre.GovernedAct.Fold` verifies canonical entries and applies deterministic
transitions. `Spectre.Domain.Projection` drives live/recovery replay;
`Spectre.Audit` drives an independently obtained canonical export. They share
the rules, not a trusted copy of the live read model.

| Code family | Responsibility |
| --- | --- |
| `Spectre.Domain.Event`, `Spectre.Canonical.Value`, `Spectre.Ledger.Entry` | Event grammar, portable encoding, identities and chain verification |
| `Spectre.GovernedAct.Transition.Foundation` | Genesis and governed artifact revisions |
| `Spectre.GovernedAct.Transition.Authority` | Subtractive delegation, restriction, revocation and Meter transfer |
| `Spectre.GovernedAct.Transition.Admission` | Recheck Decision/Act bindings during replay |
| `Spectre.GovernedAct.Transition.Execution` | Dispatch and Attempt lifecycle |
| `Spectre.GovernedAct.Transition.Information` | Evidence and information lineage |
| `Spectre.GovernedAct.Transition.Duty` | Opening, authorized disposition and associated accounting |
| `Spectre.GovernedAct.Batch`, `Spectre.GovernedAct.Completeness` | Cross-entry atomicity and complete-prefix invariants |
| `Spectre.GovernedAct.Commit`, `Spectre.Domain.Transaction` | Pure prepared batch versus host-side durable commit/recovery |
| `Spectre.Domain.Command.Durability` | Command preflight and recovery of required materializations |

Do not add business policy by pattern-matching a new application class in the
kernel. Declare the class in a `Spectre.Surface`, with its consequence contract,
and implement its host executor. The built-in governance classes have explicit
runtime semantics. `Spectre.Consequence.Validator` resolves a closed registry;
ledger data cannot name arbitrary executable validation code.

### Following the commit boundary in code

`Spectre.Kernel.Commit.payloads/3` turns an evaluation into proposed event data.
It does not persist it. `Spectre.GovernedAct.Commit.prepare/4` builds the exact
entry batch and folds it against the current prefix. Its resulting State is
still provisional. `Spectre.Domain.Transaction.append_exact/4` owns the write;
`Spectre.Domain.Recovery` confirms its receipt or reads back the actual durable
records. An exact receipt match permits reuse of the prepared fold, not a
second interpretation of the same events. A failed confirmation is not proof
that nothing was written.

Only then may `Spectre.Domain.Command.Execution` mint a Grant. Consumption
checks current authority again and records an Attempt before issuing the
checkout receipt. This is why neither a valid template, a kernel result nor a
prepared transaction can substitute for the durable execution boundary.

On the return path, the classifier in `lib/spectre/core/attempt/runner/observation.ex`
interprets the executor's report; `lib/spectre/core/outcome/attestation.ex` supplies
the shared causal binding checks used by classification and replay. Relevant contradictory
Evidence may support an ambiguous Outcome; it cannot establish success.
These checks establish recorded consistency, not a cryptographic signature
or independently authenticated provider identity.

### Public workflows and storage internals

`Spectre` keeps the documented application API. Its internal workflows are
ordinary function calls in the caller's process, not additional Domain owners:

| Source | Responsibility |
| --- | --- |
| `lib/spectre/core/facade/access.ex` | Resolve live Domain addresses, validate host options and issue narrow authenticated queries; rebinding does not renew a Scope's authority or generation |
| `lib/spectre/core/facade/proposal.ex` | Admission, execution orchestration and at most one declared refusal fallback; never retry an uncertain effect |
| `lib/spectre/core/facade/observation.ex` | Record supported late Evidence before its Outcome, without re-executing the original Act |

The disk adapter has a separate physical boundary. In
`lib/spectre/core/ledger/store/disk.ex`, one owner serializes writes, checks prefix
continuity and maintains its indexes. `disk/frame.ex` checks the bounded
canonical storage envelope and batch identity; `disk/file_io.ex` performs file
reads, writes and durability barriers. A valid frame alone is neither a durable
commit nor a GAM authorization. Corrupt frames are rejected; only the owner's
explicit incomplete-tail policy permits truncation.

## Finding code in the repository

- `lib/spectre/agents/`: Agent/Skill/Stack DSL, Instance, Router, templates,
  context and optional integration adapters. Change authoring here.
- `lib/spectre/core/`: governed records, kernel, Domain sequencing, replay,
  execution boundary, ledger, erasure and audit. This owns GAM correctness.
- `lib/spectre.ex`: public facade connecting host calls to those boundaries.
- `lib/mix/tasks/`: development commands such as scaffolding, routing evaluation,
  diagnostics and migration generation; not an agent runtime.

Directories separate responsibilities; module names remain `Spectre.Agent`,
`Spectre.Kernel`, and so on. There is no second DSL-specific kernel.

There is no `lib/package` layer. `package/0` in `mix.exs` is Mix configuration:
it lists the source files and public guides shipped to Hex, plus package
metadata. It starts no processes and installs no optional integrations. The
release check in `scripts/check_package.exs` verifies that the built package
matches that manifest byte-for-byte; plans, checkpoints and development build
artifacts are not part of the distribution.

## What owns state?

| Owner | Contains | Is not |
| --- | --- | --- |
| Domain history | Committed causal records, authority and accounting facts | A conversation buffer that can drop old obligations |
| `Spectre.GovernedAct.State` | Verified, rebuildable projection and indexes | An independent source of authority |
| Domain sequencer | Ordering, current projection, host configuration, timers | The Mind or a media transport |
| `Spectre.Instance` | One authenticated Scope, selected Definition, opaque local value | Another kernel or execution checkpoint |
| Host workers | Input processing, planning, provider/transport integration | Permission to bypass an Act for a governed effect |

One Domain has one logical order; several Instances may share it. An Instance
is one persistent OTP child, supervised by the application. A Definition is
immutable data, not a process. `Spectre.Attempt.Runner` runs one governed
attempt path; it is not an agent registry or scheduler.

Slow Ingress callbacks run in bounded temporary tasks, outside the sequencer.
The Domain owns their links and monitors; worker failure returns an error,
normal shutdown stops pending work, and an abnormal owner exit kills its tasks.
There is no nested Task.Supervisor or automatic callback retry. Completion is
revalidated against the current generation before anything is committed.
This isolates callback latency, not arbitrary same-BEAM code or transport load.

The projection currently retains historical records. `ReadIndex`,
`AuthorityIndex`, the Duty frontier and the erasure index reduce repeated
semantic scans, but do not make total memory bounded. Ledger paging and disk
compression do not remove the live projection's heap cost. See
[storage and recovery](storage-and-recovery.md).

## Foundation, governance and authority

Genesis pins the initial Principals, root Mandates, Surface, HostProfile and
Constitution. The host supplies the external recognition of that foundation;
constructing a valid record is not such recognition.

`Spectre.Foundation.new/2` is optional assembly assistance: it derives those
links from explicit records and uses the same pure bootstrap fold. It returns
ordinary host options, chooses no authority policy and never calls a verifier.
Actual bootstrap and recovery still require external recognition through the
configured Genesis verifier.

Root authority is introduced only at Genesis. At runtime,
`Spectre.delegate_mandate/4` can create a narrower child; the historical
`issue_mandate/4` name is an alias for delegation, not root issuance.
Delegation transfers Meter availability rather than duplicating it.

Surface, HostProfile and Definition revisions are governed transitions with
exact predecessor checks. The Constitution is deliberately immutable within a
Domain in this implementation. Changing it requires a new Domain and explicit
host treatment of the old obligations, not editing the stored Genesis.

`Spectre.Governance` builds administrative Candidates. The facade's
`revise_*`, `revoke_mandate`, `dispose_duty` and related functions submit them
through normal admission. None is an administrative bypass. A host must grant
the necessary class, target, Scope and accountable-party coverage; an
authenticated administrator name alone grants nothing.

## Information and consent

Observed, derived and generated Evidence retain different provenance. Derived
data cannot silently discard parents or their labels. A router score, model
answer or transcription is not automatically an observed fact.

`Spectre.Presentation` stores exact consent material. Preparing it does not show
it. `Spectre.show_presentation/4` mediates delivery, and approval is bound to the
material Candidate occurrence and qualified Evidence, not just an identical
string. The internal evaluator in
`lib/spectre/core/presentation/approval/assumptions.ex` checks the assumption graph,
including contradictory or unavailable support.

`Spectre.Declassification` changes allowed information flow through an
authorized new record; it does not rewrite provenance. `Spectre.Erasure`
records a governed payload-erasure request and its verifiability consequences.
Deleting bytes does not erase the Act, its Duty or its causal tombstone.

## Where to read next

- [Agent authoring](agents-and-dsl.md): every current DSL declaration, Skills,
  routing, Extension ports, Morph and Instance.
- [Input, streaming and control](integration-and-streaming.md): what the app
  decides, which builders it uses, and what chunking/cancel cannot mean.
- [Storage and recovery](storage-and-recovery.md): three distinct store roles,
  failure handling, clocks and audit.
- [Testing and release](testing-and-release.md): how to test these boundaries,
  including failures that static analysis cannot find.
