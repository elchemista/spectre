defmodule Spectre.Definition do
  @moduledoc """
  Compiled behavioral description shared by Agents and Skills.

  Agent and Skill DSL modules compile their declarations once and expose one
  immutable definition. Runtime code uses this module to resolve scoped rules,
  policies, prompt roots, protections, hooks, and mounted Skill configuration
  without flattening away ownership.
  """

  alias Spectre.Extension.Mount, as: ExtensionMount
  alias Spectre.Skill.Mount
  alias Spectre.Stack.Ref

  @version 1

  defstruct kind: :agent,
            id: nil,
            version: @version,
            owner: nil,
            stack: nil,
            stack_refs: [],
            prompt_root: "priv/spectre/prompts",
            config: [],
            router: [],
            rules: [],
            policies: %{},
            protections: [],
            after_actions: [],
            injections: [],
            requirements: [],
            skills: [],
            extensions: []

  @type kind :: :agent | :skill
  @type scope :: :agent | {:skill, term()}

  @type t :: %__MODULE__{
          kind: kind(),
          id: term(),
          version: pos_integer(),
          owner: module(),
          stack: module() | nil,
          stack_refs: [Ref.t()],
          prompt_root: String.t(),
          config: keyword(),
          router: keyword(),
          rules: [map()],
          policies: map(),
          protections: [map()],
          after_actions: [map()],
          injections: [term()],
          requirements: [map()],
          skills: [Mount.t()],
          extensions: [ExtensionMount.t()]
        }

  @doc """
  Builds a normalized compiled definition.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = Map.take(attrs, fields())
    definition = struct(__MODULE__, attrs)

    %{
      definition
      | prompt_root:
          definition.prompt_root ||
            Keyword.get(definition.config, :prompt_root, "priv/spectre/prompts")
    }
  end

  @doc """
  Returns the compiled definition exposed by a DSL module.

  Legacy Agent modules that only expose the original metadata callbacks are
  normalized into a definition so runtime callers have one access path.
  """
  @spec fetch(module()) :: {:ok, t()} | {:error, term()}
  def fetch(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded?(module) do
      true -> fetch_loaded(module)
      false -> {:error, {:unknown_spectre_definition, module}}
    end
  rescue
    exception -> {:error, {:definition_exception, module, exception.__struct__}}
  catch
    kind, reason -> {:error, {:definition_failure, module, kind, reason}}
  end

  @spec fetch_loaded(module()) :: {:ok, t()} | {:error, term()}
  defp fetch_loaded(module) do
    if function_exported?(module, :__spectre_definition__, 0) do
      normalize_definition(module, module.__spectre_definition__())
    else
      legacy_definition(module)
    end
  end

  @doc """
  Returns a definition or raises an `ArgumentError` with a stable reason.
  """
  @spec fetch!(module()) :: t()
  def fetch!(module) do
    case fetch(module) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid Spectre definition: #{inspect(reason)}"
    end
  end

  @doc """
  Returns every rule visible to an Agent with mount ownership materialized.
  """
  @spec rules(module()) :: [map()]
  def rules(agent) do
    definition = fetch!(agent)

    own = materialize_rules(definition.rules, definition.owner, :agent, %{}, %{}, [])

    mounted =
      Enum.flat_map(definition.skills, fn mount ->
        skill = fetch!(mount.module)

        materialize_rules(
          skill.rules,
          skill.owner,
          Mount.scope(mount),
          mount.bindings,
          requirement_modes(skill.requirements),
          skill.injections
        )
      end)

    own ++ mounted
  end

  @doc """
  Resolves the definition active for a route scope.
  """
  @spec for_scope(module(), scope()) :: {:ok, t()} | {:error, term()}
  def for_scope(agent, :agent), do: fetch(agent)

  def for_scope(agent, {:skill, mount_id}) do
    with {:ok, agent_definition} <- fetch(agent),
         %Mount{} = mount <- Enum.find(agent_definition.skills, &(&1.id == mount_id)),
         {:ok, definition} <- fetch(mount.module) do
      {:ok, definition}
    else
      nil -> {:error, {:unknown_skill_mount, agent, mount_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the definition for a scope or raises an `ArgumentError`.
  """
  @spec for_scope!(module(), scope()) :: t()
  def for_scope!(agent, scope) do
    case for_scope(agent, scope) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid Spectre scope: #{inspect(reason)}"
    end
  end

  @doc """
  Resolves an owning module's prompt root within an Agent composition.
  """
  @spec prompt_root(module(), scope()) :: {:ok, String.t()} | {:error, term()}
  def prompt_root(agent, scope) do
    with {:ok, definition} <- for_scope(agent, scope) do
      {:ok, definition.prompt_root}
    end
  end

  @doc """
  Returns Agent injections followed by the active Skill injections.

  Scope-specific ordering is handled later by `Spectre.Prompt.Plan`; this
  function only selects definitions participating in the current route.
  """
  @spec injections(module(), scope()) :: [term()]
  def injections(agent, :agent), do: materialize_injections(fetch!(agent).injections, :agent)

  def injections(agent, {:skill, _mount_id} = scope) do
    materialize_injections(fetch!(agent).injections, :agent) ++
      materialize_injections(for_scope!(agent, scope).injections, scope)
  end

  @doc """
  Returns every protection visible to an Agent with Skill action bindings and
  scoped policy references applied.
  """
  @spec protections(module()) :: [map()]
  def protections(agent) do
    definition = fetch!(agent)

    own = Enum.map(definition.protections, &materialize_protection(&1, :agent, %{}))

    mounted =
      Enum.flat_map(definition.skills, fn mount ->
        scope = Mount.scope(mount)

        mount.module
        |> fetch!()
        |> Map.fetch!(:protections)
        |> Enum.map(&materialize_protection(&1, scope, mount.bindings))
      end)

    own ++ mounted
  end

  @doc """
  Returns every Agent and mounted-Skill action hook after logical binding.
  """
  @spec after_actions(module()) :: [map()]
  def after_actions(agent) do
    definition = fetch!(agent)

    own =
      Enum.map(
        definition.after_actions,
        &materialize_action_hook(&1, definition.owner, :agent, %{})
      )

    mounted =
      Enum.flat_map(definition.skills, fn mount ->
        skill = fetch!(mount.module)
        scope = Mount.scope(mount)

        Enum.map(
          skill.after_actions,
          &materialize_action_hook(&1, skill.owner, scope, mount.bindings)
        )
      end)

    own ++ mounted
  end

  @doc """
  Resolves a policy reference to its definition and owning scope.

  Legacy atom references resolve in Agent scope. Skill policy references are
  represented as `{{:skill, mount_id}, policy_name}`.
  """
  @spec policy(module(), term()) :: {:ok, map(), scope()} | {:error, term()}
  def policy(agent, name) when is_atom(name) do
    find_policy(agent, :agent, name)
  end

  def policy(agent, {{:skill, _mount_id} = scope, name}) when is_atom(name) do
    find_policy(agent, scope, name)
  end

  def policy(_agent, reference), do: {:error, {:invalid_policy_reference, reference}}

  @doc """
  Returns a stable policy reference for a scope.
  """
  @spec policy_ref(scope(), atom()) :: atom() | {scope(), atom()}
  def policy_ref(:agent, name) when is_atom(name), do: name
  def policy_ref({:skill, _mount_id} = scope, name) when is_atom(name), do: {scope, name}

  @doc """
  Returns the local policy name from a scoped reference.
  """
  @spec policy_name(term()) :: atom() | nil
  def policy_name(name) when is_atom(name), do: name
  def policy_name({{:skill, _mount_id}, name}) when is_atom(name), do: name
  def policy_name(_reference), do: nil

  @doc """
  Returns the scope carried by a policy reference.
  """
  @spec policy_scope(term()) :: scope()
  def policy_scope({{:skill, _mount_id} = scope, name}) when is_atom(name), do: scope
  def policy_scope(_reference), do: :agent

  @doc """
  Returns the mount for a scope when it exists.
  """
  @spec mount(module(), scope()) :: Mount.t() | nil
  def mount(_agent, :agent), do: nil

  def mount(agent, {:skill, mount_id}) do
    agent
    |> fetch!()
    |> Map.fetch!(:skills)
    |> Enum.find(&(&1.id == mount_id))
  end

  @spec normalize_definition(module(), term()) :: {:ok, t()} | {:error, term()}
  defp normalize_definition(module, %__MODULE__{owner: module} = definition) do
    {:ok, definition |> Map.from_struct() |> new()}
  end

  defp normalize_definition(module, %__MODULE__{} = definition) do
    {:ok, definition |> Map.from_struct() |> Map.put(:owner, definition.owner || module) |> new()}
  end

  defp normalize_definition(module, attrs) when is_map(attrs),
    do: {:ok, attrs |> Map.put_new(:owner, module) |> new()}

  defp normalize_definition(module, other),
    do: {:error, {:invalid_definition_reply, module, reply_shape(other)}}

  @spec legacy_definition(module()) :: {:ok, t()} | {:error, term()}
  defp legacy_definition(module) do
    if function_exported?(module, :__spectre_config__, 0) do
      config = module.__spectre_config__()

      {:ok,
       new(%{
         id: module,
         owner: module,
         config: config,
         router: optional_callback(module, :__spectre_router__, []),
         rules: optional_callback(module, :__spectre_rules__, []),
         policies: optional_callback(module, :__spectre_policies__, %{}),
         protections: optional_callback(module, :__spectre_protections__, []),
         after_actions: optional_callback(module, :__spectre_after_actions__, []),
         extensions: optional_callback(module, :__spectre_extensions__, []),
         stack: Keyword.get(config, :stack),
         stack_refs: optional_callback(module, :__spectre_stack_refs__, []),
         prompt_root: Keyword.get(config, :prompt_root, "priv/spectre/prompts")
       })}
    else
      {:error, {:unknown_spectre_definition, module}}
    end
  end

  @spec optional_callback(module(), atom(), term()) :: term()
  defp optional_callback(module, function, default) do
    if function_exported?(module, function, 0), do: apply(module, function, []), else: default
  end

  @spec materialize_rules([map()], module(), scope(), map(), map(), [term()]) :: [map()]
  defp materialize_rules(
         rules,
         owner,
         scope,
         bindings,
         requirement_modes,
         definition_injections
       ) do
    Enum.map(rules, fn rule ->
      rule
      |> Map.put(:owner, owner)
      |> Map.put(:scope, scope)
      |> Map.update(
        :handler,
        nil,
        &bind_handler(&1, bindings, requirement_modes, owner, scope)
      )
      |> Map.update(:injections, [], &materialize_rule_injections(&1, scope, rule.flow))
      |> Map.put(:definition_injections, materialize_injections(definition_injections, scope))
    end)
  end

  @spec materialize_rule_injections([term()], scope(), atom() | nil) :: [term()]
  defp materialize_rule_injections(injections, scope, flow) do
    Enum.map(injections, &put_operation_scope(&1, {:flow, scope, flow}))
  end

  @spec materialize_injections([term()], scope()) :: [term()]
  defp materialize_injections(injections, scope) do
    Enum.map(injections, &put_operation_scope(&1, scope))
  end

  @spec put_operation_scope(term(), term()) :: term()
  defp put_operation_scope(%{__struct__: Spectre.Prompt.Operation} = operation, scope),
    do: %{operation | scope: scope}

  defp put_operation_scope(operation, _scope), do: operation

  @spec bind_handler(term(), map(), map(), module(), scope()) :: term()
  defp bind_handler({:action, action, opts}, bindings, requirement_modes, owner, scope) do
    opts =
      case Map.fetch(requirement_modes, action) do
        {:ok, mode} -> Keyword.put_new(opts, :mode, mode)
        :error -> opts
      end

    opts =
      opts
      |> materialize_handler_hooks(owner, scope, bindings)
      |> materialize_handler_policy(scope)

    {:action, Map.get(bindings, action, action), opts}
  end

  defp bind_handler(handler, _bindings, _requirement_modes, _owner, _scope), do: handler

  @spec materialize_handler_hooks(keyword(), module(), scope(), map()) :: keyword()
  defp materialize_handler_hooks(opts, owner, scope, bindings) do
    if Keyword.has_key?(opts, :hooks) do
      Keyword.update!(opts, :hooks, fn hooks ->
        Enum.map(hooks, &materialize_action_hook(&1, owner, scope, bindings))
      end)
    else
      opts
    end
  end

  @spec materialize_handler_policy(keyword(), scope()) :: keyword()
  defp materialize_handler_policy(opts, scope) do
    if Keyword.has_key?(opts, :policy) do
      Keyword.update!(opts, :policy, &materialize_policy_reference(&1, scope))
    else
      opts
    end
  end

  @spec requirement_modes([map()]) :: map()
  defp requirement_modes(requirements) do
    Map.new(requirements, fn requirement -> {requirement.name, requirement.mode} end)
  end

  @spec materialize_protection(map(), scope(), map()) :: map()
  defp materialize_protection(%{action: action, policy: policy} = protection, scope, bindings) do
    protection
    |> Map.put(:action, Map.get(bindings, action, action))
    |> Map.put(:policy, policy_ref(scope, policy))
    |> Map.put(:scope, scope)
  end

  @spec bind_action_field(map(), map()) :: map()
  defp bind_action_field(%{action: action} = value, bindings),
    do: Map.put(value, :action, Map.get(bindings, action, action))

  defp bind_action_field(value, _bindings), do: value

  @spec materialize_action_hook(map(), module(), scope(), map()) :: map()
  defp materialize_action_hook(hook, owner, scope, bindings) do
    hook
    |> bind_action_field(bindings)
    |> Map.put(:scope, scope)
    |> Map.update(:run, nil, fn
      function when is_atom(function) and not is_nil(function) -> {owner, function}
      run -> run
    end)
  end

  @spec materialize_policy_reference(term(), scope()) :: term()
  defp materialize_policy_reference(policy, scope)
       when is_atom(policy) and not is_nil(policy),
       do: policy_ref(scope, policy)

  defp materialize_policy_reference(policy, _scope), do: policy

  @spec find_policy(module(), scope(), atom()) :: {:ok, map(), scope()} | {:error, term()}
  defp find_policy(agent, scope, name) do
    with {:ok, definition} <- for_scope(agent, scope),
         policy when not is_nil(policy) <- Map.get(definition.policies, name) do
      {:ok, policy, scope}
    else
      nil -> {:error, {:unknown_policy, policy_ref(scope, name)}}
      {:error, _reason} = error -> error
    end
  end

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
