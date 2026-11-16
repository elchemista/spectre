Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.RecoveredReadModelTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Attempt.Runner.Recovery
  alias Spectre.GAM.Domain.Reconciliation
  alias Spectre.GAM.GovernedAct.{DispatchState, View}
  alias Spectre.GAM.V04Test.Fixture

  test "recovery distinguishes pending, attempted, cancelled and absent dispatch facts", c do
    assert :dispatch_ready = Recovery.from_projection(c.pending, c.decision, c.act)
    assert {:ok, result} = Recovery.from_projection(c.attempted, c.decision, c.act)
    assert result.attempt === c.attempt
    assert result.outcome === nil

    cancelled =
      DispatchState.mark_cancelled(c.pending, c.act.ref, %{
        reason: :mandate_expired,
        cause_ref: c.f.mandate.ref,
        cancelled_at: c.f.mandate.expires_at
      })

    assert {:ok, result} = Recovery.from_projection(cancelled, c.decision, c.act)
    assert result.act === c.act
    assert result.attempt === nil

    ref = c.act.ref

    assert {:error, {:invalid_dispatch_state, ^ref}} =
             Recovery.from_projection(
               %{c.pending | pending_dispatches: MapSet.new()},
               c.decision,
               c.act
             )

    assert {:error, {:admitted_act_not_found, ^ref}} =
             Recovery.from_projection(%{c.pending | acts: %{}}, c.decision, c.act)

    assert {:error, {:admitted_act_changed, ^ref}} =
             Recovery.from_projection(c.pending, c.decision, %{c.act | target_refs: ["other"]})
  end

  test "recovery never treats a missing, malformed or misbound Attempt as safe to retry", c do
    ref = c.attempt.ref

    for {attempts, error} <- [
          {%{}, {:attempt_not_found, ref}},
          {%{ref => %{}}, {:invalid_recorded_attempt, ref}},
          {%{ref => %{c.attempt | act_ref: "other"}}, :recorded_attempt_binding_mismatch},
          {%{ref => %{c.attempt | executor_ref: "other"}}, :recorded_attempt_binding_mismatch},
          {%{ref => %{c.attempt | material_digest: "other"}}, :recorded_attempt_binding_mismatch}
        ] do
      assert {:error, ^error} =
               Recovery.from_projection(%{c.attempted | attempts: attempts}, c.decision, c.act)
    end
  end

  test "pending dispatch inspection rejects broken causal records", c do
    state = c.pending
    ref = c.act.ref
    mandate_ref = c.act.mandate_ref
    assert {:ok, [{act, mandate}]} = DispatchState.pending(c.pending)
    assert act === c.act
    assert mandate === c.f.mandate

    for {state, error} <- [
          {%{c.pending | acts: %{}}, {:pending_dispatch_act_not_found, ref}},
          {%{c.pending | acts: %{ref => nil}}, {:invalid_pending_dispatch_act, ref}},
          {%{c.pending | mandates: %{}}, {:pending_dispatch_mandate_not_found, mandate_ref}},
          {%{c.pending | mandates: %{mandate_ref => nil}},
           {:invalid_pending_dispatch_mandate, mandate_ref}},
          {put_in(state.acts[ref].mandate_revision, -1),
           {:pending_dispatch_mandate_mismatch, ref}},
          {%{c.pending | terminal_dispatches: c.attempted.terminal_dispatches},
           {:pending_dispatch_already_terminal, ref}}
        ] do
      assert {:error, ^error} = DispatchState.pending(state)
    end
  end

  test "query lookups distinguish missing, inconsistent and invalid identities", c do
    identity = c.candidate.identity_key
    decision_ref = c.decision.ref
    assert {:ok, decision} = View.candidate_decision(c.pending, identity)
    assert decision === c.decision
    assert :not_found = View.candidate_decision(c.before, identity)
    assert {:error, :invalid_candidate_identity_key} = View.candidate_decision(c.pending, nil)

    assert {:error, {:candidate_identity_decision_not_found, ^identity, ^decision_ref}} =
             View.candidate_decision(%{c.pending | decisions: %{}}, identity)

    assert {:error, {:candidate_identity_index_mismatch, ^identity, ^decision_ref}} =
             View.candidate_decision(%{c.pending | decisions: %{decision_ref => nil}}, identity)

    assert {:error, {:invalid_candidate_admission, ^identity}} =
             View.candidate_decision(%{c.pending | admissions: %{identity => nil}}, identity)

    assert {:ok, act} = View.decision_act(c.pending, c.decision)
    assert act === c.act
    assert {:ok, nil} = View.decision_act(c.pending, %{c.decision | outcome: :refused})

    assert {:error, {:admitted_decision_missing_act, ^decision_ref}} =
             View.decision_act(%{c.pending | acts: %{}}, c.decision)
  end

  test "evidence lookup preserves requested order and does not return a partial set", c do
    assert {:ok, [payment, payment]} =
             View.evidence_set(c.pending, [c.payment.ref, c.payment.ref])

    assert payment === c.payment

    assert {:error, {:evidence_not_found, "missing"}} =
             View.evidence_set(c.pending, [c.payment.ref, "missing"])

    assert {:error, :invalid_evidence_refs} = View.evidence_set(c.pending, c.payment.ref)
    assert {:error, {:invalid_meter_mandate_ref, nil}} = View.meter_accounts(c.pending, nil)
  end

  test "scope queries fail closed on absent, malformed or differently bound openings", c do
    state = c.pending
    context = Fixture.context(c.f)
    ref = context.scope_ref
    assert {:ok, _opening} = View.scope_context(c.pending, context)
    assert {:error, :invalid_scope_context} = View.scope_context(c.pending, %{})

    assert {:error, {:scope_not_open, ^ref}} =
             View.scope_context(put_in(state.catalog.scopes, %{}), context)

    assert {:error, {:invalid_projected_scope, ^ref}} =
             View.scope_context(put_in(state.catalog.scopes[ref], nil), context)

    assert {:error, {:scope_context_domain_mismatch, ^ref}} =
             View.scope_context(%{c.pending | domain_ref: "other"}, context)

    assert {:error, {:scope_context_binding_mismatch, ^ref}} =
             View.scope_context(c.pending, %{context | ref: nil, channel_ref: "other"})
  end

  test "missing definitions and Duties are not fabricated by the read model", c do
    state = c.pending
    assert {:error, {:invalid_definition_ref, nil}} = View.definition(c.pending, nil)
    assert {:error, {:definition_not_found, "missing"}} = View.definition(c.pending, "missing")

    assert {:error, {:invalid_definition_record, "missing"}} =
             View.definition(put_in(state.catalog.definitions["missing"], %{}), "missing")

    assert :not_found = View.duty(c.pending, {:ref, "missing"})
    assert :not_found = View.duty(c.pending, {:cause_key, {:missing, "cause"}})
    assert {:error, :invalid_duty_lookup} = View.duty(c.pending, {:ref, nil})
    assert {:error, :invalid_duty_lookup} = View.duty(c.pending, {:cause_key, nil})
  end

  test "reconciliation uses the nearest durable dispatch deadline", c do
    assert Reconciliation.next_deadline(c.pending, c.pending.recorded_at) ===
             c.f.mandate.expires_at

    assert Reconciliation.next_deadline(c.before, c.before.recorded_at) === nil

    assert Reconciliation.next_deadline(c.attempted, c.attempted.recorded_at) ===
             c.attempt.started_at + c.act.observation_window_ms
  end
end
