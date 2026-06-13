defmodule Spectre.Router.Plugs.SemanticCacheSearch do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.{Candidate, Context}
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
  defp semantic_search(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    visible_rules = Support.rules_for(rules, :semantic_cache, context.input)
    visible_labels = Support.labels_for(visible_rules)

    case SemanticCache.lookup(text, Keyword.put(opts, :semantic_search?, true)) do
      {:ok, %{accepted?: true} = result} ->
        route =
          result
          |> Map.put(:local, context.local_result)
          |> Support.route_from_result(visible_rules, visible_labels, :semantic_cache_search)

        if route.handler do
          Support.log_route(:info, "semantic_accept", route, opts)

          {:cont,
           context
           |> Context.add_candidate(
             Candidate.from_result(route, route_rule(route, visible_rules), route.strategy)
           )
           |> Context.put_trace({:semantic_accept, route})}
        else
          Support.log_route(:debug, "semantic_label_not_routeable", route, opts)

          local_result =
            (context.local_result || %{}) |> Map.put(:semantic_cache_after, :label_not_routeable)

          {:cont,
           context
           |> Context.put_local_result(local_result)
           |> Context.put_trace({:semantic_label_not_routeable, route})}
        end

      {:error, reason} ->
        Support.log(:debug, "semantic_skip reason=#{Support.format_reason(reason)}", opts)
        local_result = (context.local_result || %{}) |> Map.put(:semantic_cache_after, reason)

        {:cont,
         context
         |> Context.put_local_result(local_result)
         |> Context.put_trace({:semantic_skip, reason})}
    end
  end

  defp route_rule(route, rules), do: Enum.find(rules, &(&1.label == route.label))
end
