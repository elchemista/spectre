defmodule Spectre.Stack.Installable do
  @moduledoc """
  Versioned contract implemented by packages that can be installed in a Stack.

  `manifest/0` and `compile/3` run while the Stack definition is compiled and
  must return immutable data. `child_specs/2`, when implemented, runs only
  when a caller explicitly starts `Spectre.Stack.Runtime`.
  """

  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Value

  @contract_version 1

  @callback manifest() :: Package.t() | map() | keyword()
  @callback compile(keyword(), Macro.t() | nil, Macro.Env.t()) ::
              {:ok, map() | keyword()} | {:error, term()}
  @callback child_specs(Installation.t(), keyword()) ::
              [{term(), Supervisor.child_spec()}]
              | {:ok, [{term(), Supervisor.child_spec()}]}
              | {:error, term()}

  @optional_callbacks compile: 3, child_specs: 2

  @doc """
  Defines a static manifest and default data-only compiler.
  """
  defmacro __using__(manifest_opts) do
    quote bind_quoted: [manifest_opts: manifest_opts] do
      @behaviour Spectre.Stack.Installable
      @spectre_stack_manifest_opts manifest_opts

      @impl Spectre.Stack.Installable
      def manifest do
        Keyword.put(@spectre_stack_manifest_opts, :module, __MODULE__)
      end

      @impl Spectre.Stack.Installable
      def compile(opts, nil, _caller), do: {:ok, opts}

      def compile(_opts, _block, _caller),
        do: {:error, :package_does_not_define_a_stack_dsl}

      defoverridable manifest: 0, compile: 3
    end
  end

  @doc """
  Returns the supported installable contract version.
  """
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc """
  Verifies and returns an installable package manifest.
  """
  @spec verify(module(), pos_integer()) :: {:ok, Package.t()} | {:error, term()}
  def verify(module, contract \\ @contract_version)

  def verify(_module, contract) when contract != @contract_version,
    do: {:error, {:unsupported_stack_contract, contract, [@contract_version]}}

  def verify(module, @contract_version) when is_atom(module) and not is_nil(module),
    do: verify_installable(module)

  def verify(module, @contract_version), do: {:error, {:invalid_installable, module}}

  @spec verify_installable(module()) :: {:ok, Package.t()} | {:error, term()}
  defp verify_installable(module) do
    with {:ok, manifest} <- invoke(module, :manifest, []),
         {:ok, package} <- normalize_package(module, manifest),
         :ok <- verify_package_contract(package) do
      {:ok, package}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Verifies an installable or raises with a stable contract error.
  """
  @spec verify!(module(), pos_integer()) :: Package.t()
  def verify!(module, contract \\ @contract_version) do
    case verify(module, contract) do
      {:ok, package} ->
        package

      {:error, reason} ->
        raise ArgumentError,
              "invalid Spectre Stack installable #{inspect(module)}: #{inspect(reason)}"
    end
  end

  @doc false
  @spec compile!(module(), keyword(), Macro.t() | nil, Macro.Env.t()) :: map() | keyword()
  def compile!(module, opts, block, %Macro.Env{} = caller) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Stack installation options must be a keyword list")

    config = module |> invoke_compile(opts, block, caller) |> normalize_compile_reply!(module)
    validate_config!(config, module)
    Value.ensure_portable!(config, "Stack package #{inspect(module)} configuration")
  end

  @doc false
  @spec child_specs(Installation.t(), keyword()) ::
          {:ok, [{term(), Supervisor.child_spec()}]} | {:error, term()}
  def child_specs(%Installation{package: %Package{module: module}} = installation, opts)
      when is_list(opts) do
    with {:ok, functions} <- invoke(module, :__info__, [:functions]) do
      if {:child_specs, 2} in functions,
        do: invoke_child_specs(module, installation, opts),
        else: {:ok, []}
    end
  end

  @spec invoke_child_specs(module(), Installation.t(), keyword()) ::
          {:ok, [{term(), Supervisor.child_spec()}]} | {:error, term()}
  defp invoke_child_specs(module, installation, opts) do
    case invoke(module, :child_specs, [installation, opts]) do
      {:ok, {:ok, specs}} -> normalize_child_specs(specs)
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, specs} -> normalize_child_specs(specs)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_package(module(), term()) :: {:ok, Package.t()} | {:error, term()}
  defp normalize_package(module, manifest) do
    {:ok, Package.new!(module, manifest)}
  rescue
    exception in ArgumentError -> {:error, {:invalid_manifest, Exception.message(exception)}}
  end

  @spec verify_package_contract(Package.t()) :: :ok | {:error, term()}
  defp verify_package_contract(%Package{contract: @contract_version}), do: :ok

  defp verify_package_contract(%Package{contract: contract}),
    do: {:error, {:unsupported_stack_contract, contract, [@contract_version]}}

  @spec default_compile(keyword(), Macro.t() | nil) :: {:ok, keyword()} | {:error, term()}
  defp default_compile(opts, nil), do: {:ok, opts}
  defp default_compile(_opts, _block), do: {:error, :package_does_not_define_a_stack_dsl}

  @spec invoke_compile(module(), keyword(), Macro.t() | nil, Macro.Env.t()) ::
          {:ok, term()} | {:error, term()}
  defp invoke_compile(module, opts, block, caller) do
    if function_exported?(module, :compile, 3),
      do: invoke(module, :compile, [opts, block, caller]),
      else: default_compile(opts, block)
  end

  @spec normalize_compile_reply!({:ok, term()} | {:error, term()}, module()) :: term()
  defp normalize_compile_reply!({:ok, {:ok, value}}, _module), do: value

  defp normalize_compile_reply!({:ok, {:error, reason}}, module),
    do: raise_compile_error(module, reason)

  defp normalize_compile_reply!({:ok, value}, _module), do: value
  defp normalize_compile_reply!({:error, reason}, module), do: raise_compile_error(module, reason)

  @spec validate_config!(term(), module()) :: :ok
  defp validate_config!(config, module) do
    unless is_map(config) or is_list(config) do
      raise ArgumentError,
            "Stack package #{inspect(module)} compiler must return a map or keyword list"
    end

    if is_list(config) and not Keyword.keyword?(config) do
      raise ArgumentError,
            "Stack package #{inspect(module)} compiler returned a non-keyword list"
    end

    :ok
  end

  @spec normalize_child_specs(term()) ::
          {:ok, [{term(), Supervisor.child_spec()}]} | {:error, term()}
  defp normalize_child_specs(specs) when is_list(specs) do
    if Enum.all?(specs, fn
         {resource, _child_spec} -> not is_nil(resource)
         _other -> false
       end) do
      {:ok, specs}
    else
      {:error, {:invalid_stack_child_specs, specs}}
    end
  end

  defp normalize_child_specs(specs), do: {:error, {:invalid_stack_child_specs, specs}}

  @spec invoke(module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp invoke(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    exception ->
      {:error,
       {:stack_callback_exception, module, function, exception.__struct__,
        Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:stack_callback_failure, module, function, kind, reason}}
  end

  @spec raise_compile_error(module(), term()) :: no_return()
  defp raise_compile_error(module, reason) do
    raise ArgumentError,
          "Stack package #{inspect(module)} compilation failed: #{inspect(reason)}"
  end
end
