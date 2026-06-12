defmodule Spectre.LLM do
  @moduledoc """
  Small LLM boundary used by `Spectre.Runner`.
  """

  @callback complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Completes a rendered prompt through the configured LLM adapter or function.
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) when is_binary(prompt) do
    cond do
      complete = Keyword.get(opts, :complete) ->
        call_complete(complete, prompt, opts)

      adapter = Keyword.get(opts, :adapter) ->
        adapter.complete(prompt, opts)

      adapter = Application.get_env(:spectre, :llm_adapter) ->
        adapter.complete(prompt, opts)

      true ->
        {:error, :missing_llm_adapter}
    end
  end

  @spec call_complete_fun(function() | term(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp call_complete_fun(fun, prompt, opts) when is_function(fun, 2), do: fun.(prompt, opts)
  defp call_complete_fun(fun, prompt, _opts) when is_function(fun, 1), do: fun.(prompt)
  defp call_complete_fun(other, _prompt, _opts), do: {:error, {:invalid_complete, other}}

  @spec call_complete(
          function() | module() | {module(), atom()} | {module(), atom(), keyword()} | term(),
          String.t(),
          keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  defp call_complete({module, function, adapter_opts}, prompt, opts)
       when is_atom(module) and is_atom(function) and is_list(adapter_opts) do
    apply(module, function, [prompt, Keyword.merge(adapter_opts, opts)])
  end

  defp call_complete({module, function}, prompt, opts)
       when is_atom(module) and is_atom(function) do
    apply(module, function, [prompt, opts])
  end

  defp call_complete(module, prompt, opts) when is_atom(module), do: module.complete(prompt, opts)
  defp call_complete(fun, prompt, opts), do: call_complete_fun(fun, prompt, opts)
end
