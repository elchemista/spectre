# Preparing for Spectre 0.3

This document is the migration ledger from the stable 0.2 foundations toward
the reflective 0.3 runtime. It is not a promise that unreleased 0.3 behavior
already exists, and it does not make 0.2 hosts accept self-publication or
self-activation.

## Baseline to preserve

Before adopting any reflective feature, preserve these single models:

- canonical Definition identity and typed components;
- sealed Manifest authority and execution closure;
- immutable Definition publication and verified resolution;
- stable Agent/Subject Instance identity and generation-fenced Activation;
- ownership-based event admission and Definition lifecycle;
- branch-aware private Skill state;
- State, Run, and canonical Instance recovery formats.

`Spectre.Foundation.Conformance`, `Spectre.Stack.Conformance`, and the runtime
Skill/Routing fixture are the executable 0.2.7 baseline. A later lowering is
compatible only when the same
fixtures, module-first golden path, and complete Stack matrix continue to
pass without an escape hatch or a second internal representation.

## Required migration shape

Reflective inputs must cross the boundary in this order:

```text
declarative input
  -> validated versioned value
  -> existing canonical Definition IR
  -> Manifest authority + execution closure
  -> immutable publication
  -> explicit host Candidate/Activation action
  -> existing Instance sequencer and lifecycle fences
```

Compiled and runtime-authored Skills that express equivalent declarations
must produce equivalent semantic IR over the shared canonical components.
Runtime origin is provenance, not weaker validation and not additional
authority. Spectre 0.2.7 implements this Skill-only step; Work remains a later
gate.

## Host actions that remain explicit

Until governance contracts are delivered, a model cannot publish or activate
its own Definition, widen authority, acquire an Instance owner fence, enable a
Skill, or bypass a conflict. Hosts may expose narrowly authorized operations
that request those actions, but the host remains the decision-maker and the
result still crosses the normal sequencer and persistence boundaries.

## Rollout discipline

For each future foundation or runtime tag:

1. append a permanent compatibility fixture;
2. update the conformance matrix only when a writer or reader truly changes;
3. keep every older guaranteed fixture readable;
4. test compiled and runtime lowerings against one canonical result;
5. inject crash, restart, race, stale-owner, and corrupt-payload failures;
6. run the complete satellite Stack matrix;
7. document new authority and rollback consequences before activation.

Generated callbacks, goal-driven Work, autonomous Forge behavior, empirical
reflection, and governance are separate later gates. They must not be smuggled
into an earlier Skill or routing release.
