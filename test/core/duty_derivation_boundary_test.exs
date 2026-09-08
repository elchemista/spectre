defmodule Spectre.DutyDerivationBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Duty, Evidence}
  alias Spectre.Domain.Event.Metadata
  alias Spectre.Duty.Derive
  alias Spectre.Duty.Derive.{Cause, Dispute, Facts}
  alias Spectre.Duty.Derive.Dispute.OutcomeAttestation
  alias Spectre.GovernedAct.Integrity
  alias Spectre.GovernedAct.Transition.Duty.Opening
  alias Spectre.V04Test.Fixture

  test "a trusted counter-attestation after a definitive receipt creates an explicit dispute", c do
    now = c.act.committed_at
    outcome = Fixture.outcome(c.f, c.act, c.attempt, :succeeded, [c.receipt.ref])
    {:ok, counter} = Evidence.new(%{c.receipt | ref: nil, stance: :contradicts, observed_at: now + 1})
    state = %{c.attempted | outcomes: %{outcome.ref => outcome}, evidence: Map.merge(c.attempted.evidence, %{c.receipt.ref => c.receipt, counter.ref => counter})}
    state = %{state | event_metadata: Map.merge(state.event_metadata, %{
      c.receipt.ref => metadata(100, now), outcome.ref => metadata(101, now), counter.ref => metadata(102, now + 1)})}
    facts = Facts.from_state(state)
    assert [] = OutcomeAttestation.causes(facts, state.constitution, now)
    assert [cause] = OutcomeAttestation.causes(facts, state.constitution, now + 1)
    assert cause.cause_key == {:disputed_evidence, c.act.ref, {:outcome, outcome.ref}, counter.ref}
    assert cause.required_at == now + 1
    assert cause.containment["retry"] == :forbidden
    assert cause.containment["dispatch"] == :blocked
    assert Enum.all?([c.receipt.ref, counter.ref], &(&1 in cause.known_evidence_refs))
    assert [^cause] = Dispute.causes(facts, state.constitution, now + 1)
    assert cause == Derive.required_cause(state, cause.cause_key, now + 1)

    # Correct timing alone cannot turn a different source into the executor.
    {:ok, impostor} = Evidence.new(%{counter | ref: nil, source_ref: "another-executor"})
    hostile = %{state | evidence: state.evidence |> Map.delete(counter.ref) |> Map.put(impostor.ref, impostor)}
    hostile = put_in(hostile.event_metadata[impostor.ref], metadata(102, now + 1))
    assert [] = OutcomeAttestation.causes(Facts.from_state(hostile), state.constitution, now + 1)
  end

  test "a default cause time cannot move a known obligation forward", c do
    cause = Cause.build(:ambiguous_outcome, {:external, 1}, %{}, %{}, %{accountable_ref: "owner", containment: nil})
    assert cause.containment["retry"] == :forbidden
    assert cause.containment["meter_reservations"] == %{}
    assert Derive.materialization_attrs(cause, 123).opened_at == 123
    assert Derive.materialization_attrs(%{cause | required_at: 100}, 123).opened_at == 100
    assert Cause.authority_refs("reviewer") == ["reviewer"]
    assert Cause.authority_refs(42) == []
    configured = %{"duty_rules" => %{"ambiguous_outcome" => %{"conflict_refs" => "custodian"}}}
    cause = Cause.build(:ambiguous_outcome, {:external, 2}, %{}, configured, %{act: c.act})
    assert "custodian" in cause.conflict_refs
    assert c.act.proposer_ref in cause.conflict_refs
    refute "unrelated" in cause.conflict_refs
    for invalid <- [nil, %{}] do
      assert [] = Derive.required_duties(invalid, 1)
      assert [] = Derive.required_duties(invalid, %{}, 1)
      assert nil == Derive.required_cause(invalid, :unknown, 1)
      assert nil == Derive.required_cause(invalid, %{}, :unknown, 1)
      assert [] = Derive.missing_openings(invalid, 1)
      assert [] = Derive.available_evidence_at(invalid, 1)
    end
    assert nil == Derive.cause_key(nil)
    assert nil == Derive.required_cause(c.before, {:unknown, c.act.ref}, c.act.committed_at)
  end

  test "whole-prefix integrity detects conserved quantity and immutable Constitution corruption", c do
    state = c.before
    assert :ok = Integrity.validate(state, c.act.committed_at)
    assert {:error, :invalid_governed_integrity_input} = Integrity.validate(state, 1.0)
    assert {:error, :invalid_governed_integrity_input} = Integrity.validate(nil, 1)
    changed = put_in(state.catalog.genesis.constitution_ref, "constitution:forged")
    assert {:error, :genesis_constitution_mismatch} = Integrity.validate(changed, c.act.committed_at)
    changed = put_in(state.meters[c.act.mandate_ref][c.f.refs.meter].spent, 1)
    assert {:error, {:meter_invalid, _, _, {:meter_conservation_violation, _}}} = Integrity.validate(changed, c.act.committed_at)
  end

  test "materialized debt cannot erase a missing fact without a disposition", c do
    time = c.attempt.started_at + c.act.observation_window_ms
    [cause] = Derive.required_duties(c.attempted, time)
    {:ok, duty} = cause |> Derive.materialization_attrs(time) |> Duty.new()
    state = %{c.attempted | duties: %{duty.cause_key => duty}}
    assert :ok = Integrity.validate(state, time)
    changed = %{duty | missing: []}
    assert {:error, {:duty_cause_materialization_mismatch, _}} = Integrity.validate(%{state | duties: %{duty.cause_key => changed}}, time)
    assert [] = Derive.missing_openings(state, time)
  end

  test "Duty replay binds every authority and accounting field back to its causal Act", c do
    time = c.attempt.started_at + c.act.observation_window_ms
    [cause] = Derive.required_duties(c.attempted, time)
    {:ok, duty} = cause |> Derive.materialization_attrs(time) |> Duty.new()
    assert :ok = Opening.validate(c.attempted, duty)

    assert {:error, {:duty_opened_in_terminal_state, _}} =
             Opening.validate(c.attempted, %{duty | status: :disposed, disposition_act_ref: "act:close"})
    assert {:error, {:duplicate_duty_cause, _}} =
             Opening.validate(%{c.attempted | duties: %{duty.cause_key => duty}}, duty)
    assert {:error, {:act_not_found, _}} = Opening.validate(%{c.attempted | acts: %{}}, duty)
    state = c.attempted
    mismatched_attempt = put_in(state.attempts[c.attempt.ref].act_ref, "another-act")
    assert {:error, {:duty_attempt_act_mismatch, _, _}} = Opening.validate(mismatched_attempt, duty)

    for {field, value, reason} <- [
          {:mandate_ref, "another-mandate", :duty_mandate_mismatch},
          {:subjects, ["another-subject"], :duty_subjects_mismatch},
          {:accountable, "another-owner", :duty_accountable_mismatch},
          {:conflict_refs, [], :duty_conflict_refs_mismatch}
        ] do
      assert {:error, {^reason, _, _}} = Opening.validate(c.attempted, Map.put(duty, field, value))
    end

    {:ok, invented} = Duty.new(class: "app.invented", cause_key: {:invented, 1}, accountable: "owner", opened_at: time)
    assert {:error, {:duty_cause_not_required_at_prefix, _}} = Opening.validate(c.attempted, invented)
  end

  defp metadata(revision, time), do: %Metadata{revision: revision, batch_id: "observations", recorded_at: time}
end
