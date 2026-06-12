defmodule Spectre.Router.SemanticCache do
  @moduledoc """
  Adapter boundary for semantic cache lookups.

  Configure one of:

    * `semantic_lookup: &MyCache.lookup/2`
    * `semantic_cache: MyCache`
    * `semantic_cache: {MyCache, :lookup}`

  The adapter should return `{:ok, map}` for accepted route-like results or
  `{:error, reason}` for misses.
  """

  @doc """
  Looks up a message in the configured semantic cache.
  """
  @spec lookup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def lookup(text, opts) when is_binary(text) and is_list(opts) do
    cond do
      lookup = Keyword.get(opts, :semantic_lookup) ->
        call_lookup(lookup, text, opts)

      cache = Keyword.get(opts, :semantic_cache) ->
        call_lookup(cache, text, opts)

      true ->
        {:error, :missing_semantic_cache_adapter}
    end
  rescue
    exception ->
      {:error, {:semantic_cache_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:semantic_cache_exit, reason}}
    kind, reason -> {:error, {:semantic_cache_failure, kind, reason}}
  end

  @spec call_lookup(function() | module() | {module(), atom()} | term(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp call_lookup(fun, text, opts) when is_function(fun, 2), do: fun.(text, opts)
  defp call_lookup(fun, text, _opts) when is_function(fun, 1), do: fun.(text)
  defp call_lookup(module, text, opts) when is_atom(module), do: module.lookup(text, opts)
  defp call_lookup({module, function}, text, opts), do: apply(module, function, [text, opts])
  defp call_lookup(other, _text, _opts), do: {:error, {:invalid_semantic_cache_adapter, other}}
end
