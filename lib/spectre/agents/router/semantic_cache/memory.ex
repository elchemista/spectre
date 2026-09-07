defmodule Spectre.Router.SemanticCache.Memory do
  @moduledoc """
  Explicitly supervised, bounded semantic cache using compressed ETS and Vettore.

      {Spectre.Router.SemanticCache.Memory,
       name: MyApp.SupportCache, namespace: "tenant-a/support",
       definition_ref: definition.ref, profile_ref: "embedding:model-v1",
       dimensions: 384, labels: ["orders/lookup"], max_entries: 1000}

  Capacity includes reviewed and quarantined examples. A full cache returns
  `:semantic_cache_full`; it never silently evicts an example being reviewed.
  Each record is a separate ETS object, outside the GenServer heap. Pagination
  uses ordered keys; exact lookup uses a separate text index. The vector index
  is rebuilt lazily only when approved content changes, using saved vectors.

  This is a disposable read/learning model, not an append-only ledger. Persist
  `Spectre.Router.SemanticCache.snapshot/1` with host storage when required, or
  implement that module's backend callback for a different persistence system.
  Cache files, chat and embeddings have their own retention obligations; erasing
  ledger payloads does not automatically erase these host-owned copies.
  """

  use GenServer
  @behaviour Spectre.Router.SemanticCache

  alias Spectre.Router.SemanticCache.{Configuration, Example, Index}

  @doc "Validates configuration before linking; start this child in the host supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, config} <- Configuration.new(opts) do
      server_opts = if is_nil(config.name), do: [], else: [name: config.name]
      GenServer.start_link(__MODULE__, config, server_opts)
    end
  end

  @impl Spectre.Router.SemanticCache
  def execute(operation, opts),
    do:
      GenServer.call(Keyword.fetch!(opts, :server), operation, Keyword.get(opts, :timeout, 5000))

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       config: config,
       revision: 0,
       index: nil,
       examples: :ets.new(:semantic_examples, [:ordered_set, :private, :compressed]),
       exact: :ets.new(:semantic_exact, [:set, :private, :compressed])
     }}
  end

  @impl GenServer
  def handle_call(operation, _from, state) do
    {reply, state} = perform(operation, state)
    {:reply, reply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: Index.close(state.index)

  defp perform(:info, state) do
    {{:ok,
      %{
        binding: state.config.binding,
        count: count(state),
        revision: state.revision,
        max_entries: state.config.max_entries
      }}, state}
  end

  defp perform({:get, id}, state), do: {fetch(state, id), state}

  defp perform({:examples, opts}, state) do
    result =
      with {:ok, page} <- Configuration.page(opts) do
        key =
          if is_nil(page.after),
            do: :ets.first(state.examples),
            else: :ets.next(state.examples, page.after)

        examples = page(state.examples, key, page, [])
        {:ok, %{examples: examples, next: next_cursor(examples, page.limit)}}
      end

    {result, state}
  end

  defp perform({:put, attrs}, state) do
    with true <- count(state) < state.config.max_entries,
         {:ok, example} <- Example.new(attrs, state.config, state.revision + 1),
         false <- :ets.member(state.examples, example.id) do
      {{:ok, example}, insert(state, example)}
    else
      true -> {{:error, :cache_example_exists}, state}
      false -> {{:error, :semantic_cache_full}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp perform({:update, id, revision, attrs}, state) do
    with {:ok, example} <- editable(state, id, revision),
         {:ok, updated} <- Example.update(example, attrs, state.config, state.revision + 1) do
      state = remove(state, example)
      {{:ok, updated}, insert(state, updated)}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp perform({:verify, id, revision}, state) do
    case editable(state, id, revision) do
      {:ok, example} ->
        approved = %{example | verified: true, revision: state.revision + 1}
        {{:ok, approved}, insert(state, approved)}

      {:error, _} = error ->
        {error, state}
    end
  end

  defp perform({:delete, id, revision}, state) do
    with {:ok, example} <- fetch(state, id), :ok <- revision(example, revision) do
      {{:ok, example.id}, %{remove(state, example) | revision: state.revision + 1}}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp perform({:exact, text, opts}, state) do
    result =
      with {:ok, query} <- Configuration.query(opts, state.config),
           {:ok, text} <- Example.text(text, state.config.max_text_bytes) do
        ids = exact_ids(state, Example.normalize(text))

        matches =
          for id <- ids,
              {:ok, example} = fetch(state, id),
              MapSet.member?(query.labels, example.label),
              do: %{id: id, label: example.label, score: 1.0, method: :exact}

        {:ok, Index.rank(matches, query.limit)}
      end

    {result, state}
  end

  defp perform({:search, embedding, opts}, state) do
    with {:ok, query} <- Configuration.query(opts, state.config),
         {:ok, vector} when not is_nil(vector) <-
           Example.embedding(embedding, state.config.dimensions),
         {:ok, index} <- ensure_index(state) do
      {Index.search(index, vector, query), %{state | index: index}}
    else
      {:ok, nil} -> {{:error, :invalid_cache_embedding}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp perform(:snapshot, state) do
    snapshot = %{
      "version" => 1,
      "binding" => stringify(state.config.binding),
      "revision" => state.revision,
      "examples" => Enum.map(:ets.tab2list(state.examples), fn {_id, e} -> Example.dump(e) end)
    }

    {{:ok, snapshot}, state}
  end

  defp perform({:restore, snapshot}, state) do
    with true <- count(state) == 0,
         {:ok, examples, revision} <- restore(snapshot, state.config) do
      state = Enum.reduce(examples, state, &insert(&2, &1))
      {{:ok, length(examples)}, %{state | revision: max(state.revision, revision)}}
    else
      false -> {{:error, :cache_not_empty}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp perform({:import, attrs, source}, state) do
    with true <- source in [:offline_dataset, :static_route_example],
         true <- is_list(attrs) and length(attrs) + count(state) <= state.config.max_entries,
         {:ok, examples} <-
           prepare_examples(attrs, fn {attrs, index} ->
             Example.new(attrs, state.config, state.revision + index, Atom.to_string(source))
           end),
         false <- Enum.any?(examples, &:ets.member(state.examples, &1.id)) do
      {{:ok, length(examples)}, Enum.reduce(examples, state, &insert(&2, &1))}
    else
      error when is_boolean(error) -> {{:error, :invalid_cache_import}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp perform(:clear, state) do
    :ets.delete_all_objects(state.examples)
    :ets.delete_all_objects(state.exact)
    {{:ok, :cleared}, %{invalidate(state) | revision: state.revision + 1}}
  end

  defp perform(_operation, state), do: {{:error, :invalid_cache_operation}, state}

  defp insert(state, example) do
    :ets.insert(state.examples, {example.id, example})

    state =
      if example.verified do
        key = Example.normalize(example.text)
        :ets.insert(state.exact, {key, MapSet.put(exact_ids(state, key), example.id)})
        invalidate(state)
      else
        state
      end

    %{state | revision: max(state.revision, example.revision)}
  end

  defp remove(state, example) do
    :ets.delete(state.examples, example.id)

    if example.verified do
      key = Example.normalize(example.text)
      ids = MapSet.delete(exact_ids(state, key), example.id)

      if MapSet.size(ids) == 0,
        do: :ets.delete(state.exact, key),
        else: :ets.insert(state.exact, {key, ids})

      invalidate(state)
    else
      state
    end
  end

  defp exact_ids(state, key) do
    case :ets.lookup(state.exact, key) do
      [{^key, ids}] -> ids
      [] -> MapSet.new()
    end
  end

  defp editable(state, id, revision) do
    with {:ok, example} <- fetch(state, id),
         :ok <- revision(example, revision),
         true <- example.source == "online_learned" do
      {:ok, example}
    else
      false -> {:error, :cache_example_read_only}
      {:error, _} = error -> error
    end
  end

  defp revision(example, revision) do
    if example.revision === revision, do: :ok, else: {:error, :cache_revision_conflict}
  end

  defp fetch(state, id) do
    case :ets.lookup(state.examples, id) do
      [{^id, example}] -> {:ok, example}
      [] -> {:error, :cache_example_not_found}
    end
  end

  defp count(state), do: :ets.info(state.examples, :size)

  defp ensure_index(%{index: nil} = state),
    do: Index.build(state.config, :ets.tab2list(state.examples))

  defp ensure_index(state), do: {:ok, state.index}

  defp invalidate(state) do
    Index.close(state.index)
    %{state | index: nil}
  end

  defp page(_table, :"$end_of_table", _query, acc), do: Enum.reverse(acc)
  defp page(_table, _key, %{limit: 0}, acc), do: Enum.reverse(acc)

  defp page(table, key, query, acc) do
    [{^key, example}] = :ets.lookup(table, key)
    next = :ets.next(table, key)

    if (is_nil(query.source) or example.source == query.source) and
         (is_nil(query.verified) or example.verified == query.verified) do
      page(table, next, %{query | limit: query.limit - 1}, [example | acc])
    else
      page(table, next, query, acc)
    end
  end

  defp next_cursor(examples, limit) when length(examples) == limit, do: List.last(examples).id
  defp next_cursor(_examples, _limit), do: nil

  defp restore(snapshot, config) when is_map(snapshot) do
    with true <- Enum.sort(Map.keys(snapshot)) == ["binding", "examples", "revision", "version"],
         true <- snapshot["version"] === 1 and snapshot["binding"] === stringify(config.binding),
         revision = snapshot["revision"],
         true <- is_integer(revision) and revision >= 0,
         attrs = snapshot["examples"],
         true <- is_list(attrs) and length(attrs) <= config.max_entries,
         {:ok, examples} <-
           prepare_examples(attrs, fn {attrs, _index} -> Example.restore(attrs, config) end),
         true <- Enum.all?(examples, &(&1.revision <= revision)) do
      {:ok, examples, revision}
    else
      _invalid -> {:error, :invalid_cache_snapshot}
    end
  end

  defp restore(_snapshot, _config), do: {:error, :invalid_cache_snapshot}

  defp prepare_examples(attrs, builder) do
    attrs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn attrs, {:ok, examples} ->
      with {:ok, example} <- builder.(attrs), false <- Map.has_key?(examples, example.id) do
        {:cont, {:ok, Map.put(examples, example.id, example)}}
      else
        true -> {:halt, {:error, :duplicate_cache_example}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, examples} -> {:ok, Map.values(examples)}
      error -> error
    end
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
