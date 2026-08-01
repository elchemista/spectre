defmodule Spectre.Operation.Memory do
  @moduledoc "Selective post-commit port for Mnemonic or an application memory adapter."

  @spec persist(module(), map(), keyword()) :: :ok | {:error, term()}
  def persist(agent, payload, opts) when is_atom(agent) and is_map(payload) and is_list(opts) do
    memory = agent.__spectre_config__() |> Keyword.get(:memory)

    cond do
      is_nil(memory) ->
        {:error, :operation_memory_not_configured}

      not is_atom(memory) or not Code.ensure_loaded?(memory) ->
        {:error, {:operation_memory_unavailable, memory}}

      function_exported?(memory, :remember_operation, 2) ->
        normalize(memory.remember_operation(payload, opts))

      function_exported?(memory, :remember, 2) ->
        normalize(memory.remember(payload, opts))

      true ->
        {:error, {:operation_memory_callback_missing, memory}}
    end
  rescue
    exception -> {:error, {:operation_memory_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:operation_memory_failure, kind, reason}}
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _receipt}), do: :ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(value), do: {:error, {:invalid_operation_memory_reply, value}}
end
