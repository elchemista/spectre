Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.V04Test.LedgerMnesiaTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.Domain.Admission.Planner
  alias Spectre.GAM.Domain.{Configuration, Recovery, Sequencer, Startup}
  alias Spectre.GAM.GovernedAct.Commit
  alias Spectre.GAM.Ledger
  alias Spectre.GAM.Ledger.{Entry, Reader}
  alias Spectre.GAM.Ledger.Store, as: LedgerStore
  alias Spectre.GAM.Ledger.Store.Mnesia
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  @heads :spectre_test_ledger_heads
  @batches :spectre_test_ledger_batches
  @entries :spectre_test_ledger_entries

  test "compressed records and indexed batch reads preserve the canonical ledger", %{
    store: {Mnesia, opts}
  } do
    store = {Mnesia, Keyword.put(opts, :compressed, true)}
    payloads = [%{"body" => String.duplicate("kept outside process heap", 1_000)}]
    assert {:ok, 1} = append(store, "compressed", "first", payloads, 0)
    assert {:ok, 2} = append(store, "compressed", "second", [%{"n" => 2}], 1)

    [{@entries, {"compressed", 1}, stored}] = :mnesia.dirty_read(@entries, {"compressed", 1})
    assert <<"SPZB", 1, _::binary>> = stored
    assert byte_size(stored) < 2_000
    assert {:ok, %{revision: 2}} = LedgerStore.head(store, "compressed")

    assert {:ok, %{entries: [entry], revision: 1}} =
             LedgerStore.read_batch(store, "compressed", 1)

    assert entry.payload === hd(payloads)
    assert {:ok, full} = Ledger.load({Mnesia, opts}, "compressed")
    zero = %{revision: 0, head_digest: Entry.genesis_digest()}

    assert {:ok, actual} =
             Reader.reduce(store, "compressed", zero, [], fn batch, acc ->
               {:ok, acc ++ batch}
             end)

    assert actual === full.entries
  end

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

  test "corrupt float first revision is rejected before lookup constructs a Range", %{
    store: store
  } do
    corrupt_first_revision(store)

    assert {:error, :invalid_ledger_mnesia_batch_range} =
             Ledger.lookup_batch(store, "corrupt-range", "batch")
  end

  test "load rejects numerically equal but noncanonical batch coordinates", %{store: store} do
    corrupt_first_revision(store)

    assert {:error, :invalid_ledger_mnesia_batch_range} = Ledger.load(store, "corrupt-range")
    assert {:error, :invalid_ledger_mnesia_batch_range} = Ledger.export(store, "corrupt-range")
  end

  test "idempotent retry cannot acknowledge a corrupt batch index", %{store: store} do
    {original, payloads} = corrupt_first_revision(store)

    assert {:error, :invalid_ledger_mnesia_batch_range} =
             append(store, "corrupt-range", "batch", payloads, 0)

    # Repair only the deliberately corrupted test index. The rejected retry
    # must not have appended entries or changed the durable identity.
    :ok = :mnesia.dirty_write(@batches, original)
    assert {:ok, 2} = append(store, "corrupt-range", "batch", payloads, 0)
    assert {:ok, %{revision: 2, entries: [_, _]}} = Ledger.load(store, "corrupt-range")
  end

  for {index, value, error} <- [
        {2, "not-a-digest", :invalid_ledger_mnesia_batch_identity},
        {3, 0.0, :invalid_ledger_mnesia_batch_revision},
        {5, 2.0, :invalid_ledger_mnesia_batch_range},
        {6, 2.0, :invalid_ledger_mnesia_batch_count},
        {7, "not-a-digest", :invalid_ledger_mnesia_batch_head}
      ] do
    test "corrupt batch coordinate #{index} cannot be trusted by load, lookup or retry", %{
      store: store
    } do
      payloads = [%{"first" => 1}, %{"second" => 2}]
      assert {:ok, 2} = append(store, "coordinates", "batch", payloads, 0)
      [row] = :mnesia.dirty_read(@batches, {"coordinates", "batch"})
      :ok = :mnesia.dirty_write(@batches, put_elem(row, unquote(index), unquote(value)))
      assert {:error, unquote(error)} = Ledger.lookup_batch(store, "coordinates", "batch")
      assert {:error, unquote(error)} = Ledger.load(store, "coordinates")
      assert {:error, unquote(error)} = append(store, "coordinates", "batch", payloads, 0)
      :ok = :mnesia.dirty_write(@batches, row)
      assert {:ok, %{revision: 2}} = Ledger.load(store, "coordinates")
    end
  end

  test "a batch needs a matching head and exact metadata derived from actual entries", %{
    store: store
  } do
    assert {:ok, 1} = append(store, "head-boundary", "batch", [%{"x" => 1}], 0)
    [head] = :mnesia.dirty_read(@heads, "head-boundary")
    :ok = :mnesia.dirty_delete(@heads, "head-boundary")

    assert {:error, :ledger_mnesia_batch_without_head} =
             Ledger.lookup_batch(store, "head-boundary", "batch")

    :ok = :mnesia.dirty_write(@heads, put_elem(head, 2, 0))
    assert {:error, _} = Ledger.lookup_batch(store, "head-boundary", "batch")
    :ok = :mnesia.dirty_write(@heads, head)
    [batch] = :mnesia.dirty_read(@batches, {"head-boundary", "batch"})
    :ok = :mnesia.dirty_write(@batches, put_elem(batch, 2, String.duplicate("a", 64)))

    assert {:error, {:ledger_mnesia_batch_metadata_mismatch, "batch"}} =
             Ledger.lookup_batch(store, "head-boundary", "batch")

    :ok = :mnesia.dirty_write(@batches, batch)
    assert {:ok, _} = Ledger.lookup_batch(store, "head-boundary", "batch")
    assert :not_found = Ledger.lookup_batch(store, "head-boundary", "absent")
  end

  test "corrupt, miskeyed and absent entry bytes cannot be restored through a valid head", %{
    store: store
  } do
    assert {:ok, 2} = append(store, "entry-boundary", "batch", [%{"x" => 1}, %{"x" => 2}], 0)
    [first] = :mnesia.dirty_read(@entries, {"entry-boundary", 1})
    [second] = :mnesia.dirty_read(@entries, {"entry-boundary", 2})

    for encoded <- ["invalid-codec", 42, elem(second, 2)] do
      :ok = :mnesia.dirty_write(@entries, put_elem(first, 2, encoded))
      assert {:error, _} = Ledger.load(store, "entry-boundary")
      assert {:error, _} = Ledger.lookup_batch(store, "entry-boundary", "batch")
    end

    :ok = :mnesia.dirty_delete(@entries, {"entry-boundary", 1})
    assert {:error, _} = Ledger.load(store, "entry-boundary")
    :ok = :mnesia.dirty_write(@entries, first)
    assert {:ok, %{revision: 2}} = Ledger.load(store, "entry-boundary")
    :ok = :mnesia.dirty_delete(@batches, {"entry-boundary", "batch"})
    assert {:error, _} = Ledger.load(store, "entry-boundary")
  end

  test "a Domain cannot recover from manually altered database rows after a database restart", %{
    store: store
  } do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(projection_store: nil, namespace: "mnesia-recovery-tampering")
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    evidence = Fixture.paid_evidence(fixture)
    assert {:ok, ^evidence} = Fixture.observe_payment(fixture, evidence)
    snapshot = Fixture.snapshot(fixture)
    expected = Sequencer.projection(fixture.server)
    Fixture.stop_process(fixture.server)

    for batch <- Enum.chunk_by(snapshot.entries, & &1.batch_id) do
      first = hd(batch)

      assert {:ok, _} =
               LedgerStore.append(
                 store,
                 snapshot.domain_ref,
                 first.batch_id,
                 Enum.map(batch, & &1.payload),
                 first.revision - 1,
                 recorded_at: first.recorded_at
               )
    end

    opts = Keyword.put(fixture.sequencer_opts, :store, store)
    assert {:ok, config} = Configuration.new(opts)
    assert {:ok, ^expected} = Startup.load(config)
    key = {snapshot.domain_ref, snapshot.revision}
    [original] = :mnesia.dirty_read(@entries, key)
    entry = List.last(snapshot.entries)
    assert {:ok, altered} = Entry.encode(%{entry | payload: %{"manually_changed" => true}})

    for modification <- [:replace, :delete] do
      case modification do
        :replace -> :mnesia.dirty_write(@entries, put_elem(original, 2, altered))
        :delete -> :mnesia.dirty_delete(@entries, key)
      end

      # Exercise persisted damage, not only a mocked read response or the
      # application's in-memory projection.
      assert :ok = Application.stop(:mnesia)
      assert {:ok, _} = Application.ensure_all_started(:mnesia)
      assert :ok = :mnesia.wait_for_tables([@heads, @batches, @entries], 5_000)
      assert {:error, _} = Recovery.recover(store, snapshot.domain_ref, fixture.constitution, [])
      assert {:error, _} = Startup.load(config)

      # Host restores the exact original row. A fresh verification, rather
      # than an "ignore corruption" flag, is the only route back to service.
      assert :ok = :mnesia.dirty_write(@entries, original)
      assert {:ok, ^expected} = Startup.load(config)
    end
  end

  for compressed <- [false, true] do
    @tag prepared_compressed: compressed
    test "prepared admission survives lost acknowledgement and Mnesia restart (compressed: #{compressed})",
         ctx do
      {Mnesia, opts} = ctx.store
      store = {Mnesia, Keyword.put(opts, :compressed, ctx.prepared_compressed)}
      {fixture, prefix, prepared} = prepared_admission(store)

      assert {:error, :ambiguous} =
               LedgerStore.append(
                 store,
                 prefix.domain_ref,
                 "prepared-admission",
                 prepared.payloads,
                 prefix.revision,
                 recorded_at: prefix.recorded_at,
                 fault_injection: :after_commit
               )

      assert :ok = Application.stop(:mnesia)
      assert {:ok, _} = Application.ensure_all_started(:mnesia)
      assert :ok = :mnesia.wait_for_tables([@heads, @batches, @entries], 5_000)
      assert {:ok, receipt} = Ledger.lookup_batch(store, prefix.domain_ref, "prepared-admission")
      assert Commit.confirmed?(prepared, receipt)
      assert {:ok, confirmed} = Recovery.confirm_prepared(store, prefix, prepared, [])
      assert confirmed === prepared.state
      assert map_size(confirmed.acts) === 2
      assert map_size(confirmed.attempts) === 0
      assert MapSet.size(confirmed.pending_dispatches) === 2
      account = confirmed.meters[fixture.mandate.ref][fixture.refs.meter]
      assert {account.ceiling, account.available, account.reserved} === {2, 0, 2}

      assert {:ok, revision} =
               LedgerStore.append(
                 store,
                 prefix.domain_ref,
                 "prepared-admission",
                 prepared.payloads,
                 prefix.revision,
                 recorded_at: prefix.recorded_at
               )

      assert revision === prefix.revision + 8

      assert {:ok, ^confirmed} =
               Recovery.recover(store, prefix.domain_ref, prefix.constitution, [])

      assert {:ok, export} = Ledger.export(store, prefix.domain_ref)

      assert {:ok, report} =
               Spectre.GAM.Audit.verify(export, prefix.constitution, prefix.recorded_at)

      assert report.counts.acts === 2
      assert report.head_digest === confirmed.head_digest
    end

    @tag prepared_compressed: compressed
    test "Mnesia cannot confirm a rehashed incomplete admission (compressed: #{compressed})",
         ctx do
      {Mnesia, opts} = ctx.store
      store = {Mnesia, Keyword.put(opts, :compressed, ctx.prepared_compressed)}
      {_fixture, prefix, prepared} = prepared_admission(store)
      assert List.last(prepared.payloads)["type"] === "dispatch_ready"
      damaged = Enum.drop(prepared.payloads, -1)

      assert {:ok, _} =
               LedgerStore.append(
                 store,
                 prefix.domain_ref,
                 "prepared-admission",
                 damaged,
                 prefix.revision,
                 recorded_at: prefix.recorded_at
               )

      assert {:ok, snapshot} = Ledger.load(store, prefix.domain_ref)
      assert {:ok, ^snapshot} = Ledger.verify_snapshot(snapshot)

      assert {:error, {:committed_batch_identity_mismatch, "prepared-admission"}} =
               Recovery.confirm_prepared(store, prefix, prepared, [])

      assert {:error, {:act_dispatch_missing_from_admission_batch, act_ref}} =
               Recovery.recover(store, prefix.domain_ref, prefix.constitution, [])

      assert Map.has_key?(prepared.state.acts, act_ref)

      assert {:error, {:act_dispatch_missing_from_admission_batch, ^act_ref}} =
               Recovery.resume(store, prefix)
    end
  end

  defp prepared_admission(store) do
    Runtime.reset(Fixture.default_now())

    fixture =
      Fixture.start_domain(projection_store: nil, namespace: "mnesia-prepared", meter_ceiling: 2)

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    evidence = Fixture.paid_evidence(fixture)
    assert {:ok, ^evidence} = Fixture.observe_payment(fixture, evidence)
    context = Fixture.context(fixture)
    state = :sys.get_state(fixture.server)
    prefix = state.projection

    requests =
      for id <- ["first", "second"] do
        %{
          from: {self(), make_ref()},
          context: context,
          candidate: Fixture.refund_candidate(fixture, 1, identity_key: id)
        }
      end

    {plans, payloads} = Planner.plan(state, requests, prefix.recorded_at)
    assert Enum.all?(plans, &is_nil(&1.error))

    assert {:ok, prepared} =
             Commit.prepare(prefix, "prepared-admission", payloads, prefix.recorded_at)

    assert map_size(prepared.state.acts) === 2

    # The prefix is copied byte-for-byte in canonical batch order, not rebuilt
    # from guessed fixture fields. Both backends must acknowledge the same head.
    for batch <- Enum.chunk_by(Fixture.snapshot(fixture).entries, & &1.batch_id) do
      first = hd(batch)

      assert {:ok, _} =
               LedgerStore.append(
                 store,
                 prefix.domain_ref,
                 first.batch_id,
                 Enum.map(batch, & &1.payload),
                 first.revision - 1,
                 recorded_at: first.recorded_at
               )
    end

    Fixture.stop_process(fixture.server)
    assert {:ok, ^prefix} = Recovery.recover(store, prefix.domain_ref, prefix.constitution, [])
    {fixture, prefix, prepared}
  end

  test "batch paging rejects an interior cursor and an entry whose batch metadata disappeared", %{
    store: {Mnesia, opts} = store
  } do
    assert :not_found = Mnesia.export("missing", opts)
    assert :not_found = Mnesia.load_from("missing", 0, opts)
    assert :not_found = Mnesia.read_batch("missing", 1, opts)
    assert {:ok, 2} = append(store, "paging", "batch", [%{"n" => 1}, %{"n" => 2}], 0)
    assert {:error, :ledger_cursor_inside_batch} = Mnesia.read_batch("paging", 2, opts)
    :ok = :mnesia.dirty_delete(@batches, {"paging", "batch"})
    assert {:error, :ledger_mnesia_entry_without_batch} = Mnesia.read_batch("paging", 1, opts)
  end

  test "an orphaned occupied entry slot cannot be overwritten by a fresh append", %{store: store} do
    assert {:ok, 1} = append(store, "orphan", "original", [%{"value" => "must-survive"}], 0)
    [entry] = :mnesia.dirty_read(@entries, {"orphan", 1})
    :ok = :mnesia.dirty_delete(@heads, "orphan")
    :ok = :mnesia.dirty_delete(@batches, {"orphan", "original"})

    assert {:error, {:ledger_mnesia_entry_already_exists, 1}} =
             append(store, "orphan", "new", [%{"value" => "replacement"}], 0)

    assert :mnesia.dirty_read(@entries, {"orphan", 1}) === [entry]
    assert :mnesia.dirty_read(@heads, "orphan") === []
    assert :mnesia.dirty_read(@batches, {"orphan", "new"}) === []
  end

  test "idempotency cannot acknowledge a batch beyond, outside or without the current head", %{
    store: store
  } do
    payloads = [%{"n" => 1}, %{"n" => 2}]
    assert {:ok, 2} = append(store, "retry-head", "batch", payloads, 0)
    [head] = :mnesia.dirty_read(@heads, "retry-head")
    :ok = :mnesia.dirty_delete(@heads, "retry-head")

    assert {:error, :ledger_mnesia_batch_without_head} =
             append(store, "retry-head", "batch", payloads, 0)

    for corrupt <- [put_elem(head, 2, 1), put_elem(head, 3, String.duplicate("f", 64))] do
      :ok = :mnesia.dirty_write(@heads, corrupt)

      assert {:error, :ledger_mnesia_batch_not_in_head} =
               append(store, "retry-head", "batch", payloads, 0)

      assert {:error, :ledger_mnesia_batch_not_in_head} =
               Ledger.lookup_batch(store, "retry-head", "batch")
    end

    :ok = :mnesia.dirty_write(@heads, put_elem(head, 2, 2.0))

    assert {:error, :invalid_ledger_mnesia_head_row} =
             append(store, "retry-head", "batch", payloads, 0)

    :ok = :mnesia.dirty_write(@heads, head)
    assert {:ok, 2} = append(store, "retry-head", "batch", payloads, 0)
  end

  test "malformed cursors and options cannot start Mnesia transactions", %{store: {Mnesia, opts}} do
    for invalid <- [nil, -1, 1.0, "1"] do
      assert {:error, :invalid_ledger_cursor} = Mnesia.load_from("domain", invalid, opts)
      assert {:error, :invalid_ledger_cursor} = Mnesia.read_batch("domain", invalid, opts)
    end

    assert {:error, :invalid_ledger_mnesia_options} = Mnesia.load("domain", %{})
    assert {:error, :invalid_ledger_mnesia_options} = Mnesia.ensure_tables(%{})
  end

  defp corrupt_first_revision(store) do
    payloads = [%{"event" => "first"}, %{"event" => "second"}]
    assert {:ok, 2} = append(store, "corrupt-range", "batch", payloads, 0)
    [original] = :mnesia.dirty_read(@batches, {"corrupt-range", "batch"})
    assert elem(original, 4) === 1
    :ok = :mnesia.dirty_write(@batches, put_elem(original, 4, 1.0))
    {original, payloads}
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
  test "suffix reads verify only the selected complete batches", %{store: store} do
    assert {:ok, 1} = append(store, "suffix", "a", [%{"n" => 1}], 0)
    assert {:ok, prefix} = Ledger.load(store, "suffix")
    assert {:ok, 3} = append(store, "suffix", "b", [%{"n" => 2}, %{"n" => 3}], 1)
    assert {:ok, suffix} = Ledger.load_from(store, "suffix", prefix)
    assert Enum.map(suffix.entries, & &1.revision) == [2, 3]
    assert {:ok, %{entries: []}} = Ledger.load_from(store, "suffix", suffix)

    [first | _] = suffix.entries

    assert {:error, _} =
             Ledger.load_from(store, "suffix", %{revision: 2, head_digest: first.digest})

    :mnesia.dirty_delete(@entries, {"suffix", 3})
    assert {:error, _} = Ledger.load_from(store, "suffix", prefix)
  end

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
