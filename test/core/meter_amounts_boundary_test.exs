defmodule Spectre.Core.MeterAmountsBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Kernel.Meter.Amounts

  test "host descriptors normalize to one canonical quantity map" do
    expected = %{"a" => 1, "b" => 2, "c" => 3}

    assert {:ok, ^expected} =
             Amounts.normalize([
               %{meter_ref: "a", quantity: 1},
               %{"meter_ref" => "b", "quantity" => 2},
               {"c", 3}
             ])

    assert {:ok, ^expected} = Amounts.normalize(expected)
    assert {:ok, %{}} = Amounts.normalize([])
    assert {:error, :empty_meter_amounts} = Amounts.non_empty([])
    assert {:error, :empty_meter_amounts} = Amounts.non_empty(%{})
    assert {:ok, ^expected} = Amounts.non_empty(expected)
  end

  test "different descriptor encodings cannot hide a duplicate reservation" do
    for duplicate <- [
          %{meter_ref: "a", quantity: 1},
          %{"meter_ref" => "a", "quantity" => 1},
          {"a", 1}
        ] do
      assert {:error, {:duplicate_meter_reservation, "a"}} =
               Amounts.normalize([{"a", 2}, duplicate])
    end
  end

  test "malformed descriptors, quantities and improper list tails never raise" do
    for value <- [
          nil,
          1,
          :meter,
          [nil],
          [%{quantity: 1}],
          [{"a", 1, 2}],
          %{"a" => 1.0},
          %{"a" => -1},
          %{"a" => 0},
          %{a: 1},
          [{"a", 1} | :tail]
        ] do
      assert {:error, _} = Amounts.normalize(value)
    end
  end

  test "a partition is disjoint, complete and exact in canonical quantity types" do
    total = %{"a" => 2, "b" => 3}
    assert :ok = Amounts.exact_partition(total, %{"a" => 2}, %{"b" => 3})
    assert :ok = Amounts.exact_partition(total, total, %{})
    assert :ok = Amounts.exact_partition(%{}, %{}, %{})

    for {left, right} <- [
          {%{"a" => 1}, %{"a" => 1, "b" => 3}},
          {%{"a" => 2}, %{}},
          {%{"a" => 2, "c" => 1}, %{"b" => 3}},
          {%{"a" => 2.0}, %{"b" => 3}},
          {%{"a" => "2"}, %{"b" => 3}}
        ] do
      assert {:error, :invalid_meter_partition} = Amounts.exact_partition(total, left, right)
    end

    assert {:error, :invalid_meter_partition} =
             Amounts.exact_partition(%{"a" => -1}, %{"a" => -1}, %{})

    assert {:error, :invalid_meter_partition} = Amounts.exact_partition(nil, %{}, %{})
  end
end
