defmodule Spectre.ServerAgentTest.LocalClassifier do
  def classify(_text, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:local_classifier_called, opts})
    {:ok, %{label: :pricing, accepted?: true, confidence: 0.99, margin: 0.5}}
  end
end

defmodule Spectre.ServerAgentTest.IntentModel do
  def complete(_prompt, _opts), do: {:ok, "pricing"}
end

defmodule Spectre.ServerAgentTest.FailedClassifier do
  def classify(_text, _opts), do: {:error, :classifier_offline}
end

defmodule Spectre.ServerAgentTest.ResponseModel do
  def complete(_prompt, _opts), do: raise("response model must not classify intents")
end

defmodule Spectre.ServerAgentTest.StackExtension do
  @behaviour Spectre.Extension
  def api_version, do: 1
  def id, do: :stack_classifier
  def compile(_owner, _opts), do: {:ok, %{}}

  def agent_config(_config),
    do: [
      model: Spectre.ServerAgentTest.ResponseModel,
      classifier: [adapter: {Spectre.ServerAgentTest.IntentModel, :complete, []}]
    ]
end

defmodule Spectre.ServerAgentTest.Package do
  use Spectre.Stack.Installable,
    id: :classifier_package,
    version: "1.0.0",
    spectre: ">= 0.3.0 and < 0.5.0",
    agent_extensions: [Spectre.ServerAgentTest.StackExtension]
end

defmodule Spectre.ServerAgentTest.Stack do
  use Spectre.Stack
  install(Spectre.ServerAgentTest.Package)
end

defmodule Spectre.ServerAgentTest.Clarify do
  @behaviour Spectre.Router.Arbitrator
  def decide(_arbitration, _opts), do: {:clarify, "Which one?"}
end

