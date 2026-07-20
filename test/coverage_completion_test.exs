defmodule SpectreCoverageCompletionTest.FastembedBackend do
  @moduledoc false

  def load("ready"), do: {:ok, 3}
  def load("already"), do: {:error, "model already loaded"}
  def load("string-error"), do: {:error, "model unavailable"}
  def load("term-error"), do: {:error, :model_unavailable}

  def embed_text(["dimension probe"]), do: {:ok, [[1, 0, 0]]}
  def embed_text(["empty"]), do: {:ok, []}
  def embed_text(["error"]), do: {:error, :embedding_failed}
  def embed_text([_text]), do: {:ok, [[1, 2.5, 0]]}
end

defmodule SpectreCoverageCompletionTest.TaskEmbedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  def download(_model, _opts), do: {:ok, 2}
  def load(_model, _opts), do: {:ok, 2}

  def embed(text, _opts) do
    if String.contains?(text, "alpha"), do: {:ok, [1.0, 0.0]}, else: {:ok, [0.0, 1.0]}
  end
end

defmodule SpectreCoverageCompletionTest.Agent do
  @moduledoc false
  use Spectre.Agent

  router(semantic_cache?: true, classification_log?: false)

  flow :coverage do
    on :ALPHA,
      regex: ~r/^alpha$/,
      embedding: ["alpha example"],
      bag: ["alpha bag"],
      learn: true,
      cache: true do
      reply(:alpha)
    end

    on :BETA,
      regex: ~r/^beta$/,
      embedding: ["beta example"],
      jaro: ["beta jaro"],
      learn: true,
      cache: true do
      reply(:beta)
    end

    on :NO_CACHE, regex: ~r/^private$/, learn: true, cache: false do
      reply(:private)
    end
  end
end

defmodule SpectreCoverageCompletionTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl true
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:coverage_journal, record})

    case Keyword.get(opts, :reply, :ok) do
      :raise -> raise "journal exploded"
      :throw -> throw(:journal_throw)
      :exit -> exit(:journal_exit)
      reply -> reply
    end
  end
end

defmodule SpectreCoverageCompletionTest.Redactor do
  @moduledoc false

  def record(record), do: %{record | input: nil, reply: nil}
  def map(record), do: Map.from_struct(record)
  def ok_map(record), do: {:ok, Map.from_struct(record)}
  def with_reason(record, reason), do: %{record | reason: %{code: reason}}
  def fail(_record), do: {:error, :redaction_denied}
  def invalid(_record), do: {:unexpected, :shape, :here}
  def explode(_record), do: raise("redactor exploded")
  def throw_reason(_record), do: throw(:redactor_throw)
  def invalid_atom(_record), do: :invalid
  def invalid_binary(_record), do: "invalid"
end

defmodule SpectreCoverageCompletionTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.Classifier.Dataset, as: DatasetTask
  alias Mix.Tasks.Spectre.Classifier.DownloadModel, as: DownloadModelTask
  alias Mix.Tasks.Spectre.Classifier.Train, as: TrainTask
  alias Spectre.Awaitable
  alias Spectre.Classifier
  alias Spectre.Classifier.Embeddings.ExFastembed
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Journal.Recorder
  alias Spectre.Result
  alias Spectre.Router.Context, as: RouterContext
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.State
  alias Spectre.State.Codec

  @agent SpectreCoverageCompletionTest.Agent

  setup do
    previous_classifier = Application.get_env(:spectre, :classifier)
    previous_journal = Application.get_env(:spectre, :journal)
    previous_semantic_cache = Application.get_env(:spectre, :semantic_cache)

    on_exit(fn ->
      restore_env(:classifier, previous_classifier)
      restore_env(:journal, previous_journal)
      restore_env(:semantic_cache, previous_semantic_cache)
      Learned.clear(@agent)
    end)

    Learned.clear(@agent)
    :ok
  end

  describe "production ExFastembed adapter" do
    test "executes the injected backend for every load and embed reply" do
      opts = [ex_fastembed_module: SpectreCoverageCompletionTest.FastembedBackend]

      assert {:ok, 3} = ExFastembed.download("ready", opts)
      assert {:ok, 3} = ExFastembed.load("already", opts)
      assert {:error, "model unavailable"} = ExFastembed.load("string-error", opts)
      assert {:error, :model_unavailable} = ExFastembed.load("term-error", opts)
      assert {:ok, vector} = ExFastembed.embed("value", opts)
      assert vector == [1.0, 2.5, 0.0]
      assert {:error, :empty_embedding} = ExFastembed.embed("empty", opts)
      assert {:error, :embedding_failed} = ExFastembed.embed("error", opts)
    end

    test "reports an unavailable backend as the optional dependency" do
      assert {:error, {:missing_dependency, :ex_fastembed}} =
               ExFastembed.load("ready",
                 ex_fastembed_module: SpectreCoverageCompletionTest.Missing
               )

      assert {:error, {:missing_dependency, :ex_fastembed}} =
               ExFastembed.embed("value",
                 ex_fastembed_module: SpectreCoverageCompletionTest.Missing
               )
    end
  end

  describe "classifier Mix tasks" do
    @tag :tmp_dir
    test "dataset, download, and train tasks execute successful local workflows", %{tmp_dir: tmp} do
      dataset = Path.join(tmp, "dataset.json")
      source = Path.join(tmp, "source.json")
      artifact = Path.join(tmp, "artifact")

      File.write!(
        source,
        Jason.encode!([
          %{text: "alpha training", label: "ALPHA"},
          %{text: "beta training", label: "BETA"}
        ])
      )

      Application.put_env(:spectre, :classifier,
        embedding_adapter: SpectreCoverageCompletionTest.TaskEmbedding,
        encoder_model: "coverage-model",
        artifact_dir: artifact,
        classification_log?: false
      )

      reenable("spectre.classifier.dataset")

      assert :ok =
               DatasetTask.run([
                 "SpectreCoverageCompletionTest.Agent",
                 dataset,
                 "--source",
                 source,
                 "--pretty"
               ])

      assert {:ok, rows} = dataset |> File.read!() |> Jason.decode()
      assert Enum.any?(rows, &(&1["label"] == "ALPHA"))

      reenable("spectre.classifier.download_model")

      assert :ok =
               DownloadModelTask.run([
                 "--model",
                 "coverage-model"
               ])

      reenable("spectre.classifier.train")

      assert :ok =
               TrainTask.run([
                 dataset,
                 artifact,
                 "--model",
                 "coverage-model",
                 "--accept-threshold",
                 "0.4",
                 "--margin-threshold",
                 "0.0",
                 "--high-confidence-threshold",
                 "0.8"
               ])

      assert File.exists?(Path.join(artifact, "classifier.etf"))
    end

    test "task parsers reject malformed CLI input" do
      for {task, argv} <- [
            {DatasetTask, ["--unknown"]},
            {DownloadModelTask, ["--unknown"]},
            {TrainTask, ["--unknown"]}
          ] do
        reenable(task_name(task))
        assert_raise Mix.Error, fn -> task.run(argv) end
      end

      reenable("spectre.classifier.dataset")

      assert_raise Mix.Error, ~r/expected an agent module/, fn ->
        DatasetTask.run([])
      end
    end
  end

  describe "strict state codec failure matrix" do
    test "rejects invalid top-level payloads and raises only through decode!" do
      for {payload, shape} <- [
            {nil, :atom},
            {[:not, :a, :map], :list},
            {{:tuple}, {:tuple, 1}},
            {self(), :pid}
          ] do
        assert {:error, {:invalid_state_payload, ^shape}} = Codec.decode(payload)
      end

      assert {:error, _reason} = Codec.decode("not-json")
      assert_raise ArgumentError, fn -> Codec.decode!("not-json") end
      assert {:error, {:invalid_state, :map}} = Codec.encode(%{revision: 0})
    end

    test "validates state collection shapes, limits, and revisions" do
      invalid_states = [
        {%State{revision: -1}, {:invalid_state_revision, -1}},
        {%State{pending_effects: :bad}, :invalid_effect_collections},
        {%State{planned_effects: :bad}, :invalid_effect_collections},
        {%State{awaitables: :bad}, :invalid_state_collections},
        {%State{memory_refs: :bad}, :invalid_state_collections},
        {%State{trace: :bad}, :invalid_state_collections},
        {%State{pending_effects: [%Effect{}, %Effect{}]},
         {:state_collection_too_large, :pending_effects, 2, 1}},
        {%State{planned_effects: List.duplicate(%Effect{}, 33)},
         {:state_collection_too_large, :planned_effects, 33, 32}},
        {%State{awaitables: List.duplicate(%Awaitable{}, 65)},
         {:state_collection_too_large, :awaitables, 65, 64}},
        {%State{memory_refs: List.duplicate(:x, 257)},
         {:state_collection_too_large, :memory_refs, 257, 256}},
        {%State{trace: List.duplicate(:x, 257)}, {:state_collection_too_large, :trace, 257, 256}}
      ]

      for {state, reason} <- invalid_states do
        assert {:error, ^reason} = Codec.encode(state)
      end
    end

    test "validates every effect and awaitable invariant during encoding" do
      base_effect = Effect.stage(%{name: :alpha})

      effects = [
        {%{base_effect | kind: :network}, {:invalid_effect_kind, :network}},
        {%{base_effect | status: :invented}, {:invalid_effect_status, :invented}},
        {%{base_effect | idempotency_key: nil}, :invalid_idempotency_key},
        {%{base_effect | owner: "owner"}, :invalid_effect_owner},
        {%{base_effect | scope: {:bad, :scope}}, {:invalid_effect_scope, {:bad, :scope}}},
        {%{base_effect | args: []}, :invalid_effect_args},
        {%{base_effect | payload: []}, :invalid_effect_payload},
        {%{base_effect | metadata: []}, :invalid_effect_metadata}
      ]

      for {effect, reason} <- effects do
        assert {:error, ^reason} = Codec.encode(%State{pending_effects: [effect]})
      end

      assert {:error, {:invalid_effect, :atom}} =
               Codec.encode(%State{pending_effects: [:not_an_effect]})

      awaitable = Awaitable.open_policy(:confirm, base_effect)

      awaitables = [
        {%{awaitable | kind: :timer}, {:invalid_awaitable_kind, :timer}},
        {%{awaitable | status: :invented}, {:invalid_awaitable_status, :invented}},
        {%{awaitable | attempts: -1}, {:invalid_awaitable_attempts, -1}},
        {%{awaitable | metadata: []}, :invalid_awaitable_metadata}
      ]

      for {value, reason} <- awaitables do
        assert {:error, ^reason} = Codec.encode(%State{awaitables: [value]})
      end

      assert {:error, {:invalid_awaitable, :binary}} =
               Codec.encode(%State{awaitables: ["not-an-awaitable"]})
    end

    test "rejects malformed schema fields, enums, collections, and tagged values" do
      {:ok, empty} = Codec.encode(%State{})
      {:ok, effect_state} = Codec.encode(%State{pending_effects: [Effect.stage(%{name: :a})]})

      {:ok, awaitable_state} =
        Codec.encode(%State{awaitables: [Awaitable.open_policy(:confirm, "effect-id")]})

      effect = hd(effect_state["pending_effects"])
      awaitable = hd(awaitable_state["awaitables"])

      invalid = [
        Map.put(empty, "state_version", 99),
        Map.put(empty, "revision", -1),
        Map.put(empty, "revision", "one"),
        Map.delete(empty, "state_version"),
        Map.put(empty, "pending_effects", %{}),
        Map.put(empty, "data", []),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "kind", "network")]),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "status", "invented")]),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "mode", "invented")]),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "owner", "owner")]),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "scope", "bad")]),
        Map.put(effect_state, "pending_effects", [Map.put(effect, "args", [])]),
        Map.put(effect_state, "pending_effects", [:bad]),
        Map.put(awaitable_state, "awaitables", [Map.put(awaitable, "kind", "timer")]),
        Map.put(awaitable_state, "awaitables", [Map.put(awaitable, "status", "invented")]),
        Map.put(awaitable_state, "awaitables", [Map.put(awaitable, "attempts", -1)]),
        Map.put(awaitable_state, "awaitables", [Map.put(awaitable, "max_attempts", 0)]),
        Map.put(awaitable_state, "awaitables", [:bad])
      ]

      assert Enum.all?(invalid, &match?({:error, _reason}, Codec.decode(&1)))

      tagged_values = [
        %{"$spectre" => "atom", "value" => "atom_that_does_not_exist_coverage"},
        %{"$spectre" => "datetime", "value" => "not-a-date"},
        %{"$spectre" => "tuple", "values" => [%{"$spectre" => "unknown"}]},
        %{"$spectre" => "map", "entries" => [["only-key"]]},
        %{"$spectre" => "map", "entries" => [["key", %{"$spectre" => "unknown"}]]},
        %{"$spectre" => "struct", "module" => "Elixir.Unknown.Coverage", "fields" => %{}},
        %{"$spectre" => "struct", "module" => "Elixir.URI", "fields" => "bad"},
        %{"$spectre" => "unknown"}
      ]

      for tagged <- tagged_values do
        assert {:error, _reason} = Codec.decode(Map.put(empty, "data", tagged))
      end
    end

    test "round trips supported nested values and rejects unsafe runtime terms" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      state = %State{
        data: %{
          atom: :alpha,
          datetime: now,
          tuple: {:ok, 1},
          struct: URI.parse("https://example.test/path"),
          list: [1, "two", false]
        }
      }

      assert {:ok, encoded} = Codec.encode(state)
      assert {:ok, ^state} = Codec.decode(encoded)

      for unsafe <- [self(), make_ref(), fn -> :ok end] do
        assert {:error, {:unsupported_state_value, _shape}} =
                 Codec.encode(%State{data: %{x: unsafe}})
      end
    end
  end

  describe "classifier artifact and server matrix" do
    @tag :tmp_dir
    test "classifies centroid and example artifacts through all scoring modes", %{tmp_dir: tmp} do
      centroid = classifier_artifact(:centroid_head)
      write_classifier(tmp, centroid)

      assert {:ok, route} =
               Classifier.classify_once("alpha",
                 artifact_dir: tmp,
                 load_embedding: fn _model, _opts -> {:ok, 2} end,
                 embed: fn _text, _opts -> {:ok, [1.0, 0.0]} end,
                 classification_log?: true,
                 classification_log_input?: true,
                 local_top_k: 1
               )

      assert route.label == "ALPHA"
      assert route.accepted?

      write_classifier(tmp, classifier_artifact(:example_index))

      for score_mode <- [:max, :mean] do
        assert {:ok, route} =
                 Classifier.classify_once("alpha",
                   artifact_dir: tmp,
                   load_embedding: fn _model -> {:ok, 2} end,
                   embed: fn _text -> {:ok, [1.0, 0.0]} end,
                   classification_log?: true,
                   classification_log_input?: false,
                   local_example_score: score_mode,
                   local_example_top_k: :invalid
                 )

        assert route.label == "ALPHA"
      end
    end

    @tag :tmp_dir
    test "rejects every classifier schema and vector corruption", %{tmp_dir: tmp} do
      base = classifier_artifact(:centroid_head)

      corruptions = [
        :not_a_map,
        "not-a-map",
        ["not-a-map"],
        {:not, :a_map},
        Map.put(base, :kind, :unknown),
        Map.put(base, :version, 2),
        Map.put(base, :dimensions, 0),
        Map.put(base, :labels, []),
        Map.put(base, :labels, ["ALPHA", "ALPHA"]),
        Map.put(base, :labels, ["ALPHA", ""]),
        Map.put(base, :accept_threshold, -0.1),
        Map.put(base, :margin_threshold, 1.1),
        Map.put(base, :high_confidence_threshold, :invalid),
        Map.put(base, :centroids, []),
        Map.put(base, :centroids, %{"ALPHA" => [1.0, 0.0]}),
        put_in(base, [:centroids, "ALPHA"], [1.0]),
        put_in(base, [:centroids, "ALPHA"], [1.0, :invalid]),
        classifier_artifact(:example_index) |> Map.put(:examples, []),
        classifier_artifact(:example_index) |> Map.put(:examples, [:invalid]),
        classifier_artifact(:example_index)
        |> put_in([:examples, Access.at(0), :label], "UNKNOWN"),
        classifier_artifact(:example_index)
        |> put_in([:examples, Access.at(0), :id], nil),
        classifier_artifact(:example_index)
        |> put_in([:examples, Access.at(0), :vector], [1.0])
      ]

      for artifact <- corruptions do
        write_classifier(tmp, artifact)

        assert {:error, _reason} =
                 Classifier.classify_once("alpha",
                   artifact_dir: tmp,
                   load_embedding: fn _model, _opts -> {:ok, 2} end,
                   embed: fn _text, _opts -> {:ok, [1.0, 0.0]} end
                 )
      end

      write_classifier(tmp, base)

      assert {:error, {:classifier_dimension_mismatch, 2, 3}} =
               Classifier.classify_once("alpha",
                 artifact_dir: tmp,
                 load_embedding: fn _model, _opts -> {:ok, 3} end
               )
    end

    @tag :tmp_dir
    test "runs ready and unavailable GenServer modes", %{tmp_dir: tmp} do
      write_classifier(tmp, classifier_artifact(:centroid_head))
      ready_name = SpectreCoverageCompletionTest.ReadyClassifier

      ready =
        start_supervised!(
          {Classifier,
           artifact_dir: tmp,
           name: ready_name,
           load_embedding: fn _model, _opts -> {:ok, 2} end,
           embed: fn _text, _opts -> {:ok, [1.0, 0.0]} end,
           classification_log?: false}
        )

      assert Process.alive?(ready)

      assert {:ok, %{label: "ALPHA"}} =
               Classifier.classify("alpha",
                 name: ready_name,
                 embed: fn _text, _opts -> {:ok, [1.0, 0.0]} end
               )

      assert :ok = stop_supervised(Classifier)

      unavailable_name = SpectreCoverageCompletionTest.UnavailableClassifier

      unavailable =
        start_supervised!(
          {Classifier,
           artifact_dir: Path.join(tmp, "missing"), name: unavailable_name, required?: false}
        )

      assert Process.alive?(unavailable)
      assert {:error, :enoent} = Classifier.classify("alpha", name: unavailable_name)

      previous_trap = Process.flag(:trap_exit, true)

      assert {:error, :enoent} =
               Classifier.start_link(
                 artifact_dir: Path.join(tmp, "required-missing"),
                 name: SpectreCoverageCompletionTest.RequiredClassifier,
                 required?: true
               )

      Process.flag(:trap_exit, previous_trap)
    end
  end

  describe "learned semantic cache review and failure matrix" do
    test "covers public validation, cacheability, and Route conversion" do
      opts = learned_opts()

      assert {:error, {:invalid_semantic_cache_result, :bad}} = Learned.put("alpha", :bad, opts)
      assert {:error, :blank_text} = Learned.put("   ", %{label: :ALPHA}, opts)

      assert {:error, {:unknown_label, :UNKNOWN}} =
               Learned.put("unknown", %{label: :UNKNOWN}, opts)

      assert {:error, {:uncacheable_label, :NO_CACHE}} =
               Learned.put("private", %{label: :NO_CACHE}, opts)

      route = Spectre.Route.new(%{label: :ALPHA, strategy: :llm_classifier, accepted?: true})
      assert {:ok, row} = Learned.put("alpha route", route, opts)
      assert row.label == :ALPHA
      row_id = row.id

      assert {:error, {:invalid_agent, "agent"}} = Learned.examples("agent")
      assert {:error, {:invalid_example_lookup, @agent, :bad}} = Learned.get_example(@agent, :bad)

      assert {:error, {:invalid_relabel, @agent, ^row_id, "BETA"}} =
               Learned.relabel(@agent, row_id, "BETA")

      assert {:error, {:invalid_delete, @agent, :bad}} = Learned.delete(@agent, :bad)
      assert {:error, {:invalid_verify, @agent, :bad}} = Learned.verify(@agent, :bad)
      assert {:error, {:invalid_agent, "agent"}} = Learned.snapshot("agent")

      assert {:error, {:invalid_semantic_cache_source, :invented}} =
               Learned.examples(@agent, source: :invented)
    end

    @tag :tmp_dir
    test "reviews all sources and handles snapshot success and corruption", %{tmp_dir: tmp} do
      opts = learned_opts()
      assert {:ok, row} = Learned.put("alpha online", %{label: :ALPHA, confidence: 0.7}, opts)
      assert {:ok, ^row} = Learned.get_example(@agent, row.id)
      assert {:error, :not_found} = Learned.get_example(@agent, "missing")

      assert {:ok, static} = Learned.examples(@agent, source: :static_route_example)
      assert Enum.any?(static, &(&1.source == :static_route_example))
      assert {:ok, all} = Learned.examples(@agent, source: :all)
      assert length(all) > length(static)

      assert {:ok, rows} = Learned.snapshot(@agent)
      assert [%{id: id}] = rows
      assert id == row.id
      assert {:error, {:invalid_snapshot_path, 123}} = Learned.snapshot(@agent, path: 123)

      path = Path.join(tmp, "snapshot.jsonl")
      assert {:ok, ^path} = Learned.snapshot(@agent, path: path)
      assert :ok = Learned.clear(@agent)

      assert {:ok, %{loaded: 1, skipped: 0}} = Learned.load_snapshot(@agent, path)

      assert {:ok, %{loaded: 0, skipped: 1}} =
               Learned.load_snapshot(@agent, [%{"text" => "", "label" => "ALPHA"}])

      assert {:ok, %{loaded: 0, skipped: 1}} =
               Learned.load_snapshot(@agent, [%{"text" => "x", "label" => "UNKNOWN"}])

      assert {:ok, %{loaded: 0, skipped: 1}} = Learned.load_snapshot(@agent, [:bad])
      assert {:error, {:invalid_snapshot, 123}} = Learned.load_snapshot(@agent, 123)
      assert {:error, :missing_snapshot} = Learned.load_snapshot(@agent, [])

      corrupt = Path.join(tmp, "corrupt.jsonl")
      File.write!(corrupt, "{not-json}\n")

      assert {:error, {:invalid_snapshot, %{loaded: 0, skipped: 1}}} =
               Learned.load_snapshot(@agent, corrupt, strict?: true)
    end

    @tag :tmp_dir
    test "parses JSON and JSONL sources and reports source failures", %{tmp_dir: tmp} do
      json = Path.join(tmp, "rows.json")
      jsonl = Path.join(tmp, "rows.jsonl")
      unsupported = Path.join(tmp, "rows.txt")

      File.write!(json, Jason.encode!([%{text: "alpha json", label: "ALPHA"}]))
      File.write!(unsupported, "unsupported")

      File.write!(
        jsonl,
        "# comment\n" <>
          Jason.encode!(%{text: "beta jsonl", intent: "BETA"}) <> "\n{bad-json}\n"
      )

      assert {:ok, json_rows} =
               Learned.examples(@agent, source: :offline_dataset, semantic_cache_source: json)

      assert Enum.any?(json_rows, &(&1.text == "alpha json"))

      assert {:error, _reason} =
               Learned.examples(@agent, source: :offline_dataset, semantic_cache_source: jsonl)

      assert {:error, {:unsupported_semantic_cache_source, ^unsupported}} =
               Learned.examples(@agent,
                 source: :offline_dataset,
                 semantic_cache_source: unsupported
               )

      missing = Path.join(tmp, "missing.json")

      assert {:error, {:missing_semantic_cache_source, ^missing}} =
               Learned.examples(@agent,
                 source: :offline_dataset,
                 semantic_cache_source: missing
               )
    end

    test "contains embedding exceptions, exits, throws, and invalid adapters" do
      base = Keyword.merge(learned_opts(), semantic_search?: true, semantic_cache_threshold: 0.0)

      failures = [
        {fn _text -> raise "embedding boom" end, :embedding_exception},
        {fn _text -> exit(:embedding_exit) end, :embedding_exit},
        {fn _text -> throw(:embedding_throw) end, :embedding_failure},
        {123, :invalid_embedding_adapter}
      ]

      for {embedding, code} <- failures do
        assert {:error, reason} =
                 Learned.lookup("query", Keyword.put(base, :embedding, embedding))

        assert reason_code(reason) == code
      end

      assert {:error, :empty_learned_semantic_cache} =
               Learned.lookup(
                 "query",
                 Keyword.merge(base,
                   embedding: fn _text -> {:error, :cannot_embed} end,
                   semantic_cache_static?: false
                 )
               )
    end

    test "search builds and reuses a real Vettore index and enforces thresholds" do
      embedding = fn text, _opts ->
        if String.contains?(text, "beta"), do: {:ok, [0.0, 1.0]}, else: {:ok, [1.0, 0.0]}
      end

      opts =
        Keyword.merge(learned_opts(),
          semantic_search?: true,
          semantic_cache_threshold: 0.0,
          semantic_cache_top_k: :invalid,
          semantic_cache_capacity: :invalid,
          embedding: embedding
        )

      assert {:ok, %{label: :ALPHA, strategy: :semantic_cache_search}} =
               Learned.lookup("alpha query", opts)

      # The second lookup must use the already cached Vettore collection.
      assert {:ok, %{label: :ALPHA}} = Learned.lookup("alpha query again", opts)

      assert {:error, :below_threshold} =
               Learned.lookup("alpha query", Keyword.put(opts, :semantic_cache_threshold, 1.1))

      assert {:error, :cannot_embed_row} =
               Learned.lookup(
                 "query",
                 Keyword.put(opts, :embedding, fn _text, _opts -> {:error, :cannot_embed_row} end)
               )
    end

    test "online rows update by normalized text and mutation honors changed rule visibility" do
      opts = learned_opts()

      assert {:error, {:missing_spectre_agent, nil}} =
               Learned.put("alpha", %{label: :ALPHA}, Keyword.delete(opts, :spectre_agent))

      assert {:ok, first} =
               Learned.put(
                 "  repeated alpha  ",
                 %{"intent" => "alpha", "id" => "fixed-id", metadata: :invalid, confidence: 0},
                 Keyword.put(opts, :semantic_learn_confidence, 0.44)
               )

      assert first.id == "fixed-id"
      assert first.confidence == 0.44
      assert first.metadata.agent == @agent

      assert {:ok, second} =
               Learned.put("REPEATED ALPHA", %{label: :ALPHA, confidence: 0.9}, opts)

      assert second.id == first.id
      assert second.inserted_at == first.inserted_at
      assert Learned.online_revision(@agent) >= 2

      hidden_opts = Keyword.put(opts, :spectre_rules, [])

      assert {:error, {:unknown_label, :ALPHA}} =
               Learned.verify(@agent, first.id, hidden_opts)

      assert {:ok, verified} = Learned.verify(@agent, first.id, opts)
      assert verified.verified?
      assert :ok = Learned.delete(@agent, first.id, opts)
      assert {:error, :not_found} = Learned.delete(@agent, first.id, opts)
    end

    test "static examples are read-only for relabel, verify and delete" do
      assert {:ok, [static | _]} = Learned.examples(@agent, source: :static_route_example)

      assert {:error, :read_only_example} = Learned.relabel(@agent, static.id, :BETA)
      assert {:error, :read_only_example} = Learned.verify(@agent, static.id)
      assert {:error, :read_only_example} = Learned.delete(@agent, static.id)

      assert {:error, {:invalid_agent, SpectreCoverageCompletionTest}} =
               Learned.examples(SpectreCoverageCompletionTest)
    end

    @tag :tmp_dir
    test "snapshot decoding normalizes optional types and all input envelopes", %{tmp_dir: tmp} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries = [
        %{
          text: "alpha rich",
          label: :ALPHA,
          source_strategy: :regex,
          confidence: 0,
          metadata: %{nested: %{atom: :value}, list: [:one, now]},
          inserted_at: now,
          updated_at: "invalid-time"
        },
        %{
          "text" => "beta rich",
          "label" => "BETA",
          "source_strategy" => "atom_that_does_not_exist_for_snapshot",
          "metadata" => :invalid,
          "inserted_at" => 123,
          "updated_at" => DateTime.to_iso8601(now)
        },
        %{"text" => "alpha blank strategy", "label" => "ALPHA", "source_strategy" => ""},
        %{"label" => "ALPHA"}
      ]

      assert {:ok, %{loaded: 3, skipped: 1}} =
               Learned.load_snapshot(@agent, rows: entries)

      assert {:ok, rows} = Learned.snapshot(@agent)
      assert Enum.any?(rows, &(&1.text == "alpha rich"))

      path = Path.join(tmp, "rows.jsonl")
      File.write!(path, Jason.encode!(%{text: "alpha opts", label: "ALPHA"}) <> "\n")
      assert {:ok, %{loaded: 1}} = Learned.load_snapshot(@agent, path: path)

      missing = Path.join(tmp, "missing.jsonl")
      assert {:error, :enoent} = Learned.load_snapshot(@agent, missing)

      # Renaming a temporary snapshot onto an existing directory fails and
      # exercises cleanup of the temporary file.
      assert {:error, _reason} = Learned.snapshot(@agent, path: tmp)
      assert [] == Path.wildcard(tmp <> ".tmp-*")
    end

    @tag :tmp_dir
    test "offline datasets skip malformed rows and reject invalid JSON containers", %{
      tmp_dir: tmp
    } do
      json = Path.join(tmp, "object.json")
      valid = Path.join(tmp, "mixed.json")

      File.write!(json, Jason.encode!(%{text: "not a list", label: "ALPHA"}))

      File.write!(
        valid,
        Jason.encode!([123, %{text: "", label: "ALPHA"}, %{text: "alpha", label: ""}])
      )

      assert {:error, {:invalid_learning_json, ^json}} =
               Learned.examples(@agent, source: :offline_dataset, semantic_cache_source: json)

      assert {:ok, [%{text: "", label: :ALPHA}]} =
               Learned.examples(@agent, source: :offline_dataset, semantic_cache_source: valid)
    end
  end

  describe "journal validation and failure matrix" do
    test "rejects every invalid configuration dimension" do
      invalid = [
        true,
        [],
        {SpectreCoverageCompletionTest.JournalStore, [mode: :invalid]},
        {SpectreCoverageCompletionTest.JournalStore, [mode: :async, on_error: :error]},
        {SpectreCoverageCompletionTest.JournalStore, [mode: :sync, on_error: :invalid]},
        {SpectreCoverageCompletionTest.JournalStore, [sample_rate: -0.1]},
        {SpectreCoverageCompletionTest.JournalStore, [sample_rates: :invalid]},
        {SpectreCoverageCompletionTest.JournalStore, [sample_rates: %{"routing" => 1.0}]},
        {SpectreCoverageCompletionTest.JournalStore, [sample_rates: %{routing: 2.0}]},
        {SpectreCoverageCompletionTest.JournalStore, [buffer_size: 0]},
        {SpectreCoverageCompletionTest.JournalStore, [overflow: :invalid]}
      ]

      for journal <- invalid do
        assert {:error, {:invalid_journal_configuration, _reason}} =
                 Recorder.record_routing(routing_context(journal))
      end
    end

    test "covers disabled, sampled, sync append, and error policies" do
      context = routing_context(false)
      assert {:ok, ^context} = Recorder.record_routing(context)

      sampled = journal(sample_rate: 0.0, store_opts: [pid: self()])
      assert {:ok, _context} = Recorder.record_routing(routing_context(sampled))
      refute_receive {:coverage_journal, _record}

      success = journal(mode: :sync, store_opts: [pid: self(), reply: {:ok, :stored}])
      assert {:ok, _context} = Recorder.record_routing(routing_context(success))
      assert_receive {:coverage_journal, _record}

      for policy <- [:warn, :ignore, :error] do
        failing = journal(mode: :sync, on_error: policy, store_opts: [reply: {:error, :down}])
        reply = Recorder.record_routing(routing_context(failing))

        if policy == :error,
          do: assert(match?({:error, {:journal_append_failed, :down}}, reply)),
          else: assert(match?({:ok, %RouterContext{}}, reply))
      end
    end

    test "normalizes redactors and contains all redactor failures" do
      success_redactors = [
        &SpectreCoverageCompletionTest.Redactor.record/1,
        {SpectreCoverageCompletionTest.Redactor, :record},
        {SpectreCoverageCompletionTest.Redactor, :with_reason, [:scrubbed]}
      ]

      for redactor <- success_redactors do
        config = journal(mode: :sync, redact: redactor, store_opts: [pid: self()])
        assert {:ok, _context} = Recorder.record_routing(routing_context(config))
        assert_receive {:coverage_journal, %Spectre.Journal.Record{}}
      end

      failing_redactors = [
        {SpectreCoverageCompletionTest.Redactor, :fail},
        {SpectreCoverageCompletionTest.Redactor, :invalid},
        {SpectreCoverageCompletionTest.Redactor, :explode},
        {SpectreCoverageCompletionTest.Redactor, :throw_reason},
        :invalid
      ]

      for redactor <- failing_redactors do
        config = journal(mode: :sync, on_error: :error, redact: redactor)

        assert {:error, {:journal_append_failed, {:journal_redaction_failed, _reason}}} =
                 Recorder.record_routing(routing_context(config))
      end
    end

    test "records routing, lifecycle, policy, execution, and persistence shapes" do
      config =
        journal(
          mode: :sync,
          events: :all,
          include_input: true,
          include_reply: true,
          retention: [days: 7],
          sample_rates: [policy: 1.0, execution: 1.0],
          store_opts: [pid: self()]
        )

      route = Spectre.Route.new(%{label: :ALPHA, strategy: :regex, accepted?: true})

      routing =
        config
        |> routing_context()
        |> Map.put(:route, route)
        |> Map.put(:traces, [{:llm_arbitrated, route}, {:clarify, "which?"}])

      assert {:ok, _context} = Recorder.record_routing(routing)
      assert_receive {:coverage_journal, %{phase: :arbitration, input: %{text: "secret"}}}

      effect = Effect.stage(%{name: :alpha})

      events = [
        %{type: :awaitable_opened, name: :confirm, kind: :accept, label: :yes},
        %{type: :effect_completed, effect_id: effect.id, effect: Effect.complete(effect, :ok)},
        %{type: :custom_lifecycle, reason: {:custom, :reason}}
      ]

      result = %Result{
        input: Input.new("runtime secret"),
        reply_text: "runtime reply",
        state: %State{conversation_id: "conversation", revision: 2},
        events: events,
        metadata: %{state_persistence: %{status: :committed, mode: :sync, revision: 2}}
      }

      runtime_context = %{
        agent: @agent,
        opts: [journal: config, turn_id: "turn", trace_id: "trace"]
      }

      assert {:ok, ^result} = Recorder.record_result(result, runtime_context)

      for phase <- [:policy, :execution, :lifecycle] do
        assert_receive {:coverage_journal, %{phase: ^phase}}
      end

      assert {:ok, ^result} = Recorder.record_persistence(result, runtime_context)
      assert_receive {:coverage_journal, %{phase: :persistence}}
    end

    test "contains journal adapter exception, throw, exit, and invalid replies" do
      for reply <- [:raise, :throw, :exit, :invalid_reply] do
        config = journal(mode: :sync, on_error: :error, store_opts: [reply: reply])

        assert {:error, {:journal_append_failed, _reason}} =
                 Recorder.record_routing(routing_context(config))
      end
    end

    test "accepts atom and keyword store configurations and records routing edge reasons" do
      assert {:ok, _context} =
               Recorder.record_routing(
                 routing_context(SpectreCoverageCompletionTest.JournalStore)
               )

      configurations = [
        [
          store: SpectreCoverageCompletionTest.JournalStore,
          mode: :sync,
          include_input: true,
          retention: %{days: 7},
          store_opts: [pid: self()]
        ],
        [
          store: SpectreCoverageCompletionTest.JournalStore,
          mode: :sync,
          retention: [days: 3],
          store_opts: [pid: self()]
        ],
        [
          store: SpectreCoverageCompletionTest.JournalStore,
          mode: :sync,
          retention: :forever,
          store_opts: [pid: self()]
        ]
      ]

      contexts = [
        %{
          routing_context(Enum.at(configurations, 0))
          | host_context: nil,
            route: nil,
            traces: [{:llm_arbitration_failed, {:timeout, :private}}],
            errors: ["opaque", {"not_atom", :private}]
        },
        %{
          routing_context(Enum.at(configurations, 1))
          | traces: [{:llm_arbitration_skipped, :disabled}],
            host_context: %{state: :invalid}
        },
        %{
          routing_context(Enum.at(configurations, 2))
          | traces: [{:clarify, "question"}]
        }
      ]

      Enum.each(contexts, fn context ->
        assert {:ok, ^context} = Recorder.record_routing(context)
        assert_receive {:coverage_journal, %Spectre.Journal.Record{phase: :arbitration}}
      end)

      disabled = %{
        routing_context(journal(mode: :sync))
        | opts: [journal: journal(events: [:policy])]
      }

      assert {:ok, ^disabled} = Recorder.record_routing(disabled)
    end

    test "runtime records filter invalid events and summarize policy, lifecycle, and effects" do
      config =
        journal(
          mode: :sync,
          events: :all,
          include_input: true,
          include_reply: true,
          retention: :short,
          sample_rates: [policy: 1.0, execution: 1.0, lifecycle: 1.0],
          store_opts: [pid: self()]
        )

      effect = Effect.complete(Effect.stage(%{name: :perform}), {:ok, %{safe: true}})

      result = %Result{
        input: Input.new("visible"),
        reply_text: "reply",
        state: %State{conversation_id: "conversation", revision: 3},
        events: [
          :invalid_event,
          %{
            type: :policy_resolved,
            name: :confirm,
            kind: :policy,
            label: :accepted,
            source: :input
          },
          %{
            type: :effect_completed,
            effect_id: effect.id,
            kind: :action,
            name: :perform,
            effect: effect
          },
          %{type: :custom_lifecycle, subject_id: "subject", reason: "opaque"}
        ]
      }

      context = %{agent: @agent, opts: [journal: config]}
      assert {:ok, ^result} = Recorder.record_result(result, context)
      assert_receive {:coverage_journal, %{phase: :policy, policy: %{name: :confirm}}}
      assert_receive {:coverage_journal, %{phase: :execution, effect: %{name: :perform}}}

      assert_receive {:coverage_journal,
                      %{phase: :lifecycle, transition: %{entity_id: "subject"}}}

      bad_context = %{context | opts: [journal: true]}

      assert {:error, {:invalid_journal_configuration, true}} =
               Recorder.record_result(result, bad_context)

      assert {:error, {:invalid_journal_configuration, true}} =
               Recorder.record_persistence(result, bad_context)
    end

    test "redactor accepts maps and wrapped maps and identifies scalar reply shapes" do
      for redactor <- [
            {SpectreCoverageCompletionTest.Redactor, :map},
            {SpectreCoverageCompletionTest.Redactor, :ok_map}
          ] do
        config = journal(mode: :sync, redact: redactor, store_opts: [pid: self()])
        assert {:ok, _context} = Recorder.record_routing(routing_context(config))
        assert_receive {:coverage_journal, %Spectre.Journal.Record{}}
      end

      for function <- [:invalid_atom, :invalid_binary] do
        config =
          journal(
            mode: :sync,
            on_error: :error,
            redact: {SpectreCoverageCompletionTest.Redactor, function}
          )

        assert {:error, {:journal_append_failed, {:journal_redaction_failed, _}}} =
                 Recorder.record_routing(routing_context(config))
      end
    end
  end

  defp learned_opts do
    [
      spectre_agent: @agent,
      spectre_rules: Enum.map(@agent.__spectre_rules__(), &Spectre.Rule.new/1),
      semantic_cache_static?: true,
      mirror_training_dataset?: false,
      embedding: {SpectreCoverageCompletionTest.TaskEmbedding, []}
    ]
  end

  defp classifier_artifact(:centroid_head) do
    %{
      version: 1,
      kind: :centroid_head,
      encoder_model: "coverage-model",
      dimensions: 2,
      labels: ["ALPHA", "BETA"],
      centroids: %{"ALPHA" => [1.0, 0.0], "BETA" => [0.0, 1.0]},
      accept_threshold: 0.5,
      margin_threshold: 0.0,
      high_confidence_threshold: 0.9
    }
  end

  defp classifier_artifact(:example_index) do
    %{
      version: 1,
      kind: :example_index,
      encoder_model: "coverage-model",
      dimensions: 2,
      labels: ["ALPHA", "BETA"],
      examples: [
        %{id: "alpha-1", label: "ALPHA", vector: [1.0, 0.0]},
        %{id: "alpha-2", label: :ALPHA, vector: [0.9, 0.1]},
        %{id: "beta-1", label: "BETA", vector: [0.0, 1.0]}
      ],
      centroids: %{},
      accept_threshold: 0.5,
      margin_threshold: 0.0,
      high_confidence_threshold: 0.9
    }
  end

  defp write_classifier(dir, artifact) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "classifier.etf"), :erlang.term_to_binary(artifact))
  end

  defp routing_context(journal) do
    %RouterContext{
      input: Input.new(%{text: "secret", meta: %{conversation_id: "from-meta"}}),
      host_context: %{state: %State{conversation_id: "conversation", revision: 1}},
      opts: [journal: journal, spectre_agent: @agent, turn_id: "turn", trace_id: "trace"],
      labels: [:ALPHA],
      rules: [],
      candidates: [],
      traces: [],
      errors: []
    }
  end

  defp journal(opts) do
    {SpectreCoverageCompletionTest.JournalStore, opts}
  end

  defp reason_code(reason) when is_tuple(reason), do: elem(reason, 0)
  defp reason_code(reason), do: reason

  defp reenable(task), do: Mix.Task.reenable(task)

  defp task_name(Mix.Tasks.Spectre.Classifier.Dataset), do: "spectre.classifier.dataset"

  defp task_name(Mix.Tasks.Spectre.Classifier.DownloadModel),
    do: "spectre.classifier.download_model"

  defp task_name(Mix.Tasks.Spectre.Classifier.Train), do: "spectre.classifier.train"

  defp restore_env(key, nil), do: Application.delete_env(:spectre, key)
  defp restore_env(key, value), do: Application.put_env(:spectre, key, value)
end
