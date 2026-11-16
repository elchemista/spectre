defmodule Spectre.GAM.Ledger.Store.Disk.Frame do
  @moduledoc false

  # A disk frame is a storage envelope, not GAM authority. These pure checks
  # preserve the canonical bytes, closed grammar and batch chain. The Disk
  # owner checks continuity against its prefix; FileIO establishes durability.
  alias Spectre.GAM.Canonical.Value
  alias Spectre.GAM.Ledger
  alias Spectre.GAM.Ledger.Entry
  alias Spectre.GAM.Ledger.Store.{Compression, Support}

  @frame_magic "SPDL"
  @frame_version 1
  @frame_header_size 4 + 1 + 8 + 32
  @frame_format "spectre-ledger-batch-frame"
  @frame_fields ~w(format format_version domain_ref batch_id identity_digest expected_revision entries)

  @doc "Returns the fixed frame-header size used for streaming and indexed reads."
  @spec header_size() :: pos_integer()
  def header_size, do: @frame_header_size

  @doc "Encodes one bounded canonical batch frame; the returned bytes are not durable."
  @spec encode(
          String.t(),
          String.t(),
          Entry.digest(),
          non_neg_integer(),
          [Entry.t()],
          pos_integer(),
          boolean()
        ) :: {:ok, binary()} | {:error, term()}
  def encode(
        domain_ref,
        batch_id,
        identity,
        expected_revision,
        entries,
        max_frame_bytes,
        compressed
      ) do
    data = %{
      "format" => @frame_format,
      "format_version" => @frame_version,
      "domain_ref" => domain_ref,
      "batch_id" => batch_id,
      "identity_digest" => identity,
      "expected_revision" => expected_revision,
      "entries" => Enum.map(entries, &Entry.to_data/1)
    }

    case Value.encode(data, max_bytes: max_frame_bytes) do
      {:ok, encoded} ->
        encoded = Compression.pack(encoded, compressed)
        checksum = :crypto.hash(:sha256, encoded)

        {:ok,
         <<@frame_magic, @frame_version, byte_size(encoded)::unsigned-big-64,
           checksum::binary-size(32), encoded::binary>>}

      {:error, {:canonical_value_too_large, size, _limit}} ->
        {:error, {:ledger_frame_too_large, size, max_frame_bytes}}

      {:error, reason} ->
        {:error, {:invalid_ledger_frame, reason}}
    end
  end

  @doc "Checks the fixed header and length bound before reading or allocating the frame body."
  @spec header(binary(), non_neg_integer(), pos_integer()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  def header(
        <<@frame_magic, @frame_version, length::unsigned-big-64, checksum::binary-size(32)>>,
        offset,
        max_frame_bytes
      ) do
    cond do
      length == 0 -> {:error, {:invalid_ledger_frame_length, offset, length}}
      length > max_frame_bytes -> {:error, {:ledger_frame_too_large, offset, length}}
      true -> {:ok, length, checksum}
    end
  end

  def header(<<@frame_magic, version, _rest::binary>>, offset, _max),
    do: {:error, {:unsupported_ledger_frame_version, offset, version}}

  def header(_header, offset, _max),
    do: {:error, {:invalid_ledger_frame_header, offset}}

  @doc "Verifies and decodes one body, including checksum, expansion limit and exact Domain envelope."
  @spec decode_payload(binary(), binary(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def decode_payload(encoded, checksum, domain_ref, offset, max_frame_bytes) do
    with :ok <- verify_checksum(encoded, checksum, offset),
         {:ok, data} <- decode_frame_data(encoded, max_frame_bytes, offset),
         :ok <- validate_frame_keys(data, offset),
         :ok <- validate_frame_header(data, domain_ref, offset) do
      {:ok, data}
    end
  end

  @spec verify_checksum(binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp verify_checksum(encoded, checksum, offset) do
    if :crypto.hash(:sha256, encoded) == checksum,
      do: :ok,
      else: {:error, {:ledger_frame_checksum_mismatch, offset}}
  end

  @spec decode_frame_data(binary(), pos_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp decode_frame_data(encoded, max_frame_bytes, offset) do
    result =
      with {:ok, bytes} <- Compression.unpack(encoded, max_frame_bytes),
           do: Value.decode(bytes, max_bytes: max_frame_bytes)

    case result do
      {:ok, data} when is_map(data) and not is_struct(data) -> {:ok, data}
      {:ok, _value} -> {:error, {:invalid_ledger_frame_payload, offset}}
      {:error, reason} -> {:error, {:invalid_ledger_frame_encoding, offset, reason}}
    end
  end

  @doc "Checks the batch chain and identity after decode_payload/5 has validated its envelope."
  @spec decode_batch(map(), String.t(), non_neg_integer()) ::
          {:ok, Ledger.batch_info(), [Entry.t()]} | {:error, term()}
  def decode_batch(data, domain_ref, offset) do
    with batch_id when is_binary(batch_id) and batch_id != "" <- Map.get(data, "batch_id"),
         identity when is_binary(identity) <- Map.get(data, "identity_digest"),
         true <- Support.valid_digest?(identity),
         expected_revision when is_integer(expected_revision) and expected_revision >= 0 <-
           Map.get(data, "expected_revision"),
         raw_entries when is_list(raw_entries) and raw_entries != [] <- Map.get(data, "entries"),
         [first | _] when is_map(first) <- raw_entries,
         {:ok, first} <- Entry.from_data(first),
         {:ok, verified} <-
           Entry.verify_chain(raw_entries,
             domain_ref: domain_ref,
             start_revision: expected_revision,
             prev_digest: first.prev_digest
           ),
         :ok <- Support.validate_batch_coordinates(verified.entries, domain_ref, batch_id),
         payloads <- Enum.map(verified.entries, & &1.payload),
         {:ok, expected_identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
         true <- identity == expected_identity do
      info =
        Support.batch_info(batch_id, identity, expected_revision, List.last(verified.entries))

      {:ok, info, verified.entries}
    else
      false -> {:error, {:invalid_or_duplicate_ledger_frame, offset}}
      nil -> {:error, {:invalid_ledger_frame, offset}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_ledger_frame, offset}}
    end
  end

  @spec validate_frame_keys(map(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_frame_keys(data, offset) do
    unknown = Map.keys(data) -- @frame_fields
    missing = @frame_fields -- Map.keys(data)

    cond do
      unknown != [] -> {:error, {:unknown_ledger_frame_fields, offset}}
      missing != [] -> {:error, {:missing_ledger_frame_field, offset, List.first(missing)}}
      true -> :ok
    end
  end

  @spec validate_frame_header(map(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_frame_header(
         %{
           "format" => @frame_format,
           "format_version" => @frame_version,
           "domain_ref" => domain_ref
         },
         domain_ref,
         _offset
       ),
       do: :ok

  defp validate_frame_header(_data, _domain_ref, offset),
    do: {:error, {:ledger_frame_binding_mismatch, offset}}
end
