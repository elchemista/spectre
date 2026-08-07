defmodule Spectre.Stack.Package do
  @moduledoc """
  Versioned, immutable manifest published by a Stack-installable package.

  A package manifest describes what can be installed. It does not contain
  provider processes, credentials, clients, or any other runtime handle.
  """

  alias Spectre.Stack.Value

  @enforce_keys [:id, :module, :version]
  defstruct id: nil,
            module: nil,
            version: nil,
            contract: 1,
            spectre: ">= 0.0.0",
            provides: [],
            requires: [],
            conflicts: [],
            operations: [],
            actions: [],
            resources: [],
            agent_extensions: [],
            dsl: nil,
            metadata: %{},
            digest: nil

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          version: String.t(),
          contract: pos_integer(),
          spectre: String.t(),
          provides: [term()],
          requires: [term()],
          conflicts: [term()],
          operations: [term()],
          actions: [term()],
          resources: [term()],
          agent_extensions: [module()],
          dsl: module() | nil,
          metadata: map(),
          digest: String.t() | nil
        }

  @doc """
  Normalizes and validates a manifest returned by `package_module`.

  The owning module is supplied by the core and cannot be forged by a
  manifest callback.
  """
  @spec new!(module(), t() | map() | keyword()) :: t()
  def new!(package_module, manifest)
      when is_atom(package_module) and not is_nil(package_module) do
    attrs =
      manifest
      |> normalize_manifest!()
      |> Map.put(:module, package_module)
      |> Map.delete(:digest)

    package =
      __MODULE__
      |> struct(Map.take(attrs, fields_without_digest()))
      |> validate!()

    %{package | digest: Value.digest(canonical(package))}
  end

  @doc """
  Returns whether the package accepts the supplied Spectre release.
  """
  @spec compatible?(t(), String.t()) :: boolean()
  def compatible?(%__MODULE__{spectre: requirement}, core_version) do
    Version.match?(core_version, requirement)
  end

  @doc """
  Returns the stable identifier represented by a capability entry.
  """
  @spec entry_id(term()) :: term()
  def entry_id(entry), do: Value.entry_id(entry)

  @spec validate!(t()) :: t()
  defp validate!(%__MODULE__{} = package) do
    validate_id!(package.id)
    validate_module!(package.module)
    validate_version!(package.version, :version)
    validate_contract!(package.contract)
    validate_requirement!(package.spectre)
    validate_list!(package.provides, :provides)
    validate_list!(package.requires, :requires)
    validate_list!(package.conflicts, :conflicts)
    validate_list!(package.operations, :operations)
    validate_list!(package.actions, :actions)
    validate_list!(package.resources, :resources)
    validate_agent_extensions!(package.agent_extensions)
    validate_dsl!(package.dsl)

    unless is_map(package.metadata),
      do: raise(ArgumentError, "package metadata must be a map")

    Value.ensure_portable!(canonical(package), "package manifest")
    package
  end

  @spec normalize_manifest!(t() | map() | keyword()) :: map()
  defp normalize_manifest!(%__MODULE__{} = package), do: Map.from_struct(package)
  defp normalize_manifest!(manifest) when is_map(manifest), do: manifest

  defp normalize_manifest!(manifest) when is_list(manifest) do
    if Keyword.keyword?(manifest),
      do: Map.new(manifest),
      else: raise(ArgumentError, "package manifest must be a keyword list or map")
  end

  defp normalize_manifest!(manifest),
    do: raise(ArgumentError, "invalid package manifest: #{inspect(manifest)}")

  @spec validate_id!(term()) :: :ok
  defp validate_id!(id) do
    unless Value.valid_id?(id),
      do: raise(ArgumentError, "invalid package id: #{inspect(id)}")

    :ok
  end

  @spec validate_module!(term()) :: :ok
  defp validate_module!(module) do
    unless is_atom(module) and not is_nil(module),
      do: raise(ArgumentError, "package module must be a module")

    :ok
  end

  @spec validate_version!(term(), atom()) :: :ok
  defp validate_version!(version, field) do
    unless is_binary(version) and match?({:ok, _parsed}, Version.parse(version)),
      do: raise(ArgumentError, "package #{field} must be a semantic version")

    :ok
  end

  @spec validate_contract!(term()) :: :ok
  defp validate_contract!(contract) do
    unless is_integer(contract) and contract > 0,
      do: raise(ArgumentError, "package contract must be a positive integer")

    :ok
  end

  @spec validate_requirement!(term()) :: :ok
  defp validate_requirement!(requirement) do
    unless is_binary(requirement) and
             match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           do: raise(ArgumentError, "package spectre compatibility must be a version requirement")

    :ok
  end

  @spec validate_list!(term(), atom()) :: :ok
  defp validate_list!(values, field) do
    unless is_list(values),
      do: raise(ArgumentError, "package #{field} must be a list")

    ids = Enum.map(values, &Value.entry_id/1)

    case duplicate(ids) do
      nil -> :ok
      id -> raise ArgumentError, "duplicate package #{field} entry: #{inspect(id)}"
    end
  end

  @spec validate_dsl!(term()) :: :ok
  defp validate_dsl!(nil), do: :ok

  defp validate_dsl!(module) when is_atom(module) and not is_nil(module), do: :ok

  defp validate_dsl!(dsl),
    do: raise(ArgumentError, "package dsl must be a module or nil, got: #{inspect(dsl)}")

  @spec validate_agent_extensions!(term()) :: :ok
  defp validate_agent_extensions!(extensions) when is_list(extensions) do
    case Enum.find_index(extensions, &(not is_atom(&1) or is_nil(&1))) do
      nil ->
        case duplicate(extensions) do
          nil ->
            :ok

          module ->
            raise ArgumentError,
                  "duplicate package agent_extensions entry: #{inspect(module)}"
        end

      index ->
        invalid = Enum.at(extensions, index)

        raise ArgumentError,
              "package agent_extensions entries must be modules, got: #{inspect(invalid)}"
    end
  end

  defp validate_agent_extensions!(extensions) do
    raise ArgumentError,
          "package agent_extensions must be a list, got: #{inspect(extensions)}"
  end

  @spec duplicate([term()]) :: term() | nil
  defp duplicate(values) do
    values
    |> Enum.reduce_while(MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value),
        do: {:halt, value},
        else: {:cont, MapSet.put(seen, value)}
    end)
    |> case do
      %MapSet{} -> nil
      value -> value
    end
  end

  @spec canonical(t()) :: map()
  defp canonical(%__MODULE__{} = package) do
    package
    |> Map.from_struct()
    |> Map.delete(:digest)
  end

  @spec fields_without_digest() :: [atom()]
  defp fields_without_digest do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
    |> List.delete(:digest)
  end
end
