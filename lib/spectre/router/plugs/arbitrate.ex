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
  alias Spectre.Router.SemanticCache
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
            finish_llm_route(context, route, visible_rules)

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

  @spec finish_llm_route(Context.t(), Spectre.Route.t(), [Spectre.Rule.t()]) ::
          {:cont, Context.t()} | {:error, term()}
  defp finish_llm_route(%Context{} = context, route, visible_rules) do
    Support.log_route(:info, "llm_arbitrated", route, context.opts)

    case maybe_learn_semantic_example(context, route, visible_rules) do
      {:ok, context} ->
        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({:llm_arbitrated, route})
         |> Context.halt()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec maybe_learn_semantic_example(Context.t(), Spectre.Route.t(), [Spectre.Rule.t()]) ::
          {:ok, Context.t()} | {:error, term()}
  defp maybe_learn_semantic_example(%Context{} = context, route, visible_rules) do
    with :ok <- learnable_route(route, visible_rules),
         :ok <- learnable_text(context.input.text, context.opts),
         :ok <- learnable_label(route.label),
         :ok <- unprotected_route(route, context),
         :ok <- semantic_cache_missed(context),
         :ok <- secret_free(context.input.text) do
      write_semantic_example(context, route)
    else
      {:skip, reason} -> {:ok, Context.put_trace(context, {:semantic_learn_skipped, reason})}
    end
  end

  @spec learnable_route(Spectre.Route.t(), [Spectre.Rule.t()]) :: :ok | {:skip, term()}
  defp learnable_route(
         %Spectre.Route{accepted?: true, strategy: :llm_classifier, handler: handler} = route,
         rules
       )
       when not is_nil(handler) do
    case route_rule(route, rules) do
      %Spectre.Rule{learn: true} -> :ok
      %Spectre.Rule{} -> {:skip, :route_not_learnable}
      nil -> {:skip, :route_not_visible}
    end
  end

  defp learnable_route(%Spectre.Route{strategy: strategy}, _rules)
       when strategy != :llm_classifier,
       do: {:skip, :not_llm_classifier_route}

  defp learnable_route(_route, _rules), do: {:skip, :route_not_accepted}

  @spec learnable_text(String.t(), keyword()) :: :ok | {:skip, term()}
  defp learnable_text(text, opts) when is_binary(text) do
    length = text |> String.trim() |> String.length()
    min = Keyword.get(opts, :semantic_learn_min_chars, 8)
    max = Keyword.get(opts, :semantic_learn_max_chars, 1000)

    cond do
      length == 0 -> {:skip, :blank_text}
      length < min -> {:skip, :too_short}
      length > max -> {:skip, :too_long}
      true -> :ok
    end
  end

  @spec learnable_label(atom()) :: :ok | {:skip, term()}
  defp learnable_label(label) when label in [:UNKNOWN, :unknown, :clarify, :fallback],
    do: {:skip, :fallback_label}

  defp learnable_label(_label), do: :ok

  @spec unprotected_route(Spectre.Route.t(), Context.t()) :: :ok | {:skip, term()}
  defp unprotected_route(
         %Spectre.Route{handler: {:action, action, handler_opts}},
         %Context{} = context
       ) do
    if Keyword.get(context.opts, :semantic_learn_protected?, false) do
      :ok
    else
      agent = Keyword.get(context.opts, :spectre_agent)

      effect =
        Spectre.Effect.stage(%{
          name: action,
          args: Keyword.get(handler_opts, :args, %{}),
          payload: %{source: :dsl}
        })

      cond do
        is_nil(agent) -> :ok
        Spectre.ActionProtection.protected_by(agent, effect) -> {:skip, :protected_route}
        true -> :ok
      end
    end
  end

  defp unprotected_route(_route, _context), do: :ok

  @spec semantic_cache_missed(Context.t()) :: :ok | {:skip, term()}
  defp semantic_cache_missed(%Context{} = context) do
    if Keyword.get(context.opts, :semantic_learn_even_on_cache_hit?, false) do
      :ok
    else
      if Enum.any?(context.candidates, &semantic_cache_candidate?/1) do
        {:skip, :semantic_cache_hit}
      else
        :ok
      end
    end
  end

  @spec semantic_cache_candidate?(Candidate.t()) :: boolean()
  defp semantic_cache_candidate?(%Candidate{provider: provider}) do
    provider in [:semantic_cache, :semantic_cache_exact, :semantic_cache_search]
  end

  @spec secret_free(String.t()) :: :ok | {:skip, term()}
  defp secret_free(text) do
    if secret_like?(text), do: {:skip, :secret_like_input}, else: :ok
  end

  @spec secret_like?(String.t()) :: boolean()
  defp secret_like?(text) do
    Regex.match?(
      ~r/(password|passwd|api[_-]?key|secret|token|bearer|private[_-]?key)\s*[:=]\s*["']?[A-Za-z0-9_\-.=\/+]{8,}/i,
      text
    )
  end

  @spec write_semantic_example(Context.t(), Spectre.Route.t()) ::
          {:ok, Context.t()} | {:error, term()}
  defp write_semantic_example(%Context{} = context, route) do
    result = %{
      label: route.label,
      accepted?: true,
      confidence: Keyword.get(context.opts, :semantic_learn_confidence, 0.86),
      margin: nil,
      strategy: :semantic_cache_learned,
      source_strategy: :llm_classifier,
      matched: context.input.text,
      metadata: %{
        agent: Keyword.get(context.opts, :spectre_agent),
        route: route.label,
        verified?: false,
        learned_at: DateTime.utc_now(),
        original_route_strategy: :llm_classifier
      }
    }

    case SemanticCache.put(context.input.text, result, context.opts) do
      {:ok, _row} ->
        {:ok, Context.put_trace(context, {:semantic_learned, route.label})}

      :ok ->
        {:ok, Context.put_trace(context, {:semantic_learned, route.label})}

      {:error, reason} ->
        if Keyword.get(context.opts, :semantic_learn_failure, :ignore) == :error do
          {:error, {:semantic_learn_failed, reason}}
        else
          {:ok, Context.put_trace(context, {:semantic_learn_failed, reason})}
        end
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
