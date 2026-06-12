defmodule Spectre.Router.LocalClassifier do
  @moduledoc """
  Adapter boundary for local intent classifiers.

  Configure one of:

    * `classify: &MyClassifier.classify/2`
    * `classifier: MyClassifier`
    * `classifier: {MyClassifier, :classify}`

  If no explicit adapter is configured, Spectre tries its own classifier
  artifact through `Spectre.Classifier`.
  """

  @doc """
  Classifies text through the configured local classifier.
  """
  @spec classify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify(text, opts) when is_binary(text) and is_list(opts) do
    cond do
      classify = Keyword.get(opts, :classify) ->
        call_classifier(classify, text, opts)

      classifier = Keyword.get(opts, :classifier) ->
        call_classifier(classifier, text, opts)

      true ->
        call_classifier(Spectre.Classifier, text, opts)
    end
  rescue
    exception ->
      {:error, {:classifier_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:classifier_exit, reason}}
    kind, reason -> {:error, {:classifier_failure, kind, reason}}
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
end
