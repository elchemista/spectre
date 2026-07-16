defmodule Spectre.Router.LocalClassifier do
  @moduledoc """
  Adapter boundary for local intent classifiers.

  Configure one of:

    * `classify: &MyClassifier.classify/2`
    * `classifier_local: MyClassifier`
    * `classifier_local: {MyClassifier, :classify}`
    * `classifier MyLLM, local: MyClassifier` in an agent DSL

  If no explicit adapter is configured, Spectre tries its own classifier
  artifact through `Spectre.Classifier`.
  """

  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @doc """
  Classifies text through the configured local classifier.
  """
  @spec classify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify(text, opts) when is_binary(text) and is_list(opts) do
    local_opts = local_opts(opts)

    case Call.run(:local_classifier, fn -> dispatch(text, opts, local_opts) end, local_opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, Failure.invalid_reply(:local_classifier, other)}
      {:error, _reason} = error -> error
    end
  end

  @spec dispatch(String.t(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp dispatch(text, opts, local_opts) do
    cond do
      classify = Keyword.get(opts, :classify) ->
        call_classifier(classify, text, local_opts)

      classifier = Keyword.get(opts, :classifier_local) ->
        call_classifier(classifier, text, local_opts)

      classifier = classifier_local(opts) ->
        call_classifier(classifier, text, local_opts)

      true ->
        call_classifier(Spectre.Classifier, text, local_opts)
    end
  end

  @spec call_classifier(
          function() | module() | {module(), atom()} | term(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  defp call_classifier(fun, text, opts) when is_function(fun, 2), do: fun.(text, opts)
  defp call_classifier(fun, text, _opts) when is_function(fun, 1), do: fun.(text)
  defp call_classifier(module, text, opts) when is_atom(module), do: module.classify(text, opts)
  defp call_classifier({module, function}, text, opts), do: apply(module, function, [text, opts])
  defp call_classifier(other, _text, _opts), do: {:error, {:invalid_classifier_adapter, other}}

  @spec classifier_local(keyword()) :: term() | nil
  defp classifier_local(opts) do
    opts
    |> classifier_config()
    |> Keyword.get(:local)
  end

  @spec local_opts(keyword()) :: keyword()
  defp local_opts(opts) do
    opts
    |> classifier_config()
    |> Keyword.get(:local_opts, [])
    |> Keyword.merge(opts)
  end

  @spec classifier_config(keyword()) :: keyword()
  defp classifier_config(opts) do
    case Keyword.get(opts, :classifier, []) do
      config when is_list(config) -> config
      _other -> []
    end
  end
end
