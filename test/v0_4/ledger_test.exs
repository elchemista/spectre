defmodule Spectre.V04Test.LedgerTest do
  use ExUnit.Case, async: true

  alias Spectre.Ledger
  alias Spectre.Ledger.Store
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
             append(store, domain_ref, "batch:empty", [], 0)

    assert :not_found = Ledger.load(store, domain_ref)

    left = [%{"side" => "left", "index" => 1}, %{"side" => "left", "index" => 2}]
    right = [%{"side" => "right", "index" => 1}, %{"side" => "right", "index" => 2}]

    tasks = [
      Task.async(fn -> append(store, domain_ref, "batch:left", left, 0) end),
      Task.async(fn -> append(store, domain_ref, "batch:right", right, 0) end)
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

    assert {:ok, 2} = append(store, domain_ref, batch_id, payloads, 0)
    assert {:ok, first_info} = Ledger.lookup_batch(store, domain_ref, batch_id)

    assert {:ok, 2} = append(store, domain_ref, batch_id, payloads, 0)
    assert {:ok, ^first_info} = Ledger.lookup_batch(store, domain_ref, batch_id)

    assert {:error, {:batch_identity_conflict, ^batch_id}} =
             append(store, domain_ref, batch_id, [%{"event" => "different"}], 0)

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

    assert {:ok, 3} = append(store, domain_ref, batch_id, payloads, 0)
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

  test "domain cursors and batch identities are isolated in a shared table", %{store: store} do
    assert :not_found = Ledger.lookup_batch(store, "missing", "same-batch")
    assert :not_found = Ledger.export(store, "missing")

    assert {:ok, 2} = append(store, "left", "same-batch", [%{"n" => 1}, %{"n" => 2}], 0)
    assert {:ok, 1} = append(store, "right", "same-batch", [%{"n" => 3}], 0)
    assert {:ok, 3} = append(store, "left", "next-batch", [%{"n" => 4}], 2)
    assert {:ok, left} = Ledger.load(store, "left")
    assert {:ok, right} = Ledger.load(store, "right")
    assert Enum.map(left.entries, & &1.payload["n"]) == [1, 2, 4]
    assert Enum.map(right.entries, & &1.payload["n"]) == [3]
    assert {:ok, %{last_revision: 2}} = Ledger.lookup_batch(store, "left", "same-batch")
    assert {:ok, %{last_revision: 1}} = Ledger.lookup_batch(store, "right", "same-batch")
    assert :not_found = Ledger.lookup_batch(store, "right", "next-batch")
    assert {:ok, exported} = Ledger.export(store, "left")
    assert {:ok, ^left} = Ledger.verify(exported)
  end

  test "before/after commit ambiguity preserves the entire batch and retry identity", %{
    store: store
  } do
    payloads = [%{"n" => 1}, %{"n" => 2}]

    assert {:error, :ambiguous} =
             append(store, "domain", "batch", payloads, 0, fault: :before_commit)

    assert :not_found = Ledger.load(store, "domain")
    assert :not_found = Ledger.lookup_batch(store, "domain", "batch")

    assert {:error, :ambiguous} =
             append(store, "domain", "batch", payloads, 0, fault: :after_commit)

    assert {:ok, %{revision: 2, entries: [_, _]}} = Ledger.load(store, "domain")
    assert {:ok, %{last_revision: 2}} = Ledger.lookup_batch(store, "domain", "batch")
    assert {:ok, 3} = append(store, "domain", "later", [%{"n" => 3}], 2)
    assert {:ok, 2} = append(store, "domain", "batch", payloads, 0, fault: :before_commit)
    assert {:ok, %{revision: 3, entries: [_, _, _]}} = Ledger.load(store, "domain")
  end

  test "compression preserves canonical history, retry semantics and CAS", %{store: plain} do
    server = start_supervised!(Supervisor.child_spec({ETS, compressed: true}, id: :compressed))
    compressed = {ETS, server: server}

    for store <- [plain, compressed] do
      assert {:ok, 2} = append(store, "domain", "batch", [%{"n" => 1}, %{"n" => 2}], 0)
      assert {:ok, 3} = append(store, "domain", "later", [%{"n" => 3}], 2)
      assert {:ok, 2} = append(store, "domain", "batch", [%{"n" => 1}, %{"n" => 2}], 0)
      assert {:error, :conflict} = append(store, "domain", "stale", [%{"n" => 4}], 0)

      assert {:error, {:batch_identity_conflict, "batch"}} =
               append(store, "domain", "batch", [%{"n" => 5}], 0)
    end

    assert Ledger.export(plain, "domain") == Ledger.export(compressed, "domain")

    assert Ledger.lookup_batch(plain, "domain", "batch") ==
             Ledger.lookup_batch(compressed, "domain", "batch")

    assert {:error, :invalid_ledger_ets_compressed} = ETS.start_link(compressed: :yes)
  end

  test "exports in short-lived readers remain complete prefixes while appends continue", %{
    store: store
  } do
    assert {:ok, 2} = append(store, "domain", "batch:1", [%{"n" => 1}, %{"n" => 2}], 0)

    writer =
      Task.async(fn ->
        for batch <- 2..30 do
          expected = (batch - 1) * 2

          assert {:ok, revision} =
                   append(
                     store,
                     "domain",
                     "batch:#{batch}",
                     [%{"n" => expected + 1}, %{"n" => expected + 2}],
                     expected
                   )

          assert revision == expected + 2
        end
      end)

    readers =
      for _ <- 1..10 do
        Task.async(fn ->
          assert {:ok, exported} = Ledger.export(store, "domain")
          assert {:ok, snapshot} = Ledger.verify(exported)
          assert rem(snapshot.revision, 2) == 0

          assert Enum.map(snapshot.entries, & &1.payload["n"]) ==
                   Enum.to_list(1..snapshot.revision)
        end)
      end

    Task.await_many([writer | readers], 10_000)
    assert {:ok, %{revision: 60}} = Ledger.load(store, "domain")
  end

  # Writes belong to the adapter contract; the public Ledger facade is read-only.
  defp append(store, domain, batch, payloads, revision, opts \\ []) do
    Store.append(
      store,
      domain,
      batch,
      payloads,
      revision,
      Keyword.put_new(opts, :recorded_at, revision + 1)
    )
  end
end