defmodule Spectre.ServerAgentTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.Router

  defp compile_agent(body, opts \\ "server: MyApp.SupportServer") do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Spectre.Agent, #{opts}
      #{body}
    end
    """)

    module
  end

  test "declarative routes preserve flow defaults, explicit overrides and nested path" do
    agent =
      compile_agent("""
      router strategies: [:regex, :intent_dataset, :local_classifier, :llm_classifier]
      flow :support, defaults: [collect_intent: true] do
        on :pricing, semantic_examples: ["how much?"]
        on :delete_account, regex: ~r/^delete$/, collect_intent: false, protected: true
        flow :billing, defaults: [dataset_lookup: false] do
          on :invoice, regex: ~r/^invoice$/
        end
      end
      """)

    [pricing, deletion, invoice] = agent.__spectre_rules__()
    assert agent.__spectre_server__() == MyApp.SupportServer
    assert pricing.handler == {:server, {[:support], :pricing}, []}
    assert pricing.embedding == ["how much?"]
    assert pricing.learn
    refute deletion.learn
    assert deletion.opts[:protected]
    assert invoice.learn
    refute invoice.cache
    assert invoice.opts[:dataset_lookup] == false
    refute Keyword.has_key?(pricing.opts, :dataset_lookup)
    assert invoice.flow_path == [:support, :billing]

    assert agent.__spectre_router__()[:via] == [
             :regex,
             :semantic_cache,
             :classifier,
             :llm_classifier
           ]

    assert {:ok, {[:support, :billing], :invoice}, metadata} = Router.route(agent, "invoice")
    assert metadata.scope == :agent
    assert {:ok, {:support, :delete_account}, %{protected: true}} = Router.route(agent, "delete")
  end

  test "an Agent with bodyless routes requires a valid server binding" do
    assert_raise ArgumentError, ~r/bodyless/, fn ->
      compile_agent("flow :support do\n on :pricing\n end", "history: 20")
    end

    assert_raise ArgumentError, ~r/invalid_server/, fn ->
      compile_agent("flow :support do\n on :pricing\n end", "server: false")
    end
  end

  test "conflicting aliases and non boolean collection flags fail explicitly" do
    assert_raise ArgumentError, ~r/conflicting options :collect_intent and :learn/, fn ->
      compile_agent("flow :support do\n on :pricing, collect_intent: true, learn: false\n end")
    end

    assert_raise ArgumentError, ~r/only true or false/, fn ->
      compile_agent("flow :support do\n on :pricing, collect_intent: :yes\n end")
    end

    assert_raise ArgumentError, ~r/conflicting options :strategies and :via/, fn ->
      compile_agent("router strategies: [:regex], via: [:embedding]")
    end
  end

  test "named classifier bindings coexist and retain dedicated timeouts" do
    agent =
      compile_agent("""
      classifier :local, Spectre.ServerAgentTest.LocalClassifier, artifact_dir: "priv/intents", timeout: 100
      classifier :llm, Spectre.ServerAgentTest.IntentModel, timeout: 200
      router strategies: [:local_classifier, :llm_classifier]
      flow :support do
        on :pricing
      end
      """)

    binding = agent.__spectre_config__()[:classifier]
    assert binding[:local] == Spectre.ServerAgentTest.LocalClassifier
    assert binding[:local_opts][:artifact_dir] == "priv/intents"
    assert binding[:local_opts][:local_classifier_timeout] == 100
    assert binding[:adapter] == {Spectre.ServerAgentTest.IntentModel, :complete, []}
    assert binding[:llm_opts][:llm_timeout] == 200

    assert {:ok, {:support, :pricing}, %{route: %{strategy: :local_classifier}}} =
             Router.route(agent, "price", test_pid: self())

    assert_receive {:local_classifier_called, _opts}
  end

  test "a local override retains the Stack classifier and uses its distinct LLM" do
    agent =
      compile_agent(
        """
        classifier :local, Spectre.ServerAgentTest.FailedClassifier
        router strategies: [:local_classifier, :llm_classifier], log_decisions: false
        flow :support do
          on :pricing
        end
        """,
        "server: MyApp.SupportServer, stack: Spectre.ServerAgentTest.Stack"
      )

    binding = agent.__spectre_config__()[:classifier]
    assert binding[:local] == Spectre.ServerAgentTest.FailedClassifier
    assert binding[:adapter] == {Spectre.ServerAgentTest.IntentModel, :complete, []}
    assert agent.__spectre_config__()[:model] == Spectre.ServerAgentTest.ResponseModel

    assert {:ok, {:support, :pricing}, %{route: %{strategy: :llm_classifier}}} =
             Router.route(agent, "how much does it cost?")
  end

  test "missing routes and failed classifiers retain different fallback reasons" do
    agent =
      compile_agent("""
      router strategies: [:regex]
      flow :support do
        on :pricing, regex: ~r/^price$/
      end
      """)

    assert {:unmatched, %{reason: :no_match}} = Router.route(agent, "hello")

    failing =
      compile_agent("""
      classifier :local, Spectre.ServerAgentTest.FailedClassifier
      router strategies: [:local_classifier]
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: {:classifier_error, :classifier_offline}}} =
             Router.route(failing, "price")
  end

  test "arbitration groups control the real provider thresholds and terminal metadata" do
    agent =
      compile_agent("""
      classifier :local, Spectre.ServerAgentTest.LocalClassifier
      router strategies: [:local_classifier], log_decisions: false,
        arbitrator: {Spectre.Router.Arbitrators.Default,
          local_classifier: [min_score: 1.0, min_margin: 0.2], on_no_decision: :clarify}
      flow :support do
        on :pricing
      end
      """)

    assert {:unmatched, %{reason: :ambiguous, arbitration: explanation}} =
             Router.route(agent, "price", test_pid: self())

    assert [%{eligible?: false, required: %{score: 1.0, margin: 0.2}}] = explanation.candidates

    terminal =
      compile_agent("""
      router strategies: [:regex], terminal: [intents: [:pricing], min_confidence: 0.9]
      flow :support do
        on :pricing, regex: ~r/^price$/
      end
      """)

    assert {:ok, {:support, :pricing}, %{route: %{terminal?: true}}} =
             Router.route(terminal, "price")

    assert_raise ArgumentError, ~r/conflicting options/, fn ->
      compile_agent(
        "router arbitrator: {Spectre.Router.Arbitrators.Default, on_conflict: :llm, conflict: :best}"
      )
    end

    assert_raise ArgumentError, ~r/unknown local_classifier option/, fn ->
      compile_agent(
        "router arbitrator: {Spectre.Router.Arbitrators.Default, local_classifier: [confidence: 0.8]}"
      )
    end
  end

  test "ambiguity and UNKNOWN remain explicit and keep accepted candidates" do
    agent =
      compile_agent("""
      router strategies: [:regex], arbitrator: {Spectre.ServerAgentTest.Clarify, []}
      flow :support do
        on :pricing, regex: ~r/price/
        on :refund, regex: ~r/price/
      end
      """)

    assert {:unmatched, %{reason: :ambiguous, candidates: [_ | _]}} = Router.route(agent, "price")

    unknown =
      compile_agent("""
      router strategies: [:regex]
      flow :support do
        on :UNKNOWN
      end
      """)

    assert {:ok, {:support, :UNKNOWN}, _metadata} = Router.route(unknown, "hello")
  end

  test "Skill dispatch retains mount scope" do
    skill = Module.concat(__MODULE__, "Skill#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(skill)} do
      use Spectre.Skill
      flow :billing do
        on :invoice, regex: ~r/^invoice$/
      end
    end
    """)

    agent =
      compile_agent("""
      router strategies: [:regex]
      skill #{inspect(skill)}, as: :accounts
      """)

    assert {:ok, {{{:skill, :accounts}, :billing}, :invoice}, %{scope: {:skill, :accounts}}} =
             Router.route(agent, "invoice")
  end

  test "input normalization is an explicit once per input stage" do
    agent =
      compile_agent("""
      input_pipeline do
        plug Spectre.Input.Plugs.NormalizeText, trim: true, case: :downcase
      end
      router strategies: [:regex]
      flow :support do
        on :pricing, regex: ~r/^price$/
      end
      """)

    assert {:ok, input} = Router.prepare_input(agent, "  PRICE  ")
    assert input.text == "price"
    assert {:ok, {:support, :pricing}, _metadata} = Router.route(agent, input)
  end
end
