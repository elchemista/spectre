defmodule Spectre.Core.RoutedAgentsRecoveryTest do
  use Spectre.Test.RoutedAgentCase, async: false

  alias Spectre.Audit.Export
  alias Spectre.Domain.Sequencer
  alias Spectre.{Evidence, Instance, Ledger}
  alias Spectre.Ledger.Store.Mock
  alias Spectre.V04Test.{Fixture, Runtime}

  @tag status: :failed
  test "a routed definitive failure remains an observed effect and settles its reservation", c do
    {_result, _, candidate} = prepare(c, "refund 24")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.decision.outcome == :admitted
    assert proposal.primary.outcome.status == :failed
    assert_receive {:executed, _, _, _, _}
    assert account(c).spent == 24 and account(c).reserved == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.outcomes == [proposal.primary.outcome]
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert_history(c)
  end

  @tag status: :definitive_no_effect
  test "only a definitive no-effect attestation returns a routed reservation to availability",
       c do
    {_result, _, candidate} = prepare(c, "refund 25")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.decision.outcome == :admitted
    assert proposal.primary.outcome.status == :definitive_no_effect
    assert_receive {:executed, _, _, _, _}
    assert account(c).spent == 0 and account(c).reserved == 0
    assert account(c).available == 10_000
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert_history(c)
  end

  @tag status: :ambiguous
  test "a routed ambiguous effect remains visible as debt and retry cannot execute again", c do
    {_result, _, candidate} = prepare(c, "refund 215")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, _, _, _}
    assert executions(c) == 1
    assert account(c).suspended == 215
    assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
    assert duty.act_ref == proposal.primary.act.ref
    assert duty.containment["retry"] == :forbidden
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.outcomes == [proposal.primary.outcome]
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert {:ok, [^duty]} = Spectre.duties(c.scope, status: :open)
    assert_history(c)
  end

  @tag status: :crash
  test "executor failure after checkout leaves durable Attempt and Duty observable after agent loss",
       c do
    {_result, _, candidate} = prepare(c, "refund 216")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, attempt, _, snapshot}
    assert event_revision(snapshot, "attempt_started", attempt.ref) > 0
    assert {:ok, [duty]} = Spectre.duties(c.scope)
    GenServer.stop(c.instance, :normal)
    assert {:ok, [^duty]} = Spectre.duties(c.scope)
    assert account(c).suspended == 216
    assert executions(c) == 1
    assert_history(c)
  end

  @tag mock_store: true
  test "lost commit acknowledgement after a routed admission cannot cause a second effect", c do
    {result, _, candidate} = prepare(c, "refund 91")
    assert :ok = Mock.push(c.fixture.mock, [{:append, :after, {:error, :ambiguous}}])
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 91)
    before = projection(c)
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  @tag mock_store: true
  test "failure before a routed admission commit cannot deliver an executor capability", c do
    {_result, _, candidate} = prepare(c, "refund 92")
    assert :ok = Mock.push(c.fixture.mock, [{:append, :before, {:error, :disk_full}}])
    before = projection(c)
    assert {:error, _} = Instance.propose(c.instance, candidate)
    assert executions(c) == 0
    assert projection(c) == before
    assert_history(c)
  end

  for store <- [:ets, :disk] do
    @tag store: store
    test "a full routed agent's history survives Domain restart using #{store}", c do
      {result, route, candidate} = prepare(c, "refund 93")
      {_evidence, candidate} = record_route(c, result.turn, route, candidate)
      assert {:ok, proposal} = Instance.propose(c.instance, candidate)
      assert_completed(c, result.turn, proposal, 93)
      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
      before = projection(c)
      monitor = Process.monitor(c.instance)
      GenServer.stop(c.fixture.server)
      assert_receive {:DOWN, ^monitor, :process, _, _}
      # ETS survives Domain loss; Disk must also survive losing its own process.
      recovered = c.fixture |> restart_store() |> Fixture.restart_domain(generation: 8)
      on_exit(fn -> Fixture.stop_domain(recovered) end)
      :ets.insert(c.effects, {:store, recovered.store_config, recovered.refs.domain})
      assert Sequencer.projection(recovered.server) == before
      assert {:ok, domain} = Spectre.lookup_domain(recovered.refs.domain)
      # A different host generation cannot silently rewrite the old Opening.
      assert {:error, {:scope_context_binding_mismatch, _}} =
               Spectre.resume_scope(domain, Fixture.context(recovered))

      assert {:ok, context} =
               Spectre.authenticate(domain, c.recovered_scope_ref, %{
                 principal_ref: recovered.refs.proposer,
                 authentication_ref: "auth:recovered",
                 session_ref: "session:recovered"
               })

      assert {:ok, scope} = Spectre.open_scope(domain, context, opened_at: Runtime.now())

      # The payment Condition is Domain-wide: while the old proof is current
      # it must not be hidden from recognition. Obtain a fresh attestation in
      # this new session after the old proof's explicit validity interval ends.
      Runtime.set_time(c.payment.valid_until)

      payment_attrs =
        recovered
        |> Fixture.paid_evidence(valid_until: Runtime.now() + 1_000)
        |> Map.from_struct()
        |> Map.delete(:ref)

      assert {:ok, [payment]} = Spectre.observe(scope, payment_attrs)

      instance =
        start_supervised!({Instance, scope: scope, definition_ref: c.successor.ref, state: 0},
          id: :recovered
        )

      c = %{c | fixture: recovered, scope: scope, instance: instance, payment: payment}
      assert {:error, :candidate_retry_context_mismatch} = Instance.propose(instance, candidate)
      assert executions(c) == 1
      {next, route, candidate} = prepare(c, "money back", identity: "recovered-message")
      assert route.template == "revised_refund"
      assert {:ok, proposal} = Instance.propose(instance, candidate)
      assert_completed(c, next.turn, proposal, 193)
      assert_history(c)
    end
  end

  test "an offline audit retains the routing trace, Morph history and exact head without live agents",
       c do
    {result, route, candidate} = prepare(c, "refund 94")
    {evidence, candidate} = record_route(c, result.turn, route, candidate)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 94)
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    assert {:ok, ledger} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, export} = Export.new(ledger, c.fixture.constitution, Runtime.now())
    assert {:ok, bytes} = Export.encode(export)
    assert {:ok, head} = Spectre.head(c.scope.domain)
    Fixture.stop_domain(c.fixture)
    assert {:ok, report} = Export.verify(bytes)
    assert report.ledger_revision == head.revision
    assert report.head_digest == head.head_digest
    assert report.counts.outcomes == 1
    assert Enum.any?(report.definitions, &(&1["ref"] == c.definition.ref))
    assert Enum.any?(report.definitions, &(&1["ref"] == c.successor.ref))
    assert {:ok, decoded} = Export.decode(bytes)

    assert Enum.any?(
             decoded["ledger"]["entries"],
             &(&1["payload"]["data"] == Evidence.canonical(evidence))
           )

    refute bytes =~ inspect(c.capability)
  end
end
