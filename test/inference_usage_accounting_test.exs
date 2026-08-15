defmodule SpectreInferenceUsageAccountingTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Response
  alias Spectre.Inference.Usage
  alias Spectre.Inference.UsageAccounting

  test "provider policy preserves authoritative token counters" do
    response =
      Response.new(%{
        text: String.duplicate("x", 100),
        latency_ms: 12,
        usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
      })

    {usage, quality} = UsageAccounting.complete_response(response, snapshot(:provider))

    assert usage.output_tokens == 1
    assert usage.total_tokens == 3
    assert usage.output_bytes == 100
    assert usage.duration_ms == 12
    assert quality == :provider
  end

  test "conservative floors are explicit estimates and remain sticky" do
    response =
      Response.new(%{
        text: String.duplicate("x", 100),
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      })

    {usage, quality} = UsageAccounting.complete_response(response, snapshot(:conservative))

    assert usage.input_tokens == 4
    assert usage.output_tokens == 25
    assert usage.total_tokens == 29
    assert quality == :estimated

    {stream_usage, stream_quality} =
      UsageAccounting.merge_stream(
        Usage.new(usage),
        [%{input_tokens: 4, output_tokens: 30, total_tokens: 34}],
        snapshot(:conservative),
        quality,
        :provider
      )

    assert stream_usage.output_tokens == 30
    assert stream_quality == :estimated
  end

  test "unavailable outcomes never manufacture provider usage" do
    assert {%{}, :unavailable} =
             UsageAccounting.complete_response_outcome(
               {:error, :provider_failed},
               snapshot(:provider)
             )
  end

  defp snapshot(policy) do
    BudgetSnapshot.new(
      inference_id: "usage-accounting",
      attempt_id: "attempt-one",
      reserved: %Usage{input_tokens: 4},
      estimation_policy: policy
    )
  end
end
