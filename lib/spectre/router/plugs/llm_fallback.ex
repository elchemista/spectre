defmodule Spectre.Router.Plugs.LLMFallback do
  @moduledoc """
  Legacy LLM fallback classifier plug.

  Newer pipelines normally use `Spectre.Router.Plugs.Arbitrate`, which can ask
  the LLM classifier as an arbitration outcome. This plug remains available for
  custom pipelines that want an explicit fallback step.
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.LLMClassifier
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: fallback(context)
  end

  @spec fallback(Context.t()) :: {:cont, Context.t()}
  defp fallback(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    local_result = context.local_result || %{}
    {visible_rules, strategy, ambiguous} = visible_rules(rules, context.input)
    ambiguity_reason = Support.ambiguity_reason(strategy, ambiguous)
    visible_labels = Support.labels_for(visible_rules)
    context = put_ambiguity_trace(context, ambiguity_reason)

    cond do
      not Keyword.get(opts, :llm_fallback?, false) ->
        fallback_route(context, visible_labels, local_result, :llm_fallback_disabled)

      visible_rules == [] and not is_nil(ambiguity_reason) ->
        fallback_route(context, visible_labels, local_result, ambiguity_reason)

      true ->
        classify(context, text, opts, visible_rules, visible_labels, local_result)
    end
  end

  @spec classify(Context.t(), String.t(), keyword(), [Spectre.Rule.t()], [atom()], map()) ::
          {:cont, Context.t()}
  defp classify(context, text, opts, visible_rules, visible_labels, local_result) do
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
  end

  @spec visible_rules([Spectre.Rule.t()], Spectre.Input.t()) ::
          {[Spectre.Rule.t()], atom(), [atom()]}
  defp visible_rules(rules, input) do
    classifier_rules = Support.rules_for(rules, :llm_classifier, input)
    classifier_ambiguous = Support.ambiguous_labels(rules, :llm_classifier, input)

    case classifier_rules do
      [] ->
        fallback_visible_rules(rules, input, classifier_ambiguous)

      _visible ->
        {classifier_rules, :llm_classifier, classifier_ambiguous}
    end
  end

  @spec fallback_visible_rules([Spectre.Rule.t()], Spectre.Input.t(), [atom()]) ::
          {[Spectre.Rule.t()], atom(), [atom()]}
  defp fallback_visible_rules(rules, input, classifier_ambiguous) do
    llm_rules = Support.rules_for(rules, :llm, input)
    llm_ambiguous = Support.ambiguous_labels(rules, :llm, input)

    case {llm_rules, llm_ambiguous} do
      {[], []} -> {[], :llm_classifier, classifier_ambiguous}
      _visible_or_ambiguous -> {llm_rules, :llm, llm_ambiguous}
    end
  end

  @spec put_ambiguity_trace(Context.t(), term() | nil) :: Context.t()
  defp put_ambiguity_trace(%Context{} = context, nil), do: context

  defp put_ambiguity_trace(%Context{} = context, reason),
    do: Context.put_trace(context, reason)

  @spec fallback_route(Context.t(), [atom()], map(), term()) :: {:cont, Context.t()}
  defp fallback_route(%Context{} = context, labels, local_result, reason) do
    route = Support.fallback_route(context.rules, context.input, labels, local_result, reason)

    {:cont,
     context
     |> Context.put_route(route)
     |> Context.put_trace({:fallback_route, reason})
     |> Context.halt()}
  end
end
