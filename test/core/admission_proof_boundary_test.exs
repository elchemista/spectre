defmodule Spectre.Core.AdmissionProofBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.{Decision, Ledger, Row}
  alias Spectre.Domain.{Event, Sequencer}
  alias Spectre.GovernedAct.Transition.Admission
  alias Spectre.GovernedAct.Transition.Admission.Act, as: ActProof
  alias Spectre.GovernedAct.Transition.Admission.Decision, as: DecisionProof
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "admission-proof")
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    {:ok, _} = Fixture.observe_payment(f, payment)
    before = Sequencer.projection(f.server)

    {:ok, %{act: act, decision: decision}} =
      Sequencer.submit(
        f.server,
        Fixture.context(f),
        Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])
      )

    {:ok, payload} = Event.record(:decision, decision)
    {:ok, event} = Event.decode(payload)
    {:ok, admitted} = Admission.apply(before, event, before.revision + 1)
    admitted = %{admitted | revision: before.revision + 1}
    assert :ok = DecisionProof.validate(before, decision, before.revision + 1)
    assert :ok = ActProof.validate(admitted, act, decision)
    %{f: f, before: before, admitted: admitted, act: act, decision: decision, event: event}
  end

  # Exercise the semantic proof independently of the content digest checker.
  # These are isolated mutations of a real admitted prefix, never live state
  # updates. A rejection must identify the violated GAM relationship.
  test "an Act cannot follow a refused, undecidable or unknown-class Decision", c do
    for outcome <- [:refused, :undecidable, :unknown_class] do
      assert {:error, {:act_for_non_admitted_decision, ref}} =
               ActProof.validate(c.admitted, c.act, %{c.decision | outcome: outcome})

      assert ref == c.decision.ref
    end
  end

  test "no intervening event can separate the Act from its Decision", c do
    for revision <- [c.admitted.revision - 1, c.admitted.revision + 1] do
      assert {:error, {:act_not_adjacent_to_decision, _, _}} =
               ActProof.validate(%{c.admitted | revision: revision}, c.act, c.decision)
    end
  end

  test "class, material and commit time cannot change after admission", c do
    for {field, value, reason} <- [
          {:class, "orders.other", :decision_act_class_mismatch},
          {:material_digest, String.duplicate("f", 64), :act_material_digest_mismatch},
          {:committed_at, c.act.committed_at + 1, :act_commit_time_mismatch}
        ] do
      assert {:error, error} =
               ActProof.validate(c.admitted, Map.replace!(c.act, field, value), c.decision)

      assert elem(error, 0) == reason
    end
  end

  test "an Act cannot replace any trusted role, scope or acquisition binding", c do
    for field <- [
          :decision_ref,
          :submission_context_ref,
          :authenticated_principal_ref,
          :authentication_ref,
          :ingress_ref,
          :mandate_ref,
          :proposer_ref,
          :executor_ref,
          :authorizer_ref,
          :accountable_ref,
          :scope_ref,
          :host_profile_ref
        ] do
      assert {:error, {:decision_act_mismatch, ^field, _, _}} =
               ActProof.validate(
                 c.admitted,
                 Map.replace!(c.act, field, "other-reference"),
                 c.decision
               )
    end

    for field <- [:host_generation, :mandate_revision, :surface_revision] do
      assert {:error, {:decision_act_mismatch, ^field, _, _}} =
               ActProof.validate(c.admitted, Map.update!(c.act, field, &(&1 + 1)), c.decision)
    end
  end

  test "the one-Act-per-Decision index cannot be absent, foreign or already consumed", c do
    key = c.decision.candidate_identity_key

    for admission <- [nil, %{}, %{decision_ref: "foreign", act_ref: nil}] do
      state = %{c.admitted | admissions: %{key => admission}}

      assert {:error, {:invalid_candidate_admission, ^key}} =
               ActProof.validate(state, c.act, c.decision)
    end

    state = %{
      c.admitted
      | admissions: Map.update!(c.admitted.admissions, key, &%{&1 | act_ref: "earlier-act"})
    }

    assert {:error, {:decision_already_has_act, _, "earlier-act"}} =
             ActProof.validate(state, c.act, c.decision)
  end

  test "the frozen executor contract must still belong to the named Mandate", c do
    for mandates <- [%{}, %{c.act.mandate_ref => %{c.f.mandate | executor_contract_refs: []}}] do
      assert {:error, {:act_executor_contract_outside_mandate, _}} =
               ActProof.validate(%{c.admitted | mandates: mandates}, c.act, c.decision)
    end
  end

  test "replay requires the current Surface and its exact class row", c do
    catalog = c.admitted.catalog
    surface = catalog.surfaces[catalog.surface_ref]

    for {surfaces, tag} <- [
          {%{}, :act_surface_not_found},
          {%{surface.ref => %{surface | declarations: %{}}}, :act_unknown_surface_class},
          {%{surface.ref => %{surface | declarations: %{c.act.class => %Row{read: true}}}},
           :act_surface_row_mismatch}
        ] do
      state = %{c.admitted | catalog: %{catalog | surfaces: surfaces}}
      assert {:error, reason} = ActProof.validate(state, c.act, c.decision)
      assert elem(reason, 0) == tag
    end
  end

  test "a Surface requiring presentation cannot reuse an admission without consent", c do
    catalog = c.admitted.catalog
    surface = catalog.surfaces[catalog.surface_ref]
    surface = %{surface | presentation_required_classes: [c.act.class]}
    state = %{c.admitted | catalog: %{catalog | surfaces: %{surface.ref => surface}}}

    assert {:error, {:act_missing_required_presentation, _, _}} =
             ActProof.validate(state, c.act, c.decision)
  end

  test "Decision replay fences both the authority prefix and its own entry coordinate", c do
    assert {:error, {:decision_authority_revision_mismatch, _, _, _}} =
             DecisionProof.validate(
               c.before,
               %{c.decision | authority_revision: c.before.revision + 1},
               nil
             )

    assert {:error, {:decision_entry_revision_mismatch, _, _, _}} =
             DecisionProof.validate(c.before, c.decision, c.before.revision + 2)
  end

  test "admission proof rejects stale foundation records and unexplained admission reasons", c do
    for {decision, tag} <- [
          {%{c.decision | host_profile_ref: "other"}, :decision_host_profile_mismatch},
          {%{c.decision | surface_revision: c.decision.surface_revision + 1},
           :decision_surface_revision_mismatch},
          {%{c.decision | proposer_ref: "other"}, :admitted_decision_principal_mismatch},
          {%{c.decision | mandate_revision: c.decision.mandate_revision + 1},
           :decision_mandate_revision_mismatch},
          {%{c.decision | reasons: [:unproved]}, :admitted_decision_has_reasons},
          {%{c.decision | authorizer_ref: "other"}, :decision_authorizer_mismatch},
          {%{c.decision | accountable_ref: "other"}, :decision_accountable_mismatch},
          {%{c.decision | executor_ref: "other"}, :decision_executor_outside_mandate}
        ] do
      assert {:error, reason} = DecisionProof.validate(c.before, decision, nil)
      assert elem(reason, 0) == tag
    end
  end

  test "a receipt from after admission cannot become its recognition basis", c do
    evidence = hd(Map.values(c.before.evidence))

    state = %{
      c.before
      | evidence:
          Map.put(c.before.evidence, evidence.ref, %{
            evidence
            | observed_at: c.decision.decided_at + 1
          })
    }

    assert {:error, {:decision_evidence_from_future, _, _}} =
             DecisionProof.validate(state, c.decision, nil)
  end

  test "duplicate Candidate decisions never silently replace the durable admission", c do
    ref = c.decision.ref
    key = c.decision.candidate_identity_key
    state = %{c.before | admissions: %{key => %{decision_ref: ref, act_ref: nil}}}

    for {decisions, tag} <- [
          {%{}, :candidate_identity_decision_not_found},
          {%{ref => c.decision}, :duplicate_candidate_decision},
          {%{ref => %{c.decision | candidate_digest: String.duplicate("f", 64)}},
           :candidate_identity_conflict}
        ] do
      # A distinct record ref passes uniqueness and reaches Candidate identity
      # conflict handling, rather than failing at the duplicate-event check.
      {:ok, decision} =
        Decision.new(%{c.decision | ref: nil, decided_at: c.decision.decided_at + 1})

      {:ok, payload} = Event.record(:decision, decision)
      {:ok, event} = Event.decode(payload)
      assert {:error, reason} = Admission.apply(%{state | decisions: decisions}, event, nil)
      assert elem(reason, 0) == tag
    end
  end

  test "unsupported admission events fail without changing the actual ledger", c do
    snapshot = Fixture.snapshot(c.f)

    assert {:error, {:unsupported_admission_event, "evidence_observed"}} =
             Admission.apply(
               c.before,
               %Event{type: "evidence_observed", identity: "unsupported", data: %{}},
               nil
             )

    assert {:ok, ^snapshot} = Ledger.load(c.f.store_config, c.f.refs.domain)
  end
end
