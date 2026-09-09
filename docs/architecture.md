# Architecture: follow one request

You do not need to understand the whole kernel to write an agent.

Start with this distinction: **the agent suggests what to do; the application
decides what it may do; an executor performs the allowed operation.** Spectre
keeps a record of those steps so that a suggestion cannot quietly become an
action.

This guide follows a refund through that process, then shows where the code
lives. If you want to write a handler first, start with
[building an agent](agents-and-dsl.md). For the exact guarantees and trust
assumptions, keep [the governed surface](../GOVERNED_SURFACE.md) as a reference.

## Start with the problem, not the implementation

A customer says: “Please refund order 42.”

Your agent might propose a €50 refund. That leaves three separate questions:

1. **Is €50 the right suggestion?** Your handler, business logic or model works
   this out. It can still make a mistake.
2. **Is this agent allowed to attempt that refund?** Spectre's kernel checks
   the permission, the order, the supporting facts and the remaining budget.
3. **Did the payment service actually refund the money?** The executor reports
   what it observed. A lost response might leave the answer unknown.

Passing step 1 does not pass step 2. Passing step 2 does not prove step 3.

The name `refund.issue` is an application-defined **class**: a name for one
kind of governed action. Spectre does not contain special business logic for
your refund service. Your application declares the class and supplies the
implementation.

## From input to an external effect

For an Agent written with the DSL, the path looks like this:

```text
Input
  → Router chooses a handler
  → handle_turn prepares a request
  → host calls advance
  → kernel decides whether this exact request is allowed
  → ledger records the authorization
  → executor attempts the operation
  → observations are recorded
  → handle_result decides what to prepare next
```

Routing and model use are optional. A handler can receive structured input
directly. A model can help prepare a request, but the kernel does not call it.
See [agent recipes](agent-recipes.md) for these combinations.

### Before the application submits anything

`Instance.turn/3` processes input and returns prepared requests. Think of a
request as a ticket saying “this is the operation I suggest.” It is not an
execution credential.

The application chooses a ticket and calls `Instance.advance/3`. It may do
that immediately, after a UI interaction, or according to its own workflow.
GAM does not require a human approval for every request.

### When the request is submitted

The kernel checks the complete proposal against the current rules and facts.
It returns a **Decision**. If admitted, the authorized operation is recorded
as an **Act**.

For an external operation, Spectre then records an **Attempt** before asking
the broker for the capability used by the executor. The broker is your
application's credential-access boundary; handlers do not receive its keys.

The ordering matters: a failed or uncertain ledger write must not be treated
as permission to call the external service.

Some governance changes happen entirely through ledger transitions. Those do
not need an external executor Attempt.

### When the service responds—or does not

An **Outcome** records what the observations support. Success, failure,
definite no effect and ambiguity are different results.

If the payment service times out, Spectre does not assume that no money moved.
It does not automatically repeat the refund. Budget may remain held, and an
unresolved obligation—a **Duty**—may need investigation.

A receipt arriving later can still be recorded, even after the agent's
permission has been revoked. Revocation prevents new use of authority; it
does not erase what happened earlier.

## Four different kinds of fact

These are the four names you will encounter most often:

| Name | Read it as | Refund example |
| --- | --- | --- |
| Mandate | Permission with limits | This proposer may refund covered orders within this budget and time window |
| Evidence | Information supporting or contradicting a claim | A payment receipt or a disputed delivery record |
| Act | The exact operation recorded as authorized | Attempt a €50 refund for order 42 |
| Duty | Something that still needs a responsible resolution | Find out whether the timed-out refund happened |

Evidence is not permission. A message saying “the customer asked for it” can
support a fact about the request; it cannot grant refund authority.

A Duty does not disappear because a timer elapsed. Resolving it requires the
appropriate recorded action and authority, including the required independence
from those responsible for the original operation.

## A few names worth keeping separate

### The application, the running agent and the shared rules

- **Host:** your Elixir application and its deployment.
- **Definition:** a published version of an agent's declarations and code
  identity. It is data, not a running process.
