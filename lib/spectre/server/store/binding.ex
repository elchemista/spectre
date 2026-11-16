defmodule Spectre.Server.Store.Binding do
  @moduledoc false
  alias Spectre.GAM.Adapter
  alias Spectre.Server.{Checkpoint, Store}

  def configured(opts), do: resolve(opts, nil)

  def resolve(opts, fallback) do
    with {:ok, selected} when not is_nil(selected) <- selected(opts, fallback),
         {module, reference} <- Store.Port.adapter(selected),
         true <-
           Adapter.validate(module, fetch: 2, put_new: 3, compare_and_swap: 4, delete: 3) == :ok do
      {:ok, {module, reference}}
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:error, :invalid_managed_coordination_store}
    end
  rescue
    ArgumentError -> {:error, :invalid_managed_coordination_store}
  end

  defp selected(opts, fallback) do
    cond do
      Keyword.has_key?(opts, :store) ->
        {:ok, opts[:store]}

      reference = Checkpoint.coordination_reference(%{opts: opts[:options] || []}) ->
        {:ok, {reference.adapter, reference.store}}

      true ->
        stack_store(opts, fallback)
    end
  end

  defp stack_store(opts, fallback) do
    with runtime when not is_nil(runtime) <- opts[:stack_runtime],
         {:ok, agent} <- Spectre.Definition.fetch(opts[:agent]),
         stack when not is_nil(stack) <- agent.stack,
         {:ok, definition} <- Spectre.Stack.Definition.fetch(stack),
         {:ok, contract} <- Spectre.Stack.resolve(stack, :contract, {:spectre, :server_store, 1}),
         installation <- Enum.find(definition.installations, &(&1.id == contract.installation)) do
      provider_store(installation, stack, runtime, fallback)
    else
      _ -> {:ok, fallback}
    end
  end

  defp provider_store(installation, stack, runtime, fallback) do
    with %{adapter: adapter, resource: resource} <- installation.package.metadata[:server_store],
         {:ok, ref} <- Spectre.Stack.resolve(stack, :resource, resource) do
      case Spectre.Stack.Runtime.resolve(runtime, ref) do
        {:ok, pid} -> {:ok, {adapter, pid}}
        {:error, {:unknown_stack_runtime_ref, _}} -> {:ok, fallback}
        {:error, reason} -> {:error, {:coordination_store_unavailable, reason}}
      end
    else
      _ -> {:error, :invalid_managed_coordination_store}
    end
  end
end
