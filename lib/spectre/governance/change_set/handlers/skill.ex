defmodule Spectre.Governance.ChangeSet.Handlers.Skill do
  @moduledoc false

  @behaviour Spectre.Governance.ChangeSet.Handler

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.Definition, as: SkillDefinition

  @types ~w(mount_skill replace_skill disable_skill update_skill_config update_applicability)

  @impl true
  def operation_types, do: @types

  @impl true
  def component_classes, do: [:applicability, :compiled_runtime, :skills]

  @impl true
  def apply(%Operation{type: type} = operation, %Composition{} = composition, context)
      when type in @types do
    with :ok <- require_agent(composition.definition) do
      apply_type(type, operation.payload, composition, context)
    end
  end

  def apply(%Operation{type: type}, %Composition{}, _context),
    do: {:error, {:unsupported_skill_governance_operation, type}}

  defp apply_type("mount_skill", payload, composition, context) do
    with :ok <- exact_payload(payload, ~w(mount_id definition bindings opts)),
         {:ok, mount_id} <- stable_name(Map.get(payload, "mount_id"), :mount_id),
         {:ok, definition} <- runtime_definition(Map.get(payload, "definition")),
         :ok <- authorize_definition(definition, context),
         {:ok, bindings} <- optional_map(Map.get(payload, "bindings", %{}), :bindings),
         {:ok, opts} <- optional_map(Map.get(payload, "opts", %{}), :opts),
         {:ok, mounts, component} <- mounts(composition.definition),
         nil <- find_mount(mounts, mount_id),
         mount = mount_data(mount_id, definition, bindings, opts),
         {:ok, canonical} <- replace_mounts(composition.definition, component, mounts ++ [mount]) do
      {:ok,
       Composition.update(composition,
         definition: canonical,
         operation_type: "mount_skill",
         component_classes: [:skills],
         risk: :medium
       )}
    else
      %{} -> {:error, {:skill_mount_already_exists, Map.get(payload, "mount_id")}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_type("replace_skill", payload, composition, context) do
    with :ok <- exact_payload(payload, ~w(mount_id definition bindings opts)),
         {:ok, mount_id} <- stable_name(Map.get(payload, "mount_id"), :mount_id),
         {:ok, definition} <- runtime_definition(Map.get(payload, "definition")),
         :ok <- authorize_definition(definition, context),
         {:ok, mounts, component} <- mounts(composition.definition),
         %{} = previous <- find_mount(mounts, mount_id),
         {:ok, bindings} <-
           optional_map(Map.get(payload, "bindings", get(previous, :bindings, %{})), :bindings),
         {:ok, opts} <- optional_map(Map.get(payload, "opts", get(previous, :opts, %{})), :opts),
         replacement = mount_data(mount_id, definition, bindings, opts),
         next =
           Enum.map(mounts, &if(same_name?(get(&1, :id), mount_id), do: replacement, else: &1)),
         {:ok, canonical} <- replace_mounts(composition.definition, component, next) do
      {:ok,
       Composition.update(composition,
         definition: canonical,
         operation_type: "replace_skill",
         component_classes: [:skills],
         risk: :high
       )}
    else
      nil -> {:error, {:skill_mount_not_found, Map.get(payload, "mount_id")}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_type("disable_skill", payload, composition, _context) do
    with :ok <- exact_payload(payload, ~w(mount_id)),
         {:ok, mount_id} <- stable_name(Map.get(payload, "mount_id"), :mount_id),
         {:ok, mounts, component} <- mounts(composition.definition),
         %{} <- find_mount(mounts, mount_id),
         next = Enum.reject(mounts, &same_name?(get(&1, :id), mount_id)),
         {:ok, canonical} <- replace_mounts(composition.definition, component, next) do
      {:ok,
       Composition.update(composition,
         definition: canonical,
         operation_type: "disable_skill",
         component_classes: [:skills],
         risk: :medium
       )}
    else
      nil -> {:error, {:skill_mount_not_found, Map.get(payload, "mount_id")}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_type("update_skill_config", payload, composition, context) do
    with :ok <- exact_payload(payload, ~w(mount_id changes)),
         {:ok, mount_id} <- stable_name(Map.get(payload, "mount_id"), :mount_id),
         {:ok, changes} <- nonempty_map(Map.get(payload, "changes"), :changes),
         {:ok, allowed_paths} <- mutable_paths(context, mount_id),
         :ok <- permitted_changes(changes, allowed_paths),
         {:ok, mounts, component} <- mounts(composition.definition),
         %{} = mount <- find_mount(mounts, mount_id),
         {:ok, definition} <- mounted_definition(mount),
         {:ok, definition} <- update_config(definition, changes),
         {:ok, replacement} <- update_mount_definition(mount, definition),
         next = replace_mount(mounts, mount_id, replacement),
         {:ok, canonical} <- replace_mounts(composition.definition, component, next) do
      {:ok,
       Composition.update(composition,
         definition: canonical,
         operation_type: "update_skill_config",
         component_classes: [:skills, :compiled_runtime],
         risk: :medium
       )}
    else
      nil -> {:error, {:skill_mount_not_found, Map.get(payload, "mount_id")}}
      {:error, _reason} = error -> error
    end
  end

  defp apply_type("update_applicability", payload, composition, context) do
    with :ok <- exact_payload(payload, ~w(mount_id applicability)),
         {:ok, mount_id} <- stable_name(Map.get(payload, "mount_id"), :mount_id),
         {:ok, applicability} <- Applicability.new(Map.get(payload, "applicability")),
         {:ok, ceiling} <- applicability_ceiling(context, mount_id),
         :ok <- within_applicability_ceiling(applicability, ceiling),
         {:ok, mounts, component} <- mounts(composition.definition),
         %{} = mount <- find_mount(mounts, mount_id),
         {:ok, definition} <- mounted_definition(mount),
         {:ok, definition} <- update_definition_applicability(definition, applicability),
         {:ok, wrapped} <- SkillDefinition.from_canonical(definition),
         {:ok, _evidence} <- SkillDefinition.anti_hijack(wrapped),
         {:ok, replacement} <- update_mount_definition(mount, definition),
         next = replace_mount(mounts, mount_id, replacement),
         {:ok, canonical} <- replace_mounts(composition.definition, component, next) do
      {:ok,
       Composition.update(composition,
         definition: canonical,
         operation_type: "update_applicability",
         component_classes: [:skills, :applicability],
         risk: :high
       )}
    else
      nil -> {:error, {:skill_mount_not_found, Map.get(payload, "mount_id")}}
      {:error, _reason} = error -> error
    end
  end

  defp require_agent(%Canonical{kind: :agent}), do: :ok

  defp require_agent(%Canonical{kind: kind}),
    do: {:error, {:governance_requires_agent_definition, kind}}

  defp runtime_definition(value) do
    with {:ok, definition} <- SkillDefinition.new(value),
         :runtime <- SkillDefinition.origin(definition) do
      {:ok, definition}
    else
      :compiled -> {:error, :governance_skill_requires_runtime_definition}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_definition(definition, context) do
    with %Envelope{} = authority <- Map.get(context, :authority),
         :ok <- authorize_operations(SkillDefinition.operation_refs(definition), authority),
         :ok <- authorize_prompt(definition, authority, context) do
      :ok
    else
      nil -> {:error, :governance_authority_required}
      {:error, _reason} = error -> error
    end
  end

  defp authorize_operations(refs, authority) do
    case Enum.find(refs, fn ref -> not Enum.any?(authority.operations, &same_name?(&1, ref)) end) do
      nil -> :ok
      ref -> {:error, {:governance_operation_authority_exceeded, ref}}
    end
  end

  defp authorize_prompt(definition, authority, context) do
    fragments = SkillDefinition.prompt_fragments(definition)
    budget = SkillDefinition.prompt_budget(definition)
    ceiling = Map.get(context, :prompt_token_ceiling) || Map.get(authority.limits, :max_tokens)

    cond do
      fragments == [] ->
        :ok

      not is_number(ceiling) or ceiling < 0 ->
        {:error, :governance_prompt_budget_not_granted}

      budget.reserved_tokens > ceiling ->
        {:error, {:governance_prompt_budget_exceeded, budget.reserved_tokens, ceiling}}

      fragment =
          Enum.find(fragments, fn fragment ->
            not Enum.any?(authority.prompt_budget_classes, &same_name?(&1, fragment.budget_class))
          end) ->
        {:error, {:governance_prompt_budget_class_not_granted, fragment.budget_class}}

      true ->
        :ok
    end
  end

  defp mounts(definition) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- get(payload, :mounts, []) do
      {:ok, mounts, component}
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_skill_mounts, shape(value)}}
    end
  end

  defp replace_mounts(definition, component, mounts) do
    payload = put(component.payload, :mounts, mounts)

    with {:ok, replacement} <- Component.new(%{component | payload: payload}) do
      components =
        Enum.map(
          definition.components,
          &if(&1.component_type == :skills, do: replacement, else: &1)
        )

      definition |> Map.from_struct() |> Map.put(:components, components) |> Canonical.new()
    end
  end

  defp find_mount(mounts, id), do: Enum.find(mounts, &same_name?(get(&1, :id), id))

  defp replace_mount(mounts, id, replacement),
    do: Enum.map(mounts, &if(same_name?(get(&1, :id), id), do: replacement, else: &1))

  defp mount_data(id, definition, bindings, opts) do
    canonical = SkillDefinition.canonical(definition)

    %{
      "id" => id,
      "definition_ref" => canonical |> Canonical.ref() |> Ref.to_string(),
      "definition" => Canonical.to_data(canonical),
      "bindings" => bindings,
      "opts" => opts
    }
  end

  defp mounted_definition(mount) do
    case get(mount, :definition) do
      value when is_map(value) -> Canonical.from_data(value)
      value -> {:error, {:governance_mount_has_no_runtime_definition, shape(value)}}
    end
  end

  defp update_mount_definition(mount, definition) do
    with {:ok, wrapped} <- SkillDefinition.from_canonical(definition) do
      canonical = SkillDefinition.canonical(wrapped)

      {:ok,
       mount
       |> put(:definition_ref, canonical |> Canonical.ref() |> Ref.to_string())
       |> put(:definition, Canonical.to_data(canonical))}
    end
  end

  defp update_config(definition, changes) do
    with {:ok, component} <- Canonical.fetch_component(definition, :compiled_runtime),
         payload when is_map(payload) <- component.payload,
         {:ok, config} <- config_map(get(payload, :config, %{})),
         {:ok, config} <- apply_config_changes(config, changes),
         {:ok, replacement} <-
           Component.new(%{component | payload: put(payload, :config, config)}) do
      rebuild_skill(definition, :compiled_runtime, replacement)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_skill_config, shape(value)}}
    end
  end

  defp update_definition_applicability(definition, applicability) do
    with {:ok, component} <- Canonical.fetch_component(definition, :applicability),
         payload when is_map(payload) <- component.payload,
         {:ok, replacement} <-
           Component.new(%{
             component
             | payload: put(payload, :declared, Applicability.to_data(applicability))
           }) do
      rebuild_skill(definition, :applicability, replacement)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_skill_applicability, shape(value)}}
    end
  end

  defp rebuild_skill(definition, type, replacement) do
    components =
      Enum.map(definition.components, &if(&1.component_type == type, do: replacement, else: &1))

    definition |> Map.from_struct() |> Map.put(:components, components) |> Canonical.new()
  end

  defp mutable_paths(context, mount_id) do
    paths = context |> Map.get(:mutable_config_paths, %{}) |> fetch_by_name(mount_id)

    if is_list(paths) and paths != [] and Enum.all?(paths, &valid_path?/1),
      do: {:ok, Enum.uniq(paths)},
      else: {:error, {:skill_config_not_mutable, mount_id}}
  end

  defp permitted_changes(changes, allowed) do
    case Enum.find(Map.keys(changes), &(&1 not in allowed)) do
      nil -> :ok
      path -> {:error, {:skill_config_path_not_mutable, path}}
    end
  end

  defp config_map([]), do: {:ok, %{}}
  defp config_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp config_map(value), do: {:error, {:invalid_governance_skill_config, shape(value)}}

  defp apply_config_changes(config, changes) do
    Enum.reduce_while(changes, {:ok, config}, fn {path, value}, {:ok, current} ->
      case put_path(current, String.split(path, ".", trim: true), value) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_path(_map, [], _value), do: {:error, :empty_skill_config_path}
  defp put_path(map, [key], value) when is_map(map), do: {:ok, Map.put(map, key, value)}

  defp put_path(map, [key | rest], value) when is_map(map) do
    child = Map.get(map, key, %{})

    if is_map(child) and not is_struct(child) do
      with {:ok, child} <- put_path(child, rest, value), do: {:ok, Map.put(map, key, child)}
    else
      {:error, {:skill_config_path_conflict, key}}
    end
  end

  defp applicability_ceiling(context, mount_id) do
    case context |> Map.get(:applicability_ceilings, %{}) |> fetch_by_name(mount_id) do
      nil -> {:error, {:skill_applicability_ceiling_required, mount_id}}
      value -> Applicability.new(value)
    end
  end

  defp within_applicability_ceiling(value, ceiling) do
    checks = [
      subset_or_unbounded?(value.scopes, ceiling.scopes),
      subset?(ceiling.required_tags, value.required_tags),
      subset?(ceiling.forbidden_tags, value.forbidden_tags),
      subset?(ceiling.conflicts, value.conflicts)
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :skill_applicability_ceiling_exceeded}
  end

  defp subset_or_unbounded?(_values, []), do: true
  defp subset_or_unbounded?(values, ceiling), do: subset?(values, ceiling)

  defp subset?(left, right),
    do: Enum.all?(left, fn item -> Enum.any?(right, &same_name?(&1, item)) end)

  defp fetch_by_name(map, name) when is_map(map) do
    Enum.find_value(map, fn {key, value} -> if same_name?(key, name), do: value end)
  end

  defp fetch_by_name(_value, _name), do: nil

  defp exact_payload(payload, allowed) do
    case Map.keys(payload) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_skill_governance_fields, Enum.sort(unknown)}}
    end
  end

  defp stable_name(value, field) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, {:skill_governance_code_reference_forbidden, field}},
      else: {:ok, value}
  end

  defp stable_name(value, field), do: {:error, {:invalid_skill_governance_field, field, value}}

  defp optional_map(value, _field) when is_map(value) and not is_struct(value), do: {:ok, value}

  defp optional_map(value, field),
    do: {:error, {:invalid_skill_governance_field, field, shape(value)}}

  defp nonempty_map(value, field) when is_map(value) and map_size(value) > 0,
    do: optional_map(value, field)

  defp nonempty_map(value, field), do: {:error, {:invalid_skill_governance_field, field, value}}

  defp valid_path?(path) when is_binary(path),
    do: Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/, path)

  defp valid_path?(_path), do: false

  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right) when is_binary(left) and is_binary(right), do: left == right

  defp same_name?(left, right) do
    case {Value.encode(left), Value.encode(right)} do
      {{:ok, left}, {:ok, right}} -> left == right
      _other -> false
    end
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_value, _key, default), do: default

  defp put(map, key, value) do
    string = Atom.to_string(key)
    if Map.has_key?(map, string), do: Map.put(map, string, value), else: Map.put(map, key, value)
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
