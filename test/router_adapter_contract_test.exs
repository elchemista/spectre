defmodule SpectreRouterAdapterContractTest.RaisingLabel do
  @moduledoc false
  defstruct []
end

defmodule SpectreRouterAdapterContractTest.Embedding do
  @moduledoc false

  def embed(text, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:embedding_boundary, text, opts[:source]})

    case text do
      "bad" -> {:error, :example_failed}
      "invalid" -> {:ok, :not_a_vector}
      "empty" -> {:ok, []}
      "mixed" -> {:ok, [1.0, :bad]}
      "raw" -> :invalid_reply
      "opposite" -> {:ok, [0.0, 1.0]}
      _other -> {:ok, [1.0, 0.0]}
    end
  end
end

defmodule SpectreRouterAdapterContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Input
  alias Spectre.Router.Context
  alias Spectre.Router.DefaultPipeline
  alias Spectre.Router.LLMClassifier
  alias Spectre.Router.Plugs.EmbeddingSimilarity
  alias Spectre.Router.Plugs.LLMFallback
  alias Spectre.Rule

  test "the declared default pipeline executes end to end" do
    assert {:ok, %Context{} = routed} =
             DefaultPipeline.call(context("nothing", [], classification_log?: false))

    assert routed.halted?
    assert routed.route.label == :unknown
  end

  test "LLM classifier normalizes prompts and labels and contains every callback failure class" do
    assert {:error, :missing_llm_classifier_model} = LLMClassifier.classify("hello", [:HELLO])
    assert {:error, :no_llm_classifier_labels} = LLMClassifier.classify("hello", [], [])

    test_pid = self()

    model = fn prompt, opts ->
      send(test_pid, {:classifier_prompt, prompt, opts})
      {:ok, "```text\nlabel: hello-world\n```"}
    end

    assert {:ok, route} =
             LLMClassifier.classify("hello", [:HELLO_WORLD],
               classifier: [
                 adapter: model,
                 prompt: fn assigns ->
                   {:ok,
                    "#{assigns.custom}|#{assigns.text}|#{assigns.recent_chat}|#{inspect(assigns.evidence)}"}
                 end,
                 llm_opts: [temperature: 0.2]
               ],
               classifier_assigns: [custom: "value"],
               recent_chat: "User: before",
               classifier_evidence: :invalid_evidence
             )

    assert route.label == :HELLO_WORLD
    assert route.accepted?
    assert_receive {:classifier_prompt, prompt, classifier_opts}
    assert prompt =~ "value|hello|User: before|:invalid_evidence"
    assert classifier_opts[:purpose] == :classifier
    assert classifier_opts[:temperature] == 0.2
    assert classifier_opts[:max_tokens] == 8

    assert {:ok, default_prompt_route} =
             LLMClassifier.classify("hello", [:HELLO],
               model: fn prompt, _opts ->
                 assert prompt =~ "Routing evidence:\nnone"
                 {:ok, "HELLO"}
               end,
               classifier: :invalid,
               classifier_assigns: :invalid
             )

    assert default_prompt_route.label == :HELLO

    for prompt_reply <- [{:error, :prompt_down}, %{bad: :prompt}] do
      assert {:error, _reason} =
               LLMClassifier.classify("hello", [:HELLO],
                 classifier: [
                   adapter: fn _prompt, _opts -> {:ok, "HELLO"} end,
                   prompt: fn _assigns -> prompt_reply end
                 ]
               )
    end

    assert {:error, {:ambiguous_llm_classifier_labels, labels}} =
             LLMClassifier.classify("hello", [:"HELLO-WORLD", :HELLO_WORLD],
               model: fn _prompt, _opts -> {:ok, "hello world"} end
             )

    assert labels == [:"HELLO-WORLD", :HELLO_WORLD]

    assert {:error, {:unknown_llm_classifier_label, "OTHER"}} =
             LLMClassifier.classify("hello", [:HELLO],
               model: fn _prompt, _opts -> {:ok, "OTHER"} end
             )

    assert {:error, {:llm_classifier_exception, Protocol.UndefinedError, _message}} =
             LLMClassifier.classify("hello", [%SpectreRouterAdapterContractTest.RaisingLabel{}],
               model: fn _prompt, _opts -> {:ok, "HELLO"} end
             )

    assert LLMClassifier.enabled?(llm_classifier?: true)
    refute LLMClassifier.enabled?(llm_classifier?: false, via: [:llm_classifier])
    assert LLMClassifier.enabled?(via: [:regex, :llm_classifier])
    refute LLMClassifier.enabled?(via: [:regex])
    assert LLMClassifier.available?(model: model)
    assert LLMClassifier.available?(classifier: [adapter: model])
    refute LLMClassifier.available?([])
  end

  test "embedding evidence accepts module, tuple, and function adapters while isolating bad vectors" do
    rules = [
      rule(:EMPTY, []),
      rule(:MATCH, ["same", "opposite", "bad"])
    ]

    context =
      context("query", rules,
        embedding: {SpectreRouterAdapterContractTest.Embedding, [source: :tuple]},
        test_pid: self()
      )

    assert {:cont, routed} = EmbeddingSimilarity.call(context, [])
    assert [%Spectre.Router.Candidate{label: :MATCH, matched: "same"}] = routed.candidates

    assert_receive {:embedding_boundary, "query", :tuple}
    assert_receive {:embedding_boundary, "same", :tuple}
    assert_receive {:embedding_boundary, "opposite", :tuple}
    assert_receive {:embedding_boundary, "bad", :tuple}

    assert {:cont, module_routed} =
             context("query", [rule(:MATCH, ["same"])],
               embedding: SpectreRouterAdapterContractTest.Embedding,
               test_pid: self()
             )
             |> EmbeddingSimilarity.call([])

    assert [%Spectre.Router.Candidate{label: :MATCH}] = module_routed.candidates

    fun2 = fn text, opts ->
      send(Keyword.fetch!(opts, :test_pid), {:fun2_embedding, text})
      {:ok, [1.0, 0.0]}
    end

    assert {:cont, fun2_routed} =
             context("query", [rule(:MATCH, ["same"])],
               embedding: fun2,
               test_pid: self()
             )
             |> EmbeddingSimilarity.call([])

    assert [%Spectre.Router.Candidate{}] = fun2_routed.candidates
    assert_receive {:fun2_embedding, "query"}

    fun1 = fn _text -> {:ok, [1.0, 0.0]} end

    assert {:cont, fun1_routed} =
             context("query", [rule(:MATCH, ["same"])], embedding: fun1)
             |> EmbeddingSimilarity.call([])

    assert [%Spectre.Router.Candidate{}] = fun1_routed.candidates

    for {embedding, expected_reason} <- [
          {nil, :missing_embedding_adapter},
          {123, {:invalid_embedding_adapter, 123}}
        ] do
      opts = if is_nil(embedding), do: [], else: [embedding: embedding]

      assert {:cont, skipped} =
               context("query", [rule(:MATCH, ["same"])], opts)
               |> EmbeddingSimilarity.call([])

      assert {:embedding_skip, reason} = hd(skipped.traces)
      assert reason == expected_reason
      assert skipped.candidates == []
    end

    for text <- ["invalid", "empty", "mixed", "raw"] do
      assert {:cont, skipped} =
               context(text, [rule(:MATCH, ["same"])],
                 embedding: SpectreRouterAdapterContractTest.Embedding,
                 test_pid: self()
               )
               |> EmbeddingSimilarity.call([])

      assert [{:embedding_skip, _reason}] = skipped.traces
      assert skipped.candidates == []
    end

    assert {:cont, no_example_candidate} =
             context("query", [rule(:MATCH, ["bad"])],
               embedding: SpectreRouterAdapterContractTest.Embedding,
               test_pid: self()
             )
             |> EmbeddingSimilarity.call([])

    assert no_example_candidate.candidates == []

    halted = %{context("query", rules, embedding: fun1) | halted?: true}
    assert {:cont, ^halted} = EmbeddingSimilarity.call(halted, [])
  end

  test "a failed probabilistic strategy recovers to the declared :UNKNOWN rule" do
    unknown_rule = rule(:UNKNOWN, [])
    rules = [rule(:BILLING, [], via: [:llm_classifier]), unknown_rule]

    assert {:cont, recovered} =
             context("bill", rules,
               llm_fallback?: true,
               model: fn _prompt, _opts -> {:error, :classifier_down} end
             )
             |> LLMFallback.call([])

    assert recovered.route.label == :UNKNOWN
    assert recovered.route.handler == {:reply, :UNKNOWN, []}
    assert recovered.route.strategy == :unknown_fallback
    refute recovered.route.accepted?
    assert recovered.route.fallback_error != nil

    without_unknown = [rule(:BILLING, [], via: [:llm_classifier])]

    assert {:cont, bare} =
             context("bill", without_unknown,
               llm_fallback?: true,
               model: fn _prompt, _opts -> {:error, :classifier_down} end
             )
             |> LLMFallback.call([])

    assert bare.route.label == :unknown
    assert bare.route.handler == nil
  end

  test "legacy LLM fallback accepts visible labels and degrades safely when disabled or ambiguous" do
    visible_rules = [
      rule(:BILLING, [], via: [:llm_classifier]),
      rule(:SUPPORT, [], via: [:llm_classifier])
    ]

    assert {:cont, disabled} =
             context("bill", visible_rules, llm_fallback?: false)
             |> LLMFallback.call([])

    assert disabled.halted?
    assert disabled.route.label == :unknown
    assert {:fallback_route, :llm_fallback_disabled} in disabled.traces

    assert {:cont, accepted} =
             context("bill", visible_rules,
               llm_fallback?: true,
               model: fn _prompt, _opts -> {:ok, "BILLING"} end
             )
             |> LLMFallback.call([])

    assert accepted.halted?
    assert accepted.route.label == :BILLING
    assert accepted.route.handler == {:reply, :BILLING, []}
    assert match?({:llm_accept, _route}, hd(accepted.traces))

    assert {:cont, failed} =
             context("bill", visible_rules,
               llm_fallback?: true,
               model: fn _prompt, _opts -> {:error, :classifier_down} end
             )
             |> LLMFallback.call([])

    assert failed.route.label == :unknown
    assert match?({:fallback_route, _reason}, hd(failed.traces))

    llm_only = [rule(:LEGACY, [], via: [:llm])]

    assert {:cont, legacy} =
             context("legacy", llm_only,
               llm_fallback?: true,
               model: fn _prompt, _opts -> {:ok, "LEGACY"} end
             )
             |> LLMFallback.call([])

    assert legacy.route.label == :LEGACY

    duplicate_rules = [
      rule(:DUPLICATE, [], via: [:llm_classifier], scope: :agent),
      rule(:DUPLICATE, [], via: [:llm_classifier], scope: {:skill, :duplicate})
    ]

    assert {:cont, ambiguous} =
             context("duplicate", duplicate_rules, llm_fallback?: true)
             |> LLMFallback.call([])

    assert ambiguous.route.label == :unknown

    assert {:fallback_route, {:ambiguous_scoped_labels, :llm_classifier, [:DUPLICATE]}} in ambiguous.traces

    assert {:cont, no_labels} =
             context("nothing", [], llm_fallback?: true)
             |> LLMFallback.call([])

    assert {:fallback_route, :no_llm_classifier_labels} in no_labels.traces

    halted = %{context("bill", visible_rules, llm_fallback?: true) | halted?: true}
    assert {:cont, ^halted} = LLMFallback.call(halted, [])
  end

  defp context(text, rules, opts) do
    input = Input.new(text)

    %Context{
      input: input,
      host_context: %{},
      opts: opts,
      labels: Enum.map(rules, & &1.label) |> Enum.uniq(),
      rules: rules,
      candidates: []
    }
  end

  defp rule(label, embeddings, opts \\ []) do
    Rule.new(%{
      label: label,
      flow: :router_contract,
      handler: {:reply, label, []},
      owner: __MODULE__,
      scope: Keyword.get(opts, :scope, :agent),
      embedding: embeddings,
      via: Keyword.get(opts, :via, [])
    })
  end
end
