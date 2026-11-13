defmodule Spectre.Server.Memory do
  @moduledoc false
  alias Spectre.Provider.Call

  def recall(agent, input, context, opts) do
    resolved = options(agent, context, opts) |> Keyword.delete(:memory)
    explicit = Keyword.merge(Map.get(context, :options, []), opts)

    resolved =
      case Keyword.fetch(explicit, :memory) do
        {:ok, injected} -> Keyword.put(resolved, :memory, injected)
        :error -> resolved
      end

    Spectre.Runtime.Persistence.load_memory(agent, input, state(context), resolved)
  end

  def remember(agent, input, text, context, opts) do
    opts = options(agent, context, opts)
    module = Keyword.get(agent.__spectre_config__(), :memory)
    result = %Spectre.Result{input: input, state: state(context), reply_text: text}

    payload = %{
      agent: agent,
      input: input,
      reply_text: text,
      route: result.route,
      state: result.state,
      effects: [],
      awaitables: [],
      events: []
    }

    cond do
      is_nil(module) ->
        :ok

      :erlang.external_size(payload) > Keyword.get(opts, :memory_persist_max_bytes, 2_000_000) ->
        {:error, :memory_persist_payload_too_large}

      not Code.ensure_loaded?(module) ->
        {:error, {:memory_adapter_unavailable, module}}

      true ->
        persist(module, input, result, payload, agent, opts)
    end
  end

  defp persist(module, input, result, payload, agent, opts) do
    case Call.run(
           :memory,
           fn ->
             module
             |> invoke_persistence(input, result, payload, agent, opts)
             |> normalize_persistence()
           end,
           Keyword.put(opts, :purpose, :memory_persist)
         ) do
      {:ok, :persisted} -> :ok
      {:error, _} = error -> error
    end
  end

  defp invoke_persistence(module, input, result, payload, agent, opts) do
    cond do
      function_exported?(module, :remember, 4) -> module.remember(input, result, agent, opts)
      function_exported?(module, :persist, 4) -> module.persist(input, result, agent, opts)
      function_exported?(module, :remember, 2) -> module.remember(payload, opts)
      function_exported?(module, :persist, 2) -> module.persist(payload, opts)
      true -> :ok
    end
  end

  defp normalize_persistence(:ok), do: {:ok, :persisted}
  defp normalize_persistence({:ok, _}), do: {:ok, :persisted}
  defp normalize_persistence({:error, _} = error), do: error
  defp normalize_persistence(_), do: {:error, :invalid_memory_persist_reply}

  defp options(agent, context, opts) do
    agent.__spectre_config__()
    |> Keyword.merge(Map.get(context, :options, []))
    |> Keyword.merge(opts)
    |> Keyword.put(:agent, agent)
    |> Keyword.put(:spectre_server, true)
    |> Keyword.put(:identity, Map.get(context, :identity, %{}))
  end

  defp state(context) do
    %Spectre.State{
      current_flow: Map.get(context, :current_flow),
      current_scope: Map.get(context, :current_scope),
      data: %{chat_history: Map.get(context, :history, [])}
    }
  end
end
