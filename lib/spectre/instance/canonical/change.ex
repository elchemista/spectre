defmodule Spectre.Instance.Canonical.Change do
  @moduledoc false

  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Snapshot
  alias Spectre.Run.Value

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            snapshot_id: nil,
            base_revision: 0,
            section_revisions: %{},
            writes: %{},
            correlation_id: nil,
            causation_id: nil,
            provenance: %{},
            metadata: %{},
            created_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          snapshot_id: String.t(),
          base_revision: non_neg_integer(),
          section_revisions: %{required(Sections.name()) => non_neg_integer()},
          writes: %{required(Sections.name()) => term()},
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          provenance: map(),
          metadata: map(),
          created_at: integer()
        }

  @spec new(Snapshot.t(), map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(snapshot, writes, opts \\ [])

  def new(%Snapshot{} = snapshot, writes, opts) when is_list(opts) do
    with {:ok, writes} <- normalize_writes(writes),
         :ok <- ensure_writes_present(writes),
         :ok <- ensure_snapshot_writable(snapshot, writes),
         :ok <- validate_writes(writes),
         {:ok, id} <- identifier(Keyword.get(opts, :id)),
         {:ok, provenance} <- portable_map(Keyword.get(opts, :provenance, %{}), :provenance),
         {:ok, metadata} <- portable_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      names = Map.keys(writes)

      {:ok,
       %__MODULE__{
         id: id,
         snapshot_id: snapshot.id,
         base_revision: snapshot.base_revision,
         section_revisions: Map.take(snapshot.section_revisions, names),
         writes: writes,
         correlation_id: snapshot.correlation_id,
         causation_id: snapshot.causation_id,
         provenance: provenance,
         metadata: metadata,
         created_at: System.system_time(:millisecond)
       }}
    end
  end

  def new(%Snapshot{}, _writes, opts), do: {:error, {:invalid_change_options, shape(opts)}}

  @spec normalize_writes(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_writes(writes) when is_list(writes) do
    if Keyword.keyword?(writes) do
      normalize_writes(Map.new(writes))
    else
      {:error, {:invalid_canonical_writes, :list}}
    end
  end

  defp normalize_writes(writes) when is_map(writes) and not is_struct(writes) do
    Enum.reduce_while(writes, {:ok, %{}}, fn {name, value}, {:ok, normalized} ->
      if Sections.valid_name?(name) do
        {:cont, {:ok, Map.put(normalized, name, value)}}
      else
        {:halt, {:error, {:unknown_canonical_section, name}}}
      end
    end)
  end

  defp normalize_writes(writes), do: {:error, {:invalid_canonical_writes, shape(writes)}}

  @spec ensure_writes_present(map()) :: :ok | {:error, :empty_canonical_change}
  defp ensure_writes_present(writes) when map_size(writes) == 0,
    do: {:error, :empty_canonical_change}

  defp ensure_writes_present(_writes), do: :ok

  @spec ensure_snapshot_writable(Snapshot.t(), map()) :: :ok | {:error, term()}
  defp ensure_snapshot_writable(%Snapshot{} = snapshot, writes) do
    cond do
      Snapshot.read_only?(snapshot) ->
        {:error, :snapshot_read_only}

      name = Enum.find(Map.keys(writes), &(not Snapshot.writable?(snapshot, &1))) ->
        {:error, {:snapshot_section_not_writable, name}}

      true ->
        :ok
    end
  end

  @spec validate_writes(map()) :: :ok | {:error, term()}
  defp validate_writes(writes) do
    Enum.reduce_while(writes, :ok, fn {name, value}, :ok ->
      case Value.validate(value, [:canonical, :writes, name]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:nonportable_canonical_change, reason}}}
      end
    end)
  end

  @spec portable_map(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Value.validate(value, [:canonical, field]) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:nonportable_canonical_change, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_canonical_change_field, field, shape(value)}}

  @spec identifier(term()) :: {:ok, String.t()} | {:error, term()}
  defp identifier(nil), do: {:ok, Spectre.Identity.uuid7()}
  defp identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(value), do: {:error, {:invalid_canonical_change_id, shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
