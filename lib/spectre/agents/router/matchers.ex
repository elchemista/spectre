defmodule Spectre.Router.Matchers do
  @moduledoc """
  Local regex, string-bag and Jaro matchers. Regex is compiled once; fuzzy
  examples are NFC-normalized, lowercased and whitespace-normalized once.
  No embeddings, model calls, caches or external I/O are implicit here.
  """

  use Spectre.Router.Adapter

  @impl true
  def prepare(data, opts) do
    case Keyword.fetch!(opts, :method) do
      "regex" -> compile_regex(data)
      method when method in ["string_bag", "bag_distance", "jaro"] -> examples(data)
    end
  end

  @impl true
  def evaluate(%{input: input, rules: rules}, opts) when is_binary(input) do
    if String.valid?(input) do
      score_rules(rules, input, Keyword.fetch!(opts, :method))
    else
      {:error, :invalid_router_text}
    end
  end

  def evaluate(_request, _opts), do: :skip

  defp score_rules(rules, input, "regex") do
    results =
      Enum.flat_map(rules, fn rule ->
        case Regex.named_captures(rule.data, input) do
          nil -> []
          captures -> [result(rule, 1.0, captures)]
        end
      end)

    {:ok, best(results)}
  end

  defp score_rules(rules, input, method) do
    normalized = normalize(input)
    scorer = if method == "jaro", do: &String.jaro_distance/2, else: &String.bag_distance/2

    results =
      Enum.map(rules, fn rule ->
        score = Enum.reduce(rule.data, 0.0, &max(scorer.(normalized, &1), &2))
        result(rule, score)
      end)

    {:ok, best(results)}
  end

  # Return the strongest nominations while preserving the runner-up needed for
  # ambiguity/margin checks. The contract's bound applies to built-ins too.
  defp best(results), do: results |> Enum.sort_by(&{-&1.score, &1.rule}) |> Enum.take(32)

  defp compile_regex(source) when is_binary(source),
    do: compile_regex(%{"source" => source, "options" => "u"})

  defp compile_regex(%{"source" => source, "options" => opts} = data)
       when map_size(data) == 2 and is_binary(source) and (is_binary(opts) or is_list(opts)) do
    case Regex.compile(source, opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, :invalid_router_regex}
    end
  rescue
    ArgumentError -> {:error, :invalid_router_regex}
  end

  defp compile_regex(_data), do: {:error, :invalid_router_regex}

  defp examples(value) when is_binary(value), do: examples([value])

  defp examples(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and String.valid?(&1) and String.trim(&1) != "")),
      do: {:ok, Enum.map(values, &normalize/1)},
      else: {:error, :invalid_router_examples}
  end

  defp examples(_values), do: {:error, :invalid_router_examples}

  defp normalize(text),
    do:
      text
      |> String.normalize(:nfc)
      |> String.downcase()
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
end
