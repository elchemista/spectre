defmodule Spectre.IntentDataset do
  @moduledoc """
  Labeled intent examples, their review workflow and lookup projections.

  Examples may be text-only. Vector search uses only valid stored embeddings;
  an exact hit never needs an encoder. Online examples remain unverified by
  default. This facade uses the existing supervised dataset owner, training
  artifacts and snapshot format, rather than creating another store.

  New configuration groups are translated to the legacy adapter contract once.
  Conflicting aliases raise `ArgumentError` instead of silently changing policy.
  """

  alias Spectre.Router.SemanticCache

  @lookup_misses [:miss, :not_found, :empty_learned_semantic_cache]

  @groups %{
    lookup: %{
      semantic: :semantic_search?,
      include_unverified: :semantic_cache_include_unverified?
    },
    search: %{
      method: :semantic_cache_search_method,
      candidates: :semantic_cache_search_candidates,
      limit: :semantic_cache_top_k,
      min_score: :semantic_cache_threshold
    },
    collection: %{
      index: :semantic_cache_index,
      compressed: :semantic_cache_compressed?
    },
    collect: %{
      enabled: :semantic_learn?,
      on_error: :semantic_learn_failure,
      min_chars: :semantic_learn_min_chars,
      max_chars: :semantic_learn_max_chars,
      include_protected: :semantic_learn_protected?,
      initial_confidence: :semantic_learn_confidence
    }
  }
  @aliases %{
    agent: :spectre_agent,
    intent_dataset: :semantic_cache,
    sources: :semantic_cache_source,
    collection_options: :semantic_cache_index_options,
    include_training_examples: :mirror_training_dataset?,
    include_static_examples: :semantic_cache_static?,
    max_online_examples: :semantic_cache_online_capacity,
    max_cached_indexes: :semantic_cache_capacity,
    max_index_revisions: :index_capacity
  }

  @doc "Translates intent dataset options without changing legacy defaults."
  @spec normalize_options(keyword()) :: keyword()
  def normalize_options(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "dataset options must be keywords")

    opts = Enum.reduce(@aliases, opts, fn {new, old}, acc -> rename(acc, new, old) end)

    Enum.reduce(@groups, opts, fn {group, fields}, acc ->
      case Keyword.pop(acc, group) do
        {nil, acc} -> acc
        {false, acc} when group == :lookup -> merge_option(acc, :semantic_cache?, false)
        {values, acc} when is_list(values) -> normalize_group(acc, group, values, fields)
        {invalid, _acc} -> raise ArgumentError, "invalid #{group} options: #{inspect(invalid)}"
      end
    end)
  end

  defp normalize_group(opts, group, values, fields) do
    unless Keyword.keyword?(values), do: raise(ArgumentError, "#{group} must be keywords")

    Enum.reduce(values, opts, fn
      {:exact, value}, acc when group == :lookup and is_boolean(value) ->
        merge_option(acc, :intent_exact?, value)

      {:metric, :cosine}, acc when group == :collection ->
        acc

      {key, value}, acc ->
        case Map.fetch(fields, key) do
          {:ok, old} -> merge_option(acc, old, value)
          :error -> raise ArgumentError, "unknown #{group} option: #{inspect(key)}"
        end
    end)
  end

  defp rename(opts, new, old) do
    case Keyword.pop(opts, new) do
      {nil, rest} -> rest
      {value, rest} -> merge_option(rest, old, value)
    end
  end

  defp merge_option(opts, key, value) do
    case Keyword.fetch(opts, key) do
      {:ok, existing} when existing != value ->
        raise ArgumentError, "conflicting intent dataset option #{inspect(key)}"

      _ ->
        Keyword.put(opts, key, value)
    end
  end

  @doc "Looks up intent evidence; no response or authorization is cached."
  def lookup(text, opts \\ []) do
    opts = runtime_options(opts)

    if Keyword.get(opts, :semantic_cache?, true) do
      do_lookup(text, opts)
    else
      {:error, :dataset_lookup_disabled}
    end
  end

  defp do_lookup(text, opts) do
    semantic? = Keyword.get(opts, :semantic_search?, false)

    if Keyword.get(opts, :intent_exact?, true) do
      case SemanticCache.lookup(text, Keyword.put(opts, :semantic_search?, false)) do
        {:ok, result} ->
          {:ok, rename_strategy(result)}

        {:error, reason} when semantic? and reason in @lookup_misses ->
          semantic_lookup(text, opts)

        error ->
          error
      end
    else
      if semantic?, do: semantic_lookup(text, opts), else: {:error, :dataset_lookup_disabled}
    end
  end

  defp semantic_lookup(text, opts) do
    case SemanticCache.lookup(text, Keyword.put(opts, :semantic_search?, true)) do
      {:ok, result} -> {:ok, rename_strategy(result)}
      error -> error
    end
  end

  defp rename_strategy(result) do
    Map.update(result, :strategy, :intent_exact, fn
      :semantic_cache_exact -> :intent_exact
      :semantic_cache_search -> :intent_similarity
      strategy -> strategy
    end)
  end

  @doc "Stores an eligible labeled example; this does not train a classifier."
  def put(text, result, opts \\ []), do: SemanticCache.put(text, result, runtime_options(opts))

  for {name, arity} <- [
        examples: 2,
        get_example: 3,
        relabel: 4,
        update_example: 4,
        delete: 3,
        verify: 3,
        snapshot: 2,
        clear: 2
      ] do
    args = Macro.generate_arguments(arity - 1, __MODULE__)
    [agent | _rest] = args

    @doc "Delegates the #{name} operation to the configured dataset service."
    def unquote(name)(unquote_splicing(args), opts \\ []) do
      apply(SemanticCache, unquote(name), [
        unquote_splicing(args),
        runtime_options(Keyword.put(opts, :agent, unquote(agent)))
      ])
    end
  end

  @doc "Restores portable labeled examples and compatible stored vectors."
  def load_snapshot(agent, snapshot, opts \\ []),
    do:
      SemanticCache.load_snapshot(
        agent,
        snapshot,
        runtime_options(Keyword.put(opts, :agent, agent))
      )

  defp runtime_options(opts) do
    opts = normalize_options(opts)

    case Keyword.get(opts, :spectre_agent) do
      agent when is_atom(agent) and not is_nil(agent) ->
        agent.__spectre_config__()
        |> Keyword.merge(agent.__spectre_router__())
        |> Keyword.merge(opts)
        |> Keyword.put_new(:spectre_rules, Spectre.Definition.rules(agent))

      _ ->
        opts
    end
  end
end
