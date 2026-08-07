defmodule SpectreSemanticCacheContractTest.Embedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  @impl true
  def load(_model, _opts), do: {:ok, 2}

  @impl true
  def embed(text, opts) do
    if String.starts_with?(text, "forbidden stored row ") do
      raise "stored semantic-cache rows must never be embedded at request time"
    end

    vector = vector(text)

    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:semantic_cache_embedding_call, text, vector})
    end

    {:ok, vector}
  end

  defp vector("right-ish"), do: [1.0, 0.0]
  defp vector("bulk query"), do: [1.0, 0.0]
  defp vector(_text), do: [0.0, 1.0]
end

defmodule SpectreSemanticCacheContractTest.ClassifierLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl true
  def complete(_prompt, _opts), do: {:ok, "NEW_MATCH"}
end

defmodule SpectreSemanticCacheContractTest.ReplyRenderer do
  @moduledoc false

  def render(prompt, _assigns, _opts), do: Atom.to_string(prompt)
end

defmodule SpectreSemanticCacheContractTest.Agent do
  @moduledoc false
  use Spectre.Agent, prompt_root: "tmp/semantic_cache_contract/prompts"

  embedding(SpectreSemanticCacheContractTest.Embedding, model: "contract")
  classifier(SpectreSemanticCacheContractTest.ClassifierLLM)
  router(via: [:semantic_cache, :llm_classifier])

  flow :conversation do
    on :RIGHT, learn: true do
      reply(:right, renderer: {SpectreSemanticCacheContractTest.ReplyRenderer, :render})
    end

    on :LEFT, learn: true do
      reply(:left, renderer: {SpectreSemanticCacheContractTest.ReplyRenderer, :render})
    end

    on :NEW_MATCH, learn: true do
      reply(:new_match, renderer: {SpectreSemanticCacheContractTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreSemanticCacheContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner

  @agent SpectreSemanticCacheContractTest.Agent
  @embedding SpectreSemanticCacheContractTest.Embedding

  setup do
    opts = opts()
    assert :ok = SemanticCache.clear(@agent, opts)
    on_exit(fn -> SemanticCache.clear(@agent, opts) end)
    {:ok, opts: opts}
  end

  test "loading saved vectors and routing an exact hit make zero embedding calls", %{opts: opts} do
    assert {:ok, %{loaded: 2, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), opts)

    refute_embedding_call()

    assert {:ok, route} = route("stored right", opts)
    assert route.label == :RIGHT
    assert route.strategy == :semantic_cache_exact
    refute_embedding_call()
  end

  test "semantic search embeds only the incoming query once", %{opts: opts} do
    assert {:ok, %{loaded: 2, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), opts)

    assert {:ok, route} = route("right-ish", opts)
    assert route.label == :RIGHT
    assert route.strategy == :semantic_cache_search

    assert_receive {:semantic_cache_embedding_call, "right-ish", vector}
    assert vector == [1.0, 0.0]
    refute_embedding_call()
  end

  test "per-call Encoder adapters persist a learned vector exactly once", %{opts: opts} do
    adapter_opts =
      opts
      |> Keyword.delete(:embedding)
      |> Keyword.put(:embedding_adapter, @embedding)
      |> Keyword.put(:test_pid, self())

    assert {:ok, row} =
             SemanticCache.put(
               "adapter configured row",
               %{label: :RIGHT, strategy: :llm_classifier, verified?: true},
               adapter_opts
             )

    assert_receive {:semantic_cache_embedding_call, "adapter configured row", vector}
    assert row.embedding == vector
    refute_embedding_call()

    assert {:ok, [snapshot]} = SemanticCache.snapshot(@agent, adapter_opts)
    assert snapshot.embedding == vector
    refute_embedding_call()
  end

  test "request-time calls stay constant with one thousand stored vectors", %{opts: opts} do
    rows =
      Enum.map(1..1_000, fn index ->
        %{
          id: "bulk-#{index}",
          text: "forbidden stored row #{index}",
          label: :RIGHT,
          verified?: true,
          embedding: [1.0, 0.0]
        }
      end)

    assert {:ok, %{loaded: 1_000, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, rows, opts)

    refute_embedding_call()

    assert {:ok, exact} = route("forbidden stored row 500", opts)
    assert exact.label == :RIGHT
    assert exact.strategy == :semantic_cache_exact
    refute_embedding_call()

    assert {:ok, semantic} = route("bulk query", opts)
    assert semantic.label == :RIGHT
    assert semantic.strategy == :semantic_cache_search

    assert_receive {:semantic_cache_embedding_call, "bulk query", vector}
    assert vector == [1.0, 0.0]
    refute_embedding_call()
  end

  @tag :tmp_dir
  test "an owner crash reloads the saved artifact without rebuilding stored vectors", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    artifact_dir = Path.join(tmp_dir, "artifact")
    artifact_path = Path.join(artifact_dir, "semantic_cache.jsonl")
    File.mkdir_p!(artifact_dir)

    assert {:ok, %{loaded: 2, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), opts)

    assert {:ok, ^artifact_path} =
             SemanticCache.snapshot(@agent, Keyword.put(opts, :path, artifact_path))

    old_owner = Process.whereis(Owner)
    owner_monitor = Process.monitor(old_owner)
    Process.exit(old_owner, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^old_owner, :killed}
    new_owner = eventually(fn -> ready_replacement_owner(Owner, Learned, old_owner) end)
    assert :ets.info(Learned, :owner) == new_owner
    assert index_entries() == []

    recovered_opts =
      opts
      |> Keyword.put(:artifact_dir, artifact_dir)
      |> Keyword.put(:semantic_cache_static?, true)
      |> Keyword.put(:mirror_training_dataset?, true)

    assert {:ok, exact} = route("stored right", recovered_opts)
    assert exact.label == :RIGHT
    assert exact.strategy == :semantic_cache_exact
    refute_embedding_call()

    assert {:ok, semantic} = route("right-ish", recovered_opts)
    assert semantic.label == :RIGHT
    assert semantic.strategy == :semantic_cache_search
    assert_receive {:semantic_cache_embedding_call, "right-ish", vector}
    assert vector == [1.0, 0.0]
    refute_embedding_call()
  end

  test "invalid stored dimensions fail before the query provider is called", %{opts: opts} do
    rows = [
      %{
        id: "two-dimensional",
        text: "two dimensional",
        label: :RIGHT,
        verified?: true,
        embedding: [1.0, 0.0]
      },
      %{
        id: "three-dimensional",
        text: "three dimensional",
        label: :LEFT,
        verified?: true,
        embedding: [0.0, 1.0, 0.0]
      }
    ]

    assert {:ok, %{loaded: 2, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, rows, opts)

    assert {:error, {:semantic_cache_dimension_mismatch, id, actual, expected}} =
             Learned.lookup("right-ish", Keyword.put(opts, :semantic_search?, true))

    assert id in ["two-dimensional", "three-dimensional"]
    assert Enum.sort([actual, expected]) == [2, 3]
    refute_embedding_call()
  end

  @tag :tmp_dir
  test "a semantic miss and new learned match reuse one vector across snapshot restore", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    assert {:ok, %{loaded: 2, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), opts)

    text = "a completely new request"
    assert {:ok, router_context} = route_context(text, opts)
    assert is_nil(router_context.semantic_cache_query_embedding)
    assert {:ok, route} = Spectre.Router.route_from_context(router_context)
    assert route.label == :NEW_MATCH
    assert route.strategy == :llm_classifier

    assert_receive {:semantic_cache_embedding_call, ^text, query_vector}
    refute_embedding_call()

    assert {:ok, examples} = SemanticCache.examples(@agent, opts)
    assert learned = Enum.find(examples, &(&1.text == text))
    assert learned.text == text
    assert learned.embedding == query_vector

    assert {:ok, verified} = SemanticCache.verify(@agent, learned.id, opts)
    assert verified.embedding == query_vector
    refute_embedding_call()

    snapshot = Path.join(tmp_dir, "cache.jsonl")
    assert {:ok, ^snapshot} = SemanticCache.snapshot(@agent, Keyword.put(opts, :path, snapshot))
    assert File.read!(snapshot) =~ ~s("embedding":[0.0,1.0])

    assert :ok = SemanticCache.clear(@agent, opts)

    assert {:ok, %{loaded: 3, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, snapshot, opts)

    refute_embedding_call()

    assert {:ok, restored} = route(text, opts)
    assert restored.label == :NEW_MATCH
    assert restored.strategy == :semantic_cache_exact
    refute_embedding_call()
  end

  test "a legacy vectorless snapshot stays exact-only without provider backfill", %{opts: opts} do
    legacy = [%{text: "legacy exact", label: :RIGHT, verified?: true}]

    assert {:ok, %{loaded: 1, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, legacy, opts)

    assert {:ok, %{label: :RIGHT, strategy: :semantic_cache_exact}} =
             Learned.lookup("legacy exact", Keyword.put(opts, :semantic_search?, false))

    assert {:error, :semantic_cache_embeddings_not_loaded} =
             Learned.lookup("different query", Keyword.put(opts, :semantic_search?, true))

    refute_embedding_call()
  end

  test "timestamps and request-only adapter options do not invalidate the loaded index", %{
    opts: opts
  } do
    id = "stable-vector-revision"
    first_time = ~U[2026-07-24 10:00:00Z]
    second_time = ~U[2026-07-25 10:00:00Z]

    first_opts =
      Keyword.put(
        opts,
        :embedding,
        {@embedding, [test_pid: self(), request_ref: make_ref()]}
      )

    second_opts =
      Keyword.put(
        opts,
        :embedding,
        {@embedding, [test_pid: self(), request_ref: make_ref()]}
      )

    assert {:ok, %{loaded: 1, skipped: 0}} =
             SemanticCache.load_snapshot(
               @agent,
               [
                 %{
                   id: id,
                   text: "stable row",
                   label: :RIGHT,
                   verified: true,
                   embedding: [1.0, 0.0],
                   inserted_at: first_time,
                   updated_at: first_time
                 }
               ],
               first_opts
             )

    assert [{first_key, %{collection: first_collection}}] = index_entries()

    assert {:ok, %{loaded: 1, skipped: 0}} =
             SemanticCache.load_snapshot(
               @agent,
               [
                 %{
                   id: id,
                   text: "stable row",
                   label: :RIGHT,
                   verified: true,
                   embedding: [1.0, 0.0],
                   inserted_at: second_time,
                   updated_at: second_time
                 }
               ],
               second_opts
             )

    assert [{second_key, %{collection: second_collection}}] = index_entries()
    assert second_key == first_key
    assert second_collection == first_collection
    refute_embedding_call()
  end

  test "online learned rows evict the oldest entry at the configured per-agent bound", %{
    opts: opts
  } do
    bounded_opts = Keyword.put(opts, :semantic_cache_online_capacity, 2)

    rows = [
      %{
        id: "bounded-oldest",
        text: "bounded oldest",
        label: :RIGHT,
        verified?: true,
        embedding: [1.0, 0.0],
        updated_at: ~U[2026-01-01 00:00:00Z]
      },
      %{
        id: "bounded-middle",
        text: "bounded middle",
        label: :RIGHT,
        verified?: true,
        embedding: [1.0, 0.0],
        updated_at: ~U[2026-02-01 00:00:00Z]
      },
      %{
        id: "bounded-newest",
        text: "bounded newest",
        label: :LEFT,
        verified?: true,
        embedding: [0.0, 1.0],
        updated_at: ~U[2026-03-01 00:00:00Z]
      }
    ]

    assert {:ok, %{loaded: 3, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, rows, bounded_opts)

    assert {:ok, retained} = SemanticCache.examples(@agent, bounded_opts)

    assert MapSet.new(Enum.map(retained, & &1.id)) ==
             MapSet.new(["bounded-middle", "bounded-newest"])

    assert {:error, :not_found} =
             SemanticCache.get_example(@agent, "bounded-oldest", bounded_opts)
  end

  defp opts do
    Keyword.merge(@agent.__spectre_config__(),
      spectre_agent: @agent,
      spectre_rules: Enum.map(@agent.__spectre_rules__(), &Spectre.Rule.new/1),
      semantic_cache_static?: false,
      mirror_training_dataset?: false,
      semantic_cache_threshold: 0.8,
      classification_log?: false,
      embedding: {@embedding, [test_pid: self()]}
    )
  end

  defp stored_rows do
    [
      %{text: "stored right", label: :RIGHT, verified?: true, embedding: [1.0, 0.0]},
      %{text: "stored left", label: :LEFT, verified?: true, embedding: [-1.0, 0.0]}
    ]
  end

  defp route(text, opts) do
    with {:ok, context} <- route_context(text, opts) do
      Spectre.Router.route_from_context(context)
    end
  end

  defp route_context(text, opts) do
    input = %Spectre.Input{text: text}

    Spectre.Router.route_context(
      input,
      %Spectre.Context{
        agent: @agent,
        input: input,
        state: %Spectre.State{},
        opts: opts
      }
    )
  end

  defp refute_embedding_call do
    refute_receive {:semantic_cache_embedding_call, _text, _vector}
  end

  defp index_entries do
    Learned
    |> :ets.tab2list()
    |> Enum.filter(fn
      {{{:agent, @agent}, _hash}, _index} -> true
      _other -> false
    end)
  end

  defp replacement_pid(name, old_pid) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _other -> nil
    end
  end

  defp ready_replacement_owner(name, table, old_pid) do
    case replacement_pid(name, old_pid) do
      pid when is_pid(pid) -> if :ets.info(table, :owner) == pid, do: pid
      nil -> nil
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(fun, 0), do: flunk("condition did not become true: #{inspect(fun)}")
end
