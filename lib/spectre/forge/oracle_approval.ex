defmodule Spectre.Forge.OracleApproval do
  @moduledoc """
  Independent host approval binding one proposed evaluation case to an oracle.

  Approval is evidence, not activation authority. It cannot select an
  evaluator implementation; `oracle_ref` must resolve through a host registry.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Experience.Redactor
  alias Spectre.Governance.Data

  @schema_version 1
  @fields [
    :schema_version,
    :case_digest,
    :oracle_ref,
    :approver_ref,
    :approved_at,
    :provenance,
    :digest
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            case_digest: nil,
            oracle_ref: nil,
            approver_ref: nil,
            approved_at: nil,
            provenance: %{},
            digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          case_digest: String.t(),
          oracle_ref: String.t(),
          approver_ref: String.t(),
          approved_at: non_neg_integer(),
          provenance: map(),
          digest: String.t()
        }

  @doc "Returns the oracle-approval transport schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds a content-bound oracle approval."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = approval), do: approval |> to_data() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_forge_oracle_approval, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         @schema_version <- value(attrs, :schema_version, @schema_version),
         :ok <- digest(value(attrs, :case_digest), :case_digest),
         {:ok, oracle_ref} <- ref(value(attrs, :oracle_ref), :oracle_ref),
         {:ok, approver_ref} <- ref(value(attrs, :approver_ref), :approver_ref),
         {:ok, approved_at} <- non_negative(value(attrs, :approved_at), :approved_at),
         {:ok, provenance} <- portable_map(value(attrs, :provenance, %{})),
         :ok <- reject_sensitive(provenance),
         base = %{
           schema_version: @schema_version,
           case_digest: value(attrs, :case_digest),
           oracle_ref: oracle_ref,
           approver_ref: approver_ref,
           approved_at: approved_at,
           provenance: provenance
         },
         expected = content_digest(base),
         :ok <- supplied_digest(value(attrs, :digest), expected) do
      {:ok, struct!(__MODULE__, Map.put(base, :digest, expected))}
    else
      version when is_integer(version) ->
        {:error, {:unsupported_forge_oracle_approval_schema, version}}

      {:error, _reason} = error ->
        error

      value ->
        {:error, {:invalid_forge_oracle_approval, shape(value)}}
    end
  end

  def new(value), do: {:error, {:invalid_forge_oracle_approval, shape(value)}}

  @doc "Builds an approval or raises with its stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, approval} -> approval
      {:error, reason} -> raise ArgumentError, "invalid Forge oracle approval: #{inspect(reason)}"
    end
  end

  @doc "Returns JSON-shaped approval data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = approval) do
    %{
      "schema_version" => approval.schema_version,
      "case_digest" => approval.case_digest,
      "oracle_ref" => approval.oracle_ref,
      "approver_ref" => approval.approver_ref,
      "approved_at" => approval.approved_at,
      "provenance" => approval.provenance,
      "digest" => approval.digest
    }
  end

  @doc "Restores an approval from decoded transport data."
  def from_data(data), do: new(data)

  @doc "Returns the stable approval reference."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{digest: digest}), do: "oracle-approval:sha256:" <> digest

  @doc "Checks whether this approval binds the supplied case and oracle."
  @spec approves?(t(), String.t(), String.t()) :: boolean()
  def approves?(%__MODULE__{} = approval, case_digest, oracle_ref),
    do: approval.case_digest == case_digest and approval.oracle_ref == oracle_ref

  @doc "Revalidates the complete approval."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = approval) do
    case approval |> to_data() |> from_data() do
      {:ok, ^approval} -> :ok
      {:ok, _other} -> {:error, :forge_oracle_approval_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp content_digest(base) do
    base
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Value.digest!()
  end

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- aliases, collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_forge_oracle_approval_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_forge_oracle_approval_fields, collisions}}
    end
  end

  defp ref(value, _field) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, :forge_code_reference_forbidden},
      else: {:ok, value}
  end

  defp ref(value, field), do: {:error, {:invalid_forge_oracle_approval_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative(value, field),
    do: {:error, {:invalid_forge_oracle_approval_field, field, value}}

  defp portable_map(value) when is_map(value) and not is_struct(value) do
    case Data.normalize_map(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:nonportable_forge_oracle_provenance, reason}}
    end
  end

  defp portable_map(value), do: {:error, {:invalid_forge_oracle_provenance, shape(value)}}

  defp reject_sensitive(value), do: reject_sensitive(value, [])

  defp reject_sensitive(value, path) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      case reject_sensitive_entry(key, item, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case reject_sensitive(item, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive(_value, _path), do: :ok

  defp reject_sensitive_entry(key, item, path) do
    if Redactor.sensitive_key?(key) and item != "[REDACTED]",
      do: {:error, {:sensitive_forge_provenance, Enum.reverse([key | path])}},
      else: reject_sensitive(item, [key | path])
  end

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    if match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower)),
      do: :ok,
      else: {:error, {:invalid_forge_oracle_digest, value}}
  end

  defp digest(value, field), do: {:error, {:invalid_forge_oracle_digest, field, value}}

  defp supplied_digest(nil, _expected), do: :ok
  defp supplied_digest(expected, expected), do: :ok
  defp supplied_digest(_supplied, _expected), do: {:error, :forge_oracle_approval_digest_mismatch}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
