defmodule SpectreRouterArbitrationContractTest.DecideOnlyArbitrator do
  @moduledoc false

  def decide(arbitration, opts) do
    case Keyword.get(opts, :custom_decision, :clarify) do
      :clarify -> {:clarify, "custom clarification"}
      :error -> {:error, :custom_failure}
      {:ok, route} -> {:ok, route}
      :llm -> {:llm, arbitration}
    end
  end
end

defmodule SpectreRouterArbitrationContractTest.LLMArbitrator do
  @moduledoc false

  alias Spectre.Router.Candidate

  def explain(arbitration, opts) do
    llm_candidate =
      Enum.find(arbitration.candidates, &(&1.provider == :llm_classifier))

    decision =
      case {llm_candidate, Keyword.get(opts, :second_arbitration, :accept)} do
        {nil, _mode} ->
          {:llm, arbitration}

        {_candidate, :invalid} ->
          {:clarify, "invalid second decision"}

        {candidate, mode} ->
          route = Candidate.to_route(candidate, arbitration.labels)
          {:ok, modify_route(route, mode)}
      end

    {decision,
     %{
       version: 1,
       outcome: if(llm_candidate, do: :second_pass, else: :llm),
       reason: :contract_arbitrator,
       thresholds: %{},
       candidates: []
     }}
  end

  defp modify_route(route, :non_llm), do: %{route | strategy: :regex}
  defp modify_route(route, :unaccepted), do: %{route | accepted?: false}
  defp modify_route(route, :invisible), do: %{route | label: :NOT_VISIBLE, rule: nil}
  defp modify_route(route, _mode), do: route
end

defmodule SpectreRouterArbitrationContractTest.Cache do
  @moduledoc false

  def put(text, result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:semantic_write, text, result})
    Keyword.get(opts, :cache_reply, {:ok, %{id: "learned"}})
  end
end

defmodule SpectreRouterArbitrationContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Input
  alias Spectre.Router.Arbitration
  alias Spectre.Router.Arbitrators.Default
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.Plugs.Arbitrate
  alias Spectre.Rule
  alias Spectre.State

  test "custom arbitration errors, clarifications, and LLM availability failures are terminal" do
    base = context("route this", [rule(:ROUTE)])

    assert {:error, :custom_failure} =
             base
             |> with_opts(
               arbitrator: SpectreRouterArbitrationContractTest.DecideOnlyArbitrator,
               custom_decision: :error
             )
             |> Arbitrate.call([])

    assert {:cont, clarified} =
             base
             |> with_opts(
               arbitrator: SpectreRouterArbitrationContractTest.DecideOnlyArbitrator,
               custom_decision: :clarify
             )
             |> Arbitrate.call([])

    assert clarified.halted?
    assert clarified.route.label == :unknown
    assert clarified.route.raw == "custom clarification"
    assert clarified.arbitration.reason == :custom_arbitrator
    assert clarified.semantic_cache_query_embedding == nil

    unknown_context =
      context("route this", [rule(:UNKNOWN), rule(:ROUTE)])
      |> with_opts(
        arbitrator: SpectreRouterArbitrationContractTest.DecideOnlyArbitrator,
        custom_decision: :clarify
      )

    assert {:cont, with_unknown_rule} = Arbitrate.call(unknown_context, [])
    assert with_unknown_rule.route.label == :UNKNOWN
    assert with_unknown_rule.route.handler == {:reply, :UNKNOWN, []}

    assert {:cont, unresolved} =
             base
             |> with_opts(
               arbitrator: SpectreRouterArbitrationContractTest.DecideOnlyArbitrator,
               custom_decision: :llm,
               llm_classifier?: true,
               model: fn _prompt, _opts -> {:ok, "ROUTE"} end
             )
             |> Arbitrate.call([])

    assert unresolved.halted?
    assert unresolved.route.label == :unknown
    assert unresolved.route.raw == "Please rephrase your request."
    assert {:llm_rearbitration_unresolved, "Please rephrase your request."} in unresolved.traces

    for {extra_opts, expected_reason} <- [
          {[llm_classifier?: false], :llm_classifier_disabled},
          {[llm_classifier?: true], :missing_llm_classifier_model},
          {[
             llm_classifier?: true,
             model: fn _prompt, _opts -> {:ok, "ROUTE"} end
           ], :no_llm_visible_rules}
        ] do
      rules =
        if expected_reason == :no_llm_visible_rules,
          do: [rule(:ROUTE, via: [:regex])],
          else: [rule(:ROUTE)]

      result =
        context("route this", rules)
        |> with_opts(
          [
            arbitrator: SpectreRouterArbitrationContractTest.LLMArbitrator
          ] ++ extra_opts
        )
        |> Arbitrate.call([])

      assert {:cont, skipped} = result
      assert skipped.halted?
      assert skipped.route.label == :unknown
      assert {:llm_arbitration_skipped, expected_reason} in skipped.traces
    end
  end

  test "LLM arbitration carries evidence, assigns, and bounded recent chat into the classifier" do
    test_pid = self()

    state = %State{
      data: %{
        chat_history: [
          %{user: "old user", assistant: "old answer"},
          %{"user" => "recent user", "assistant" => "recent answer"},
          :malformed_turn
        ]
      }
    }

    for {configured_assigns, history_opts, expected_custom, expected_history} <- [
          {%{custom: :map}, [classifier_history_limit: 2], :map,
           "User: recent user\nAssistant: recent answer\nUser: \nAssistant: "},
          {[custom: :keyword], [classifier_history: false], :keyword, "none"},
          {:invalid, [recent_chat: "supplied history"], nil, "supplied history"}
        ] do
      prompt = fn assigns ->
        send(test_pid, {:classifier_assigns, assigns})
        {:ok, "classification prompt"}
      end

      opts =
        [
          arbitrator: SpectreRouterArbitrationContractTest.LLMArbitrator,
          llm_classifier?: true,
          classifier: [
            adapter: fn _prompt, _opts -> {:ok, "ROUTE"} end,
            prompt: prompt
          ],
          classifier_assigns: configured_assigns,
          semantic_learn?: false
        ] ++ history_opts

      assert {:cont, routed} =
               context("route this request", [rule(:ROUTE)], state)
               |> with_opts(opts)
               |> Arbitrate.call([])

      assert routed.halted?
      assert routed.route.label == :ROUTE
      assert routed.route.strategy == :llm_classifier
      assert {:llm_arbitrated, routed.route} in routed.traces
      assert {:semantic_learn_skipped, :semantic_learning_disabled} in routed.traces

      assert_receive {:classifier_assigns, assigns}
      assert Map.get(assigns, :custom) == expected_custom
      assert assigns.recent_chat == expected_history
      assert assigns.input.text == "route this request"
      assert assigns.state == state
      assert is_list(assigns.candidates)
      assert is_list(assigns.evidence)
    end

    assert {:cont, clarified} =
             context("route this request", [rule(:ROUTE)])
             |> with_opts(
               arbitrator: SpectreRouterArbitrationContractTest.LLMArbitrator,
               second_arbitration: :invalid,
               llm_classifier?: true,
               model: fn _prompt, _opts -> {:ok, "ROUTE"} end
             )
             |> Arbitrate.call([])

    assert clarified.halted?
    assert clarified.route.label == :unknown
    assert clarified.route.raw == "invalid second decision"

    assert {:cont, failed} =
             context("route this request", [rule(:ROUTE)])
             |> with_opts(
               arbitrator: SpectreRouterArbitrationContractTest.LLMArbitrator,
               llm_classifier?: true,
               model: fn _prompt, _opts -> {:error, :classifier_down} end
             )
             |> Arbitrate.call([])

    assert failed.halted?
    assert failed.route.label == :unknown
    assert {:llm_arbitration_failed, :classifier_down} in failed.traces
  end

  test "semantic learning reuses the query vector and honors write failure policy" do
    query_embedding = [0.2, 0.8]

    for {cache_reply, expected_trace} <- [
          {{:ok, %{id: "stored"}}, {:semantic_learned, :ROUTE}},
          {:ok, {:semantic_learned, :ROUTE}},
          {{:error, :cache_down}, {:semantic_learn_failed, :cache_down}}
        ] do
      assert {:cont, routed} =
               learning_context("remember this route",
                 cache_reply: cache_reply,
                 semantic_cache_query_embedding: query_embedding
               )
               |> Arbitrate.call([])

      assert routed.halted?
      assert expected_trace in routed.traces
      assert routed.semantic_cache_query_embedding == nil

      assert_receive {:semantic_write, "remember this route", result}
      assert result.embedding == query_embedding
      assert result.label == :ROUTE
      assert result.source_strategy == :llm_classifier
      assert result.metadata.verified? == false
    end

    assert {:error, {:semantic_learn_failed, :cache_down}} =
             learning_context("remember this route",
               cache_reply: {:error, :cache_down},
               semantic_learn_failure: :error
             )
             |> Arbitrate.call([])

    assert_receive {:semantic_write, "remember this route", result}
    refute Map.has_key?(result, :embedding)
  end

  test "semantic learning safety gates skip writes for non-learnable or sensitive turns" do
    scenarios = [
      {"learning disabled", [semantic_learn?: false], rule(:ROUTE), [],
       :semantic_learning_disabled},
      {"route not learnable", [], rule(:ROUTE, learn: false), [], :route_not_learnable},
      {"route not visible", [second_arbitration: :invisible], rule(:ROUTE), [],
       :route_not_visible},
      {"not llm route", [second_arbitration: :non_llm], rule(:ROUTE), [],
       :not_llm_classifier_route},
      {"route not accepted", [second_arbitration: :unaccepted], rule(:ROUTE), [],
       :route_not_accepted},
      {" ", [], rule(:ROUTE), [], :blank_text},
      {"short", [], rule(:ROUTE), [], :too_short},
      {"this text is deliberately over the configured maximum", [semantic_learn_max_chars: 12],
       rule(:ROUTE), [], :too_long},
      {"password=super-secret-value", [], rule(:ROUTE), [], :secret_like_input},
      {"cache already answered", [], rule(:ROUTE),
       [
         Candidate.new(%{
           label: :ROUTE,
           provider: :semantic_cache_search,
           accepted?: true,
           handler: {:reply, :ROUTE, []}
         })
       ], :semantic_cache_hit}
    ]

    for {text, opts, route_rule, candidates, expected_reason} <- scenarios do
      assert {:cont, routed} =
               learning_context(text, opts,
                 rule: route_rule,
                 candidates: candidates
               )
               |> Arbitrate.call([])

      assert {:semantic_learn_skipped, expected_reason} in routed.traces
      refute_received {:semantic_write, ^text, _result}
    end

    action_rule =
      rule(:ROUTE,
        handler: {:action, :perform, [args: %{id: 1}]},
        learn: true
      )

    assert {:cont, action_route} =
             learning_context("learn harmless action", [], rule: action_rule)
             |> Arbitrate.call([])

    assert {:semantic_learned, :ROUTE} in action_route.traces
    assert_receive {:semantic_write, "learn harmless action", _result}

    assert {:cont, fallback_label} =
             learning_context("learn unknown route", [],
               rule: rule(:UNKNOWN, learn: true),
               model_reply: "UNKNOWN"
             )
             |> Arbitrate.call([])

    assert {:semantic_learn_skipped, :fallback_label} in fallback_label.traces
    refute_received {:semantic_write, "learn unknown route", _result}
  end

  test "default arbitrator explains rejection, precedence, fallback, and malformed evidence" do
    missing_handler = candidate(:NO_HANDLER, :custom, nil, nil, handler: nil)
    rejected = candidate(:REJECTED, :custom, 1.0, nil, accepted?: false)
    weak_score = candidate(:WEAK, :custom, 0.0, nil)
    low_margin = candidate(:LOCAL, :local_classifier, 0.99, 0.01)

    {{:error, :no_route_candidate}, error_explanation} =
      Default.explain(
        arbitration([missing_handler, rejected, weak_score, low_margin]),
        no_decision: :error
      )

    assert error_explanation.outcome == :error
    assert error_explanation.reason == :arbitration_error

    assert Enum.map(error_explanation.candidates, & &1.rejection_reason) == [
             :missing_handler,
             :provider_rejected,
             :non_positive_score,
             :margin_below_threshold
           ]

    {{:clarify, _text}, clarify_explanation} =
      Default.explain(arbitration([]), no_decision: :clarify)

    assert clarify_explanation.outcome == :clarify
    assert clarify_explanation.reason == :no_eligible_candidate

    {{:llm, %Arbitration{}}, llm_explanation} =
      Default.explain(arbitration([]),
        no_decision: :llm,
        llm_classifier?: true,
        model: fn _prompt, _opts -> {:ok, "ROUTE"} end
      )

    assert llm_explanation.outcome == :llm
    assert llm_explanation.reason == :llm_fallback

    hard = candidate(:HARD, :regex, 1.0, nil, strength: :hard)
    {{:ok, hard_route}, hard_explanation} = Default.explain(arbitration([hard]), [])
    assert hard_route.label == :HARD
    assert hard_explanation.reason == :hard_evidence

    embedding = candidate(:AGREE, :embedding, 0.91, nil)
    bag = candidate(:AGREE, :bag, 0.80, nil)
    {{:ok, agreed_route}, agreement} = Default.explain(arbitration([bag, embedding]), [])
    assert agreed_route.label == :AGREE
    assert agreement.reason == :provider_agreement

    for {candidate, reason} <- [
          {candidate(:LOCAL, :local_classifier, 0.99, 0.2), :classifier_precedence},
          {candidate(:EMBED, :embedding, 0.90, nil), :embedding_precedence},
          {candidate(:BAG, :bag, 0.80, nil), :similarity_precedence},
          {candidate(:JARO, :jaro, 0.95, nil), :similarity_precedence},
          {candidate(:CUSTOM, :custom, nil, nil,
             strength: :unexpected,
             scope: {:custom, %{id: 1}},
             flow: [:nonstandard]
           ), :best_candidate}
        ] do
      {{:ok, _route}, explanation} = Default.explain(arbitration([candidate]), [])
      assert explanation.reason == reason
    end

    conflict = [
      candidate(:FIRST, :custom, 0.4, nil),
      candidate(:SECOND, :another_provider, 0.5, nil)
    ]

    {{:ok, conflict_route}, _explanation} =
      Default.explain(arbitration(conflict), conflict: :best)

    assert conflict_route.label in [:FIRST, :SECOND]
  end

  defp learning_context(text, opts, helpers \\ []) do
    route_rule = Keyword.get(helpers, :rule, rule(:ROUTE))
    model_reply = Keyword.get(helpers, :model_reply, to_string(route_rule.label))

    context(text, [route_rule])
    |> Map.put(:candidates, Keyword.get(helpers, :candidates, []))
    |> Map.put(
      :semantic_cache_query_embedding,
      Keyword.get(opts, :semantic_cache_query_embedding)
    )
    |> with_opts(
      [
        arbitrator: SpectreRouterArbitrationContractTest.LLMArbitrator,
        llm_classifier?: true,
        model: fn _prompt, _model_opts -> {:ok, model_reply} end,
        semantic_cache: SpectreRouterArbitrationContractTest.Cache,
        test_pid: self()
      ] ++ Keyword.delete(opts, :semantic_cache_query_embedding)
    )
  end

  defp context(text, rules, state \\ %State{}) do
    %Context{
      input: Input.new(text),
      host_context: %{state: state},
      opts: [],
      labels: Enum.map(rules, & &1.label),
      rules: rules,
      candidates: [],
      semantic_cache_query_embedding: [1.0, 0.0]
    }
  end

  defp with_opts(%Context{} = context, opts), do: %{context | opts: opts}

  defp rule(label, opts \\ []) do
    Rule.new(%{
      label: label,
      handler: Keyword.get(opts, :handler, {:reply, label, []}),
      owner: __MODULE__,
      scope: Keyword.get(opts, :scope, :agent),
      via: Keyword.get(opts, :via, [:llm_classifier]),
      learn: Keyword.get(opts, :learn, true)
    })
  end

  defp candidate(label, provider, score, margin, opts \\ []) do
    Candidate.new(%{
      label: label,
      provider: provider,
      score: score,
      margin: margin,
      strength: Keyword.get(opts, :strength, :medium),
      accepted?: Keyword.get(opts, :accepted?, true),
      handler: Keyword.get(opts, :handler, {:reply, label, []}),
      scope: Keyword.get(opts, :scope, :agent),
      flow: Keyword.get(opts, :flow)
    })
  end

  defp arbitration(candidates) do
    %Arbitration{
      input: Input.new("arbitrate"),
      state: %State{},
      rules: [],
      labels: Enum.map(candidates, & &1.label),
      candidates: candidates
    }
  end
end
