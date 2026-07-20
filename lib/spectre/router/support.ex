defmodule Spectre.Router.Support do
  @moduledoc """
  Shared router normalization and logging helpers.

  Router plugs should stay small and focused on one evidence source. This module
  holds the common boundary work: filtering visible rules, converting adapter
  maps into `%Spectre.Route{}` structs, formatting fallback reasons, and keeping
  log output consistent across strategies.
  """

  require Logger

  alias Spectre.Route
  alias Spectre.Rule

  @label_only_strategies [:classifier, :llm_classifier, :llm, :semantic_cache]

  @doc """
  Returns rules visible to a router strategy.

  A rule with no explicit `via:` remains visible to every strategy. When a rule
  declares `via: [:classifier]`, deterministic regex and LLM fallback plugs will
  ignore it.
  """
  @spec rules_for([Rule.t()], atom(), Spectre.Input.t() | nil) :: [Rule.t()]
  def rules_for(rules, strategy, input \\ nil) when is_list(rules) and is_atom(strategy) do
    visible = visible_rules(rules, strategy, input)
    reject_ambiguous_label_only_rules(visible, strategy)
  end

  @doc """
  Returns labels that a label-only provider cannot resolve to one visible rule.

  Deterministic providers can retain duplicate labels because their evidence
  identifies a concrete rule. Classifiers, semantic caches, and LLM classifiers
  return only a label, so duplicates are ambiguous even when their mounted
  scopes differ.
  """
  @spec ambiguous_labels([Rule.t()], atom(), Spectre.Input.t() | nil) :: [atom()]
  def ambiguous_labels(rules, strategy, input \\ nil)
      when is_list(rules) and is_atom(strategy) do
    rules
    |> visible_rules(strategy, input)
    |> ambiguous_visible_labels(strategy)
  end

  @doc """
  Builds the trace reason used when scoped labels are ambiguous.
  """
  @spec ambiguity_reason(atom(), [atom()]) ::
          {:ambiguous_scoped_labels, atom(), [atom()]} | nil
  def ambiguity_reason(_strategy, []), do: nil

  def ambiguity_reason(strategy, labels) when is_atom(strategy) and is_list(labels),
    do: {:ambiguous_scoped_labels, strategy, labels}

  @spec visible_rules([Rule.t()], atom(), Spectre.Input.t() | nil) :: [Rule.t()]
  defp visible_rules(rules, strategy, input) do
    Enum.filter(rules, fn
      %Rule{via: []} = rule -> input_match?(rule, input)
      %Rule{via: via} = rule -> strategy in via and input_match?(rule, input)
    end)
  end

  @spec input_match?(Rule.t(), Spectre.Input.t() | nil) :: boolean()
  defp input_match?(%Rule{checks: []}, _input), do: true
  defp input_match?(%Rule{} = rule, %Spectre.Input{} = input), do: Rule.checks_match?(rule, input)
  defp input_match?(%Rule{}, nil), do: false

  @spec reject_ambiguous_label_only_rules([Rule.t()], atom()) :: [Rule.t()]
  defp reject_ambiguous_label_only_rules(rules, strategy) do
    ambiguous = rules |> ambiguous_visible_labels(strategy) |> MapSet.new()
    Enum.reject(rules, &MapSet.member?(ambiguous, &1.label))
  end

  @spec ambiguous_visible_labels([Rule.t()], atom()) :: [atom()]
  defp ambiguous_visible_labels(rules, strategy) when strategy in @label_only_strategies do
    counts = Enum.frequencies_by(rules, & &1.label)

    rules
    |> labels_for()
    |> Enum.filter(&(Map.fetch!(counts, &1) > 1))
  end

  defp ambiguous_visible_labels(_rules, _strategy), do: []

  @doc """
  Returns unique labels for a rule set in evaluation order.
  """
  @spec labels_for([Rule.t()]) :: [atom()]
  def labels_for(rules) when is_list(rules) do
    rules
    |> Enum.map(& &1.label)
    |> Enum.uniq()
  end

  @doc """
  Builds an accepted route from a rule and strategy.
  """
  @spec route_from_rule(Rule.t(), atom(), String.t(), [atom()]) :: Route.t()
  def route_from_rule(%Rule{} = rule, strategy, raw, labels) do
    rule
    |> Route.from_rule(strategy, raw)
    |> Map.put(:labels, labels)
  end

  @doc """
  Normalizes adapter classifier/cache output into a Spectre route.
  """
  @spec route_from_result(map() | Route.t(), [Rule.t()], [atom()], atom()) :: Route.t()
  def route_from_result(%Route{} = route, rules, labels, strategy) do
    route
    |> provider_result_attrs()
    |> route_from_result(rules, labels, strategy)
  end

  def route_from_result(result, rules, labels, strategy) when is_map(result) do
    label = label_from_result(result, rules)
    scope = result_scope(result)
    rule = result_rule(label, scope, rules)
    label = label || raw_label_from_result(result)

    result
    |> put_result_rule(rule, label, scope)
    |> Map.put_new(:strategy, Map.get(result, :strategy, strategy))
    |> Map.put(:labels, labels)
    |> Route.new()
  end

  @spec provider_result_attrs(Route.t()) :: map()
  defp provider_result_attrs(
         %Route{
           rule: nil,
           handler: nil,
           owner: nil,
           scope: :agent
         } = route
       ) do
    route
    |> Map.from_struct()
    |> Map.put(:scope, nil)
  end

  defp provider_result_attrs(%Route{} = route), do: Map.from_struct(route)

  @spec put_result_rule(map(), Rule.t() | nil, term(), term()) :: map()
  defp put_result_rule(result, %Rule{} = rule, label, _scope) do
    result
    |> Map.put(:label, label)
    |> Map.put(:flow, rule.flow)
    |> Map.put(:handler, rule.handler)
    |> Map.put(:owner, rule.owner)
    |> Map.put(:scope, rule.scope)
    |> Map.put(:rule, rule)
    |> Map.put(:injections, rule.injections)
    |> Map.put(:definition_injections, rule.definition_injections)
  end

  defp put_result_rule(result, nil, label, scope) do
    result
    |> Map.put(:label, label)
    |> Map.put(:flow, nil)
    |> Map.put(:handler, nil)
    |> Map.put(:owner, nil)
    |> Map.put(:scope, scope)
    |> Map.put(:rule, nil)
    |> Map.put(:injections, [])
    |> Map.put(:definition_injections, [])
  end

  @doc false
  @spec route_rule(Route.t(), [Rule.t()]) :: Rule.t() | nil
  def route_rule(%Route{rule: %Rule{} = rule}, _rules), do: rule
  def route_rule(%Route{} = route, rules), do: result_rule(route.label, route.scope, rules)

  @doc """
  Adds labels to a route-like map.
  """
  @spec with_labels(map(), [atom()]) :: Route.t()
  def with_labels(result, labels), do: result |> Map.put(:labels, labels) |> Route.new()

  @doc """
  Builds a degraded fallback route from local classifier metadata.
  """
  @spec fallback_route([atom()], map(), term()) :: Route.t()
  def fallback_route(labels, %{label: label, confidence: confidence} = local_result, reason)
      when is_atom(label) and is_number(confidence) and confidence >= 0.75 do
    local_result
    |> Map.put(:accepted?, true)
    |> Map.put(:strategy, :local_classifier_degraded)
    |> Map.put(:labels, labels)
    |> Map.put(:fallback_error, reason)
    |> Route.new()
  end

  def fallback_route(labels, local_result, reason) do
    Route.new(%{
      label: :unknown,
      confidence: nil,
      margin: nil,
      scores: %{},
      accepted?: false,
      strategy: :unknown,
      labels: labels,
      local: local_result,
      fallback_error: reason
    })
  end

  @doc """
  Applies terminal routing metadata.
  """
  @spec terminalize(map(), keyword()) :: Route.t()
  def terminalize(route, opts) when is_map(route) do
    terminal_labels =
      Keyword.get(opts, :terminal_labels, Keyword.get(opts, :terminal_intents, []))

    high_threshold = Keyword.get(opts, :high_confidence_threshold, 0.9)
    confidence = Map.get(route, :confidence)

    terminal? =
      Map.get(route, :accepted?) == true and
        is_number(confidence) and
        confidence >= high_threshold and
        Map.get(route, :label) in terminal_labels

    route
    |> Map.put(:terminal?, terminal?)
    |> Map.put(
      :escalation_reason,
      escalation_reason(route, terminal?, terminal_labels, high_threshold)
    )
    |> Route.new()
  end

  @doc """
  Logs router messages when classification logging is enabled.
  """
  @spec log(atom(), String.t(), keyword()) :: :ok
  def log(level, message, opts) do
    if Keyword.get(opts, :classification_log?, true) do
      Logger.log(level, "spectre_router #{message}")
    end
  end

  @doc """
  Logs route score summaries.
  """
  @spec log_route(atom(), String.t(), map(), keyword()) :: :ok
  def log_route(level, stage, route, opts) do
    log(
      level,
      "#{stage} label=#{inspect(Map.get(route, :label))} strategy=#{Map.get(route, :strategy)} " <>
        "accepted=#{inspect(Map.get(route, :accepted?))} confidence=#{fmt(Map.get(route, :confidence))} " <>
        "margin=#{fmt(Map.get(route, :margin))} top=#{top_scores(Map.get(route, :scores, %{}))}",
      opts
    )
  end

  @doc """
  Summarizes local classifier state for logs.
  """
  @spec summarize_local(term()) :: String.t()
  def summarize_local(%{label: label, strategy: strategy, confidence: confidence, margin: margin}) do
    "#{strategy}:#{label}:confidence=#{fmt(confidence)}:margin=#{fmt(margin)}"
  end

  def summarize_local(%{strategy: strategy, error: error}),
    do: "#{strategy}:error=#{format_reason(error)}"

  def summarize_local(other), do: inspect(other, limit: 4, printable_limit: 240)

  @doc """
  Formats fallback reasons for logs.
  """
  @spec format_reason(term()) :: String.t()
  def format_reason(reason), do: inspect(reason, limit: 8, printable_limit: 400)

  @spec raw_label_from_result(map()) :: term()
  defp raw_label_from_result(result) do
    Map.get(result, :label) || Map.get(result, :intent) || Map.get(result, "label") ||
      Map.get(result, "intent")
  end

  @spec label_from_result(map(), [Rule.t()]) :: atom() | nil
  defp label_from_result(result, rules) do
    raw = raw_label_from_result(result)

    Enum.find_value(rules, fn rule ->
      if same_label?(rule.label, raw), do: rule.label
    end)
  end

  @spec result_scope(map()) :: Spectre.Definition.scope() | nil
  defp result_scope(result), do: Map.get(result, :scope) || Map.get(result, "scope")

  @spec result_rule(atom() | nil, term(), [Rule.t()]) :: Rule.t() | nil
  defp result_rule(nil, _scope, _rules), do: nil

  defp result_rule(label, nil, rules) do
    case Enum.filter(rules, &(&1.label == label)) do
      [rule] -> rule
      _ambiguous_or_missing -> nil
    end
  end

  defp result_rule(label, scope, rules) do
    Enum.find(rules, &(&1.label == label and &1.scope == scope))
  end

  @spec same_label?(atom(), term()) :: boolean()
  defp same_label?(label, raw) when is_atom(raw), do: label == raw

  defp same_label?(label, raw) when is_binary(raw),
    do: String.upcase(to_string(label)) == String.upcase(raw)

  defp same_label?(_label, _raw), do: false

  @spec escalation_reason(map(), boolean(), [atom()], float()) :: String.t() | nil
  defp escalation_reason(_route, true, _terminal_labels, _high_threshold), do: nil

  defp escalation_reason(route, false, terminal_labels, high_threshold) do
    cond do
      Map.get(route, :accepted?) != true -> "not_accepted"
      Map.get(route, :label) not in terminal_labels -> "non_terminal_label"
      not is_number(Map.get(route, :confidence)) -> "unscored"
      Map.get(route, :confidence) < high_threshold -> "below_high_confidence"
      true -> "escalate"
    end
  end

  @spec fmt(term()) :: String.t()
  defp fmt(number) when is_float(number), do: :erlang.float_to_binary(number, decimals: 4)
  defp fmt(number) when is_integer(number), do: Integer.to_string(number)
  defp fmt(nil), do: "nil"
  defp fmt(other), do: inspect(other)

  @spec top_scores(map()) :: String.t()
  defp top_scores(scores) when is_map(scores) do
    scores
    |> Enum.sort_by(fn {_label, score} -> score end, :desc)
    |> Enum.take(3)
    |> Enum.map_join(",", fn {label, score} -> "#{label}:#{fmt(score)}" end)
    |> case do
      "" -> "none"
      text -> text
    end
  end

  defp top_scores(_scores), do: "none"
end
