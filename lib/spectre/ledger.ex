defmodule Spectre.Ledger do
  @moduledoc """
  Facade and independent verifier for an ordered Domain ledger.

  A logical append is a non-empty atomic batch. Callers supply both an
  `expected_revision` CAS fence and a stable `batch_id`. Retrying the identical
  logical batch is idempotent; reusing its identity for different contents is
  rejected.

  The verifier consumes the exported entry chain directly. It does not consult
  runtime projections, cached authority, or a store-specific index.
  """

  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store

  @export_format "spectre-domain-ledger"
  @export_version 1
  @export_fields ~w(format format_version domain_ref revision head_digest entries)
  @max_identifier_bytes 1_024
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @type domain_ref :: String.t()
  @type batch_id :: String.t()
  @type snapshot :: %{
          required(:domain_ref) => domain_ref(),
          required(:revision) => non_neg_integer(),
          required(:head_digest) => Entry.digest(),
          required(:entries) => [Entry.t()],
          optional(:recovery) => map() | nil
        }
  @type batch_info :: %{
          required(:batch_id) => batch_id(),
          required(:identity_digest) => Entry.digest(),
          required(:expected_revision) => non_neg_integer(),
          required(:first_revision) => pos_integer(),
          required(:last_revision) => pos_integer(),
          required(:entry_count) => pos_integer(),
          required(:head_digest) => Entry.digest()
        }

  @doc "Returns a verified snapshot of a Domain ledger."
  @spec load(Store.config(), domain_ref(), keyword()) ::
          :not_found | {:ok, snapshot()} | {:error, term()}
  def load(store, domain_ref, opts \\ []) do
    with :ok <- validate_identifier(domain_ref, :domain_ref) do
      case Store.load(store, domain_ref, opts) do
        {:ok, snapshot} -> verify_snapshot(snapshot, domain_ref)
        :not_found -> :not_found
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Looks up the durable identity and revision range of a prior batch."
  @spec lookup_batch(Store.config(), domain_ref(), batch_id(), keyword()) ::
          :not_found | {:ok, batch_info()} | {:error, term()}
  def lookup_batch(store, domain_ref, batch_id, opts \\ []) do
    with :ok <- validate_identifier(domain_ref, :domain_ref),
         :ok <- validate_identifier(batch_id, :batch_id) do
      Store.lookup_batch(store, domain_ref, batch_id, opts)
    end
  end

  @doc "Returns the stable digest identifying a logical batch request."
  @spec batch_identity(domain_ref(), batch_id(), [map()], non_neg_integer()) ::
          {:ok, Entry.digest()} | {:error, term()}
  defdelegate batch_identity(domain_ref, batch_id, payloads, expected_revision),
    to: Entry

  @doc "Exports a verified Domain ledger as portable plain data."
  @spec export(Store.config(), domain_ref(), keyword()) ::
          :not_found | {:ok, map()} | {:error, term()}
  def export(store, domain_ref, opts \\ []) do
    with :ok <- validate_identifier(domain_ref, :domain_ref) do
      case Store.export(store, domain_ref, opts) do
        {:ok, data} ->
          verify_export(data)

        :not_found ->
          :not_found

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec verify_export(map()) :: {:ok, map()} | {:error, term()}
  defp verify_export(data) do
    with {:ok, _snapshot} <- verify(data), do: {:ok, data}
  end

  @doc "Exports a runtime snapshot without including store projections."
  @spec export_snapshot(snapshot()) :: {:ok, map()} | {:error, term()}
  def export_snapshot(snapshot) do
    with {:ok, verified} <- verify_snapshot(snapshot) do
      {:ok,
       %{
         "format" => @export_format,
         "format_version" => @export_version,
         "domain_ref" => verified.domain_ref,
         "revision" => verified.revision,
         "head_digest" => verified.head_digest,
         "entries" => Enum.map(verified.entries, &Entry.to_data/1)
       }}
    end
  end

  @doc """
  Independently verifies an exported ledger and returns its reconstructed view.

  Verification covers canonical entry digests, revision continuity, the
  previous-digest chain, Domain binding, batch contiguity, and export summary.
  """
  @spec verify(map()) :: {:ok, snapshot()} | {:error, term()}
  def verify(data) when is_map(data) and not is_struct(data) do
    with :ok <- validate_export_keys(data),
         :ok <- validate_export_header(data),
         domain_ref <- Map.get(data, "domain_ref"),
         :ok <- validate_identifier(domain_ref, :domain_ref),
         revision <- Map.get(data, "revision"),
         :ok <- validate_revision(revision),
         head_digest <- Map.get(data, "head_digest"),
         :ok <- validate_digest(head_digest),
         entries when is_list(entries) <- Map.get(data, "entries"),
         {:ok, rebuilt} <- Entry.verify_chain(entries, domain_ref: domain_ref),
         :ok <- verify_batch_topology(rebuilt.entries),
         :ok <- verify_recorded_at_order(rebuilt.entries),
         :ok <- match_export_summary(rebuilt, revision, head_digest) do
      {:ok, Map.put(rebuilt, :recovery, nil)}
    else
      nil -> {:error, :invalid_ledger_export_entries}
      false -> {:error, :invalid_ledger_export_entries}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_ledger_export_entries}
    end
  end

  def verify(_data), do: {:error, :invalid_ledger_export}

  @doc "Loads and independently verifies the export produced by a store."
  @spec verify_store(Store.config(), domain_ref(), keyword()) ::
          :not_found | {:ok, snapshot()} | {:error, term()}
  def verify_store(store, domain_ref, opts \\ []) do
    case export(store, domain_ref, opts) do
      {:ok, data} -> verify(data)
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec verify_snapshot(map(), domain_ref() | nil) :: {:ok, snapshot()} | {:error, term()}
  def verify_snapshot(snapshot, expected_domain \\ nil)

  def verify_snapshot(snapshot, expected_domain)
      when is_map(snapshot) and not is_struct(snapshot) do
    domain_ref = Map.get(snapshot, :domain_ref)
    revision = Map.get(snapshot, :revision)
    head_digest = Map.get(snapshot, :head_digest)
    entries = Map.get(snapshot, :entries)
    recovery = Map.get(snapshot, :recovery)

    with :ok <- validate_identifier(domain_ref, :domain_ref),
         :ok <- match_expected_domain(domain_ref, expected_domain),
         :ok <- validate_revision(revision),
         :ok <- validate_digest(head_digest),
         true <- is_list(entries),
         {:ok, rebuilt} <- Entry.verify_chain(entries, domain_ref: domain_ref),
         :ok <- verify_batch_topology(rebuilt.entries),
         :ok <- verify_recorded_at_order(rebuilt.entries),
         :ok <- match_export_summary(rebuilt, revision, head_digest),
         :ok <- validate_recovery(recovery) do
      {:ok, Map.put(rebuilt, :recovery, recovery)}
    else
      false -> {:error, :invalid_ledger_snapshot_entries}
      {:error, _reason} = error -> error
    end
  end

  def verify_snapshot(_snapshot, _expected_domain), do: {:error, :invalid_ledger_snapshot}

  @spec verify_batch_topology([Entry.t()]) :: :ok | {:error, term()}
  defp verify_batch_topology(entries) do
    entries
    |> Enum.reduce_while({:ok, MapSet.new(), nil}, fn entry, {:ok, seen, active} ->
      case next_batch(entry, seen, active) do
        {:ok, seen, active} -> {:cont, {:ok, seen, active}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen, nil} -> :ok
      {:ok, _seen, active} -> {:error, {:incomplete_ledger_batch, active.batch_id}}
      {:error, _reason} = error -> error
    end
  end

  @spec next_batch(Entry.t(), MapSet.t(String.t()), map() | nil) ::
          {:ok, MapSet.t(String.t()), map() | nil} | {:error, term()}
  defp next_batch(%Entry{batch_index: 0} = entry, seen, nil) do
    if MapSet.member?(seen, entry.batch_id) do
      {:error, {:duplicate_ledger_batch, entry.batch_id}}
    else
      seen = MapSet.put(seen, entry.batch_id)

      active = %{
        batch_id: entry.batch_id,
        size: entry.batch_size,
        next_index: 1,
        recorded_at: entry.recorded_at
      }

      {:ok, seen, finish_batch(active)}
    end
  end

  defp next_batch(%Entry{} = entry, seen, %{batch_id: batch_id} = active) do
    cond do
      entry.batch_id != batch_id ->
        {:error, {:interleaved_ledger_batch, batch_id, entry.batch_id}}

      entry.batch_size != active.size ->
        {:error, {:ledger_batch_size_mismatch, batch_id}}

      entry.recorded_at != active.recorded_at ->
        {:error, {:ledger_batch_recorded_at_mismatch, batch_id}}

      entry.batch_index != active.next_index ->
        {:error, {:ledger_batch_index_mismatch, batch_id, active.next_index}}

      true ->
        {:ok, seen, finish_batch(%{active | next_index: active.next_index + 1})}
    end
  end

  defp next_batch(%Entry{} = entry, _seen, nil),
    do: {:error, {:ledger_batch_missing_start, entry.batch_id}}

  @spec finish_batch(map()) :: map() | nil
  defp finish_batch(%{size: size, next_index: size}), do: nil
  defp finish_batch(active), do: active

  defp verify_recorded_at_order(entries) do
    Enum.reduce_while(entries, nil, fn entry, previous ->
      if is_nil(previous) or entry.recorded_at >= previous do
        {:cont, entry.recorded_at}
      else
        {:halt,
         {:error, {:ledger_recorded_at_regressed, entry.revision, previous, entry.recorded_at}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _latest -> :ok
    end
  end

  @spec validate_export_keys(map()) :: :ok | {:error, term()}
  defp validate_export_keys(data) do
    case Map.keys(data) -- @export_fields do
      [] ->
        missing = @export_fields -- Map.keys(data)

        if missing == [],
          do: :ok,
          else: {:error, {:missing_ledger_export_field, List.first(missing)}}

      unknown ->
        {:error, {:unknown_ledger_export_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec validate_export_header(map()) :: :ok | {:error, term()}
  defp validate_export_header(%{
         "format" => @export_format,
         "format_version" => @export_version
       }),
       do: :ok

  defp validate_export_header(%{"format" => format, "format_version" => version}),
    do: {:error, {:unsupported_ledger_export, format, version}}

  @spec match_export_summary(map(), term(), term()) :: :ok | {:error, term()}
  defp match_export_summary(rebuilt, revision, head_digest) do
    cond do
      rebuilt.revision != revision ->
        {:error, {:ledger_export_revision_mismatch, revision, rebuilt.revision}}

      rebuilt.head_digest != head_digest ->
        {:error, :ledger_export_head_mismatch}

      true ->
        :ok
    end
  end

  @spec match_expected_domain(domain_ref(), domain_ref() | nil) :: :ok | {:error, term()}
  defp match_expected_domain(_domain_ref, nil), do: :ok
  defp match_expected_domain(domain_ref, domain_ref), do: :ok
  defp match_expected_domain(_domain_ref, _expected), do: {:error, :ledger_domain_mismatch}

  @spec validate_identifier(term(), atom()) :: :ok | {:error, term()}
  defp validate_identifier(value, _field)
       when is_binary(value) and value != "" and byte_size(value) <= @max_identifier_bytes,
       do: :ok

  defp validate_identifier(_value, field), do: {:error, {:invalid_ledger_identifier, field}}

  @spec validate_revision(term()) :: :ok | {:error, term()}
  defp validate_revision(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_revision(_value), do: {:error, :invalid_ledger_revision}

  @spec validate_digest(term()) :: :ok | {:error, term()}
  defp validate_digest(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_ledger_digest}
  end

  defp validate_digest(_value), do: {:error, :invalid_ledger_digest}

  @spec validate_recovery(term()) :: :ok | {:error, term()}
  defp validate_recovery(nil), do: :ok
  defp validate_recovery(value) when is_map(value) and not is_struct(value), do: :ok
  defp validate_recovery(_value), do: {:error, :invalid_ledger_recovery_metadata}
end
