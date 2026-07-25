defmodule SpectreRealExFastembedSemanticCacheTest.CountingEmbedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  alias Spectre.Classifier.Embeddings.ExFastembed

  @impl true
  def load(model, opts) do
    result = ExFastembed.load(model, opts)
    notify(opts, {:real_embedding_load, model, result})
    result
  end

  @impl true
  def download(model, opts), do: load(model, opts)

  @impl true
  def embed(text, opts) do
    result = ExFastembed.embed(text, opts)
    notify(opts, {:real_embedding_call, text, result})
    result
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, message)
    :ok
  end
end

defmodule SpectreRealExFastembedSemanticCacheTest.ClassifierLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl true
  def complete(_prompt, _opts), do: {:ok, "SALES"}
end

defmodule SpectreRealExFastembedSemanticCacheTest.ReplyRenderer do
  @moduledoc false

  def render(prompt, _assigns, _opts), do: Atom.to_string(prompt)
end

defmodule SpectreRealExFastembedSemanticCacheTest.Agent do
  @moduledoc false
  use Spectre.Agent, prompt_root: "tmp/real_ex_fastembed_semantic_cache/prompts"

  embedding(
    SpectreRealExFastembedSemanticCacheTest.CountingEmbedding,
    model: "Xenova/bge-small-en-v1.5"
  )

  classifier(SpectreRealExFastembedSemanticCacheTest.ClassifierLLM)
  router(via: [:semantic_cache, :llm_classifier])

  flow :conversation do
    on :PRICING, learn: true do
      reply(
        :pricing,
        renderer: {SpectreRealExFastembedSemanticCacheTest.ReplyRenderer, :render}
      )
    end

    on :SALES, learn: true do
      reply(
        :sales,
        renderer: {SpectreRealExFastembedSemanticCacheTest.ReplyRenderer, :render}
      )
    end
  end
end

