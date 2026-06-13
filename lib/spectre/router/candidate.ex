defmodule Spectre.Router.Candidate do
  @moduledoc """
  A single routing signal produced by a router evidence provider.

  Candidates let router plugs report what they know without deciding the final
  route. The arbitrator can then compare hard regex matches, classifier scores,
  semantic cache hits, and other evidence with one common shape.
  """

  defstruct [
    :label,
    :flow,
    :handler,
    :provider,
    :rule,
    :score,
    :margin,
    :strength,
    :raw,
    :matched,
    :metadata,
    accepted?: false,
    terminal?: false
  ]

  @type strength :: :hard | :strong | :medium | :weak

  @type t :: %__MODULE__{
          label: atom() | nil,
          flow: atom() | nil,
          handler: Spectre.Rule.handler() | nil,
          provider: atom(),
          rule: Spectre.Rule.t() | nil,
          score: float() | nil,
          margin: float() | nil,
          strength: strength(),
          raw: term(),
          matched: term(),
          metadata: map() | nil,
          accepted?: boolean(),
          terminal?: boolean()
        }

  @doc """
  Builds a candidate from a compiled rule match.

      candidate = Spectre.Router.Candidate.from_rule(rule, :regex, input.text)
  """
  @spec from_rule(Spectre.Rule.t(), atom(), String.t(), keyword()) :: t()
  def from_rule(%Spectre.Rule{} = rule, provider, raw, opts \\ []) do
    score = Keyword.get(opts, :score, 1.0)

    new(%{
      label: rule.label,
      flow: rule.flow,
      handler: rule.handler,
      provider: provider,
      rule: rule,
      score: score,
      margin: Keyword.get(opts, :margin),
      strength: strength(rule, provider, opts),
      raw: raw,
      matched: Keyword.get(opts, :matched),
      metadata: Keyword.get(opts, :metadata, %{}),
      accepted?: Keyword.get(opts, :accepted?, true),
      terminal?: Keyword.get(opts, :terminal?, false)
    })
  end

  @doc """
  Builds a candidate from an adapter result map.

      candidate =
        Spectre.Router.Candidate.from_result(%{label: :help, confidence: 0.94}, rule, :classifier)
  """
  @spec from_result(map() | Spectre.Route.t(), Spectre.Rule.t() | nil, atom(), keyword()) :: t()
  def from_result(result, rule, provider, opts \\ [])

  def from_result(%Spectre.Route{} = route, rule, provider, opts) do
    route
    |> Map.from_struct()
    |> from_result(rule, provider, opts)
  end

  def from_result(result, rule, provider, opts) when is_map(result) do
    new(%{
      label: (rule && rule.label) || raw_label(result),
      flow: rule && rule.flow,
      handler: rule && rule.handler,
      provider: provider,
      rule: rule,
      score: Map.get(result, :confidence) || Map.get(result, :score),
      margin: Map.get(result, :margin),
      strength: strength(rule, provider, opts),
      raw: Map.get(result, :raw),
      matched: Keyword.get(opts, :matched),
      metadata: Map.merge(Map.get(result, :metadata, %{}), Keyword.get(opts, :metadata, %{})),
      accepted?: Map.get(result, :accepted?, false),
      terminal?: Map.get(result, :terminal?, false)
    })
  end

  @doc """
  Converts the winning candidate into a Spectre route.

      route = Spectre.Router.Candidate.to_route(candidate, [:help, :fallback])
  """
  @spec to_route(t(), [atom()]) :: Spectre.Route.t()
  def to_route(%__MODULE__{} = candidate, labels \\ []) do
    Spectre.Route.new(%{
      label: candidate.label,
      flow: candidate.flow,
      handler: candidate.handler,
      strategy: candidate.provider,
      confidence: candidate.score,
      margin: candidate.margin,
      accepted?: candidate.accepted?,
      raw: candidate.raw,
      labels: labels,
      terminal?: candidate.terminal?,
      scores: %{candidate.label => candidate.score || 0.0}
    })
  end

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @spec raw_label(map()) :: atom() | nil
  defp raw_label(result) do
    Map.get(result, :label) || Map.get(result, :intent) || Map.get(result, "label") ||
      Map.get(result, "intent")
  end

  @spec strength(Spectre.Rule.t() | nil, atom(), keyword()) :: strength()
  defp strength(%Spectre.Rule{global?: true} = rule, provider, opts) do
    rule_strength(rule, provider, Keyword.get(opts, :strength, :hard))
  end

  defp strength(%Spectre.Rule{} = rule, provider, opts) do
    rule_strength(rule, provider, Keyword.get(opts, :strength, :weak))
  end

  defp strength(nil, _provider, opts), do: Keyword.get(opts, :strength, :medium)

  defp rule_strength(%Spectre.Rule{opts: opts}, provider, default) do
    Keyword.get(opts, :"#{provider}_strength", Keyword.get(opts, :strength, default))
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
