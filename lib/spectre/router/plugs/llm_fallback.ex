defmodule Spectre.Router.Plugs.LLMFallback do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.LLMClassifier
  alias Spectre.Router.Support

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: fallback(context)
  end

  @spec fallback(Context.t()) :: {:cont, Context.t()}
  defp fallback(
         %Context{input: %{text: text}, labels: labels, rules: rules, opts: opts} = context
       ) do
    local_result = context.local_result || %{}

    if Keyword.get(opts, :llm_fallback?, false) do
      Support.log(
        :info,
        "llm_classifier_start local=#{Support.summarize_local(local_result)}",
        opts
      )

      case LLMClassifier.classify(text, labels, opts) do
        {:ok, result} ->
          route =
            result
            |> Map.put(:local, local_result)
            |> Support.route_from_result(rules, labels, :llm_classifier)

          Support.log_route(:info, "llm_accept", route, opts)

          {:cont,
           context
           |> Context.put_route(route)
           |> Context.put_trace({:llm_accept, route})
           |> Context.halt()}

        {:error, reason} ->
          fallback_route(context, local_result, reason)
      end
    else
      fallback_route(context, local_result, :llm_fallback_disabled)
    end
  end

  @spec fallback_route(Context.t(), map(), term()) :: {:cont, Context.t()}
  defp fallback_route(%Context{labels: labels} = context, local_result, reason) do
    route = Support.fallback_route(labels, local_result, reason)

    {:cont,
     context
     |> Context.put_route(route)
     |> Context.put_trace({:fallback_route, reason})
     |> Context.halt()}
  end
end
