Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.MeterAccountBoundaryTest do
  use ExUnit.Case, async: true
  alias Spectre.GAM.Kernel.Meter
  alias Spectre.GAM.Kernel.Meter.Account

  test "availability validates conservation before answering a quantity question" do
    account = Account.root("EUR", 100)
    assert Meter.available?(account, 100)
    refute Meter.available?(account, 101)
    refute Meter.available?(account, 1.0)
    refute Meter.available?(%{account | available: 101}, 1)
    assert {:error, :invalid_meter_account} = Account.validate(%{})
    assert {:error, :invalid_meter_account} = Meter.reserve(%{}, 1)

    assert {:error, {:invalid_suspended_disposition, :forget}} =
             Meter.resolve_suspended(account, 1, :forget)
  end

  test "untyped or misindexed balances never allocate a different Meter" do
    account = Account.root("EUR", 100)
    assert {:error, :invalid_meter_accounts} = Meter.plan_reservations(%{"EUR" => 1}, [])

    assert {:error, {:meter_account_ref_mismatch, "USD", "EUR"}} =
             Meter.reserve_many(%{"USD" => 1}, %{"USD" => account})

    assert {:error, {"EUR", _}} =
             Meter.recontain_many(%{"EUR" => 1}, %{"EUR" => %{account | spent: 1}})

    for {parent, child} <- [{nil, account}, {account, nil}] do
      assert {:error, :invalid_meter_account} = Meter.delegate(parent, child, 1)
      assert {:error, :invalid_meter_account} = Meter.devolve(parent, child)
      assert {:error, :invalid_meter_account} = Meter.devolve(parent, child, 1)
    end

    assert {:error, _} = Meter.delegate(%{account | spent: 1}, account, 1)
  end
end
