defmodule Spectre.Router.SemanticCache.Memory do
  @moduledoc """
  Shared bounded storage engine for the Exact and optional vector cache adapters.

      {Spectre.Router.SemanticCache.Memory,
       name: MyApp.SupportCache, namespace: "tenant-a/support",
       definition_ref: definition.ref, flow: "orders",
       labels: ["orders/lookup"], max_entries: 1000}

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
  alias Spectre.Agent.Collection

  @doc "Reuses this storage/review engine in a backend that selects its own search index."
  defmacro __using__(_opts) do
    callbacks =
      for {name, arity} <- Spectre.Router.SemanticCache.behaviour_info(:callbacks) do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          @impl Spectre.Router.SemanticCache
          defdelegate unquote(name)(unquote_splicing(args)),
            to: Spectre.Router.SemanticCache.Memory
        end
      end

    quote do
      @behaviour Spectre.Router.SemanticCache
      unquote_splicing(callbacks)

      @doc "Starts the explicitly configured, bounded cache under the host's supervision."
      def start_link(opts), do: Spectre.Router.SemanticCache.Memory.start_link(opts)

      @doc "Returns the host supervision specification; binding a cache never starts it."
      def child_spec(opts) do
        %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
      end

      defoverridable start_link: 1
    end
  end

  @doc "Validates configuration before linking; start this child in the host supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, config} <- Configuration.new(opts) do
      server_opts = if is_nil(config.name), do: [], else: [name: config.name]
      GenServer.start_link(__MODULE__, config, server_opts)
    end
  end

  @impl Spectre.Router.SemanticCache
  def info(opts), do: call(:info, opts)

  @impl Spectre.Router.SemanticCache
  def lookup(binding, query, opts), do: call({:bound, binding, {:lookup, query}}, opts)

  @impl Spectre.Router.SemanticCache
  def put(binding, attrs, opts), do: call({:bound, binding, {:put, attrs}}, opts)

  @impl Spectre.Router.SemanticCache
  def examples(binding, page, opts), do: call({:bound, binding, {:examples, page}}, opts)

  @impl Spectre.Router.SemanticCache
  def update(binding, id, changes, revision, opts),
    do: call({:bound, binding, {:update, id, revision, changes}}, opts)

  @impl Spectre.Router.SemanticCache
  def verify(binding, id, revision, opts),
    do: call({:bound, binding, {:verify, id, revision}}, opts)

  @impl Spectre.Router.SemanticCache
  def delete(binding, id, revision, opts),
    do: call({:bound, binding, {:delete, id, revision}}, opts)

  @impl Spectre.Router.SemanticCache
  def snapshot(binding, opts), do: call({:bound, binding, :snapshot}, opts)

  @impl Spectre.Router.SemanticCache
  def restore(binding, snapshot, opts), do: call({:bound, binding, {:restore, snapshot}}, opts)

  defp call(operation, opts) do
    # A host may share a port across flows by supplying an explicit address map
    # keyed by the complete binding. No partition is created on first access.
    binding =
      case operation do
        {:bound, binding, _operation} -> binding
        :info -> Keyword.get(opts, :binding)
      end

    case Keyword.fetch(opts, :server) do
      {:ok, servers} when is_map(servers) ->
        case Map.fetch(servers, binding) do
          {:ok, server} -> GenServer.call(server, operation, Keyword.get(opts, :timeout, 5000))
          :error -> {:error, :cache_partition_not_wired}
        end

      {:ok, server} ->
        GenServer.call(server, operation, Keyword.get(opts, :timeout, 5000))

      :error ->
        {:error, :cache_server_required}
    end
  end

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
  def handle_call({:bound, binding, operation}, _from, %{config: %{binding: binding}} = state) do
    {reply, state} = perform(operation, state)
    {:reply, reply, state}
  end

  def handle_call(:info, _from, state) do
    {reply, state} = perform(:info, state)
    {:reply, reply, state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :cache_binding_mismatch}, state}

  @impl GenServer
  def terminate(_reason, state), do: Index.close(state.index)

  defp perform(:info, state) do
    {{:ok,
      %{
        binding: state.config.binding,
        count: count(state),
        revision: state.revision,
        max_entries: state.config.max_entries,
        max_text_bytes: state.config.max_text_bytes,
        dimensions: state.config.dimensions
      }}, state}
  end

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
      {:ok, %{remove(state, example) | revision: state.revision + 1}}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp perform({:lookup, value}, state) do
    with {:ok, query} <- Configuration.query(value, state.config) do
      hits =
        for id <- exact_ids(state, Example.normalize(query.text)),
            {:ok, example} = fetch(state, id),
            MapSet.member?(query.labels, example.label),
            do: Example.nomination(example, 1.0, state.config.binding)

      if hits == [], do: search(query, state), else: {{:ok, Index.rank(hits, query.limit)}, state}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp perform(:snapshot, state) do
    snapshot = %{
      "version" => 2,
      "binding" => stringify(state.config.binding),
      "revision" => state.revision,
      "examples" => Enum.map(:ets.tab2list(state.examples), fn {_id, e} -> Example.dump(e) end)
    }

    snapshot = Map.put(snapshot, "ref", Spectre.Portable.content_ref!(:cache_snapshot, snapshot))
    {{:ok, snapshot}, state}
  end

  defp perform({:restore, snapshot}, state) do
    with true <- count(state) == 0 and state.revision == 0,
         {:ok, examples, revision} <- restore(snapshot, state.config) do
      state = Enum.reduce(examples, state, &insert(&2, &1))
      {:ok, %{state | revision: revision}}
    else
      false -> {{:error, :cache_not_empty}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp perform(_operation, state), do: {{:error, :invalid_cache_operation}, state}

  defp search(_query, %{config: %{search: nil}} = state), do: {:miss, state}
  defp search(%{vector: nil}, state), do: {{:error, :embedding_required}, state}

  defp search(query, state) do
    with {:ok, index} <- ensure_index(state) do
      # Retain ownership even when search fails, so native resources are closed.
      state = %{state | index: index}

      result =
        with {:ok, hits} <- Index.search(index, query.vector, query),
             do: nominations(hits, query, state)

      {result, state}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp nominations(hits, query, state) when is_list(hits) and length(hits) <= query.limit do
    Collection.map(hits, fn hit ->
      with %{example_ref: id, score: score} <- hit,
           true <- is_number(score) and score >= 0 and score <= 1,
           {:ok, %Example{verified: true} = example} <- fetch(state, id),
           true <- MapSet.member?(query.labels, example.label) do
        {:ok, Example.nomination(example, score, state.config.binding)}
      else
        _invalid -> {:error, :invalid_cache_index_result}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Index.rank(found, query.limit)}
      error -> error
    end
  end

  defp nominations(_hits, _query, _state), do: {:error, :invalid_cache_index_result}

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
         :ok <- revision(example, revision) do
      {:ok, example}
    else
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
    do: Index.build(state.config.search, :ets.tab2list(state.examples))

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

    if is_nil(query.verified) or example.verified == query.verified do
      page(table, next, %{query | limit: query.limit - 1}, [example | acc])
    else
      page(table, next, query, acc)
    end
  end

  defp next_cursor(examples, limit) when length(examples) == limit, do: List.last(examples).id
  defp next_cursor(_examples, _limit), do: nil

  defp restore(snapshot, config) when is_map(snapshot) do
    with true <-
           Enum.sort(Map.keys(snapshot)) == ["binding", "examples", "ref", "revision", "version"],
         {:ok, ref} <- Spectre.Portable.content_ref(:cache_snapshot, Map.delete(snapshot, "ref")),
         true <- snapshot["ref"] === ref,
         true <- snapshot["version"] === 2 and snapshot["binding"] === stringify(config.binding),
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
