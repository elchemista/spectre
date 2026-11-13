defmodule Spectre.Stack.Tools do
  @moduledoc """
  Immutable tool descriptors returned by `Spectre.Stack.Installable.tools/1`.

  A descriptor declares a helper name and a closed set of operations. It does
  not execute an adapter or grant authority. Cognitive operations declare their
  retry policy; governed operations name a host binding instead of an executor.

  Adapter module availability is checked by the consumer at runtime, allowing
  packages to compile their integration modules independently of the Stack.
  """

  alias Spectre.GAM.Canonical.Value, as: CanonicalValue
  alias Spectre.Stack.Value

  @max_bytes Spectre.Server.Checkpoint.max_bytes()
  @reserved ~w(true false nil do end fn after else catch rescue when and or not in)a

  @type operation ::
          %{path: :cognitive, retry: :safe | :never, max_bytes: pos_integer()}
          | %{path: :governed, operation: atom() | binary() | tuple(), max_bytes: pos_integer()}
  @type descriptor :: %{
          contract: 1,
          adapter: module(),
          default: atom() | nil,
          operations: %{required(atom()) => operation()}
        }
  @type t :: %{optional(atom()) => descriptor()}

  @doc "Validates descriptors without loading or invoking their adapters."
  @spec validate!(term()) :: t()
  def validate!(tools) when is_map(tools) and not is_struct(tools) do
    Enum.each(tools, fn {name, descriptor} ->
      validate_name!(name)
      validate_descriptor!(name, descriptor)
    end)

    tools
  end

  def validate!(_), do: invalid!("declarations must be a plain map")

  @doc "Builds a unique helper table from validated Stack installations."
  @spec table!([Spectre.Stack.Installation.t()]) :: map()
  def table!(installations) do
    Enum.reduce(installations, %{}, fn installation, table ->
      installation.adapters
      |> Map.get(:tools, %{})
      |> validate!()
      |> Enum.reduce(table, &put_descriptor!(&1, &2, installation))
    end)
  end

  @spec put_descriptor!({atom(), descriptor()}, map(), term()) :: map()
  defp put_descriptor!({name, descriptor}, table, installation) do
    if Map.has_key?(table, name),
      do: invalid!("duplicate helper #{inspect(name)} across Stack installations")

    Map.put(table, name, %{
      installation_id: installation.id,
      installation_digest: installation.digest,
      descriptor: descriptor,
      digest: Value.digest(descriptor)
    })
  end

  @spec validate_name!(term()) :: :ok
  defp validate_name!(name) when is_atom(name) do
    reserved? = name in @reserved or Keyword.has_key?(Kernel.SpecialForms.__info__(:macros), name)

    if reserved? or not Regex.match?(~r/^[a-z][a-z0-9_]*[!?]?$/, Atom.to_string(name)),
      do: invalid!("invalid helper name #{inspect(name)}")

    :ok
  end

  defp validate_name!(name), do: invalid!("helper name must be an atom, got #{inspect(name)}")

  @spec validate_descriptor!(atom(), term()) :: :ok
  defp validate_descriptor!(name, descriptor) do
    exact_keys!(descriptor, [:contract, :adapter, :default, :operations], "helper #{name}")

    if descriptor.contract != 1,
      do: invalid!("unsupported contract for helper #{name}: #{inspect(descriptor.contract)}")

    validate_module!(descriptor.adapter)
    validate_operations!(descriptor.operations)

    unless is_nil(descriptor.default) or Map.has_key?(descriptor.operations, descriptor.default),
      do: invalid!("default operation for helper #{name} is not declared")

    :ok
  end

  @spec validate_module!(term()) :: :ok
  defp validate_module!(module) when is_atom(module) and module not in [nil, true, false], do: :ok
  defp validate_module!(_), do: invalid!("adapter must be a module atom")

  @spec validate_operations!(term()) :: :ok
  defp validate_operations!(operations)
       when is_map(operations) and not is_struct(operations) and map_size(operations) > 0 do
    Enum.each(operations, fn {name, operation} ->
      unless is_atom(name) and name not in [nil, true, false],
        do: invalid!("operation name must be a non-reserved atom")

      validate_operation!(operation)
    end)
  end

  defp validate_operations!(_), do: invalid!("operations must be a non-empty plain map")

  @spec validate_operation!(term()) :: :ok
  defp validate_operation!(%{path: :cognitive} = operation) do
    exact_keys!(operation, [:path, :retry, :max_bytes], "cognitive operation")
    unless operation.retry in [:safe, :never], do: invalid!("retry must be :safe or :never")
    validate_max_bytes!(operation.max_bytes)
  end

  defp validate_operation!(%{path: :governed} = operation) do
    exact_keys!(operation, [:path, :operation, :max_bytes], "governed operation")
    validate_host_operation!(operation.operation)
    validate_max_bytes!(operation.max_bytes)
  end

  defp validate_operation!(_), do: invalid!("operation path must be :cognitive or :governed")

  @spec validate_host_operation!(term()) :: :ok
  defp validate_host_operation!(name)
       when (is_atom(name) and name not in [nil, true, false]) or
              (is_binary(name) and byte_size(name) > 0) or
              (is_tuple(name) and tuple_size(name) > 0) do
    case CanonicalValue.validate(name) do
      :ok -> :ok
      {:error, _} -> invalid!("host operation must be canonical data")
    end
  end

  defp validate_host_operation!(_),
    do: invalid!("host operation must be an atom, string or tuple")

  @spec validate_max_bytes!(term()) :: :ok
  defp validate_max_bytes!(limit) when is_integer(limit) and limit > 0 and limit <= @max_bytes,
    do: :ok

  defp validate_max_bytes!(_), do: invalid!("max_bytes must be between 1 and #{@max_bytes}")

  @spec exact_keys!(term(), [atom()], String.t()) :: :ok
  defp exact_keys!(value, keys, label) when is_map(value) and not is_struct(value) do
    unless Enum.sort(Map.keys(value)) == Enum.sort(keys),
      do: invalid!("#{label} requires exactly #{inspect(keys)}")

    :ok
  end

  defp exact_keys!(_, _keys, label), do: invalid!("#{label} must be a plain map")

  @spec invalid!(String.t()) :: no_return()
  defp invalid!(reason), do: raise(ArgumentError, "invalid Stack tools: #{reason}")
end
