defmodule Spectre.Router.Plugs.SemanticCacheSearch do
  @moduledoc """
  Semantic-cache search after local classifier evidence.

  Search runs later than exact lookup so it can use local classifier context
  without hiding a confident deterministic route. This ordering keeps the router
  predictable: exact evidence first, trained local evidence next, broader
  semantic fallback after that.
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      Context.hard_candidate_locked?(context) ->
        {:cont, Context.put_trace(context, {:semantic_skip, :hard_candidate})}

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
             Candidate.from_result(
               route,
               Support.route_rule(route, visible_rules),
               route.strategy
             )
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

      {:ok, _result} ->
        reason = :semantic_cache_not_accepted
        Support.log(:debug, "semantic_skip reason=#{reason}", opts)
        local_result = (context.local_result || %{}) |> Map.put(:semantic_cache_after, reason)

        {:cont,
         context
         |> Context.put_local_result(local_result)
         |> Context.put_trace({:semantic_skip, reason})}

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
