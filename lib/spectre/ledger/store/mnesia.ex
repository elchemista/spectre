defmodule Spectre.Ledger.Store.Mnesia do
  @moduledoc """
  Transactional Mnesia adapter for the append-only Domain ledger.

  The host owns the Mnesia schema, directory and cluster membership.
  `ensure_tables/1` is an explicit installation helper; normal ledger
  operations never create schemas or tables. Every append uses one
  synchronous Mnesia transaction and a write lock on the Domain head, so the
  expected revision, batch idempotency record, entries and new head move
  together. Tables must use durable copies and majority commits; volatile
  deployments should use `Spectre.Ledger.Store.ETS` instead.

  The adapter stores canonical `Spectre.Ledger.Entry` bytes rather than native
  structs. Table names and replica type are explicit deployment configuration.
  """

  @behaviour Spectre.Ledger.Store

  alias Spectre.Ledger
  alias Spectre.Ledger.Entry

  @default_heads :spectre_ledger_heads
  @default_batches :spectre_ledger_batches
  @default_entries :spectre_ledger_entries
  @storage_types [:disc_copies, :disc_only_copies]
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @max_identifier_bytes 1_024
  @heads_attributes [:key, :revision, :head_digest]
  @batches_attributes [
    :key,
    :identity_digest,
    :expected_revision,
    :first_revision,
    :last_revision,
    :entry_count,
    :head_digest
  ]
  @entries_attributes [:key, :encoded_entry]
  @configuration_options [
    :heads_table,
    :batches_table,
    :entries_table,
    :storage,
    :nodes,
    :wait_timeout
  ]
  @append_options @configuration_options ++ [:recorded_at, :fault_injection, :fault]

  @doc "Creates the three required tables in an already running Mnesia schema."
  @spec ensure_tables(keyword()) :: :ok | {:error, term()}
  def ensure_tables(opts \\ []) do
    with {:ok, config} <- configuration(opts, @configuration_options),
         :ok <- ensure_mnesia_running(),
         :ok <- create_table(config.heads, @heads_attributes, config),
         :ok <- create_table(config.batches, @batches_attributes, config),
         :ok <- create_table(config.entries, @entries_attributes, config),
         :ok <- wait_for_tables(config) do
      :ok
    end
  end

  @impl Spectre.Ledger.Store
  def append(domain_ref, batch_id, payloads, expected_revision, opts) do
    with {:ok, config} <- configuration(opts, @append_options),
         :ok <- tables_available(config),
         {:ok, identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
         {:ok, recorded_at} <- recorded_at(opts),
         {:ok, fault} <- fault_phase(opts) do
      append_transaction(
        config,
        domain_ref,
        batch_id,
        payloads,
        expected_revision,
        recorded_at,
        identity,
        fault
      )
    end
  end

  @impl Spectre.Ledger.Store
  def load(domain_ref, opts) do
    with {:ok, config} <- configuration(opts, @configuration_options),
         :ok <- tables_available(config) do
      read_transaction(fn -> load_locked(config, domain_ref) end)
    end
  end

  @impl Spectre.Ledger.Store
  def lookup_batch(domain_ref, batch_id, opts) do
    with {:ok, config} <- configuration(opts, @configuration_options),
         :ok <- tables_available(config) do
      read_transaction(fn -> lookup_batch_locked(config, domain_ref, batch_id) end)
    end
  end

  @impl Spectre.Ledger.Store
  def export(domain_ref, opts) do
    case load(domain_ref, opts) do
      {:ok, snapshot} -> Ledger.export_snapshot(snapshot)
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  defp append_transaction(
         config,
         domain_ref,
         batch_id,
         payloads,
         revision,
         recorded_at,
         identity,
         fault
       ) do
    transaction = fn ->
      case append_locked(
             config,
             domain_ref,
             batch_id,
             payloads,
             revision,
             recorded_at,
             identity,
             fault
           ) do
        {:error, reason} -> :mnesia.abort({:ledger_error, reason})
        result -> result
      end
    end

    case :mnesia.sync_transaction(transaction) do
      {:atomic, {:ok, committed_revision, :existing}} ->
        {:ok, committed_revision}

      {:atomic, {:ok, _committed_revision, :committed}} when fault == :after_commit ->
        {:error, :ambiguous}

      {:atomic, {:ok, committed_revision, :committed}} ->
        {:ok, committed_revision}

      {:aborted, {:ledger_error, reason}} ->
        {:error, reason}

      {:aborted, _reason} ->
        {:error, :ambiguous}

      _malformed ->
        {:error, :ambiguous}
    end
  end

  defp append_locked(
         config,
         domain_ref,
         batch_id,
         payloads,
         revision,
         recorded_at,
         identity,
         fault
       ) do
    batch_key = {domain_ref, batch_id}
    head_rows = :mnesia.read(config.heads, domain_ref, :write)
    batch_rows = :mnesia.read(config.batches, batch_key, :write)

    case existing_batch(config, domain_ref, batch_rows, identity, revision, batch_id) do
      {:ok, committed_revision} ->
        with {:ok, snapshot} <- load_locked(config, domain_ref),
             true <- snapshot.revision >= committed_revision do
          {:ok, committed_revision, :existing}
        else
          false -> {:error, :ledger_mnesia_batch_not_in_head}
          :not_found -> {:error, :ledger_mnesia_batch_without_head}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error

      :not_found ->
        append_new_locked(
          config,
          head_rows,
          domain_ref,
          batch_id,
          payloads,
          revision,
          recorded_at,
          identity,
          fault
        )
    end
  end

  defp append_new_locked(
         config,
         head_rows,
         domain_ref,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    with {:ok, current_revision, head_digest} <- current_head(config, domain_ref, head_rows) do
      cond do
        expected_revision != current_revision ->
          {:error, :conflict}

        fault == :before_commit ->
          {:error, :ambiguous}

        true ->
          persist_batch(
            config,
            domain_ref,
            batch_id,
            payloads,
            expected_revision,
            recorded_at,
            head_digest,
            identity
          )
      end
    end
  end

  defp persist_batch(
         config,
         domain_ref,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         head_digest,
         identity
       ) do
    with {:ok, entries} <-
           Entry.build_batch(
             domain_ref,
             batch_id,
             payloads,
             expected_revision,
             recorded_at,
             head_digest
           ),
         {:ok, encoded_entries} <- encode_entries(entries),
         :ok <- ensure_entry_slots_empty(config, domain_ref, encoded_entries) do
      last = List.last(entries)
      info = batch_info(batch_id, identity, expected_revision, entries, last)

      Enum.each(encoded_entries, fn {revision, encoded} ->
        :mnesia.write(
          config.entries,
          {config.entries, {domain_ref, revision}, encoded},
          :write
        )
      end)

      :mnesia.write(config.batches, batch_record(config.batches, domain_ref, info), :write)

      :mnesia.write(
        config.heads,
        {config.heads, domain_ref, last.revision, last.digest},
        :write
      )

      {:ok, last.revision, :committed}
    end
  end

  defp ensure_entry_slots_empty(config, domain_ref, encoded_entries) do
    Enum.reduce_while(encoded_entries, :ok, fn {revision, _encoded}, :ok ->
      case :mnesia.read(config.entries, {domain_ref, revision}, :write) do
        [] -> {:cont, :ok}
        _present -> {:halt, {:error, {:ledger_mnesia_entry_already_exists, revision}}}
      end
    end)
  end

  defp existing_batch(_config, _domain_ref, [], _identity, _revision, _batch_id),
    do: :not_found

  defp existing_batch(config, domain_ref, [row], identity, revision, batch_id) do
    with {:ok, info} <- decode_batch_record(config, domain_ref, batch_id, row),
         :ok <- validate_stored_batch(config, domain_ref, info) do
      if info.identity_digest == identity and info.expected_revision == revision,
        do: {:ok, info.last_revision},
        else: {:error, {:batch_identity_conflict, batch_id}}
    end
  end

  defp existing_batch(_config, _domain_ref, _rows, _identity, _revision, _batch_id),
    do: {:error, :invalid_ledger_mnesia_batch_row}

  defp current_head(_config, _domain_ref, []),
    do: {:ok, 0, Entry.genesis_digest()}

  defp current_head(config, domain_ref, [{table, domain_ref, revision, digest}])
       when table == config.heads do
    with :ok <- validate_head(revision, digest), do: {:ok, revision, digest}
  end

  defp current_head(_config, _domain_ref, _rows),
    do: {:error, :invalid_ledger_mnesia_head_row}

  defp load_locked(config, domain_ref) do
    case :mnesia.read(config.heads, domain_ref, :read) do
      [] ->
        :not_found

      head_rows ->
        entry_pattern = {config.entries, {domain_ref, :_}, :_}

        batch_pattern =
          {config.batches, {domain_ref, :_}, :_, :_, :_, :_, :_, :_}

        with {:ok, revision, head_digest} <- current_head(config, domain_ref, head_rows),
             {:ok, entries} <-
               decode_entry_rows(
                 :mnesia.match_object(config.entries, entry_pattern, :read),
                 config,
                 domain_ref
               ),
             {:ok, snapshot} <-
               Ledger.verify_snapshot(
                 %{
                   domain_ref: domain_ref,
                   revision: revision,
                   head_digest: head_digest,
                   entries: entries,
                   recovery: nil
                 },
                 domain_ref
               ),
             :ok <-
               validate_batch_index(
                 config,
                 domain_ref,
                 :mnesia.match_object(config.batches, batch_pattern, :read),
                 snapshot.entries
               ) do
          {:ok, snapshot}
        end
    end
  end

  defp lookup_batch_locked(config, domain_ref, batch_id) do
    case :mnesia.read(config.batches, {domain_ref, batch_id}, :read) do
      [] ->
        :not_found

      [row] ->
        with {:ok, info} <- decode_batch_record(config, domain_ref, batch_id, row),
             :ok <- validate_stored_batch(config, domain_ref, info),
             {:ok, snapshot} <- load_locked(config, domain_ref),
             true <- snapshot.revision >= info.last_revision do
          {:ok, info}
        else
          false -> {:error, :ledger_mnesia_batch_not_in_head}
          :not_found -> {:error, :ledger_mnesia_batch_without_head}
          {:error, _reason} = error -> error
        end

      _rows ->
        {:error, :invalid_ledger_mnesia_batch_row}
    end
  end

  defp read_transaction(fun) do
    case :mnesia.sync_transaction(fun) do
      {:atomic, :not_found} -> :not_found
      {:atomic, {:ok, _value} = result} -> result
      {:atomic, {:error, _reason} = error} -> error
      {:atomic, _malformed} -> {:error, :invalid_ledger_mnesia_transaction_result}
      {:aborted, reason} -> {:error, {:ledger_mnesia_transaction_failed, reason}}
      _malformed -> {:error, :invalid_ledger_mnesia_transaction_reply}
    end
  end

  defp encode_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, encoded} ->
      case Entry.encode(entry) do
        {:ok, bytes} -> {:cont, {:ok, [{entry.revision, bytes} | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_entry_rows(rows, config, domain_ref) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, decoded} ->
      case decode_entry_row(row, config, domain_ref) do
        {:ok, revision, entry} -> {:cont, {:ok, [{revision, entry} | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} ->
        {:ok,
         decoded
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map(&elem(&1, 1))}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_entry_rows(_rows, _config, _domain_ref),
    do: {:error, :invalid_ledger_mnesia_entry_rows}

  defp decode_entry_row(
         {table, {domain_ref, revision}, encoded},
         config,
         domain_ref
       )
       when table == config.entries and is_integer(revision) and revision > 0 and
              is_binary(encoded) do
    case Entry.decode(encoded) do
      {:ok, %Entry{domain_ref: ^domain_ref, revision: ^revision} = entry} ->
        {:ok, revision, entry}

      {:ok, _mismatched} ->
        {:error, {:mismatched_mnesia_ledger_entry, revision}}

      {:error, reason} ->
        {:error, {:invalid_mnesia_ledger_entry, reason}}
    end
  end

  defp decode_entry_row(_row, _config, _domain_ref),
    do: {:error, :invalid_ledger_mnesia_entry_row}

  defp batch_info(batch_id, identity, expected_revision, entries, last) do
    %{
      batch_id: batch_id,
      identity_digest: identity,
      expected_revision: expected_revision,
      first_revision: expected_revision + 1,
      last_revision: last.revision,
      entry_count: length(entries),
      head_digest: last.digest
    }
  end

  defp batch_record(table, domain_ref, info) do
    {
      table,
      {domain_ref, info.batch_id},
      info.identity_digest,
      info.expected_revision,
      info.first_revision,
      info.last_revision,
      info.entry_count,
      info.head_digest
    }
  end

  defp decode_batch_record(
         config,
         domain_ref,
         batch_id,
         {table, {domain_ref, batch_id}, identity, expected, first, last, count, head}
       )
       when table == config.batches do
    info = %{
      batch_id: batch_id,
      identity_digest: identity,
      expected_revision: expected,
      first_revision: first,
      last_revision: last,
      entry_count: count,
      head_digest: head
    }

    with :ok <- validate_batch_info(info), do: {:ok, info}
  end

  defp decode_batch_record(_config, _domain_ref, _batch_id, _row),
    do: {:error, :invalid_ledger_mnesia_batch_row}

  defp validate_batch_info(info) do
    cond do
      not valid_identifier?(info.batch_id) ->
        {:error, :invalid_ledger_mnesia_batch_id}

      not valid_digest?(info.identity_digest) ->
        {:error, :invalid_ledger_mnesia_batch_identity}

      not is_integer(info.expected_revision) or info.expected_revision < 0 ->
        {:error, :invalid_ledger_mnesia_batch_revision}

      info.first_revision != info.expected_revision + 1 ->
        {:error, :invalid_ledger_mnesia_batch_range}

      not is_integer(info.last_revision) or info.last_revision < info.first_revision ->
        {:error, :invalid_ledger_mnesia_batch_range}

      not is_integer(info.entry_count) or info.entry_count <= 0 or
        info.entry_count > Entry.max_batch_entries() or
          info.entry_count != info.last_revision - info.first_revision + 1 ->
        {:error, :invalid_ledger_mnesia_batch_count}

      not valid_digest?(info.head_digest) ->
        {:error, :invalid_ledger_mnesia_batch_head}

      true ->
        :ok
    end
  end

  defp validate_stored_batch(config, domain_ref, info) do
    rows =
      Enum.flat_map(info.first_revision..info.last_revision, fn revision ->
        :mnesia.read(config.entries, {domain_ref, revision}, :read)
      end)

    with {:ok, entries} <- decode_entry_rows(rows, config, domain_ref),
         {:ok, expected} <- batch_info_from_entries(domain_ref, entries),
         true <- expected == info do
      :ok
    else
      false -> {:error, {:ledger_mnesia_batch_metadata_mismatch, info.batch_id}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_batch_index(config, domain_ref, rows, entries) when is_list(rows) do
    with {:ok, stored} <- decode_batch_records(config, domain_ref, rows),
         {:ok, expected} <- expected_batch_index(domain_ref, entries),
         true <- stored == expected do
      :ok
    else
      false -> {:error, :ledger_mnesia_batch_index_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_batch_index(_config, _domain_ref, _rows, _entries),
    do: {:error, :invalid_ledger_mnesia_batch_rows}

  defp decode_batch_records(config, domain_ref, rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, batches} ->
      batch_id = batch_record_id(row)

      with true <- is_binary(batch_id),
           false <- Map.has_key?(batches, batch_id),
           {:ok, info} <- decode_batch_record(config, domain_ref, batch_id, row) do
        {:cont, {:ok, Map.put(batches, batch_id, info)}}
      else
        false -> {:halt, {:error, :invalid_ledger_mnesia_batch_row}}
        true -> {:halt, {:error, {:duplicate_ledger_mnesia_batch, batch_id}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp expected_batch_index(domain_ref, entries) do
    entries
    |> Enum.chunk_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, batches} ->
      with {:ok, info} <- batch_info_from_entries(domain_ref, batch),
           false <- Map.has_key?(batches, info.batch_id) do
        {:cont, {:ok, Map.put(batches, info.batch_id, info)}}
      else
        true -> {:halt, {:error, :duplicate_ledger_mnesia_batch}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp batch_info_from_entries(domain_ref, [%Entry{} = first | _rest] = entries) do
    last = List.last(entries)
    expected_revision = first.revision - 1

    with true <- valid_batch_coordinates?(entries, domain_ref, first.batch_id),
         {:ok, _verified} <-
           Entry.verify_chain(entries,
             domain_ref: domain_ref,
             start_revision: expected_revision,
             prev_digest: first.prev_digest
           ),
         {:ok, identity} <-
           Entry.batch_identity(
             domain_ref,
             first.batch_id,
             Enum.map(entries, & &1.payload),
             expected_revision
           ) do
      {:ok, batch_info(first.batch_id, identity, expected_revision, entries, last)}
    else
      false -> {:error, {:mismatched_mnesia_ledger_batch, first.batch_id}}
      {:error, reason} -> {:error, {:invalid_mnesia_ledger_batch, reason}}
    end
  end

  defp batch_info_from_entries(_domain_ref, _entries),
    do: {:error, :empty_mnesia_ledger_batch}

  defp valid_batch_coordinates?(entries, domain_ref, batch_id) do
    size = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.all?(fn {entry, index} ->
      entry.domain_ref == domain_ref and entry.batch_id == batch_id and
        entry.batch_size == size and entry.batch_index == index
    end)
  end

  defp batch_record_id(
         {_table, {_domain_ref, batch_id}, _identity, _expected, _first, _last, _count, _head}
       ),
       do: batch_id

  defp batch_record_id(_row), do: nil

  defp validate_head(revision, digest) do
    if is_integer(revision) and revision > 0 and valid_digest?(digest),
      do: :ok,
      else: {:error, :invalid_ledger_mnesia_head_row}
  end

  defp valid_identifier?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_identifier_bytes

  defp valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(@digest_pattern, value)

  defp valid_digest?(_value), do: false

  defp configuration(opts, allowed) when is_list(opts) do
    with :ok <- validate_options(opts, allowed) do
      config = %{
        heads: Keyword.get(opts, :heads_table, @default_heads),
        batches: Keyword.get(opts, :batches_table, @default_batches),
        entries: Keyword.get(opts, :entries_table, @default_entries),
        storage: Keyword.get(opts, :storage, :disc_copies),
        nodes: Keyword.get(opts, :nodes, [node()]),
        wait_timeout: Keyword.get(opts, :wait_timeout, 30_000)
      }

      validate_configuration(config)
    end
  end

  defp configuration(_opts, _allowed), do: {:error, :invalid_ledger_mnesia_options}

  defp validate_configuration(config) do
    tables = [config.heads, config.batches, config.entries]

    cond do
      not Enum.all?(tables, &(is_atom(&1) and not is_nil(&1))) ->
        {:error, :invalid_ledger_mnesia_table}

      length(Enum.uniq(tables)) != 3 ->
        {:error, :ledger_mnesia_tables_must_be_distinct}

      config.storage not in @storage_types ->
        {:error, :invalid_ledger_mnesia_storage}

      not is_list(config.nodes) or config.nodes == [] or
        not Enum.all?(config.nodes, &(is_atom(&1) and not is_nil(&1))) or
          length(config.nodes) != length(Enum.uniq(config.nodes)) ->
        {:error, :invalid_ledger_mnesia_nodes}

      not is_integer(config.wait_timeout) or config.wait_timeout < 0 ->
        {:error, :invalid_ledger_mnesia_wait_timeout}

      true ->
        {:ok, config}
    end
  end

  defp ensure_mnesia_running do
    if :mnesia.system_info(:is_running) == :yes,
      do: :ok,
      else: {:error, :mnesia_not_running}
  catch
    :exit, _reason -> {:error, :mnesia_not_running}
  end

  defp create_table(table, attributes, config) do
    options = [
      {:attributes, attributes},
      {:type, :set},
      {:majority, true},
      {config.storage, config.nodes}
    ]

    case :mnesia.create_table(table, options) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table}} -> verify_table(table, attributes, config)
      {:aborted, reason} -> {:error, {:ledger_mnesia_table_create_failed, table, reason}}
      _malformed -> {:error, {:invalid_ledger_mnesia_table_create_reply, table}}
    end
  end

  defp verify_table(table, attributes, config) do
    copies = :mnesia.table_info(table, config.storage)
    configured_nodes = MapSet.new(config.nodes)

    if is_list(copies) and
         :mnesia.table_info(table, :attributes) == attributes and
         :mnesia.table_info(table, :type) == :set and
         :mnesia.table_info(table, :majority) == true and
         :mnesia.table_info(table, :record_name) == table and
         MapSet.subset?(configured_nodes, MapSet.new(copies)),
       do: :ok,
       else: {:error, {:incompatible_ledger_mnesia_table, table}}
  catch
    :exit, reason -> {:error, {:ledger_mnesia_table_info_failed, table, reason}}
  end

  defp wait_for_tables(config) do
    tables = [config.heads, config.batches, config.entries]

    case :mnesia.wait_for_tables(tables, config.wait_timeout) do
      :ok -> :ok
      {:timeout, unavailable} -> {:error, {:ledger_mnesia_tables_unavailable, unavailable}}
      {:error, reason} -> {:error, {:ledger_mnesia_wait_failed, reason}}
      _malformed -> {:error, :invalid_ledger_mnesia_wait_reply}
    end
  catch
    :exit, reason -> {:error, {:ledger_mnesia_wait_failed, reason}}
  end

  defp tables_available(config) do
    with :ok <- ensure_mnesia_running(),
         :ok <- wait_for_tables(config),
         :ok <- verify_table(config.heads, @heads_attributes, config),
         :ok <- verify_table(config.batches, @batches_attributes, config) do
      verify_table(config.entries, @entries_attributes, config)
    end
  end

  defp fault_phase(opts) do
    value = Keyword.get(opts, :fault_injection, Keyword.get(opts, :fault))

    if value in [nil, :before_commit, :after_commit],
      do: {:ok, value},
      else: {:error, {:invalid_ledger_fault_injection, value}}
  end

  defp recorded_at(opts) do
    case Keyword.fetch(opts, :recorded_at) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _missing_or_invalid -> {:error, :ledger_recorded_at_required}
    end
  end

  defp validate_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- allowed do
        [] ->
          :ok

        unknown ->
          {:error, {:unknown_ledger_mnesia_options, unknown |> Enum.uniq() |> Enum.sort()}}
      end
    else
      {:error, :invalid_ledger_mnesia_options}
    end
  end
end
