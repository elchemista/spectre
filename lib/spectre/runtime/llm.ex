defmodule Spectre.LLM do
  @moduledoc """
  Small LLM boundary used by `Spectre.Runner`.

  The runner sends already-rendered prompts here. Adapters can be configured as
  modules, `{module, function}` tuples, `{module, function, opts}` tuples, or
  functions. A fallback model can be configured without changing prompt or
  runner code.
  """

  @callback complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Completes a rendered prompt through the configured model adapter or function.

      Spectre.LLM.complete("Say hello", model: {MyApp.LLM, :complete, model: "small"})
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) when is_binary(prompt) do
    prompt
    |> do_complete(opts)
    |> maybe_fallback(prompt, opts)
  end

  @spec do_complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defp do_complete(prompt, opts) do
    cond do
      model = Keyword.get(opts, :model) ->
        call_model(model, prompt, opts)

      adapter = Keyword.get(opts, :adapter) ->
        adapter.complete(prompt, opts)

      adapter = Application.get_env(:spectre, :llm_adapter) ->
        adapter.complete(prompt, opts)

      true ->
        {:error, :missing_llm_adapter}
    end
  end

  @spec maybe_fallback({:ok, String.t()} | {:error, term()}, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp maybe_fallback({:ok, _text} = ok, _prompt, _opts), do: ok

  defp maybe_fallback({:error, reason} = error, prompt, opts) do
    case fallback_model(opts) do
      nil ->
        error

      fallback ->
        fallback_opts =
          opts
          |> Keyword.delete(:model)
          |> Keyword.delete(:adapter)
          |> Keyword.delete(:fallback)
          |> Keyword.put(:primary_error, reason)

        case call_model(fallback, prompt, fallback_opts) do
          {:ok, _text} = ok -> ok
          {:error, fallback_reason} -> {:error, {:llm_fallback_failed, reason, fallback_reason}}
        end
    end
  end

  @spec fallback_model(keyword()) :: term() | nil
  defp fallback_model(opts) do
    Keyword.get(opts, :fallback) || fallback_from_model(Keyword.get(opts, :model))
  end

  @spec fallback_from_model(term()) :: term() | nil
  defp fallback_from_model({_module, _function, model_opts}) when is_list(model_opts) do
    Keyword.get(model_opts, :fallback)
  end

  defp fallback_from_model(_model), do: nil

  @spec call_model_fun(function() | term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp call_model_fun(fun, prompt, opts) when is_function(fun, 2), do: fun.(prompt, opts)
  defp call_model_fun(fun, prompt, _opts) when is_function(fun, 1), do: fun.(prompt)
  defp call_model_fun(other, _prompt, _opts), do: {:error, {:invalid_model, other}}

  @spec call_model(
          function() | module() | {module(), atom()} | {module(), atom(), keyword()} | term(),
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  defp call_model({module, function, adapter_opts}, prompt, opts)
       when is_atom(module) and is_atom(function) and is_list(adapter_opts) do
    apply(module, function, [prompt, model_opts(adapter_opts, opts)])
  end

  defp call_model({module, function}, prompt, opts)
       when is_atom(module) and is_atom(function) do
    apply(module, function, [prompt, Keyword.delete(opts, :model)])
  end

  defp call_model(module, prompt, opts) when is_atom(module) do
    module.complete(prompt, Keyword.delete(opts, :model))
  end

  defp call_model(fun, prompt, opts),
    do: call_model_fun(fun, prompt, Keyword.delete(opts, :model))

  @spec model_opts(keyword(), keyword()) :: keyword()
  defp model_opts(adapter_opts, opts) do
    Keyword.merge(adapter_opts, Keyword.delete(opts, :model))
  end
end
