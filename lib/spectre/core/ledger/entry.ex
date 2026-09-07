defmodule Spectre.Ledger.Entry do
  @moduledoc """
  One immutable record in a Domain ledger.

  Entries are numbered from one and form a SHA-256 chain. The digest covers
  the Domain, revision, batch coordinates, trusted recording time, previous
  digest, and payload. The
  payload must be a plain portable map; executable values and structs are
  rejected by `Spectre.Canonical.Value`.

  `Entry` structs are an in-memory convenience only. The durable form returned
  by `to_data/1` is a plain map with string keys.
  """

  require Spectre.Portable

  alias Spectre.Canonical.Value
  alias Spectre.Portable

  @schema_version 1
  @genesis_digest String.duplicate("0", 64)
  @max_identifier_bytes 1_024
  @max_payload_bytes 16 * 1_024 * 1_024
  @max_batch_bytes 64 * 1_024 * 1_024
  @max_batch_entries 10_000
  @fields [
    :schema_version,
    :domain_ref,
    :revision,
    :batch_id,
    :batch_index,
    :batch_size,
    :recorded_at,
    :prev_digest,
    :payload,
    :digest
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            domain_ref: nil,
            revision: nil,
            batch_id: nil,
            batch_index: nil,
            batch_size: nil,
            recorded_at: nil,
            prev_digest: nil,
            payload: nil,
            digest: nil

  @type digest :: <<_::512>>
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          domain_ref: String.t(),
          revision: pos_integer(),
          batch_id: String.t(),
          batch_index: non_neg_integer(),
          batch_size: pos_integer(),
          recorded_at: non_neg_integer(),
          prev_digest: digest(),
          payload: map(),
          digest: digest()
        }

  @doc "Returns the durable Entry schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the fixed predecessor digest used by revision one."
  @spec genesis_digest() :: digest()
  def genesis_digest, do: @genesis_digest

  @doc "Returns the maximum number of entries accepted in one atomic batch."
  @spec max_batch_entries() :: pos_integer()
  def max_batch_entries, do: @max_batch_entries

  @doc false
  @spec valid_identifier?(term()) :: boolean()
  def valid_identifier?(value),
    do: Portable.is_non_empty_binary(value) and byte_size(value) <= @max_identifier_bytes

  @doc "Builds and validates an Entry from its complete durable fields."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = entry), do: entry |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, :invalid_ledger_entry_attributes}
  end

  def new(attrs) when Portable.is_plain_map(attrs) do
    with :ok <- validate_keys(attrs),
         {:ok, values} <- normalize_fields(attrs),
         :ok <- validate_fields(values),
         entry <- struct!(__MODULE__, values),
         :ok <- verify(entry) do
      {:ok, entry}
    end
  end

  def new(_value), do: {:error, :invalid_ledger_entry}

  @doc "Builds a new Entry and computes its canonical digest."
  @spec build(
          String.t(),
          pos_integer(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          digest(),
          map()
        ) :: {:ok, t()} | {:error, term()}
  def build(
        domain_ref,
        revision,
        batch_id,
        batch_index,
        batch_size,
        recorded_at,
        prev_digest,
        payload
      ) do
    values = %{
      schema_version: @schema_version,
      domain_ref: domain_ref,
      revision: revision,
      batch_id: batch_id,
      batch_index: batch_index,
      batch_size: batch_size,
      recorded_at: recorded_at,
      prev_digest: prev_digest,
      payload: payload
    }

    with :ok <- validate_unsigned_fields(values),
         {:ok, digest} <- digest_unsigned(values) do
      new(Map.put(values, :digest, digest))
    end
  end

  @doc "Builds a complete linked batch after validating its portable payloads."
  @spec build_batch(
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          digest()
        ) :: {:ok, [t()]} | {:error, term()}
  def build_batch(domain_ref, batch_id, payloads, expected_revision, recorded_at, prev_digest) do
    with {:ok, _identity} <- batch_identity(domain_ref, batch_id, payloads, expected_revision),
         :ok <- validate_non_negative(recorded_at, :recorded_at),
         :ok <- validate_digest(prev_digest, :prev_digest) do
      build_batch_entries(
        payloads,
        {domain_ref, batch_id, length(payloads), recorded_at},
        expected_revision,
        0,
        prev_digest,
        []
      )
    end
  end

  @spec build_batch_entries(
          [map()],
          {String.t(), String.t(), pos_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer(),
          digest(),
          [t()]
        ) :: {:ok, [t()]} | {:error, term()}
  defp build_batch_entries(
         [],
         _batch_context,
         _revision,
         _index,
         _previous,
         entries
       ),
       do: {:ok, Enum.reverse(entries)}

  defp build_batch_entries(
         [payload | rest],
         {domain_ref, batch_id, batch_size, recorded_at} = batch_context,
         expected_revision,
         index,
         previous,
         entries
       ) do
    revision = expected_revision + index + 1

    with {:ok, entry} <-
           build(
             domain_ref,
             revision,
             batch_id,
             index,
             batch_size,
             recorded_at,
             previous,
             payload
           ) do
      build_batch_entries(
        rest,
        batch_context,
        expected_revision,
        index + 1,
        entry.digest,
        [entry | entries]
      )
    end
  end

  @doc "Computes the stable identity of a logical batch request."
  @spec batch_identity(String.t(), String.t(), [map()], non_neg_integer()) ::
          {:ok, digest()} | {:error, term()}
  def batch_identity(domain_ref, batch_id, payloads, expected_revision) do
    with :ok <- validate_identifier(domain_ref, :domain_ref),
         :ok <- validate_identifier(batch_id, :batch_id),
         :ok <- validate_expected_revision(expected_revision),
         :ok <- validate_payloads(payloads) do
      Value.digest(
        %{
          "format" => "spectre-ledger-batch-identity",
          "format_version" => 1,
          "domain_ref" => domain_ref,
          "batch_id" => batch_id,
          "expected_revision" => expected_revision,
          "payloads" => payloads
        },
        max_bytes: @max_batch_bytes
      )
    end
  end

  @doc "Verifies that an Entry digest exactly matches its durable contents."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = entry) do
    values = Map.from_struct(entry)

    with :ok <- validate_fields(values),
         {:ok, expected} <- digest_unsigned(Map.delete(values, :digest)) do
      if entry.digest == expected,
        do: :ok,
        else: {:error, {:ledger_entry_digest_mismatch, entry.revision}}
    end
  end

  def verify(_value), do: {:error, :invalid_ledger_entry}

  @doc "Verifies a contiguous chain without consulting a projection or store."
  @spec verify_chain([t() | map()], keyword()) :: {:ok, map()} | {:error, term()}
  def verify_chain(entries, opts \\ [])

  def verify_chain(entries, opts) when is_list(entries) and is_list(opts) do
    start_revision = Keyword.get(opts, :start_revision, 0)
    previous_digest = Keyword.get(opts, :prev_digest, @genesis_digest)
    expected_domain = Keyword.get(opts, :domain_ref)

    with :ok <- validate_expected_revision(start_revision),
         :ok <- validate_digest(previous_digest, :prev_digest),
         :ok <- optional_identifier(expected_domain, :domain_ref) do
      verify_chain_entries(
        entries,
        start_revision,
        previous_digest,
        expected_domain,
        []
      )
    end
  end

  def verify_chain(_entries, _opts), do: {:error, :invalid_ledger_entries}

  @spec verify_chain_entries(
          [t() | map()],
          non_neg_integer(),
          digest(),
          String.t() | nil,
          [t()]
        ) :: {:ok, map()} | {:error, term()}
  defp verify_chain_entries([], revision, head_digest, domain_ref, verified) do
    {:ok,
     %{
       domain_ref: domain_ref,
       revision: revision,
       head_digest: head_digest,
       entries: Enum.reverse(verified)
     }}
  end

  defp verify_chain_entries([raw | rest], revision, previous, domain_ref, verified) do
    with {:ok, entry} <- normalize_entry(raw),
         :ok <- verify(entry),
         :ok <- chain_position(entry, domain_ref, revision + 1, previous) do
      verify_chain_entries(
        rest,
        entry.revision,
        entry.digest,
        domain_ref || entry.domain_ref,
        [entry | verified]
      )
    end
  end

  defp verify_chain_entries(_invalid, _revision, _previous, _domain_ref, _verified),
    do: {:error, :invalid_ledger_entries}

  @doc "Returns the plain-map durable representation of an Entry."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = entry) do
    %{
      "schema_version" => entry.schema_version,
      "domain_ref" => entry.domain_ref,
      "revision" => entry.revision,
      "batch_id" => entry.batch_id,
      "batch_index" => entry.batch_index,
      "batch_size" => entry.batch_size,
      "recorded_at" => entry.recorded_at,
      "prev_digest" => entry.prev_digest,
      "payload" => entry.payload,
      "digest" => entry.digest
    }
  end

  @doc "Restores and verifies an Entry from its plain-map durable form."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when Portable.is_plain_map(data) do
    with {:ok, entry} <- new(data),
         true <- to_data(entry) == data do
      {:ok, entry}
    else
      false -> {:error, :noncanonical_ledger_entry}
      {:error, _reason} = error -> error
    end
  end

  def from_data(_data), do: {:error, :invalid_ledger_entry_data}

  @doc "Encodes an Entry with the canonical value codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = entry), do: entry |> to_data() |> Value.encode()

  @doc "Decodes and verifies canonical Entry bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(_value), do: {:error, :invalid_ledger_entry_encoding}

  @spec normalize_entry(t() | map()) :: {:ok, t()} | {:error, term()}
  defp normalize_entry(%__MODULE__{} = entry), do: {:ok, entry}
  defp normalize_entry(data) when is_map(data), do: from_data(data)
  defp normalize_entry(_value), do: {:error, :invalid_ledger_entry}

  @spec digest_unsigned(map()) :: {:ok, digest()} | {:error, term()}
  defp digest_unsigned(values) do
    values
    |> unsigned_data()
    |> Value.digest(max_bytes: @max_payload_bytes + 16_384)
  end

  @spec unsigned_data(map()) :: map()
  defp unsigned_data(values) do
    %{
      "schema_version" => Map.fetch!(values, :schema_version),
      "domain_ref" => Map.fetch!(values, :domain_ref),
      "revision" => Map.fetch!(values, :revision),
      "batch_id" => Map.fetch!(values, :batch_id),
      "batch_index" => Map.fetch!(values, :batch_index),
      "batch_size" => Map.fetch!(values, :batch_size),
      "recorded_at" => Map.fetch!(values, :recorded_at),
      "prev_digest" => Map.fetch!(values, :prev_digest),
      "payload" => Map.fetch!(values, :payload)
    }
  end

  @spec validate_fields(map()) :: :ok | {:error, term()}
  defp validate_fields(values) do
    with :ok <- validate_unsigned_fields(values) do
      validate_digest(Map.get(values, :digest), :digest)
    end
  end

  @spec validate_unsigned_fields(map()) :: :ok | {:error, term()}
  defp validate_unsigned_fields(values) do
    with :ok <- validate_schema(Map.get(values, :schema_version)),
         :ok <- validate_identifier(Map.get(values, :domain_ref), :domain_ref),
         :ok <- validate_positive(Map.get(values, :revision), :revision),
         :ok <- validate_identifier(Map.get(values, :batch_id), :batch_id),
         :ok <- validate_batch_coordinates(values),
         :ok <- validate_non_negative(Map.get(values, :recorded_at), :recorded_at),
         :ok <- validate_digest(Map.get(values, :prev_digest), :prev_digest) do
      validate_payload(Map.get(values, :payload))
    end
  end

  @spec validate_schema(term()) :: :ok | {:error, term()}
  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(value), do: {:error, {:unsupported_ledger_entry_schema, value}}

  @spec validate_identifier(term(), atom()) :: :ok | {:error, term()}
  defp validate_identifier(value, field) do
    if valid_identifier?(value),
      do: :ok,
      else: {:error, {:invalid_ledger_entry_field, field}}
  end

  @spec optional_identifier(term(), atom()) :: :ok | {:error, term()}
  defp optional_identifier(nil, _field), do: :ok
  defp optional_identifier(value, field), do: validate_identifier(value, field)

  @spec validate_positive(term(), atom()) :: :ok | {:error, term()}
  defp validate_positive(value, _field) when Portable.is_positive_integer(value), do: :ok
  defp validate_positive(_value, field), do: {:error, {:invalid_ledger_entry_field, field}}

  @spec validate_non_negative(term(), atom()) :: :ok | {:error, term()}
  defp validate_non_negative(value, _field) when Portable.is_non_negative_integer(value), do: :ok

  defp validate_non_negative(_value, field),
    do: {:error, {:invalid_ledger_entry_field, field}}

  @spec validate_expected_revision(term()) :: :ok | {:error, term()}
  defp validate_expected_revision(value) when Portable.is_non_negative_integer(value), do: :ok
  defp validate_expected_revision(_value), do: {:error, :invalid_expected_revision}

  @spec validate_batch_coordinates(map()) :: :ok | {:error, term()}
  defp validate_batch_coordinates(values) do
    index = Map.get(values, :batch_index)
    size = Map.get(values, :batch_size)

    if Portable.is_non_negative_integer(index) and Portable.is_positive_integer(size) and
         index < size,
       do: :ok,
       else: {:error, :invalid_ledger_entry_batch_coordinates}
  end

  @spec validate_digest(term(), atom()) :: :ok | {:error, term()}
  defp validate_digest(value, _field)
       when is_binary(value) and byte_size(value) == 64 do
    if Portable.sha256_digest?(value),
      do: :ok,
      else: {:error, :invalid_ledger_entry_digest}
  end

  defp validate_digest(_value, field), do: {:error, {:invalid_ledger_entry_field, field}}

  @spec validate_payload(term()) :: :ok | {:error, term()}
  defp validate_payload(payload) when Portable.is_plain_map(payload) do
    case Value.validate(payload, max_bytes: @max_payload_bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_ledger_payload, reason}}
    end
  end

  defp validate_payload(_payload), do: {:error, :ledger_payload_must_be_a_plain_map}

  @spec validate_payloads(term()) :: :ok | {:error, term()}
  defp validate_payloads(payloads)
       when is_list(payloads) and payloads != [] and length(payloads) <= @max_batch_entries do
    payloads
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {payload, index}, :ok ->
      case validate_payload(payload) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_ledger_batch_payload, index, reason}}}
      end
    end)
  end

  defp validate_payloads([]), do: {:error, :empty_ledger_batch}

  defp validate_payloads(payloads) when is_list(payloads),
    do: {:error, {:ledger_batch_too_large, length(payloads), @max_batch_entries}}

  defp validate_payloads(_payloads), do: {:error, :invalid_ledger_batch_payloads}

  @spec chain_position(t(), String.t() | nil, pos_integer(), digest()) ::
          :ok | {:error, term()}
  defp chain_position(entry, domain_ref, expected_revision, previous_digest) do
    cond do
      not is_nil(domain_ref) and entry.domain_ref != domain_ref ->
        {:error, {:ledger_domain_mismatch, expected_revision}}

      entry.revision != expected_revision ->
        {:error, {:ledger_revision_gap, expected_revision, entry.revision}}

      entry.prev_digest != previous_digest ->
        {:error, {:ledger_chain_mismatch, entry.revision}}

      true ->
        :ok
    end
  end

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = @fields ++ Enum.map(@fields, &Atom.to_string/1)
    unknown = Map.keys(attrs) -- allowed

    collisions =
      Enum.filter(@fields, fn field ->
        Map.has_key?(attrs, field) and Map.has_key?(attrs, Atom.to_string(field))
      end)

    cond do
      unknown != [] ->
        {:error, {:unknown_ledger_entry_fields, Enum.sort_by(unknown, &inspect/1)}}

      collisions != [] ->
        {:error, {:ambiguous_ledger_entry_fields, collisions}}

      true ->
        :ok
    end
  end

  @spec normalize_fields(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_fields(attrs) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn field, {:ok, values} ->
      case fetch(attrs, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, field, value)}}
        :error -> {:halt, {:error, {:missing_ledger_entry_field, field}}}
      end
    end)
  end

  @spec fetch(map(), atom()) :: {:ok, term()} | :error
  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end

  @spec unique_keyword?(keyword()) :: boolean()
  defp unique_keyword?(attrs) do
    keys = Keyword.keys(attrs)
    length(keys) == length(Enum.uniq(keys))
  end
end
