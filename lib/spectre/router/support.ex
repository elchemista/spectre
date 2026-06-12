defmodule Spectre.Router.Support do
  @moduledoc false

  require Logger

  alias Spectre.{Route, Rule}

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
    |> Map.from_struct()
    |> route_from_result(rules, labels, strategy)
  end

  def route_from_result(result, rules, labels, strategy) when is_map(result) do
    label = label_from_result(result, rules)
    rule = Enum.find(rules, &(&1.label == label))

    result
    |> Map.put(:label, label || raw_label_from_result(result))
    |> Map.put_new(:flow, rule && rule.flow)
    |> Map.put_new(:handler, rule && rule.handler)
    |> Map.put_new(:strategy, Map.get(result, :strategy, strategy))
    |> Map.put_new(:labels, labels)
    |> Route.new()
  end

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
