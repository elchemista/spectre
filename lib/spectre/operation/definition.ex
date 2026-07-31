defmodule Spectre.Operation.Definition do
  @moduledoc """
  Versioned definition loaded from a Work, Vigil or external controller.

  The definition is code-owned discovery data. Checkpoints retain only its
  controller module, stable identity and version, then resolve it again after
  restart.
  """

  alias Spectre.Operation.Budget
  alias Spectre.Operation.Spec
  alias Spectre.Run.Value

  @kinds [:work, :vigil, :directive]

  @enforce_keys [:id, :version, :kind]
  defstruct [
    :id,
    :version,
    :kind,
    :input,
    :state,
    :update,
    :checkpoint,
    :on_budget_exhausted,
    operations: %{},
    imports: [],
    branches: %{},
    blockers: [],
    waits: [],
    triggers: [],
    update_fields: [],
    security: %{},
    artifact_policy: %{},
    budget: %Budget{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          version: pos_integer() | String.t(),
          kind: :work | :vigil | :directive,
          input: Spec.validator(),
          state: Spec.validator(),
          update: Spec.validator(),
          checkpoint: term(),
          on_budget_exhausted: term(),
          operations: %{optional(atom() | String.t()) => Spec.t()},
          imports: [atom() | String.t()],
          branches: %{optional(atom() | String.t()) => [atom() | String.t()]},
          blockers: [atom() | String.t()],
          waits: [atom()],
          triggers: [atom()],
          update_fields: [:all | atom() | String.t()],
          security: map(),
          artifact_policy: map(),
          budget: Budget.t(),
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = definition), do: validate!(definition)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    operations = normalize_operations(attr(attrs, :operations, %{}))

    %__MODULE__{
      id: attr(attrs, :id),
      version: attr(attrs, :version, 1),
      kind: attr(attrs, :kind),
      input: attr(attrs, :input),
      state: attr(attrs, :state),
      update: attr(attrs, :update),
      checkpoint: attr(attrs, :checkpoint),
      on_budget_exhausted: attr(attrs, :on_budget_exhausted, :terminate),
      operations: operations,
      imports: List.wrap(attr(attrs, :imports, [])),
      branches: normalize_branches(attr(attrs, :branches, %{})),
      blockers: List.wrap(attr(attrs, :blockers, [])),
      waits: List.wrap(attr(attrs, :waits, [])),
      triggers: List.wrap(attr(attrs, :triggers, [])),
      update_fields: List.wrap(attr(attrs, :update_fields, [])),
      security: attr(attrs, :security, %{}),
      artifact_policy: attr(attrs, :artifact_policy, %{}),
      budget: Budget.new(attr(attrs, :budget)),
      metadata: attr(attrs, :metadata, %{})
    }
    |> validate!()
  end

  @spec load(module()) :: {:ok, t()} | {:error, term()}
  def load(controller) when is_atom(controller) and not is_nil(controller) do
    cond do
      not Code.ensure_loaded?(controller) ->
        {:error, {:operational_controller_not_loaded, controller}}

      function_exported?(controller, :__spectre_loop_definition__, 0) ->
        normalize_loaded(controller, controller.__spectre_loop_definition__())

      function_exported?(controller, :definition, 0) ->
        normalize_loaded(controller, controller.definition())

      true ->
        {:error, {:operational_controller_definition_missing, controller}}
    end
  rescue
    error ->
      {:error, {:operational_controller_definition_exception, controller, error.__struct__}}
  catch
    kind, reason ->
      {:error, {:operational_controller_definition_failure, controller, kind, reason}}
  end

  @spec operation(t(), atom() | String.t()) :: {:ok, Spec.t()} | {:error, term()}
  def operation(%__MODULE__{operations: operations}, id) do
    case Map.fetch(operations, id) do
      {:ok, %Spec{} = spec} -> {:ok, spec}
      :error -> {:error, {:operation_not_registered, id}}
    end
  end

  @spec compatible?(module(), term(), term()) :: boolean()
  def compatible?(controller, stored, current) do
    cond do
      stored == current ->
        true

      function_exported?(controller, :checkpoint_compatible?, 2) ->
        controller.checkpoint_compatible?(stored, current) == true

      true ->
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = definition) do
    cond do
      not valid_id?(definition.id) ->
        {:error, {:invalid_loop_definition_id, definition.id}}

      not valid_version?(definition.version) ->
        {:error, {:invalid_loop_definition_version, definition.version}}

      definition.kind not in @kinds ->
        {:error, {:invalid_loop_definition_kind, definition.kind}}

      not valid_validator?(definition.input) ->
        {:error, :invalid_loop_definition_input}

      not valid_validator?(definition.state) ->
        {:error, :invalid_loop_definition_state}

      not valid_validator?(definition.update) ->
        {:error, :invalid_loop_definition_update}

      not is_map(definition.operations) ->
        {:error, :invalid_loop_definition_operations}

      not valid_imports?(definition.imports, definition.operations) ->
        {:error, :invalid_loop_definition_imports}

      not valid_branches?(definition.branches, definition.operations, definition.imports) ->
        {:error, :invalid_loop_definition_branches}

      not valid_ids?(definition.blockers) ->
        {:error, :invalid_loop_definition_blockers}

      not valid_atom_ids?(definition.waits) ->
        {:error, :invalid_loop_definition_waits}

      not valid_atom_ids?(definition.triggers) ->
        {:error, :invalid_loop_definition_triggers}

      not valid_update_fields?(definition.update_fields) ->
        {:error, :invalid_loop_definition_update_fields}

      definition.on_budget_exhausted not in [:terminate, :controller] ->
        {:error, :invalid_loop_budget_exhaustion_behavior}

      not valid_security?(definition.security) ->
        {:error, :invalid_loop_definition_security}

      not valid_artifact_policy?(definition.artifact_policy) ->
        {:error, :invalid_loop_artifact_policy}

      not is_map(definition.metadata) ->
        {:error, :invalid_loop_definition_metadata}

      true ->
        with :ok <- portable_definition_data(definition) do
          validate_operations(definition.operations)
        end
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = definition) do
    case validate(definition) do
      :ok -> definition
      {:error, reason} -> raise ArgumentError, "invalid loop definition: #{inspect(reason)}"
    end
  end

  defp normalize_loaded(_controller, %__MODULE__{} = definition), do: {:ok, new(definition)}

  defp normalize_loaded(_controller, value) when is_map(value) or is_list(value),
    do: {:ok, new(value)}

  defp normalize_loaded(controller, value),
    do: {:error, {:invalid_operational_controller_definition, controller, value}}

  defp normalize_operations(operations) when is_list(operations) do
    operations
    |> Enum.map(&Spec.new/1)
    |> Enum.reduce(%{}, fn spec, acc ->
      if Map.has_key?(acc, spec.id) do
        raise ArgumentError, "duplicate operation id in loop definition: #{inspect(spec.id)}"
      end

      Map.put(acc, spec.id, spec)
    end)
  end

  defp normalize_operations(operations) when is_map(operations) do
    Enum.reduce(operations, %{}, fn {id, spec}, acc ->
      spec =
        case spec do
          %Spec{} -> spec
          value when is_map(value) -> Map.put_new(value, :id, id)
          value when is_list(value) -> Keyword.put_new(value, :id, id)
        end
        |> Spec.new()

      if Map.has_key?(acc, spec.id) do
        raise ArgumentError, "duplicate operation id in loop definition: #{inspect(spec.id)}"
      end

      Map.put(acc, spec.id, spec)
    end)
  end

  defp normalize_branches(nil), do: %{}

  defp normalize_branches(value) when is_list(value),
    do: value |> Map.new() |> normalize_branches()

  defp normalize_branches(value) when is_map(value) do
    Map.new(value, fn {branch, operations} -> {branch, List.wrap(operations)} end)
  end

  defp normalize_branches(value), do: value

  defp validate_operations(operations) do
    Enum.reduce_while(operations, :ok, fn
      {id, %Spec{id: id} = spec}, :ok ->
        case Spec.validate(spec) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {id, spec}, :ok ->
        {:halt, {:error, {:invalid_loop_operation_entry, id, spec}}}
    end)
  end

  defp valid_id?(value) when is_atom(value), do: not is_nil(value)
  defp valid_id?(value) when is_binary(value), do: value != ""
  defp valid_id?(_value), do: false

  defp valid_version?(value) when is_integer(value), do: value > 0
  defp valid_version?(value) when is_binary(value), do: value != ""
  defp valid_version?(_value), do: false

  defp valid_branches?(branches, operations, imports) when is_map(branches) do
    known = MapSet.new(Map.keys(operations) ++ imports)

    Enum.all?(branches, fn {branch, allowed} ->
      valid_id?(branch) and is_list(allowed) and allowed != [] and Enum.uniq(allowed) == allowed and
        Enum.all?(allowed, &(valid_id?(&1) and MapSet.member?(known, &1)))
    end)
  end

  defp valid_branches?(_branches, _operations, _imports), do: false

  defp valid_imports?(imports, operations) when is_list(imports) do
    Enum.all?(imports, &valid_id?/1) and Enum.uniq(imports) == imports and
      Enum.all?(imports, &(not Map.has_key?(operations, &1)))
  end

  defp valid_imports?(_imports, _operations), do: false

  defp valid_ids?(values),
    do: is_list(values) and Enum.all?(values, &valid_id?/1) and Enum.uniq(values) == values

  defp valid_atom_ids?(values),
    do:
      is_list(values) and Enum.all?(values, &(is_atom(&1) and not is_nil(&1))) and
        Enum.uniq(values) == values

  defp valid_update_fields?(fields) when is_list(fields) do
    Enum.uniq(fields) == fields and
      Enum.all?(fields, fn
        :all -> true
        value -> valid_id?(value)
      end)
  end

  defp valid_update_fields?(_fields), do: false

  defp valid_security?(security) when is_map(security) do
    allowed_origins = attr(security, :allowed_origins, [])
    allowed_destinations = attr(security, :allowed_destinations, [])
    allowed_visibility = attr(security, :allowed_visibility, [:origin, :subject])
    immediate? = attr(security, :allow_immediate_pause, false)

    is_list(allowed_origins) and Enum.uniq(allowed_origins) == allowed_origins and
      is_list(allowed_destinations) and Enum.uniq(allowed_destinations) == allowed_destinations and
      is_list(allowed_visibility) and allowed_visibility != [] and
      Enum.uniq(allowed_visibility) == allowed_visibility and
      Enum.all?(allowed_visibility, &(&1 in [:origin, :subject])) and is_boolean(immediate?)
  end

  defp valid_security?(_security), do: false

  defp valid_artifact_policy?(policy) when is_map(policy) do
    allowed_kinds = attr(policy, :allowed_kinds, [])
    max_count = attr(policy, :max_count, 256)
    publish_results? = attr(policy, :publish_results, true)
    publish_artifacts? = attr(policy, :publish_artifacts, true)

    is_list(allowed_kinds) and Enum.uniq(allowed_kinds) == allowed_kinds and
      Enum.all?(allowed_kinds, &valid_id?/1) and
      is_integer(max_count) and max_count >= 0 and max_count <= 256 and
      is_boolean(publish_results?) and
      is_boolean(publish_artifacts?)
  end

  defp valid_artifact_policy?(_policy), do: false

  defp valid_validator?(nil), do: true

  defp valid_validator?(validator)
       when validator in [:any, :map, :list, :binary, :integer, :number, :atom, :boolean],
       do: true

  defp valid_validator?({module, function}),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function)

  defp valid_validator?(module) when is_atom(module), do: true
  defp valid_validator?(_validator), do: false

  defp portable_definition_data(definition) do
    value = %{
      checkpoint: definition.checkpoint,
      branches: definition.branches,
      blockers: definition.blockers,
      waits: definition.waits,
      triggers: definition.triggers,
      update_fields: definition.update_fields,
      security: definition.security,
      artifact_policy: definition.artifact_policy,
      metadata: definition.metadata
    }

    case Value.validate(value, [:operation_definition, definition.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_loop_definition, reason}}
    end
  end

  defp attr(map, key, default \\ nil),
    do: Map.get(map, key, default)
end
