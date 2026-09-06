Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.CoreTest.DutyMaterializationReplayTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Duty, Ledger}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Ledger.Entry
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "duty-materialization-replay")
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 100, evidence_refs: [payment.ref])
             )

    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    outcome = Fixture.outcome(fixture, act, attempt, :ambiguous)
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)
    projection = Sequencer.projection(fixture.server)
    [duty] = Map.values(projection.duties)

    %{fixture: fixture, duty: duty, projection: projection, snapshot: Fixture.snapshot(fixture)}
  end

  test "live ambiguous Duty replays identically and remains open in independent audit", c do
    assert {:ok, rebuilt} = Projection.replay(c.snapshot, c.fixture.constitution)
    assert rebuilt === c.projection
    assert {:ok, report} = Audit.verify(c.snapshot, c.fixture.constitution, Runtime.now())
    assert report.open_duties == [Duty.canonical(c.duty)]
  end

  test "rehashed Duty cannot replace an integer reservation with its numerically equal float",
       c do
    canonical = Duty.canonical(c.duty)
    assert canonical["containment"]["meter_reservations"][c.fixture.refs.meter] === 100

    changed =
      put_in(canonical, ["containment", "meter_reservations", c.fixture.refs.meter], 100.0)

    # Duty identity addresses its cause, not its complete contents. Both records
    # are individually well-formed and have the same ref but different digests.
    assert {:ok, counterfeit} = Duty.from_canonical(changed)
    assert counterfeit.ref === c.duty.ref
    refute Duty.digest(counterfeit) === Duty.digest(c.duty)
    refute Duty.same_cause?(counterfeit, c.duty)

    forged = rechain_opening(c.snapshot, changed)
    assert {:ok, _verified} = Ledger.verify_snapshot(forged)
    expected = {:duty_cause_materialization_mismatch, c.duty.ref}

    # Checking only Audit would miss the weaker replay path: both must reject
    # at the shared transition, not only a later whole-history integrity check.
    result = Projection.replay(forged, c.fixture.constitution)
    assert match?({:error, ^expected}, result)

    assert {:error, {:semantic_violation, %{reason: ^expected}}} =
             Audit.verify(forged, c.fixture.constitution, Runtime.now())
  end

  defp rechain_opening(snapshot, replacement) do
    groups = Enum.chunk_by(snapshot.entries, & &1.batch_id)
    empty = %{snapshot | entries: [], revision: 0, head_digest: Entry.genesis_digest()}

    Enum.reduce(groups, empty, fn [first | _] = group, current ->
      payloads = Enum.map(group, &replace_opening(&1.payload, replacement))

      assert {:ok, entries} =
               Entry.build_batch(
                 snapshot.domain_ref,
                 first.batch_id,
                 payloads,
                 current.revision,
                 first.recorded_at,
                 current.head_digest
               )

      last = List.last(entries)

      %{
        current
        | entries: current.entries ++ entries,
          revision: last.revision,
          head_digest: last.digest
      }
    end)
  end

  defp replace_opening(%{"type" => "duty_opened"} = event, replacement),
    do: %{event | "data" => replacement}

  defp replace_opening(event, _replacement), do: event
end
