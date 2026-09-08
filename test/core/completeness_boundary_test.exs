defmodule Spectre.Core.CompletenessBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.GovernedAct.Completeness
  alias Spectre.V04Test.Fixture

  test "a recovered prefix rejects incomplete admission indexes", c do
    assert :ok = Completeness.validate(c.pending)

    state = c.pending
    changed_act = %{c.act | decision_ref: "decision:forged"}

    assert {:error, {:incomplete_admitted_decision, ref}} =
             Completeness.validate(put_in(state.acts[c.act.ref], changed_act))

    assert ref == c.decision.ref

    identity = c.decision.candidate_identity_key
    admission = Map.fetch!(state.admissions, identity)

    assert {:error, {:incomplete_admitted_decision, ^ref}} =
             Completeness.validate(put_in(state.admissions[identity], %{admission | act_ref: nil}))

    refused = %{c.decision | outcome: :refused}
    before = c.before

    refused_state = %{
      before
      | decisions: %{refused.ref => refused},
        admissions: %{identity => %{decision_ref: refused.ref, act_ref: nil}}
    }

    assert :ok = Completeness.validate(refused_state)

    assert {:error, {:non_admitted_decision_has_act, ^ref}} =
             Completeness.validate(
               put_in(refused_state.admissions[identity].act_ref, "act:invented")
             )
  end

  test "cancellation cannot strand a reservation outside the pending index", c do
    cancellation = %{
      cause_ref: c.f.mandate.ref,
      reason: :mandate_revoked,
      cancelled_at: c.pending.recorded_at
    }

    state = %{
      c.pending
      | pending_dispatches: MapSet.delete(c.pending.pending_dispatches, c.act.ref),
        terminal_dispatches: Map.put(c.pending.terminal_dispatches, c.act.ref, {:cancelled, cancellation})
    }

    assert {:error, {:cancelled_dispatch_reservation_not_released, ref}} =
             Completeness.validate(state)

    assert ref == c.act.ref
  end

  test "corrupt recontainment and missing correction accounting are detected on recovery", c do
    record = %{
      cause_key: {:ambiguous_outcome, c.act.ref, c.attempt.ref},
      outcome_ref: "outcome:missing",
      disposition_act_ref: nil,
      recontained: c.act.reservations,
      deficits: %{}
    }

    assert {:error, {:incomplete_meter_recontainment, ref}} =
             Completeness.validate(%{
               c.attempted
               | meter_recontainments: %{c.act.ref => record}
             })

    assert ref == c.act.ref

    no_effect =
      Fixture.outcome(c.f, c.act, c.attempt, :definitive_no_effect, [c.receipt.ref])

    correction = %{
      no_effect
      | ref: "outcome:late-correction",
        status: :succeeded,
        contradicts_outcome_ref: no_effect.ref
    }

    state = %{
      c.attempted
      | outcomes: %{no_effect.ref => no_effect, correction.ref => correction}
    }

    assert {:error, {:missing_meter_recontainment, ref}} = Completeness.validate(state)
    assert ref == correction.ref
  end

  test "Mandate succession must be complete and acyclic", c do
    ref = c.f.mandate.ref
    state = c.pending
    revised = %{Map.fetch!(state.mandates, ref) | revision: 2}

    assert {:error, {:mandate_revision_lineage_incomplete, ^ref, 2}} =
             Completeness.validate(put_in(state.mandates[ref], revised))

    cyclic = %{
      state
      | mandates: Map.put(state.mandates, ref, revised),
        mandate_successors: %{ref => ref}
    }

    assert {:error, {:mandate_restriction_cycle, ^ref}} = Completeness.validate(cyclic)
  end

  test "logical Meter owners and declassification sources cannot be forged in a snapshot", c do
    state = c.before
    owner_ref = "mandate:synthetic-owner"
    mandate = %{c.f.mandate | ref: owner_ref, revision: 1}

    bad_owner = %{
      state
      | mandates: Map.put(state.mandates, owner_ref, mandate),
        meter_owner_aliases: Map.put(state.meter_owner_aliases, owner_ref, "mandate:missing")
    }

    assert {:error, {:invalid_mandate_meter_owner, ^owner_ref, "mandate:missing"}} =
             Completeness.validate(bad_owner)

    first = %{source_act_ref: "act:one", evidence_ref: c.payment.ref}
    duplicate = %{source_act_ref: "act:one", evidence_ref: "evidence:other"}

    assert {:error, {:duplicate_declassification_act, "act:one"}} =
             Completeness.validate(%{
               state
               | declassifications: %{"declassification:one" => first, "declassification:two" => duplicate}
             })
  end
end
