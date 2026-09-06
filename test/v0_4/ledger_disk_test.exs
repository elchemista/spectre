defmodule Spectre.V04Test.LedgerDiskTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.Ledger
  alias Spectre.Ledger.Store, as: LedgerStore
  alias Spectre.Ledger.Store.Disk

  @frame_header_size 45

  test "failed first appends do not retain empty Domain indexes", %{directory: directory} do
    {store, _child} = start_disk(directory)

    for n <- 1..20 do
      assert {:error, :ambiguous} =
               LedgerStore.append(store, "absent-#{n}", "first", [%{"n" => n}], 0,
                 recorded_at: 1,
                 fault: :before_commit
               )
    end

    {Disk, opts} = store
    assert :sys.get_state(opts[:server]).domains === %{}
  end

  test "truncating an incomplete first batch leaves no committed head", %{directory: directory} do
    domain = "incomplete-genesis"
    File.write!(domain_path(directory, domain), "SPDL")
    {store, _child} = start_disk(directory, tail_policy: :truncate)
    assert :not_found = LedgerStore.head(store, domain)
    assert :not_found = Ledger.load(store, domain)
    assert {:ok, 1} = append(store, domain, "first", [%{"new" => true}], 0)
    assert {:ok, %{revision: 1}} = LedgerStore.head(store, domain)
  end

  test "the disk owner retains offsets, not historical payload bodies", %{directory: directory} do
    {store, _child} = start_disk(directory, compressed: true)
    payload = %{"body" => String.duplicate("historical bytes", 20_000)}

    for n <- 1..12 do
      assert {:ok, ^n} = append(store, "memory", "batch-#{n}", [payload], n - 1)
    end

    {Disk, opts} = store
    state = :sys.get_state(opts[:server])
    domain = state.domains["memory"]
    refute Map.has_key?(domain, :entries_rev)
    refute Map.has_key?(domain, :batches)
    assert :erlang.external_size(state) < 8_192
    assert is_reference(domain.index)
    assert {:ok, %{entries: [entry], revision: 6}} = LedgerStore.read_batch(store, "memory", 6)
    assert entry.payload === payload
    assert {:ok, %{revision: 12}} = LedgerStore.head(store, "memory")
  end

  test "compressed batches survive restart and a change of write policy", %{directory: directory} do
    payloads = [%{"body" => String.duplicate("retained content", 5_000)}]
    {store, child} = start_disk(directory, compressed: true)
    assert {:ok, 1} = append(store, "compressed", "first", payloads, 0)
    assert {:ok, original} = Ledger.export(store, "compressed")
    assert File.stat!(domain_path(directory, "compressed")).size < 5_000
    stop_disk(child)

    {store, _child} = start_disk(directory, compressed: false)
    assert {:ok, ^original} = Ledger.export(store, "compressed")
    assert {:ok, 1} = append(store, "compressed", "first", payloads, 0)
    assert {:ok, 2} = append(store, "compressed", "second", [%{"body" => "new"}], 1)
    assert {:ok, snapshot} = Ledger.load(store, "compressed")
    assert Enum.map(snapshot.entries, & &1.payload) === payloads ++ [%{"body" => "new"}]
  end

  setup do
    temporary_root = Path.expand(System.tmp_dir!())
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.join(temporary_root, "spectre-v04-ledger-disk-#{suffix}")
    File.mkdir!(directory)

    on_exit(fn -> remove_temporary_directory!(temporary_root, directory) end)

    {:ok, directory: directory}
  end

  test "complete batches and their idempotency index survive a store restart", %{
    directory: directory
  } do
    domain_ref = "domain:disk-restart"
    first_batch = [%{"event" => "one"}, %{"event" => "two"}]

    {store, child_id} = start_disk(directory)

    assert {:ok, 2} = append(store, domain_ref, "batch:first", first_batch, 0)
    assert {:ok, first_info} = Ledger.lookup_batch(store, domain_ref, "batch:first")
    path = domain_path(directory, domain_ref)
    first_batch_bytes = File.read!(path)

    assert {:error, :conflict} =
             append(
               store,
               domain_ref,
               "batch:stale-cas",
               [%{"event" => "must"}, %{"event" => "not-appear"}],
               1
             )

    assert :not_found = Ledger.lookup_batch(store, domain_ref, "batch:stale-cas")
    assert {:ok, %{revision: 2, entries: entries}} = Ledger.load(store, domain_ref)
    assert Enum.map(entries, & &1.payload) == first_batch
    assert File.read!(path) == first_batch_bytes
    stop_disk(child_id)

    {restarted, _child_id} = start_disk(directory)

    assert {:ok, snapshot} = Ledger.load(restarted, domain_ref)
    assert snapshot.revision == 2
    assert snapshot.recovery == nil
    assert Enum.map(snapshot.entries, & &1.payload) == first_batch
    assert {:ok, ^first_info} = Ledger.lookup_batch(restarted, domain_ref, "batch:first")
    assert {:ok, 2} = append(restarted, domain_ref, "batch:first", first_batch, 0)
    assert File.read!(path) == first_batch_bytes

    assert {:ok, 3} =
             append(restarted, domain_ref, "batch:second", [%{"event" => "three"}], 2)

    assert {:ok, exported} = Ledger.export(restarted, domain_ref)
    assert {:ok, %{revision: 3, recovery: nil}} = Ledger.verify(exported)
  end

  test "competing Disk CAS appends persist exactly one complete batch", %{directory: directory} do
    domain_ref = "domain:disk-cas"
    left = [%{"side" => "left", "index" => 1}, %{"side" => "left", "index" => 2}]
    right = [%{"side" => "right", "index" => 1}, %{"side" => "right", "index" => 2}]
    {store, child_id} = start_disk(directory)

    tasks = [
      Task.async(fn -> append(store, domain_ref, "batch:left", left, 0) end),
      Task.async(fn -> append(store, domain_ref, "batch:right", right, 0) end)
    ]

    replies = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(replies, &match?({:ok, 2}, &1)) == 1
    assert Enum.count(replies, &match?({:error, :conflict}, &1)) == 1

    assert {:ok, snapshot} = Ledger.load(store, domain_ref)
    persisted_payloads = Enum.map(snapshot.entries, & &1.payload)
    assert snapshot.revision == 2
    assert persisted_payloads in [left, right]
    assert snapshot.entries |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 1

    stop_disk(child_id)
    {restarted, _child_id} = start_disk(directory)
    assert {:ok, recovered} = Ledger.load(restarted, domain_ref)
    assert recovered.revision == 2
    assert Enum.map(recovered.entries, & &1.payload) == persisted_payloads
  end

  test "an incomplete tail is rejected by default and explicitly truncatable", %{
    directory: directory
  } do
    domain_ref = "domain:disk-incomplete-tail"
    {store, child_id} = start_disk(directory)

    assert {:ok, 1} =
             append(store, domain_ref, "batch:complete", [%{"event" => "complete"}], 0)

    path = domain_path(directory, domain_ref)
    complete_size = File.stat!(path).size
    stop_disk(child_id)

    File.write!(path, "SPDL", [:append, :binary])
    assert File.stat!(path).size == complete_size + 4

    {rejecting_store, rejecting_child_id} = start_disk(directory)

    assert {:error, {:incomplete_ledger_tail, ^complete_size}} =
             Ledger.load(rejecting_store, domain_ref)

    assert File.stat!(path).size == complete_size + 4
    stop_disk(rejecting_child_id)

    {truncating_store, truncating_child_id} = start_disk(directory, tail_policy: :truncate)

    assert {:ok,
            %{
              revision: 1,
              recovery: %{
                kind: :truncated_incomplete_tail,
                offset: ^complete_size,
                truncated_bytes: 4
              }
            }} = Ledger.load(truncating_store, domain_ref)

    assert File.stat!(path).size == complete_size
    stop_disk(truncating_child_id)

    {verified_store, _child_id} = start_disk(directory)
    assert {:ok, %{revision: 1, recovery: nil}} = Ledger.load(verified_store, domain_ref)
  end

  test "a valid header with a partial body follows the incomplete-tail policy", %{
    directory: directory
  } do
    domain_ref = "domain:disk-partial-body"
    {store, child_id} = start_disk(directory)

    assert {:ok, 1} =
             append(store, domain_ref, "batch:prefix", [%{"event" => "prefix"}], 0)

    path = domain_path(directory, domain_ref)
    prefix_bytes = File.read!(path)
    prefix_size = byte_size(prefix_bytes)

    assert {:ok, 2} =
             append(store, domain_ref, "batch:partial", [%{"event" => "partial"}], 1)

    complete_bytes = File.read!(path)
    partial_tail_size = @frame_header_size + 1
    partial_size = prefix_size + partial_tail_size
    assert partial_size < byte_size(complete_bytes)
    stop_disk(child_id)

    partial_bytes = binary_part(complete_bytes, 0, partial_size)
    File.write!(path, partial_bytes)

    {rejecting_store, rejecting_child_id} = start_disk(directory)

    assert {:error, {:incomplete_ledger_tail, ^prefix_size}} =
             Ledger.load(rejecting_store, domain_ref)

    assert File.read!(path) == partial_bytes
    stop_disk(rejecting_child_id)

    {truncating_store, truncating_child_id} = start_disk(directory, tail_policy: :truncate)

    assert {:ok,
            %{
              revision: 1,
              recovery: %{
                kind: :truncated_incomplete_tail,
                offset: ^prefix_size,
                truncated_bytes: ^partial_tail_size
              }
            }} = Ledger.load(truncating_store, domain_ref)

    assert File.read!(path) == prefix_bytes
    stop_disk(truncating_child_id)

    {restarted, _child_id} = start_disk(directory)
    assert {:ok, %{revision: 1, recovery: nil}} = Ledger.load(restarted, domain_ref)
  end

  test "audit export re-reads a warm cache and never truncates complete corruption", %{
    directory: directory
  } do
    domain_ref = "domain:disk-corrupt-tail"
    {store, child_id} = start_disk(directory, tail_policy: :truncate)

    assert {:ok, 1} =
             append(store, domain_ref, "batch:first", [%{"event" => "first"}], 0)

    path = domain_path(directory, domain_ref)
    first_frame_size = File.stat!(path).size

    assert {:ok, 2} =
             append(store, domain_ref, "batch:second", [%{"event" => "second"}], 1)

    complete_size = File.stat!(path).size
    assert {:ok, %{revision: 2}} = Ledger.load(store, domain_ref)

    corrupt_last_byte!(path)
    corrupt_bytes = File.read!(path)
    assert File.stat!(path).size == complete_size

    # The warm cache now holds offsets only, not a second copy of the entries.
    # Ordinary reads therefore detect changed bytes too, before an audit.
    assert {:error, {:ledger_frame_checksum_mismatch, ^first_frame_size}} =
             Ledger.load(store, domain_ref)

    assert {:error, {:ledger_frame_checksum_mismatch, ^first_frame_size}} =
             Ledger.export(store, domain_ref)

    assert File.read!(path) == corrupt_bytes
    stop_disk(child_id)

    {restarted, _child_id} = start_disk(directory, tail_policy: :truncate)

    assert {:error, {:ledger_frame_checksum_mismatch, ^first_frame_size}} =
             Ledger.load(restarted, domain_ref)

    assert File.read!(path) == corrupt_bytes
  end

  test "before/after commit ambiguity retries never duplicate a batch", %{directory: directory} do
    domain_ref = "domain:disk-ambiguous"
    before_id = "batch:before"
    after_id = "batch:after"
    before_payloads = [%{"event" => "before"}]
    after_payloads = [%{"event" => "after"}]
    {store, child_id} = start_disk(directory)

    assert {:error, :ambiguous} =
             append(store, domain_ref, before_id, before_payloads, 0,
               fault_injection: :before_commit
             )

    assert :not_found = Ledger.load(store, domain_ref)
    assert :not_found = Ledger.lookup_batch(store, domain_ref, before_id)
    assert {:ok, 1} = append(store, domain_ref, before_id, before_payloads, 0)

    assert {:error, :ambiguous} =
             append(store, domain_ref, after_id, after_payloads, 1,
               fault_injection: :after_commit
             )

    assert {:ok, %{last_revision: 2, entry_count: 1}} =
             Ledger.lookup_batch(store, domain_ref, after_id)

    stop_disk(child_id)
    {restarted, _child_id} = start_disk(directory)

    assert {:ok, 2} = append(restarted, domain_ref, after_id, after_payloads, 1)

    assert {:ok, snapshot} = Ledger.load(restarted, domain_ref)
    assert snapshot.revision == 2
    assert Enum.map(snapshot.entries, & &1.batch_id) == [before_id, after_id]
    assert Enum.map(snapshot.entries, & &1.payload) == before_payloads ++ after_payloads

    assert {:error, {:batch_identity_conflict, ^after_id}} =
             append(restarted, domain_ref, after_id, [%{"event" => "different"}], 1)
  end

  for {field, value, tag} <- [
        {"format", "another-format", :ledger_frame_binding_mismatch},
        {"format_version", 2, :ledger_frame_binding_mismatch},
        {"domain_ref", "another-domain", :ledger_frame_binding_mismatch},
        {"batch_id", nil, :invalid_ledger_frame},
        {"batch_id", 42, :invalid_ledger_frame},
        {"identity_digest", "bad", :invalid_or_duplicate_ledger_frame},
        {"expected_revision", 1.0, :invalid_ledger_frame},
        {"expected_revision", 99, :invalid_or_duplicate_ledger_frame},
        {"entries", [], :invalid_ledger_frame},
        {"entries", [%{}], :missing_ledger_entry_field}
      ] do
    test "a checksummed frame with corrupted #{field}=#{inspect(value)} is rejected without truncation",
         %{
           directory: directory
         } do
      {store, child} = start_disk(directory)
      domain = "frame-boundary"
      assert {:ok, 1} = append(store, domain, "batch", [%{"x" => 1}], 0)
      path = domain_path(directory, domain)
      stop_disk(child)

      <<"SPDL", 1, _size::unsigned-big-64, _digest::binary-size(32), encoded::binary>> =
        File.read!(path)

      {:ok, frame} = Value.decode(encoded)

      encoded =
        Value.encode!(Map.put(frame, unquote(field), unquote(Macro.escape(value))))

      bytes = disk_frame(encoded)
      File.write!(path, bytes)
      {restarted, _child} = start_disk(directory, tail_policy: :truncate)
      assert {:error, reason} = Ledger.load(restarted, domain)
      assert elem(reason, 0) == unquote(tag)
      assert {:error, _} = Ledger.export(restarted, domain)
      assert {:error, _} = Ledger.lookup_batch(restarted, domain, "batch")
      assert File.read!(path) == bytes
    end
  end

  test "invalid headers, encodings and non-map frames are never mistaken for incomplete tails", %{
    directory: directory
  } do
    domain = "invalid-frame"
    path = domain_path(directory, domain)

    for bytes <- [
          <<"NOPE", 1, 1::unsigned-big-64, 0::256, 0>>,
          <<"SPDL", 2, 1::unsigned-big-64, 0::256, 0>>,
          <<"SPDL", 1, 0::unsigned-big-64, 0::256>>,
          disk_frame("unknown-encoding"),
          disk_frame(Value.encode!([1, 2])),
          disk_frame(Value.encode!(%{"extra" => true}))
        ] do
      File.write!(path, bytes)
      {store, child} = start_disk(directory, tail_policy: :truncate)
      assert {:error, _} = Ledger.load(store, domain)
      assert File.read!(path) == bytes
      stop_disk(child)
    end
  end

  test "empty files are absent Domains and file-type confusion fails closed", %{
    directory: directory
  } do
    domain = "file-boundary"
    path = domain_path(directory, domain)
    File.write!(path, "")
    {store, child} = start_disk(directory)
    assert :not_found = Ledger.load(store, domain)
    assert :not_found = Ledger.export(store, domain)
    assert :not_found = Ledger.lookup_batch(store, domain, "batch")
    stop_disk(child)
    File.rm!(path)
    File.mkdir!(path)
    {store, _child} = start_disk(directory)
    assert {:error, _} = Ledger.load(store, domain)
    assert {:error, _} = append(store, domain, "batch", [%{"x" => 1}], 0)
  end

  test "invalid disk startup options fail before spawning a store" do
    for opts <- [
          nil,
          %{},
          [:invalid],
          [path: nil],
          [path: "", tail_policy: :ignore],
          [path: "/unused", tail_policy: :ignore],
          [path: "/unused", max_frame_bytes: 0]
        ] do
      assert {:error, _} = Disk.start_link(opts)
    end
  end

  test "directory ownership and filesystem failures return errors to untrapped callers", %{
    directory: directory
  } do
    {store, _child} = start_disk(directory)

    assert {:error, {:ledger_disk_directory_in_use, ^directory}} =
             Disk.start_link(path: directory)

    file = Path.join(directory, "not-a-directory")
    File.write!(file, "preserve")
    assert {:error, {:ledger_disk_directory_failed, _}} = Disk.start_link(path: file)
    assert File.read!(file) == "preserve"
    assert {:ok, 1} = append(store, "still-alive", "batch", [%{"x" => 1}], 0)
  end

  defp disk_frame(encoded),
    do:
      <<"SPDL", 1, byte_size(encoded)::unsigned-big-64, :crypto.hash(:sha256, encoded)::binary,
        encoded::binary>>

  defp start_disk(directory, opts \\ []) do
    child_id = {Disk, make_ref()}
    disk_opts = Keyword.put(opts, :path, directory)

    child_spec =
      Supervisor.child_spec({Disk, disk_opts},
        id: child_id,
        restart: :temporary
      )

    server = start_supervised!(child_spec)
    {{Disk, server: server}, child_id}
  end

  defp stop_disk(child_id) do
    assert :ok = stop_supervised(child_id)
  end

  defp domain_path(directory, domain_ref) do
    filename =
      domain_ref
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> Kernel.<>(".ledger")

    Path.join(directory, filename)
  end

  defp corrupt_last_byte!(path) do
    contents = File.read!(path)
    prefix_size = byte_size(contents) - 1
    prefix = binary_part(contents, 0, prefix_size)
    last_byte = :binary.at(contents, prefix_size)
    File.write!(path, prefix <> <<Bitwise.bxor(last_byte, 1)>>)
  end

  defp remove_temporary_directory!(temporary_root, directory) do
    expanded = Path.expand(directory)

    if Path.dirname(expanded) == temporary_root and
         String.starts_with?(Path.basename(expanded), "spectre-v04-ledger-disk-") do
      File.rm_rf!(expanded)
    else
      raise "refusing to remove unexpected test directory: #{inspect(expanded)}"
    end
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
