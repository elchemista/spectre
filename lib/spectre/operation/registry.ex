defmodule Spectre.Operation.Registry do
  @moduledoc "Resolves the closed operation catalog visible to one loop step."

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Spec

  @doc "Returns whether an operation id belongs to an Agent's closed registry."
  @spec registered?(module(), term()) :: boolean()
  def registered?(agent, id) when is_atom(agent),
    do: match?({:ok, _registered_id}, resolve_id(agent, id))

  def registered?(_agent, _id), do: false

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
end
