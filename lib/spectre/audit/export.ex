defmodule Spectre.Audit.Export do
  @moduledoc """
  Self-contained, canonical input for an independent semantic audit.

  An export contains only the portable Domain ledger, the exact Constitution
  whose digest is pinned by Genesis, and the trusted Domain time at which the
  export was captured. It contains no projection, Grant, credential, process
  identifier or store configuration.
  """

  require Spectre.Portable

  alias Spectre.Audit
  alias Spectre.Canonical.Value
  alias Spectre.Constitution
  alias Spectre.Genesis
  alias Spectre.Ledger
  alias Spectre.Portable

  @format "spectre-semantic-audit-input"
  @format_version 1
  @fields ~w(format format_version exported_at constitution ledger)

  @type t :: %{
          required(String.t()) => term()
        }

  @doc "Builds and validates a self-contained audit export."
  @spec new(map(), map(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def new(ledger, constitution, exported_at)
      when Portable.is_plain_map(ledger) and is_map(constitution) and
             not is_struct(constitution) and Portable.is_non_negative_integer(exported_at) do
    with {:ok, snapshot} <- Ledger.verify(ledger),
         :ok <- Constitution.validate(constitution),
         {:ok, constitution_ref} <- Constitution.ref(constitution),
         {:ok, genesis} <- genesis(snapshot),
         true <- genesis.constitution_ref == constitution_ref,
         :ok <- exported_at_covers(snapshot, exported_at) do
      data = %{
        "format" => @format,
        "format_version" => @format_version,
        "exported_at" => exported_at,
        "constitution" => constitution,
        "ledger" => ledger
      }

      # Entries and Constitution were validated individually above. The export
      # is an aggregate, not a single record: its byte budget belongs to the
      # caller of encode/decode, not Portable's per-record default.
      {:ok, data}
    else
      false -> {:error, :audit_export_constitution_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def new(_ledger, _constitution, _exported_at), do: {:error, :invalid_audit_export_input}

  @doc "Validates an already decoded audit export."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when Portable.is_plain_map(data) do
    with :ok <- exact_keys(data),
         @format <- Map.get(data, "format"),
         @format_version <- Map.get(data, "format_version"),
         {:ok, normalized} <-
           new(
             Map.get(data, "ledger"),
             Map.get(data, "constitution"),
             Map.get(data, "exported_at")
           ),
         true <- normalized == data do
      {:ok, normalized}
    else
      nil -> {:error, :invalid_audit_export_header}
      false -> {:error, :noncanonical_audit_export}
      format when is_binary(format) -> {:error, {:unsupported_audit_export_format, format}}
      version when is_integer(version) -> {:error, {:unsupported_audit_export_version, version}}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_audit_export_header}
    end
  end

  def from_data(_data), do: {:error, :invalid_audit_export}

  @doc "Encodes an audit export with the deterministic Spectre value codec."
  @spec encode(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(data, opts \\ []) do
    with {:ok, data} <- from_data(data), do: Value.encode(data, opts)
  end

  @doc "Decodes and validates a canonical audit export without creating atoms."
  @spec decode(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(encoded, opts \\ []) do
    with {:ok, data} <- Value.decode(encoded, opts), do: from_data(data)
  end

  @doc "Runs the independent semantic auditor over an export."
  @spec verify(t() | binary(), non_neg_integer() | nil, keyword()) ::
          {:ok, Audit.report()} | {:error, term()}
  def verify(export, audited_at \\ nil, codec_opts \\ [])

  def verify(encoded, audited_at, codec_opts) when is_binary(encoded) do
    with {:ok, export} <- decode(encoded, codec_opts), do: verify(export, audited_at, codec_opts)
  end

  def verify(export, audited_at, _codec_opts) when is_map(export) do
    with {:ok, export} <- from_data(export),
         {:ok, audited_at} <- audit_time(export, audited_at) do
      Audit.verify(export["ledger"], export["constitution"], audited_at)
    end
  end

  def verify(_export, _audited_at, _codec_opts), do: {:error, :invalid_audit_export}

  defp exact_keys(data) do
    keys = Map.keys(data)
    unknown = keys -- @fields
    missing = @fields -- keys

    cond do
      unknown != [] -> {:error, {:unknown_audit_export_fields, Enum.sort(unknown)}}
      missing != [] -> {:error, {:missing_audit_export_field, List.first(missing)}}
      true -> :ok
    end
  end

  defp genesis(%{entries: entries}) do
    records =
      Enum.flat_map(entries, fn entry ->
        case entry.payload do
          %{"type" => "genesis_recorded", "data" => data} -> [data]
          _other -> []
        end
      end)

    case records do
      [data] -> Genesis.from_canonical(data)
      [] -> {:error, :audit_export_genesis_missing}
      _many -> {:error, :audit_export_genesis_ambiguous}
    end
  end

  defp exported_at_covers(%{entries: []}, _exported_at), do: :ok

  defp exported_at_covers(%{entries: entries}, exported_at) do
    latest = entries |> List.last() |> Map.fetch!(:recorded_at)

    if exported_at >= latest,
      do: :ok,
      else: {:error, {:audit_export_time_precedes_ledger, exported_at, latest}}
  end

  defp audit_time(export, nil), do: {:ok, export["exported_at"]}

  defp audit_time(_export, value) when Portable.is_non_negative_integer(value),
    do: {:ok, value}

  defp audit_time(_export, value), do: {:error, {:invalid_audit_time, value}}
end
