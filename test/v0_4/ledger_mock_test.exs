defmodule Spectre.V04Test.LedgerMockTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.Store, as: LedgerStore
  alias Spectre.Ledger.Store.{ETS, Mock}

  setup do
    start_supervised!({ETS, []})
    |> then(fn ets ->
      mock =
        start_supervised!(
          {Mock,
           store: {ETS, server: ets},
           script: [
             {:append, :before, {:error, :ambiguous}},
             {:append, :after, {:error, :ambiguous}}
           ]}
        )

      {:ok, store: {Mock, server: mock}, mock: mock, ets: ets}
    end)
  end

  test "scripts uncertainty before and after a real commit without changing semantics", context do
    domain = "mock-domain"
    first = [%{"event" => "first"}]
    second = [%{"event" => "second"}]

    assert {:error, :ambiguous} = append(context.store, domain, "batch-1", first, 0)
    assert :not_found = Ledger.load(context.store, domain)

    assert {:error, :ambiguous} = append(context.store, domain, "batch-1", first, 0)
    assert {:ok, 1} = append(context.store, domain, "batch-1", first, 0)
    assert {:ok, 2} = append(context.store, domain, "batch-2", second, 1)

    assert {:ok, snapshot} = Ledger.load(context.store, domain)
    assert snapshot.revision == 2
    assert Enum.map(snapshot.entries, & &1.payload) == first ++ second

    assert Enum.map(Mock.calls(context.mock), & &1.operation) == [
             :append,
             :load,
             :append,
             :append,
             :append,
             :load
           ]
  end

  test "rejects malformed scripts instead of silently ignoring them", context do
    # A failed start_link can also deliver an exit signal on newer OTP versions.
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_ledger_mock_action, {:append, :sometimes, :ok}}} =
             Mock.start_link(
               store: {ETS, server: context.ets},
               script: [{:append, :sometimes, :ok}]
             )
  end

  # The adapter receives explicit trusted acquisition time; Ledger is read-only.
  defp append(store, domain, batch, payloads, revision, opts \\ []) do
    LedgerStore.append(
      store,
      domain,
      batch,
      payloads,
      revision,
      Keyword.put_new(opts, :recorded_at, revision + 1)
    )
  end
end
