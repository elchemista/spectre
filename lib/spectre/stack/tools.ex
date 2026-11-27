defmodule Spectre.Stack.Tools do
  @moduledoc """
  Immutable tool descriptors returned by `c:Spectre.Stack.Installable.tools/1`.
  `Spectre.Integration.tool/4` builds the same descriptor for scoped calls.

  A descriptor binds an adapter to a closed set of operations. Cognitive
  operations declare their retry policy. Governed operations name a host
  GAM binding.

  ## Tool adapter functions

  - `prepare(operation, input, trusted)` returns `{:ok, args}` or
    `{:error, reason}`. The trusted map contains the Agent, routing metadata
    and installation config. Prepare runs during command acquisition, so keep
    it fast and free of effects. Governed arguments must be a portable map.
  - `invoke(operation, args, context)` runs in a worker for a cognitive tool.
    The context contains the installation, its config, the service context
    and the checkpoint reference when available. Return the raw outcome for
    projection.
  - `project(operation, raw)` maps a cognitive result to `{:ok, result}` or
    `{:error, reason}`. The successful portable value is delivered to the
    initiating callback. Governed effects are executed after admission by a
    `Spectre.Server.GAM.EffectAdapter`.

  Adapter module availability is checked by the consumer at runtime, allowing
  packages to compile their integration modules independently of the Stack.
  """

  alias ExGAM.Canonical.Value, as: CanonicalValue
  alias Spectre.Integration
  alias Spectre.Stack.Installation
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

  @doc false
  @spec merge_integration!(t(), Integration.t() | nil) :: t()
  def merge_integration!(legacy, nil), do: legacy

  def merge_integration!(legacy, %Integration{tools: tools}) do
    legacy_operations = legacy |> Map.values() |> Enum.flat_map(&Map.keys(&1.operations))

    Enum.reduce(tools, legacy, fn {name, tool}, entries ->
      if name in legacy_operations,
        do: invalid!("duplicate operation #{inspect(name)} in tools/1 and integration/1")

      if is_nil(tool.helper), do: entries, else: put_alias!(entries, tool.helper, tool.descriptor)
    end)
  end

  @doc false
  @spec validate_integration_aliases!(t(), Integration.t()) :: :ok
  def validate_integration_aliases!(tools, %Integration{tools: typed} = integration) do
    names = for {_, %{helper: helper}} <- typed, not is_nil(helper), do: helper
    legacy = Map.drop(tools, names)

    unless merge_integration!(legacy, integration) == tools,
      do: invalid!("integration helper does not match its binding")

    :ok
  end

  @doc false
  @spec scoped_table!([Installation.t()]) :: map()
  def scoped_table!(installations) do
    installations
    |> table!()
    |> Enum.reduce(%{}, &index_helper/2)
    |> then(fn table -> Enum.reduce(installations, table, &index_unaliased_tools/2) end)
  end

  @doc false
  @spec public(Installation.t(), atom()) :: {:ok, map()} | {:error, term()}
  def public(%Installation{} = installation, name) do
    case get_in(installation.adapters, [:integration, Access.key(:tools), name]) do
      %{descriptor: descriptor, public: metadata} ->
        projection = Map.merge(metadata, %{version: 1, binding: Value.digest(descriptor)})
        {:ok, Map.put(projection, :digest, Value.digest(projection))}

      nil ->
        {:error, {:unknown_public_tool, {installation.id, name}}}
    end
  end

  defp put_alias!(tools, helper, descriptor) do
    if Map.has_key?(tools, helper), do: invalid!("duplicate helper #{inspect(helper)}")
    Map.put(tools, helper, descriptor)
  end

  defp index_helper({name, snapshot}, table) do
    Enum.reduce(snapshot.descriptor.operations, table, fn {operation, _}, entries ->
      key = {snapshot.installation_id, operation}
      Map.update(entries, key, %{key: name, snapshot: snapshot}, fn _ -> :ambiguous end)
    end)
  end

  defp index_unaliased_tools(%{adapters: %{integration: %{tools: tools}}} = installation, table) do
    Enum.reduce(tools, table, fn
      {name, %{helper: nil, descriptor: descriptor}}, entries ->
        key = {installation.id, name}
        binding = %{key: key, snapshot: snapshot(installation, descriptor)}
        Map.put(entries, key, binding)

      _, entries ->
        entries
    end)
  end

  defp index_unaliased_tools(_installation, table), do: table

  @spec put_descriptor!({atom(), descriptor()}, map(), term()) :: map()
  defp put_descriptor!({name, descriptor}, table, installation) do
    if Map.has_key?(table, name),
      do: invalid!("duplicate helper #{inspect(name)} across Stack installations")

    Map.put(table, name, snapshot(installation, descriptor))
  end

  defp snapshot(installation, descriptor) do
    %{
      installation_id: installation.id,
      installation_digest: installation.digest,
      descriptor: descriptor,
      digest: Value.digest(descriptor)
    }
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
