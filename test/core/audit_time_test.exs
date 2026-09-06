Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.CoreTest.AuditTimeTest do
  use ExUnit.Case, async: false

  alias Spectre.Audit
  alias Spectre.Audit.Export
  alias Spectre.Domain.Sequencer
  alias Spectre.Ledger
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "audit-time")
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    %{fixture: fixture}
  end

  for offset <- [-1, 0, 1, 6_000] do
    test "unobserved Attempt at deadline offset #{offset} preserves capture and reports only due causes",
         %{fixture: fixture} do
      {act, attempt} = start_attempt(fixture)
      captured_at = Runtime.now()
      deadline = attempt.started_at + act.observation_window_ms
      audited_at = deadline + unquote(offset)
      data = export(fixture, captured_at)
      before = Fixture.snapshot(fixture)

      assert {:ok, report} = Export.verify(data, audited_at)
      assert report.captured_at === captured_at
      assert report.audited_at === audited_at
      assert report.counts.duties == 0
      assert report.open_duties == []
      assert report.expired_dispatches == []
      assert report.head_digest === before.head_digest
      assert report.meters[fixture.mandate.ref][fixture.refs.meter]["reserved"] === 100

      if unquote(offset) < 0 do
        assert report.pending_duty_causes == []
      else
        assert [cause] = report.pending_duty_causes
        assert cause.cause_key === {:ambiguous_outcome, act.ref, attempt.ref}
        assert cause.required_at === deadline
        assert cause.containment["retry"] === :forbidden
      end

      # Audit is read-only: it neither materializes a Duty nor settles money.
      assert Fixture.snapshot(fixture) === before
    end
  end

  test "missing Duty already required at capture stays a hard error even with later --at", %{
    fixture: fixture
  } do
    {act, attempt} = start_attempt(fixture)
    deadline = attempt.started_at + act.observation_window_ms
    data = export(fixture, deadline)
    cause_key = {:ambiguous_outcome, act.ref, attempt.ref}

    for time <- [deadline, deadline + 10_000] do
      assert {:error, {:semantic_audit_incomplete, {:required_duty_not_materialized, ^cause_key}}} =
               Export.verify(data, time)
    end
  end

  test "strict snapshot audit retains its whole-history completeness check", %{fixture: fixture} do
    {act, attempt} = start_attempt(fixture)
    deadline = attempt.started_at + act.observation_window_ms

    assert {:error, {:semantic_audit_incomplete, {:required_duty_not_materialized, _}}} =
             Audit.verify(Fixture.snapshot(fixture), fixture.constitution, deadline)
  end

  test "recorded ambiguous Duty is not duplicated as a future unmaterialized cause", %{
    fixture: fixture
  } do
    {act, attempt} = start_attempt(fixture)
    outcome = Fixture.outcome(fixture, act, attempt, :ambiguous)
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)

    assert {:ok, report} = Export.verify(export(fixture), Runtime.now() + 6_000)
    assert report.counts.duties == 1
    assert [%{"act_ref" => act_ref}] = report.open_duties
    assert act_ref == act.ref
    assert report.pending_duty_causes == []
    assert report.meters[fixture.mandate.ref][fixture.refs.meter]["suspended"] === 100
  end

  test "timely definitive Outcome prevents a timeout cause in an old export", %{fixture: fixture} do
    {act, attempt} = start_attempt(fixture)
    receipt = Fixture.receipt_evidence(fixture, act.ref)
    assert {:ok, ^receipt} = Fixture.record_receipt(fixture, receipt)
    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)

    assert {:ok, report} = Export.verify(export(fixture), Runtime.now() + 6_000)
    assert report.pending_duty_causes == []
    assert report.open_duties == []
    assert report.meters[fixture.mandate.ref][fixture.refs.meter]["spent"] === 100
  end

  for offset <- [-1, 0, 1] do
    test "pending dispatch at Mandate expiry offset #{offset} is reported without fabricated cancellation",
         %{fixture: fixture} do
      %{act: act} = admit(fixture)
      audited_at = fixture.mandate.expires_at + unquote(offset)

      assert {:ok, report} = Export.verify(export(fixture), audited_at)
      assert report.pending_duty_causes == []
      assert report.dispatch_cancellations == []
      assert report.counts.attempts == 0

      expected =
        if unquote(offset) < 0,
          do: [],
          else: [
            %{
              act_ref: act.ref,
              mandate_ref: fixture.mandate.ref,
              expired_at: fixture.mandate.expires_at
            }
          ]

      assert report.expired_dispatches === expected
      assert report.meters[fixture.mandate.ref][fixture.refs.meter]["reserved"] === 100
    end
  end

  test "dispatch expiration omitted before capture cannot be excused by later observation", %{
    fixture: fixture
  } do
    %{act: act} = admit(fixture)
    data = export(fixture, fixture.mandate.expires_at)
    act_ref = act.ref

    assert {:error, {:semantic_audit_incomplete, {:dispatch_expiration_not_recorded, ^act_ref}}} =
             Export.verify(data, fixture.mandate.expires_at + 1)
  end

  test "observation cannot precede capture even when it covers all entries", %{fixture: fixture} do
    captured_at = Runtime.now() + 100
    audited_at = Runtime.now()

    assert {:error, {:audit_time_precedes_capture, ^audited_at, ^captured_at}} =
             Export.verify(export(fixture, captured_at), audited_at)
  end

  @tag :tmp_dir
  test "CLI --at audits an offline export and distinguishes recorded Duties from pending causes",
       %{
         fixture: fixture,
         tmp_dir: directory
       } do
    start_attempt(fixture)
    assert {:ok, bytes} = Export.encode(export(fixture))
    path = Path.join(directory, "domain.spectre")
    File.write!(path, bytes)
    Fixture.stop_domain(fixture)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Spectre.Audit.run([path, "--at", Integer.to_string(Runtime.now() + 6_000)])
      end)

    assert output =~ "Spectre audit passed"
    assert output =~ "open duties: 0"
    assert output =~ "pending duty causes: 1"
    assert output =~ "expired dispatches: 0"
    assert File.read!(path) === bytes
  end

  @tag :tmp_dir
  test "CLI default audit rejects a capture that omitted an already required Duty", %{
    fixture: fixture,
    tmp_dir: directory
  } do
    {act, attempt} = start_attempt(fixture)

    assert {:ok, bytes} =
             Export.encode(export(fixture, attempt.started_at + act.observation_window_ms))

    path = Path.join(directory, "incomplete.spectre")
    File.write!(path, bytes)

    assert_raise Mix.Error, ~r/required_duty_not_materialized/, fn ->
      Mix.Tasks.Spectre.Audit.run([path])
    end
  end

  @tag :tmp_dir
  test "CLI enforces its byte budget before decoding", %{fixture: fixture, tmp_dir: directory} do
    assert {:ok, bytes} = Export.encode(export(fixture))
    path = Path.join(directory, "bounded.spectre")
    File.write!(path, bytes)

    assert_raise Mix.Error, ~r/audit_export_not_regular_or_too_large/, fn ->
      Mix.Tasks.Spectre.Audit.run([path, "--max-bytes", "1"])
    end
  end

  test "CLI refuses malformed arguments instead of ignoring them" do
    assert_raise Mix.Error, ~r/usage:/, fn ->
      Mix.Tasks.Spectre.Audit.run(["unused", "--at", "tomorrow"])
    end
  end

  test "a reported pending cause matches the Duty later committed by real reconciliation", %{
    fixture: fixture
  } do
    {act, attempt} = start_attempt(fixture)
    deadline = attempt.started_at + act.observation_window_ms
    data = export(fixture)
    assert {:ok, before} = Export.verify(data, deadline)
    assert [cause] = before.pending_duty_causes

    %{reconciliation: {token, _timer}} = :sys.get_state(fixture.server)
    Runtime.set_time(deadline)
    send(fixture.server, {:reconcile, token})
    projection = Sequencer.projection(fixture.server)
    assert [duty] = Map.values(projection.duties)
    assert duty.cause_key === cause.cause_key
    assert duty.opened_at === cause.required_at
    assert duty.containment === cause.containment

    assert {:ok, after_repair} = Export.verify(export(fixture))
    assert after_repair.pending_duty_causes == []
    assert after_repair.open_duties == [Spectre.Duty.canonical(duty)]
    assert {:ok, ^before} = Export.verify(data, deadline)
  end

  test "an old export does not learn a definitive Outcome subsequently recorded by the live Domain",
       %{fixture: fixture} do
    {act, attempt} = start_attempt(fixture)
    data = export(fixture)
    receipt = Fixture.receipt_evidence(fixture, act.ref)
    assert {:ok, ^receipt} = Fixture.record_receipt(fixture, receipt)
    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)
    deadline = attempt.started_at + act.observation_window_ms

    assert {:ok, old_report} = Export.verify(data, deadline)
    assert [_cause] = old_report.pending_duty_causes
    assert old_report.counts.outcomes == 0
    assert {:ok, new_report} = Export.verify(export(fixture), deadline)
    assert new_report.pending_duty_causes == []
    assert new_report.counts.outcomes == 1
    refute old_report.head_digest === new_report.head_digest
  end

  defp admit(fixture) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    assert {:ok, admission} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 100, evidence_refs: [payment.ref])
             )

    admission
  end

  defp start_attempt(fixture) do
    %{act: act, grant: grant} = admit(fixture)
    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)
    {act, attempt}
  end

  defp export(fixture, captured_at \\ Runtime.now()) do
    assert {:ok, ledger} = Ledger.export_snapshot(Fixture.snapshot(fixture))
    assert {:ok, data} = Export.new(ledger, fixture.constitution, captured_at)
    data
  end
end
