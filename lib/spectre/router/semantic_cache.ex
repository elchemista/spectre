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
  @callback put(String.t(), map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback examples(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback get_example(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback relabel(module(), String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback delete(module(), String.t(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback verify(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback snapshot(module(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback load_snapshot(module(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  @callback clear(module(), keyword()) :: :ok | {:ok, term()} | {:error, term()}

  @optional_callbacks put: 3,
                      examples: 2,
                      get_example: 3,
                      relabel: 4,
                      delete: 3,
                      verify: 3,
                      snapshot: 2,
                      load_snapshot: 3,
                      clear: 2

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

      built_in_cache?(opts) ->
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
  Stores a semantic-cache example.
  """
  @spec put(String.t(), map(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def put(text, result, opts) when is_binary(text) and is_map(result) and is_list(opts) do
    safe(fn ->
      opts
      |> put_runtime_opts()
      |> put_with_runtime_opts(text, result)
    end)
  end

  def put(_text, result, _opts), do: {:error, {:invalid_semantic_cache_result, result}}

  @spec put_with_runtime_opts({:ok, keyword()} | {:error, term()}, String.t(), map()) ::
          :ok | {:ok, term()} | {:error, term()}
  defp put_with_runtime_opts({:ok, opts}, text, result) do
    cond do
      Keyword.has_key?(opts, :semantic_lookup) and is_nil(Keyword.get(opts, :semantic_cache)) ->
        learn_failure(:unwritable_semantic_lookup, opts)

      cache = Keyword.get(opts, :semantic_cache) ->
        call_optional(cache, :put, [text, result, opts], opts, learn_failure_mode(opts))

      true ->
        Learned.put(text, result, opts)
    end
  end

  defp put_with_runtime_opts({:error, reason}, _text, _result), do: {:error, reason}

  @doc """
  Lists semantic-cache examples for an agent.
  """
  @spec examples(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def examples(agent, opts \\ []) do
    with_runtime_opts(agent, opts, &examples_with_opts(agent, &1))
  end

  @doc """
  Fetches one semantic-cache example by id.
  """
  @spec get_example(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_example(agent, id, opts \\ []) do
    with_runtime_opts(agent, opts, &get_example_with_opts(agent, id, &1))
  end

  @doc """
  Relabels an online learned example and marks it verified.
  """
  @spec relabel(module(), String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def relabel(agent, id, new_label, opts \\ []) do
    with_runtime_opts(agent, opts, &relabel_with_opts(agent, id, new_label, &1))
  end

  @doc """
  Deletes an online learned example.
  """
  @spec delete(module(), String.t(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def delete(agent, id, opts \\ []) do
    with_runtime_opts(agent, opts, &delete_with_opts(agent, id, &1))
  end

  @doc """
  Marks an online learned example as verified.
  """
  @spec verify(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(agent, id, opts \\ []) do
    with_runtime_opts(agent, opts, &verify_with_opts(agent, id, &1))
  end

  @doc """
  Snapshots semantic-cache examples.
  """
  @spec snapshot(module(), keyword()) :: {:ok, term()} | {:error, term()}
  def snapshot(agent, opts \\ []) do
    with_runtime_opts(agent, opts, &snapshot_with_opts(agent, &1))
  end

  @doc """
  Loads online learned examples from a snapshot.
  """
  @spec load_snapshot(module(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def load_snapshot(agent, snapshot_or_opts, opts \\ []) do
    opts = snapshot_opts(snapshot_or_opts, opts)
    with_runtime_opts(agent, opts, &load_snapshot_with_opts(agent, snapshot_or_opts, &1))
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
    with {:ok, clear_opts} <- runtime_opts(agent, opts),
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

  @spec built_in_cache?(keyword()) :: boolean()
  defp built_in_cache?(opts) do
    opts
    |> Keyword.get(:spectre_rules, [])
    |> Enum.any?(&Map.get(&1, :cache, true))
  end

  @spec put_runtime_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp put_runtime_opts(opts) do
    case Keyword.get(opts, :spectre_agent) do
      nil -> {:ok, opts}
      agent -> runtime_opts(agent, opts)
    end
  end

  @spec runtime_opts(module(), keyword()) :: {:ok, keyword()} | {:error, term()}
  defp runtime_opts(agent, opts) do
    if valid_agent?(agent) do
      runtime_opts =
        agent.__spectre_router__()
        |> Keyword.merge(opts)
        |> Keyword.put_new(:spectre_agent, agent)
        |> Keyword.put_new(:spectre_rules, spectre_rules(agent))

      {:ok, runtime_opts}
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

  @spec with_runtime_opts(module(), keyword(), function()) :: term()
  defp with_runtime_opts(agent, opts, fun) when is_function(fun, 1) do
    safe(fn ->
      case runtime_opts(agent, opts) do
        {:ok, runtime_opts} -> fun.(runtime_opts)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec examples_with_opts(module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp examples_with_opts(agent, opts) do
    adapter_or_builtin(opts, :examples, [agent, opts], fn ->
      Learned.examples(agent, opts)
    end)
  end

  @spec get_example_with_opts(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp get_example_with_opts(agent, id, opts) do
    adapter_or_builtin(opts, :get_example, [agent, id, opts], fn ->
      Learned.get_example(agent, id, opts)
    end)
  end

  @spec relabel_with_opts(module(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp relabel_with_opts(agent, id, new_label, opts) do
    adapter_or_builtin(opts, :relabel, [agent, id, new_label, opts], fn ->
      Learned.relabel(agent, id, new_label, opts)
    end)
  end

  @spec delete_with_opts(module(), String.t(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  defp delete_with_opts(agent, id, opts) do
    adapter_or_builtin(opts, :delete, [agent, id, opts], fn ->
      Learned.delete(agent, id, opts)
    end)
  end

  @spec verify_with_opts(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp verify_with_opts(agent, id, opts) do
    adapter_or_builtin(opts, :verify, [agent, id, opts], fn ->
      Learned.verify(agent, id, opts)
    end)
  end

  @spec snapshot_with_opts(module(), keyword()) :: {:ok, term()} | {:error, term()}
  defp snapshot_with_opts(agent, opts) do
    adapter_or_builtin(opts, :snapshot, [agent, opts], fn ->
      Learned.snapshot(agent, opts)
    end)
  end

  @spec load_snapshot_with_opts(module(), term(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  defp load_snapshot_with_opts(agent, snapshot_or_opts, opts) do
    adapter_or_builtin(opts, :load_snapshot, [agent, snapshot_or_opts, opts], fn ->
      Learned.load_snapshot(agent, snapshot_or_opts, opts)
    end)
  end

  @spec adapter_or_builtin(keyword(), atom(), [term()], function()) :: term()
  defp adapter_or_builtin(opts, callback, args, builtin) when is_function(builtin, 0) do
    case Keyword.get(opts, :semantic_cache) do
      nil -> builtin.()
      cache -> call_optional(cache, callback, args, opts, :error)
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

  @spec call_optional(
          module() | {module(), atom()} | term(),
          atom(),
          [term()],
          keyword(),
          :ignore | :error
        ) ::
          term()
  defp call_optional(module, function, args, _opts, failure_mode) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_semantic_cache_adapter, module}}

      function_exported?(module, function, length(args)) ->
        apply(module, function, args)

      failure_mode == :ignore ->
        :ok

      true ->
        {:error, {:missing_semantic_cache_callback, module, function}}
    end
  end

  defp call_optional({module, _lookup_function}, function, args, opts, failure_mode)
       when is_atom(module) do
    call_optional(module, function, args, opts, failure_mode)
  end

  defp call_optional(other, _function, _args, _opts, _failure_mode),
    do: {:error, {:invalid_semantic_cache_adapter, other}}

  @spec learn_failure(term(), keyword()) :: :ok | {:error, term()}
  defp learn_failure(reason, opts) do
    case learn_failure_mode(opts) do
      :ignore -> :ok
      :error -> {:error, reason}
    end
  end

  @spec learn_failure_mode(keyword()) :: :ignore | :error
  defp learn_failure_mode(opts) do
    case Keyword.get(opts, :semantic_learn_failure, :ignore) do
      :error -> :error
      _other -> :ignore
    end
  end

  @spec snapshot_opts(term(), keyword()) :: keyword()
  defp snapshot_opts(snapshot_or_opts, opts) when is_list(snapshot_or_opts) do
    if Keyword.keyword?(snapshot_or_opts), do: Keyword.merge(snapshot_or_opts, opts), else: opts
  end

  defp snapshot_opts(_snapshot_or_opts, opts), do: opts

  @spec safe(function()) :: term()
  defp safe(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      {:error, {:semantic_cache_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:semantic_cache_exit, reason}}
    kind, reason -> {:error, {:semantic_cache_failure, kind, reason}}
  end
end
