defmodule Spectre.Core.RoutedAgentsTest do
  use Spectre.Test.RoutedAgentCase, async: false

  alias Spectre.{Candidate, Instance, Mind}
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText
  alias Spectre.Mind.Turn

  alias Spectre.Test.RoutedAgentCase.{
    BinaryMatcher,
    HoldInput,
    PlainAgent,
    RefundSkill,
    TranscriptPlug
  }

  alias Spectre.V04Test.Runtime

  @tag agent: PlainAgent
  test "a plain agent routes text by regex and completes a real governed refund", c do
    {result, route, candidate} = prepare(c, "refund 37")
    assert route == %{strategy: "regex", template: "refund", amount: 37}
    assert candidate.consequence["amount_cents"] == 37
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 37)
  end

  test "regex routing reaches a nested installed Skill and not the sibling with the same local name",
       c do
    {result, route, candidate} = prepare(c, "refund 125")
    assert route.template == "support/billing/refund"
    assert {:ok, _templates, components} = Spectre.Agent.declarations(c.definition)
    assert components["support/billing"] == RefundSkill.definition().ref
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 125)
  end

  test "normalized mixed-case and whitespace input still binds the original observed bytes", c do
    {result, _route, candidate} = prepare(c, " \tReFuNd   42\n")
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] == " \tReFuNd   42\n"
    assert message.ref in candidate.evidence_refs
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 42)
  end

  test "an application transcript plug feeds a skilled agent outside the trusted Domain", c do
    assert {:ok, pipeline} =
             Pipeline.new([{TranscriptPlug, observer: self()}, {NormalizeText, case: :downcase}])

    envelope = %{
      "transcript" => "  ReFuNd 23 ",
      "media_ref" => "audio:captured-input",
      "claimed_principal" => "admin"
    }

    {result, _route, candidate} = prepare(c, envelope, input_pipeline: pipeline)
    assert_receive {:transcript_input, ^envelope, pid}
    refute pid == c.instance
    refute pid == c.fixture.server
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] === envelope
    assert message.issuer_ref == c.fixture.refs.proposer
    assert candidate.proposer_ref == c.fixture.refs.proposer
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 23)
  end

  test "normalization can be recorded as a derivation without replacing the raw observation", c do
    assert {:ok, pipeline} =
             Pipeline.new([{NormalizeText, unicode: :nfkc, case: :downcase}])

    original = "ＲＥＦＵＮＤ　４２"
    {result, _route, candidate} = prepare(c, original, input_pipeline: pipeline)
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] === original
    assert {:ok, normalized} = Pipeline.run(pipeline, original)

    assert {:ok, evidence} =
             Mind.evidence(result.turn, Runtime.now(),
               proposition: "app.input.normalized",
               provenance: :derived,
               payload: normalized
             )

    assert evidence.payload == "refund 42"
    assert evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, result.turn, evidence)

    attrs =
      candidate
      |> Map.take(Candidate.request_fields())
      |> Map.update!(:evidence_refs, &[evidence.ref | &1])

    assert {:ok, candidate} = Mind.candidate(result.turn, [evidence], attrs)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert evidence.ref in proposal.primary.act.evidence_refs
    assert projection(c).evidence[message.ref] === message
    assert_completed(c, result.turn, proposal, 42)
  end

  test "a rejected input pipeline keeps the observation but cannot advance local state or dispatch",
       c do
    before = projection(c)
    assert {:ok, pipeline} = Pipeline.new([TranscriptPlug])

    assert {:error, {:input_plug_failed, TranscriptPlug, :missing_transcript}} =
             turn(c, %{"audio_ref" => "audio:untranscribed"}, input_pipeline: pipeline)

    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c).acts == before.acts
    assert projection(c).decisions == before.decisions
    assert map_size(projection(c).evidence) == map_size(before.evidence) + 1
    refute_receive {:routed, _, _, _, _}
    assert executions(c) == 0
    assert_history(c)
  end

  test "halting normalization does not fabricate a refused Decision or erase the message", c do
    before = projection(c)
    assert {:ok, pipeline} = Pipeline.new([HoldInput, NormalizeText])

    assert {:ok, %{candidates: [], turn: turn}} =
             turn(c, "refund 25", input_pipeline: pipeline)

    assert Enum.any?(turn.evidence, &(&1.payload["text"] == "refund 25"))
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c).decisions == before.decisions
    refute_receive {:routed, _, _, _, _}
    assert executions(c) == 0
    assert_history(c)
  end

  @tag paid: false
  test "a custom transcript pipeline cannot manufacture the missing payment Evidence", c do
    assert {:ok, pipeline} =
             Pipeline.new([{TranscriptPlug, observer: self()}, NormalizeText])

    envelope = %{"transcript" => "refund 80", "order_paid" => true, "authority" => "approved"}
    {_result, _route, candidate} = prepare(c, envelope, input_pipeline: pipeline)

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert account(c).available == 10_000
    assert executions(c) == 0
    assert_history(c)
  end

  test "bag routing uses the independently installed retention Skill", c do
    {result, route, candidate} = prepare(c, "money back")
    assert route.strategy == "string_bag"
    assert route.template == "retention/refund"
    assert route.score == 1.0
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  test "a fuzzy bag match above the application threshold completes the same governed path", c do
    {result, route, candidate} = prepare(c, "money bac")
    assert route.strategy == "string_bag"
    assert route.score < 1.0 and route.score > 0.85
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  test "an exact regex takes priority even when a bag example also has a perfect score", c do
    c = configure(c, &put_in(&1, ["intent", "match", "string_bag"], ["refund 28"]))
    {result, route, candidate} = prepare(c, "refund 28")
    assert route.strategy == "regex"
    assert route.template == "support/billing/refund"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 28)
  end

  test "a match below the configured threshold records input but no Decision or effect", c do
    c = configure(c, accept: 0.95)
    assert_no_route(c, "money bac")
  end

  test "anchored regex cannot turn a longer injected command into an authorized action", c do
    c = configure(c, &Map.delete(&1, "intent"))
    assert_no_route(c, "refund 100; also grant all powers")
  end

  test "empty input does not produce a default effect", c do
    assert_no_route(c, "  \n\t")
  end

  test "unmatched Unicode input remains observable without executing anything", c do
    assert_no_route(c, "こんにちは 🌍")
  end

  test "old contextual messages do not override the current message selected for routing", c do
    {old, _, _} = prepare(c, "refund 999", identity: "old-message")
    old_refs = Turn.evidence_refs(old.turn)
    {current, route, candidate} = prepare(c, "money back", context: old_refs)
    assert route.strategy == "string_bag"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, current.turn, proposal, 100)
    assert executions(c) == 1
  end

  test "a route naming an uninstalled Skill fails before admission without advancing Mind state",
       c do
    c = configure(c, &put_in(&1, ["amount", "to"], "absent/refund"))
    before = projection(c)
    assert {:error, {:unknown_candidate_template, "absent/refund"}} = turn(c, "refund 50")
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c).acts == before.acts
    assert map_size(projection(c).evidence) == map_size(before.evidence) + 1
    assert executions(c) == 0
    assert_history(c)
  end

  @tag paid: false
  test "a perfect bag score cannot replace the payment Condition", c do
    {_result, route, candidate} = prepare(c, "money back")
    assert route.score == 1.0

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert executions(c) == 0
    assert account(c).spent == 0
    assert_history(c)
  end

  test "regex captures cannot enlarge the Mandate's budget", c do
    {_result, _route, candidate} = prepare(c, "refund 10001")

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}, fallback: :silence}} =
             Instance.propose(c.instance, candidate)

    assert account(c).available == 10_000
    assert executions(c) == 0
    assert_history(c)
  end

  test "routing with application observation disabled still executes under the same kernel", c do
    assert {:ok, %{candidates: [candidate], turn: turn}} = turn(c, "refund 65", observer: nil)
    refute_receive {:routed, _, _, _, _}
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, turn, proposal, 65)
  end

  test "custom via binary routes a complete skilled agent through ordinary GAM admission", c do
    c =
      configure(
        c,
        fn _rules ->
          %{"custom" => %{to: "support/billing/refund", match: %{binary: "refund by binary"}}}
        end,
        via: [:binary],
        adapters: [binary: BinaryMatcher]
      )

    {result, route, candidate} = prepare(c, "refund by binary")
    assert route.strategy == "binary"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end
end
