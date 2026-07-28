defmodule Spectre.Stack.Installation do
  @moduledoc """
  Immutable result of compiling one package inside a Stack.

  Installation values contain only inspected configuration and logical
  capability declarations. Runtime handles are created later by
  `Spectre.Stack.Runtime`.
  """

  alias Spectre.Action.Provider.Mount, as: ProviderMount
  alias Spectre.Extension
  alias Spectre.Extension.Mount, as: ExtensionMount
  alias Spectre.Stack.Installable
  alias Spectre.Stack.Package
  alias Spectre.Stack.Value

  @enforce_keys [:id, :package, :config]
  defstruct id: nil,
            package: nil,
            config: %{},
            provides: [],
            operations: [],
            actions: [],
            resources: [],
            adapters: %{},
            legacy?: false,
            digest: nil

  @type t :: %__MODULE__{
          id: term(),
          package: Package.t(),
          config: map() | keyword(),
          provides: [term()],
          operations: [term()],
          actions: [term()],
          resources: [term()],
          adapters: map(),
          legacy?: boolean(),
          digest: String.t() | nil
        }

  @doc false
  @spec compile!(module(), keyword(), Macro.t() | nil, Macro.Env.t()) :: t()
  def compile!(module, opts, block, %Macro.Env{} = caller) when is_list(opts) do
    {installation_id, package_opts} = Keyword.pop(opts, :as)
    package = Installable.verify!(module)
    config = Installable.compile!(module, package_opts, block, caller)

    build!(
      installation_id || package.id,
      package,
      config,
      %{},
      false
    )
  end

  @doc """
  Converts a legacy `Spectre.Extension.Mount` into an immutable installation.
  """
  @spec from_extension_mount(ExtensionMount.t()) :: t()
  def from_extension_mount(%ExtensionMount{} = mount) do
    version = application_version(mount.module)
    providers = Extension.action_providers(mount)
    planner = Extension.action_planner(mount)

    package =
      Package.new!(mount.module, %{
        id: mount.id,
        version: version,
        contract: Installable.contract_version(),
        spectre: ">= 0.0.0",
        provides: legacy_extension_provides(providers, planner),
        metadata: %{legacy: :extension}
      })

    adapters = %{
      action_providers: providers,
      action_planner: planner
    }

    build!(mount.id, package, mount.opts, adapters, true)
  end

  @doc """
  Converts a legacy `Spectre.Action.Provider.Mount` into an installation.
  """
  @spec from_provider_mount(ProviderMount.t()) :: t()
  def from_provider_mount(%ProviderMount{} = mount) do
    package_id = {:action_provider, mount.id}

    package =
      Package.new!(mount.module, %{
        id: package_id,
        version: application_version(mount.module),
        contract: Installable.contract_version(),
        spectre: ">= 0.0.0",
        provides: [{:service, package_id}],
        actions: [],
        metadata: %{legacy: :action_provider}
      })

    build!(
      package_id,
      package,
      %{provider: mount},
      %{action_providers: [mount], action_planner: nil},
      true
    )
  end

  @doc false
  @spec build!(term(), Package.t(), map() | keyword(), map(), boolean()) :: t()
  def build!(id, %Package{} = package, config, adapters, legacy?)
      when is_boolean(legacy?) and is_map(adapters) do
    unless Value.valid_id?(id),
      do: raise(ArgumentError, "invalid Stack installation id: #{inspect(id)}")

    Value.ensure_portable!(config, "Stack installation configuration")
    Value.ensure_portable!(adapters, "Stack installation adapters")

    installation = %__MODULE__{
      id: id,
      package: package,
      config: config,
      provides: package.provides,
      operations: package.operations,
      actions: package.actions,
      resources: package.resources,
      adapters: adapters,
      legacy?: legacy?
    }

    %{installation | digest: Value.digest(canonical(installation))}
  end

  @doc false
  @spec rebuild!(t()) :: t()
  def rebuild!(%__MODULE__{
        id: id,
        package: %Package{module: module} = package,
        config: config,
        adapters: adapters,
        legacy?: legacy?
      }) do
    build!(id, Package.new!(module, package), config, adapters, legacy?)
  end

  def rebuild!(installation) do
    raise ArgumentError, "invalid Stack installation: #{inspect(installation)}"
  end

  @spec legacy_extension_provides([ProviderMount.t()], term()) :: [term()]
  defp legacy_extension_provides(providers, planner) do
    planner =
      case planner do
        nil -> []
        _planner -> [{:service, :action_planner}]
      end

    providers =
      Enum.map(providers, &{:service, {:action_provider, &1.id}})

    planner ++ providers
  end

  @spec application_version(module()) :: String.t()
  defp application_version(module) do
    with app when is_atom(app) <- Application.get_application(module),
         version when not is_nil(version) <- Application.spec(app, :vsn) do
      to_string(version)
    else
      _other -> "0.0.0"
    end
  end

  @spec canonical(t()) :: map()
  defp canonical(%__MODULE__{} = installation) do
    installation
    |> Map.from_struct()
    |> Map.delete(:digest)
  end
end
