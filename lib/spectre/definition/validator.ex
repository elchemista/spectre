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
    :state,
    :memory,
    :model,
    :classifier,
    :embedding,
    :input_pipeline,
    :journal,
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

  @doc """
  Validates a compiled definition and raises `ArgumentError` on invalid DSL.
  """
  @spec validate!(map()) :: Definition.t()
  def validate!(%Definition{} = definition) do
    with :ok <- validate_kind(definition),
         :ok <- validate_identity(definition),
         :ok <- validate_version(definition),
         :ok <- validate_skill_config(definition),
         :ok <- validate_router(definition),
         :ok <- validate_rules(definition),
         :ok <- validate_policies(definition),
         :ok <- validate_injections(definition),
         :ok <- validate_mounts(definition),
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

  defp valid_handler?({kind, value, opts})
       when kind in [:run, :action] and is_atom(value) and is_list(opts),
       do: true

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
  defp handler_injection_scopes(rules) do
    Enum.flat_map(rules, fn rule ->
      case Map.get(rule, :handler) do
        {kind, _value, opts} when kind in [:ask, :reply] ->
          [
            {{:handler, Map.get(rule, :label)},
             Operation.normalize(Keyword.get(opts, :inject), :handler)}
          ]

        {_kind, _value, opts} ->
          if Keyword.has_key?(opts, :inject) do
            raise ArgumentError, "inject: is only supported by ask/reply handlers"
          else
            []
          end

        _handler ->
          []
      end
    end)
  end

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
              not is_atom(name) or not is_atom(target) or
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
