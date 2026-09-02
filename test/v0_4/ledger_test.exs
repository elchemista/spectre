defmodule Spectre.V04Test.LedgerTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.Store.ETS

  setup do
    child_spec =
      Supervisor.child_spec({ETS, []},
        id: {ETS, make_ref()},
        restart: :temporary
      )

    server = start_supervised!(child_spec)
    {:ok, store: {ETS, server: server}}
  end

  test "a batch is non-empty and competing CAS appends expose one complete winner", %{
    store: store
  } do
    domain_ref = "domain:ledger-cas"

    assert {:error, :empty_ledger_batch} =
             Ledger.append(store, domain_ref, "batch:empty", [], 0)

    assert :not_found = Ledger.load(store, domain_ref)

    left = [%{"side" => "left", "index" => 1}, %{"side" => "left", "index" => 2}]
    right = [%{"side" => "right", "index" => 1}, %{"side" => "right", "index" => 2}]

    tasks = [
      Task.async(fn -> Ledger.append(store, domain_ref, "batch:left", left, 0) end),
      Task.async(fn -> Ledger.append(store, domain_ref, "batch:right", right, 0) end)
    ]

    replies = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(replies, &match?({:ok, 2}, &1)) == 1
    assert Enum.count(replies, &match?({:error, :conflict}, &1)) == 1

    assert {:ok, snapshot} = Ledger.load(store, domain_ref)
    assert snapshot.revision == 2
    assert length(snapshot.entries) == 2
    assert Enum.map(snapshot.entries, & &1.payload) in [left, right]
    assert snapshot.entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1
  end

  test "an identical retry is idempotent and batch identity cannot be reused", %{store: store} do
    domain_ref = "domain:ledger-idempotency"
    batch_id = "batch:stable"
    payloads = [%{"event" => "first"}, %{"event" => "second"}]

    assert {:ok, 2} = Ledger.append(store, domain_ref, batch_id, payloads, 0)
    assert {:ok, first_info} = Ledger.lookup_batch(store, domain_ref, batch_id)

    assert {:ok, 2} = Ledger.append(store, domain_ref, batch_id, payloads, 0)
    assert {:ok, ^first_info} = Ledger.lookup_batch(store, domain_ref, batch_id)

    assert {:error, {:batch_identity_conflict, ^batch_id}} =
             Ledger.append(store, domain_ref, batch_id, [%{"event" => "different"}], 0)

    assert {:ok, snapshot} = Ledger.load(store, domain_ref)
    assert snapshot.revision == 2
    assert Enum.map(snapshot.entries, & &1.payload) == payloads
  end

  test "export verification detects content tampering, reordering and a truncated batch", %{
    store: store
  } do
    domain_ref = "domain:ledger-audit"
    batch_id = "batch:audit"

    payloads = [
      %{"event" => "one"},
      %{"event" => "two"},
      %{"event" => "three"}
    ]

    assert {:ok, 3} = Ledger.append(store, domain_ref, batch_id, payloads, 0)
    assert {:ok, exported} = Ledger.export(store, domain_ref)
    assert {:ok, verified} = Ledger.verify(exported)
    assert verified.revision == 3
    assert Enum.map(verified.entries, & &1.payload) == payloads

    [first | rest] = exported["entries"]
    tampered_first = put_in(first, ["payload", "event"], "tampered")
    tampered = Map.put(exported, "entries", [tampered_first | rest])

    assert {:error, {:ledger_entry_digest_mismatch, 1}} = Ledger.verify(tampered)

    reordered = Map.put(exported, "entries", Enum.reverse(exported["entries"]))

    assert {:error, {:ledger_revision_gap, 1, 3}} = Ledger.verify(reordered)

    truncated =
      exported
      |> Map.put("entries", [first])
      |> Map.put("revision", 1)
      |> Map.put("head_digest", first["digest"])

    assert {:error, {:incomplete_ledger_batch, ^batch_id}} = Ledger.verify(truncated)
  end
end
