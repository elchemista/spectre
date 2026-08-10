defmodule Spectre.Execution.Migration.Receipt do
  @moduledoc """
  Integrity receipt for one committed registered state migration.

  It records only content digests and contract lineage. Source and migrated
  state values remain outside the receipt.
  """

  alias Spectre.Canonical.Value

  @schema_version 1

  @enforce_keys [
    :migration_digest,
    :program_digest,
    :operation_ref,
    :operation_contract_digest,
    :source_version,
    :target_version,
    :source_state_digest,
    :target_state_digest,
    :operation_receipt_digest,
    :digest
  ]
  defstruct schema_version: @schema_version,
            migration_digest: nil,
            program_digest: nil,
            operation_ref: nil,
            operation_contract_digest: nil,
            source_version: nil,
            target_version: nil,
            source_state_digest: nil,
            target_state_digest: nil,
            operation_receipt_digest: nil,
            digest: nil

  @type t :: %__MODULE__{}

  @doc false
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- known_new_fields(attrs) do
      data =
        attrs
        |> Map.take(fields())
        |> Map.put(:schema_version, @schema_version)
        |> Map.delete(:digest)

      with :ok <- validate_data(data) do
        {:ok, struct!(__MODULE__, Map.put(data, :digest, Value.digest!(data)))}
      end
    end
  rescue
    _error -> {:error, :invalid_execution_migration_receipt}
  end

  def new(value), do: {:error, {:invalid_execution_migration_receipt, shape(value)}}

  @doc "Returns the portable receipt representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = receipt), do: Map.from_struct(receipt)

  @doc "Restores and verifies a portable migration receipt."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%__MODULE__{} = receipt), do: receipt |> to_data() |> from_data()

  def from_data(value) when is_map(value) do
    with {:ok, value} <- exact_fields(value),
         receipt <- struct!(__MODULE__, value),
         data <- receipt |> Map.from_struct() |> Map.delete(:digest),
         :ok <- validate_data(data),
         true <- digest?(receipt.digest),
         true <- receipt.digest == Value.digest!(data) do
      {:ok, receipt}
    else
      false -> {:error, :execution_migration_receipt_digest_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_execution_migration_receipt}
  end

  def from_data(value),
    do: {:error, {:invalid_execution_migration_receipt, shape(value)}}

  @spec validate_data(map()) :: :ok | {:error, term()}
  defp validate_data(data) do
    digests = [
      :migration_digest,
      :program_digest,
      :operation_contract_digest,
      :source_state_digest,
      :target_state_digest
    ]

    cond do
      data.schema_version != @schema_version ->
        {:error, {:unsupported_execution_migration_receipt_schema, data.schema_version}}

      Enum.any?(digests, &(not digest?(Map.get(data, &1)))) ->
        {:error, :invalid_execution_migration_receipt_digest}

      not stable_ref?(data.operation_ref) ->
        {:error, :invalid_execution_migration_receipt_operation}

      is_nil(data.source_version) or is_nil(data.target_version) ->
        {:error, :invalid_execution_migration_receipt_version}

      not is_nil(data.operation_receipt_digest) and
          not digest?(data.operation_receipt_digest) ->
        {:error, :invalid_execution_migration_operation_receipt_digest}

      true ->
        Value.validate(data)
    end
  end

  @spec digest?(term()) :: boolean()
  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _bytes}, Base.decode16(value, case: :mixed))

  defp digest?(_value), do: false

  @spec stable_ref?(term()) :: boolean()
  defp stable_ref?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  @spec known_new_fields(map()) :: :ok | {:error, term()}
  defp known_new_fields(value) do
    case Map.keys(value) -- fields() do
      [] ->
        :ok

      unknown ->
        {:error, {:unknown_execution_migration_receipt_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec exact_fields(map()) :: {:ok, map()} | {:error, term()}
  defp exact_fields(value) when is_map(value) and not is_struct(value) do
    expected = fields()
    allowed = expected ++ Enum.map(expected, &Atom.to_string/1)

    cond do
      Enum.any?(Map.keys(value), &(&1 not in allowed)) ->
        {:error, :unknown_execution_migration_receipt_fields}

      Enum.any?(expected, fn field ->
        Map.has_key?(value, field) and Map.has_key?(value, Atom.to_string(field))
      end) ->
        {:error, :duplicate_execution_migration_receipt_fields}

      Enum.any?(expected, fn field ->
        not Map.has_key?(value, field) and not Map.has_key?(value, Atom.to_string(field))
      end) ->
        {:error, :missing_execution_migration_receipt_fields}

      true ->
        {:ok,
         Map.new(expected, fn field ->
           {field, Map.get(value, field, Map.get(value, Atom.to_string(field)))}
         end)}
    end
  end

  @spec fields() :: [atom()]
  defp fields, do: __MODULE__.__struct__() |> Map.keys() |> List.delete(:__struct__)

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
