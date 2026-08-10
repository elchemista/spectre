# Migrating to 0.2.7

Spectre 0.2.7 adds declarative runtime Skills and deterministic Routing
projections. State remains writer v5, Run remains writer v2, and canonical
Instance checkpoints remain schema 4. No existing durable checkpoint migration
is required.

## What changes

- Compiled Skills may declare `requires_operation/2` and use
  `call_operation/2`. The operation must already exist in the host Agent's
  closed registry.
- Canonical Skill prompt components now include a versioned per-Skill budget.
  Existing canonical Definition fixtures remain readable; a compiled legacy
  Skill without the field receives the current conservative budget in the
  unified view.
- Definition and Stack closures advertise both Audit and Routing projection
  generators by default.
- Trusted hosts may build a `Spectre.Skill.Definition` from portable data and
  manage it with `Spectre.Skill.Runtime`.

## Upgrade steps

1. Pin `spectre` to tag `0.2.7` and compile with warnings as errors.
2. Run the full State, Run, Instance, Definition, and Stack conformance suite
   retained from 0.2.6.
3. If a compiled Skill uses `call_operation`, register the referenced operation
   on every host Agent and grant it in the effective Authority Envelope.
4. Grant only the lifecycle capabilities the host actually needs: mount,
   replace, and disable are separate stable capability strings.
5. Reserve kernel prompt tokens and set a per-Skill ceiling before accepting
   any runtime-authored Skill.
6. Treat every mutation as revision CAS and retain the returned runtime value.
7. Execute returned `Spectre.Operation.Request` values only through the normal
   trusted host boundary, then release their continuation explicitly.

## Fail-closed differences

Runtime Skill construction rejects unknown fields, executable templates,
uncapped fragments, callback references, duplicate exact routes, undeclared
operations, and overlapping positive/negative applicability examples. Mount
also rejects failed anti-hijack examples, authority gaps, registry gaps,
declared conflicts, or prompt overflow. Equal-specificity routing ambiguity
returns an error.

Disabling no longer implies that owned in-flight work is rebound to a newer
Skill. A live generation drains until its exact continuations are released.
Replacement likewise retains an old Definition only for continuations already
pinned to it.

## What does not change

- A model cannot publish, activate, mount, replace, or disable a Skill by
  itself.
- Runtime Skills do not register executors or run operations directly.
- Agent/Subject identity, Activation fencing, Definition lifecycle, Skill state
  branches, and checkpoint writers are unchanged.
- Generated callbacks, goal-driven Work, autonomous Forge behavior, empirical
  reflection, and governance are not part of 0.2.7.

See [Runtime Skills and Routing Projections](RUNTIME_SKILLS.md) for the complete
host flow and [Preparing for Spectre 0.3](MIGRATING_TO_0_3.md) for the remaining
gate ledger.
