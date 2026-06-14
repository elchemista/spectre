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

  alias Spectre.Router.SemanticCache.Learned

  @callback lookup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback clear(module(), keyword()) :: :ok | {:ok, term()} | {:error, term()}

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

      learned_cache?(opts) ->
        Learned.lookup(text, opts)

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

  @doc """
  Clears semantic-cache state for an agent.

  Spectre's built-in learned cache is always cleared. When a custom
  `semantic_cache:` module is configured, that adapter must also implement
  `clear/2`.
  """
  @spec clear(module(), keyword()) :: :ok | {:error, term()}
  def clear(agent, opts \\ [])

  def clear(agent, opts) when is_atom(agent) and is_list(opts) do
    with {:ok, clear_opts} <- clear_opts(agent, opts),
         :ok <- Learned.clear(agent, clear_opts) do
      clear_adapter(agent, clear_opts)
    end
  rescue
    exception ->
      {:error, {:semantic_cache_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:semantic_cache_exit, reason}}
    kind, reason -> {:error, {:semantic_cache_failure, kind, reason}}
  end

  def clear(agent, _opts), do: {:error, {:invalid_agent, agent}}

  @spec call_lookup(function() | module() | {module(), atom()} | term(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp call_lookup(fun, text, opts) when is_function(fun, 2), do: fun.(text, opts)
  defp call_lookup(fun, text, _opts) when is_function(fun, 1), do: fun.(text)
  defp call_lookup(module, text, opts) when is_atom(module), do: module.lookup(text, opts)
  defp call_lookup({module, function}, text, opts), do: apply(module, function, [text, opts])
  defp call_lookup(other, _text, _opts), do: {:error, {:invalid_semantic_cache_adapter, other}}

  @spec learned_cache?(keyword()) :: boolean()
  defp learned_cache?(opts) do
    opts
    |> Keyword.get(:spectre_rules, [])
    |> Enum.any?(&Map.get(&1, :learn, false))
  end

  @spec clear_opts(module(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp clear_opts(agent, opts) do
    if valid_agent?(agent) do
      clear_opts =
        agent.__spectre_router__()
        |> Keyword.merge(opts)
        |> Keyword.put_new(:spectre_agent, agent)
        |> Keyword.put_new(:spectre_rules, spectre_rules(agent))

      {:ok, clear_opts}
    else
      {:error, {:invalid_agent, agent}}
    end
  end

  @spec valid_agent?(module()) :: boolean()
  defp valid_agent?(agent) do
    Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_router__, 0)
  end

  @spec spectre_rules(module()) :: [Spectre.Rule.t()]
  defp spectre_rules(agent) do
    if function_exported?(agent, :__spectre_rules__, 0) do
      Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1)
    else
      []
    end
  end

  @spec clear_adapter(module(), keyword()) :: :ok | {:error, term()}
  defp clear_adapter(agent, opts) do
    cond do
      cache = Keyword.get(opts, :semantic_cache) ->
        call_clear(cache, agent, opts)

      Keyword.has_key?(opts, :semantic_lookup) ->
        {:error, :unclearable_semantic_lookup}

      true ->
        :ok
    end
  end

  @spec call_clear(module() | {module(), atom()} | term(), module(), keyword()) ::
          :ok | {:error, term()}
  defp call_clear(module, agent, opts) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_semantic_cache_adapter, module}}

      function_exported?(module, :clear, 2) ->
        normalize_clear_result(module.clear(agent, opts))

      true ->
        {:error, {:missing_semantic_cache_callback, module, :clear}}
    end
  end

  defp call_clear({module, _lookup_function}, agent, opts) when is_atom(module) do
    call_clear(module, agent, opts)
  end

  defp call_clear(other, _agent, _opts), do: {:error, {:invalid_semantic_cache_adapter, other}}

  @spec normalize_clear_result(term()) :: :ok | {:error, term()}
  defp normalize_clear_result(:ok), do: :ok
  defp normalize_clear_result({:ok, _value}), do: :ok
  defp normalize_clear_result({:error, reason}), do: {:error, reason}
  defp normalize_clear_result(other), do: {:error, {:invalid_semantic_cache_clear_result, other}}
end
