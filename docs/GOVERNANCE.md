# Governed Definition Changes

Spectre 0.2.9 adds a host-controlled path for proposing, reviewing, approving,
activating, rolling back, and eventually collecting immutable Definition
Candidates. It composes over the existing Definition Store, Manifest,
Authority Envelope, Execution Closure, activation CAS, and owner fence; it does
not add a second runtime or allow authored data to execute code.

Spectre `0.3.0` adds Reflection/Experience evidence and Forge in front of
this unchanged commit chain. A Forge Proposal is inert: hosts pass its
contained ChangeSet to Composer and must pass the exact
`Spectre.Forge.evidence/2` map to composition and activation. Evidence drift is
stale-base failure, never an implicit rebase. See
[Reflective Runtime](REFLECTIVE_RUNTIME.md).

## The commit chain

Every stage produces or consumes content-addressed evidence:

```text
active Candidate
      |
      v
ChangeSet --compose--> composed Candidate --review--> evaluated Candidate
                                                        |
                                                        v
                                               approved Candidate
                                                        |
                                                        v
                                              activation generation CAS
```

The refs at each arrow are different. Approval is not activation, and passing a
Candidate or receipt struct is never enough: publication and activation re-read
the exact Candidate, Definition, Manifest, publication receipt, and gate
receipts from the configured Store.

## Author a closed ChangeSet

A `Spectre.Governance.ChangeSet` binds the exact Activation observed by its
author. Any change to the activation receipt, Candidate Ref, Definition Ref,
authority epoch, or evidence digest makes it stale. Rebasing means creating a
new ChangeSet.

```elixir
alias Spectre.Governance.ChangeSet

change_set =
  ChangeSet.new!(%{
    base_activation_receipt: activation.activation_receipt,
    base_candidate_ref: activation.candidate_ref,
    observed_definition_ref: activation.definition_ref,
    observed_authority_epoch: activation.authority_epoch,
    observed_evidence_digest: ChangeSet.evidence_digest(activation),
    operations: [
      %{
        type: "disable_skill",
        payload: %{"mount_id" => "legacy_lookup"}
      }
    ],
    author_ref: "operator:release-bot",
    provenance: %{"ticket" => "OPS-214"},
    reason: "Retire the superseded lookup Skill",
    created_at: System.system_time(:millisecond)
  })

{:ok, composed_ref} =
  Spectre.Governance.Composer.compose(definition_store, change_set,
    activation: activation,
    checkpoint_store: checkpoint_store
  )
```

The built-in vocabulary is deliberately finite:

- mount, replace, or disable one runtime Skill;
- update only host-declared mutable Skill configuration paths;
- update applicability only inside a host-declared ceiling;
- add or replace Candidate-owned evaluation cases for the current review
  cycle; and
- select a state migration already registered by the host.

Operation payloads are bounded JSON-shaped data. They cannot carry modules,
functions, PIDs, references, structs, tuples, executable templates, authority
grants, or arbitrary handler names. A host may extend the vocabulary only by
registering compiled modules that implement
`Spectre.Governance.ChangeSet.Handler`; the Registry verifies that each handler
touches only its declared component classes.

Composition can narrow authority but never expand it. Skill operation refs,
prompt budgets, applicability, mutable paths, state migrations, Manifest
parents, and the resulting Execution Closure are all revalidated before any
Candidate is published.

The Composer always adds the constitutional gate floor: structural,
authority, closure, prompt-budget, applicability, replay, full regression, and
evaluation-delta. `:required_gates` may add stricter application gates but
cannot remove this floor; critical-risk Candidates also require
`semantic_live`. Prompt-token and applicability ceilings are normalized into
the immutable Candidate and checked again from Store bytes during activation
and restart recovery. A finite applicability scope ceiling rejects `scopes:
[]`, because an empty declaration means wildcard rather than “no scopes.”
Applicability ceilings also cover positive and negative anti-hijack examples.
Replacing a mounted Skill or updating its applicability may add examples but
cannot remove any example already sealed into the mounted Definition.

## Review and anti-Goodhart evaluation

`Spectre.Governance.EvaluationDelta` compares the parent and Candidate on the
same protected corpus. Candidate-authored cases are obligations: they must
pass, but have zero weight in the protected score and cannot hide a regression.
The protected corpus must be non-empty. Its closure identity is the canonical
digest of the complete, normalized `Spectre.Eval.Case.to_data/1` objects sorted
by case id—not a digest of ids alone. Inputs, expected routes/outcomes,
strategies, allowed routes, LLM policy, state, tags, and duration limits are
therefore all bound. The Candidate, delta, report, and review receipt bind that
digest, so evaluating an arbitrary subset or swapping an oracle under the same
id fails closed.

```elixir
protected_cases = [
  %{
    id: "support-lookup",
    input: "look up the customer",
    expected_route: "LOOKUP",
    expected_outcome: :route
  }
]

protected_corpus_digest =
  Spectre.Governance.EvaluationDelta.protected_corpus_digest!(protected_cases)

# Seal protected_corpus_digest as closure.evaluation_corpus_digest.
delta =
  Spectre.Governance.EvaluationDelta.new!(parent_results, candidate_results,
    protected_cases: protected_cases,
    candidate_case_ids: candidate_case_ids,
    min_score_delta: 0.0,
    max_regressions: 0
  )

{:ok, reviewed_ref, report} =
  Spectre.Governance.Review.evaluate(
    definition_store,
    composed_ref,
    delta,
    [replay_receipt, regression_receipt],
    checker_versions: %{
      replay: {"my_app.replay", 3},
      regression: {"my_app.regression", 2}
    }
  )
```

