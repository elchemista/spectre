defmodule Spectre.CoreTest.PayloadRetentionTest do
  use ExUnit.Case, async: true

  alias Spectre.Payload.Retention

  @ref "payload:" <> String.duplicate("a", 64)
  @usage %{recorded_at: 100, revision: 10}
  @head %{recorded_at: 200, revision: 20}

  test "threshold equality creates only normal erasure request attributes" do
    assert {:ok, %{target_ref: @ref, requested_at: 200, reason: "expiry"} = request} =
             Retention.request(@ref, @usage, @head, after_ms: 100, reason: "expiry")

    assert Map.keys(request) |> Enum.sort() === [:reason, :requested_at, :target_ref]
    refute Map.has_key?(request, :affected_refs)
    refute Map.has_key?(request, :reduces_verifiability)
  end

  test "both configured thresholds must elapse, not either one" do
    assert :retain = Retention.request(@ref, @usage, @head, after_ms: 101, after_events: 10)
    assert :retain = Retention.request(@ref, @usage, @head, after_ms: 100, after_events: 11)
    assert {:ok, _} = Retention.request(@ref, @usage, @head, after_ms: 100, after_events: 10)
  end

  test "event retention uses revision distance and an updated usage extends retention" do
    assert {:ok, _} = Retention.request(@ref, @usage, @head, after_events: 10)
    assert :retain = Retention.request(@ref, %{@usage | revision: 11}, @head, after_events: 10)
    assert :retain = Retention.request(@ref, %{@usage | recorded_at: 101}, @head, after_ms: 100)
  end

  test "hold prevents a request even with zero retention" do
    assert :retain =
             Retention.request(@ref, Map.put(@usage, :hold?, true), @head,
               after_ms: 0,
               after_events: 0
             )
  end

  test "future usage cannot become eligible through a different enabled threshold" do
    assert :retain = Retention.request(@ref, %{@usage | recorded_at: 201}, @head, after_events: 0)
    assert :retain = Retention.request(@ref, %{@usage | revision: 21}, @head, after_ms: 0)
  end

  test "invalid policy cannot silently enable immediate deletion planning" do
    for opts <- [
          [],
          [after_ms: nil],
          [after_ms: -1],
          [after_ms: 1.0],
          [after_events: "10"],
          [after_ms: 0, after_ms: 100],
          [after_ms: 1, force: true],
          [after_ms: 1, reason: ""],
          [:bad],
          nil
        ] do
      assert {:error, :invalid_payload_retention_options} =
               Retention.request(@ref, @usage, @head, opts)
    end
  end

  test "only content-addressed payloads and integer recording positions are eligible" do
    for ref <- ["evidence:abc", "payload:bad", nil] do
      assert {:error, _} = Retention.request(ref, @usage, @head, after_ms: 0)
    end

    for position <- [
          nil,
          %{},
          %{@usage | recorded_at: 100.0},
          %{@usage | revision: -1},
          Map.put(@usage, :hold?, :yes)
        ] do
      assert {:error, _} = Retention.request(@ref, position, @head, after_ms: 0)
    end
  end
end
