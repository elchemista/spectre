defmodule Spectre.Route do
  @moduledoc """
  Normalized routing decision returned by Spectre.

  A route is the stable handoff between router and runner. It contains the
  selected label, handler, strategy, scores, and metadata needed for logging or
  host decisions.
  """

  defstruct [
    :label,
    :flow,
    :handler,
    :owner,
    :rule,
    :core_route,
    scope: :agent,
    injections: [],
    definition_injections: [],
    strategy: :unknown,
    confidence: 0.0,
    margin: 0.0,
    accepted?: false,
    scores: %{},
    raw: nil,
    labels: [],
    local: nil,
    fallback_error: nil,
    semantic_cache: nil,
    semantic_cache_after: nil,
    semantic_examples: [],
    terminal?: false,
    escalation_reason: nil
  ]

  @type t :: %__MODULE__{
          label: atom() | nil,
          flow: atom() | nil,
          handler: Spectre.Rule.handler() | nil,
          owner: module() | nil,
          scope: Spectre.Definition.scope(),
          rule: Spectre.Rule.t() | nil,
          injections: [Spectre.Prompt.Operation.t()],
          definition_injections: [Spectre.Prompt.Operation.t()],
          strategy: atom(),
          confidence: float() | nil,
          margin: float() | nil,
          accepted?: boolean(),
          scores: map(),
          raw: term(),
          labels: [atom()],
          local: map() | nil,
          fallback_error: term(),
          semantic_cache: term(),
          semantic_cache_after: term(),
          semantic_examples: [map()],
          terminal?: boolean(),
          escalation_reason: String.t() | nil,
          core_route: term()
        }

  @doc """
  Builds a normalized route struct.

      route = Spectre.Route.new(label: :hello, accepted?: true)
  """
  @spec new(map() | t()) :: t()
  def new(%__MODULE__{} = route), do: route

  def new(attrs) when is_map(attrs) do
    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @doc """
  Builds an accepted deterministic route from a compiled rule.

      route = Spectre.Route.from_rule(rule, :regex, "hello")
  """
  @spec from_rule(Spectre.Rule.t(), atom(), String.t()) :: t()
  def from_rule(%Spectre.Rule{} = rule, strategy, raw) do
    new(%{
      label: rule.label,
      flow: rule.flow,
      handler: rule.handler,
      owner: rule.owner,
      scope: rule.scope,
      rule: rule,
      injections: rule.injections,
      definition_injections: rule.definition_injections,
      strategy: strategy,
      confidence: 1.0,
      margin: 1.0,
      accepted?: true,
      scores: %{rule.label => 1.0},
      raw: raw
    })
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
