Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.GovernedDomainTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Kernel.Grant
  alias Spectre.Ledger.Store.Mock
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "GAM refund: Mandate and payment Evidence precede the exact Act and successful Outcome" do
    fixture = start_domain(namespace: "gam-refund")
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    candidate = Fixture.refund_candidate(fixture, 5_000)

    assert {:ok, %{decision: decision, act: act, grant: %Grant{} = grant}} =
             Sequencer.submit(fixture.server, Fixture.context(fixture), candidate)

    assert decision.outcome == :admitted
    assert decision.mandate_ref == fixture.mandate.ref
    assert decision.recognition_refs == [fixture.condition.ref]
    assert decision.reservations == %{fixture.refs.meter => 5_000}

    assert act.decision_ref == decision.ref
    assert act.mandate_ref == fixture.mandate.ref
    assert act.evidence_refs == [payment.ref]
    assert act.proposer_ref == fixture.refs.proposer
    assert act.executor_ref == fixture.refs.executor
    assert act.authorizer_ref == fixture.refs.grantor
    assert act.accountable_ref == fixture.refs.accountable
    assert grant.act_ref == act.ref
    assert grant.material_digest == act.material_digest

    assert %{available: 5_000, reserved: 5_000, suspended: 0, spent: 0} =
             meter_account(fixture)

    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    assert attempt.act_ref == act.ref
    assert attempt.executor_ref == act.executor_ref
    assert attempt.material_digest == act.material_digest

    receipt = Fixture.receipt_evidence(fixture, act.ref)
    assert {:ok, ^receipt} = Fixture.record_receipt(fixture, receipt)

    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)

    projection = Sequencer.projection(fixture.server)

    assert %{available: 5_000, reserved: 0, suspended: 0, spent: 5_000} =
             meter_account(fixture)

    assert projection.attempts[attempt.ref].act_ref == act.ref
    assert projection.outcomes[outcome.ref] == outcome
    assert projection.duties == %{}

    assert Enum.take(Fixture.event_types(Fixture.snapshot(fixture)), -9) == [
             "evidence_recorded",
             "decision_recorded",
             "act_committed",
             "meter_reserved",
             "dispatch_ready",
             "attempt_started",
             "evidence_recorded",
             "outcome_recorded",
             "meter_settled"
           ]
  end

  test "Admission is durable before Grant and Attempt is durable before capability return" do
    fixture = start_domain(namespace: "commit-order")
    payment = record_payment(fixture)
    before_admission = Fixture.snapshot(fixture).revision

    assert {:ok, %{decision: decision, act: act, grant: %Grant{} = grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 2_500, evidence_refs: [payment.ref])
             )

    admission_snapshot = Fixture.snapshot(fixture)
    admission_entries = Enum.drop(admission_snapshot.entries, before_admission)

    assert Enum.map(admission_entries, & &1.payload["type"]) == [
             "decision_recorded",
             "act_committed",
             "meter_reserved",
             "dispatch_ready"
           ]

    assert admission_snapshot.revision == before_admission + 4
    assert Sequencer.projection(fixture.server).decisions[decision.ref] == decision
    assert Sequencer.projection(fixture.server).acts[act.ref] == act
    refute Enum.any?(admission_entries, &(&1.payload["type"] == "grant_recorded"))
    refute inspect(Enum.map(admission_entries, & &1.payload)) =~ grant.nonce

    before_attempt = admission_snapshot.revision
    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)

    attempt_snapshot = Fixture.snapshot(fixture)

    assert [%{payload: %{"type" => "attempt_started"}}] =
             Enum.drop(attempt_snapshot.entries, before_attempt)

    assert attempt_snapshot.revision == before_attempt + 1
    assert Sequencer.projection(fixture.server).attempts[attempt.ref] == attempt
    assert attempt.grant_nonce_digest != grant.nonce
    refute inspect(Enum.map(attempt_snapshot.entries, & &1.payload)) =~ grant.nonce
  end

  test "stale SubmissionContext and prior-generation Grant cannot cross the generation fence" do
    fixture = start_domain(namespace: "generation", generation: 41)
    payment = record_payment(fixture)
    candidate = Fixture.refund_candidate(fixture, 1_000, evidence_refs: [payment.ref])
    stale_context = Fixture.context(fixture)
    revision = Fixture.snapshot(fixture).revision

    assert {:ok, %{act: original_act, grant: old_grant}} =
             Sequencer.submit(fixture.server, Fixture.context(fixture), candidate)

    Fixture.stop_process(fixture.server)
    restarted = Fixture.restart_domain(fixture, generation: 42)

    assert {:error, :submission_context_generation_mismatch} =
             Sequencer.submit(restarted.server, stale_context, candidate)

    assert Fixture.snapshot(restarted).revision == revision + 4

    assert {:error, :grant_generation_mismatch} =
             Sequencer.consume_grant(restarted.server, old_grant)

    assert restarted.server |> Sequencer.projection() |> Map.fetch!(:attempts) == %{}

    current_context = Fixture.context(restarted, host_generation: 42)
    # Reauthentication cannot silently rebind an immutable Scope opening.
    scope_ref = fixture.refs.scope

    assert {:error, {:scope_context_binding_mismatch, ^scope_ref}} =
             Sequencer.submit(restarted.server, current_context, candidate)

    assert Sequencer.projection(restarted.server).acts[original_act.ref] == original_act
    assert Sequencer.projection(restarted.server).attempts == %{}

    Fixture.stop_process(restarted.server)
  end

  test "Candidate identity is idempotent and rejects changed material without a second Decision" do
    fixture = start_domain(namespace: "candidate-identity")
    payment = record_payment(fixture)
    context = Fixture.context(fixture)
    candidate = Fixture.refund_candidate(fixture, 3_000, evidence_refs: [payment.ref])

    assert {:ok, first} = Sequencer.submit(fixture.server, context, candidate)
    committed_revision = Fixture.snapshot(fixture).revision
    assert {:ok, duplicate} = Sequencer.submit(fixture.server, context, candidate)

    assert duplicate.decision.ref == first.decision.ref
    assert duplicate.act.ref == first.act.ref
    assert %Grant{} = duplicate.grant
    assert Fixture.snapshot(fixture).revision == committed_revision

    changed = Fixture.refund_candidate(fixture, 3_001, evidence_refs: [payment.ref])

    assert {:error, {:candidate_identity_conflict, identity_key}} =
             Sequencer.submit(fixture.server, context, changed)

    assert identity_key == candidate.identity_key
    assert Fixture.snapshot(fixture).revision == committed_revision

    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.decisions) == 1
    assert map_size(projection.acts) == 1
  end

  test "after-commit ambiguity is reconciled by batch identity without duplicate facts" do
    fixture = start_domain(namespace: "after-commit", mock_store: true)
    payment = Fixture.paid_evidence(fixture)
    # Faults belong to the host adapter, never to untrusted submission options.
    assert :ok =
             Mock.push(fixture.mock, List.duplicate({:append, :after, {:error, :ambiguous}}, 5))

    assert {:ok, ^payment} =
             Fixture.observe_payment(fixture, payment)

    assert {:ok, %{decision: decision, act: act, grant: grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 2_000, evidence_refs: [payment.ref])
             )

    assert {:ok, ^act, attempt, _receipt} =
             Sequencer.consume_grant(fixture.server, grant)

    receipt = Fixture.receipt_evidence(fixture, act.ref)

    assert {:ok, ^receipt} =
             Fixture.record_receipt(fixture, receipt)

    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])

    assert {:ok, ^outcome} =
             Sequencer.record_outcome(fixture.server, outcome)

    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.decisions) == 1
    assert map_size(projection.acts) == 1
    assert map_size(projection.attempts) == 1
    assert map_size(projection.outcomes) == 1
    assert map_size(projection.evidence) == 2
    assert projection.decisions[decision.ref] == decision

    identities =
      Enum.map(Fixture.snapshot(fixture).entries, &{&1.payload["type"], &1.payload["identity"]})

    assert length(identities) == length(Enum.uniq(identities))
  end

  test "ambiguous world outcome suspends resources and never grants a blind retry" do
    fixture = start_domain(namespace: "no-blind-retry")
    payment = record_payment(fixture)
    candidate = Fixture.refund_candidate(fixture, 4_000, evidence_refs: [payment.ref])
    context = Fixture.context(fixture)

    assert {:ok, %{decision: decision, act: act, grant: grant}} =
             Sequencer.submit(fixture.server, context, candidate)

    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    ambiguous = Fixture.outcome(fixture, act, attempt, :ambiguous)
    assert {:ok, ^ambiguous} = Sequencer.record_outcome(fixture.server, ambiguous)

    projection = Sequencer.projection(fixture.server)
    assert projection.meter_reservations[act.ref] == :suspended

    assert %{available: 6_000, reserved: 0, suspended: 4_000, spent: 0} =
             meter_account(fixture)

    assert map_size(projection.attempts) == 1
    assert map_size(projection.outcomes) == 1
    assert map_size(projection.duties) == 1

    [duty] = Map.values(projection.duties)
    assert duty.act_ref == act.ref
    assert duty.attempt_ref == attempt.ref
    assert duty.status == :open
    assert duty.containment["retry"] == :forbidden

    assert {:error, :consequence_retry_contained} =
             Sequencer.consume_grant(fixture.server, grant)

    revision = Fixture.snapshot(fixture).revision

    assert {:ok, %{decision: ^decision, act: ^act, grant: nil}} =
             Sequencer.submit(fixture.server, context, candidate)

    assert {:ok, ^ambiguous} = Sequencer.record_outcome(fixture.server, ambiguous)
    assert Fixture.snapshot(fixture).revision == revision
    assert map_size(Sequencer.projection(fixture.server).attempts) == 1
  end

  test "restart derives a missing Duty once and suspends its reservation atomically" do
    fixture =
      start_domain(
        namespace: "recovery-duty",
        observation_window_ms: 100
      )

    payment = record_payment(fixture)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 4_000,
                 evidence_refs: [payment.ref],
                 observation_window_ms: 100
               )
             )

    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    before_restart = Sequencer.projection(fixture.server)
    assert before_restart.meter_reservations[act.ref] == :reserved
    assert before_restart.duties == %{}

    Fixture.stop_process(fixture.server)
    Runtime.set_time(attempt.started_at + 101)
    restarted = Fixture.restart_domain(fixture)
    repaired = Sequencer.projection(restarted.server)

    assert repaired.meter_reservations[act.ref] == :suspended

    assert %{available: 6_000, reserved: 0, suspended: 4_000, spent: 0} =
             repaired.meters[fixture.mandate.ref][fixture.refs.meter]

    assert map_size(repaired.duties) == 1
    [duty] = Map.values(repaired.duties)
    assert duty.cause_key == {:ambiguous_outcome, act.ref, attempt.ref}
    assert duty.opened_at == attempt.started_at + 100

    repair_entries = Enum.take(Fixture.snapshot(restarted).entries, -2)

    assert Enum.map(repair_entries, & &1.payload["type"]) == [
             "meter_suspended",
             "duty_opened"
           ]

    assert repair_entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1
    repaired_revision = repaired.revision

    Fixture.stop_process(restarted.server)
    restarted_again = Fixture.restart_domain(restarted)
    assert Sequencer.projection(restarted_again.server).revision == repaired_revision
    assert map_size(Sequencer.projection(restarted_again.server).duties) == 1
    Fixture.stop_process(restarted_again.server)
  end

  test "one microbatch evaluates sequentially and cannot overspend a shared Mandate" do
    fixture =
      start_domain(
        namespace: "microbatch-meter",
        meter_ceiling: 100,
        batch_size: 2,
        batch_wait_ms: 10_000
      )

    payment = record_payment(fixture)
    context = Fixture.context(fixture)
    revision = Fixture.snapshot(fixture).revision

    candidates = [
      Fixture.refund_candidate(fixture, 70,
        identity_key: fixture.refs.candidate_identity <> ":one",
        evidence_refs: [payment.ref]
      ),
      Fixture.refund_candidate(fixture, 70,
        identity_key: fixture.refs.candidate_identity <> ":two",
        evidence_refs: [payment.ref]
      )
    ]

    tasks =
      Enum.map(candidates, fn candidate ->
        Task.async(fn -> Sequencer.submit(fixture.server, context, candidate) end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, &match?({:ok, _result}, &1))
    admissions = Enum.map(results, fn {:ok, admission} -> admission end)

    assert Enum.count(admissions, &(&1.decision.outcome == :admitted)) == 1
    assert Enum.count(admissions, &(&1.decision.outcome == :refused)) == 1
    assert Enum.count(admissions, &match?(%Grant{}, &1.grant)) == 1

    refused = Enum.find(admissions, &(&1.decision.outcome == :refused))
    assert {:insufficient_meter_quantity, fixture.refs.meter} in refused.decision.reasons
    assert refused.act == nil
    assert refused.grant == nil

    assert Enum.sort(Enum.map(admissions, & &1.decision.authority_revision)) == [
             revision,
             revision + 4
           ]

    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.decisions) == 2
    assert map_size(projection.acts) == 1

    assert %{ceiling: 100, available: 30, reserved: 70, suspended: 0, spent: 0} =
             meter_account(fixture)

    batch_entries = Enum.drop(Fixture.snapshot(fixture).entries, revision)
    assert length(batch_entries) == 5
    assert batch_entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1
  end

  defp start_domain(opts) do
    fixture = Fixture.start_domain(opts)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp record_payment(fixture) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)
    payment
  end

  defp meter_account(fixture) do
    fixture.server
    |> Sequencer.projection()
    |> Map.fetch!(:meters)
    |> Map.fetch!(fixture.mandate.ref)
    |> Map.fetch!(fixture.refs.meter)
  end
end
