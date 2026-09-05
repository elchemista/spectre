defmodule Spectre.Core.MeterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Kernel.Meter
  alias Spectre.Kernel.Meter.Account

  property "arbitrary operation sequences conserve quantity, including rejected overdrafts" do
    check all(
            ceiling <- integer(0..10_000),
            operations <-
              list_of(
                tuple(
                  {member_of([
                     :reserve,
                     :release,
                     :settle,
                     :suspend,
                     :resolve_release,
                     :resolve_settle
                   ]), integer(0..10_000)}
                ),
                max_length: 100
              )
          ) do
      Enum.reduce(operations, Account.root("meter", ceiling), fn {operation, quantity}, account ->
        {source, destination} = buckets(operation)
        result = move(operation, account, quantity)

        if quantity <= Map.fetch!(account, source) do
          assert {:ok, updated} = result
          # Independent bucket arithmetic, not just the implementation's validator.
          assert updated ==
                   account
                   |> Map.update!(source, &(&1 - quantity))
                   |> Map.update!(destination, &(&1 + quantity))

          assert updated.ceiling == ceiling
          assert conserved?(updated)
          assert :ok = Account.validate(updated)
          updated
        else
          assert {:error, {:insufficient_meter_quantity, ^source}} = result
          account
        end
      end)
    end
  end

  property "delegation is subtractive and only free child quantity can return" do
    check all(
            ceiling <- integer(0..10_000),
            delegated <- integer(0..ceiling),
            reserved <- integer(0..delegated)
          ) do
      parent = Account.root("meter", ceiling)
      child = Account.child("meter")
      assert {:ok, parent, child} = Meter.delegate(parent, child, delegated)
      assert parent.available + child.available == ceiling
      assert parent.delegated == child.ceiling
      assert {:ok, child} = Meter.reserve(child, reserved)
      assert {:ok, child} = Meter.suspend(child, reserved)
      assert {:ok, parent, child} = Meter.devolve(parent, child)
      assert child.available == 0
      assert child.suspended == reserved
      assert parent.delegated == reserved
      assert parent.available + child.suspended == ceiling
      assert conserved?(parent) and conserved?(child)
    end
  end

  test "multi-meter reservations reject an overdraft without partial balances" do
    accounts = %{"a" => Account.root("a", 5), "b" => Account.root("b", 2)}

    assert {:error, {:insufficient_meter_quantity, "b"}} =
             Meter.reserve_many(%{"a" => 3, "b" => 3}, accounts)

    assert {:ok, updated, %{"a" => 3, "b" => 2}} =
             Meter.reserve_many(%{"a" => 3, "b" => 2}, accounts)

    assert updated["a"].available == 2
    assert updated["b"].available == 0
    assert accounts["a"].reserved == 0
  end

  test "recontainment reports a deficit instead of inventing released resources" do
    accounts = %{"a" => Account.root("a", 2)}

    assert {:ok, updated, %{"a" => 2}, %{"a" => 3}} =
             Meter.recontain_many(%{"a" => 5}, accounts)

    assert updated["a"].suspended == 2
    assert updated["a"].available == 0

    assert {:error, {:unknown_meter, "unknown"}} =
             Meter.recontain_many(%{"unknown" => 1}, accounts)
  end

  test "malformed quantities, mismatched meters and unconserved accounts fail closed" do
    account = Account.root("a", 5)

    for quantity <- [-1, 0.5, "1", nil] do
      assert {:error, :invalid_meter_quantity} = Meter.reserve(account, quantity)
    end

    assert {:error, :incompatible_meter_allocations} =
             Meter.delegate(account, Account.child("b"), 1)

    assert {:error, {:meter_conservation_violation, _}} =
             Meter.reserve(%{account | available: 6}, 1)
  end

  defp move(:resolve_release, account, n), do: Meter.resolve_suspended(account, n, :release)
  defp move(:resolve_settle, account, n), do: Meter.resolve_suspended(account, n, :settle)
  defp move(operation, account, n), do: apply(Meter, operation, [account, n])

  defp buckets(:reserve), do: {:available, :reserved}
  defp buckets(:release), do: {:reserved, :available}
  defp buckets(:settle), do: {:reserved, :spent}
  defp buckets(:suspend), do: {:reserved, :suspended}
  defp buckets(:resolve_release), do: {:suspended, :available}
  defp buckets(:resolve_settle), do: {:suspended, :spent}

  defp conserved?(account) do
    values =
      Map.take(account, [:available, :reserved, :suspended, :spent, :delegated]) |> Map.values()

    Enum.all?(values, &(&1 >= 0)) and Enum.sum(values) == account.ceiling
  end
end
