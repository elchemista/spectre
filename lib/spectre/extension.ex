defmodule Spectre.Extension do
  @moduledoc """
  Compile-time contract for on-demand Spectre libraries.

  Extensions can be mounted explicitly after `use Spectre.Agent`:

      use Spectre.Agent
      use Spectre.Kinetic
      use Spectre.Lens

  An installed package can instead list its adapters in the
  `agent_extensions` manifest field. `use Spectre.Agent, stack: MyStack`
  registers those adapters automatically with the immutable installation
  configuration.

  Extensions contribute data and runtime ports to the single Spectre
  definition.
  They must not install their own `@before_compile` hook or manipulate private
  Agent attributes. New ecosystem packages should publish a
  `Spectre.Stack.Installable` manifest; Extension mounts remain
  source-compatible and can be materialized through
  `Spectre.Stack.Installation.from_extension_mount/1`.

  Version-zero extensions keep receiving their registration options directly.
  Version-one extensions may register namespaced attributes in `setup/2`,
  compile those attributes once through `compile/2`, consume namespaced flow
  options, and contribute runtime ports from the immutable compiled value.
  Spectre.Agent remains the only owner of an `@before_compile` hook.
  """

  alias Spectre.Action.Provider.Mount, as: ProviderMount
  alias Spectre.Effect.Executor.Mount, as: ExecutorMount
  alias Spectre.Extension.Mount
  alias Spectre.Flow.Constraint, as: FlowConstraint

  @api_version 1

  @callback id() :: term()
  @callback api_version() :: pos_integer()
  @callback setup(module(), keyword()) :: :ok
  @callback compile(module(), keyword()) :: term() | {:ok, term()} | {:error, term()}
  @callback action_providers(term()) ::
              [ProviderMount.t() | {term(), module()} | {term(), module(), keyword()}]
  @callback action_planner(term()) :: {module(), keyword()} | module() | nil
  @callback effect_executors(term()) ::
              [
                ExecutorMount.t()
                | {atom(), module()}
                | {atom(), module(), keyword()}
              ]
  @callback flow_constraints(keyword(), term()) ::
              {[Spectre.Flow.Constraint.t()], keyword()} | {:error, term()}
  @callback inference_selector(term()) :: {module(), keyword()} | module() | nil
  @callback agent_config(term()) :: keyword()
  @callback expand_handler(Macro.t(), Macro.Env.t(), keyword()) ::
              {:ok, Macro.t()} | :ignore | {:error, term()}

  @optional_callbacks id: 0,
                      api_version: 0,
                      setup: 2,
                      compile: 2,
                      action_providers: 1,
                      action_planner: 1,
                      effect_executors: 1,
                      flow_constraints: 2,
                      inference_selector: 1,
                      agent_config: 1,
                      expand_handler: 3

  @doc """
  Registers an extension on a module already initialized with
  `use Spectre.Agent`.
  """
  @spec register!(module(), module(), keyword()) :: :ok
  def register!(owner, extension, opts \\ [])
      when is_atom(owner) and is_atom(extension) and is_list(opts) do
    validate_registration!(owner, extension, opts)
    mount = Mount.new(extension, opts)
    ensure_supported_api!(mount)

    existing =
      owner
      |> Module.get_attribute(:spectre_extensions)
      |> List.wrap()
      |> Enum.find(&(&1.id == mount.id))

    register_mount!(owner, extension, opts, mount, existing)
  end

  @doc false
  @spec compile_all!(module(), [Mount.t()]) :: [Mount.t()]
  def compile_all!(owner, mounts) when is_atom(owner) and is_list(mounts) do
    Enum.map(mounts, &compile_mount!(owner, &1))
  end

  @doc false
  @spec compile_mount!(module(), Mount.t()) :: Mount.t()
  def compile_mount!(_owner, %Mount{api_version: 0} = mount), do: mount

  def compile_mount!(owner, %Mount{} = mount) do
    ensure_loaded!(mount)

    compiled =
      if function_exported?(mount.module, :compile, 2) do
        module = mount.module

        case module.compile(owner, mount.opts) do
          {:ok, value} -> value
          {:error, reason} -> extension_error!(mount, :compile, reason)
          value -> value
        end
      else
        mount.opts
      end

    %{mount | compiled: compiled}
  end

  @doc """
  Lets all mounted extensions consume their namespaced flow options.

  Any options left after the final extension are rejected by `Spectre.Agent`.
  """
  @spec flow_constraints(keyword(), [Mount.t()]) ::
          {[Spectre.Flow.Constraint.t()], keyword()}
  def flow_constraints(opts, mounts) when is_list(opts) and is_list(mounts) do
    Enum.reduce(mounts, {[], opts}, fn mount, {constraints, remaining} ->
      {next, remaining} = flow_constraints(mount, remaining)
      {constraints ++ next, remaining}
    end)
  end

  @doc false
  @spec flow_constraints(Mount.t(), keyword()) ::
          {[Spectre.Flow.Constraint.t()], keyword()}
  def flow_constraints(%Mount{} = mount, opts) when is_list(opts) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :flow_constraints, 2) do
      module = mount.module

      case module.flow_constraints(opts, extension_config(mount)) do
        {constraints, remaining} when is_list(constraints) and is_list(remaining) ->
          {Enum.map(constraints, &normalize_constraint!/1), remaining}

        {:error, reason} ->
          extension_error!(mount, :flow_constraints, reason)

        other ->
          extension_error!(mount, :flow_constraints, {:invalid_reply, other})
      end
    else
      {[], opts}
    end
  end

  @doc """
  Merges infrastructure defaults contributed by compiled extensions.

  An explicit Agent option wins over an extension default. Two extensions may
  not silently contribute the same key, even when the Agent overrides it,
  because that would leave the selected implementation ambiguous.
  """
  @spec merge_agent_config(keyword(), [Mount.t()]) :: keyword()
  def merge_agent_config(config, mounts) when is_list(config) and is_list(mounts) do
    unless Keyword.keyword?(config),
      do: raise(ArgumentError, "Spectre Agent configuration must be a keyword list")

    {defaults, _owners} = Enum.reduce(mounts, {[], %{}}, &merge_mount_config/2)

    defaults |> Enum.reverse() |> Keyword.merge(config)
  end

  @doc false
  @spec agent_config(Mount.t()) :: keyword()
  def agent_config(%Mount{} = mount) do
    ensure_loaded!(mount)

    config =
      if function_exported?(mount.module, :agent_config, 1) do
        module = mount.module
        module.agent_config(extension_config(mount))
      else
        []
      end

    if is_list(config) and Keyword.keyword?(config),
      do: config,
      else: extension_error!(mount, :agent_config, {:invalid_reply, config})
  end

  @doc """
  Lets mounted extensions translate one package-local handler form into the
  ordinary Agent handler AST.

  This is the namespace-safe alternative to importing every package verb into
  the Agent module. Exactly zero or one extension may claim a form.
  """
  @spec expand_handler(module(), Macro.t(), Macro.Env.t()) :: {:ok, Macro.t()} | :ignore
  def expand_handler(owner, handler, %Macro.Env{} = caller) when is_atom(owner) do
    matches =
      owner
      |> Module.get_attribute(:spectre_extensions)
      |> List.wrap()
      |> Enum.reverse()
      |> Enum.flat_map(&expand_handler_mount(&1, handler, caller))

    case matches do
      [] ->
        :ignore

      [{_mount, expanded}] ->
        {:ok, expanded}

      claimed ->
        ids = Enum.map(claimed, fn {mount, _expanded} -> mount.id end)

        raise ArgumentError,
              "multiple Spectre extensions claimed handler #{Macro.to_string(handler)}: " <>
                inspect(ids)
    end
  end

  @doc """
  Fetches one compiled extension mount from an Agent definition.
  """
  @spec fetch(module(), term()) :: {:ok, Mount.t()} | {:error, term()}
  def fetch(agent, id) when is_atom(agent) do
    with {:ok, definition} <- Spectre.Definition.fetch(agent) do
      case Enum.find(definition.extensions, &(&1.id == id)) do
        %Mount{} = mount -> {:ok, mount}
        nil -> {:error, {:extension_not_mounted, id}}
      end
    end
  end

  @doc """
  Returns the single inference selector contributed to an Agent.
  """
  @spec inference_selector(module()) :: {module(), keyword()} | nil
  def inference_selector(agent) when is_atom(agent) do
    selectors =
      agent
      |> Spectre.Definition.fetch!()
      |> Map.fetch!(:extensions)
      |> Enum.map(&inference_selector/1)
      |> Enum.reject(&is_nil/1)

    case selectors do
      [] -> nil
      [selector] -> selector
      many -> raise ArgumentError, "multiple inference selectors configured: #{inspect(many)}"
    end
  end

  @doc false
  @spec inference_selector(Mount.t()) :: {module(), keyword()} | nil
  def inference_selector(%Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :inference_selector, 1) do
      module = mount.module
      normalize_planner!(module.inference_selector(extension_config(mount)))
    else
      nil
    end
  end

  @doc """
  Returns provider mounts contributed by an extension.
  """
  @spec action_providers(Mount.t()) :: [ProviderMount.t()]
  def action_providers(%Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :action_providers, 1) do
      module = mount.module

      module.action_providers(extension_config(mount))
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
      normalize_planner!(module.action_planner(extension_config(mount)))
    else
      nil
    end
  end

  @doc """
  Returns non-action effect executors contributed by an extension.

  Each executor owns exactly one effect `kind`. Core retains effect ownership,
  policy, persistence, idempotency, replay, and terminal lifecycle mutation;
  the contributed module performs only the external capability call.
  """
  @spec effect_executors(Mount.t()) :: [ExecutorMount.t()]
  def effect_executors(%Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :effect_executors, 1) do
      module = mount.module

      module.effect_executors(extension_config(mount))
      |> List.wrap()
      |> Enum.map(&normalize_executor!/1)
    else
      []
    end
  end

  @spec normalize_provider!(ProviderMount.t() | tuple()) :: ProviderMount.t()
  defp normalize_provider!(%ProviderMount{} = mount), do: mount
  defp normalize_provider!({id, module}), do: ProviderMount.new(id, module, [])
  defp normalize_provider!({id, module, opts}), do: ProviderMount.new(id, module, opts)

  defp normalize_provider!(other),
    do: raise(ArgumentError, "invalid action provider contribution: #{inspect(other)}")

  @spec normalize_executor!(ExecutorMount.t() | tuple()) :: ExecutorMount.t()
  defp normalize_executor!(%ExecutorMount{} = mount), do: mount
  defp normalize_executor!({kind, module}), do: ExecutorMount.new(kind, module, [])
  defp normalize_executor!({kind, module, opts}), do: ExecutorMount.new(kind, module, opts)

  defp normalize_executor!(other),
    do: raise(ArgumentError, "invalid effect executor contribution: #{inspect(other)}")

  @spec normalize_constraint!(FlowConstraint.t() | map() | keyword()) :: FlowConstraint.t()
  defp normalize_constraint!(%FlowConstraint{} = constraint), do: constraint
  defp normalize_constraint!(constraint), do: FlowConstraint.new(constraint)

  @spec validate_registration!(module(), module(), keyword()) :: :ok
  defp validate_registration!(owner, extension, opts) do
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

    :ok
  end

  @spec register_mount!(module(), module(), keyword(), Mount.t(), Mount.t() | nil) :: :ok
  defp register_mount!(owner, _extension, _opts, mount, nil) do
    setup!(owner, mount)
    Module.put_attribute(owner, :spectre_extensions, mount)
    :ok
  end

  defp register_mount!(
         owner,
         extension,
         [],
         mount,
         %Mount{module: existing_module, opts: existing_opts} = existing
       )
       when extension == existing_module and is_list(existing_opts) do
    if Keyword.has_key?(existing_opts, :stack_ref),
      do: :ok,
      else: duplicate_extension!(owner, mount, existing)
  end

  defp register_mount!(owner, _extension, _opts, mount, %Mount{} = existing),
    do: duplicate_extension!(owner, mount, existing)

  @spec merge_mount_config(Mount.t(), {[term()], map()}) :: {[term()], map()}
  defp merge_mount_config(%Mount{} = mount, {defaults, owners}) do
    Enum.reduce(agent_config(mount), {defaults, owners}, fn entry, accumulated ->
      merge_config_entry(entry, accumulated, mount)
    end)
  end

  @spec merge_config_entry({term(), term()}, {[term()], map()}, Mount.t()) ::
          {[term()], map()}
  defp merge_config_entry({key, value}, {entries, seen}, %Mount{} = mount) do
    case Map.fetch(seen, key) do
      :error ->
        {[{key, value} | entries], Map.put(seen, key, mount.id)}

      {:ok, owner} ->
        raise ArgumentError,
              "extensions #{inspect(owner)} and #{inspect(mount.id)} both " <>
                "contribute Agent configuration #{inspect(key)}"
    end
  end

  @spec expand_handler_mount(Mount.t(), Macro.t(), Macro.Env.t()) ::
          [{Mount.t(), Macro.t()}]
  defp expand_handler_mount(%Mount{} = mount, handler, caller) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :expand_handler, 3),
      do: call_expand_handler(mount, handler, caller),
      else: []
  end

  @spec call_expand_handler(Mount.t(), Macro.t(), Macro.Env.t()) ::
          [{Mount.t(), Macro.t()}]
  defp call_expand_handler(%Mount{} = mount, handler, caller) do
    module = mount.module

    case module.expand_handler(handler, caller, mount.opts) do
      :ignore -> []
      {:ok, expanded} -> [{mount, expanded}]
      {:error, reason} -> extension_error!(mount, :expand_handler, reason)
      other -> extension_error!(mount, :expand_handler, {:invalid_reply, other})
    end
  end

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

  @spec setup!(module(), Mount.t()) :: :ok
  defp setup!(_owner, %Mount{api_version: 0}), do: :ok

  defp setup!(owner, %Mount{} = mount) do
    ensure_loaded!(mount)

    if function_exported?(mount.module, :setup, 2) do
      module = mount.module

      case module.setup(owner, mount.opts) do
        :ok -> :ok
        {:error, reason} -> extension_error!(mount, :setup, reason)
        other -> extension_error!(mount, :setup, {:invalid_reply, other})
      end
    else
      :ok
    end
  end

  @spec extension_config(Mount.t()) :: term()
  defp extension_config(%Mount{api_version: 0, opts: opts}), do: opts
  defp extension_config(%Mount{compiled: compiled}), do: compiled

  @spec ensure_supported_api!(Mount.t()) :: :ok
  defp ensure_supported_api!(%Mount{api_version: version}) when version in [0, @api_version],
    do: :ok

  defp ensure_supported_api!(%Mount{} = mount) do
    raise ArgumentError,
          "unsupported Spectre extension API #{inspect(mount.api_version)} for " <>
            inspect(mount.module)
  end

  @spec extension_error!(Mount.t(), atom(), term()) :: no_return()
  defp extension_error!(%Mount{} = mount, callback, reason) do
    raise ArgumentError,
          "Spectre extension #{inspect(mount.id)} #{callback} failed: #{inspect(reason)}"
  end

  @spec duplicate_extension!(module(), Mount.t(), Mount.t()) :: no_return()
  defp duplicate_extension!(owner, mount, existing) do
    raise ArgumentError,
          "duplicate Spectre extension #{inspect(mount.id)} in #{inspect(owner)}: " <>
            "#{inspect(existing.module)} and #{inspect(mount.module)}"
  end

  @spec ensure_loaded!(Mount.t()) :: :ok
  defp ensure_loaded!(%Mount{} = mount) do
    unless Code.ensure_loaded?(mount.module),
      do: raise(ArgumentError, "unknown Spectre extension module: #{inspect(mount.module)}")

    :ok
  end
end
