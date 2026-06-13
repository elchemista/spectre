defmodule Spectre.Router.Plugs.BagDistance do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.{Candidate, Context, Support}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    if Context.halted?(context), do: {:cont, context}, else: collect(context)
  end

  defp collect(%Context{input: %{text: text}, rules: rules} = context) do
    candidates =
      rules
      |> Support.rules_for(:bag, context.input)
      |> Enum.flat_map(&candidate(&1, text))

    {:cont, Context.add_candidates(context, candidates)}
  end

  defp candidate(%Spectre.Rule{bag: []}, _text), do: []

  defp candidate(%Spectre.Rule{} = rule, text) do
    {example, score} =
      rule.bag
      |> Enum.map(&{&1, String.bag_distance(normalize(text), normalize(&1))})
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

  defp normalize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
