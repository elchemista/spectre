# Migrating to 0.2.9

Spectre 0.2.9 adds governed Definition changes without changing any durable
State, Run, or canonical Instance writer. State remains writer v5, Run remains
writer v2, and Instance checkpoints remain schema 4. Existing bootstrap
Candidates continue to activate through the same API.

## Upgrade checklist

1. Pin `spectre` to tag `0.2.9` and compile with warnings as errors.
2. Run `Spectre.Foundation.Conformance.matrix/0` and keep every existing
   checkpoint, Definition, runtime Skill, and data-execution fixture in the
   upgrade suite.
3. Import `test/fixtures/compatibility/0.2.9/governance-v1.json` into any
   application-specific compatibility gate.
4. If governed Candidates are used, configure a durable Definition Store and
   persist the external checker id/version map in Instance options.
5. Keep approval actors and activation authority in trusted host code. Do not
   derive them from a ChangeSet, model output, or Skill data.
6. Treat rollback as a new activation commit and reconcile external Effects
   and Skill state explicitly.
7. Execute GC plans only inside a backend transaction or lease that rechecks a
   complete reference inventory.

## Compatibility details

`Spectre.Definition.Candidate` schema remains version 1. Governed Candidates
add an optional `governance` field and use source `governed_host`; legacy
Candidate bytes omit that field and retain their exact identity.

The Store adds immutable gate-receipt artifacts. Candidate publication and
fetch now revalidate all governed receipt bindings, while bootstrap Candidate
behavior remains unchanged. Governed activation and restart recovery require
the configured checker versions used during review.

The new portable schema versions are all 1:

- ChangeSet and Candidate governance state;
- gate receipt and receipt Ref;
- evaluation delta and Human Report generator;
- conservative GC plan.

## Behavioral changes

- A stale ChangeSet fails instead of rebasing implicitly.
- Candidate-owned evaluation cases can only add obligations; they cannot
  improve the protected score.
- Medium- and high-risk Candidates require human approval under the default
  policy.
- Approval emits a new Candidate Ref but does not activate it.
- Rollback targets an ancestor Candidate and increments activation generation;
  it never promises to undo external Effects.
- A GC inventory marked complete must actually be closed over Candidate and
  Definition lineage.

See [Governed Definition Changes](GOVERNANCE.md) for the full host workflow.

