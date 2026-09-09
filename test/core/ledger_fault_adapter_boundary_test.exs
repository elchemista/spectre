defmodule Spectre.LedgerFaultAdapterBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger.Store.{ETS, Mock}

  test "fault configuration cannot fabricate durable success or recursively wrap itself" do
    assert {:error, :invalid_ledger_mock_options} = Mock.start_link(nil)

    for {opts, reason} <- [
          {[:bad], :invalid_ledger_mock_options},
          {[], :ledger_mock_store_required},
          {[store: Mock], :ledger_mock_cannot_wrap_itself},
          {[store: {Mock, []}], :ledger_mock_cannot_wrap_itself},
          {[store: ETS, script: :bad], :invalid_ledger_mock_script},
          {[store: ETS, script: [{:append, :before, {:ok, 1}}]], :synthetic_ledger_append_success}
        ] do
      assert {:error, ^reason} = GenServer.start(Mock, opts)
    end

    assert {:error, :ledger_mock_server_required} = Mock.load("domain", [])
    assert {:error, :invalid_ledger_mock_options} = Mock.load("domain", nil)
  end

  test "a lost-ack script cannot mask the real delegate's CAS rejection" do
    ets = start_supervised!(ETS)
    server = start_supervised!({Mock, store: {ETS, server: ets}})
    opts = [server: server, recorded_at: 1]
    assert {:ok, 1} = Mock.append("domain", "first", [%{"n" => 1}], 0, opts)
    assert :ok = Mock.push(server, {:append, :after, {:error, :ambiguous}})
    assert {:error, :conflict} = Mock.append("domain", "stale", [%{"n" => 2}], 0, opts)

    assert {:error, :synthetic_ledger_append_success} =
             Mock.push(server, {:append, :after, {:ok, 2}})

    assert {:ok, %{revision: 1}} = Mock.load("domain", server: server)
    assert :not_found = Mock.lookup_batch("domain", "stale", server: server)
  end
end
