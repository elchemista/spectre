defmodule Spectre.Router.Plugs.SemanticCacheSearch do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.Support

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      not Keyword.get(context.opts, :semantic_cache?, true) ->
        {:cont, context}

      not Keyword.get(context.opts, :semantic_after_classifier?, true) ->
        {:cont, context}

      true ->
        semantic_search(context)
    end
  end

  @spec semantic_search(Context.t()) :: {:cont, Context.t()}
  defp semantic_search(
         %Context{input: %{text: text}, labels: labels, rules: rules, opts: opts} = context
       ) do
    case SemanticCache.lookup(text, Keyword.put(opts, :semantic_search?, true)) do
      {:ok, %{accepted?: true} = result} ->
        route =
          result
          |> Map.put(:local, context.local_result)
          |> Support.route_from_result(rules, labels, :semantic_cache_search)

        Support.log_route(:info, "semantic_accept", route, opts)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:semantic_accept, route})
         |> Context.halt()}

      {:error, reason} ->
        Support.log(:debug, "semantic_skip reason=#{Support.format_reason(reason)}", opts)
        local_result = (context.local_result || %{}) |> Map.put(:semantic_cache_after, reason)

        {:cont,
         context
         |> Context.put_local_result(local_result)
         |> Context.put_trace({:semantic_skip, reason})}
    end
  end
end
