defmodule Spectre.Extension do
  @moduledoc """
  Minimal compile-time contract for on-demand Spectre libraries.

  Extensions are mounted after `use Spectre.Agent`:

      use Spectre.Agent
      use Spectre.Kinetic
      use Spectre.Lens

  They contribute data and runtime ports to the single Spectre definition.
  They must not install their own `@before_compile` hook or manipulate private
  Agent attributes.
  """

  alias Spectre.Action.Provider.Mount, as: ProviderMount
  alias Spectre.Extension.Mount

  @callback id() :: term()
  @callback action_providers(keyword()) ::
              [ProviderMount.t() | {term(), module()} | {term(), module(), keyword()}]
  @callback action_planner(keyword()) :: {module(), keyword()} | module() | nil

  @optional_callbacks id: 0, action_providers: 1, action_planner: 1

  @doc """
  Registers an extension on a module already initialized with
  `use Spectre.Agent`.
  """
  @spec register!(module(), module(), keyword()) :: :ok
  def register!(owner, extension, opts \\ [])
      when is_atom(owner) and is_atom(extension) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Spectre extension options must be a keyword list")

    unless Module.has_attribute?(owner, :spectre_extensions) do
      raise ArgumentError,
            "#{inspect(extension)} must be used after `use Spectre.Agent` in #{inspect(owner)}"
    end

    unless Module.get_attribute(owner, :spectre_kind) == :agent do
      raise ArgumentError,
            "#{inspect(extension)} can only extend a Spectre Agent, got #{inspect(owner)}"
    end

    Module.put_attribute(owner, :spectre_extensions, Mount.new(extension, opts))
    :ok
  end

  @doc """
  Returns provider mounts contributed by an extension.
  """
  @spec action_providers(Mount.t()) :: [ProviderMount.t()]
  def action_providers(%Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :action_providers, 1) do
      module = mount.module

      module.action_providers(mount.opts)
      |> List.wrap()
      |> Enum.map(&normalize_provider!/1)
    else
      []
    end
  end

  @doc """
  Returns the optional planner contributed by an extension.
  """
  @spec action_planner(Mount.t()) :: {module(), keyword()} | nil
  def action_planner(%Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :action_planner, 1) do
      module = mount.module
      normalize_planner!(module.action_planner(mount.opts))
    else
      nil
    end
  end

  @spec normalize_provider!(ProviderMount.t() | tuple()) :: ProviderMount.t()
  defp normalize_provider!(%ProviderMount{} = mount), do: mount
  defp normalize_provider!({id, module}), do: ProviderMount.new(id, module, [])
  defp normalize_provider!({id, module, opts}), do: ProviderMount.new(id, module, opts)

  defp normalize_provider!(other),
    do: raise(ArgumentError, "invalid action provider contribution: #{inspect(other)}")

  @spec normalize_planner!(term()) :: {module(), keyword()} | nil
  defp normalize_planner!(nil), do: nil

  defp normalize_planner!(module) when is_atom(module) and not is_nil(module),
    do: {module, []}

  defp normalize_planner!({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "action planner options must be a keyword list")

    {module, opts}
  end

  defp normalize_planner!(other),
    do: raise(ArgumentError, "invalid action planner contribution: #{inspect(other)}")

  @spec ensure_loaded!(Mount.t()) :: :ok
  defp ensure_loaded!(%Mount{} = mount) do
    unless Code.ensure_loaded?(mount.module),
      do: raise(ArgumentError, "unknown Spectre extension module: #{inspect(mount.module)}")

    :ok
  end
end
