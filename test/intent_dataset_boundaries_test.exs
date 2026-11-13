defmodule Spectre.IntentDatasetBoundariesTest.RemoteEncoder do
  def embed(text, opts) do
    if pid = opts[:test_pid], do: send(pid, {:remote_encode, text})

    case text do
      "unavailable" -> {:error, :remote_unavailable}
      "null vector" -> {:ok, nil}
      "three coordinates" -> {:ok, [1.0, 0.0, 0.0]}
      _ -> {:ok, [1.0, 0.0]}
    end
  end
end

defmodule Spectre.IntentDatasetBoundariesTest.LoadingEncoder do
  def load(_model, opts), do: opts[:load_result]
  def embed(_text, _opts), do: raise("invalid encoder loading must stop before encoding")
end

defmodule Spectre.IntentDatasetBoundariesTest.ReadOnlyDataset do
  def lookup(_text, opts) do
    if opts[:semantic_search?],
      do: {:ok, %{label: :pricing, accepted?: true, strategy: :custom_similarity}},
      else: {:error, :miss}
  end

  def examples(_agent, _opts), do: {:error, :dataset_store_unavailable}
end

defmodule Spectre.IntentDatasetBoundariesTest.InvalidIntentModel do
  def complete(_prompt, _opts), do: {:ok, "not_a_declared_intent"}
end

defmodule Spectre.IntentDatasetBoundariesTest.AbstainingArbitrator do
  @behaviour Spectre.Router.Arbitrator
  def decide(_arbitration, _opts),
    do: {:ok, Spectre.Route.new(label: :unknown, strategy: :custom_abstention)}
end

defmodule Spectre.IntentDatasetBoundariesTest.Agent do
  use Spectre.Agent, server: MyApp.Server

  flow :support do
    on(:pricing, semantic_examples: ["static price"])
    on(:private, dataset_lookup: false)
  end
end

defmodule Spectre.IntentDatasetBoundariesTest.UnavailableDatasetAgent do
  use Spectre.Agent, server: MyApp.Server
  intent_dataset(Spectre.IntentDatasetBoundariesTest.ReadOnlyDataset)

  flow :support do
    on(:pricing)
  end
end

