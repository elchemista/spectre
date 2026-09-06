defmodule Spectre.Core.MindContextWindowTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Mind.{Context, Turn}
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Mind do
    @behaviour Spectre.Mind
    def ref, do: "mind:window"
    def deliberate(_turn, _opts), do: {:ok, []}
  end

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "recent context is bounded and does not weaken kernel recognition" do
    f = fixture(max_events: 2, max_evidence: 1)
    payment = Fixture.paid_evidence(f)
    assert {:ok, ^payment} = Fixture.observe_payment(f, payment)
    counter = Fixture.paid_evidence(f, %{stance: :contradicts})
    assert {:ok, ^counter} = Fixture.observe_payment(f, counter)
    for n <- 1..3, do: turn(f, "new:#{n}")
    turn = turn(f, "latest")
    assert [%{proposition: "latest"}] = turn.evidence
    assert turn.context_window.partial?
    assert turn.context_window.evidence_count == 1
    assert turn.context_window.revision == Sequencer.projection(f.server).revision
    candidate = Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])

    assert {:ok, %{decision: decision, grant: nil}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    refute decision.outcome == :admitted
    assert Map.has_key?(Sequencer.projection(f.server).evidence, counter.ref)
  end

  test "bytes are bounded even when one record is much larger than the window" do
    f = fixture(max_events: 100, max_evidence: 50, max_bytes: 10)
    turn = turn(f, "large", String.duplicate("x", 10_000))
    assert turn.evidence == []
    assert turn.context_window.evidence_bytes == 0
    assert turn.context_window.partial?
    assert map_size(Sequencer.projection(f.server).evidence) == 1
  end

  test "zero event budget omits context, not ledger records" do
    f = fixture(max_events: 0)
    turn = turn(f, "zero")
    assert turn.evidence == []
    assert map_size(Sequencer.projection(f.server).evidence) == 1
  end

  test "selection metadata is bound by the Turn seal" do
    f = fixture(max_events: 10)
    turn = turn(f, "sealed")
    state = :sys.get_state(f.server)
    assert :ok = Turn.verify_seal(turn, state.grant_secret)
    changed = %{turn | context_window: %{turn.context_window | partial?: false, revision: 0}}
    assert {:error, :turn_authentication_failed} = Turn.verify_seal(changed, state.grant_secret)
  end

  test "limits reject floats, negative values, unknown options and malformed input" do
    for limits <- [
          [max_events: 1.0],
          [max_evidence: -1],
          [max_bytes: :infinity],
          [unknown: 1],
          [:bad],
          %{}
        ] do
      assert {:error, :invalid_mind_context_limits} = Context.normalize(limits)
    end
  end

  defp fixture(limits) do
    f =
      Fixture.start_domain(
        namespace: "context-window-#{System.unique_integer([:positive])}",
        mind: Mind,
        context: limits
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    f
  end

  defp turn(f, proposition, payload \\ "input") do
    input = %{
      proposition: proposition,
      issuer_ref: f.refs.proposer,
      provenance: :observed,
      bindings: %{},
      payload: payload
    }

    assert {:ok, {Mind, turn}} = Sequencer.begin_turn(f.server, Fixture.context(f), input, [])
    turn
  end
end
