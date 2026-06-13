defmodule Spectre.Router.Plugs.JaroDistance do
  @moduledoc """
  Jaro-distance evidence provider for typo-tolerant short examples.

  Jaro matching is intentionally a router plug rather than a rule-level special
  case. Keeping each evidence source in its own plug makes the arbitration step
  explicit and lets agents opt into only the strategies they need.

      on :help, jaro: ["help", "support", "assist me"] do
        reply :help
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

  defp collect(%Context{input: %{text: text}, rules: rules} = context) do
    candidates =
      rules
      |> Support.rules_for(:jaro, context.input)
      |> Enum.flat_map(&candidate(&1, text))

    {:cont, Context.add_candidates(context, candidates)}
  end

  defp candidate(%Spectre.Rule{jaro: []}, _text), do: []

  defp candidate(%Spectre.Rule{} = rule, text) do
    {example, score} =
      rule.jaro
      |> Enum.map(&{&1, String.jaro_distance(normalize(text), normalize(&1))})
      |> Enum.max_by(fn {_example, score} -> score end, fn -> {nil, 0.0} end)

    if example do
      [
        Candidate.from_rule(rule, :jaro, text,
          score: score,
          matched: example,
          metadata: %{examples: rule.jaro}
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
