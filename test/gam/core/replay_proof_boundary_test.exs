Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.ReplayProofBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Act, Governance, Outcome, Row, SubmissionContext}
  alias Spectre.GAM.Domain.Event
  alias Spectre.GAM.GovernedAct.Transition.Admission.Decision, as: DecisionProof
  alias Spectre.GAM.GovernedAct.Transition.Outcome, as: OutcomeProof
  alias Spectre.GAM.GovernedAct.Transition.Scope, as: ScopeTransition
  alias Spectre.GAM.Mandate.Revocation
  alias Spectre.GAM.Scope.Opening
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  test "replayed Decision requires the recorded Principal and exact live Mandate", c do
    state = c.before
    assert :ok = DecisionProof.validate(state, c.decision, nil)

    assert {:error, {:authenticated_principal_not_found, _}} =
             DecisionProof.validate(put_in(state.catalog.principals, %{}), c.decision, nil)

    assert {:error, {:decision_mandate_not_found, _}} =
             DecisionProof.validate(%{state | mandates: %{}}, c.decision, nil)

    assert {:error, {:invalid_decision_submission_context, _, _}} =
             DecisionProof.validate(state, %{c.decision | authentication_ref: "forged"}, nil)

    changed = %{c.f.mandate | holder_ref: "another-holder"}

    assert {:error, {:decision_mandate_holder_mismatch, _}} =
             DecisionProof.validate(put_in(state.mandates[changed.ref], changed), c.decision, nil)

    expired = %{c.f.mandate | expires_at: c.decision.decided_at}

    assert {:error, {:decision_mandate_not_current, _}} =
             DecisionProof.validate(put_in(state.mandates[expired.ref], expired), c.decision, nil)

    for revocation <- [
          %Revocation{
            identity: "revocation",
            effective_at: c.decision.decided_at,
            mode: :cascade
          },
          :corrupt
        ] do
      assert {:error, {:decision_mandate_revoked, _}} =
               DecisionProof.validate(
                 put_in(state.revocations[c.f.mandate.ref], revocation),
                 c.decision,
                 nil
               )
    end
  end

  test "retained revocation proof grants only narrow controller authority", c do
    state = c.before

    decision = %{
      c.decision
      | candidate_class: "mandate.revoke",
        authorizer_ref: c.decision.authenticated_principal_ref,
        executor_ref: Governance.kernel_executor_ref(),
        recognition_refs: [],
        recognition_evidence_refs: [],
        reservations: %{}
    }

    mandate = %{
      c.f.mandate
      | revocation: %{
          "mode" => :retained_controller,
          "controller_refs" => [decision.authenticated_principal_ref]
        }
    }

    state = put_in(state.mandates[mandate.ref], mandate)
    assert :ok = DecisionProof.validate(state, decision, nil)

    assert {:error, {:decision_revocation_controller_mismatch, _}} =
             DecisionProof.validate(
               put_in(state.mandates[mandate.ref].revocation["controller_refs"], []),
               decision,
               nil
             )

    for {field, value, error} <- [
          {:authorizer_ref, "other", :decision_revocation_authorizer_mismatch},
          {:accountable_ref, "other", :decision_accountable_mismatch},
          {:executor_ref, c.f.refs.executor, :decision_revocation_executor_mismatch},
          {:recognition_refs, [c.f.condition.ref], :decision_revocation_not_narrow}
        ] do
      assert {:error, {^error, _}} =
               DecisionProof.validate(state, Map.put(decision, field, value), nil)
    end
  end

  test "a late correction has one exact causal target and cannot rewrite it twice", c do
    no_effect = Fixture.outcome(c.f, c.act, c.attempt, :definitive_no_effect, [c.receipt.ref])

    correction = %{
      no_effect
      | ref: "correction",
        status: :succeeded,
        contradicts_outcome_ref: no_effect.ref
    }

    history = %{no_effect.ref => no_effect}
    assert :ok = OutcomeProof.validate_history(history, correction)

    assert {:error, {:corrected_outcome_not_found, _}} =
             OutcomeProof.validate_history(%{}, correction)

    assert {:error, {:outcome_correction_cause_mismatch, _, _}} =
             OutcomeProof.validate_history(history, %{correction | attempt_ref: "other-attempt"})

    assert {:error, {:corrected_outcome_not_no_effect, _}} =
             OutcomeProof.validate_history(
               %{no_effect.ref => %{no_effect | status: :succeeded}},
               correction
             )

    assert {:error, {:outcome_correction_precedes_target, _, _}} =
             OutcomeProof.validate_history(history, %{
               correction
               | observed_at: no_effect.observed_at - 1
             })

    assert {:error, {:outcome_already_corrected, _, _}} =
             OutcomeProof.validate_history(Map.put(history, correction.ref, correction), %{
               correction
               | ref: "second-correction"
             })

    assert {:error, :invalid_outcome_history} = OutcomeProof.validate_history(nil, correction)
    assert {:error, :invalid_outcome_transition} = OutcomeProof.validate_for_act(nil, correction)

    assert {:error, :erasure_failure_must_be_definitive_or_ambiguous} =
             OutcomeProof.validate_for_act(%{c.act | class: "data.erase"}, %{
               correction
               | status: :failed
             })

    assert Outcome.correction?(correction)
  end

  test "an Outcome cannot attest itself with absent or malformed Evidence", c do
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :succeeded, [c.receipt.ref])

    assert :ok =
             OutcomeProof.validate_evidence(
               %{c.receipt.ref => c.receipt},
               outcome,
               c.attempt,
               c.act
             )

    assert {:error, {:outcome_evidence_not_found, _}} =
             OutcomeProof.validate_evidence(%{}, outcome, c.attempt, c.act)

    assert {:error, {:invalid_outcome_evidence, _}} =
             OutcomeProof.validate_evidence(%{c.receipt.ref => %{}}, outcome, c.attempt, c.act)

    assert {:error, :invalid_outcome_evidence_index} =
             OutcomeProof.validate_evidence(nil, outcome, c.attempt, c.act)
  end

  test "Scope replay proves the source Act's complete effect and authenticated binding", c do
    {state, opening, act} = governed_scope(c)
    assert {:ok, restored} = replay_scope(state, opening)
    assert restored.catalog.scopes[opening.ref] == opening

    for {field, value, reason} <- [
          {:class, "app.write", :scope_opening_act_class_mismatch},
          {:row, c.act.row, :scope_opening_act_row_mismatch},
          {:reservations, c.act.reservations, :scope_opening_act_has_reservations},
          {:executor_ref, c.f.refs.executor, :scope_opening_act_not_ledger_internal},
          {:consequence, %{}, :scope_opening_consequence_mismatch},
          {:scope_ref, "another-parent", :scope_opening_parent_act_mismatch},
          {:accountable_ref, "another-owner", :scope_opening_accountable_act_mismatch},
          {:target_refs, [], :scope_opening_target_missing},
          {:committed_at, act.committed_at - 1, :scope_opening_commit_time_mismatch},
          {:host_generation, act.host_generation + 1, :scope_opening_generation_act_mismatch},
          {:ingress_ref, "other-ingress", :scope_opening_ingress_act_mismatch}
        ] do
      changed = Map.put(act, field, value)
      # The transition receives decoded records: checking cross-record proof is
      # separate from the constructor's content-address check.
      assert {:error, {^reason, _, _}} =
               replay_scope(put_in(state.acts[act.ref], changed), opening)
    end
  end

  test "Scope replay rejects absent parents, principals and disposition paths", c do
    {state, opening, _act} = governed_scope(c)

    for {changed, reason} <- [
          {%{opening | domain_ref: "foreign"}, :scope_domain_mismatch},
          {%{opening | parent_ref: "missing"}, :scope_parent_not_found},
          {%{opening | accountable_ref: "missing"}, :scope_principal_not_found},
          {%{opening | disposition_authority_refs: ["missing"]},
           :scope_disposition_authority_not_found}
        ] do
      assert {:error, {^reason, _, _}} = replay_scope(state, changed)
    end

    assert {:error, {:invalid_scope_submission_context, _, _}} =
             replay_scope(state, %{opening | authentication_ref: "forged"})
  end

  defp governed_scope(c) do
    assert {:ok, context} =
             SubmissionContext.new(%{
               Fixture.context(c.f)
               | ref: nil,
                 seal: nil,
                 scope_ref: "work:replay-boundary"
             })

    assert {:ok, promise} =
             Spectre.GAM.Condition.new(%{
               c.f.condition
               | ref: nil,
                 bindings: %{"scope_ref" => context.scope_ref}
             })

    attrs =
      Map.merge(Opening.context_bindings(context), %{
        parent_ref: c.f.refs.scope,
        kind: :work,
        promise_condition: promise,
        accountable_ref: c.f.refs.accountable,
        disposition_authority_refs: [c.f.refs.grantor],
        due_at: Runtime.now() + 1_000
      })

    assert {:ok, draft} = Opening.governed_draft(attrs)
    {:ok, row} = Row.new(%{write: true, govern: true})

    assert {:ok, act} =
             Act.new(%{
               c.act
               | ref: nil,
                 class: "scope.open",
                 row: row,
                 reservations: %{},
                 disclosure: nil,
                 observation_window_ms: 0,
                 executor_ref: Governance.kernel_executor_ref(),
                 executor_contract_ref: Governance.kernel_contract_ref(),
                 target_refs: [context.scope_ref],
                 consequence: %{"scope_open" => draft}
             })

    assert {:ok, opening} = Opening.from_governed_draft(draft, act.ref, act.committed_at)
    state = c.before
    {put_in(state.acts[act.ref], act), opening, act}
  end

  defp replay_scope(state, opening) do
    assert {:ok, payload} = Event.scope_opened(opening)
    assert {:ok, event} = Event.decode(payload)
    ScopeTransition.apply(state, event, nil)
  end
end
