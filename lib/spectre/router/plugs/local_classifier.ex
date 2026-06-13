defmodule Spectre.Router.Plugs.LocalClassifier do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.{Candidate, Context}
  alias Spectre.Router.LocalClassifier, as: ClassifierAdapter
  alias Spectre.Router.Support

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: classify(context)
  end

  @spec classify(Context.t()) :: {:cont, Context.t()}
  defp classify(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    cache_reason = semantic_cache_reason(context)
    visible_rules = Support.rules_for(rules, :classifier, context.input)
    visible_labels = Support.labels_for(visible_rules)

    case ClassifierAdapter.classify(text, opts) do
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
             Candidate.from_result(route, route_rule(route, visible_rules), :local_classifier)
           )
           |> Context.put_trace({:local_accept, route})}
        else
          Support.log_route(:debug, "local_label_not_routeable", route, opts)

          {:cont,
           context
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

  defp route_rule(route, rules), do: Enum.find(rules, &(&1.label == route.label))
end
