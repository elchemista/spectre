defmodule SpectreInferenceBudgetContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.Budget
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Usage

  test "reservations are bounded, snapshot the pre-reservation capacity, and are idempotent" do
    budget =
      Budget.new("inference-budget",
        limits: %{attempts: 2, output_tokens: 10, total_tokens: 20}
      )

    requested = %Usage{output_tokens: 6, total_tokens: 6}

    assert {:ok, reserved, %BudgetSnapshot{} = snapshot} =
             Budget.reserve(budget, "attempt-one", requested)

    assert snapshot.attempt_id == "attempt-one"
    assert snapshot.remaining == %{output_tokens: 6, total_tokens: 6}
    assert snapshot.reserved == requested
    assert Budget.remaining(reserved) == %{attempts: 1, output_tokens: 4, total_tokens: 14}

    assert {:ok, ^reserved, ^snapshot} = Budget.reserve(reserved, "attempt-one", requested)

    assert {:error, {:inference_budget_exhausted, :output_tokens}} =
             Budget.reserve(reserved, "attempt-two", %Usage{output_tokens: 5})
  end

  test "confirmed settlement releases unused capacity and duplicate settlement is exact" do
    budget = Budget.new("confirmed", limits: %{attempts: 2, output_tokens: 10})

    {:ok, reserved, _snapshot} =
      Budget.reserve(budget, "attempt-one", %Usage{output_tokens: 10})

    usage = %Usage{output_tokens: 3, total_tokens: 3}
    assert {:ok, settled} = Budget.settle(reserved, "attempt-one", usage, :confirmed)
    assert settled.consumed == usage
    assert settled.reservations == %{}
    assert Budget.remaining(settled) == %{attempts: 1, output_tokens: 7}

    assert {:ok, ^settled} = Budget.settle(settled, "attempt-one", usage, :confirmed)

    assert {:error, {:inference_budget_settlement_conflict, "attempt-one"}} =
             Budget.settle(
               settled,
               "attempt-one",
               %Usage{output_tokens: 4, total_tokens: 4},
               :confirmed
             )
  end

  test "ambiguous settlement retains the worst-case reservation until reconciliation" do
    budget = Budget.new("ambiguous", limits: %{attempts: 2, output_tokens: 10})

    {:ok, reserved, _snapshot} =
      Budget.reserve(budget, "attempt-one", %Usage{output_tokens: 10})

    ambiguous_usage = %Usage{output_tokens: 2, total_tokens: 2}

    assert {:ok, ambiguous} =
             Budget.settle(reserved, "attempt-one", ambiguous_usage, :ambiguous)

    assert ambiguous.reservations == reserved.reservations
    assert ambiguous.consumed == %Usage{}
    assert Budget.remaining(ambiguous) == %{attempts: 1, output_tokens: 0}

    assert {:error, {:inference_budget_exhausted, :output_tokens}} =
             Budget.reserve(ambiguous, "attempt-two", %Usage{output_tokens: 1})

    assert {:error, {:inference_budget_settlement_regressed, "attempt-one"}} =
             Budget.settle(
               ambiguous,
               "attempt-one",
               %Usage{output_tokens: 1, total_tokens: 1},
               :confirmed
             )

    confirmed_usage = %Usage{output_tokens: 3, total_tokens: 3}

    assert {:ok, reconciled} =
             Budget.settle(ambiguous, "attempt-one", confirmed_usage, :confirmed)

    assert reconciled.reservations == %{}
    assert reconciled.consumed == confirmed_usage
    assert Budget.remaining(reconciled) == %{attempts: 1, output_tokens: 7}
  end

  test "cost accounting is fail-closed without a pinned pricing reference" do
    assert_raise ArgumentError, ~r/inference_cost_budget_requires_pricing_ref/, fn ->
      Budget.new("cost-without-pricing", limits: %{cost: 1.0})
    end

    budget =
      Budget.new("cost-with-pricing",
        limits: %{attempts: 1, cost: 1.0},
        pricing_ref: "pricing:test:v1",
        estimation_policy: :provider
      )

    assert {:ok, reserved, %BudgetSnapshot{pricing_ref: "pricing:test:v1"}} =
             Budget.reserve(budget, "attempt-one", %Usage{cost: 1.0})

    assert {:error, {:inference_budget_exhausted, :attempts}} =
             Budget.reserve(reserved, "attempt-two", %Usage{})
  end

  test "portable budget and usage validation rejects every malformed accounting shape" do
    assert %Budget{limits: %{}} = Budget.new("default-budget")

    budget =
      Budget.new("validated-budget",
        limits: %{attempts: 2, output_tokens: 10},
        estimation_policy: :provider
      )

    invalid = [
      {%{budget | inference_id: ""}, :invalid_inference_budget_id},
      {%{budget | deadline_at: -1}, :invalid_inference_budget_deadline},
      {%{budget | pricing_ref: ""}, :invalid_inference_budget_pricing_ref},
      {%{budget | estimation_policy: :guessed}, :invalid_inference_budget_estimation_policy},
      {%{budget | limits: %URI{}}, :invalid_inference_budget_limits},
      {%{budget | limits: %{unknown: 1}}, :invalid_inference_budget_limits},
      {%{budget | reservations: %URI{}}, :invalid_inference_budget_accounting},
      {%{budget | reservations: %{"attempt" => :invalid}}, :invalid_inference_budget_accounting},
      {%{budget | settlements: %URI{}}, :invalid_inference_budget_accounting},
      {%{budget | settlements: %{"attempt" => %{usage: %Usage{}, status: :unknown}}},
       :invalid_inference_budget_accounting},
      {%{budget | consumed: %{budget.consumed | output_tokens: -1}}, :invalid_inference_usage}
    ]

    Enum.each(invalid, fn {candidate, reason} ->
      assert {:error, ^reason} = Budget.validate(candidate)
    end)

    assert {:error, :invalid_inference_usage} = Usage.validate(:invalid)
    assert %Usage{input_tokens: 2} = Usage.new(%{"input_tokens" => 2})

    assert_raise ArgumentError, "inference usage must be non-negative", fn ->
      Usage.new(output_tokens: -1)
    end

    {:ok, reserved, _snapshot} = Budget.reserve(budget, "settled-attempt", %Usage{})
    {:ok, settled} = Budget.settle(reserved, "settled-attempt", %Usage{}, :confirmed)

    assert {:error, {:inference_attempt_already_settled, "settled-attempt"}} =
             Budget.reserve(settled, "settled-attempt", %Usage{})
  end
end
