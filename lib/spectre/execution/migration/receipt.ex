defmodule Spectre.Execution.Migration.Receipt do
  @moduledoc """
  Integrity receipt for one committed registered state migration.

  It records only content digests and contract lineage. Source and migrated
  state values remain outside the receipt.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref

  @schema_version 1
  @digest_fields [
    :migration_digest,
    :program_digest,
    :materialization_digest,
    :operation_contract_digest,
    :source_state_digest,
    :target_state_digest
  ]

  @enforce_keys [
    :migration_digest,
    :program_digest,
    :definition_ref,
    :materialization_digest,
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
            definition_ref: nil,
            materialization_digest: nil,
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
    with :ok <- known_new_fields(attrs),
         {:ok, definition_ref} <- normalize_definition_ref(Map.get(attrs, :definition_ref)),
         {:ok, operation_ref} <- normalize_operation_ref(Map.get(attrs, :operation_ref)) do
      data =
        attrs
        |> Map.take(fields())
        |> Map.put(:schema_version, @schema_version)
        |> Map.put(:definition_ref, definition_ref)
        |> Map.put(:operation_ref, operation_ref)
        |> Map.delete(:digest)

      with :ok <- validate_data(data),
           {:ok, digest} <- Value.digest(data) do
        {:ok, struct!(__MODULE__, Map.put(data, :digest, digest))}
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
         {:ok, definition_ref} <- normalize_definition_ref(Map.get(value, :definition_ref)),
         {:ok, operation_ref} <- normalize_operation_ref(Map.get(value, :operation_ref)),
         value <-
           value
           |> Map.put(:definition_ref, definition_ref)
           |> Map.put(:operation_ref, operation_ref),
         receipt <- struct!(__MODULE__, value),
         data <- receipt |> Map.from_struct() |> Map.delete(:digest),
         :ok <- validate_data(data),
         true <- digest?(receipt.digest),
         {:ok, digest} <- Value.digest(data),
         true <- receipt.digest == digest do
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
    with :ok <- validate_schema(data.schema_version),
         :ok <- validate_digests(data),
         :ok <- validate_definition_ref(data.definition_ref),
         :ok <- validate_operation_ref(data.operation_ref),
         :ok <- validate_versions(data.source_version, data.target_version),
         :ok <- validate_operation_receipt(data.operation_receipt_digest) do
      Value.validate(data)
    end
  end

  defp validate_schema(@schema_version), do: :ok

  defp validate_schema(version),
    do: {:error, {:unsupported_execution_migration_receipt_schema, version}}

  defp validate_digests(data) do
    if Enum.all?(@digest_fields, &digest?(Map.get(data, &1))),
      do: :ok,
      else: {:error, :invalid_execution_migration_receipt_digest}
  end

  defp validate_definition_ref(value) do
    if definition_ref?(value),
      do: :ok,
      else: {:error, :invalid_execution_migration_receipt_definition_ref}
  end

  defp validate_operation_ref(value) do
    if stable_ref?(value),
      do: :ok,
      else: {:error, :invalid_execution_migration_receipt_operation}
  end

  defp validate_versions(source, target) do
    if stable_version?(source) and stable_version?(target),
      do: :ok,
      else: {:error, :invalid_execution_migration_receipt_version}
  end

  defp validate_operation_receipt(nil), do: :ok

  defp validate_operation_receipt(value) do
    if digest?(value),
      do: :ok,
      else: {:error, :invalid_execution_migration_operation_receipt_digest}
  end

  @spec digest?(term()) :: boolean()
  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _bytes}, Base.decode16(value, case: :lower))

  defp digest?(_value), do: false

  @spec stable_ref?(term()) :: boolean()
  defp stable_ref?(value), do: is_binary(value) and value != ""

  @spec definition_ref?(term()) :: boolean()
  defp definition_ref?(value) when is_binary(value), do: match?({:ok, _ref}, Ref.parse(value))
  defp definition_ref?(_value), do: false

  @spec stable_version?(term()) :: boolean()
  defp stable_version?(value) when is_integer(value), do: value > 0
  defp stable_version?(value) when is_binary(value), do: value != ""
  defp stable_version?(_value), do: false

  @spec normalize_operation_ref(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_operation_ref(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp normalize_operation_ref(value) when is_binary(value) and value != "", do: {:ok, value}

  defp normalize_operation_ref(_value),
    do: {:error, :invalid_execution_migration_receipt_operation}

  @spec normalize_definition_ref(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_definition_ref(%Ref{} = ref) do
    if Ref.valid?(ref),
      do: {:ok, Ref.to_string(ref)},
      else: {:error, :invalid_execution_migration_receipt_definition_ref}
  end

  defp normalize_definition_ref(value) when is_binary(value) do
    case Ref.parse(value) do
      {:ok, ref} -> {:ok, Ref.to_string(ref)}
      _invalid -> {:error, :invalid_execution_migration_receipt_definition_ref}
    end
  end

  defp normalize_definition_ref(_value),
    do: {:error, :invalid_execution_migration_receipt_definition_ref}

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