- **Instance:** the OTP process holding one agent's local state.
- **Scope:** the authenticated interaction or unit of work that an Instance
  is bound to.
- **Domain:** the shared rules, accounting and ordered history used by one
  or more Scopes.

For example, several support conversations can have separate Instances in the
same tenant Domain. Starting another conversation does not create more refund
budget.

### The proposed operation

A **Candidate** is the complete proposal presented to the kernel. Its
**consequence** describes the actual operation: the order, amount, recipient
or model request.

A **Surface** is the application's catalog of governed classes and their
contracts. A **Condition** says which supporting facts must be established.
A **Meter** accounts for a limited quantity, such as a spend budget.

You usually work with requests and handlers. The authoring layer builds the
Candidate using your request data and the host's bindings; you do not manually
construct every GAM record on every turn.

## What is a Row?

A Row answers one small question: **what kinds of power does this action use?**

It is not a database row or a Router rule. It contains boolean flags, not
money amounts, resource IDs or credentials.

For an external order lookup, `attempt: true, read: true` says:

- an external operation will be attempted;
- that operation reads a resource.

It does **not** say “read any order.” The class, exact target, Mandate and other
checks still limit which order may be read.

| Flag | Meaning |
| --- | --- |
| `attempt` | Attempt an external operation |
| `observe` | Establish an observation through a declared boundary |
| `read` | Read a resource |
| `write` | Change a resource |
| `disclose` | Release information to specified destinations |
| `spend` | Use a limited resource budget |
| `delegate` | Pass on narrower authority |
| `govern` | Make a governed change to authority or configuration |
| `present` | Present material relevant to consent |

Omitted flags are false. The host declares the Row on the Surface class.
The normal request builder reads it from there; an agent handler does not
choose its own powers with a `row:` option.

