defmodule Spectre.Router.Plugs.SemanticCacheExact do
  @moduledoc """
  Exact semantic-cache lookup before classifier fallback.

  This plug runs early because a trusted cache hit is usually cheaper and more
  stable than asking a classifier or an LLM. Cache misses are recorded as local
  metadata so later plugs can include that context in traces and fallback logs.
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
        {:cont, Context.put_trace(context, {:cache_skip, :hard_candidate})}

      not Keyword.get(context.opts, :semantic_cache?, true) ->
        {:cont, Context.put_local_result(context, %{semantic_cache: :semantic_cache_disabled})}

      true ->
        semantic_lookup(context, false, :cache_accept, :cache_skip)
    end
  end

  @spec semantic_lookup(Context.t(), boolean(), atom(), atom()) :: {:cont, Context.t()}
  defp semantic_lookup(
         %Context{input: %{text: text}, rules: rules, opts: opts} = context,
         search?,
         accept_trace,
         skip_trace
       ) do
    lookup_opts = Keyword.put(opts, :semantic_search?, search?)
    ambiguous = Support.ambiguous_labels(rules, :semantic_cache, context.input)
    ambiguity_reason = Support.ambiguity_reason(:semantic_cache, ambiguous)
    visible_rules = Support.rules_for(rules, :semantic_cache, context.input)
    visible_labels = Support.labels_for(visible_rules)
    context = put_ambiguity_trace(context, ambiguity_reason)

    with :ok <- routeable_labels(visible_rules, ambiguity_reason) do
      lookup_visible(
        context,
        text,
        lookup_opts,
        opts,
        visible_rules,
        visible_labels,
        accept_trace,
        skip_trace
      )
    else
      {:skip, reason} -> skip_lookup(context, skip_trace, reason, opts)
    end
  end

  @spec lookup_visible(
          Context.t(),
          String.t(),
          keyword(),
          keyword(),
          [Spectre.Rule.t()],
          [atom()],
          atom(),
          atom()
        ) :: {:cont, Context.t()}
  defp lookup_visible(
         context,
         text,
         lookup_opts,
         opts,
         visible_rules,
         visible_labels,
         accept_trace,
         skip_trace
       ) do
    case SemanticCache.lookup(text, lookup_opts) do
      {:ok, %{accepted?: true} = result} ->
        route = Support.route_from_result(result, visible_rules, visible_labels, :semantic_cache)

        if route.handler do
          Support.log_route(:info, to_string(accept_trace), route, opts)

          {:cont,
           context
           |> Context.add_candidate(
             Candidate.from_result(
               route,
               Support.route_rule(route, visible_rules),
               route.strategy
             )
           )
           |> Context.put_trace({accept_trace, route})}
        else
          Support.log_route(:debug, "semantic_label_not_routeable", route, opts)

          {:cont,
           context
           |> Context.put_local_result(%{semantic_cache: :label_not_routeable})
           |> Context.put_trace({:semantic_label_not_routeable, route})}
        end

      {:ok, _result} ->
        reason = :semantic_cache_not_accepted
        Support.log(:debug, "#{skip_trace} reason=#{reason}", opts)

        {:cont,
         context
         |> Context.put_local_result(%{semantic_cache: reason})
         |> Context.put_trace({skip_trace, reason})}

      {:error, reason} ->
        Support.log(:debug, "#{skip_trace} reason=#{Support.format_reason(reason)}", opts)

        {:cont,
         context
         |> Context.put_local_result(%{semantic_cache: reason})
         |> Context.put_trace({skip_trace, reason})}
    end
  end

  @spec routeable_labels([Spectre.Rule.t()], term() | nil) :: :ok | {:skip, term()}
  defp routeable_labels([], reason) when not is_nil(reason), do: {:skip, reason}
  defp routeable_labels(_visible_rules, _reason), do: :ok

  @spec skip_lookup(Context.t(), atom(), term(), keyword()) :: {:cont, Context.t()}
  defp skip_lookup(%Context{} = context, skip_trace, reason, opts) do
    Support.log(:debug, "#{skip_trace} reason=#{Support.format_reason(reason)}", opts)

    {:cont,
     context
     |> Context.put_local_result(%{semantic_cache: reason})
     |> Context.put_trace({skip_trace, reason})}
  end

  @spec put_ambiguity_trace(Context.t(), term() | nil) :: Context.t()
  defp put_ambiguity_trace(%Context{} = context, nil), do: context

  defp put_ambiguity_trace(%Context{} = context, reason),
    do: Context.put_trace(context, reason)
end
