defmodule Spectre.Router.LLMClassifier do
  @moduledoc """
  One-label LLM fallback classifier for Spectre routes.
  """

  alias Spectre.Route

  @doc """
  Asks a configured LLM completion function to return exactly one label.
  """
  @spec classify(String.t(), [atom()], keyword()) :: {:ok, Route.t()} | {:error, term()}
  def classify(text, labels, opts \\ []) when is_binary(text) and is_list(labels) do
    with {:ok, complete} <- complete_fun(opts),
         {:ok, prompt_text} <- prompt(text, labels, opts),
         {:ok, model_text} <- complete.(prompt_text, llm_opts(opts)),
         {:ok, label} <- normalize_label(model_text, labels) do
      {:ok,
       Route.new(%{
         label: label,
         confidence: 0.0,
         margin: 0.0,
         scores: %{},
         accepted?: true,
         strategy: :llm_classifier,
         raw: model_text
       })}
    end
  end

  @spec complete_fun(keyword()) :: {:ok, function()} | {:error, term()}
  defp complete_fun(opts) do
    if Keyword.has_key?(opts, :model) do
      {:ok, &Spectre.LLM.complete(&1, Keyword.merge(opts, &2))}
    else
      {:error, :missing_llm_classifier_model}
    end
  end

  @spec prompt(String.t(), [atom()], keyword()) :: {:ok, String.t()} | {:error, term()}
  defp prompt(text, labels, opts) do
    assigns = %{text: text, labels: labels, recent_chat: Keyword.get(opts, :recent_chat, "none")}

    case Keyword.get(opts, :classifier_prompt) do
      fun when is_function(fun, 1) -> normalize_prompt_result(fun.(assigns))
      nil -> {:ok, default_prompt(assigns)}
    end
  end

  @spec normalize_prompt_result(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_prompt_result({:ok, prompt}) when is_binary(prompt), do: {:ok, prompt}
  defp normalize_prompt_result(prompt) when is_binary(prompt), do: {:ok, prompt}
  defp normalize_prompt_result(other), do: {:error, {:invalid_classifier_prompt, other}}

  @spec default_prompt(map()) :: String.t()
  defp default_prompt(%{text: text, labels: labels, recent_chat: recent_chat}) do
    """
    Classify the latest message into exactly ONE label.
    Reply with the label only, no explanation.

    Available labels:
    #{Enum.map_join(labels, "\n", &to_string/1)}

    Recent chat:
    #{recent_chat}

    Latest message:
    #{text}
    """
  end

  @spec llm_opts(keyword()) :: keyword()
  defp llm_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> Keyword.put_new(:purpose, :classifier)
    |> Keyword.put_new(:temperature, 0.0)
    |> Keyword.put_new(:max_tokens, 8)
  end

  @spec normalize_label(term(), [atom()]) :: {:ok, atom()}
  defp normalize_label(text, labels) do
    normalized_text =
      text
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z_]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    tokens = String.split(normalized_text)

    {:ok, Enum.find(labels, :unknown, &label_present?(&1, normalized_text, tokens))}
  end

  @spec label_present?(atom(), String.t(), [String.t()]) :: boolean()
  defp label_present?(label, normalized_text, tokens) do
    normalized_label = label |> to_string() |> String.upcase()
    label_words = String.replace(normalized_label, "_", " ")

    normalized_label in tokens or
      String.contains?(" #{normalized_text} ", " #{normalized_label} ") or
      String.contains?(" #{normalized_text} ", " #{label_words} ")
  end
end
