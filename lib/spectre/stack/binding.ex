defmodule Spectre.Stack.Binding do
  @moduledoc """
  Binds an immutable Stack installation to one Agent definition.

  `install/2` has three distinct effects:

    * the Stack compiler produces immutable installation data;
    * `Spectre.Stack.Runtime` starts caller-owned resources;
    * this module activates package-declared Agent extensions when an Agent
      selects the Stack with `use Spectre.Agent, stack: MyStack`.

  Packages opt into the last phase through the `:agent_extensions` field in
  their `Spectre.Stack.Package` manifest. Core owns registration and the single
  Agent compile pass; a package never needs a second `@before_compile` hook.
  """

  alias Spectre.Extension
  alias Spectre.Extension.Mount
  alias Spectre.Stack.Definition, as: StackDefinition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Ref

  @doc false
  @spec setup_agent!(module(), module() | nil) :: :ok
  def setup_agent!(owner, nil) when is_atom(owner) do
    Module.put_attribute(owner, :spectre_stack_refs, [])
    :ok
  end

  def setup_agent!(owner, stack)
      when is_atom(owner) and is_atom(stack) and not is_nil(stack) do
    definition =
      case StackDefinition.fetch(stack) do
        {:ok, definition} ->
          definition

        {:error, reason} ->
          raise ArgumentError,
                "cannot bind Spectre Stack #{inspect(stack)} to #{inspect(owner)}: " <>
                  inspect(reason)
      end

    refs =
      Enum.map(definition.installations, fn installation ->
        {:ok, ref} = StackDefinition.resolve(definition, :package, installation.package.id)
        register_extensions!(owner, stack, installation, ref)
        ref
      end)

    Module.put_attribute(owner, :spectre_stack_refs, refs)
    :ok
  end

  def setup_agent!(owner, stack) do
    raise ArgumentError,
          "invalid Spectre Stack for #{inspect(owner)}: expected a module, got #{inspect(stack)}"
  end

  @doc """
  Returns the immutable package references bound into an Agent definition.
  """
  @spec refs(module()) :: {:ok, [Ref.t()]} | {:error, term()}
  def refs(agent) when is_atom(agent) and not is_nil(agent) do
    with {:ok, definition} <- Spectre.Definition.fetch(agent) do
      {:ok, definition.stack_refs}
    end
  end

  @doc """
  Fetches an installation bound to an Agent by local installation or package ID.
  """
  @spec installation(module(), term()) :: {:ok, Installation.t()} | {:error, term()}
  def installation(agent, id) when is_atom(agent) and not is_nil(agent) do
    with {:ok, agent_definition} <- Spectre.Definition.fetch(agent),
         stack when is_atom(stack) and not is_nil(stack) <- agent_definition.stack,
         {:ok, stack_definition} <- StackDefinition.fetch(stack),
         {:ok, installation} <- find_installation(stack_definition, id),
         :ok <- verify_bound(agent_definition.stack_refs, stack_definition, installation) do
      {:ok, installation}
    else
      nil -> {:error, :agent_has_no_stack}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches immutable package configuration through an Agent's selected Stack.
  """
  @spec config(module(), term()) :: {:ok, map() | keyword()} | {:error, term()}
  def config(agent, id) do
    with {:ok, installation} <- installation(agent, id) do
      {:ok, installation.config}
    end
  end

  @doc false
  @spec stack_mount?(Mount.t()) :: boolean()
  def stack_mount?(%Mount{opts: opts}) do
    Keyword.has_key?(opts, :stack_ref) and Keyword.has_key?(opts, :stack_config)
  end

  @spec register_extensions!(module(), module(), Installation.t(), Ref.t()) :: :ok
  defp register_extensions!(owner, stack, %Installation{} = installation, %Ref{} = ref) do
    Enum.each(installation.package.agent_extensions, fn extension ->
      Extension.register!(
        owner,
        extension,
        as: installation.id,
        stack: stack,
        stack_ref: ref,
        stack_config: installation.config,
        stack_installation: installation.id,
        stack_package: installation.package.id,
        stack_package_version: installation.package.version
      )
    end)

    :ok
  end

  @spec find_installation(StackDefinition.t(), term()) ::
          {:ok, Installation.t()} | {:error, term()}
  defp find_installation(definition, id) do
    case StackDefinition.installation(definition, id) do
      {:ok, installation} ->
        {:ok, installation}

      {:error, {:unknown_stack_installation, ^id}} ->
        case Enum.find(definition.installations, &(&1.package.id == id)) do
          %Installation{} = installation -> {:ok, installation}
          nil -> {:error, {:package_not_installed, id}}
        end
    end
  end

  @spec verify_bound([Ref.t()], StackDefinition.t(), Installation.t()) ::
          :ok | {:error, term()}
  defp verify_bound(refs, stack_definition, installation) do
    with {:ok, current} <-
           StackDefinition.resolve(stack_definition, :package, installation.package.id),
         %Ref{} = bound <-
           Enum.find(refs, fn ref ->
             ref.kind == :package and ref.id == installation.package.id
           end) do
      if bound == current,
        do: :ok,
        else: {:error, {:stale_stack_binding, installation.id}}
    else
      nil -> {:error, {:package_not_bound, installation.id}}
      {:error, _reason} = error -> error
    end
  end
end
