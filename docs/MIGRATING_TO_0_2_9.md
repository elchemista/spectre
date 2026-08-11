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
8. Publish a non-empty protected evaluation corpus whose closure digest comes
   from `EvaluationDelta.protected_corpus_digest!/1`; it binds complete
   normalized case content, sorted by id. Pass the same cases through
   `protected_cases:` when building each delta.
9. Persist semantic-live profile, variability, and expiry evidence when policy
   requires that gate. Decide explicitly whether emergency restart/rollback
   may use the narrowly scoped expired-receipt host flags documented in
   `GOVERNANCE.md`.

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

The `0.2.9` tag did not exist while these contracts were hardened (the latest
published tag was `0.2.8`). Development snapshots of the 0.2.9 Candidate state,
evaluation delta, Human Report, receipt, or compatibility fixture are not a
supported durable format: regenerate them from the final 0.2.9 APIs. Schema 1
denotes the finalized release contract, not those untagged pre-release bytes.

## Behavioral changes

- A stale ChangeSet fails instead of rebasing implicitly.
- Candidate-owned evaluation cases can only add obligations; they cannot
  improve the protected score.
- Required gate options are additive. The constitutional floor cannot be
  reduced, evaluation deltas allow no protected regressions, and any attached
  failed receipt rejects the Candidate.
- `EvaluationDelta.new/3` now requires `protected_cases:` and binds full case
  content. `max_regressions` must be exactly zero and `min_score_delta` cannot
  be negative; hosts that previously tolerated regressions must tighten policy.
- Prompt and applicability ceilings are sealed into governed Candidate state
  and rechecked at activation/recovery; `scopes: []` is a wildcard and cannot
  pass a finite scope ceiling.
- Medium- and high-risk Candidates require human approval under the default
  policy.
- Approval emits a new Candidate Ref but does not activate it; explicit host
  rejection emits a terminal rejected Candidate Ref.
- Rollback targets an ancestor Candidate and increments activation generation;
  it never promises to undo external Effects.
- A GC inventory marked complete must actually be closed over Candidate and
  Definition lineage.
- An incomplete GC inventory remains valid only as conservative retain-only
  evidence. Definition Refs now require lowercase hexadecimal canonical text.

See [Governed Definition Changes](GOVERNANCE.md) for the full host workflow.
