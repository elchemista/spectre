defmodule Spectre.Core.RoutedAgentsProvenanceTest do
  use Spectre.Test.RoutedAgentCase, async: false

  alias Spectre.{Candidate, Instance, Ledger, Mind}
  alias Spectre.Domain.Sequencer
  alias Spectre.Mind.Turn
  alias Spectre.Router.Selection
  alias Spectre.Test.RoutedAgentCase.RoutingMind
  alias Spectre.V04Test.{Fixture, Runtime}

  test "routing Evidence cannot override trusted origin or become an observed fact", c do
    {result, _route, _candidate} = prepare(c, "refund 10")
    {_definition, router} = c.configurations[c.definition.ref]
    assert {:ok, selection} = Spectre.Router.route(router, "refund 10")
    before = projection(c)

    for attrs <- [
          [provenance: :observed],
          [issuer_ref: c.fixture.refs.grantor],
          [parent_refs: []],
          [bindings: %{"scope_ref" => "foreign"}],
          [payload: "forged"],
          [proposition: "payment.confirmed"]
        ] do
      assert {:error, _} = Selection.evidence(selection, result.turn, Runtime.now(), attrs)
    end

    assert projection(c) == before
    assert executions(c) == 0
  end

  test "library routing provenance remains derived Evidence and reaches the canonical export",
       c do
    {result, _route, candidate} = prepare(c, "refund 37")
    {_definition, router} = c.configurations[c.definition.ref]
    assert {:ok, selection} = Spectre.Router.route(router, "refund 37")
    assert {:ok, evidence} = Selection.evidence(selection, result.turn, Runtime.now())
    assert evidence.provenance == :derived
    assert evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert evidence.proposition["router_ref"] == router.ref
    assert evidence.proposition["turn_ref"] == result.turn.ref

    assert evidence.payload == %{
             "rule" => selection.rule,
             "candidate" => selection.candidate,
             "via" => "regex",
             "score" => 1.0
           }

    refute Map.has_key?(evidence.payload, "matched")
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, result.turn, evidence)

    attrs =
      candidate
      |> Map.take(Candidate.request_fields())
      |> Map.update!(:evidence_refs, &[evidence.ref | &1])

    assert {:ok, candidate} = Mind.candidate(result.turn, [evidence], attrs)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert evidence.ref in proposal.primary.act.evidence_refs
    assert_completed(c, result.turn, proposal, 37)
  end

  test "an application observer exception cannot execute or partially advance the Instance", c do
    observer = fn _event -> raise "host diagnostic observer crashed" end

    assert {:error, {:mind_failed, RoutingMind, RuntimeError}} =
             turn(c, "refund 65", observer: observer)

    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert executions(c) == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.acts == []
    assert Enum.any?(view.evidence, &(&1.proposition == "chat.message"))
    assert_history(c)
  end

  test "route Evidence is recorded before admission and is causally linked without becoming authority",
       c do
    {result, route, candidate} = prepare(c, "refund 71")
    {route_evidence, candidate} = record_route(c, result.turn, route, candidate)
    assert route_evidence.provenance == :derived
    assert route_evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert route_evidence.issuer_ref == RoutingMind.ref()
    assert route_evidence.bindings["scope_ref"] == c.scope.context.scope_ref
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 71)
    assert route_evidence.ref in proposal.primary.act.evidence_refs

    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)

    assert event_revision(snapshot, "evidence_recorded", route_evidence.ref) <
             event_revision(snapshot, "decision_recorded", proposal.primary.decision.ref)

    assert {:ok, view} = Spectre.view(c.scope)
    assert route_evidence in view.evidence
  end

  @tag paid: false
  test "a router cannot launder its derived conclusion into observed payment authority", c do
    {result, route, candidate} = prepare(c, "money back")

    {_route_evidence, candidate} =
      record_route(c, result.turn, route, candidate,
        proposition: "order_paid",
        bindings: %{"order_ref" => c.fixture.refs.order}
      )

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert executions(c) == 0
    assert account(c).available == 10_000
    assert_history(c)
  end

  test "public observability correlates Decision, Act, Attempt and Outcome with one ledger head",
       c do
    {result, _, candidate} = prepare(c, "refund 83")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 83)
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.decisions == [proposal.primary.decision]
    assert view.acts == [proposal.primary.act]
    assert view.attempts == [proposal.primary.attempt]
    assert view.outcomes == [proposal.primary.outcome]
    assert view.pending_act_refs == []
    assert {:ok, acts} = Spectre.acts(c.scope)
    assert acts == view.acts
    assert {:ok, []} = Spectre.duties(c.scope)
    assert {:ok, head} = Spectre.head(c.scope.domain)
    assert head.revision == view.revision
    assert head.head_digest == projection(c).head_digest
    refute inspect({proposal, view}) =~ inspect(c.capability)
    assert_portable_leaves(view)
    assert_history(c)
  end

  test "one Scope's route and execution do not appear in another authenticated Scope's view", c do
    {result, _, candidate} = prepare(c, "refund 19")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 19)
    other = open_other_scope(c)
    assert {:ok, view} = Spectre.view(other)
    assert view.decisions == [] and view.acts == [] and view.attempts == []
    assert view.outcomes == [] and view.duties == [] and view.evidence == []

    assert {:error, {:evidence_outside_scope, _}} =
             Spectre.turn(other, input(c, "money back", "other"),
               context_evidence_refs: candidate.evidence_refs
             )

    assert executions(c) == 1
    assert_history(c)
  end

  test "an authenticated foreign Scope cannot replay a routed Candidate to retrieve its result",
       c do
    {result, _, candidate} = prepare(c, "refund 20")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 20)
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  test "another principal cannot retrieve a routed result through the idempotent proposal path",
       c do
    {result, _, candidate} = prepare(c, "refund 21")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 21)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(c.admin, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  test "a foreign Scope cannot trigger delivery of another agent's committed but pending Act",
       c do
    {result, _, candidate} = prepare(c, "refund 22")
    # Stop at the actual admission/dispatch seam: no hand-built Act or Grant.
    assert {:ok, %{act: act}} =
             Sequencer.submit(c.fixture.server, c.scope.context, candidate)

    assert MapSet.member?(projection(c).pending_dispatches, act.ref)
    assert executions(c) == 0
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert executions(c) == 0
    assert projection(c) == before
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 22)
  end

  @tag paid: false
  test "a non-admitted result is private to its original context and is never reevaluated on retry",
       c do
    {_turn, _, candidate} = prepare(c, "money back")
    assert {:ok, original} = Instance.propose(c.instance, candidate)
    assert original.primary.decision.outcome == :undecidable
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert projection(c) == before
    attrs = c.fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)
    assert {:ok, [_payment]} = Spectre.observe(c.scope, attrs)
    after_payment = projection(c)
    assert {:ok, ^original} = Instance.propose(c.instance, candidate)
    assert projection(c) == after_payment
    assert executions(c) == 0
    assert_history(c)
  end

  test "retry of spoofed-claim refusal belongs to the authenticated caller, not the claimed proposer",
       c do
    {_result, _, candidate} = prepare(c, "refund 26")

    attrs =
      candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:proposer_ref, c.fixture.refs.grantor)

    assert {:ok, spoofed} = Candidate.new(attrs)
    assert {:ok, refused} = Instance.propose(c.instance, spoofed)
    assert refused.primary.decision.outcome == :refused
    assert refused.primary.decision.reasons == [:proposer_context_mismatch]
    before = projection(c)
    assert {:ok, ^refused} = Instance.propose(c.instance, spoofed)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(c.admin, spoofed)
    assert projection(c) == before
    assert executions(c) == 0
    assert_history(c)
  end
end
