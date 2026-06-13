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
  defp fallback(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    local_result = context.local_result || %{}
    visible_rules = Support.rules_for(rules, :llm, context.input)
    visible_labels = Support.labels_for(visible_rules)

    if Keyword.get(opts, :llm_fallback?, false) do
      Support.log(
        :info,
        "llm_classifier_start local=#{Support.summarize_local(local_result)}",
        opts
      )

      case LLMClassifier.classify(text, visible_labels, opts) do
        {:ok, result} ->
          route =
            result
            |> Map.put(:local, local_result)
            |> Support.route_from_result(visible_rules, visible_labels, :llm_classifier)

          Support.log_route(:info, "llm_accept", route, opts)

          {:cont,
           context
           |> Context.put_route(route)
           |> Context.put_trace({:llm_accept, route})
           |> Context.halt()}

        {:error, reason} ->
          fallback_route(context, visible_labels, local_result, reason)
      end
    else
      fallback_route(context, visible_labels, local_result, :llm_fallback_disabled)
    end
  end

  @spec fallback_route(Context.t(), [atom()], map(), term()) :: {:cont, Context.t()}
  defp fallback_route(%Context{} = context, labels, local_result, reason) do
    route = Support.fallback_route(labels, local_result, reason)

    {:cont,
     context
     |> Context.put_route(route)
     |> Context.put_trace({:fallback_route, reason})
     |> Context.halt()}
  end
end