defmodule SpectreRealExFastembedSemanticCacheTest do
  use ExUnit.Case, async: false

  alias Spectre.Classifier.Trainer
  alias Spectre.Router.SemanticCache

  @moduletag :real_ex_fastembed
  @moduletag timeout: 600_000

  @agent SpectreRealExFastembedSemanticCacheTest.Agent
  @adapter SpectreRealExFastembedSemanticCacheTest.CountingEmbedding
  @backend Module.concat(["ExFastembed"])
  @model "Xenova/bge-small-en-v1.5"

  setup_all do
    unless Code.ensure_loaded?(@backend) do
      flunk("""
      real ExFastembed tests were requested, but ExFastembed is not loaded.
      Set SPECTRE_EX_FASTEMBED_PATH to a real ex_fastembed checkout before mix deps.get.
      """)
    end

    :ok
  end

  @tag :tmp_dir
  test "real model trains, restores, routes, and learns with exact call cardinality", %{
    tmp_dir: tmp_dir
  } do
    dataset_path = Path.join(tmp_dir, "dataset.json")
    artifact_dir = Path.join(tmp_dir, "artifact")

    training_rows = [
      %{"text" => "hello there friend", "label" => "PRICING"},
      %{"text" => "talk to enterprise sales", "label" => "SALES"}
    ]

    File.write!(dataset_path, Jason.encode!(training_rows))

    training_opts = [
      embedding_adapter: @adapter,
      encoder_model: @model,
      ex_fastembed_module: @backend,
      test_pid: self(),
      embedding_timeout: 300_000
    ]

    assert {:ok, %{dimensions: dimensions, examples: 2}} =
             Trainer.train(dataset_path, artifact_dir, training_opts)

    assert dimensions > 0
    assert_receive {:real_embedding_load, @model, {:ok, ^dimensions}}

    assert_receive {:real_embedding_call, "hello there friend", {:ok, pricing_vector}}
    assert_receive {:real_embedding_call, "talk to enterprise sales", {:ok, sales_vector}}
    refute_receive {:real_embedding_call, _text, _result}

    assert length(pricing_vector) == dimensions
    assert length(sales_vector) == dimensions

    persisted_rows = read_jsonl(Path.join(artifact_dir, "semantic_cache.jsonl"))
    assert embedding_for(persisted_rows, "hello there friend") == pricing_vector
    assert embedding_for(persisted_rows, "talk to enterprise sales") == sales_vector

    opts = runtime_opts(artifact_dir)
    assert :ok = SemanticCache.clear(@agent, opts)
    drain_embedding_messages()

    assert {:ok, exact_route} = route("hello there friend", opts)
    assert exact_route.label == :PRICING
    assert exact_route.strategy == :semantic_cache_exact
    refute_receive {:real_embedding_call, _text, _result}

    semantic_text = "connect me with an enterprise sales representative"
    semantic_opts = Keyword.put(opts, :semantic_cache_threshold, 0.0)

    assert {:ok, semantic_route} = route(semantic_text, semantic_opts)
    assert semantic_route.label == :SALES
    assert semantic_route.strategy == :semantic_cache_search

    assert_receive {:real_embedding_call, ^semantic_text, {:ok, semantic_vector}}
    assert length(semantic_vector) == dimensions
    refute_receive {:real_embedding_call, _text, _result}

    new_text = "please connect me with the sales team"
    assert {:ok, learned_route} = route(new_text, opts)
    assert learned_route.label == :SALES
    assert learned_route.strategy == :llm_classifier

    assert_receive {:real_embedding_call, ^new_text, {:ok, query_vector}}
    refute_receive {:real_embedding_call, _text, _result}

    assert {:ok, [learned]} = SemanticCache.examples(@agent, opts)
    assert learned.text == new_text
    assert learned.embedding == query_vector
    refute learned.verified?

    assert {:ok, verified} = SemanticCache.verify(@agent, learned.id, opts)
    assert verified.embedding == query_vector
    refute_receive {:real_embedding_call, _text, _result}

    snapshot_path = Path.join(tmp_dir, "semantic_cache.snapshot.jsonl")
    assert {:ok, ^snapshot_path} = SemanticCache.snapshot(@agent, opts ++ [path: snapshot_path])
    assert embedding_for(read_jsonl(snapshot_path), new_text) == query_vector

    assert :ok = SemanticCache.clear(@agent, opts)

    assert {:ok, %{loaded: 1, skipped: 0}} =
             SemanticCache.load_snapshot(
               @agent,
               snapshot_path,
               Keyword.put(opts, :semantic_cache_static?, false)
             )

    refute_receive {:real_embedding_call, _text, _result}

    assert {:ok, restored_route} =
             route(new_text, Keyword.put(opts, :semantic_cache_static?, false))

    assert restored_route.label == :SALES
    assert restored_route.strategy == :semantic_cache_exact
    refute_receive {:real_embedding_call, _text, _result}

    assert :ok = SemanticCache.clear(@agent, opts)
  end

  defp runtime_opts(artifact_dir) do
    Keyword.merge(@agent.__spectre_config__(),
      artifact_dir: artifact_dir,
      classification_log?: false,
      embedding:
        {@adapter,
         [
           model: @model,
           ex_fastembed_module: @backend,
           test_pid: self()
         ]},
      ex_fastembed_module: @backend,
      test_pid: self(),
      semantic_cache_threshold: 2.0,
      embedding_timeout: 300_000,
      semantic_cache_timeout: 300_000,
      router_timeout: 600_000
    )
  end

  defp route(text, opts) do
    input = %Spectre.Input{text: text}

    Spectre.Router.route(
      input,
      %Spectre.Context{
        agent: @agent,
        input: input,
        state: %Spectre.State{},
        opts: opts
      }
    )
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp embedding_for(rows, text) do
    rows
    |> Enum.find(&(Map.fetch!(&1, "text") == text))
    |> Map.fetch!("embedding")
  end

  defp drain_embedding_messages do
    receive do
      {:real_embedding_load, _model, _result} -> drain_embedding_messages()
      {:real_embedding_call, _text, _result} -> drain_embedding_messages()
    after
      0 -> :ok
    end
  end
end
