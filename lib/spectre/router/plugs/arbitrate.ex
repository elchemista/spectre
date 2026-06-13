defmodule Spectre.Router.Plugs.Arbitrate do
  @moduledoc """
  Turns accumulated routing evidence into a route decision.

  Earlier plugs collect candidates; this plug is the boundary where competing
  evidence becomes one action: accept a candidate, ask the LLM classifier,
  clarify, or produce a fallback route. Keeping this as a plug makes custom
  arbitration possible without rewriting evidence providers.
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Arbitration
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.LLMClassifier
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: arbitrate(context)
  end

  defp arbitrate(%Context{} = context) do
    arbitration = Arbitration.from_context(context)

    case call_arbitrator(arbitration, context.opts) do
      {:ok, route} ->
        Support.log_route(:info, "arbitrated", route, context.opts)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:arbitrated, route})
         |> Context.halt()}

      {:llm, %Arbitration{} = arbitration} ->
        llm_arbitrate(context, arbitration)

      {:clarify, text} ->
        route = clarify_route(context, text)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:clarify, text})
         |> Context.halt()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp llm_arbitrate(%Context{} = context, %Arbitration{} = _arbitration) do
    visible_rules =
      case Support.rules_for(context.rules, :llm_classifier, context.input) do
        [] -> context.rules
        rules -> rules
      end

    labels = Support.labels_for(visible_rules)

    case LLMClassifier.classify(context.input.text, labels, context.opts) do
      {:ok, result} ->
        route = Support.route_from_result(result, visible_rules, labels, :llm_classifier)

        candidate =
          Candidate.from_result(route, route_rule(route, visible_rules), :llm_classifier)

        context = Context.add_candidate(context, candidate)

        case call_arbitrator(
               Arbitration.from_context(context),
               Keyword.put(context.opts, :conflict, :best)
             ) do
          {:ok, route} ->
            Support.log_route(:info, "llm_arbitrated", route, context.opts)

            {:cont,
             context
             |> Context.put_route(route)
             |> Context.put_trace({:llm_arbitrated, route})
             |> Context.halt()}

          other ->
            {:error, {:invalid_llm_arbitration_result, other}}
        end

      {:error, reason} ->
        route = fallback_route(context, reason)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:llm_arbitration_failed, reason})
         |> Context.halt()}
    end
  end

  defp call_arbitrator(%Arbitration{} = arbitration, opts) do
    {module, arbitrator_opts} = arbitrator(opts)
    module.decide(arbitration, Keyword.merge(arbitrator_opts, opts))
  end

  defp arbitrator(opts) do
    case Keyword.get(opts, :arbitrator, {Spectre.Router.Arbitrators.Default, []}) do
      {module, arbitrator_opts} when is_atom(module) and is_list(arbitrator_opts) ->
        {module, arbitrator_opts}

      module when is_atom(module) ->
        {module, []}
    end
  end

  defp route_rule(route, rules), do: Enum.find(rules, &(&1.label == route.label))

  defp clarify_route(context, text) do
    case Enum.find(context.rules, &(&1.label == :UNKNOWN)) do
      %Spectre.Rule{} = rule ->
        Candidate.from_rule(rule, :clarify, context.input.text,
          score: 0.0,
          metadata: %{text: text}
        )
        |> Candidate.to_route(context.labels)

      nil ->
        Spectre.Route.new(%{
          label: :unknown,
          strategy: :clarify,
          accepted?: false,
          raw: text,
          labels: context.labels
        })
    end
  end

  defp fallback_route(context, reason) do
    context.labels
    |> Support.fallback_route(%{strategy: :arbitration, error: reason}, reason)
  end
end
