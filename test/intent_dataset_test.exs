defmodule Spectre.IntentDatasetTest.Embedding do
  @behaviour Spectre.Classifier.Embedding

  def load(_model, _opts), do: {:ok, 2}

  def embed(text, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:dataset_embedding, text})
    vector = if String.contains?(text, "account"), do: [0.0, 1.0], else: [1.0, 0.0]
    {:ok, vector}
  end
end

defmodule Spectre.IntentDatasetTest.Agent do
  use Spectre.Agent, server: MyApp.SupportServer

  embedding(Spectre.IntentDatasetTest.Embedding, model: "test-encoder")
  router(strategies: [:intent_dataset])

  flow :support, defaults: [collect_intent: true] do
    on(:pricing)
    on(:account)
    on(:private, dataset_lookup: false, collect_intent: false)
  end
end

defmodule Spectre.IntentDatasetTest.FailingLookup do
  def lookup(_text, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:dataset_lookup_phase, opts[:semantic_search?]})
    if opts[:semantic_search?], do: {:error, :miss}, else: {:error, :adapter_failed}
  end
end

defmodule Spectre.IntentDatasetTest do
  use ExUnit.Case, async: false

  alias Spectre.IntentDataset

  @agent Spectre.IntentDatasetTest.Agent

  setup do
    opts = [
      agent: @agent,
      include_static_examples: false,
      include_training_examples: false,
      test_pid: self()
    ]

    assert :ok = IntentDataset.clear(@agent, opts)
    on_exit(fn -> IntentDataset.clear(@agent, opts) end)
    {:ok, opts: opts}
  end

  test "configuration keeps explicit aliases, flags and metric semantics" do
    normalized =
      IntentDataset.normalize_options(
        lookup: [exact: false, semantic: true, include_unverified: true],
        search: [method: :quantized, candidates: 30, limit: 2, min_score: 0.9],
        collection: [index: :flat, metric: :cosine],
        max_cached_indexes: 3,
        max_index_revisions: 2,
        collect: [enabled: false]
      )

    refute normalized[:intent_exact?]
    assert normalized[:semantic_search?]
    assert normalized[:semantic_cache_include_unverified?]
    assert normalized[:semantic_cache_search_method] == :quantized
    assert normalized[:semantic_cache_search_candidates] == 30
    assert normalized[:semantic_cache_capacity] == 3
    assert normalized[:index_capacity] == 2
    refute normalized[:semantic_learn?]

    assert_raise ArgumentError, ~r/conflicting/, fn ->
      IntentDataset.normalize_options(search: [limit: 2], semantic_cache_top_k: 7)
    end

    assert_raise ArgumentError, ~r/unknown collection option/, fn ->
      IntentDataset.normalize_options(collection: [metric: :hamming])
    end

    assert_raise ArgumentError, ~r/unknown lookup option/, fn ->
      IntentDataset.normalize_options(lookup: [sematic: true])
    end
  end

  test "text-only examples survive snapshots and exact lookup without encoding", %{opts: opts} do
    assert {:ok, %{loaded: 1, skipped: 0}} =
             IntentDataset.load_snapshot(
               @agent,
               [
                 %{id: "vectorless", text: "known price", label: :pricing, verified: true}
               ],
               opts
             )

    assert {:ok, %{label: :pricing, strategy: :intent_exact}} =
             IntentDataset.lookup("known price", opts)

    refute_receive {:dataset_embedding, _}

    assert {:error, :semantic_cache_embeddings_not_loaded} =
             IntentDataset.lookup(
               "different price",
               opts ++ [lookup: [exact: false, semantic: true]]
             )

    refute_receive {:dataset_embedding, _}
    assert {:ok, [snapshot]} = IntentDataset.snapshot(@agent, opts)
    assert snapshot.embedding == nil
    assert :ok = IntentDataset.clear(@agent, opts)
    assert {:ok, %{loaded: 1}} = IntentDataset.load_snapshot(@agent, [snapshot], opts)
    assert {:ok, %{strategy: :intent_exact}} = IntentDataset.lookup("known price", opts)
  end

  test "online collection remains excluded until verification or explicit inclusion", %{
    opts: opts
  } do
    assert {:ok, row} =
             IntentDataset.put(
               "new price wording",
               %{label: :pricing, strategy: :llm_classifier},
               opts
             )

    assert row.embedding == [1.0, 0.0]
    refute row.verified?
    assert_receive {:dataset_embedding, "new price wording"}

    assert {:error, :empty_learned_semantic_cache} =
             IntentDataset.lookup("new price wording", opts)

    assert {:ok, %{label: :pricing, strategy: :intent_exact}} =
             IntentDataset.lookup(
               "new price wording",
               opts ++ [lookup: [include_unverified: true]]
             )

    assert {:ok, verified} = IntentDataset.verify(@agent, row.id, opts)
    assert verified.verified?
    assert {:ok, %{label: :pricing}} = IntentDataset.lookup("new price wording", opts)
    refute_receive {:dataset_embedding, _}
  end

  test "lookup disabled is honored even with a loaded matching example", %{opts: opts} do
    assert {:ok, %{loaded: 1}} =
             IntentDataset.load_snapshot(
               @agent,
               [
                 %{text: "known price", label: :pricing, verified: true}
               ],
               opts
             )

    assert {:error, :dataset_lookup_disabled} =
             IntentDataset.lookup("known price", opts ++ [lookup: false])

    assert {:ok, %{label: :pricing}} = IntentDataset.lookup("known price", opts)
  end

  test "an exact provider failure keeps its cause instead of becoming a semantic miss" do
    assert {:error, :adapter_failed} =
             IntentDataset.lookup("price",
               intent_dataset: Spectre.IntentDatasetTest.FailingLookup,
               lookup: [exact: true, semantic: true],
               test_pid: self()
             )

    assert_receive {:dataset_lookup_phase, false}
    refute_receive {:dataset_lookup_phase, true}
  end

  test "quantized search encodes only the query and returns intent evidence", %{opts: opts} do
    rows = [
      %{text: "stored price", label: :pricing, verified: true, embedding: [1.0, 0.0]},
      %{text: "stored account", label: :account, verified: true, embedding: [0.0, 1.0]},
      %{text: "vectorless account", label: :account, verified: true}
    ]

    assert {:ok, %{loaded: 3}} = IntentDataset.load_snapshot(@agent, rows, opts)
    refute_receive {:dataset_embedding, _}

    assert {:ok, %{label: :pricing, strategy: :intent_similarity}} =
             IntentDataset.lookup(
               "price query",
               opts ++
                 [
                   lookup: [exact: false, semantic: true],
                   search: [method: :quantized, candidates: 10, limit: 2, min_score: 0.9]
                 ]
             )

    assert_receive {:dataset_embedding, "price query"}
    refute_receive {:dataset_embedding, _}
  end

  test "example edits, relabel and delete update both lookup projections", %{opts: opts} do
    assert {:ok, row} =
             IntentDataset.put("price original", %{label: :pricing, verified?: true}, opts)

    assert_receive {:dataset_embedding, "price original"}

    assert {:ok, edited} =
             IntentDataset.update_example(@agent, row.id, %{text: "account new"}, opts)

    assert edited.id == row.id
    assert edited.embedding == [0.0, 1.0]
    assert_receive {:dataset_embedding, "account new"}
    assert {:error, :miss} = IntentDataset.lookup("price original", opts)

    assert {:ok, relabeled} = IntentDataset.relabel(@agent, row.id, :account, opts)
    assert relabeled.verified?
    assert {:ok, %{label: :account}} = IntentDataset.lookup("account new", opts)
    assert {:ok, fetched} = IntentDataset.get_example(@agent, row.id, opts)
    assert fetched.label == :account
    assert :ok = IntentDataset.delete(@agent, row.id, opts)
    assert {:error, :not_found} = IntentDataset.get_example(@agent, row.id, opts)
    refute_receive {:dataset_embedding, _}
  end

  test "a compatible profile is required before querying saved vectors", %{opts: opts} do
    assert {:ok, row} =
             IntentDataset.put("stored price", %{label: :pricing, verified?: true}, opts)

    assert_receive {:dataset_embedding, "stored price"}
    assert {:ok, [_]} = IntentDataset.snapshot(@agent, opts)

    assert {:error, {:semantic_cache_embedding_profile_mismatch, id}} =
             IntentDataset.lookup(
               "another price",
               opts ++
                 [
                   lookup: [exact: false, semantic: true],
                   embedding: {Spectre.IntentDatasetTest.Embedding, [model: "different-encoder"]}
                 ]
             )

    assert id == row.id
    refute_receive {:dataset_embedding, _}
  end

  @tag :tmp_dir
  test "training companions and dataset sources remain usable by new Agents", %{
    opts: opts,
    tmp_dir: dir
  } do
    source = Path.join(dir, "source.json")

    File.write!(
      source,
      Spectre.JSON.encode!([
        %{text: "price input", label: "pricing"},
        %{text: "account input", label: "account"},
        %{text: "unknown input", label: "NOT_DECLARED"}
      ])
    )

    assert {:ok, rows} = Spectre.Training.Dataset.from_agent(@agent, source: source)
    # Preserve the existing training artifact label codec.
    assert Enum.sort(Enum.map(rows, & &1.label)) == ["ACCOUNT", "PRICING"]
    dataset = Path.join(dir, "dataset.json")
    File.write!(dataset, Spectre.JSON.encode!(rows))
    artifact = Path.join(dir, "artifacts")

    assert {:ok, %{examples: 2, dimensions: 2}} =
             Spectre.Classifier.Trainer.train(dataset, artifact,
               embedding_adapter: Spectre.IntentDatasetTest.Embedding,
               test_pid: self()
             )

    assert File.exists?(Path.join(artifact, "semantic_cache.jsonl"))

    assert {:ok, %{label: :pricing, strategy: :intent_exact}} =
             IntentDataset.lookup(
               "price input",
               Keyword.merge(opts,
                 artifact_dir: artifact,
                 include_static_examples: true,
                 include_training_examples: true
               )
             )
  end
end
