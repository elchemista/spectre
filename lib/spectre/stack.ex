defmodule Spectre.Stack do
  @moduledoc """
  Compile-time installer and resolver for Spectre packages.

  A Stack describes one immutable environment. Packages contribute manifests,
  local DSL compilers, and optional caller-owned runtime resources without
  importing package verbs globally or registering capabilities in a process
  registry.

      defmodule MyApp.AI do
        use Spectre.Stack

        install MyApp.Inference do
          provider :openrouter, MyApp.OpenRouter
          model :fast, id: "small-model"
        end
      end

  Selecting the Stack from `use Spectre.Agent, stack: MyStack` activates every
  package-declared Agent extension. Installed operations and planner-visible
  actions still require explicit Flow, Work, Skill, or policy binding before
  they are visible or authorized.
  """

  alias Spectre.Stack.Binding
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Ref
  alias Spectre.Stack.Runtime

  @doc """
  Initializes a Stack definition.
  """
  defmacro __using__(opts \\ []) do
    opts = eval_opts(opts, __CALLER__)
    id = Keyword.get(opts, :id, __CALLER__.module)
    version = Keyword.get(opts, :version, 1)

    quote bind_quoted: [stack_id: id, stack_version: version] do
      import Spectre.Stack, only: [install: 1, install: 2, install: 3]

      Module.register_attribute(__MODULE__, :spectre_stack_installations,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_stack_id, persist: false)
      Module.register_attribute(__MODULE__, :spectre_stack_version, persist: false)

      @spectre_stack_id stack_id
      @spectre_stack_version stack_version
      @before_compile Spectre.Stack
    end
  end

  @doc """
  Installs and compiles one package.
  """
  defmacro install(package, opts \\ []) do
    {block, opts} = split_block(opts)
    compile_install(package, opts, block, __CALLER__)
  end

  @doc """
  Installs a package with explicit options and a package-local DSL block.
  """
  defmacro install(package, opts, do: block) do
    compile_install(package, opts, block, __CALLER__)
  end

  @doc false
  defmacro __before_compile__(env) do
    installations =
      env.module
      |> Module.get_attribute(:spectre_stack_installations)
      |> List.wrap()
      |> Enum.reverse()

    definition =
      Definition.new!(%{
        id: Module.get_attribute(env.module, :spectre_stack_id) || env.module,
        owner: env.module,
        version: Module.get_attribute(env.module, :spectre_stack_version) || 1,
        installations: installations
      })

    manifest = Definition.manifest(definition)

    quote do
      @doc false
      def __spectre_stack_definition__, do: unquote(Macro.escape(definition))

      @doc false
      def __spectre_stack_manifest__, do: unquote(Macro.escape(manifest))
    end
  end

  @doc """
  Returns the immutable definition for a Stack module.
  """
  @spec definition(module()) :: Definition.t()
  def definition(stack), do: Definition.fetch!(stack)

  @doc """
  Resolves a logical capability from a Stack module.
  """
  @spec resolve(module(), Definition.capability_kind(), term()) ::
          {:ok, Ref.t()} | {:error, term()}
  def resolve(stack, kind, id), do: Definition.resolve(stack, kind, id)

  @doc """
  Returns immutable configuration for a package bound to an Agent.
  """
  @spec config(module(), term()) :: {:ok, map() | keyword()} | {:error, term()}
  def config(agent, package_or_installation), do: Binding.config(agent, package_or_installation)

  @doc """
  Returns the immutable installation selected through an Agent's Stack.
  """
  @spec installation(module(), term()) :: {:ok, Installation.t()} | {:error, term()}
  def installation(agent, package_or_installation),
    do: Binding.installation(agent, package_or_installation)

  @doc """
  Starts a caller-owned runtime for a Stack.
  """
  @spec start_link(module(), keyword()) :: Supervisor.on_start()
  def start_link(stack, opts \\ []), do: Runtime.start_link(stack, opts)

  @spec compile_install(Macro.t(), Macro.t(), Macro.t() | nil, Macro.Env.t()) :: Macro.t()
  defp compile_install(package, opts, block, caller) do
    package = Macro.expand(package, caller)
    opts = eval_opts(opts, caller)
    installation = Installation.compile!(package, opts, block, caller)

    quote do
      @spectre_stack_installations unquote(Macro.escape(installation))
    end
  end

  @spec split_block(term()) :: {Macro.t() | nil, term()}
  defp split_block(opts) when is_list(opts) do
    {block, opts} = Keyword.pop(opts, :do)
    {block, opts}
  end

  defp split_block(opts), do: {nil, opts}

  @spec eval_opts(term(), Macro.Env.t()) :: term()
  defp eval_opts(opts, caller) when is_list(opts) do
    expanded = Macro.prewalk(opts, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(expanded, [], caller)
    value
  end

  defp eval_opts(opts, caller), do: Macro.expand(opts, caller)
end
