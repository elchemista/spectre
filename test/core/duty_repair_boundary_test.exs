defmodule Spectre.Core.DutyRepairBoundaryTest.AdvancingClock do
  alias Spectre.V04Test.Runtime

  def now do
    time = Runtime.now()
    Runtime.set_time(time + 10_000)
    send(self(), :repair_clock_read)
    time
  end
end

defmodule Spectre.Core.DutyRepairBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.Core.DutyRepairBoundaryTest.AdvancingClock
  alias Spectre.Domain.{Sequencer, Transaction}
  alias Spectre.Ledger.Store.Mock
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(mock_store: true)
    on_exit(fn -> Fixture.stop_domain(f) end)
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    %{f: f}
  end

  test "repair pins time once and does not chase newly due work recursively", %{f: f} do
    {first, first_attempt} = attempt(f, "first")
    Runtime.set_time(Runtime.now() + 1)
    {second, _} = attempt(f, "second")
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    Runtime.set_time(first_attempt.started_at + first.observation_window_ms)

    assert {:ok, repaired} = Transaction.repair_missing_duties(%{state | clock: AdvancingClock})
    assert_receive :repair_clock_read
    refute_receive :repair_clock_read, 0
    assert [duty] = Map.values(repaired.duties)
    assert duty.act_ref === first.ref
    refute duty.act_ref === second.ref
    assert repaired.recorded_at === duty.opened_at
  end

  test "repair CAS retries are finite and cannot append a duplicate Duty", %{f: f} do
    {act, attempt} = attempt(f, "repair-conflict")
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    Runtime.set_time(attempt.started_at + act.observation_window_ms)
    before = Fixture.snapshot(f)
    assert :ok = Mock.push(f.mock, List.duplicate({:append, :before, {:error, :conflict}}, 3))

    assert {:error, :duty_repair_conflict_retries_exhausted} =
             Transaction.repair_missing_duties(%{state | conflict_retries: 2})

    assert Fixture.snapshot(f) === before

    assert {:ok, repaired} = Transaction.repair_missing_duties(state)
    assert map_size(repaired.duties) === 1
    assert {:ok, ^repaired} = Transaction.repair_missing_duties(%{state | projection: repaired})
    assert Fixture.snapshot(f).revision === repaired.revision
  end

  defp attempt(f, identity) do
    candidate = Fixture.refund_candidate(f, 10, identity_key: identity)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    {act, attempt}
  end
end
