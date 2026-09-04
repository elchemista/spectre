defmodule Spectre.Ledger.Store.Postgres do
  @moduledoc """
  PostgreSQL ledger adapter backed by the host application's Repo.

  Spectre intentionally has no database dependency. The application supplies
  `:repo`; by default SQL is executed dynamically through
  `Ecto.Adapters.SQL.query/4` and transactions through the Repo's
  `transaction/2` and `rollback/1` callbacks. A different compatible SQL module
  may be supplied with `:query_module`.

  Each logical batch is stored once as canonical bytes. A transaction-scoped
  advisory lock serializes one Domain, while a revision-guarded head update and
  database constraints preserve CAS and idempotency. Write transactions force
  `synchronous_commit` on; the host remains responsible for keeping PostgreSQL
  `fsync` enabled. Schema creation belongs to an application migration generated
  by Spectre; this adapter never runs DDL.
  """

  @behaviour Spectre.Ledger.Store

  alias Spectre.Adapter
  alias Spectre.Canonical.Value
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  @identifier_pattern ~r/\A[a-z_][a-z0-9_]*\z/
  @default_schema "public"
  @default_prefix "spectre_ledger"
  @namespace_options [:schema, :table_prefix]
  @configuration_options [
    :repo,
    :query_module,
    :schema,
    :table_prefix,
    :query_opts,
    :transaction_opts
  ]
  @append_options @configuration_options ++ [:recorded_at, :fault_injection, :fault]

  @impl Spectre.Ledger.Store
  def append(domain_ref, batch_id, payloads, expected_revision, opts) do
    with {:ok, config} <- configuration(opts, @append_options),
         :ok <- adapter_available(config),
         {:ok, identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
         {:ok, recorded_at} <- Support.recorded_at(opts),
         {:ok, fault} <- Support.fault_phase(opts) do
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
         :ok <- adapter_available(config) do
      read_transaction(config, fn -> load_locked(config, domain_ref) end)
    end
  end

  @impl Spectre.Ledger.Store
  def lookup_batch(domain_ref, batch_id, opts) do
    with {:ok, config} <- configuration(opts, @configuration_options),
         :ok <- adapter_available(config) do
      read_transaction(config, fn -> lookup_batch_locked(config, domain_ref, batch_id) end)
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

  @doc "Returns the validated SQL namespace used by the migration generator."
  @spec namespace(keyword()) ::
          {:ok, %{schema: String.t(), table_prefix: String.t()}} | {:error, term()}
  def namespace(opts \\ [])

  def namespace(opts) when is_list(opts) do
    with :ok <- validate_options(opts, @namespace_options) do
      namespace_from_options(opts)
    end
  end

  def namespace(_opts), do: {:error, :invalid_ledger_postgres_options}

  @doc "Returns the PostgreSQL DDL embedded by the host migration generator."
  @spec migration_sql(keyword()) ::
          {:ok, %{up: [String.t()], down: [String.t()]}} | {:error, term()}
  def migration_sql(opts \\ []) do
    with {:ok, namespace} <- namespace(opts) do
      config = Map.put(namespace, :repo, nil)
      heads = table(config, "heads")
      batches = table(config, "batches")
      mutation_guard = qualified(config, config.table_prefix <> "_guard")
      append_only_trigger = ~s("spectre_ledger_append_only")

      {:ok,
       %{
         up: [
           """
           CREATE TABLE #{heads} (
             domain_ref text PRIMARY KEY,
             revision bigint NOT NULL CHECK (revision > 0),
             head_digest character(64) NOT NULL
               CHECK (head_digest ~ '^[0-9a-f]{64}$'),
             CHECK (octet_length(domain_ref) BETWEEN 1 AND 1024)
           )
           """,
           """
           CREATE TABLE #{batches} (
             domain_ref text NOT NULL REFERENCES #{heads} (domain_ref)
               ON UPDATE RESTRICT ON DELETE RESTRICT,
             batch_id text NOT NULL,
             identity_digest character(64) NOT NULL
               CHECK (identity_digest ~ '^[0-9a-f]{64}$'),
             expected_revision bigint NOT NULL CHECK (expected_revision >= 0),
             first_revision bigint NOT NULL CHECK (first_revision > 0),
             last_revision bigint NOT NULL CHECK (last_revision >= first_revision),
             entry_count integer NOT NULL CHECK (entry_count > 0),
             head_digest character(64) NOT NULL
               CHECK (head_digest ~ '^[0-9a-f]{64}$'),
             encoded_entries bytea NOT NULL,
             PRIMARY KEY (domain_ref, batch_id),
             UNIQUE (domain_ref, first_revision),
             CHECK (octet_length(domain_ref) BETWEEN 1 AND 1024),
             CHECK (octet_length(batch_id) BETWEEN 1 AND 1024),
             CHECK (first_revision = expected_revision + 1),
             CHECK (entry_count = last_revision - first_revision + 1)
           )
           """,
           """
           CREATE FUNCTION #{mutation_guard}()
           RETURNS trigger
           LANGUAGE plpgsql
           AS $spectre$
           BEGIN
             RAISE EXCEPTION 'Spectre ledger batches are append-only';
             RETURN NULL;
           END;
           $spectre$
           """,
           """
           CREATE TRIGGER #{append_only_trigger}
           BEFORE UPDATE OR DELETE OR TRUNCATE ON #{batches}
           FOR EACH STATEMENT
           EXECUTE FUNCTION #{mutation_guard}()
           """
         ],
         down: [
           "DROP TRIGGER #{append_only_trigger} ON #{batches}",
           "DROP FUNCTION #{mutation_guard}()",
           "DROP TABLE #{batches}",
           "DROP TABLE #{heads}"
         ]
       }}
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
    operation = fn ->
      with :ok <- require_synchronous_commit(config),
           {:ok, _lock} <- lock_domain(config, domain_ref),
           {:ok, existing} <- existing_batch(config, domain_ref, batch_id),
           {:ok, result} <-
             append_or_reuse(
               config,
               existing,
               domain_ref,
               batch_id,
               payloads,
               revision,
               recorded_at,
               identity,
               fault
             ) do
        result
      else
        {:error, reason} -> rollback(config, {:ledger_error, reason})
      end
    end

    case transaction(config, operation) do
      {:ok, {:existing, committed_revision}} ->
        {:ok, committed_revision}

      {:ok, {:committed, _committed_revision}} when fault == :after_commit ->
        {:error, :ambiguous}

      {:ok, {:committed, committed_revision}} ->
        {:ok, committed_revision}

      {:error, {:ledger_error, reason}} ->
        {:error, reason}

      {:error, _unknown_transaction_failure} ->
        {:error, :ambiguous}

      _malformed ->
        {:error, :ambiguous}
    end
  end

  defp require_synchronous_commit(config) do
    case query(config, "SET LOCAL synchronous_commit = on", []) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp append_or_reuse(
         config,
         %{identity_digest: identity, expected_revision: revision, last_revision: last},
         domain_ref,
         _batch_id,
         _payloads,
         revision,
         _recorded_at,
         identity,
         _fault
       ) do
    with {:ok, snapshot} <- load_locked(config, domain_ref),
         true <- snapshot.revision >= last do
      {:ok, {:existing, last}}
    else
      false -> {:error, :ledger_postgres_batch_not_in_head}
      :not_found -> {:error, :ledger_postgres_batch_without_head}
      {:error, _reason} = error -> error
    end
  end

  defp append_or_reuse(
         _config,
         %{},
         _domain_ref,
         batch_id,
         _payloads,
         _revision,
         _recorded_at,
         _identity,
         _fault
       ),
       do: {:error, {:batch_identity_conflict, batch_id}}

  defp append_or_reuse(
         config,
         nil,
         domain_ref,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    with {:ok, current_revision, head_digest} <- locked_head(config, domain_ref),
         :ok <- matching_revision(current_revision, expected_revision),
         :ok <- before_commit(fault),
         {:ok, entries} <-
           Entry.build_batch(
             domain_ref,
             batch_id,
             payloads,
             expected_revision,
             recorded_at,
             head_digest
           ),
         {:ok, encoded} <- encode_entries(entries),
         last = List.last(entries),
         :ok <- write_head(config, domain_ref, current_revision, last),
         :ok <- write_batch(config, domain_ref, batch_id, identity, entries, last, encoded) do
      {:ok, {:committed, last.revision}}
    end
  end

  defp lock_domain(config, domain_ref) do
    with {:ok, result} <-
           query(
             config,
             "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)",
             [domain_ref]
           ),
         {:ok, [[_lock_value]]} <- result_rows(result) do
      {:ok, :locked}
    else
      {:ok, _malformed_rows} -> {:error, :invalid_ledger_postgres_lock_result}
      {:error, _reason} = error -> error
    end
  end

  defp existing_batch(config, domain_ref, batch_id) do
    with {:ok, result} <-
           query(
             config,
             """
             SELECT identity_digest, expected_revision, first_revision,
                    last_revision, entry_count, head_digest, encoded_entries
             FROM #{table(config, "batches")}
             WHERE domain_ref = $1 AND batch_id = $2
             """,
             [domain_ref, batch_id]
           ),
         {:ok, result_rows} <- result_rows(result) do
      decode_existing_batch(result_rows, domain_ref, batch_id)
    end
  end

  defp locked_head(config, domain_ref) do
    with {:ok, result} <-
           query(
             config,
             """
             SELECT revision, head_digest
             FROM #{table(config, "heads")}
             WHERE domain_ref = $1
             FOR UPDATE
             """,
             [domain_ref]
           ),
         {:ok, result_rows} <- result_rows(result) do
      decode_head(result_rows, :allow_missing)
    end
  end

  defp write_head(config, domain_ref, 0, last) do
    with {:ok, result} <-
           query(
             config,
             """
             INSERT INTO #{table(config, "heads")} (domain_ref, revision, head_digest)
             VALUES ($1, $2, $3)
             ON CONFLICT (domain_ref) DO NOTHING
             """,
             [domain_ref, last.revision, last.digest]
           ) do
      affected_once(result)
    end
  end

  defp write_head(config, domain_ref, expected_revision, last) do
    with {:ok, result} <-
           query(
             config,
             """
             UPDATE #{table(config, "heads")}
             SET revision = $2, head_digest = $3
             WHERE domain_ref = $1 AND revision = $4
             """,
             [domain_ref, last.revision, last.digest, expected_revision]
           ) do
      affected_once(result)
    end
  end

  defp write_batch(config, domain_ref, batch_id, identity, entries, last, encoded) do
    first = hd(entries)

    with {:ok, result} <-
           query(
             config,
             """
             INSERT INTO #{table(config, "batches")} (
               domain_ref, batch_id, identity_digest, expected_revision,
               first_revision, last_revision, entry_count, head_digest,
               encoded_entries
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
             """,
             [
               domain_ref,
               batch_id,
               identity,
               first.revision - 1,
               first.revision,
               last.revision,
               length(entries),
               last.digest,
               encoded
             ]
           ) do
      affected_once(result)
    end
  end

  defp load_locked(config, domain_ref) do
    with {:ok, head_result} <-
           query(
             config,
             """
             SELECT revision, head_digest
             FROM #{table(config, "heads")}
             WHERE domain_ref = $1
             FOR SHARE
             """,
             [domain_ref]
           ),
         {:ok, head_rows} <- result_rows(head_result) do
      load_batches(config, domain_ref, head_rows)
    end
  end

  defp load_batches(_config, _domain_ref, []), do: :not_found

  defp load_batches(config, domain_ref, [[revision, head_digest]]) do
    with :ok <- validate_head(revision, head_digest),
         {:ok, batches_result} <-
           query(
             config,
             """
             SELECT batch_id, identity_digest, expected_revision,
                    first_revision, last_revision, entry_count,
                    head_digest, encoded_entries
             FROM #{table(config, "batches")}
             WHERE domain_ref = $1
             ORDER BY first_revision ASC
             """,
             [domain_ref]
           ),
         {:ok, batch_rows} <- result_rows(batches_result),
         {:ok, entries} <- decode_batches(batch_rows, domain_ref) do
      Ledger.verify_snapshot(
        %{
          domain_ref: domain_ref,
          revision: revision,
          head_digest: head_digest,
          entries: entries,
          recovery: nil
        },
        domain_ref
      )
    end
  end

  defp load_batches(_config, _domain_ref, _invalid),
    do: {:error, :invalid_ledger_postgres_head_row}

  defp lookup_batch_locked(config, domain_ref, batch_id) do
    with {:ok, result} <-
           query(
             config,
             """
             SELECT identity_digest, expected_revision, first_revision,
                    last_revision, entry_count, head_digest, encoded_entries
             FROM #{table(config, "batches")}
             WHERE domain_ref = $1 AND batch_id = $2
             """,
             [domain_ref, batch_id]
           ),
         {:ok, rows} <- result_rows(result) do
      case decode_batch_lookup(rows, domain_ref, batch_id) do
        :not_found ->
          :not_found

        {:ok, info} ->
          with {:ok, snapshot} <- load_locked(config, domain_ref),
               true <- snapshot.revision >= info.last_revision do
            {:ok, info}
          else
            false -> {:error, :ledger_postgres_batch_not_in_head}
            :not_found -> {:error, :ledger_postgres_batch_without_head}
            {:error, _reason} = error -> error
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp read_transaction(config, operation) do
    case transaction(config, operation) do
      {:ok, :not_found} -> :not_found
      {:ok, {:ok, _value} = result} -> result
      {:ok, {:error, _reason} = error} -> error
      {:ok, _malformed} -> {:error, :invalid_ledger_postgres_transaction_result}
      {:error, reason} -> {:error, {:ledger_postgres_transaction_failed, error_kind(reason)}}
      _malformed -> {:error, :invalid_ledger_postgres_transaction_reply}
    end
  end

  defp transaction(config, operation) do
    apply(config.repo, :transaction, [operation, config.transaction_opts])
  end

  defp rollback(config, reason), do: apply(config.repo, :rollback, [reason])

  defp query(config, statement, parameters) do
    case apply(config.query_module, :query, [
           config.repo,
           statement,
           parameters,
           config.query_opts
         ]) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:ledger_postgres_query_failed, error_kind(reason)}}
      _malformed -> {:error, :invalid_ledger_postgres_query_reply}
    end
  end

  defp encode_entries(entries) do
    entries
    |> Enum.map(&Entry.to_data/1)
    |> Value.encode()
  end

  defp decode_batches(rows, domain_ref) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [batch_id, identity, expected, first, last, count, head, encoded], {:ok, entries}
      when is_binary(encoded) ->
        info = Support.batch_info(batch_id, identity, expected, first, last, count, head)

        with :ok <- validate_batch_info(info, batch_id),
             {:ok, batch} <- decode_entry_batch(encoded),
             :ok <- validate_decoded_batch(batch, domain_ref, info) do
          {:cont, {:ok, Enum.reverse(batch, entries)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_ledger_postgres_batch_row}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_entry_batch(encoded) do
    with {:ok, values} <- Value.decode(encoded),
         true <- is_list(values) and values != [] do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, entries} ->
        case Entry.from_data(value) do
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          {:error, reason} -> {:halt, {:error, {:invalid_postgres_ledger_entry, reason}}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _reason} = error -> error
      end
    else
      false -> {:error, :empty_postgres_ledger_batch}
      {:error, reason} -> {:error, {:invalid_postgres_ledger_batch, reason}}
    end
  end

  defp decode_batch_lookup(result_rows, domain_ref, batch_id) do
    case result_rows do
      [] ->
        :not_found

      [[identity, expected, first, last, count, head, encoded]] when is_binary(encoded) ->
        info = Support.batch_info(batch_id, identity, expected, first, last, count, head)

        with :ok <- validate_batch_info(info, batch_id),
             {:ok, entries} <- decode_entry_batch(encoded),
             :ok <- validate_decoded_batch(entries, domain_ref, info) do
          {:ok, info}
        end

      _invalid ->
        {:error, :invalid_ledger_postgres_batch_row}
    end
  end

  defp decode_existing_batch([], _domain_ref, _batch_id), do: {:ok, nil}

  defp decode_existing_batch(
         [[identity, expected, first, last, count, head, encoded]],
         domain_ref,
         batch_id
       )
       when is_binary(encoded) do
    info = Support.batch_info(batch_id, identity, expected, first, last, count, head)

    with :ok <- validate_batch_info(info, batch_id),
         {:ok, entries} <- decode_entry_batch(encoded),
         :ok <- validate_decoded_batch(entries, domain_ref, info) do
      {:ok, info}
    end
  end

  defp decode_existing_batch(_rows, _domain_ref, _batch_id),
    do: {:error, :invalid_ledger_postgres_batch_row}

  defp validate_batch_info(info, expected_batch_id) do
    case Support.validate_batch_info(info, expected_batch_id) do
      :ok -> :ok
      {:error, field} -> {:error, batch_info_error(field)}
    end
  end

  defp batch_info_error(:batch_id), do: :invalid_ledger_postgres_batch_id
  defp batch_info_error(:identity), do: :invalid_ledger_postgres_batch_identity
  defp batch_info_error(:revision), do: :invalid_ledger_postgres_batch_revision
  defp batch_info_error(:range), do: :invalid_ledger_postgres_batch_range
  defp batch_info_error(:count), do: :invalid_ledger_postgres_batch_count
  defp batch_info_error(:head), do: :invalid_ledger_postgres_batch_head

  defp validate_decoded_batch(entries, domain_ref, info) do
    first = List.first(entries)
    last = List.last(entries)

    with true <- length(entries) == info.entry_count,
         %Entry{} <- first,
         %Entry{} <- last,
         true <- first.domain_ref == domain_ref,
         true <- first.batch_id == info.batch_id,
         true <- first.revision == info.first_revision,
         true <- last.revision == info.last_revision,
         true <- last.digest == info.head_digest,
         true <-
           Enum.all?(entries, &(&1.domain_ref == domain_ref and &1.batch_id == info.batch_id)),
         {:ok, identity} <-
           Entry.batch_identity(
             domain_ref,
             info.batch_id,
             Enum.map(entries, & &1.payload),
             info.expected_revision
           ),
         true <- identity == info.identity_digest do
      :ok
    else
      false -> {:error, {:ledger_postgres_batch_metadata_mismatch, info.batch_id}}
      nil -> {:error, {:ledger_postgres_batch_metadata_mismatch, info.batch_id}}
      {:error, reason} -> {:error, {:invalid_postgres_ledger_batch, reason}}
      _invalid -> {:error, {:ledger_postgres_batch_metadata_mismatch, info.batch_id}}
    end
  end

  defp decode_head([], :allow_missing), do: {:ok, 0, Entry.genesis_digest()}

  defp decode_head([[revision, digest]], _missing_policy) do
    with :ok <- validate_head(revision, digest), do: {:ok, revision, digest}
  end

  defp decode_head(_rows, _missing_policy), do: {:error, :invalid_ledger_postgres_head_row}

  defp validate_head(revision, digest) do
    if is_integer(revision) and revision > 0 and Support.valid_digest?(digest),
      do: :ok,
      else: {:error, :invalid_ledger_postgres_head_row}
  end

  defp affected_once(%{num_rows: 1}), do: :ok
  defp affected_once(%{num_rows: 0}), do: {:error, :conflict}

  defp affected_once(%{num_rows: count}) when is_integer(count),
    do: {:error, {:invalid_ledger_postgres_affected_rows, count}}

  defp affected_once(_result), do: {:error, :invalid_ledger_postgres_query_result}

  defp result_rows(%{rows: rows}) when is_list(rows), do: {:ok, rows}
  defp result_rows(_result), do: {:error, :invalid_ledger_postgres_query_result}

  defp matching_revision(revision, revision), do: :ok
  defp matching_revision(_current, _expected), do: {:error, :conflict}

  defp before_commit(:before_commit), do: {:error, :ambiguous}
  defp before_commit(_fault), do: :ok

  defp configuration(opts, allowed) when is_list(opts) do
    with :ok <- validate_options(opts, allowed),
         {:ok, repo} <- required_module(opts, :repo),
         {:ok, query_module} <- query_module(opts),
         {:ok, namespace} <- namespace_from_options(opts),
         {:ok, query_opts} <- keyword_option(opts, :query_opts, []),
         {:ok, transaction_opts} <- keyword_option(opts, :transaction_opts, []) do
      {:ok,
       %{
         repo: repo,
         query_module: query_module,
         schema: namespace.schema,
         table_prefix: namespace.table_prefix,
         query_opts: query_opts,
         transaction_opts: transaction_opts
       }}
    end
  end

  defp configuration(_opts, _allowed), do: {:error, :invalid_ledger_postgres_options}

  defp namespace_from_options(opts) do
    with {:ok, schema} <-
           sql_identifier(Keyword.get(opts, :schema, @default_schema), :schema),
         {:ok, prefix} <-
           sql_identifier(Keyword.get(opts, :table_prefix, @default_prefix), :table_prefix) do
      {:ok, %{schema: schema, table_prefix: prefix}}
    end
  end

  defp required_module(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, module} when is_atom(module) and not is_nil(module) -> {:ok, module}
      :error -> {:error, {:missing_ledger_postgres_option, key}}
      {:ok, _invalid} -> {:error, {:invalid_ledger_postgres_option, key}}
    end
  end

  defp query_module(opts) do
    module = Keyword.get(opts, :query_module, Ecto.Adapters.SQL)

    if is_atom(module) and not is_nil(module),
      do: {:ok, module},
      else: {:error, {:invalid_ledger_postgres_option, :query_module}}
  end

  defp keyword_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: {:error, {:invalid_ledger_postgres_option, key}}

      _invalid ->
        {:error, {:invalid_ledger_postgres_option, key}}
    end
  end

  defp adapter_available(config) do
    with :ok <- postgres_repo_available(config.repo),
         :ok <- postgres_query_available(config.query_module) do
      :ok
    end
  end

  defp postgres_repo_available(repo) do
    case Adapter.validate(repo, transaction: 2, rollback: 1) do
      :ok ->
        :ok

      {:error, {:adapter_callback_missing, ^repo, callback, arity}} ->
        {:error, {:ledger_postgres_repo_callback_missing, callback, arity}}

      {:error, _reason} ->
        {:error, {:ledger_postgres_repo_unavailable, repo}}
    end
  end

  defp postgres_query_available(query_module) do
    case Adapter.validate(query_module, query: 4) do
      :ok ->
        :ok

      {:error, {:adapter_callback_missing, ^query_module, :query, 4}} ->
        {:error, {:ledger_postgres_query_callback_missing, :query, 4}}

      {:error, _reason} ->
        {:error, {:ledger_postgres_query_module_unavailable, query_module}}
    end
  end

  defp sql_identifier(value, field) when is_binary(value) do
    max_bytes = if field == :table_prefix, do: 55, else: 63

    if byte_size(value) <= max_bytes and Regex.match?(@identifier_pattern, value),
      do: {:ok, value},
      else: {:error, :invalid_ledger_postgres_identifier}
  end

  defp sql_identifier(_value, field),
    do: {:error, {:invalid_ledger_postgres_option, field}}

  defp table(config, suffix) do
    ~s("#{config.schema}"."#{config.table_prefix}_#{suffix}")
  end

  defp qualified(config, identifier), do: ~s("#{config.schema}"."#{identifier}")

  defp validate_options(opts, allowed) do
    Support.validate_options(
      opts,
      allowed,
      :invalid_ledger_postgres_options,
      :unknown_ledger_postgres_options
    )
  end

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(%{__struct__: module}), do: module
  defp error_kind(_reason), do: :unknown
end
