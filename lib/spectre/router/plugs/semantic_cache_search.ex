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

      exact_cache_hit?(context) ->
        {:cont, Context.put_trace(context, {:semantic_skip, :exact_cache_hit})}

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

  @spec exact_cache_hit?(Context.t()) :: boolean()
  defp exact_cache_hit?(%Context{traces: traces}) do
    Enum.any?(traces, &match?({:cache_accept, %Spectre.Route{accepted?: true}}, &1))
  end

  @spec semantic_search(Context.t()) :: {:cont, Context.t()}
  defp semantic_search(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    ambiguous = Support.ambiguous_labels(rules, :semantic_cache, context.input)
    ambiguity_reason = Support.ambiguity_reason(:semantic_cache, ambiguous)
    visible_rules = Support.rules_for(rules, :semantic_cache, context.input)
    visible_labels = Support.labels_for(visible_rules)
    context = put_ambiguity_trace(context, ambiguity_reason)

    case routeable_labels(visible_rules, ambiguity_reason) do
      :ok -> search_visible(context, text, opts, visible_rules, visible_labels)
      {:skip, reason} -> skip_search(context, reason, opts)
    end
  end

  @spec search_visible(Context.t(), String.t(), keyword(), [Spectre.Rule.t()], [atom()]) ::
          {:cont, Context.t()}
  defp search_visible(context, text, opts, visible_rules, visible_labels) do
    {reply, metadata} =
      SemanticCache.lookup_with_metadata(text, Keyword.put(opts, :semantic_search?, true))

    context = put_query_embedding(context, metadata)

    case reply do
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

  @spec put_query_embedding(Context.t(), map()) :: Context.t()
  defp put_query_embedding(context, %{query_embedding: embedding})
       when is_list(embedding) and embedding != [] do
    Context.put_semantic_cache_query_embedding(context, embedding)
  end

  defp put_query_embedding(context, _metadata), do: context

  @spec routeable_labels([Spectre.Rule.t()], term() | nil) :: :ok | {:skip, term()}
  defp routeable_labels([], reason) when not is_nil(reason), do: {:skip, reason}
  defp routeable_labels(_visible_rules, _reason), do: :ok

  @spec skip_search(Context.t(), term(), keyword()) :: {:cont, Context.t()}
  defp skip_search(%Context{} = context, reason, opts) do
    Support.log(:debug, "semantic_skip reason=#{Support.format_reason(reason)}", opts)
    local_result = (context.local_result || %{}) |> Map.put(:semantic_cache_after, reason)

    {:cont,
     context
     |> Context.put_local_result(local_result)
     |> Context.put_trace({:semantic_skip, reason})}
  end

  @spec put_ambiguity_trace(Context.t(), term() | nil) :: Context.t()
  defp put_ambiguity_trace(%Context{} = context, nil), do: context

  defp put_ambiguity_trace(%Context{} = context, reason),
    do: Context.put_trace(context, reason)
end
