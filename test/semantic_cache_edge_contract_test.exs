defmodule SpectreSemanticCacheEdgeContractTest.Embedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  @impl true
  def load(_model, _opts), do: {:ok, 2}

  @impl true
  def embed("provider error", opts) do
    notify(opts, "provider error")
    {:error, :embedding_provider_down}
  end

  def embed(text, opts) do
    notify(opts, text)
    {:ok, [1.0, 0.0]}
  end

  defp notify(opts, text) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:edge_embedding_call, text})
    end
  end
end

defmodule SpectreSemanticCacheEdgeContractTest.Agent do
  @moduledoc false
  use Spectre.Agent

  embedding(SpectreSemanticCacheEdgeContractTest.Embedding)
  router(via: [:semantic_cache])

  flow :coverage do
    on :CACHE, embedding: ["static cache"], cache: true do
      reply(:cache)
    end

    on :OTHER, cache: true do
      reply(:other)
    end

    on :NO_CACHE, cache: false do
      reply(:no_cache)
    end
  end
end

defmodule SpectreSemanticCacheEdgeContractTest.FailingIndex do
  @moduledoc false

  def new(_metric, opts), do: {:ok, Keyword.fetch!(opts, :mode)}
  def put(_collection, _embedding), do: :ok

  def put_many(%Vettore.Collection{index_state: :error}, _embeddings),
    do: {:error, :index_write_failed}

  def put_many(%Vettore.Collection{index_state: :raise}, _embeddings),
    do: raise("index write exploded")

  def put_many(%Vettore.Collection{index_state: :throw}, _embeddings),
    do: throw(:index_write_thrown)

  def delete(_collection, _id), do: :ok
  def search(_collection, _query, _opts), do: {:error, :index_search_unavailable}
end

defmodule SpectreSemanticCacheEdgeContractTest.ScriptedIndex do
  @moduledoc false

  def search(%Vettore.Collection{index_state: :empty}, _query, _opts), do: {:ok, []}
  def search(%Vettore.Collection{index_state: :error}, _query, _opts), do: {:error, :index_down}

  def search(%Vettore.Collection{index_state: :value}, _query, _opts) do
    {:ok,
     [
       %Vettore.Result{
         id: "legacy-value",
         value: "legacy value",
         score: 0.99,
         metric: :cosine,
         metadata: %{}
       }
     ]}
  end

  def search(%Vettore.Collection{index_state: :non_binary_value}, _query, _opts) do
    {:ok,
     [
       %Vettore.Result{
         id: "legacy-atom",
         value: :legacy_label,
         score: 0.98,
         metric: :cosine,
         metadata: %{}
       }
     ]}
  end
end

defmodule SpectreSemanticCacheEdgeContractTest.RaisingCreateStore do
  @moduledoc false

  def new(_opts), do: raise("store creation exploded")
  def put(_state, _embedding), do: :ok
  def put_many(_state, _embeddings), do: :ok
  def get(_state, _id), do: {:error, :not_found}
  def delete(_state, _id), do: :ok
  def all(_state), do: {:ok, []}
  def snapshot(_state, _path), do: :ok
  def load_snapshot(_path), do: {:error, :not_found}
end

defmodule SpectreSemanticCacheEdgeContractTest.ThrowingCreateStore do
  @moduledoc false

  def new(_opts), do: throw(:store_creation_thrown)
  def put(_state, _embedding), do: :ok
  def put_many(_state, _embeddings), do: :ok
  def get(_state, _id), do: {:error, :not_found}
  def delete(_state, _id), do: :ok
  def all(_state), do: {:ok, []}
  def snapshot(_state, _path), do: :ok
  def load_snapshot(_path), do: {:error, :not_found}
end

defmodule SpectreSemanticCacheEdgeContractTest.RaisingCloseStore do
  @moduledoc false

  def close(_state), do: raise("store close exploded")
end

defmodule SpectreSemanticCacheEdgeContractTest.ThrowingCloseStore do
  @moduledoc false

  def close(_state), do: throw(:store_close_thrown)
end

defmodule SpectreSemanticCacheEdgeContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner

  @agent SpectreSemanticCacheEdgeContractTest.Agent
  @embedding SpectreSemanticCacheEdgeContractTest.Embedding
  @online_table Module.concat(Learned, Online)
  @revision_table Module.concat(Learned, Revisions)

  setup do
    opts = cache_opts()
    assert :ok = SemanticCache.clear(@agent, opts)
    on_exit(fn -> SemanticCache.clear(@agent, opts) end)
    {:ok, opts: opts}
  end

  test "stored embeddings are validated, reused, and accepted through the Route API", %{
    opts: opts
  } do
    assert Learned.online_revision(SpectreSemanticCacheEdgeContractTest.FreshAgent) == 0

    assert {:ok, first} =
             Learned.put(
               "same normalized text",
               %{
                 id: "stable-id",
                 label: :CACHE,
                 strategy: :llm_classifier,
                 verified?: true,
                 embedding: [1, 0],
                 metadata: %{
                   reviewed_at: ~U[2026-07-25 08:00:00Z],
                   origin: :test,
                   nested: %{attempt: 1},
                   values: [:a, 2]
                 }
               },
               opts
             )

    assert first.embedding == [1.0, 0.0]
    refute_receive {:edge_embedding_call, _text}

    assert {:ok, reused} =
             Learned.put(
               " SAME NORMALIZED TEXT ",
               %{
                 label: :CACHE,
                 strategy: :llm_classifier,
                 verified?: true,
                 metadata: %{
                   reviewed_at: ~U[2026-07-25 08:00:00Z],
                   origin: :test,
                   nested: %{attempt: 1},
                   values: [:a, 2]
                 }
               },
               opts
             )

    assert reused.id == first.id
    assert reused.embedding == first.embedding
    refute_receive {:edge_embedding_call, _text}

    assert {:ok, route_row} =
             Learned.put(
               "route input",
               %Spectre.Route{
                 label: :OTHER,
                 strategy: :llm_classifier,
                 confidence: 0.91,
                 accepted?: true
               },
               opts
             )

    assert route_row.label == :OTHER
    assert route_row.embedding == [1.0, 0.0]
    assert_receive {:edge_embedding_call, "route input"}

    assert {:ok, snapshots} = Learned.snapshot(@agent, opts)
    snapshot = Enum.find(snapshots, &(&1.id == first.id))
    encoded = Jason.encode!(snapshot)
    assert encoded =~ "reviewed_at"
    assert encoded =~ "origin"

    assert {:error, :invalid_semantic_cache_embedding} =
             Learned.put("bad member", %{label: :CACHE, embedding: [1.0, :bad]}, opts)

    assert {:error, :invalid_semantic_cache_embedding} =
             Learned.put("empty vector", %{label: :CACHE, embedding: []}, opts)

    assert {:error, :invalid_semantic_cache_embedding} =
             Learned.put("wrong vector", %{label: :CACHE, embedding: "not-a-vector"}, opts)

    assert {:error, {:unknown_label, 123}} =
             Learned.put("bad label", %{label: 123, embedding: [1.0, 0.0]}, opts)

    assert {:error, {:uncacheable_label, :NO_CACHE}} =
             Learned.put("private", %{label: :NO_CACHE, embedding: [1.0, 0.0]}, opts)

    assert {:error, :blank_text} =
             Learned.put("  ", %{label: :CACHE, embedding: [1.0, 0.0]}, opts)

    assert {:error, {:invalid_semantic_cache_result, :invalid}} =
             Learned.put("bad result", :invalid, opts)

    assert {:error, {:missing_spectre_agent, nil}} =
             Learned.put(
               "missing agent",
               %{label: :CACHE, embedding: [1.0, 0.0]},
               Keyword.delete(opts, :spectre_agent)
             )

    assert {:error, :embedding_provider_down} =
             Learned.put(
               "provider error",
               %{label: :CACHE, strategy: :llm_classifier},
               opts
             )

    assert_receive {:edge_embedding_call, "provider error"}
  end

  @tag :tmp_dir
  test "snapshot loading reports corruption and preserves a matching stored vector", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    first_time = ~U[2026-07-24 10:00:00Z]

    assert {:ok, %{loaded: 1, skipped: 0}} =
             Learned.load_snapshot(
               @agent,
               [
                 %{
                   id: "preserved",
                   text: "preserved text",
                   label: :CACHE,
                   verified: true,
                   embedding: [1.0, 0.0],
                   inserted_at: first_time,
                   updated_at: first_time
                 }
               ],
               opts
             )

    assert {:ok, %{loaded: 1, skipped: 0}} =
             Learned.load_snapshot(
               @agent,
               [
                 %{
                   id: "preserved",
                   text: " PRESERVED TEXT ",
                   label: :CACHE,
                   verified: true,
                   embedding: nil,
                   source_strategy: "brand_new_atom_that_must_not_be_created",
                   confidence: :invalid,
                   metadata: :invalid,
                   inserted_at: "not-a-date",
                   updated_at: "not-a-date"
                 }
               ],
               opts
             )

    assert {:ok, preserved} = Learned.get_example(@agent, "preserved", opts)
    assert preserved.embedding == [1.0, 0.0]
    assert preserved.source_strategy == nil
    assert preserved.confidence == 0.86
    assert preserved.metadata == %{}
    assert DateTime.compare(preserved.updated_at, first_time) == :gt

    invalid_rows = [
      %{text: "", label: :CACHE},
      %{text: "unknown", label: :UNKNOWN},
      %{text: "private", label: :NO_CACHE},
      %{text: "bad embedding", label: :CACHE, embedding: [1.0, :bad]},
      :not_a_map
    ]

    assert {:ok, %{loaded: 0, skipped: 5, errors: errors}} =
             Learned.load_snapshot(@agent, [rows: invalid_rows], opts)

    assert :blank_text in errors
    assert {:unknown_label, :UNKNOWN} in errors
    assert {:uncacheable_label, :NO_CACHE} in errors
    assert :invalid_semantic_cache_embedding in errors
    assert {:invalid_snapshot_row, :not_a_map} in errors

    assert {:error, {:invalid_snapshot, %{loaded: 0, skipped: 5}}} =
             Learned.load_snapshot(@agent, invalid_rows, Keyword.put(opts, :strict?, true))

    invalid_jsonl = Path.join(tmp_dir, "broken.jsonl")
    File.write!(invalid_jsonl, "{definitely not json}\n")

    assert {:ok, %{loaded: 0, skipped: 1, errors: [{:invalid_json, _reason}]}} =
             Learned.load_snapshot(@agent, invalid_jsonl, opts)

    assert {:error, :missing_snapshot} = Learned.load_snapshot(@agent, [], opts)
    assert {:error, {:invalid_snapshot, :opaque}} = Learned.load_snapshot(@agent, :opaque, opts)

    assert {:error, :enoent} =
             Learned.load_snapshot(@agent, Path.join(tmp_dir, "missing.jsonl"), opts)
  end

  @tag :tmp_dir
  test "snapshot export rejects invalid destinations and source selections", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    assert {:ok, _row} =
             Learned.put(
               "export me",
               %{label: :CACHE, verified?: true, embedding: [1.0, 0.0]},
               opts
             )

    assert {:error, {:invalid_semantic_cache_source, :invalid}} =
             Learned.snapshot(@agent, Keyword.put(opts, :source, :invalid))

    assert {:error, {:invalid_snapshot_path, 42}} =
             Learned.snapshot(@agent, Keyword.put(opts, :path, 42))

    blocker = Path.join(tmp_dir, "not-a-directory")
    File.write!(blocker, "file")

    assert {:error, _reason} =
             Learned.snapshot(@agent, Keyword.put(opts, :path, Path.join(blocker, "cache.jsonl")))
  end

  @tag :tmp_dir
  test "offline artifacts remain reviewable when a vector is malformed", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    json = Path.join(tmp_dir, "dataset.json")

    File.write!(
      json,
      Jason.encode!([
        %{
          text: "offline without a valid vector",
          intent: "CACHE",
          embedding: "invalid",
          note: String.duplicate("x", 2_001)
        }
      ])
    )

    review_opts =
      opts
      |> Keyword.put(:semantic_cache_static?, true)
      |> Keyword.put(:mirror_training_dataset?, true)
      |> Keyword.put(:semantic_cache_source, ["", json])

    assert {:ok, [row]} =
             Learned.examples(@agent, Keyword.put(review_opts, :source, :offline_dataset))

    assert row.source == :offline_dataset
    assert row.embedding == nil
    refute Map.has_key?(row.metadata.source, "embedding")
    refute Map.has_key?(row.metadata.source, "note")

    unreadable = Path.join(tmp_dir, "unreadable.jsonl")
    File.mkdir_p!(unreadable)

    assert {:error, :eisdir} =
             Learned.rows(
               review_opts
               |> Keyword.delete(:source)
               |> Keyword.put(:semantic_cache_source, unreadable)
             )
  end

  test "stale online rows fail safely when route definitions no longer match", %{opts: opts} do
    assert {:ok, row} =
             Learned.put(
               "stale route",
               %{label: :CACHE, verified?: true, embedding: [1.0, 0.0]},
               opts
             )

    :ets.insert(@online_table, {{@agent, row.id}, %{row | editable?: false}})

    assert {:error, :read_only_example} = Learned.verify(@agent, row.id, opts)
    assert {:error, :read_only_example} = Learned.delete(@agent, row.id, opts)

    :ets.insert(@online_table, {{@agent, row.id}, %{row | label: :REMOVED, editable?: true}})

    assert {:error, {:unknown_label, :REMOVED}} = Learned.delete(@agent, row.id, opts)
  end

  test "index write failures are returned without calling the query embedding provider", %{
    opts: opts
  } do
    for {mode, expected} <- [
          {:error, :index_write_failed},
          {:raise, :semantic_cache_index_exception},
          {:throw, :semantic_cache_index_failure}
        ] do
      assert :ok = SemanticCache.clear(@agent, opts)

      failing_opts =
        opts
        |> Keyword.put(:semantic_cache_index, SpectreSemanticCacheEdgeContractTest.FailingIndex)
        |> Keyword.put(:semantic_cache_index_options, mode: mode)

      assert {:ok, %{loaded: 1, skipped: 0}} =
               Learned.load_snapshot(
                 @agent,
                 [%{text: "indexed row", label: :CACHE, verified: true, embedding: [1.0, 0.0]}],
                 failing_opts
               )

      assert {:error, reason} =
               Learned.lookup(
                 "new query",
                 Keyword.put(failing_opts, :semantic_search?, true)
               )

      case expected do
        atom when atom in [:semantic_cache_index_exception, :semantic_cache_index_failure] ->
          assert elem(reason, 0) == atom

        atom ->
          assert reason == atom
      end

      refute_receive {:edge_embedding_call, "new query"}
    end

    invalid_index_opts =
      Keyword.put(opts, :semantic_cache_index, SpectreSemanticCacheEdgeContractTest.MissingIndex)

    assert {:ok, %{loaded: 1}} =
             Learned.load_snapshot(
               @agent,
               [
                 %{
                   text: "invalid index row",
                   label: :CACHE,
                   verified: true,
                   embedding: [1.0, 0.0]
                 }
               ],
               invalid_index_opts
             )

    assert {:error, :invalid_index} =
             Learned.lookup(
               "new query",
               Keyword.put(invalid_index_opts, :semantic_search?, true)
             )
  end

  test "search handles empty, failed, and legacy index results without rebuilding rows", %{
    opts: opts
  } do
    assert {:ok, %{loaded: 1, skipped: 0}} =
             Learned.load_snapshot(
               @agent,
               [
                 %{
                   id: "row",
                   text: "stored",
                   label: :CACHE,
                   verified: true,
                   embedding: [1.0, 0.0]
                 }
               ],
               opts
             )

    assert {:ok, rows} = Learned.rows(opts)
    key = index_key(rows, opts)

    for {state, expected} <- [
          {:empty, {:error, :miss}},
          {:error, {:error, :index_down}}
        ] do
      install_scripted_index(key, state)

      assert ^expected =
               Learned.lookup("query #{state}", Keyword.put(opts, :semantic_search?, true))

      assert_receive {:edge_embedding_call, "query " <> _state}
    end

    install_scripted_index(key, :value)

    assert {:ok, legacy} =
             Learned.lookup("legacy query", Keyword.put(opts, :semantic_search?, true))

    assert legacy.label == "legacy value"
    assert legacy.matched == "legacy value"
    assert legacy.semantic_examples == []
    assert_receive {:edge_embedding_call, "legacy query"}

    install_scripted_index(key, :non_binary_value)

    assert {:ok, legacy_atom} =
             Learned.lookup("legacy atom query", Keyword.put(opts, :semantic_search?, true))

    assert legacy_atom.label == :legacy_label
    assert legacy_atom.matched == nil
    assert_receive {:edge_embedding_call, "legacy atom query"}
  end

  test "owner validates adapters, evicts old agent indexes, and removes crashed collections" do
    assert {:error, {:unknown_semantic_cache_table, :unknown}} =
             Owner.ensure_table(:unknown, [])

    assert {:error, {:unknown_semantic_cache_table, Learned}} =
             Owner.ensure_table(Learned, :invalid)

    assert {:error, {:invalid_collection_options, :invalid}} =
             Owner.new_collection(:invalid)

    assert {:error, {:invalid_semantic_cache_index, :wrong}} =
             Owner.cache_index(:wrong, :key, %{}, 1)

    assert {:error, {:invalid_semantic_cache_index, Learned}} =
             Owner.cache_index(Learned, :key, :invalid, 1)

    assert {:error, {:invalid_semantic_cache_index, Learned}} =
             Owner.cache_index(Learned, :key, %{}, 0)

    assert {:error, {:invalid_agent, "agent"}} = Owner.clear_indexes("agent")
    assert {:error, :invalid_dimensions} = Owner.new_collection(dimensions: 0)

    assert {:error, {:semantic_cache_collection_exception, RuntimeError, _message}} =
             Owner.new_collection(
               dimensions: 2,
               store: SpectreSemanticCacheEdgeContractTest.RaisingCreateStore
             )

    assert {:error, {:semantic_cache_collection_failure, :throw, :store_creation_thrown}} =
             Owner.new_collection(
               dimensions: 2,
               store: SpectreSemanticCacheEdgeContractTest.ThrowingCreateStore
             )

    {:ok, first} = Owner.new_collection(dimensions: 2)
    first_owner = first.store_state.owner

    assert {:ok, %{collection: ^first}} =
             Owner.cache_index(
               Learned,
               {{:agent, @agent}, :first},
               %{collection: first, inserted_at: 1},
               1
             )

    {:ok, duplicate} = Owner.new_collection(dimensions: 2)
    duplicate_owner = duplicate.store_state.owner

    assert {:ok, %{collection: ^first}} =
             Owner.cache_index(
               Learned,
               {{:agent, @agent}, :first},
               %{collection: duplicate, inserted_at: 2},
               1
             )

    refute eventually_alive?(duplicate_owner)
    assert Process.alive?(first_owner)

    {:ok, second} = Owner.new_collection(dimensions: 2)
    second_owner = second.store_state.owner

    assert {:ok, %{collection: ^second}} =
             Owner.cache_index(
               Learned,
               {{:agent, @agent}, :second},
               %{collection: second, inserted_at: 2},
               1
             )

    refute eventually_alive?(first_owner)
    assert Process.alive?(second_owner)

    Process.exit(second_owner, :kill)

    assert eventually(fn ->
             :ets.lookup(Learned, {{:agent, @agent}, :second}) == []
           end)

    fake_owner = spawn(fn -> Process.sleep(:infinity) end)

    assert {:error, {:semantic_cache_collection_close_exception, RuntimeError, _message}} =
             Owner.drop_collection(%Vettore.Collection{
               store_mod: SpectreSemanticCacheEdgeContractTest.RaisingCloseStore,
               store_state: %{owner: fake_owner}
             })

    assert {:error, {:semantic_cache_collection_close_failure, :throw, :store_close_thrown}} =
             Owner.drop_collection(%Vettore.Collection{
               store_mod: SpectreSemanticCacheEdgeContractTest.ThrowingCloseStore,
               store_state: %{owner: fake_owner}
             })

    Process.exit(fake_owner, :kill)
  end

  test "owner absence is explicit and a standalone owner can rebuild the tables" do
    supervisor = Process.whereis(Spectre.ApplicationSupervisor)
    assert is_pid(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, Owner)

    try do
      assert Process.whereis(Owner) == nil

      assert {:error, :semantic_cache_owner_not_started} =
               Owner.ensure_table(Learned, [:named_table, :public, :set])

      assert_raise RuntimeError, ~r/semantic cache table unavailable/, fn ->
        Learned.online_revision(@agent)
      end

      Learned = :ets.new(Learned, [:named_table, :public, :set])

      assert_raise RuntimeError, ~r/semantic cache indexes unavailable/, fn ->
        Learned.clear(@agent, source: :offline_dataset)
      end

      true = :ets.delete(Learned)

      assert {:ok, temporary_owner} = Owner.start_link()
      assert Process.whereis(Owner) == temporary_owner
      assert :ets.info(Learned, :owner) == temporary_owner
      assert :ok = GenServer.stop(temporary_owner)
    after
      case Supervisor.restart_child(supervisor, Owner) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end

      assert eventually(fn -> is_pid(Process.whereis(Owner)) end)
      assert :ets.info(@revision_table, :owner) == Process.whereis(Owner)
    end
  end

  test "capacity accepts unlimited and invalid application configuration falls back safely", %{
    opts: opts
  } do
    previous = Application.get_env(:spectre, :semantic_cache)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:spectre, :semantic_cache)
      else
        Application.put_env(:spectre, :semantic_cache, previous)
      end
    end)

    assert {:ok, %{loaded: 1}} =
             Learned.load_snapshot(
               @agent,
               [%{text: "unlimited", label: :CACHE, verified: true, embedding: [1.0, 0.0]}],
               Keyword.put(opts, :semantic_cache_capacity, :unlimited)
             )

    assert :ok = SemanticCache.clear(@agent, opts)
    Application.put_env(:spectre, :semantic_cache, %{invalid: true})

    assert {:ok, %{loaded: 1}} =
             Learned.load_snapshot(
               @agent,
               [%{text: "fallback", label: :CACHE, verified: true, embedding: [1.0, 0.0]}],
               Keyword.delete(opts, :semantic_cache_capacity)
             )

    assert :ok = SemanticCache.clear(@agent, opts)

    assert {:ok, %{loaded: 1}} =
             Learned.load_snapshot(
               @agent,
               [
                 %{text: "invalid capacity", label: :CACHE, verified: true, embedding: [1.0, 0.0]}
               ],
               Keyword.put(opts, :semantic_cache_capacity, 0)
             )
  end

  defp cache_opts do
    Keyword.merge(@agent.__spectre_config__(),
      spectre_agent: @agent,
      spectre_rules: Enum.map(@agent.__spectre_rules__(), &Map.from_struct(Spectre.Rule.new(&1))),
      semantic_cache_static?: false,
      mirror_training_dataset?: false,
      semantic_cache_threshold: 0.8,
      classification_log?: false,
      embedding: @embedding,
      test_pid: self()
    )
  end

  defp index_key(rows, opts) do
    revision =
      rows
      |> Enum.map(&{&1.id, &1.label, &1.normalized_text, &1.embedding})
      |> Enum.sort()

    {{:agent, @agent},
     :erlang.phash2({
       revision,
       Keyword.get(opts, :semantic_cache_index, :flat),
       Keyword.get(opts, :semantic_cache_index_options, []),
       Keyword.get(opts, :semantic_cache_compressed?, true)
     })}
  end

  defp install_scripted_index(key, state) do
    collection = %Vettore.Collection{
      dimensions: 2,
      metric: :cosine,
      normalize: :l2,
      score: :raw,
      index_mod: SpectreSemanticCacheEdgeContractTest.ScriptedIndex,
      index_state: state
    }

    true = :ets.insert(Learned, {key, %{collection: collection, inserted_at: 1}})
  end

  defp eventually_alive?(pid, attempts \\ 100)

  defp eventually_alive?(pid, attempts) when attempts > 0 do
    if Process.alive?(pid) do
      Process.sleep(5)
      eventually_alive?(pid, attempts - 1)
    else
      false
    end
  end

  defp eventually_alive?(pid, 0), do: Process.alive?(pid)

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      value when value in [nil, false] ->
        Process.sleep(5)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(_fun, 0), do: false
end
