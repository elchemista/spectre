defmodule Spectre.IntentDatasetEmbedTest.Encoder do
  @behaviour Spectre.Classifier.Embedding
  def load(model, _opts) do
    notify({:batch_encoder_load, model})
    {:ok, 2}
  end

  def embed(text, _opts) do
    notify({:batch_encoder_embed, text})

    case text do
      "provider failure" -> {:error, :encoder_unavailable}
      "wrong dimensions" -> {:ok, [1.0, 0.0, 0.0]}
      "account old" -> {:ok, [0.0, 1.0]}
      _ -> {:ok, [1.0, 0.0]}
    end
  end

  defp notify(message) do
    if pid = Application.get_env(:spectre, :intent_dataset_embed_test_pid), do: send(pid, message)
  end
end

defmodule Spectre.IntentDatasetEmbedTest.Agent do
  use Spectre.Agent, server: MyApp.Server
  embedding(Spectre.IntentDatasetEmbedTest.Encoder, model: "test-v1")

  flow :support do
    on(:pricing)
    on(:account)
  end
end

defmodule Spectre.IntentDatasetEmbedTest.GlobalAgent do
  use Spectre.Agent, server: MyApp.Server

  flow :support do
    on(:pricing)
  end
end

defmodule Spectre.IntentDatasetEmbedTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Spectre.IntentDataset
  alias Spectre.IntentDataset.Embedding
  alias Spectre.Router.SemanticCache.Learned.Index

  @agent Spectre.IntentDatasetEmbedTest.Agent

  setup do
    Application.put_env(:spectre, :intent_dataset_embed_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:spectre, :intent_dataset_embed_test_pid)
      IntentDataset.clear(@agent)
    end)

    :ok
  end

  @tag :tmp_dir
  test "CLI encodes text-only rows, reuses compatible vectors and creates a usable index", %{
    tmp_dir: dir
  } do
    {:ok, metadata} = Index.bind_embedding_profile(%{}, [0.0, 1.0], @agent.__spectre_config__())

    existing = %{
      id: "existing",
      text: "account old",
      label: "account",
      verified: true,
      embedding: [0.0, 1.0],
      metadata: Map.put(metadata, "origin", "verified offline")
    }

    source = write_source(dir, [existing, %{text: "price new", label: "pricing", verified: true}])
    output = Path.join(dir, "prepared.jsonl")
    before = File.read!(source)

    text =
      capture_io(fn ->
        assert :ok = Mix.Tasks.Spectre.IntentDataset.Embed.run([inspect(@agent), source, output])
      end)

    assert text =~ "1 embedded, 1 reused"
    assert_receive {:batch_encoder_load, "test-v1"}
    assert_receive {:batch_encoder_embed, "price new"}
    refute_receive {:batch_encoder_embed, _}
    assert File.read!(source) == before
    [reused, prepared] = read_rows(output)
    assert reused["id"] == "existing"
    assert reused["embedding"] == [0.0, 1.0]
    assert reused["metadata"] == existing.metadata
    assert prepared["embedding"] == [1.0, 0.0]
    assert prepared["metadata"]["embedding_profile_ref"] == metadata["embedding_profile_ref"]
    assert {:ok, %{loaded: 2}} = IntentDataset.load_snapshot(@agent, output)

    assert {:ok, %{label: :pricing, strategy: :intent_similarity}} =
             IntentDataset.lookup("different price",
               agent: @agent,
               lookup: [exact: false, semantic: true]
             )

    assert_receive {:batch_encoder_embed, "different price"}
    refute File.exists?(Path.join(dir, "classifier.json"))
  end

  @tag :tmp_dir
  test "an entirely prepared artifact never loads or invokes the encoder", %{tmp_dir: dir} do
    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], @agent.__spectre_config__())

    source =
      write_source(dir, [
        %{
          text: "price saved",
          label: "pricing",
          verified: false,
          embedding: [1.0, 0.0],
          metadata: metadata
        }
      ])

    output = Path.join(dir, "prepared.jsonl")
    assert {:ok, %{embedded: 0, reused: 1}} = Embedding.prepare(@agent, source, output)
    assert [%{"verified" => false}] = read_rows(output)
    refute_receive {:batch_encoder_load, _}
    refute_receive {:batch_encoder_embed, _}
  end

  @tag :tmp_dir
  test "all labels are validated before encoding and an existing target stays intact", %{
    tmp_dir: dir
  } do
    source =
      write_source(dir, [
        %{text: "first price", label: "pricing"},
        %{text: "unknown price", label: "undeclared"}
      ])

    output = Path.join(dir, "existing.jsonl")
    File.write!(output, "previous artifact")

    assert {:error, {:intent_dataset_row, 2, {:unknown_label, "undeclared"}}} =
             Embedding.prepare(@agent, source, output)

    assert File.read!(output) == "previous artifact"
    refute_receive {:batch_encoder_load, _}
    refute_receive {:batch_encoder_embed, _}
  end

  @tag :tmp_dir
  test "mismatched and unidentifiable stored profiles fail before provider calls", %{tmp_dir: dir} do
    output = Path.join(dir, "prepared.jsonl")
    base = %{text: "stored price", label: "pricing", embedding: [1.0, 0.0]}
    missing = write_source(dir, [base])

    assert {:error, {:intent_dataset_row, 1, :semantic_cache_embedding_profile_missing}} =
             Embedding.prepare(@agent, missing, output)

    {:ok, metadata} = Index.bind_embedding_profile(%{}, [1.0, 0.0], @agent.__spectre_config__())

    source =
      write_source(dir, [
        Map.put(base, :metadata, Map.put(metadata, "embedding_profile_ref", "different-profile"))
      ])

    assert {:error, {:intent_dataset_row, 1, :semantic_cache_embedding_profile_mismatch}} =
             Embedding.prepare(@agent, source, output)

    refute File.exists?(output)
    refute_receive {:batch_encoder_load, _}
    refute_receive {:batch_encoder_embed, _}
  end

  @tag :tmp_dir
  test "encoding failures and incompatible new dimensions leave source and target untouched", %{
    tmp_dir: dir
  } do
    output = Path.join(dir, "prepared.jsonl")
    File.write!(output, "previous artifact")

    for {text, expected} <- [
          {"provider failure", :encoder_unavailable},
          {"wrong dimensions", {:embedding_dimension_mismatch, 3, 2}}
        ] do
      source = write_source(dir, [%{text: text, label: "pricing"}])
      before = File.read!(source)
      assert {:error, ^expected} = Embedding.prepare(@agent, source, output)
      assert File.read!(source) == before
      assert File.read!(output) == "previous artifact"
    end

    assert Path.wildcard(Path.join(dir, "*.tmp-*")) == []
  end

  @tag :tmp_dir
  test "the configured encoder_model belongs to profile identity", %{tmp_dir: dir} do
    previous = Application.get_env(:spectre, :classifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spectre, :classifier, previous),
        else: Application.delete_env(:spectre, :classifier)
    end)

    Application.put_env(:spectre, :classifier,
      embedding_adapter: Spectre.IntentDatasetEmbedTest.Encoder,
      encoder_model: "global-v1"
    )

    source = write_source(dir, [%{text: "price global", label: "pricing"}])
    output = Path.join(dir, "prepared.jsonl")

    assert {:ok, %{embedded: 1}} =
             Embedding.prepare(Spectre.IntentDatasetEmbedTest.GlobalAgent, source, output)

    assert_receive {:batch_encoder_load, "global-v1"}
    assert_receive {:batch_encoder_embed, "price global"}
    first = File.read!(output)

    Application.put_env(:spectre, :classifier,
      embedding_adapter: Spectre.IntentDatasetEmbedTest.Encoder,
      encoder_model: "global-v2"
    )

    assert {:error, {:intent_dataset_row, 1, :semantic_cache_embedding_profile_mismatch}} =
             Embedding.prepare(Spectre.IntentDatasetEmbedTest.GlobalAgent, output, output)

    assert File.read!(output) == first
    refute_receive {:batch_encoder_load, _}
    refute_receive {:batch_encoder_embed, _}
  end

  defp write_source(dir, rows) do
    path = Path.join(dir, "source.jsonl")
    File.write!(path, Enum.map_join(rows, "\n", &Spectre.JSON.encode!/1))
    path
  end

  defp read_rows(path),
    do:
      path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Spectre.JSON.decode!/1)
end
