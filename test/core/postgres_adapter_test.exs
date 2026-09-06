defmodule Spectre.CoreTest.PostgresAdapterTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Postgres

  # Exercises the host Repo/SQL contract without adding database dependencies.
  # These scripts prove call ordering and validation, not PostgreSQL durability.
  defmodule Repo do
    import ExUnit.Assertions

    def script(steps), do: Process.put({__MODULE__, :steps}, steps)
    def remaining, do: Process.get({__MODULE__, :steps}, [])

    def transaction(operation, opts) do
      send(self(), {:transaction, opts})

      case Keyword.fetch(opts, :test_result) do
        {:ok, result} -> result
        :error -> {:ok, operation.()}
      end
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def rollback(reason), do: throw({:rollback, reason})

    def query(__MODULE__, sql, params, opts) do
      [{fragment, reply} | rest] = remaining()
      assert String.contains?(sql, fragment)
      Process.put({__MODULE__, :steps}, rest)
      send(self(), {:query, fragment, params, opts})
      reply
    end
  end

  @opts [repo: Repo, query_module: Repo, recorded_at: 100]
  @read_opts [repo: Repo, query_module: Repo]
  @payloads [%{"event" => "first"}, %{"event" => "second"}]

  test "batch paging uses the revision index without loading unrelated encoded rows" do
    batch = stored_batch()

    Repo.script([
      {"FOR SHARE", rows([[2, batch.head]])},
      {"AND first_revision = $2", rows([batch.row])}
    ])

    assert {:ok, %{revision: 2}} = Postgres.head("domain", @read_opts)
    assert {:ok, %{entries: entries, revision: 2}} = Postgres.read_batch("domain", 1, @read_opts)
    assert Enum.map(entries, & &1.payload) === @payloads
    assert Repo.remaining() == []
    assert_received {:query, "AND first_revision = $2", ["domain", 1], []}
  end

  test "optional compression is physical and reads do not depend on the write setting" do
    payloads = [%{"body" => String.duplicate("payload", 5_000)}]
    Repo.script(new_batch_script())

    assert {:ok, 1} =
             Postgres.append(
               "domain",
               "compressed",
               payloads,
               0,
               Keyword.put(@opts, :compressed, true)
             )

    assert_receive {:query, ~s(INSERT INTO "public"."spectre_ledger_batches"), params, []}
    ["domain", "compressed", identity, 0, 1, 1, 1, head, encoded] = params
    assert <<"SPZB", 1, _::binary>> = encoded
    row = ["compressed", identity, 0, 1, 1, 1, head, encoded]
    Repo.script([{"AND first_revision = $2", rows([row])}])
    assert {:ok, %{entries: [entry]}} = Postgres.read_batch("domain", 1, @read_opts)
    assert entry.payload === hd(payloads)
  end

  test "namespace validation prevents SQL identifier injection" do
    assert {:ok, %{schema: "public", table_prefix: "spectre_ledger"}} = Postgres.namespace()
    assert {:ok, _} = Postgres.namespace(schema: "tenant_1", table_prefix: "audit")

    for value <- ["public; DROP TABLE x", "public.other", "\"quoted\"", "", 42] do
      assert {:error, _} = Postgres.namespace(schema: value)
    end

    assert {:error, _} = Postgres.namespace(unknown: true)
    assert {:error, _} = Postgres.namespace(:invalid)
  end

  test "migration DDL guards batch mutation and enforces CAS/idempotency coordinates" do
    assert {:ok, %{up: up, down: down}} =
             Postgres.migration_sql(schema: "audit", table_prefix: "gam")

    sql = Enum.join(up, "\n")
    assert sql =~ ~s(CREATE TABLE "audit"."gam_batches")
    assert sql =~ "PRIMARY KEY (domain_ref, batch_id)"
    assert sql =~ "UNIQUE (domain_ref, first_revision)"
    assert sql =~ "CHECK (first_revision = expected_revision + 1)"
    assert sql =~ "BEFORE UPDATE OR DELETE OR TRUNCATE"
    assert sql =~ "ON UPDATE RESTRICT ON DELETE RESTRICT"
    assert List.last(down) == ~s(DROP TABLE "audit"."gam_heads")
  end

  test "new append sets synchronous commit and locks before writing one canonical batch" do
    Repo.script(new_batch_script())
    assert {:ok, 2} = Postgres.append("domain", "batch", @payloads, 0, @opts)
    assert Repo.remaining() == []
    assert_receive {:transaction, []}
    assert_receive {:query, "SET LOCAL synchronous_commit = on", [], []}
    assert_receive {:query, "pg_advisory_xact_lock", ["domain"], []}
    assert_receive {:query, ~s(INSERT INTO "public"."spectre_ledger_batches"), params, []}
    ["domain", "batch", identity, 0, 1, 2, 2, head, encoded] = params
    assert {:ok, ^identity} = Entry.batch_identity("domain", "batch", @payloads, 0)
    assert {:ok, records} = Value.decode(encoded)
    assert length(records) == 2
    assert Enum.map(records, & &1["payload"]) == @payloads
    assert Enum.map(records, & &1["recorded_at"]) == [100, 100]
    assert List.last(records)["digest"] == head
  end

  test "CAS conflict and pre-commit ambiguity perform no writes" do
    Repo.script(Enum.take(new_batch_script(), 4))
    assert {:error, :conflict} = Postgres.append("domain", "batch", @payloads, 1, @opts)
    assert Repo.remaining() == []
    Repo.script(Enum.take(new_batch_script(), 4))

    assert {:error, :ambiguous} =
             Postgres.append(
               "domain",
               "batch",
               @payloads,
               0,
               Keyword.put(@opts, :fault, :before_commit)
             )

    assert Repo.remaining() == []
    refute_received {:query, ~s(INSERT INTO "public"."spectre_ledger_heads"), _, _}
  end

  test "lost acknowledgement after commit remains ambiguous to the caller" do
    Repo.script(new_batch_script())

    assert {:error, :ambiguous} =
             Postgres.append(
               "domain",
               "batch",
               @payloads,
               0,
               Keyword.put(@opts, :fault, :after_commit)
             )

    assert Repo.remaining() == []
  end

  test "existing identical batch is verified against durable head and never rewritten" do
    batch = stored_batch()

    Repo.script([
      {"SET LOCAL", rows([])},
      {"pg_advisory_xact_lock", rows([[nil]])},
      {"SELECT identity_digest", rows([tl(batch.row)])}
      | [{"FOR SHARE", rows([[2, batch.head]])}]
    ])

    assert {:ok, 2} =
             Postgres.append(
               "domain",
               "batch",
               @payloads,
               0,
               Keyword.put(@opts, :recorded_at, 999)
             )

    assert Repo.remaining() == []
    refute_received {:query, ~s(INSERT INTO "public"."spectre_ledger_heads"), _, _}
  end

  test "batch identity conflict is rejected before reading or changing the head" do
    batch = stored_batch()

    Repo.script([
      {"SET LOCAL", rows([])},
      {"pg_advisory_xact_lock", rows([[nil]])},
      {"SELECT identity_digest", rows([tl(batch.row)])}
    ])

    assert {:error, {:batch_identity_conflict, "batch"}} =
             Postgres.append("domain", "batch", [%{"event" => "changed"}], 0, @opts)

    assert Repo.remaining() == []
  end

  test "load and lookup decode and verify canonical bytes against stored metadata" do
    batch = stored_batch()
    Repo.script(load_script(batch))
    assert {:ok, snapshot} = Postgres.load("domain", @read_opts)
    assert snapshot.entries == batch.entries
    assert snapshot.revision == 2

    Repo.script([
      {"SELECT identity_digest", rows([tl(batch.row)])},
      {"FOR SHARE", rows([[2, batch.head]])}
    ])

    assert {:ok, info} = Postgres.lookup_batch("domain", "batch", @read_opts)
    assert info.head_digest == batch.head
    assert info.entry_count == 2
    assert Repo.remaining() == []
  end

  test "missing ledger and malformed query replies fail without invented data" do
    Repo.script([{"FOR SHARE", rows([])}])
    assert :not_found = Postgres.load("domain", @read_opts)
    Repo.script([{"FOR SHARE", {:ok, %{rows: :invalid}}}])
    assert {:error, :invalid_ledger_postgres_query_result} = Postgres.load("domain", @read_opts)
    Repo.script([{"FOR SHARE", :invalid}])
    assert {:error, :invalid_ledger_postgres_query_reply} = Postgres.load("domain", @read_opts)
    Repo.script([{"FOR SHARE", {:error, :disconnected}}])

    assert {:error, {:ledger_postgres_query_failed, :disconnected}} =
             Postgres.load("domain", @read_opts)
  end

  test "corrupted canonical bytes and changed head are rejected on read" do
    batch = stored_batch()
    bad_row = List.replace_at(batch.row, 7, "not-canonical")
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([bad_row])}])
    assert {:error, {:invalid_postgres_ledger_batch, _}} = Postgres.load("domain", @read_opts)

    Repo.script([
      {"FOR SHARE", rows([[2, String.duplicate("0", 64)]])},
      {"ORDER BY", rows([batch.row])}
    ])

    assert {:error, _} = Postgres.load("domain", @read_opts)
  end

  for {field, index, value, error} <- [
        {:batch_id, 0, "", :invalid_ledger_postgres_batch_id},
        {:identity, 1, "short", :invalid_ledger_postgres_batch_identity},
        {:expected_revision, 2, -1, :invalid_ledger_postgres_batch_revision},
        {:first_revision, 3, 2, :invalid_ledger_postgres_batch_range},
        {:last_revision, 4, 0, :invalid_ledger_postgres_batch_range},
        {:entry_count, 5, 3, :invalid_ledger_postgres_batch_count},
        {:head_digest, 6, "short", :invalid_ledger_postgres_batch_head}
      ] do
    test "load rejects invalid SQL #{field} before trusting the encoded batch" do
      batch = stored_batch()
      row = List.replace_at(batch.row, unquote(index), unquote(value))
      Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])
      assert {:error, unquote(error)} = Postgres.load("domain", @read_opts)
      assert Repo.remaining() == []
    end
  end

  test "SQL batch coordinates cannot silently accept a float first revision" do
    batch = stored_batch()
    row = List.replace_at(batch.row, 3, 1.0)
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])
    assert {:error, :invalid_ledger_postgres_batch_range} = Postgres.load("domain", @read_opts)
  end

  test "a well-shaped but different batch identity must match decoded content" do
    batch = stored_batch()
    row = List.replace_at(batch.row, 1, String.duplicate("a", 64))
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])

    assert {:error, {:ledger_postgres_batch_metadata_mismatch, "batch"}} =
             Postgres.load("domain", @read_opts)
  end

  test "a well-shaped but different per-batch head is rejected" do
    batch = stored_batch()
    row = List.replace_at(batch.row, 6, String.duplicate("b", 64))
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])

    assert {:error, {:ledger_postgres_batch_metadata_mismatch, "batch"}} =
             Postgres.load("domain", @read_opts)
  end

  test "empty canonical bytes cannot represent a non-empty SQL batch" do
    batch = stored_batch()
    {:ok, encoded} = Value.encode([])
    row = List.replace_at(batch.row, 7, encoded)
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])
    assert {:error, :empty_postgres_ledger_batch} = Postgres.load("domain", @read_opts)
  end

  test "canonical values that are not entries cannot be restored as history" do
    batch = stored_batch()
    {:ok, encoded} = Value.encode([%{"not" => "an entry"}])
    row = List.replace_at(batch.row, 7, encoded)
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])
    assert {:error, {:invalid_postgres_ledger_entry, _}} = Postgres.load("domain", @read_opts)
  end

  test "a truncated canonical batch cannot hide behind complete SQL metadata" do
    batch = stored_batch()
    {:ok, encoded} = Value.encode([Entry.to_data(hd(batch.entries))])
    row = List.replace_at(batch.row, 7, encoded)
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])

    assert {:error, {:invalid_postgres_ledger_batch, :ledger_batch_coordinates_mismatch}} =
             Postgres.load("domain", @read_opts)
  end

  test "reordered canonical entries are rejected independently of their individual digests" do
    batch = stored_batch()
    {:ok, encoded} = Value.encode(Enum.map(Enum.reverse(batch.entries), &Entry.to_data/1))
    row = List.replace_at(batch.row, 7, encoded)
    Repo.script([{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([row])}])
    assert {:error, {:invalid_postgres_ledger_batch, _}} = Postgres.load("domain", @read_opts)
  end

  test "a SQL row for this Domain cannot carry another Domain's valid canonical history" do
    batch = stored_batch()
    Repo.script(load_script(batch))

    assert {:error, {:invalid_postgres_ledger_batch, _}} =
             Postgres.load("other-domain", @read_opts)
  end

  test "duplicated returned batches do not create a second copy of the history" do
    batch = stored_batch()

    Repo.script([
      {"FOR SHARE", rows([[2, batch.head]])},
      {"ORDER BY", rows([batch.row, batch.row])}
    ])

    assert {:error, _} = Postgres.load("domain", @read_opts)
  end

  test "multiple head rows are rejected rather than selecting an arbitrary revision" do
    batch = stored_batch()
    Repo.script([{"FOR SHARE", rows([[2, batch.head], [2, batch.head]])}])
    assert {:error, :invalid_ledger_postgres_head_row} = Postgres.load("domain", @read_opts)
  end

  test "an existing batch without a Domain head cannot acknowledge a retry" do
    batch = stored_batch()

    Repo.script([
      {"SET LOCAL", rows([])},
      {"pg_advisory_xact_lock", rows([[nil]])},
      {"SELECT identity_digest", rows([tl(batch.row)])},
      {"FOR SHARE", rows([])}
    ])

    assert {:error, :ledger_postgres_batch_without_head} =
             Postgres.append("domain", "batch", @payloads, 0, @opts)

    assert Repo.remaining() == []
  end

  test "lookup rejects a stored batch whose head has disappeared" do
    batch = stored_batch()
    Repo.script([{"SELECT identity_digest", rows([tl(batch.row)])}, {"FOR SHARE", rows([])}])

    assert {:error, :ledger_postgres_batch_without_head} =
             Postgres.lookup_batch("domain", "batch", @read_opts)
  end

  test "lookup does not accept ambiguous duplicate SQL batch rows" do
    batch = stored_batch()
    Repo.script([{"SELECT identity_digest", rows([tl(batch.row), tl(batch.row)])}])

    assert {:error, :invalid_ledger_postgres_batch_row} =
             Postgres.lookup_batch("domain", "batch", @read_opts)
  end

  test "SQL failure before locking prevents subsequent reads and writes" do
    Repo.script([{"SET LOCAL", {:error, :read_only_transaction}}])

    assert {:error, {:ledger_postgres_query_failed, :read_only_transaction}} =
             Postgres.append("domain", "batch", @payloads, 0, @opts)

    assert Repo.remaining() == []
    refute_received {:query, "pg_advisory_xact_lock", _, _}
  end

  test "provider exception structs are reduced to their type, without private details" do
    Repo.script([{"FOR SHARE", {:error, RuntimeError.exception("private SQL credentials")}}])

    assert {:error, {:ledger_postgres_query_failed, RuntimeError}} =
             Postgres.load("domain", @read_opts)
  end

  test "opaque provider errors do not leak their nested private contents" do
    Repo.script([{"FOR SHARE", {:error, {:connection, "private SQL credentials"}}}])

    assert {:error, {:ledger_postgres_query_failed, :unknown}} =
             Postgres.load("domain", @read_opts)
  end

  test "unknown write transaction failure is ambiguous, never a definite rollback claim" do
    opts = Keyword.put(@opts, :transaction_opts, test_result: {:error, :connection_lost})
    assert {:error, :ambiguous} = Postgres.append("domain", "batch", @payloads, 0, opts)
  end

  test "malformed successful write transaction result is ambiguous" do
    opts = Keyword.put(@opts, :transaction_opts, test_result: {:ok, :saved})
    assert {:error, :ambiguous} = Postgres.append("domain", "batch", @payloads, 0, opts)
  end

  test "a read transaction failure remains distinct from an absent Domain" do
    opts = Keyword.put(@read_opts, :transaction_opts, test_result: {:error, :connection_lost})

    assert {:error, {:ledger_postgres_transaction_failed, :connection_lost}} =
             Postgres.load("domain", opts)
  end

  test "malformed read transaction success cannot return an unverified snapshot" do
    opts = Keyword.put(@read_opts, :transaction_opts, test_result: {:ok, :saved})
    assert {:error, :invalid_ledger_postgres_transaction_result} = Postgres.load("domain", opts)
  end

  test "query and transaction options reach only their matching host boundary" do
    Repo.script([{"FOR SHARE", rows([])}])
    opts = Keyword.merge(@read_opts, query_opts: [timeout: 100], transaction_opts: [timeout: 200])
    assert :not_found = Postgres.load("domain", opts)
    assert_receive {:transaction, [timeout: 200]}
    assert_receive {:query, "FOR SHARE", ["domain"], [timeout: 100]}
  end

  test "a failed head CAS prevents batch insertion" do
    script =
      new_batch_script()
      |> Enum.take(5)
      |> List.update_at(4, fn {sql, _} -> {sql, {:ok, %{num_rows: 0}}} end)

    Repo.script(script)
    assert {:error, :conflict} = Postgres.append("domain", "batch", @payloads, 0, @opts)
    refute_received {:query, ~s(INSERT INTO "public"."spectre_ledger_batches"), _, _}
  end

  test "writing multiple rows for a single batch is rejected" do
    script =
      List.update_at(new_batch_script(), 5, fn {sql, _} -> {sql, {:ok, %{num_rows: 2}}} end)

    Repo.script(script)

    assert {:error, {:invalid_ledger_postgres_affected_rows, 2}} =
             Postgres.append("domain", "batch", @payloads, 0, @opts)
  end

  defp new_batch_script do
    [
      {"SET LOCAL synchronous_commit = on", rows([])},
      {"pg_advisory_xact_lock", rows([[nil]])},
      {"SELECT identity_digest", rows([])},
      {"FOR UPDATE", rows([])},
      {~s(INSERT INTO "public"."spectre_ledger_heads"), {:ok, %{num_rows: 1}}},
      {~s(INSERT INTO "public"."spectre_ledger_batches"), {:ok, %{num_rows: 1}}}
    ]
  end

  test "suffix query keeps the head lock and binds its lower bound as a parameter" do
    batch = stored_batch()

    Repo.script([
      {"FOR SHARE", rows([[2, batch.head]])},
      {"AND last_revision > $2", rows([batch.row])}
    ])

    cursor = %{revision: 0, head_digest: Entry.genesis_digest()}

    assert {:ok, %{revision: 2, entries: entries}} =
             Spectre.Ledger.load_from({Postgres, @read_opts}, "domain", cursor)

    assert entries === batch.entries
    assert_receive {:query, "AND last_revision > $2", ["domain", 0], _}
    assert Repo.remaining() == []
  end

  test "suffix refuses a SQL batch crossing the requested boundary" do
    batch = stored_batch()

    Repo.script([
      {"FOR SHARE", rows([[2, batch.head]])},
      {"AND last_revision > $2", rows([batch.row])}
    ])

    cursor = %{revision: 1, head_digest: hd(batch.entries).digest}

    assert {:error, {:ledger_revision_gap, 2, 1}} =
             Spectre.Ledger.load_from({Postgres, @read_opts}, "domain", cursor)
  end

  defp stored_batch do
    {:ok, entries} =
      Entry.build_batch("domain", "batch", @payloads, 0, 100, Entry.genesis_digest())

    {:ok, identity} = Entry.batch_identity("domain", "batch", @payloads, 0)
    {:ok, encoded} = Value.encode(Enum.map(entries, &Entry.to_data/1))
    head = List.last(entries).digest
    %{entries: entries, head: head, row: ["batch", identity, 0, 1, 2, 2, head, encoded]}
  end

  defp load_script(batch),
    do: [{"FOR SHARE", rows([[2, batch.head]])}, {"ORDER BY", rows([batch.row])}]

  defp rows(values), do: {:ok, %{rows: values}}
end
