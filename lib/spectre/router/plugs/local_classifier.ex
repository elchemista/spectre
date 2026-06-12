defmodule Spectre.Router.Plugs.LocalClassifier do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.LocalClassifier, as: ClassifierAdapter
  alias Spectre.Router.Support

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: classify(context)
  end

  @spec classify(Context.t()) :: {:cont, Context.t()}
  defp classify(
         %Context{input: %{text: text}, labels: labels, rules: rules, opts: opts} = context
       ) do
    cache_reason = semantic_cache_reason(context)

    case ClassifierAdapter.classify(text, opts) do
      {:ok, %{accepted?: true} = result} ->
        route =
          result
          |> maybe_put_cache_reason(cache_reason)
          |> Support.route_from_result(rules, labels, :local_classifier)

        Support.log_route(:info, "local_accept", route, opts)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:local_accept, route})
         |> Context.halt()}

      {:ok, result} ->
        route = Support.route_from_result(result, rules, labels, :local_classifier)
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
end
