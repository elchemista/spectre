# Architecture and the GAM boundary

This guide describes the current 0.4 runtime, not the removed 0.3 runtime.
Read [the governed surface](../GOVERNED_SURFACE.md) for the deployment assumptions
and [the capability inventory](capabilities.md) for what is not implemented.
The [Governed Act Model](../GOVERNED_ACT_MODEL.md) is the normative model;
this guide maps its concepts to code.

## Four different kinds of fact

| Concept | Question answered | Main modules |
| --- | --- | --- |
| Mandate | Who may exercise which authority, for whom, with what limits? | `Spectre.Mandate`, `Spectre.Kernel.Authority`, `Spectre.Mandate.Ancestry` |
| Evidence | What supports or contradicts a proposition, from which sources? | `Spectre.Evidence`, `Spectre.Condition`, `Spectre.Kernel.Recognition` |
| Act | Which exact consequence was admitted and durably authorized? | `Spectre.Candidate`, `Spectre.Decision`, `Spectre.Act`, `Spectre.Kernel.Commit` |
| Duty | What causal debt remains, and who can independently dispose of it? | `Spectre.Duty`, `Spectre.Duty.Derive`, `Spectre.Duty.Disposition`; internal checks in `lib/spectre/duty/authority.ex` |

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

`Spectre.turn/3` records observations before invoking the Mind. The Mind runs
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
`lib/spectre/presentation/approval/assumptions.ex` checks the assumption graph,
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
