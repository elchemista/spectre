defmodule Spectre.Core.DutyFrontierEquivalenceTest do
  use ExUnit.Case, async: false

  alias Spectre.Attempt.Reconciler
  alias Spectre.Domain.{Event, Sequencer}
  alias Spectre.Duty.{Derive, Frontier}
  alias Spectre.GovernedAct.Fold
  alias Spectre.Kernel.Observation
  alias Spectre.Ledger.Entry
  alias Spectre.Outcome
  alias Spectre.Test.DutyFrontierAssertions
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "frontier-#{System.unique_integer([:positive])}")
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    assert {:ok, ^payment} = Fixture.observe_payment(f, payment)
    %{f: f}
  end

  test "every committed prefix and deadline agrees with exhaustive derivation", %{f: f} do
    for n <- 1..6 do
      {act, attempt} = attempt(f, "cycle-#{n}")
      receipt = Fixture.receipt_evidence(f, act.ref)
      assert {:ok, ^receipt} = Fixture.record_receipt(f, receipt)
      outcome = Fixture.outcome(f, act, attempt, :succeeded, [receipt.ref])
      assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    end

    assert_prefixes(f)
  end

  test "late success retains the timeout cause and its original time", %{f: f} do
    {act, attempt} = attempt(f, "late")
    Runtime.set_time(attempt.started_at + act.observation_window_ms + 1)
    receipt = Fixture.receipt_evidence(f, act.ref)
    assert {:ok, ^receipt} = Fixture.record_receipt(f, receipt)
    outcome = Fixture.outcome(f, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    [duty] = Sequencer.projection(f.server).duties |> Map.values()
    assert duty.opened_at == attempt.started_at + act.observation_window_ms
    assert_prefixes(f)
  end

  test "new counterproof reaches old recognition dependencies outside recent context", %{f: f} do
    {act, _attempt} = attempt(f, "disputed")

    for n <- 1..12 do
      unrelated = Fixture.paid_evidence(f, %{proposition: "irrelevant:#{n}"})
      assert {:ok, ^unrelated} = Fixture.observe_payment(f, unrelated)
    end

    counter = Fixture.paid_evidence(f, %{stance: :contradicts})
    assert {:ok, ^counter} = Fixture.observe_payment(f, counter)

    assert Enum.any?(Sequencer.projection(f.server).duties, fn {_key, duty} ->
             duty.act_ref == act.ref and duty.class == :disputed_evidence
           end)

    assert_prefixes(f)
  end

  for delay <- [0, 1] do
    @delay delay
    test "receipt acquired #{delay} ms after the deadline agrees across same-time batches", %{
      f: f
    } do
      {act, attempt} = attempt(f, "deadline-boundary")
      deadline = attempt.started_at + act.observation_window_ms
      time = deadline + @delay
      receipt = Fixture.receipt_evidence(f, act.ref, %{observed_at: time})
      assert {:ok, event} = Event.record(:evidence, receipt)

      # A committed receipt batch reaches the deadline before the separate
      # Outcome batch. This prefix has a required but not yet materialized Duty.
      prefix = append(Sequencer.projection(f.server), [event], time)
      assert [cause] = Frontier.missing(prefix, time)
      assert [^cause] = Derive.missing_openings(prefix, time)
      assert cause.required_at === deadline
      assert map_size(prefix.duties) === 0

      outcome = successful_outcome(act, attempt, receipt, time)
      assert {:ok, payloads} = Observation.payloads(prefix, outcome, time)
      completed = append(prefix, payloads, time)

      expected = if @delay === 0, do: [], else: [cause]
      assert Frontier.missing(completed, time) === expected
      assert Derive.missing_openings(completed, time) === expected
      assert completed.outcomes[outcome.ref] === outcome
      assert :ok = Fold.validate_complete(completed)
    end
  end

  test "timely success cannot erase a Duty already materialized at the same timestamp", %{f: f} do
    {act, attempt} = attempt(f, "materialized-boundary")
    deadline = attempt.started_at + act.observation_window_ms
    receipt = Fixture.receipt_evidence(f, act.ref, %{observed_at: deadline})
    assert {:ok, event} = Event.record(:evidence, receipt)
    prefix = append(Sequencer.projection(f.server), [event], deadline)
    assert {:ok, plan} = Reconciler.repair_plan(prefix, deadline)
    contained = append(prefix, plan.payloads, deadline)
    assert [duty] = Map.values(contained.duties)
    assert duty.status === :open

    outcome = successful_outcome(act, attempt, receipt, deadline)
    assert {:ok, payloads} = Observation.payloads(contained, outcome, deadline)
    completed = append(contained, payloads, deadline)

    assert completed.duties[duty.cause_key] === duty
    assert Frontier.missing(completed, deadline) === []
    assert Derive.missing_openings(completed, deadline) === []
    assert :ok = Fold.validate_complete(completed)
  end

  defp attempt(f, identity) do
    candidate = Fixture.refund_candidate(f, 100, identity_key: identity)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    {act, attempt}
  end

  defp assert_prefixes(f) do
    DutyFrontierAssertions.assert_prefixes(Fixture.snapshot(f), f.constitution)
  end

  defp successful_outcome(act, attempt, receipt, time) do
    assert {:ok, outcome} =
             Outcome.new(%{
               act_ref: act.ref,
               attempt_ref: attempt.ref,
               status: :succeeded,
               evidence_refs: [receipt.ref],
               observed_at: time,
               details_ref: "receipt:deadline-boundary"
             })

    outcome
  end

  defp append(prefix, payloads, time) do
    assert {:ok, entries} =
             Entry.build_batch(
               prefix.domain_ref,
               "boundary:#{System.unique_integer([:positive])}",
               payloads,
               prefix.revision,
               time,
               prefix.head_digest
             )

    assert {:ok, state} = Fold.append_batch(prefix, entries)
    state
  end
end
