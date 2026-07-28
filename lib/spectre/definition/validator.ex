defmodule Spectre.Definition.Validator do
  @moduledoc """
  Compile-time validation for Agent definitions and mounted Skills.
  """

  alias Spectre.Definition
  alias Spectre.Prompt.Operation
  alias Spectre.Skill.Mount

  @supported_skill_versions [1]
  @skill_forbidden_config [
    :actions,
    :action_providers,
    :action_planner,
    :state,
    :memory,
    :turn_handlers,
    :model,
    :classifier,
    :embedding,
    :stack,
    :input_pipeline,
    :journal,
    :history,
    :chat_history_limit,
    :idle,
    :shutdown,
    :fail
  ]

  @router_steps [
    :regex,
    :bag,
    :jaro,
    :embedding,
    :semantic_cache,
    :classifier,
    :llm,
    :llm_classifier,
    :arbitrate,
    :terminalize
  ]

  # `Definition.t()` describes the valid compiled shape, while this validator
  # deliberately exercises malformed structs received from dynamic or test
  # construction. Dialyzer therefore sees these defensive fallback clauses as
  # unreachable in the production call graph even though they are public-boundary
  # validation covered by tests.
  @dialyzer {:nowarn_function, validate_router: 1}
  @dialyzer {:nowarn_function, validate_rules: 1}
  @dialyzer {:nowarn_function, validate_policies: 1}
  @dialyzer {:nowarn_function, validate_requirement_list: 1}
  @dialyzer {:nowarn_function, validate_protections: 1}
  @dialyzer {:nowarn_function, validate_extensions: 1}

  @doc """
  Validates a compiled definition and raises `ArgumentError` on invalid DSL.
  """
  @spec validate!(map()) :: Definition.t()
  def validate!(%Definition{} = definition) do
    with :ok <- validate_kind(definition),
         :ok <- validate_identity(definition),
         :ok <- validate_version(definition),
         :ok <- validate_skill_config(definition),
         :ok <- validate_stack(definition),
         :ok <- validate_turn_handlers(definition),
         :ok <- validate_skill_router(definition),
         :ok <- validate_router(definition),
         :ok <- validate_rules(definition),
         :ok <- validate_policies(definition),
         :ok <- validate_injections(definition),
         :ok <- validate_mounts(definition),
         :ok <- validate_extensions(definition),
         :ok <- validate_requirements(definition),
         :ok <- validate_protections(definition) do
      definition
    else
      {:error, reason} ->
        raise ArgumentError,
              "invalid Spectre #{definition.kind} definition #{inspect(definition.owner)}: " <>
                format_reason(reason)
    end
  end

  @spec validate_kind(map()) :: :ok | {:error, term()}
  defp validate_kind(%Definition{kind: kind}) when kind in [:agent, :skill], do: :ok
  defp validate_kind(%Definition{kind: kind}), do: {:error, {:invalid_kind, kind}}

  @spec validate_identity(map()) :: :ok | {:error, term()}
  defp validate_identity(%Definition{id: nil}), do: {:error, :missing_id}

  defp validate_identity(%Definition{version: version})
       when not is_integer(version) or version < 1,
       do: {:error, {:invalid_version, version}}

  defp validate_identity(%Definition{owner: owner}) when not is_atom(owner),
    do: {:error, {:invalid_owner, owner}}

  defp validate_identity(%Definition{prompt_root: root}) when not is_binary(root),
    do: {:error, {:invalid_prompt_root, root}}

  defp validate_identity(%Definition{}), do: :ok

  @spec validate_version(map()) :: :ok | {:error, term()}
  defp validate_version(%Definition{kind: :skill, version: version})
       when version not in @supported_skill_versions,
       do: {:error, {:unsupported_skill_version, version, @supported_skill_versions}}

  defp validate_version(%Definition{}), do: :ok

  @spec validate_skill_config(map()) :: :ok | {:error, term()}
  defp validate_skill_config(%Definition{kind: :skill, config: config}) do
    case Enum.find(@skill_forbidden_config, &Keyword.has_key?(config, &1)) do
      nil -> :ok
      key -> {:error, {:skill_cannot_configure_agent_infrastructure, key}}
    end
  end

  defp validate_skill_config(%Definition{}), do: :ok

  @spec validate_stack(Definition.t()) :: :ok | {:error, term()}
  defp validate_stack(%Definition{stack: nil}), do: :ok

  defp validate_stack(%Definition{kind: :agent, stack: stack})
       when is_atom(stack) and not is_nil(stack),
       do: :ok

  defp validate_stack(%Definition{stack: stack}),
    do: {:error, {:invalid_stack, stack}}

  @spec validate_turn_handlers(Definition.t()) :: :ok | {:error, term()}
  defp validate_turn_handlers(%Definition{config: config}) do
    case Keyword.get(config, :turn_handlers) do
      value when value in [nil, false] ->
        :ok

      handlers when is_list(handlers) ->
        validate_turn_handler_list(handlers, 0)

      invalid ->
        {:error, {:invalid_turn_handlers, invalid}}
    end
  end

  @spec validate_turn_handler_list([term()], non_neg_integer()) :: :ok | {:error, term()}
  defp validate_turn_handler_list([], _index), do: :ok

  defp validate_turn_handler_list([handler | rest], index) do
    case validate_turn_handler(handler) do
      :ok -> validate_turn_handler_list(rest, index + 1)
      {:error, reason} -> {:error, {:invalid_turn_handler, index, reason}}
    end
  end

  @spec validate_turn_handler(term()) :: :ok | {:error, term()}
  defp validate_turn_handler(handler) when is_atom(handler) and not is_nil(handler), do: :ok

  defp validate_turn_handler({handler, opts})
       when is_atom(handler) and not is_nil(handler) and is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_options, opts}}
  end

  defp validate_turn_handler(handler), do: {:error, {:invalid_spec, handler}}

  @spec validate_skill_router(map()) :: :ok | {:error, term()}
  defp validate_skill_router(%Definition{kind: :skill, router: []}), do: :ok

  defp validate_skill_router(%Definition{kind: :skill, router: router}),
    do: {:error, {:skill_cannot_configure_agent_infrastructure, {:router, router}}}

  defp validate_skill_router(%Definition{}), do: :ok

  @spec validate_router(map()) :: :ok | {:error, term()}
  defp validate_router(%Definition{router: router}) when is_list(router) do
    case Enum.find(List.wrap(Keyword.get(router, :via, [])), &(&1 not in @router_steps)) do
      nil -> :ok
      step -> {:error, {:unknown_router_step, step}}
    end
  end

  defp validate_router(%Definition{router: router}), do: {:error, {:invalid_router, router}}

  @spec validate_rules(map()) :: :ok | {:error, term()}
  defp validate_rules(%Definition{rules: rules}) when is_list(rules) do
    labels = Enum.map(rules, &Map.get(&1, :label))

    cond do
      invalid = Enum.find(labels, &(not is_atom(&1))) ->
        {:error, {:invalid_rule_label, invalid}}

      duplicate = duplicate(labels) ->
        {:error, {:duplicate_rule_label, duplicate}}

      invalid = Enum.find(rules, &(not valid_handler?(Map.get(&1, :handler)))) ->
        {:error, {:invalid_rule_handler, Map.get(invalid, :label), Map.get(invalid, :handler)}}

      true ->
        :ok
    end
  end

  defp validate_rules(%Definition{rules: rules}), do: {:error, {:invalid_rules, rules}}

  @spec valid_handler?(term()) :: boolean()
  defp valid_handler?({kind, value, opts})
       when kind in [:ask, :reply] and not is_nil(value) and is_list(opts),
       do: true

  defp valid_handler?({:run, value, opts}) when is_atom(value) and is_list(opts), do: true

  defp valid_handler?({:action, value, opts}) when is_list(opts),
    do: Spectre.Action.valid_ref?(value)

  defp valid_handler?(_handler), do: false

  @spec validate_policies(map()) :: :ok | {:error, term()}
  defp validate_policies(%Definition{policies: policies}) when is_map(policies) do
    case Enum.find(policies, fn {name, policy} ->
           not is_atom(name) or Map.get(policy, :name) != name
         end) do
      nil -> :ok
      invalid -> {:error, {:invalid_policy, invalid}}
    end
  end

  defp validate_policies(%Definition{policies: policies}),
    do: {:error, {:invalid_policies, policies}}

  @spec validate_injections(map()) :: :ok | {:error, term()}
  defp validate_injections(%Definition{} = definition) do
    scopes =
      [{:definition, definition.injections}] ++
        flow_injection_scopes(definition.rules) ++ handler_injection_scopes(definition.rules)

    Enum.reduce_while(scopes, :ok, fn {scope, operations}, :ok ->
      case validate_injection_scope(scope, operations) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  rescue
    exception in ArgumentError -> {:error, {:invalid_injection, Exception.message(exception)}}
  end

  @spec flow_injection_scopes([map()]) :: [{term(), [Operation.t()]}]
  defp flow_injection_scopes(rules) do
    rules
    |> Enum.reject(&is_nil(Map.get(&1, :flow)))
    |> Enum.uniq_by(&Map.get(&1, :flow))
    |> Enum.map(&{{:flow, Map.get(&1, :flow)}, Map.get(&1, :injections, [])})
  end

  @spec handler_injection_scopes([map()]) :: [{term(), [Operation.t()]}]
  defp handler_injection_scopes(rules), do: Enum.flat_map(rules, &handler_injection_scope/1)

  @spec handler_injection_scope(map()) :: [{term(), [Operation.t()]}]
  defp handler_injection_scope(%{handler: {:ask, _value, opts}} = rule) do
    [
      {{:handler, Map.get(rule, :label)},
       Operation.normalize(Keyword.get(opts, :inject), :handler)}
    ]
  end

  defp handler_injection_scope(%{handler: {_kind, _value, opts}}) do
    if Keyword.has_key?(opts, :inject) do
      raise ArgumentError, "inject: is only supported by ask handlers"
    else
      []
    end
  end

  defp handler_injection_scope(_rule), do: []

  @spec validate_injection_scope(term(), [Operation.t()]) :: :ok | {:error, term()}
  defp validate_injection_scope(scope, operations) when is_list(operations) do
    if Enum.all?(operations, &match?(%Operation{}, &1)) do
      ids = Enum.map(operations, & &1.id)

      replacement =
        operations
        |> Enum.filter(&(&1.position == :replace and is_nil(&1.condition)))
        |> Enum.group_by(& &1.target)
        |> Enum.find(fn {_target, scoped} -> length(scoped) > 1 end)

      cond do
        duplicate = duplicate(ids) ->
          {:error, {:duplicate_injection, scope, duplicate}}

        not is_nil(replacement) ->
          {target, _operations} = replacement
          {:error, {:duplicate_unconditional_replacement, scope, target}}

        true ->
          :ok
      end
    else
      {:error, {:invalid_injection_operation, scope}}
    end
  end

  defp validate_injection_scope(scope, operations),
    do: {:error, {:invalid_injections, scope, operations}}

  @spec validate_mounts(map()) :: :ok | {:error, term()}
  defp validate_mounts(%Definition{kind: :skill, skills: []}), do: :ok
  defp validate_mounts(%Definition{kind: :skill}), do: {:error, :nested_skills_not_supported}

  defp validate_mounts(%Definition{skills: mounts}) do
    ids = Enum.map(mounts, & &1.id)

    cond do
      not Enum.all?(mounts, &match?(%Mount{}, &1)) ->
        {:error, :invalid_skill_mount}

      duplicate = duplicate(ids) ->
        {:error, {:duplicate_skill_mount, duplicate}}

      invalid = Enum.find(ids, &(not valid_mount_id?(&1))) ->
        {:error, {:invalid_skill_mount_id, invalid}}

      true ->
        validate_mount_bindings(mounts)
    end
  end

  @spec validate_mount_bindings([Mount.t()]) :: :ok | {:error, term()}
  defp validate_mount_bindings(mounts) do
    Enum.reduce_while(mounts, :ok, fn mount, :ok ->
      skill = Definition.fetch!(mount.module)
      requirement_names = MapSet.new(skill.requirements, & &1.name)

      cond do
        requirement = Enum.find(skill.requirements, &missing_binding?(&1, mount.bindings)) ->
          {:halt, {:error, {:missing_skill_binding, mount.id, requirement.name}}}

        invalid =
            Enum.find(mount.bindings, fn {name, target} ->
              not is_atom(name) or not Spectre.Action.valid_ref?(target) or
                  not MapSet.member?(requirement_names, name)
            end) ->
          {:halt, {:error, {:invalid_skill_binding, mount.id, invalid}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @spec missing_binding?(map(), map()) :: boolean()
  defp missing_binding?(%{name: name}, bindings), do: not Map.has_key?(bindings, name)

  @spec valid_mount_id?(term()) :: boolean()
  defp valid_mount_id?(id), do: is_atom(id) or is_binary(id) or is_integer(id)

  @spec validate_extensions(Definition.t()) :: :ok | {:error, term()}
  defp validate_extensions(%Definition{kind: :skill, extensions: []}), do: :ok

  defp validate_extensions(%Definition{kind: :skill, extensions: [_first | _rest]}),
    do: {:error, :skills_cannot_mount_extensions}

  defp validate_extensions(%Definition{extensions: extensions}) when is_list(extensions) do
    if Enum.all?(extensions, &match?(%Spectre.Extension.Mount{}, &1)) do
      case extensions |> Enum.map(& &1.id) |> duplicate() do
        nil -> :ok
        duplicate -> {:error, {:duplicate_extension, duplicate}}
      end
    else
      {:error, :invalid_extension_mount}
    end
  end

  defp validate_extensions(%Definition{extensions: extensions}),
    do: {:error, {:invalid_extensions, extensions}}

  @spec validate_requirements(map()) :: :ok | {:error, term()}
  defp validate_requirements(%Definition{kind: :agent, requirements: [_first | _rest]}),
    do: {:error, :action_requirements_are_skill_only}

  defp validate_requirements(%Definition{kind: :skill, requirements: requirements} = definition) do
    with :ok <- validate_requirement_list(requirements) do
      validate_skill_action_requirements(definition, requirements)
    end
  end

  defp validate_requirements(%Definition{requirements: requirements}),
    do: validate_requirement_list(requirements)

  @spec validate_requirement_list(term()) :: :ok | {:error, term()}
  defp validate_requirement_list(requirements) when is_list(requirements) do
    names = Enum.map(requirements, &Map.get(&1, :name))

    cond do
      invalid = Enum.find(requirements, &(not valid_requirement?(&1))) ->
        {:error, {:invalid_requirement, invalid}}

      name = duplicate(names) ->
        {:error, {:duplicate_requirement, name}}

      true ->
        :ok
    end
  end

  defp validate_requirement_list(requirements),
    do: {:error, {:invalid_requirements, requirements}}

  @spec validate_skill_action_requirements(map(), [map()]) ::
          :ok | {:error, term()}
  defp validate_skill_action_requirements(definition, requirements) do
    declared = MapSet.new(requirements, & &1.name)

    case Enum.find(skill_action_references(definition), &(not MapSet.member?(declared, &1))) do
      nil -> :ok
      action -> {:error, {:undeclared_skill_action, action}}
    end
  end

  @spec skill_action_references(map()) :: [term()]
  defp skill_action_references(definition) do
    rule_actions =
      Enum.flat_map(definition.rules, fn rule ->
        case Map.get(rule, :handler) do
          {:action, action, _opts} -> [action]
          _handler -> []
        end
      end)

    configured_actions =
      Enum.map(definition.protections ++ definition.after_actions, &Map.get(&1, :action))

    Enum.uniq(rule_actions ++ configured_actions)
  end

  @spec valid_requirement?(term()) :: boolean()
  defp valid_requirement?(%{name: name, mode: mode})
       when is_atom(name) and mode in [:read, :write, :destructive],
       do: true

  defp valid_requirement?(_requirement), do: false

  @spec validate_protections(map()) :: :ok | {:error, term()}
  defp validate_protections(%Definition{
         kind: :skill,
         protections: protections,
         policies: policies
       })
       when is_list(protections) do
    case Enum.find(protections, fn protection ->
           not is_map(protection) or not Map.has_key?(protection, :action) or
             not Map.has_key?(policies, Map.get(protection, :policy))
         end) do
      nil -> :ok
      protection -> {:error, {:invalid_protection, protection}}
    end
  end

  defp validate_protections(%Definition{protections: protections}) when is_list(protections) do
    case Enum.find(protections, fn protection ->
           not is_map(protection) or not Map.has_key?(protection, :action) or
             not Map.has_key?(protection, :policy)
         end) do
      nil -> :ok
      protection -> {:error, {:invalid_protection, protection}}
    end
  end

  defp validate_protections(%Definition{protections: protections}),
    do: {:error, {:invalid_protections, protections}}

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

  @spec format_reason(term()) :: String.t()
  defp format_reason({:missing_skill_binding, mount, requirement}) do
    "Skill #{inspect(mount)} requires a binding for #{inspect(requirement)}"
  end

  defp format_reason({:undeclared_skill_action, action}) do
    "Skill action #{inspect(action)} must be declared with requires_action/2"
  end

  defp format_reason({:unknown_router_step, step}),
    do: "unknown router via step #{inspect(step)}"

  defp format_reason({:duplicate_unconditional_replacement, scope, target}),
    do: "multiple unconditional prompt replacements for #{inspect(target)} in #{inspect(scope)}"

  defp format_reason(reason), do: inspect(reason)
end