See [the order-lookup setup](host-setup.md#connect-a-handler-to-a-governed-action)
for the Row alongside its target contract and executor binding.

## What owns state?

There are three kinds of state. Keeping them separate makes integration easier.

### 1. Agent state: “what am I working on?”

The Instance holds your local value and Skill substates. Examples include
the selected order, a draft answer, or the next step in a workflow.

One Instance is one persistent OTP child. Slow mutations run in a temporary
worker so that state reads remain responsive. The host chooses how to supervise
Instances and when to start Workers or Vigils.

A local checkpoint saves application state. It does not restore authentication,
execution credentials or permission to repeat an old effect.

### 2. Governed state: “what is allowed, and what happened?”

The Domain sequencer owns the ordering of changes and its current
**projection**: records and indexes rebuilt from verified ledger entries.

The ledger is the durable history. The projection is a working view of that
history, not a second authority source.

Several Instances can share a Domain. The Mind runs outside the sequencer;
slow ingress callbacks also use temporary tasks owned by the Domain. Their
results are checked again before being accepted.

### 3. Application storage: “where do we keep the data?”

Your adapters choose the databases and services for chat, memory, payloads and
the ledger. Your application owns their supervision, backups and retention.

There is an important current limit: Spectre's own projection retains
historical records in memory. A different ledger backend changes persistence,
not that internal retention. Paging reduces how much ledger data is read at
once; it does not make the projection a bounded cache.

See [storage and recovery](storage-and-recovery.md) for the adapter contracts
and the distinction between host storage policy and library resource limits.

## Foundation, governance and authority

A Domain needs initial rules before it can evaluate its first request.

The **foundation** supplies the actors, root Mandates, Surface, host assumptions
and Duty rules. **Genesis** records the links to those exact initial records.
The host's Genesis verifier says which foundation it recognizes.

`Spectre.Foundation.new/2` helps assemble those links. It does not choose a
budget, invent an administrator or authenticate a signature for you.

Once running:

- delegation may create narrower authority, not a new unrestricted root;
- transferring budget to a child does not leave the same budget available
  to spend on the parent;
- changes to Surface, HostProfile and Definition go through governed actions;
- the Constitution—the Domain's Duty and disposition rules—is immutable
  within that Domain in 0.4.

Changing the Constitution requires a new Domain and explicit handling of the
old obligations. Editing Genesis in the database is not an upgrade procedure.

The facade's `revise_*`, `revoke_mandate` and `dispose_duty` helpers build and
submit normal proposals. An “admin” caller still needs the relevant authority.
The older `issue_mandate/4` name is an alias for delegation, not root issuance.

## Information and consent

Suppose an agent proposes sending a customer's order details to another service.

The system needs more than “the user clicked yes.” It needs to know what
information would be sent, where it would go, and what material the user saw.

A **Presentation** records that material. Preparing one does not show it.
`Spectre.show_presentation/4` handles the declared delivery step. Approval is
bound to the particular proposal and its supporting facts, not just matching
text that could be reused for another occurrence.

Information also keeps its source relationships and labels. A summary or
transcription cannot quietly shed restrictions inherited from its sources.

An authorized **declassification** changes permitted information flow through
a new record. **Erasure** handles deletion of payloads and records its result.
Neither operation rewrites the past or automatically closes related Duties.

## How replay and audit check the same rules

Recovery rebuilds the working state from the ledger. Audit checks a separately
obtained canonical export. Both use the same pure transition rules.

“Canonical” means that records have one defined encoding, so their digests can
be checked consistently. “Fold” means applying entries in order to rebuild
state. Neither term implies that the external provider told the truth.

Sharing these rules avoids maintaining one interpretation for live operation
and another for audit. The auditor reads the export; it does not simply trust
the live projection.

### Following the commit boundary in code

For contributors tracing one write, read these in order:

1. `Spectre.Kernel.Commit.payloads/3` builds proposed events.
2. `Spectre.GovernedAct.Commit.prepare/4` builds and checks a provisional batch.
3. `Spectre.Domain.Transaction.append_exact/4` asks the store to write it.
4. `Spectre.Domain.Recovery` confirms the receipt or reads back the durable
   records. An exact match can reuse the prepared state.
5. `Spectre.Domain.Command.Execution` releases the internal Grant only after
   that confirmation. Consuming it records the Attempt before broker checkout.

A prepared batch is not a committed batch. A failed acknowledgement does not
prove that nothing was written.

Return-path checks live in `core/attempt/runner/observation.ex` and
`core/outcome/attestation.ex`. They bind observations to the right Act and
Attempt. They establish consistency, not independent provider authenticity.

## Finding code in the repository

Start in the part that matches what you want to change:

| You want to work on… | Start here |
| --- | --- |
| DSL, handlers, prompts, Skills, routing or Instances | `lib/spectre/agents/` |
| GAM records, authorization, accounting, replay or execution ordering | `lib/spectre/core/` |
| Public host calls | `lib/spectre.ex` and `lib/spectre/core/facade/` |
| Generators, routing evaluation and diagnostics | `lib/mix/tasks/` |

Within the core, `governed_act/transition/` contains the rules for foundation,
authority, admission, execution, information and Duty changes. `Batch` and
`Completeness` check relationships spanning multiple entries.

The disk adapter separates ledger ownership (`disk.ex`), frame validation
(`disk/frame.ex`) and physical I/O (`disk/file_io.ex`). A well-formed frame is
not, by itself, proof of durability or authorization.

Application classes belong in a Surface and an executor, not new
pattern-matching branches in the kernel. The built-in governance classes are
different: they have explicit runtime semantics. Ledger records cannot name
arbitrary executable validator code.

There is no `lib/package` runtime. `package/0` in `mix.exs` only lists what
ships to Hex. It does not install integrations or start services.

## Where to read next

- [Build an agent](agents-and-dsl.md) for declarations and callbacks.
- [Connect it to your application](host-setup.md) for permission and services.
- [Handle streaming and cancellation](integration-and-streaming.md) for
  long-running interactions.
- [Operate storage and recovery](storage-and-recovery.md) for failure handling.
- [Read the precise trust boundary](../GOVERNED_SURFACE.md) when reviewing a deployment.

The [Governed Act Model](../GOVERNED_ACT_MODEL.md) is the formal model behind
these explanations. You can use this guide without reading the whole model first.
