defmodule Spectre.Router.Plugs.BagDistance do
  @moduledoc """
  Bag-distance evidence provider for short example matching.

  This plug is useful for compact deterministic examples where word overlap is
  a better signal than a strict regex. It produces scored candidates and lets
  the arbitrator decide whether the score is strong enough for the turn.

      on :list_projects, bag: ["show projects", "list my projects"] do
        reply :project_list
      end
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: collect(context)
  end

  @spec collect(Context.t()) :: {:cont, Context.t()}
  defp collect(%Context{input: %{text: text}, rules: rules} = context) do
    normalized_text = normalize(text)

    candidates =
      rules
      |> Support.rules_for(:bag, context.input)
      |> Enum.flat_map(&candidate(&1, text, normalized_text))

    {:cont, Context.add_candidates(context, candidates)}
  end

  @spec candidate(Spectre.Rule.t(), term(), String.t()) :: [Candidate.t()]
  defp candidate(%Spectre.Rule{bag: []}, _text, _normalized_text), do: []

  defp candidate(%Spectre.Rule{} = rule, text, normalized_text) do
    {example, score} =
      rule.bag
      |> Enum.map(&{&1, String.bag_distance(normalized_text, normalize(&1))})
      |> Enum.max_by(fn {_example, score} -> score end, fn -> {nil, 0.0} end)

    if example do
      [
        Candidate.from_rule(rule, :bag, text,
          score: score,
          matched: example,
          metadata: %{examples: rule.bag}
        )
      ]
    else
      []
    end
  end

  @spec normalize(term()) :: String.t()
  defp normalize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
