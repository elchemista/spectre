defmodule Spectre.Operation.Registry do
  @moduledoc "Resolves the closed operation catalog visible to one loop step."

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Spec

  @validator_atoms [:any, :map, :list, :binary, :integer, :number, :atom, :boolean]

  @doc "Returns whether an operation id belongs to an Agent's closed registry."
  @spec registered?(module(), term()) :: boolean()
  def registered?(agent, id) when is_atom(agent),
    do: match?({:ok, _registered_id}, resolve_id(agent, id))

  def registered?(_agent, _id), do: false

  @doc false
  @spec code_modules(module()) :: {:ok, [module()]} | {:error, term()}
  def code_modules(agent) when is_atom(agent) and not is_nil(agent) do
    with {:ok, operations} <- agent_operations(agent) do
      modules =
        operations
        |> Map.values()
        |> Enum.flat_map(&spec_modules/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, modules}
    end
  end

  def code_modules(agent), do: {:error, {:operation_agent_not_loaded, agent}}

  @doc "Resolves an exact or JSON string operation reference in the Agent registry."
  @spec resolve_id(module(), term()) :: {:ok, term()} | {:error, term()}
  def resolve_id(agent, id) when is_atom(agent) do
    with {:ok, operations} <- agent_operations(agent) do
      case Map.fetch(operations, id) do
        {:ok, _spec} -> {:ok, id}
        :error -> resolve_string_alias(operations, id)
      end
    end
  end

  def resolve_id(_agent, id), do: {:error, {:operation_not_registered, id}}

  @doc false
  @spec resolve_spec(module(), term()) :: {:ok, Spec.t()} | {:error, term()}
  def resolve_spec(agent, id) when is_atom(agent) do
    with {:ok, operations} <- agent_operations(agent) do
      case Map.fetch(operations, id) do
        {:ok, %Spec{} = spec} -> {:ok, spec}
        :error -> resolve_spec_alias(operations, id)
      end
    end
  end

  def resolve_spec(_agent, id), do: {:error, {:operation_not_registered, id}}

  @doc false
  @spec predicate_id_for_executor(module(), {module(), atom()}) ::
          {:ok, term()} | {:error, term()}
  def predicate_id_for_executor(agent, {module, function} = executor)
      when is_atom(agent) and is_atom(module) and is_atom(function) do
    with {:ok, operations} <- agent_operations(agent) do
      matches =
        Enum.filter(operations, fn {_id, spec} ->
          spec.executor == executor and predicate_spec?(spec)
        end)

      case matches do
        [{id, _spec}] -> {:ok, id}
        [] -> {:error, {:prompt_predicate_not_registered, module, function}}
        many -> {:error, {:ambiguous_prompt_predicate, Enum.map(many, &elem(&1, 0))}}
      end
    end
  end

  def predicate_id_for_executor(_agent, executor),
    do: {:error, {:invalid_prompt_predicate_executor, executor}}

  @doc false
  @spec predicate_spec?(Spec.t()) :: boolean()
  def predicate_spec?(%Spec{} = spec) do
    spec.kind == :function and spec.side_effect == :none and spec.output == :boolean
  end

  @spec all(module(), Definition.t()) :: {:ok, %{optional(term()) => Spec.t()}} | {:error, term()}
  def all(agent, %Definition{} = definition) when is_atom(agent) do
    with {:ok, agent_operations} <- agent_operations(agent),
         {:ok, imported} <- resolve_imports(agent_operations, definition.imports) do
      {:ok, Map.merge(imported, definition.operations)}
    end
  end

  @spec resolve(module(), Definition.t(), term()) :: {:ok, Spec.t()} | {:error, term()}
  def resolve(agent, %Definition{} = definition, id) do
    with {:ok, operations} <- all(agent, definition) do
      case Map.fetch(operations, id) do
        {:ok, %Spec{} = spec} -> {:ok, spec}
        :error -> resolve_spec_alias(operations, id)
      end
    end
  end

  @spec agent_operations(module()) :: {:ok, map()} | {:error, term()}
  defp agent_operations(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0) do
      agent.__spectre_config__()
      |> Keyword.get(:operations, [])
      |> normalize()
    else
      {:error, {:operation_agent_not_loaded, agent}}
    end
  rescue
    error -> {:error, {:operation_registry_exception, agent, error.__struct__}}
  end

  defp normalize(operations) when is_list(operations) do
    Enum.reduce_while(operations, {:ok, %{}}, fn value, {:ok, acc} ->
      spec = Spec.new(value)

      if Map.has_key?(acc, spec.id),
        do: {:halt, {:error, {:duplicate_registered_operation, spec.id}}},
        else: {:cont, {:ok, Map.put(acc, spec.id, spec)}}
    end)
  end

  defp normalize(operations) when is_map(operations) do
    operations
    |> Enum.map(fn {id, value} ->
      case value do
        %Spec{} = spec -> %{spec | id: id}
        attrs when is_map(attrs) -> Map.put(attrs, :id, id)
        attrs when is_list(attrs) -> Keyword.put(attrs, :id, id)
      end
    end)
    |> normalize()
  end

  defp normalize(value), do: {:error, {:invalid_agent_operation_registry, value}}

  @spec resolve_string_alias(map(), term()) :: {:ok, term()} | {:error, term()}
  defp resolve_string_alias(operations, id) when is_binary(id) do
    case Enum.find(Map.keys(operations), &(is_atom(&1) and Atom.to_string(&1) == id)) do
      nil -> {:error, {:operation_not_registered, id}}
      registered_id -> {:ok, registered_id}
    end
  end

  defp resolve_string_alias(_operations, id), do: {:error, {:operation_not_registered, id}}

  @spec resolve_imports(map(), [term()]) :: {:ok, map()} | {:error, term()}
  defp resolve_imports(agent, imports) do
    Enum.reduce_while(imports, {:ok, %{}}, fn authored_id, {:ok, imported} ->
      case resolve_import(agent, authored_id) do
        {:ok, registered_id, spec} ->
          {:cont, {:ok, Map.put(imported, registered_id, spec)}}

        :error ->
          {:halt, {:error, {:imported_operation_not_registered, authored_id}}}
      end
    end)
  end

  @spec resolve_import(map(), term()) :: {:ok, term(), Spec.t()} | :error
  defp resolve_import(operations, id) do
    case Map.fetch(operations, id) do
      {:ok, %Spec{} = spec} ->
        {:ok, id, spec}

      :error when is_binary(id) ->
        case Enum.find(operations, fn {registered_id, _spec} ->
               is_atom(registered_id) and Atom.to_string(registered_id) == id
             end) do
          {registered_id, %Spec{} = spec} -> {:ok, registered_id, spec}
          nil -> :error
        end

      :error ->
        :error
    end
  end

  @spec resolve_spec_alias(map(), term()) :: {:ok, Spec.t()} | {:error, term()}
  defp resolve_spec_alias(operations, id) when is_binary(id) do
    case Enum.find(operations, fn {registered_id, _spec} ->
           is_atom(registered_id) and Atom.to_string(registered_id) == id
         end) do
      {_registered_id, %Spec{} = spec} -> {:ok, spec}
      nil -> {:error, {:operation_not_registered, id}}
    end
  end

  defp resolve_spec_alias(_operations, id), do: {:error, {:operation_not_registered, id}}

  @spec spec_modules(Spec.t()) :: [module()]
  defp spec_modules(%Spec{} = spec) do
    executor_modules =
      if spec.kind == :cognitive and spec.executor == :inference,
        do: [],
        else: module_refs(spec.executor, :executor)

    executor_modules ++
      module_refs(spec.input, :validator) ++
      module_refs(spec.output, :validator) ++
      module_refs(spec.reconcile, :executor) ++
      module_refs(spec.fallback, :executor) ++
      module_refs(spec.policy, :policy)
  end

  defp module_refs(nil, _field), do: []
  defp module_refs(:registered, :policy), do: []
  defp module_refs(value, :validator) when value in @validator_atoms, do: []

  defp module_refs({module, function}, _field) when is_atom(module) and is_atom(function),
    do: [module]

  defp module_refs(module, _field) when is_atom(module) and not is_nil(module), do: [module]
  defp module_refs(_value, _field), do: []
end