defmodule Spectre.IntentDatasetBoundariesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Spectre.IntentDataset
  alias Spectre.IntentDataset.Embedding
  alias Spectre.Router.SemanticCache.Learned.Index
  alias Spectre.Server.Router

  @agent Spectre.IntentDatasetBoundariesTest.Agent
  @remote Spectre.IntentDatasetBoundariesTest.RemoteEncoder
  @loader Spectre.IntentDatasetBoundariesTest.LoadingEncoder

  setup do
    on_exit(fn -> IntentDataset.clear(@agent) end)
    :ok
  end

  @tag :tmp_dir
  test "a configured remote encoder needs no local model loading and preserves existing dimensions",
       %{tmp_dir: dir} do
    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], embedding: @remote)

    source =
      source(dir, [
        %{text: "already encoded", label: "pricing", embedding: [1.0, 0.0], metadata: metadata},
        %{text: "new wording", label: "pricing"}
      ])

    output = Path.join(dir, "output.jsonl")

    assert {:ok, %{embedded: 1, reused: 1}} =
             Embedding.prepare(@agent, source, output, embedding: @remote, test_pid: self())

    assert_receive {:remote_encode, "new wording"}
    refute_receive {:remote_encode, "already encoded"}
  end

  @tag :tmp_dir
  test "inconsistent saved dimensions are rejected before remote work", %{tmp_dir: dir} do
    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], embedding: @remote)

    source =
      source(dir, [
        %{text: "first", label: "pricing", embedding: [1.0, 0.0], metadata: metadata},
        %{text: "second", label: "pricing", embedding: [1.0, 0.0, 0.0], metadata: metadata}
      ])

    assert {:error, {:intent_dataset_row, 2, {:embedding_dimension_mismatch, 3, 2}}} =
             Embedding.prepare(@agent, source, Path.join(dir, "output.jsonl"),
               embedding: @remote,
               test_pid: self()
             )

    refute_receive {:remote_encode, _}
  end

  @tag :tmp_dir
  test "invalid model loading, missing vectors and incompatible fresh vectors leave the target intact",
       %{tmp_dir: dir} do
    output = Path.join(dir, "output.jsonl")
    File.write!(output, "previous data")
    source = source(dir, [%{text: "pricing", label: "pricing"}])

    for {reply, expected} <- [
          {{:ok, 0}, :invalid_embedding_dimensions},
          {{:error, :model_unavailable}, :model_unavailable}
        ] do
      assert {:error, ^expected} =
               Embedding.prepare(@agent, source, output,
                 embedding: {@loader, [load_result: reply]}
               )

      assert File.read!(output) == "previous data"
    end

    source = source(dir, [%{text: "null vector", label: "pricing"}])

    assert {:error, :embedding_vector_required} =
             Embedding.prepare(@agent, source, output, embedding: @remote)

    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], embedding: @remote)

    source =
      source(dir, [
        %{text: "stored", label: "pricing", embedding: [1.0, 0.0], metadata: metadata},
        %{text: "three coordinates", label: "pricing"}
      ])

    assert {:error, {:embedding_dimension_mismatch, 3, 2}} =
             Embedding.prepare(@agent, source, output, embedding: @remote)

    assert File.read!(output) == "previous data"
  end

  @tag :tmp_dir
  test "encoder dimensions are checked against stored vectors before encoding new text", %{
    tmp_dir: dir
  } do
    options = [embedding: {@loader, [load_result: {:ok, 3}]}]
    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], options)

    source =
      source(dir, [
        %{text: "stored", label: "pricing", embedding: [1.0, 0.0], metadata: metadata},
        %{text: "new text", label: "pricing"}
      ])

    assert {:error, {:embedding_dimension_mismatch, 2, 3}} =
             Embedding.prepare(@agent, source, Path.join(dir, "output.jsonl"), options)
  end

  @tag :tmp_dir
  test "malformed JSON, text, metadata and vectors fail without deleting vectorless source examples",
       %{tmp_dir: dir} do
    output = Path.join(dir, "output.jsonl")
    File.write!(output, "previous data")

    invalid = [
      {"{invalid", :json},
      {"[1,2]", :invalid_intent_dataset_row},
      {Spectre.JSON.encode!(%{text: nil, label: "pricing"}), :invalid_text},
      {Spectre.JSON.encode!(%{text: " ", label: "pricing"}), :invalid_text},
      {Spectre.JSON.encode!(%{text: "pricing", label: "pricing", metadata: []}),
       :invalid_metadata},
      {Spectre.JSON.encode!(%{text: "pricing", label: "pricing", embedding: []}),
       :invalid_semantic_cache_embedding},
      {Spectre.JSON.encode!(%{text: "private", label: "private"}), {:uncacheable_label, :private}}
    ]

    for {contents, expected} <- invalid do
      path = Path.join(dir, "source.jsonl")
      File.write!(path, contents)

      assert {:error, {:intent_dataset_row, 1, reason}} =
               Embedding.prepare(@agent, path, output, embedding: @remote, test_pid: self())

      if expected == :json,
        do: assert(match?({:invalid_json, _}, reason)),
        else: assert(reason == expected)

      assert File.read!(path) == contents
      assert File.read!(output) == "previous data"
    end

    refute_receive {:remote_encode, _}
  end

  @tag :tmp_dir
  test "an empty batch creates a valid empty artifact without selecting an encoder", %{
    tmp_dir: dir
  } do
    path = source(dir, [])
    output = Path.join(dir, "empty.jsonl")
    assert {:ok, %{examples: 0, embedded: 0, reused: 0}} = Embedding.prepare(@agent, path, output)
    assert File.read!(output) == ""
  end

  @tag :tmp_dir
  test "output filesystem failures clean temporary files and preserve the existing target directory",
       %{tmp_dir: dir} do
    path = source(dir, [%{text: "pricing", label: "pricing"}])
    output = Path.join(dir, "existing-directory")
    File.mkdir_p!(output)
    assert {:error, reason} = Embedding.prepare(@agent, path, output, embedding: @remote)
    assert reason in [:eisdir, :eexist]
    assert File.dir?(output)
    assert Path.wildcard(output <> ".tmp-*") == []
  end

  @tag :tmp_dir
  test "invalid encoder profile configuration fails before any request", %{tmp_dir: dir} do
    path = source(dir, [%{text: "pricing", label: "pricing"}])

    assert {:error, :invalid_semantic_cache_embedding_model_profile} =
             Embedding.prepare(@agent, path, Path.join(dir, "output.jsonl"),
               embedding: @remote,
               embedding_model_profile: :invalid,
               test_pid: self()
             )

    refute_receive {:remote_encode, _}
  end

  test "disabled lookup phases and malformed option groups remain explicit" do
    assert {:error, :dataset_lookup_disabled} =
             IntentDataset.lookup("price", lookup: [exact: false, semantic: false])

    assert {:error, :missing_semantic_cache_adapter} = IntentDataset.lookup("price")

    for opts <- [[lookup: 9], [collect: false], [search: [:malformed]]] do
      assert_raise ArgumentError, fn -> IntentDataset.normalize_options(opts) end
    end
  end

  test "a custom dataset can fall back from an exact miss without changing its strategy" do
    assert {:ok, %{label: :pricing, strategy: :custom_similarity}} =
             IntentDataset.lookup("price",
               intent_dataset: Spectre.IntentDatasetBoundariesTest.ReadOnlyDataset,
               lookup: [exact: true, semantic: true]
             )
  end

  test "a failed edit keeps the previous text and vector usable" do
    opts = [
      agent: @agent,
      embedding: @remote,
      include_static_examples: false,
      include_training_examples: false
    ]

    assert {:ok, saved} =
             IntentDataset.put("original price", %{label: :pricing, verified?: true}, opts)

    assert {:error, :remote_unavailable} =
             IntentDataset.update_example(@agent, saved.id, %{text: "unavailable"}, opts)

    assert {:ok, current} = IntentDataset.get_example(@agent, saved.id, opts)
    assert current.text == saved.text
    assert current.embedding == saved.embedding
    assert {:ok, %{label: :pricing}} = IntentDataset.lookup("original price", opts)
  end

  @tag :tmp_dir
  test "CLI usage and provider errors explain failures without creating output", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/expected: mix spectre.intent_dataset.embed/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Embed.run([])
    end

    path = source(dir, [%{text: "pricing", label: "unknown"}])
    output = Path.join(dir, "output.jsonl")

    assert_raise Mix.Error, ~r/intent dataset embedding failed.*unknown_label/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Embed.run([inspect(@agent), path, output])
    end

    refute File.exists?(output)
  end

  @tag :tmp_dir
  test "export all includes declared examples and reports invalid source or storage failure", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "export.jsonl")

    capture_io(fn ->
      assert :ok =
               Mix.Tasks.Spectre.IntentDataset.Export.run([
                 inspect(@agent),
                 path,
                 "--source",
                 "all"
               ])
    end)

    assert File.read!(path) =~ "static price"

    assert_raise Mix.Error, ~r/expected: mix spectre.intent_dataset.export/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Export.run([inspect(@agent), path, "--unknown"])
    end

    assert_raise Mix.Error, ~r/invalid dataset source/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Export.run([inspect(@agent), path, "--source", "invalid"])
    end

    assert_raise Mix.Error, ~r/dataset_store_unavailable/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Export.run([
        inspect(Spectre.IntentDatasetBoundariesTest.UnavailableDatasetAgent),
        path
      ])
    end

    parent_file = Path.join(dir, "not-a-directory")
    File.write!(parent_file, "preserve me")

    assert_raise Mix.Error, ~r/intent dataset export failed/, fn ->
      Mix.Tasks.Spectre.IntentDataset.Export.run([
        inspect(@agent),
        Path.join(parent_file, "export.jsonl")
      ])
    end

    assert File.read!(parent_file) == "preserve me"
  end

  test "routing a model's unknown label preserves the classifier failure" do
    module =
      agent("""
      classifier :llm, Spectre.IntentDatasetBoundariesTest.InvalidIntentModel
      router strategies: [:llm_classifier], log_decisions: false
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched,
            %{
              reason:
                {:classifier_error, {:unknown_llm_classifier_label, "not_a_declared_intent"}}
            }} = Router.route(module, "price")

    assert_raise Mix.Error, ~r/expected: mix spectre.routes/, fn ->
      Mix.Tasks.Spectre.Routes.run([])
    end
  end

  test "custom arbitration abstention retains conflicting evidence for the fallback" do
    module =
      agent("""
      router strategies: [:regex, :bag], log_decisions: false,
        arbitrator: Spectre.IntentDatasetBoundariesTest.AbstainingArbitrator
      flow :support do
        on :pricing, regex: ~r/^request$/
        on :account, bag: ["request"]
      end
      """)

    assert {:unmatched, %{reason: :ambiguous}} = Router.route(module, "request")

    assert Router.dispatch_key(%Spectre.Route{flow: :support, label: :pricing, scope: nil}) ==
             {:support, :pricing}
  end

  defp source(dir, rows) do
    path = Path.join(dir, "source.jsonl")
    File.write!(path, Enum.map_join(rows, "\n", &Spectre.JSON.encode!/1))
    path
  end

  defp agent(body) do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string(
      "defmodule #{inspect(module)} do\nuse Spectre.Agent, server: MyApp.Server\n#{body}\nend"
    )

    module
  end
end
