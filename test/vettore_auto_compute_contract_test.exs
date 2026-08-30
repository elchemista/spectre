defmodule SpectreVettoreAutoComputeContractTest.Embedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  @impl true
  def load(_model, _opts), do: {:ok, 2}

  @impl true
  def embed(_text, _opts), do: {:ok, [1.0, 0.0]}
end

defmodule SpectreVettoreAutoComputeContractTest.Agent do
  @moduledoc false
  use Spectre.Agent

  embedding(SpectreVettoreAutoComputeContractTest.Embedding)
  router(via: [:semantic_cache])

  flow :automatic_compute_contract do
    on :MATCH, cache: true do
      reply(:match)
    end
  end
end

defmodule SpectreVettoreAutoComputeContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Classifier
  alias Spectre.Classifier.Math
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Learned.Index

  @agent SpectreVettoreAutoComputeContractTest.Agent
  @vettore_gpu_keys [:gpu, :gpu_fallback, :gpu_min_size]

  setup do
    previous = Map.new(@vettore_gpu_keys, &{&1, Application.fetch_env(:vettore, &1)})

    Application.put_env(:vettore, :gpu, false)
    Application.put_env(:vettore, :gpu_fallback, :cpu)
    Application.put_env(:vettore, :gpu_min_size, 1)

    opts = semantic_opts()
    assert :ok = SemanticCache.clear(@agent, opts)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:vettore, key, value)
        {key, :error} -> Application.delete_env(:vettore, key)
      end)

      SemanticCache.clear(@agent, opts)
    end)

    {:ok, semantic_opts: opts}
  end

  test "classifier math uses explicit automatic compute options" do
    Application.put_env(:vettore, :gpu, :malformed)
    Application.put_env(:vettore, :gpu_fallback, :malformed)
    Application.put_env(:vettore, :gpu_min_size, :malformed)

    assert Math.cosine([1.0, 0.0], [1.0, 0.0]) == 1.0
    assert_in_delta hd(Math.normalize([3.0, 4.0])), 0.6, 0.00001
  end

  test "Flat indexes default to automatic GPU selection with CPU fallback", %{
    semantic_opts: opts
  } do
    assert {:ok, %{loaded: 1, skipped: 0}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), opts)

    assert [{_key, %{collection: collection}}] = index_entries()
    assert collection.score == :raw
    assert collection.index_options[:gpu] == :auto
    assert collection.index_options[:gpu_fallback] == :cpu
    assert collection.index_options[:gpu_min_size] == 1_000_000

    assert {:ok, %{label: :MATCH}} = SemanticCache.lookup("near match", opts)
  end

  @tag :tmp_dir
  test "classifier Flat options can override automatic GPU selection", %{tmp_dir: tmp} do
    write_classifier(tmp)
    opts = classifier_opts(tmp)

    assert {:ok, %{label: "MATCH"}} = Classifier.classify_once("match", opts)

    assert {:ok, %{label: "MATCH"}} =
             Classifier.classify_once(
               "match",
               Keyword.put(opts, :local_classifier_index_options, gpu: false)
             )

    assert {:ok, %{label: "MATCH"}} =
             Classifier.classify_once(
               "match",
               Keyword.put(opts, :local_classifier_index_options,
                 gpu: true,
                 gpu_fallback: :cpu,
                 gpu_min_size: 1
               )
             )

    assert {:ok, %{label: "MATCH"}} =
             Classifier.classify_once(
               "match",
               Keyword.put(opts, :local_classifier_index_options,
                 gpu: :auto,
                 gpu_fallback: :cpu,
                 gpu_min_size: 10
               )
             )

    assert {:error, :invalid_gpu_option} =
             Classifier.classify_once(
               "match",
               Keyword.put(opts, :local_classifier_index_options, gpu: :invalid)
             )
  end

  test "semantic-cache Flat options override defaults and retain Vettore validation", %{
    semantic_opts: opts
  } do
    cpu_opts =
      Keyword.put(opts, :semantic_cache_index_options,
        gpu: false,
        gpu_min_size: 25
      )

    assert {:ok, %{loaded: 1}} =
             SemanticCache.load_snapshot(@agent, stored_rows(), cpu_opts)

    assert [{_key, %{collection: collection}}] = index_entries()
    assert collection.index_options[:gpu] == false
    assert collection.index_options[:gpu_fallback] == :cpu
    assert collection.index_options[:gpu_min_size] == 25

    assert :ok = Index.clear(@agent)

    auto_opts =
      Keyword.put(opts, :semantic_cache_index_options,
        gpu: :auto,
        gpu_fallback: :cpu,
        gpu_min_size: 10
      )

    assert {:ok, rows} = Learned.rows(auto_opts)
    assert {:ok, 1} = Index.warm(rows, auto_opts)

    assert [{_key, %{collection: collection}}] = index_entries()
    assert collection.index_options[:gpu] == :auto
    assert collection.index_options[:gpu_fallback] == :cpu
    assert collection.index_options[:gpu_min_size] == 10

    assert :ok = Index.clear(@agent)

    invalid_opts =
      Keyword.put(opts, :semantic_cache_index_options,
        gpu: :invalid,
        gpu_fallback: :cpu,
        gpu_min_size: 10
      )

    assert {:error, :invalid_gpu_option} = Index.warm(rows, invalid_opts)
  end

  test "HNSW index options remain untouched", %{semantic_opts: opts} do
    hnsw_options = [m: 4, m0: 8, ef_construction: 16]

    hnsw_opts =
      opts
      |> Keyword.put(:semantic_cache_index, :hnsw)
      |> Keyword.put(:semantic_cache_index_options, hnsw_options)

    assert {:ok, %{loaded: 1}} = SemanticCache.load_snapshot(@agent, stored_rows(), hnsw_opts)
    assert [{_key, %{collection: collection}}] = index_entries()
    assert collection.index == :hnsw
    assert collection.index_options == hnsw_options
  end

  defp semantic_opts do
    Keyword.merge(@agent.__spectre_config__(),
      spectre_agent: @agent,
      spectre_rules: Enum.map(@agent.__spectre_rules__(), &Spectre.Rule.new/1),
      semantic_cache_static?: false,
      semantic_search?: true,
      mirror_training_dataset?: false,
      semantic_cache_threshold: 0.5,
      embedding: SpectreVettoreAutoComputeContractTest.Embedding
    )
  end

  defp stored_rows do
    [%{text: "stored match", label: :MATCH, verified?: true, embedding: [1.0, 0.0]}]
  end

  defp index_entries do
    Learned
    |> :ets.tab2list()
    |> Enum.filter(fn
      {{{:agent, @agent}, _hash}, _index} -> true
      _other -> false
    end)
  end

  defp classifier_opts(tmp) do
    [
      artifact_dir: tmp,
      load_embedding: fn _model, _opts -> {:ok, 2} end,
      embed: fn _text, _opts -> {:ok, [1.0, 0.0]} end,
      classification_log?: false
    ]
  end

  defp write_classifier(tmp) do
    artifact = %{
      version: 1,
      kind: :centroid_head,
      encoder_model: "automatic-compute-contract",
      dimensions: 2,
      labels: ["MATCH"],
      centroids: %{"MATCH" => [1.0, 0.0]},
      accept_threshold: 0.5,
      margin_threshold: 0.0,
      high_confidence_threshold: 0.9
    }

    File.write!(Path.join(tmp, "classifier.etf"), :erlang.term_to_binary(artifact))
  end
end