External replay, regression, and semantic-live receipts must match the exact
checker id and version configured by the host. Built-in structural, authority,
closure, prompt-budget, applicability, and evaluation-delta checkers have
fixed Spectre identities. Expired, failed, duplicated, unbound, or unknown
receipts fail closed.

The constitutional evaluation floor is `min_score_delta >= 0.0` and
`max_regressions == 0`; callers may demand a higher minimum score delta but
cannot weaken either threshold. Every attached failed receipt rejects the
Candidate even when its class was only an additional, non-mandatory check.
Each semantic-live receipt requires a profile, an expiry, and portable
variability provenance of the form
`%{"variability" => %{"sample_count" => n, "measure_digest" => sha256}}`
with at least two samples.

Expiry remains mandatory and is enforced for new activation. By default it is
also enforced during restart recovery and rollback. If an already active
critical deployment would otherwise be unrecoverable, trusted host
configuration may set `allow_expired_semantic_live_recovery?: true` in the
Instance's nested `opts`; an explicit rollback call may separately set
`allow_expired_semantic_live_rollback?: true`. These emergency flags waive only
the current-time expiry check for an already stored semantic-live receipt. The
receipt's status, binding, checker id/version, profile, variability evidence,
and original validity window are still verified. They never permit a new
activation, and the host should re-attest and activate fresh evidence as soon
as recovery is complete.

The returned `Spectre.Projection.HumanReport` is a deterministic structural and
textual projection. It binds parent/Candidate identities, gate receipt refs,
lineage, and the evaluation delta. It never asks a model to decide whether the
change is “better.” The verified report, including its complete evaluation
delta, is stored in evaluated/rejected/approved Candidate state; a Store-only
audit can therefore reconstruct the evidence instead of relying on the return
value of `Review.evaluate/5`.

## Approval and activation remain separate

```elixir
{:ok, approved_ref} =
  Spectre.Governance.Approval.approve(definition_store, reviewed_ref,
    mode: :human,
    actor_ref: "operator:alice"
  )

{:ok, next_activation} =
  Spectre.activate(instance, approved_ref,
    expected_generation: activation.generation,
    checker_versions: %{
      replay: {"my_app.replay", 3},
      regression: {"my_app.regression", 2}
    }
  )
```

The default policy allows automatic approval only for low-risk changes;
medium- and high-risk changes require a named human actor. Applications can
provide a stricter `Spectre.Governance.Approval.Policy`.

An evaluated Candidate can also be closed explicitly without leaving it
permanently approvable:

```elixir
{:ok, rejected_ref} =
  Spectre.Governance.Approval.reject(definition_store, reviewed_ref,
    actor_ref: "operator:alice",
    reason: "Protected behavior needs another revision"
  )
```

Activation replays the approval and gate policy against Store bytes immediately
before the normal owner-fenced generation CAS. Persist the same
`checker_versions` configuration in Instance options so restart recovery can
verify governed activations without relying on call-local state.

No ChangeSet, Candidate, model response, or gate receipt can call activation.
Only the host-facing Instance API can commit it.

## Rollback is a new forward commit

```elixir
{:ok, rollback_activation} =
  Spectre.rollback(instance, ancestor_candidate_ref,
    expected_generation: current_activation.generation
  )
```

Rollback accepts only an ancestor in the active Candidate lineage. It re-reads
and verifies the target and commits a new activation generation through the
same fence and CAS path. Restoring broader historical authority requires an
explicit host opt-in.

Rollback does not undo messages, network requests, tool calls, or any other
external Effect. Its activation provenance records
`external_effects_rolled_back: false`. Skill-state migration or branch choices
remain explicit host work; they are not inferred from Definition ancestry.

## Conservative artifact GC

`Spectre.Governance.GC.plan/3` accepts a Candidate and Definition inventory plus
every known live activation, Run, checkpoint, Skill-state, and lineage
reference. Its default `inventory_complete?: false` mode is deliberately
retain-only: missing ancestors are not claimed as inspected evidence and every
decision carries `inventory_not_complete`. Set `inventory_complete?: true`
only after supplying the full inventory; that mode rejects an inventory not
closed over Candidate/Manifest ancestry. The result is a content-addressed
`Spectre.Governance.GC.Plan`, and anything not explicitly requested as eligible
is retained.

Candidate live references have the same explicit classes as Definition refs:
`run_candidate_refs`, `checkpoint_candidate_refs`,
`state_binding_candidate_refs`, and `lineage_candidate_refs`. The transported
plan seals Candidate and Definition lineage sets and verifies the exact reason
list for every decision; deleting a lineage reason from otherwise valid plan
bytes invalidates the plan.

The plan is evidence, not a delete command. A durable Store backend may delete
eligible artifacts only inside its own transaction or lease after revalidating
the same inventory and live references. Spectre core intentionally provides no
unsafe scan-then-delete shortcut.

## Security boundary

Governance proves identity, constrained composition, recorded checks, and
explicit host decisions. It does not prove semantic truth, make model output
trusted, reverse external Effects, grant distributed ownership, or authorize
artifact deletion from a stale scan.
