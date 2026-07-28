defmodule Spectre.Stack.Runtime do
  @moduledoc """
  Caller-owned supervisor for resources declared by a resolved Stack.

  A Runtime is never globally registered by default. Package callbacks receive
  runtime-only options, where credentials and client configuration may live,
  and return child specs paired with logical resource identifiers. The
  supervisor fences every child under the corresponding `Spectre.Stack.Ref`.

  This isolates Stack bindings without claiming that all existing Spectre
  application processes are already per-Stack; that broader runtime migration
  belongs to later vNext phases.
  """

  use Supervisor

  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Ref

  @doc """
  Starts a Stack runtime.

  `:packages` is a map or keyword list keyed by local installation id. These
  values are supplied only to runtime callbacks and are not copied into the
  immutable Stack definition.
  """
  @spec start_link(module() | Definition.t(), keyword()) :: Supervisor.on_start()
  def start_link(stack_or_definition, opts \\ []) when is_list(opts) do
    definition = normalize_definition!(stack_or_definition)
    {name, opts} = Keyword.pop(opts, :name)
    supervisor_opts = if is_nil(name), do: [], else: [name: name]

    Supervisor.start_link(__MODULE__, {definition, opts}, supervisor_opts)
  end

  @doc """
  Returns the child specs resolved for a Stack without starting them.
  """
  @spec child_specs(module() | Definition.t(), keyword()) ::
          {:ok, [Supervisor.child_spec()]} | {:error, term()}
  def child_specs(stack_or_definition, opts \\ []) when is_list(opts) do
    definition = normalize_definition!(stack_or_definition)

    with {:ok, package_opts} <- normalize_package_opts(Keyword.get(opts, :packages, %{})) do
      definition
      |> collect_child_specs(package_opts)
      |> unique_child_specs()
    end
  rescue
    exception in ArgumentError -> {:error, {:invalid_stack_runtime, Exception.message(exception)}}
  end

  @doc """
  Resolves a running resource Ref to its supervised child pid.
  """
  @spec resolve(Supervisor.supervisor(), Ref.t()) :: {:ok, pid()} | {:error, term()}
  def resolve(supervisor, %Ref{kind: :resource} = ref) do
    case Enum.find(Supervisor.which_children(supervisor), fn {id, _pid, _type, _modules} ->
           id == Ref.key(ref)
         end) do
      {_id, pid, _type, _modules} when is_pid(pid) -> {:ok, pid}
      {_id, :undefined, _type, _modules} -> {:error, {:stack_resource_not_running, ref}}
      {_id, :restarting, _type, _modules} -> {:error, {:stack_resource_restarting, ref}}
      nil -> {:error, {:unknown_stack_runtime_ref, ref}}
    end
  end

  def resolve(_supervisor, %Ref{} = ref),
    do: {:error, {:stack_runtime_requires_resource_ref, ref.kind}}

  @impl Supervisor
  def init({%Definition{} = definition, opts}) do
    case child_specs(definition, opts) do
      {:ok, specs} ->
        Supervisor.init(specs, strategy: Keyword.get(opts, :strategy, :one_for_one))

      {:error, reason} ->
        raise ArgumentError, "cannot start Spectre Stack runtime: #{inspect(reason)}"
    end
  end

  @spec collect_child_specs(Definition.t(), map()) ::
          {:ok, [Supervisor.child_spec()]} | {:error, term()}
  defp collect_child_specs(%Definition{} = definition, package_opts) do
    Enum.reduce_while(definition.installations, {:ok, []}, fn installation, {:ok, acc} ->
      runtime_opts =
        Map.get(
          package_opts,
          installation.id,
          Map.get(package_opts, installation.package.id, [])
        )

      case installation_child_specs(definition, installation, runtime_opts) do
        {:ok, specs} -> {:cont, {:ok, acc ++ specs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec installation_child_specs(Definition.t(), Installation.t(), keyword()) ::
          {:ok, [Supervisor.child_spec()]} | {:error, term()}
  defp installation_child_specs(definition, installation, runtime_opts)
       when is_list(runtime_opts) do
    if Keyword.keyword?(runtime_opts) do
      with {:ok, specs} <- Installable.child_specs(installation, runtime_opts) do
        normalize_installation_specs(definition, installation, specs)
      end
    else
      {:error, {:invalid_stack_runtime_options, installation.id, runtime_opts}}
    end
  end

  defp installation_child_specs(_definition, installation, runtime_opts),
    do: {:error, {:invalid_stack_runtime_options, installation.id, runtime_opts}}

  @spec normalize_installation_specs(
          Definition.t(),
          Installation.t(),
          [{term(), Supervisor.child_spec()}]
        ) :: {:ok, [Supervisor.child_spec()]} | {:error, term()}
  defp normalize_installation_specs(definition, installation, specs) do
    Enum.reduce_while(specs, {:ok, []}, fn {resource_id, child_spec}, {:ok, acc} ->
      with :ok <- declared_resource(installation, resource_id),
           {:ok, ref} <- Definition.resolve(definition, :resource, resource_id),
           :ok <- owned_ref(installation, ref),
           {:ok, normalized} <- normalize_child_spec(child_spec, ref) do
        {:cont, {:ok, acc ++ [normalized]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec declared_resource(Installation.t(), term()) :: :ok | {:error, term()}
  defp declared_resource(%Installation{} = installation, resource_id) do
    declared = Enum.map(installation.resources, &Package.entry_id/1)

    if resource_id in declared,
      do: :ok,
      else: {:error, {:undeclared_stack_resource, installation.id, resource_id}}
  end

  @spec owned_ref(Installation.t(), Ref.t()) :: :ok | {:error, term()}
  defp owned_ref(%Installation{id: id}, %Ref{installation: id}), do: :ok

  defp owned_ref(%Installation{} = installation, %Ref{} = ref),
    do: {:error, {:stack_resource_owner_mismatch, installation.id, ref.installation}}

  @spec normalize_child_spec(Supervisor.child_spec(), Ref.t()) ::
          {:ok, Supervisor.child_spec()} | {:error, term()}
  defp normalize_child_spec(child_spec, ref) do
    {:ok, Supervisor.child_spec(child_spec, id: Ref.key(ref))}
  rescue
    exception ->
      {:error, {:invalid_stack_child_spec, ref.id, exception.__struct__}}
  end

  @spec unique_child_specs({:ok, [Supervisor.child_spec()]} | {:error, term()}) ::
          {:ok, [Supervisor.child_spec()]} | {:error, term()}
  defp unique_child_specs({:error, _reason} = error), do: error

  defp unique_child_specs({:ok, specs}) do
    ids = Enum.map(specs, &Map.fetch!(&1, :id))

    case ids -- Enum.uniq(ids) do
      [] -> {:ok, specs}
      [duplicate | _rest] -> {:error, {:duplicate_stack_runtime_resource, duplicate}}
    end
  end

  @spec normalize_package_opts(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_package_opts(opts) when is_map(opts), do: {:ok, opts}

  defp normalize_package_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, Map.new(opts)},
      else: {:error, {:invalid_stack_package_runtime_options, opts}}
  end

  defp normalize_package_opts(opts),
    do: {:error, {:invalid_stack_package_runtime_options, opts}}

  @spec normalize_definition!(module() | Definition.t()) :: Definition.t()
  defp normalize_definition!(%Definition{} = definition), do: Definition.validate!(definition)
  defp normalize_definition!(stack) when is_atom(stack), do: Definition.fetch!(stack)
end
