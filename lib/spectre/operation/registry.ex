defmodule Spectre.Operation.Registry do
  @moduledoc "Resolves the closed operation catalog visible to one loop step."

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Spec

  @spec all(module(), Definition.t()) :: {:ok, %{optional(term()) => Spec.t()}} | {:error, term()}
  def all(agent, %Definition{} = definition) when is_atom(agent) do
    with {:ok, agent_operations} <- agent_operations(agent),
         :ok <- ensure_imports(agent_operations, definition.imports) do
      imported = Map.take(agent_operations, definition.imports)
      {:ok, Map.merge(imported, definition.operations)}
    end
  end

  @spec resolve(module(), Definition.t(), term()) :: {:ok, Spec.t()} | {:error, term()}
  def resolve(agent, %Definition{} = definition, id) do
    with {:ok, operations} <- all(agent, definition) do
      case Map.fetch(operations, id) do
        {:ok, %Spec{} = spec} -> {:ok, spec}
        :error -> {:error, {:operation_not_registered, id}}
      end
    end
  end

  @spec agent_operations(module()) :: {:ok, map()} | {:error, term()}
  defp agent_operations(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0) do
      agent
      |> apply(:__spectre_config__, [])
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

  defp ensure_imports(agent, imports) do
    case Enum.find(imports, &(not Map.has_key?(agent, &1))) do
      nil -> :ok
      id -> {:error, {:imported_operation_not_registered, id}}
    end
  end
end
