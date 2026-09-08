defmodule Spectre.Agents.HandlerRuntimeTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Instance
  alias Spectre.Router.SemanticCache
  alias Spectre.Store.Memory, as: ApplicationStore

  test "multiple flows still require an explicit host choice", c do
    assert {:error, :agent_flow_required} = Instance.turn(c.instance, input(c, "refund 20"))
    assert Instance.current_turn(c.instance) == nil
    refute_received {:handler_execution, _, _, _}
  end

  test "routing prepares a request but cannot mint an Act or call its executor", c do
    before = Sequencer.projection(c.fixture.server)
    {turn, request} = prepare(c, " REFUND 37 ")
    assert turn.selection.via == "regex"
    assert request.candidate.consequence["amount_cents"] == 37
    assert request.candidate.row == c.fixture.row
    assert request.candidate.scope_ref == c.fixture.refs.scope
    assert request.candidate.proposer_ref == c.fixture.refs.proposer
    assert turn.ref == request.turn_ref
    assert Instance.current_turn(c.instance) === turn
    after_turn = Sequencer.projection(c.fixture.server)
    assert after_turn.acts === before.acts
    assert after_turn.decisions === before.decisions
    assert map_size(after_turn.evidence) > map_size(before.evidence)
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "advance commits before execution and returns durable result to the handler", c do
    {turn, request} = prepare(c, "refund 37")
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert completed.ref == turn.ref
    assert completed.requests == []
    assert completed.result.status == :done
    assert completed.result.details.primary.outcome.status == :succeeded
    assert_receive {:handler_execution, executor, act, attempt}
    refute executor == c.instance
    refute executor == c.fixture.server
    projection = Sequencer.projection(c.fixture.server)
    assert projection.acts[act.ref] == act
    assert projection.attempts[attempt.ref] == attempt
    assert Instance.state(c.instance).value.result == :done

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "bag selection passes through the same governed request and review path", c do
    {turn, request} = prepare(c, "refund my order")
    assert turn.selection.via == "string_bag"
    assert {:ok, result} = Instance.advance(c.instance, request)
    assert {:quarantined, id, revision} = result.result.learning
    assert id == request.ref
    assert {:ok, %{examples: [example]}} = SemanticCache.examples(c.cache)
    assert example.revision == revision
    refute example.verified
    assert example.label == "support/refund"
    assert_replay(c)
  end

  test "reviewed cache nomination neither bypasses the kernel nor learns from itself", c do
    {:ok, example} = SemanticCache.put(c.cache, %{text: "give it back", label: "support/refund"})
    {:ok, _} = SemanticCache.verify(c.cache, example.id, example.revision)
    {turn, request} = prepare(c, "give it back")
    assert turn.selection.via == "semantic_cache"
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert completed.result.status == :done
    assert completed.result.learning == :not_requested
    assert {:ok, %{count: 1}} = SemanticCache.info(c.cache)
    evidence = Sequencer.projection(c.fixture.server).evidence

    assert Enum.any?(evidence, fn {_ref, e} ->
             e.provenance == :derived and
               get_in(e.payload, ["source", "example_ref"]) == example.id
           end)

    assert_replay(c)
  end

  test "cache cannot grant an otherwise refused operation", c do
    {_turn, request} = prepare(c, "refund 999999")
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert completed.result.status == :refused
    assert completed.result.learning == :not_requested
    assert completed.result.details.primary.act == nil
    assert {:ok, %{count: 0}} = SemanticCache.info(c.cache)
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "no match and ambiguity are handler messages, not manufactured Decisions", c do
    before = Sequencer.projection(c.fixture.server).decisions

    assert {:ok, %{requests: []}} =
             Instance.turn(c.instance, input(c, "unmatched"), flow: :support)

    assert Instance.state(c.instance).value.last_route == :no_match
    assert {:ok, %{requests: []}} = Instance.turn(c.instance, input(c, "both"), flow: :uncertain)
    assert Instance.state(c.instance).value.last_route == :ambiguous
    assert Sequencer.projection(c.fixture.server).decisions === before
    refute_received {:handler_execution, _, _, _}
  end

  test "modified, foreign and superseded tickets cannot submit", c do
    {_first, request} = prepare(c, "refund 20")

    for changed <- [
          %{request | ref: "forged"},
          %{request | instance_ref: "foreign"},
          %{request | revision: request.revision + 1},
          %{request | candidate: %{request.candidate | identity_key: "forged"}}
        ] do
      assert {:error, :invalid_or_superseded_instance_request} =
               Instance.advance(c.instance, changed)
    end

    {_second, current} = prepare(c, "refund 21")

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    assert {:ok, completed} = Instance.advance(c.instance, current)
    assert completed.result.status == :done
    assert_receive {:handler_execution, _, act, _}
    assert act.consequence["amount_cents"] == 21
    refute_received {:handler_execution, _, _, _}
  end

  @tag gated: true
  test "pending work leaves readers responsive and duplicate advance cannot execute twice", c do
    {_turn, request} = prepare(c, "refund 20")
    assert {:pending, operation} = Instance.advance(c.instance, request, wait: 0)
    assert operation == request.ref
    assert_receive {:handler_execution, executor, _act, _attempt}, 1000
    assert :pending = Instance.operation(c.instance, operation)
    assert Instance.state(c.instance, 200).value.count == 1
    assert Instance.info(c.instance, 200).definition_ref == c.definition.ref
    assert {:ok, definition} = Instance.definition(c.instance, 200)
    assert definition == c.definition
    assert Instance.current_turn(c.instance, 200).requests == []

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    # The checkpoint queues behind advance and gives a deterministic completion
    # barrier, without polling, sleeping or re-submitting the request.
    store = start_supervised!(ApplicationStore)

    saved =
      Task.async(fn ->
        Instance.checkpoint(c.instance, {ApplicationStore, server: store}, "finished", 0)
      end)

    send(executor, :release)
    assert {:ok, 1} = Task.await(saved)
    assert {:ok, completed} = Instance.operation(c.instance, operation)
    assert completed.result.status == :done
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  @tag gated: true, max_pending_operations: 0
  test "busy rejection does not lose or cancel the active operation", c do
    {_turn, request} = prepare(c, "refund 20")
    assert {:pending, operation} = Instance.advance(c.instance, request, wait: 0)
    assert_receive {:handler_execution, executor, _act, _attempt}, 1000

    assert {:error, :instance_busy} =
             Instance.turn(c.instance, input(c, "refund 21"), flow: :support)

    assert :pending = Instance.operation(c.instance, operation)
    send(executor, :release)
  end

  for {outcome, status} <- [
        failed: :failed,
        definitive_no_effect: :no_effect,
        ambiguous: :unclear
      ] do
    @tag status: outcome
    test "executor #{outcome} remains #{status} and never becomes a cache approval", c do
      {_turn, request} = prepare(c, "refund 20")
      assert {:ok, completed} = Instance.advance(c.instance, request)
      assert completed.result.status == unquote(status)
      assert completed.result.details.primary.outcome.status == unquote(outcome)
      assert completed.result.learning == :not_requested
      assert {:ok, %{count: 0}} = SemanticCache.info(c.cache)
      assert_replay(c)
    end
  end

  test "mounting the same Skill twice keeps independent state and exact child publication", c do
    assert {:ok, first} =
             Instance.turn(c.instance, input(c, "refund"),
               flow: "billing/support",
               context_evidence_refs: [c.fixture.refs.payment_evidence]
             )

    assert first.owner == "billing/"

    assert first.definition_ref ==
             c.definition.body["authoring"]["component_definitions"]["billing"]["ref"]

    assert Instance.state(c.instance).value.count == 0
    assert {:ok, completed} = Instance.advance(c.instance, hd(first.requests))
    assert completed.result.status == :done

    assert {:ok, _second} =
             Instance.turn(c.instance, input(c, "refund"),
               flow: "returns/support",
               context_evidence_refs: [c.fixture.refs.payment_evidence]
             )

    store = start_supervised!(ApplicationStore)
    config = {ApplicationStore, server: store}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "skills", 0)
    assert {:ok, 1, saved} = Spectre.Store.get(config, "skills")
    assert saved["components"]["billing/"][:value][:count] == 1
    assert saved["components"]["billing/"][:value][:result] == :done
    assert saved["components"]["returns/"][:value][:count] == 1
    refute Map.has_key?(saved["components"]["returns/"][:value], :result)
    refute Map.has_key?(saved, "scope")
    refute Map.has_key?(saved, "requests")
    assert_replay(c)
  end

  test "observability correlates durable results without publishing input or consequence", c do
    {_turn, request} = prepare(c, "refund 20")
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert_receive {:spectre_agent_event, [:spectre, :agent, :result], %{}, metadata}
    assert metadata.request_ref == request.ref
    assert metadata.act_ref == completed.result.details.primary.act.ref
    assert metadata.outcome_ref == completed.result.details.primary.outcome.ref
    refute Map.has_key?(metadata, :input)
    refute Map.has_key?(metadata, :consequence)
    refute Map.has_key?(metadata, :capability)
    refute Map.has_key?(metadata, :options)
  end
end
