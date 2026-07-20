defmodule Spectre.Router.Plugs.LocalClassifier do
  @moduledoc """
  Local classifier evidence provider.

  The classifier converts a trained artifact result into a route candidate.
  Accepted but unrouteable labels are kept as local metadata so later semantic
  or LLM fallback steps can explain why the local model did not produce a final
  route.

      router via: [:regex, :classifier, :llm_classifier]
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.LocalClassifier
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      Context.hard_candidate_locked?(context) ->
        {:cont, Context.put_trace(context, {:local_skip, :hard_candidate})}

      true ->
        classify(context)
    end
  end

  @spec classify(Context.t()) :: {:cont, Context.t()}
  defp classify(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    cache_reason = semantic_cache_reason(context)
    ambiguous = Support.ambiguous_labels(rules, :classifier, context.input)
    ambiguity_reason = Support.ambiguity_reason(:classifier, ambiguous)
    visible_rules = Support.rules_for(rules, :classifier, context.input)
    visible_labels = Support.labels_for(visible_rules)
    context = put_ambiguity_trace(context, ambiguity_reason)

    if visible_rules == [] do
      {:cont, Context.put_trace(context, {:local_skip, ambiguity_reason || :no_visible_rules})}
    else
      classify_visible(context, text, opts, visible_rules, visible_labels, cache_reason)
    end
  end

  @spec put_ambiguity_trace(Context.t(), term() | nil) :: Context.t()
  defp put_ambiguity_trace(%Context{} = context, nil), do: context

  defp put_ambiguity_trace(%Context{} = context, reason),
    do: Context.put_trace(context, reason)

  @spec classify_visible(Context.t(), String.t(), keyword(), [Spectre.Rule.t()], [atom()], term()) ::
          {:cont, Context.t()}
  defp classify_visible(context, text, opts, visible_rules, visible_labels, cache_reason) do
    case LocalClassifier.classify(text, opts) do
      {:ok, %{accepted?: true} = result} ->
        route =
          result
          |> maybe_put_cache_reason(cache_reason)
          |> Support.route_from_result(visible_rules, visible_labels, :local_classifier)

        if route.handler do
          Support.log_route(:info, "local_accept", route, opts)

          {:cont,
           context
           |> Context.add_candidate(
             Candidate.from_result(
               route,
               Support.route_rule(route, visible_rules),
               :local_classifier
             )
           )
           |> Context.put_trace({:local_accept, route})}
        else
          Support.log_route(:debug, "local_label_not_routeable", route, opts)

          {:cont,
           context
           |> Context.add_candidate(
             Candidate.from_result(
               route,
               Support.route_rule(route, visible_rules),
               :local_classifier
             )
           )
           |> Context.put_local_result(
             Map.put(Map.from_struct(route), :semantic_cache, cache_reason)
           )
           |> Context.put_trace({:local_label_not_routeable, route})}
        end

      {:ok, result} ->
        route =
          Support.route_from_result(result, visible_rules, visible_labels, :local_classifier)

        Support.log_route(:info, "local_uncertain", route, opts)

        {:cont,
         context
         |> Context.add_candidate(
           Candidate.from_result(
             route,
             Support.route_rule(route, visible_rules),
             :local_classifier
           )
         )
         |> Context.put_local_result(
           Map.put(Map.from_struct(route), :semantic_cache, cache_reason)
         )
         |> Context.put_trace({:local_uncertain, route})}

      {:error, reason} ->
        Support.log(:debug, "local_skip reason=#{Support.format_reason(reason)}", opts)

        local_result = %{
          strategy: :local_unavailable,
          error: reason,
          semantic_cache: cache_reason
        }

        {:cont,
         context
         |> Context.put_local_result(local_result)
         |> Context.put_trace({:local_error, reason})}
    end
  end

  @spec semantic_cache_reason(Context.t()) :: term()
  defp semantic_cache_reason(%Context{local_result: %{semantic_cache: reason}}), do: reason
  defp semantic_cache_reason(_context), do: nil

  @spec maybe_put_cache_reason(map(), term()) :: map()
  defp maybe_put_cache_reason(result, :semantic_cache_disabled), do: result
  defp maybe_put_cache_reason(result, nil), do: result
  defp maybe_put_cache_reason(result, reason), do: Map.put(result, :semantic_cache, reason)
end
