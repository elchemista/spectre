defmodule Spectre.ServerRoutingReviewTest.EncoderDown do
  def embed(_text, _opts), do: {:error, :encoder_down}
end

defmodule Spectre.ServerRoutingReviewTest.LocalDown do
  def classify(_text, _opts), do: {:error, :local_down}
end

defmodule Spectre.ServerRoutingReviewTest.IntentModel do
  def complete(_prompt, _opts), do: {:ok, "pricing"}
end

defmodule Spectre.ServerRoutingReviewTest.Dataset do
  def lookup(_text, opts) do
    if pid = opts[:test_pid], do: send(pid, {:dataset_phase, opts[:semantic_search?]})

    {:ok,
     %{
       label: :pricing,
       accepted?: true,
       confidence: 1.0,
       margin: 1.0,
       strategy:
         if(opts[:semantic_search?], do: :semantic_cache_search, else: :semantic_cache_exact)
     }}
  end
end

defmodule Spectre.ServerRoutingReviewTest.DatasetDown do
  def lookup(_text, _opts), do: {:error, :dataset_unavailable}
end

defmodule Spectre.ServerRoutingReviewTest.ClarifyAfterLLM do
  @behaviour Spectre.Router.Arbitrator
  def decide(arbitration, _opts) do
    if Enum.any?(arbitration.candidates, &(&1.provider == :llm_classifier)),
      do: {:clarify, "Please clarify the request"},
      else: {:llm, arbitration}
  end
end

defmodule Spectre.ServerRoutingReviewTest.UnavailablePipeline do
  def call(context),
    do: {:ok, Spectre.Router.Context.put_error(context, {:error, :custom_pipeline_unavailable})}
end

defmodule Spectre.ServerRoutingReviewTest.Skill do
  use Spectre.Skill

  flow :billing do
    on(:invoice)
  end
end

defmodule Spectre.ServerRoutingReviewTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Spectre.Server.Router

  test "encoder and dataset failures retain causes when recognition is unavailable" do
    embedding =
      agent("""
      embedding Spectre.ServerRoutingReviewTest.EncoderDown
      router strategies: [:embedding], log_decisions: false
      flow :support do
        on :pricing, semantic_examples: ["price"]
      end
      """)

    assert {:unmatched, %{reason: {:classifier_error, :encoder_down}}} =
             Router.route(embedding, "how much?")

    dataset =
      agent("""
      intent_dataset Spectre.ServerRoutingReviewTest.DatasetDown
      router strategies: [:intent_dataset], log_decisions: false
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: {:classifier_error, :dataset_unavailable}}} =
             Router.route(dataset, "price")

    custom =
      agent("""
      router pipeline: Spectre.ServerRoutingReviewTest.UnavailablePipeline
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: {:classifier_error, :custom_pipeline_unavailable}}} =
             Router.route(custom, "price")
  end

  test "optional source failures do not override a working LLM or its clarification" do
    working =
      agent("""
      intent_dataset Spectre.ServerRoutingReviewTest.DatasetDown
      classifier :llm, Spectre.ServerRoutingReviewTest.IntentModel
      router strategies: [:intent_dataset, :llm_classifier], log_decisions: false
      flow :support do
        on :pricing
      end
      """)

    assert {:ok, {:support, :pricing}, _metadata} = Router.route(working, "price")

    clarify =
      agent("""
      classifier :local, Spectre.ServerRoutingReviewTest.LocalDown
      classifier :llm, Spectre.ServerRoutingReviewTest.IntentModel
      router strategies: [:local_classifier, :llm_classifier], log_decisions: false,
        arbitrator: Spectre.ServerRoutingReviewTest.ClarifyAfterLLM
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: :ambiguous}} = Router.route(clarify, "price")
  end

  test "dataset phase options are honored by the Router rather than only the facade" do
    disabled =
      agent("""
      intent_dataset Spectre.ServerRoutingReviewTest.Dataset, lookup: [exact: false, semantic: false]
      router strategies: [:intent_dataset], log_decisions: false
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: :no_match}} = Router.route(disabled, "price", test_pid: self())
    refute_receive {:dataset_phase, _}

    semantic =
      agent("""
      intent_dataset Spectre.ServerRoutingReviewTest.Dataset, lookup: [exact: false, semantic: true]
      router strategies: [:intent_dataset], log_decisions: false
      flow :support do
        on :pricing
      end
      """)

    assert {:ok, {:support, :pricing}, %{route: %{strategy: :semantic_cache_search}}} =
             Router.route(semantic, "price", test_pid: self())

    assert_receive {:dataset_phase, true}
    refute_receive {:dataset_phase, false}

    excluded =
      agent("""
      intent_dataset Spectre.ServerRoutingReviewTest.Dataset
      router strategies: [:intent_dataset], log_decisions: false
      flow :support do
        on :pricing, dataset_lookup: false
      end
      """)

    assert {:unmatched, %{reason: :no_match}} = Router.route(excluded, "price", test_pid: self())
    refute_receive {:dataset_phase, _}
  end

  test "route inspection prints the exact global, nested and mounted callback keys" do
    module =
      agent("""
      interrupt :cancel, regex: ~r/^cancel$/
      flow :support do
        flow :billing do
          on :pricing
        end
      end
      skill Spectre.ServerRoutingReviewTest.Skill, as: :accounts
      """)

    json =
      capture_io(fn -> assert :ok = Mix.Tasks.Spectre.Routes.run([inspect(module), "--json"]) end)

    assert {:ok, routes} = Spectre.JSON.decode(json)
    keys = Map.new(routes, &{&1["intent"], &1["dispatch"]})
    assert keys["cancel"] == "{nil, :cancel}"
    assert keys["pricing"] == "{[:support, :billing], :pricing}"
    assert keys["invoice"] == "{{{:skill, :accounts}, :billing}, :invoice}"
  end

  test "legacy cache false keeps custom adapter routing for exact and semantic lookup" do
    for {lookup, strategy} <- [
          {[exact: true, semantic: false], :semantic_cache_exact},
          {[exact: false, semantic: true], :semantic_cache_search}
        ] do
      module =
        agent("""
        intent_dataset Spectre.ServerRoutingReviewTest.Dataset, lookup: #{inspect(lookup)}
        router strategies: [:intent_dataset], log_decisions: false
        flow :support do
          on :pricing, cache: false
        end
        """)

      [rule] = module.__spectre_rules__()
      refute rule.cache
      refute Keyword.has_key?(rule.opts, :dataset_lookup)

      assert {:ok, {:support, :pricing}, %{route: %{strategy: ^strategy}}} =
               Router.route(module, "price")
    end
  end

  defp agent(body) do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string(
      "defmodule #{inspect(module)} do\nuse Spectre.Agent, server: MyApp.Server\n#{body}\nend"
    )

    module
  end
end
