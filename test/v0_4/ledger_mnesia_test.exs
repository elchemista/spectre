defmodule Spectre.V04Test.LedgerMnesiaTest do
  use ExUnit.Case, async: false

  alias Spectre.Ledger
  alias Spectre.Ledger.Store, as: LedgerStore
  alias Spectre.Ledger.Store.Mnesia

  @heads :spectre_test_ledger_heads
  @batches :spectre_test_ledger_batches
  @entries :spectre_test_ledger_entries

  setup_all do
    # Mnesia configuration is node-global: this module is synchronous and owns
    # an isolated disk schema, never the developer's configured directory.
    previous_dir = Application.fetch_env(:mnesia, :dir)

    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.join(System.tmp_dir!(), "spectre-mnesia-test-#{suffix}")

    File.mkdir!(directory)
    :ok = Application.stop(:mnesia)
    Application.put_env(:mnesia, :dir, String.to_charlist(directory))

    on_exit(fn ->
      Application.stop(:mnesia)

      case previous_dir do
        {:ok, value} -> Application.put_env(:mnesia, :dir, value)
        :error -> Application.delete_env(:mnesia, :dir)
      end

      File.rm_rf!(directory)
      {:ok, _} = Application.ensure_all_started(:mnesia)
    end)

    :ok = :mnesia.create_schema([node()])
    {:ok, _apps} = Application.ensure_all_started(:mnesia)
    :ok
  end

  setup do
    delete_tables()

    opts = [
      heads_table: @heads,
      batches_table: @batches,
      entries_table: @entries,
      storage: :disc_copies,
      nodes: [node()]
    ]

    assert :ok = Mnesia.ensure_tables(opts)
    on_exit(&delete_tables/0)
    {:ok, store: {Mnesia, opts}}
  end

  test "persists an idempotent append-only chain with CAS and export", %{store: store} do
    domain = "mnesia-domain"
    first = [%{"event" => "first"}, %{"event" => "second"}]
    second = [%{"event" => "third"}]

    assert {:ok, 2} = append(store, domain, "batch-1", first, 0)
    assert {:ok, 2} = append(store, domain, "batch-1", first, 0)
    assert {:error, :conflict} = append(store, domain, "batch-2", second, 0)
    assert {:ok, 3} = append(store, domain, "batch-2", second, 2)

    assert {:ok, snapshot} = Ledger.load(store, domain)
    assert snapshot.revision == 3
    assert Enum.map(snapshot.entries, & &1.payload) == first ++ second

    assert {:ok, %{first_revision: 1, last_revision: 2, entry_count: 2}} =
             Ledger.lookup_batch(store, domain, "batch-1")

    assert {:ok, export} = Ledger.export(store, domain)
    assert {:ok, verified} = Ledger.verify(export)
    assert verified.head_digest == snapshot.head_digest

    assert {:error, {:batch_identity_conflict, "batch-1"}} =
             append(store, domain, "batch-1", [%{"event" => "changed"}], 0)
  end

  test "serializes concurrent writers on one Domain head", %{store: store} do
    domain = "mnesia-cas"

    tasks =
      for id <- 1..8 do
        Task.async(fn ->
          append(store, domain, "batch-#{id}", [%{"writer" => id}], 0)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, 1}, &1)) == 1
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 7
    assert {:ok, %{revision: 1}} = Ledger.load(store, domain)
  end

  test "durable entries and retry identities survive a Mnesia restart", %{store: store} do
    payloads = [%{"event" => "durable"}]
    assert {:ok, 1} = append(store, "restart", "batch", payloads, 0)
    assert {:ok, snapshot} = Ledger.load(store, "restart")
    assert {:ok, info} = Ledger.lookup_batch(store, "restart", "batch")
    assert :ok = Application.stop(:mnesia)
    assert {:ok, _} = Application.ensure_all_started(:mnesia)
    assert :ok = :mnesia.wait_for_tables([@heads, @batches, @entries], 5_000)
    assert {:ok, ^snapshot} = Ledger.load(store, "restart")
    assert {:ok, ^info} = Ledger.lookup_batch(store, "restart", "batch")
    assert {:ok, 1} = append(store, "restart", "batch", payloads, 0)
  end

  test "classifies uncertainty before and after synchronous commit", %{store: store} do
    domain = "mnesia-faults"
    payloads = [%{"event" => "once"}]

    assert {:error, :ambiguous} =
             append(store, domain, "batch", payloads, 0, fault_injection: :before_commit)

    assert :not_found = Ledger.load(store, domain)

    assert {:error, :ambiguous} =
             append(store, domain, "batch", payloads, 0, fault_injection: :after_commit)

    assert {:ok, 1} = append(store, domain, "batch", payloads, 0)
    assert {:ok, %{revision: 1, entries: [_entry]}} = Ledger.load(store, domain)
  end

  defp delete_tables do
    Enum.each([@entries, @batches, @heads], fn table ->
      case :mnesia.delete_table(table) do
        {:atomic, :ok} -> :ok
        {:aborted, {:no_exists, ^table}} -> :ok
        {:aborted, {:no_exists, ^table, _detail}} -> :ok
      end
    end)
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
