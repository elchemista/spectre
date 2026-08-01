defmodule Spectre.Stack.Definition do
  @moduledoc """
  Compiled, immutable environment installed for an Agent.

  Definitions validate package compatibility, dependency ordering, ownership,
  and capability collisions. They contain logical configuration only.
  """

  alias Spectre.Stack.Installable
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Ref
  alias Spectre.Stack.Value

  @version 1

  @enforce_keys [:id, :owner, :installations]
  defstruct id: nil,
            owner: nil,
            version: @version,
            contract: 1,
            installations: [],
            packages: %{},
            index: %{},
            digest: nil

  @type capability_kind ::
          :package | :contract | :service | :operation | :action | :resource

  @type t :: %__MODULE__{
          id: term(),
          owner: module(),
          version: pos_integer(),
          contract: pos_integer(),
          installations: [Installation.t()],
          packages: %{optional(term()) => Package.t()},
          index: %{optional({capability_kind(), term()}) => Installation.t()},
          digest: String.t() | nil
        }

  @doc false
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(attrs) when is_map(attrs) do
    id = Map.fetch!(attrs, :id)
    owner = Map.fetch!(attrs, :owner)
    version = Map.get(attrs, :version, @version)
    contract = Map.get(attrs, :contract, Installable.contract_version())
    installations = Map.get(attrs, :installations, [])

    validate_header!(id, owner, version, contract, installations)
    installations = Enum.map(installations, &Installation.rebuild!/1)
    validate_unique_installations!(installations)
    validate_compatibility!(installations)

    ordered = order_installations!(installations)
    index = build_index!(ordered)
    validate_requirements!(ordered, index)
    validate_conflicts!(ordered, index)

    packages =
      Map.new(ordered, fn %Installation{package: %Package{id: package_id} = package} ->
        {package_id, package}
      end)

    definition = %__MODULE__{
      id: id,
      owner: owner,
      version: version,
      contract: contract,
      installations: ordered,
      packages: packages,
      index: index
    }

    %{definition | digest: Value.digest(canonical(definition))}
  end

  @doc """
  Revalidates every invariant and digest in a compiled definition.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = definition) do
    rebuilt =
      new!(%{
        id: definition.id,
        owner: definition.owner,
        version: definition.version,
        contract: definition.contract,
        installations: definition.installations
      })

    if rebuilt == definition,
      do: {:ok, definition},
      else: {:error, :stack_definition_integrity_mismatch}
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_stack_definition, Exception.message(exception)}}
  end

  @doc """
  Revalidates a compiled definition or raises.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = definition) do
    case validate(definition) do
      {:ok, validated} -> validated
      {:error, reason} -> raise ArgumentError, "invalid Stack definition: #{inspect(reason)}"
    end
  end

  @doc """
  Fetches the compiled definition exposed by a Stack module.
  """
  @spec fetch(module()) :: {:ok, t()} | {:error, term()}
  def fetch(stack) when is_atom(stack) and not is_nil(stack) do
    validate_exported_definition(stack, stack.__spectre_stack_definition__())
  rescue
    UndefinedFunctionError -> {:error, {:unknown_stack, stack}}
    exception -> {:error, {:stack_definition_exception, stack, exception.__struct__}}
  catch
    kind, reason -> {:error, {:stack_definition_failure, stack, kind, reason}}
  end

  def fetch(stack), do: {:error, {:unknown_stack, stack}}

  @spec validate_exported_definition(module(), term()) :: {:ok, t()} | {:error, term()}
  defp validate_exported_definition(stack, %__MODULE__{owner: stack} = definition) do
    with {:ok, validated} <- validate(definition),
         true <- stack.__spectre_stack_manifest__() == manifest(validated) do
      {:ok, validated}
    else
      false -> {:error, {:stack_manifest_integrity_mismatch, stack}}
      {:error, reason} -> {:error, {:invalid_stack_definition, stack, reason}}
    end
  end

  defp validate_exported_definition(stack, %__MODULE__{owner: owner}),
    do: {:error, {:stack_owner_mismatch, stack, owner}}

  defp validate_exported_definition(stack, reply),
    do: {:error, {:invalid_stack_definition, stack, reply}}

  @doc """
  Fetches a Stack definition or raises.
  """
  @spec fetch!(module()) :: t()
  def fetch!(stack) do
    case fetch(stack) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid Spectre Stack: #{inspect(reason)}"
    end
  end

  @doc """
  Returns a package installation by its local installation identifier.
  """
  @spec installation(t() | module(), term()) ::
          {:ok, Installation.t()} | {:error, term()}
  def installation(stack, id) when is_atom(stack), do: stack |> fetch!() |> installation(id)

  def installation(%__MODULE__{} = definition, id) do
    case Enum.find(definition.installations, &(&1.id == id)) do
      %Installation{} = installation -> {:ok, installation}
      nil -> {:error, {:unknown_stack_installation, id}}
    end
  end

  @doc """
  Resolves a closed logical capability to a fenced `Spectre.Stack.Ref`.
  """
  @spec resolve(t() | module(), capability_kind(), term()) ::
          {:ok, Ref.t()} | {:error, term()}
  def resolve(stack, kind, id) when is_atom(stack), do: stack |> fetch!() |> resolve(kind, id)

  def resolve(%__MODULE__{} = definition, kind, id) do
    case Map.fetch(definition.index, {kind, id}) do
      {:ok, installation} -> {:ok, Ref.new(definition, installation, kind, id)}
      :error -> {:error, {:unknown_stack_capability, kind, id}}
    end
  end

  @doc """
  Returns the portable manifest for inspection, contract tests, and tooling.
  """
  @spec manifest(t() | module()) :: map()
  def manifest(stack) when is_atom(stack), do: stack |> fetch!() |> manifest()

  def manifest(%__MODULE__{} = definition) do
    %{
      id: definition.id,
      owner: definition.owner,
      version: definition.version,
      contract: definition.contract,
      digest: definition.digest,
      packages: Enum.map(definition.installations, & &1.package),
      installations: definition.installations
    }
  end

  @spec validate_header!(term(), term(), term(), term(), term()) :: :ok
  defp validate_header!(id, owner, version, contract, installations) do
    unless Value.valid_id?(id),
      do: raise(ArgumentError, "invalid Stack id: #{inspect(id)}")

    unless is_atom(owner) and not is_nil(owner),
      do: raise(ArgumentError, "Stack owner must be a module")

    unless is_integer(version) and version > 0,
      do: raise(ArgumentError, "Stack definition version must be a positive integer")

    unless contract == Installable.contract_version() do
      raise ArgumentError,
            "unsupported Stack contract #{inspect(contract)}; supported: " <>
              inspect([Installable.contract_version()])
    end

    unless is_list(installations) and
             Enum.all?(installations, &match?(%Installation{}, &1)) do
      raise ArgumentError, "Stack installations must contain Installation values"
    end

    :ok
  end

  @spec validate_unique_installations!([Installation.t()]) :: :ok
  defp validate_unique_installations!(installations) do
    duplicate_installation =
      installations
      |> Enum.map(& &1.id)
      |> duplicate()

    duplicate_package =
      installations
      |> Enum.map(& &1.package.id)
      |> duplicate()

    cond do
      duplicate_installation ->
        raise ArgumentError,
              "duplicate Stack installation: #{inspect(duplicate_installation)}"

      duplicate_package ->
        raise ArgumentError, "duplicate Stack package: #{inspect(duplicate_package)}"

      true ->
        :ok
    end
  end

  @spec validate_compatibility!([Installation.t()]) :: :ok
  defp validate_compatibility!(installations) do
    Enum.each(installations, fn %Installation{package: package} ->
      unless Package.compatible?(package, Spectre.version()) do
        raise ArgumentError,
              "Stack package #{inspect(package.id)} #{package.version} requires Spectre " <>
                "#{package.spectre}, running #{Spectre.version()}"
      end
    end)
  end

  @spec order_installations!([Installation.t()]) :: [Installation.t()]
  defp order_installations!(installations) do
    dependency_index =
      Enum.reduce(installations, %{}, fn installation, index ->
        index
        |> put_unique!(:package, installation.package.id, installation)
        |> put_provides!(installation)
      end)

    {_visited, ordered} =
      Enum.reduce(installations, {%{}, []}, fn installation, state ->
        visit!(installation, dependency_index, %{}, state)
      end)

    # visit! prepends in post-order, so the reverse is the topological order.
    Enum.reverse(ordered)
  end

  @spec visit!(
          Installation.t(),
          map(),
          map(),
          {map(), [Installation.t()]}
        ) :: {map(), [Installation.t()]}
  defp visit!(
         %Installation{package: package} = installation,
         dependency_index,
         visiting,
         state
       ) do
    {visited, ordered} = state

    cond do
      Map.has_key?(visited, package.id) ->
        state

      Map.has_key?(visiting, package.id) ->
        raise ArgumentError, "cyclic Stack package dependency at #{inspect(package.id)}"

      true ->
        visiting = Map.put(visiting, package.id, true)

        {visited, ordered} =
          package.requires
          |> Enum.reduce({visited, ordered}, fn requirement, dependency_state ->
            dependency = fetch_requirement!(dependency_index, package.id, requirement)
            visit!(dependency, dependency_index, visiting, dependency_state)
          end)

        {Map.put(visited, package.id, true), [installation | ordered]}
    end
  end

  @spec fetch_requirement!(map(), term(), term()) :: Installation.t()
  defp fetch_requirement!(dependency_index, package_id, requirement) do
    {kind, id} = requirement_key(requirement)

    case Map.fetch(dependency_index, {kind, id}) do
      {:ok, dependency} ->
        dependency

      :error ->
        raise ArgumentError,
              "Stack package #{inspect(package_id)} requires missing #{kind} " <>
                inspect(id)
    end
  end

  @spec requirement_key(term()) :: {:package | :contract | :service, term()}
  defp requirement_key({:package, id}), do: {:package, id}
  defp requirement_key({:package, id, _requirement}), do: {:package, id}
  defp requirement_key({:contract, id}), do: {:contract, id}
  defp requirement_key({:contract, id, _requirement}), do: {:contract, id}
  defp requirement_key({:service, id}), do: {:service, id}
  defp requirement_key({:service, id, _requirement}), do: {:service, id}
  defp requirement_key(contract), do: {:contract, contract}

  @spec build_index!([Installation.t()]) :: map()
  defp build_index!(installations) do
    Enum.reduce(installations, %{}, fn installation, index ->
      index
      |> put_unique!(:package, installation.package.id, installation)
      |> put_provides!(installation)
      |> put_entries!(:operation, installation.operations, installation)
      |> put_entries!(:action, installation.actions, installation)
      |> put_entries!(:resource, installation.resources, installation)
    end)
  end

  @spec put_provides!(map(), Installation.t()) :: map()
  defp put_provides!(index, %Installation{} = installation) do
    Enum.reduce(installation.provides, index, fn
      {:service, id}, acc -> put_unique!(acc, :service, id, installation)
      {:contract, id}, acc -> put_unique!(acc, :contract, id, installation)
      contract, acc -> put_unique!(acc, :contract, contract, installation)
    end)
  end

  @spec put_entries!(map(), capability_kind(), [term()], Installation.t()) :: map()
  defp put_entries!(index, kind, entries, installation) do
    Enum.reduce(entries, index, fn entry, acc ->
      put_unique!(acc, kind, Package.entry_id(entry), installation)
    end)
  end

  @spec put_unique!(map(), capability_kind(), term(), Installation.t()) :: map()
  defp put_unique!(index, kind, id, installation) do
    case Map.fetch(index, {kind, id}) do
      {:ok, owner} ->
        raise ArgumentError,
              "duplicate Stack #{kind} ownership for #{inspect(id)}: " <>
                "#{inspect(owner.package.id)} and #{inspect(installation.package.id)}"

      :error ->
        Map.put(index, {kind, id}, installation)
    end
  end

  @spec validate_requirements!([Installation.t()], map()) :: :ok
  defp validate_requirements!(installations, index) do
    Enum.each(installations, fn %Installation{package: package} ->
      Enum.each(package.requires, &validate_requirement!(&1, package, index))
    end)
  end

  @spec validate_requirement!(term(), Package.t(), map()) :: :ok
  defp validate_requirement!({:package, id}, package, index),
    do: require_capability!(:package, id, nil, package, index)

  defp validate_requirement!({:package, id, requirement}, package, index),
    do: require_capability!(:package, id, requirement, package, index)

  defp validate_requirement!({:contract, id}, package, index),
    do: require_capability!(:contract, id, nil, package, index)

  defp validate_requirement!({:contract, id, requirement}, package, index),
    do: require_capability!(:contract, id, requirement, package, index)

  defp validate_requirement!({:service, id}, package, index),
    do: require_capability!(:service, id, nil, package, index)

  defp validate_requirement!({:service, id, requirement}, package, index),
    do: require_capability!(:service, id, requirement, package, index)

  defp validate_requirement!(contract, package, index),
    do: require_capability!(:contract, contract, nil, package, index)

  @spec require_capability!(
          capability_kind(),
          term(),
          String.t() | nil,
          Package.t(),
          map()
        ) :: :ok
  defp require_capability!(kind, id, requirement, package, index) do
    case Map.fetch(index, {kind, id}) do
      {:ok, installation} ->
        validate_dependency_version!(package, installation.package, requirement)

      :error ->
        raise ArgumentError,
              "Stack package #{inspect(package.id)} requires missing #{kind} #{inspect(id)}"
    end
  end

  @spec validate_dependency_version!(Package.t(), Package.t(), String.t() | nil) :: :ok
  defp validate_dependency_version!(_package, _dependency, nil), do: :ok

  defp validate_dependency_version!(package, dependency, requirement) do
    valid_requirement? =
      is_binary(requirement) and
        match?({:ok, _parsed}, Version.parse_requirement(requirement))

    unless valid_requirement? and Version.match?(dependency.version, requirement) do
      raise ArgumentError,
            "Stack package #{inspect(package.id)} requires #{inspect(dependency.id)} " <>
              "#{inspect(requirement)}, installed #{dependency.version}"
    end
  end

  @spec validate_conflicts!([Installation.t()], map()) :: :ok
  defp validate_conflicts!(installations, index) do
    Enum.each(installations, fn %Installation{package: package} ->
      Enum.each(package.conflicts, &validate_conflict!(&1, package, index))
    end)
  end

  @spec validate_conflict!(term(), Package.t(), map()) :: :ok
  defp validate_conflict!(conflict, package, index) do
    {kind, id} = conflict_key(conflict)

    case Map.get(index, {kind, id}) do
      nil ->
        :ok

      %Installation{package: %{id: owner_id}} when owner_id == package.id ->
        :ok

      owner ->
        raise ArgumentError,
              "Stack package #{inspect(package.id)} conflicts with " <>
                "#{kind} #{inspect(id)} owned by #{inspect(owner.package.id)}"
    end
  end

  @spec conflict_key(term()) :: {capability_kind(), term()}
  defp conflict_key({:package, id}), do: {:package, id}
  defp conflict_key({:contract, id}), do: {:contract, id}
  defp conflict_key({:service, id}), do: {:service, id}
  defp conflict_key(id), do: {:package, id}

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
  defp canonical(%__MODULE__{} = definition) do
    %{
      id: definition.id,
      owner: definition.owner,
      version: definition.version,
      contract: definition.contract,
      installations: definition.installations
    }
  end
end
