defmodule Spectre.Agents.ClassificationResultTest do
  use ExUnit.Case, async: true

  alias Spectre.Agent.{Classification, Turn}

  defmodule Assistant do
    use Spectre.Agent, namespace: "customer-care", name: "classifier"
    classifier(:intent, class: "model.classify", via: :model)

    flow :support do
      router(via: [:llm_classifier], classifier: :intent, accept: 0.8, margin: 0.1)
      route(:refund, classify: true)
      route(:shipment, classify: true)
      route(:admin, match: [regex: ~r/^local-only$/])
    end
  end

  setup do
    plan = Assistant.__spectre_plan__()

    turn = %Turn{
      ref: "turn:classifier",
      definition_ref: "definition:classifier",
      flow: :support,
      owner: "",
      input: "Where is my parcel?",
      mind_turn: nil,
      routing: %{name: "support", declaration: plan.flows["support"]}
    }

    %{turn: turn, owner: %{plan: plan}}
  end

  test "preparation exposes only the labels opted into this flow's classifier", c do
    assert {:ok, request} = Classification.prepare(c.owner, c.turn, :intent, c.turn.input)
    assert request["labels"] == ["support/refund", "support/shipment"]
    assert request["turn_ref"] == c.turn.ref

    assert {:error, :classifier_flow_binding_mismatch} =
             Classification.prepare(c.owner, c.turn, :foreign, c.turn.input)

    assert :skip = Classification.evaluate(%{input: c.turn.input}, [])
  end

  test "a confirmed correlated label selects a handler, not an executable action", c do
    {turn, result} = result(c.turn, [%{"label" => "support/shipment", "score" => 0.95}])
    assert {:ok, {:support, :shipment, %{}}} = Classification.route_result(turn, result)
  end

  test "result cannot be transplanted from another turn or replaced outside the continuation",
       c do
    {turn, result} = result(c.turn, [%{"label" => "support/shipment", "score" => 0.95}])

    for changed <- [
          %{result | turn_ref: "foreign"},
          %{result | status: :unclear},
          %{result | operation: {:request, :refund}},
          %{result | data: %{"labels" => []}}
        ] do
      assert {:error, :classifier_result_binding_mismatch} =
               Classification.route_result(turn, changed)
    end
  end

  test "a plausible score never admits a forbidden, fabricated or duplicated label", c do
    for labels <- [
          [%{"label" => "support/admin", "score" => 1.0}],
          [%{"label" => "foreign/refund", "score" => 1.0}],
          [%{"label" => "support/refund", "score" => 1.01}],
          [%{"label" => "support/refund", "score" => "0.99"}],
          [%{"label" => "support/refund", "score" => 0.95, "ignored" => "admin"}],
          List.duplicate(%{"label" => "support/refund", "score" => 0.95}, 2)
        ] do
      {turn, result} = result(c.turn, labels)
      assert {:error, _} = Classification.route_result(turn, result)
    end
  end

  test "low confidence and ambiguity remain distinct, with no invented default handler", c do
    {turn, low} = result(c.turn, [%{"label" => "support/refund", "score" => 0.5}])
    assert :no_match = Classification.route_result(turn, low)

    {turn, unclear} =
      result(c.turn, [
        %{"label" => "support/refund", "score" => 0.9},
        %{"label" => "support/shipment", "score" => 0.9}
      ])

    assert {:ambiguous, labels} = Classification.route_result(turn, unclear)
    assert Enum.sort(labels) == ["support/refund", "support/shipment"]
  end

  defp result(turn, labels) do
    result = %{
      status: :done,
      turn_ref: turn.ref,
      operation: {:classify, :intent},
      data: %{"labels" => labels}
    }

    {%{turn | result: result}, result}
  end
end
