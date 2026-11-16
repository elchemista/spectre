defmodule Spectre.Stack.Effects do
  @moduledoc """
  Versioned, immutable effect registrations returned by Stack packages.

  This additive contract is separate from tool helper descriptors. It declares
  an execution adapter for a closed operation; registration grants no authority.
  Version 1 tool descriptors and manual GAM bindings remain supported.
  """

  alias Spectre.GAM.Canonical.Value

  @fields [
    :contract,
    :adapter,
    :operation,
    :side_effect,
    :material,
    :partition,
    :schema_hash,
    :config
  ]
  @side_effects [:none, :idempotent, :reconcilable, :non_idempotent]

  @type descriptor :: %{
          contract: 1,
          adapter: module(),
          operation: atom() | binary(),
          side_effect: :none | :idempotent | :reconcilable | :non_idempotent,
          material: :arguments,
          partition: [atom()],
          schema_hash: binary() | nil,
          config: map()
        }
  @type t :: %{optional(atom() | binary() | tuple()) => descriptor()}

  @doc "Validates effect registration data without loading or invoking adapters."
  @spec validate!(term()) :: t()
  def validate!(effects) when is_map(effects) and not is_struct(effects) do
    Enum.each(effects, fn {operation, descriptor} ->
      validate_operation!(operation)
      validate_descriptor!(descriptor)
    end)

    effects
  end

  def validate!(_), do: invalid!("registrations must be a plain map")

  @spec validate_operation!(term()) :: :ok
  defp validate_operation!(operation)
       when (is_atom(operation) and operation not in [nil, true, false]) or
              (is_binary(operation) and byte_size(operation) > 0) or
              (is_tuple(operation) and tuple_size(operation) > 0) do
    if Value.validate(operation) != :ok, do: invalid!("operation must be canonical data")
    :ok
  end

  defp validate_operation!(_), do: invalid!("invalid operation reference")

  @spec validate_descriptor!(term()) :: :ok
  defp validate_descriptor!(descriptor) when is_map(descriptor) and not is_struct(descriptor) do
    validate_keys!(descriptor)
    validate_semantics!(descriptor)
    validate_partition!(descriptor.partition)
    validate_payload!(descriptor)
  end

  defp validate_descriptor!(_), do: invalid!("descriptor must be a plain map")

  @spec validate_keys!(map()) :: :ok
  defp validate_keys!(descriptor) do
    if Enum.sort(Map.keys(descriptor)) != Enum.sort(@fields),
      do: invalid!("descriptor requires exactly #{inspect(@fields)}")

    :ok
  end

  @spec validate_semantics!(map()) :: :ok
  defp validate_semantics!(descriptor) do
    if descriptor.contract != 1, do: invalid!("unsupported effect contract")

    if not is_atom(descriptor.adapter) or descriptor.adapter in [nil, true, false],
      do: invalid!("adapter must be a module")

    validate_operation!(descriptor.operation)
    if descriptor.side_effect not in @side_effects, do: invalid!("invalid side_effect")
    if descriptor.material != :arguments, do: invalid!("material must be :arguments")
    :ok
  end

  @spec validate_partition!(term()) :: :ok
  defp validate_partition!(partition) when is_list(partition) do
    if Enum.any?(partition, &(&1 not in [:subject, :conversation, :task, :flow])),
      do: invalid!("invalid identity partition")

    :ok
  end

  defp validate_partition!(_), do: invalid!("invalid identity partition")

  @spec validate_payload!(map()) :: :ok
  defp validate_payload!(descriptor) do
    if not is_nil(descriptor.schema_hash) and not is_binary(descriptor.schema_hash),
      do: invalid!("schema_hash must be a string or nil")

    if not is_map(descriptor.config) or is_struct(descriptor.config),
      do: invalid!("config must be a plain map")

    if Value.validate(descriptor) != :ok, do: invalid!("descriptor must be canonical data")
    :ok
  end

  @spec invalid!(String.t()) :: no_return()
  defp invalid!(message), do: raise(ArgumentError, "invalid Stack effects: #{message}")
end
