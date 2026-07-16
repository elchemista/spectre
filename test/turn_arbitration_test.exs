defmodule SpectreTurnArbitrationTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Router.Arbitration
  alias Spectre.Router.Arbitrators.Default
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.State
  alias Spectre.Turn
  alias Spectre.Turn.Decision

  @handler {:reply, :ok, []}

  describe "default arbitration" do
    test "hard deterministic evidence wins over a higher classifier score" do
      local =
        candidate(:BILLING, :local_classifier,
          score: 0.99,
          margin: 0.5,
          strength: :medium
        )

      hard = candidate(:HELP, :regex, score: 0.2, strength: :hard)

      assert {:ok, route} = Default.decide(arbitration([local, hard]), [])
      assert route.label == :HELP
      assert route.strategy == :regex
      assert route.confidence == 0.2
    end

    test "agreement across providers wins before a conflicting single classifier" do
      bag = candidate(:BILLING, :bag, score: 0.80)
      cache = candidate(:BILLING, :semantic_cache, score: 0.85)

      local =
        candidate(:OTHER, :local_classifier,
          score: 0.99,
          margin: 0.5
        )

      assert {:ok, route} =
               Default.decide(arbitration([local, bag, cache]), [])

      assert route.label == :BILLING
      assert route.strategy == :semantic_cache
      assert route.confidence == 0.85
    end

    test "classifier acceptance threshold is configurable" do
      local =
        candidate(:LOCAL, :local_classifier,
          score: 0.92,
          margin: 0.2
        )

      bag = candidate(:BAG, :bag, score: 0.80)
      payload = arbitration([local, bag])

      assert {:ok, default_route} = Default.decide(payload, [])
      assert default_route.label == :BAG

      assert {:ok, configured_route} =
               Default.decide(payload, classifier_accept: 0.90)

      assert configured_route.label == :LOCAL
      assert configured_route.strategy == :local_classifier
    end

    test "classifier margin threshold rejects ambiguous local evidence" do
      local =
        candidate(:LOCAL, :local_classifier,
          score: 0.99,
          margin: 0.01
        )

      bag = candidate(:BAG, :bag, score: 0.80)
      payload = arbitration([local, bag])

      assert {:ok, default_route} = Default.decide(payload, [])
      assert default_route.label == :BAG

      assert {:ok, configured_route} =
               Default.decide(payload, classifier_margin: 0.0)

      assert configured_route.label == :LOCAL
    end

    test "embedding evidence must satisfy both score and margin" do
      embedding =
        candidate(:SEMANTIC, :embedding,
          score: 0.90,
          margin: 0.01
        )

      bag = candidate(:BAG, :bag, score: 0.80)
      payload = arbitration([embedding, bag])

      assert {:ok, default_route} = Default.decide(payload, [])
      assert default_route.label == :BAG

      assert {:ok, configured_route} =
               Default.decide(payload, embedding_margin: 0.0)

      assert configured_route.label == :SEMANTIC
      assert configured_route.strategy == :embedding
    end

    test "bag evidence below threshold clarifies unless threshold is lowered" do
      payload = arbitration([candidate(:BAG, :bag, score: 0.71)])

      assert {:clarify, "Please rephrase your request."} =
               Default.decide(payload, [])

      assert {:ok, route} = Default.decide(payload, bag_accept: 0.70)
      assert route.label == :BAG
    end

    test "jaro evidence respects its acceptance threshold" do
      payload = arbitration([candidate(:FUZZY, :jaro, score: 0.89)])

      assert {:clarify, _message} = Default.decide(payload, [])

      assert {:ok, route} = Default.decide(payload, jaro_accept: 0.85)
      assert route.label == :FUZZY
      assert route.strategy == :jaro
    end

    test "conflicting generic evidence asks for LLM arbitration when it is configured" do
      payload =
        arbitration([
          candidate(:FIRST, :custom, score: 0.90),
          candidate(:SECOND, :custom, score: 0.80)
        ])

      opts = [via: [:llm_classifier], model: fn _prompt -> {:ok, "FIRST"} end]

      assert {:llm, ^payload} = Default.decide(payload, opts)
      assert {:clarify, _message} = Default.decide(payload, [])
    end

    test "conflict best mode selects the highest ranked candidate" do
      payload =
        arbitration([
          candidate(:FIRST, :custom, score: 0.90),
          candidate(:SECOND, :custom, score: 0.80)
        ])

      assert {:ok, route} = Default.decide(payload, conflict: :best)
      assert route.label == :FIRST
      assert route.confidence == 0.90
    end

    test "candidate without a handler cannot become a route" do
      payload =
        arbitration([
          candidate(:UNROUTABLE, :custom, score: 1.0, handler: nil)
        ])

      assert {:clarify, _message} = Default.decide(payload, [])
    end

    test "candidate not accepted is ignored" do
      payload =
        arbitration([
          candidate(:REJECTED, :custom, score: 1.0, accepted?: false)
        ])

      assert {:clarify, _message} = Default.decide(payload, [])
    end

    test "accepted LLM candidate becomes a route and retains visible labels" do
      payload =
        arbitration([
          candidate(:ANSWER, :llm_classifier,
            score: 0.0,
            margin: 0.0,
            accepted?: true,
            terminal?: true
          )
        ])

      assert {:ok, route} = Default.decide(payload, [])
      assert route.label == :ANSWER
      assert route.strategy == :llm_classifier
      assert route.labels == [:ANSWER]
      assert route.terminal?
    end

    test "empty evidence uses an available LLM or follows the configured fallback" do
      payload = arbitration([])

      assert {:clarify, _message} = Default.decide(payload, [])

      assert {:llm, ^payload} =
               Default.decide(payload,
                 via: [:llm_classifier],
                 model: fn _prompt -> {:ok, "ANSWER"} end
               )

      assert {:clarify, _message} =
               Default.decide(payload,
                 via: [:llm_classifier],
                 model: fn _prompt -> {:ok, "ANSWER"} end,
                 no_decision: :clarify
               )

      assert {:error, :no_route_candidate} = Default.decide(payload, no_decision: :error)
    end
  end

  describe "arbitration snapshots" do
    test "hard-evidence short-circuiting is opt-in for custom arbitrators" do
      hard = candidate(:HELP, :regex, strength: :hard)

      default_context =
        %Context{opts: [arbitrator: {Default, []}]}
        |> Context.add_candidate(hard)

      custom_context = %{
        default_context
        | opts: [arbitrator: {SpectreTurnArbitrationTest, []}]
      }

      assert Context.hard_candidate_locked?(default_context)
      refute Context.hard_candidate_locked?(custom_context)

      assert Context.hard_candidate_locked?(%{
               custom_context
               | opts: Keyword.put(custom_context.opts, :hard_short_circuit?, true)
             })
    end

    test "preserves evidence insertion order and host state" do
      first = candidate(:FIRST, :regex, strength: :hard)
      second = candidate(:SECOND, :bag, score: 0.8)
      state = %State{current_flow: :support}

      context =
        %Context{
          input: Input.new("route me"),
          host_context: %{state: state},
          opts: [],
          labels: [:FIRST, :SECOND],
          rules: []
        }
        |> Context.add_candidate(first)
        |> Context.add_candidate(second)

      snapshot = Arbitration.from_context(context)

      assert snapshot.candidates == [first, second]
      assert snapshot.state == state
      assert snapshot.input.text == "route me"
      assert snapshot.labels == [:FIRST, :SECOND]
    end
  end

  describe "turn decision precedence" do
    test "open awaitable wins over pending effect, completion and reply" do
      state =
        %State{}
        |> State.put_pending_effect(
          Effect.stage(%{name: :protected_action}),
          :terms
        )

      completed =
        %{name: :old_action}
        |> Effect.stage()
        |> Effect.complete(:done)

      result = %Result{
        state: state,
        effects: [completed],
        reply_text: "visible"
      }

      awaitable = State.open_policy_awaitable(state)
      assert {:awaiting, ^awaitable, ^result} = Decision.decide(result)
    end

    test "authoritative pending state wins over local completions and reply" do
      state =
        State.put_pending_effect(
          %State{},
          Effect.stage(%{name: :current_action}),
          nil
        )

      completed =
        %{name: :old_action}
        |> Effect.stage()
        |> Effect.complete(:done)

      accepted =
        :terms
        |> Awaitable.open_policy(completed)
        |> Awaitable.accept(:accepted)

      result = %Result{
        state: state,
        effects: [completed],
        awaitables: [accepted],
        reply_text: "visible"
      }

      pending = State.pending_effect(state)
      assert {:needs, ^pending, ^result} = Decision.decide(result)
    end

    test "authoritative empty state suppresses stale open and pending transitions" do
      waiting =
        %{name: :stale_action}
        |> Effect.stage()
        |> Effect.waiting_policy(:terms)

      open = Awaitable.open_policy(:terms, waiting)

      result = %Result{
        state: %State{},
        effects: [waiting],
        awaitables: [open]
      }

      assert Result.open_awaitable(result) == nil
      assert Result.pending_effect(result) == nil
      assert {:no_response, ^result} = Decision.decide(result)
    end

    test "state-less results fall back to transition-local awaitables" do
      waiting =
        %{name: :action}
        |> Effect.stage()
        |> Effect.waiting_policy(:terms)

      open = Awaitable.open_policy(:terms, waiting)
      result = %Result{effects: [waiting], awaitables: [open]}

      assert Result.open_awaitable(result) == open
      assert {:awaiting, ^open, ^result} = Decision.decide(result)
    end

    test "terminal effect wins over terminal awaitable and reply" do
      completed =
        %{name: :action}
        |> Effect.stage()
        |> Effect.complete(%{id: 1})

      rejected =
        :terms
        |> Awaitable.open_policy(completed)
        |> Awaitable.reject(:no)

      result = %Result{
        effects: [completed],
        awaitables: [rejected],
        reply_text: "also visible"
      }

      assert {:completed, ^completed, ^result} = Decision.decide(result)
      assert Result.latest_completion(result) == completed
    end

    test "terminal awaitable is surfaced when no effect completed" do
      effect = Effect.stage(%{name: :action})

      rejected =
        :terms
        |> Awaitable.open_policy(effect)
        |> Awaitable.reject(:no)

      result = %Result{awaitables: [rejected]}

      assert {:completed, ^rejected, ^result} = Decision.decide(result)
    end

    test "latest terminal effect determines completion and action outcome" do
      completed =
        %{name: :first}
        |> Effect.stage()
        |> Effect.complete(:done)

      failed =
        %{name: :second}
        |> Effect.stage()
        |> Effect.fail(:denied)

      result = %Result{effects: [completed, failed]}

      assert Result.completions(result) == [completed, failed]
      assert Result.latest_completion(result) == failed
      assert Result.action_outcome(result) == {:error, :denied}
      assert {:completed, ^failed, ^result} = Decision.decide(result)
    end

    test "blank replies become no_response while non-blank replies become reply" do
      blank = %Result{reply_text: " \n\t "}
      visible = %Result{reply_text: "done"}

      assert {:no_response, ^blank} = Decision.decide(blank)
      assert {:reply, ^visible} = Decision.decide(visible)
    end

    test "lifecycle snapshot normalizes cancellation and visibility" do
      cancelled =
        %{name: :action}
        |> Effect.stage()
        |> Effect.cancel(:host_cancelled)

      result = %Result{effects: [cancelled], reply_text: "cancelled"}
      lifecycle = Result.lifecycle(result)

      assert lifecycle.open_awaitable == nil
      assert lifecycle.pending_effect == nil
      assert lifecycle.completions == [cancelled]
      assert lifecycle.latest_completion == cancelled
      assert lifecycle.action_outcome == {:cancelled, :host_cancelled}
      assert lifecycle.visible_reply?
    end

    test "Turn.from_result stores the same lifecycle used for its decision" do
      result = %Result{reply_text: "hello"}

      turn =
        Turn.from_result(
          SpectreTurnArbitrationTest,
          Input.new("hello"),
          [source: :test],
          result
        )

      assert {:reply, ^result} = turn.decision
      assert turn.metadata.lifecycle == Result.lifecycle(result)
      assert turn.opts == [source: :test]
      assert turn.agent == SpectreTurnArbitrationTest
    end
  end

  defp candidate(label, provider, opts) do
    %Candidate{
      label: label,
      flow: Keyword.get(opts, :flow),
      handler: Keyword.get(opts, :handler, @handler),
      provider: provider,
      score: Keyword.get(opts, :score, 0.9),
      margin: Keyword.get(opts, :margin, 0.2),
      strength: Keyword.get(opts, :strength, :weak),
      raw: Keyword.get(opts, :raw, label),
      matched: Keyword.get(opts, :matched),
      metadata: %{},
      accepted?: Keyword.get(opts, :accepted?, true),
      terminal?: Keyword.get(opts, :terminal?, false)
    }
  end

  defp arbitration(candidates) do
    labels =
      candidates
      |> Enum.map(& &1.label)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %Arbitration{
      input: Input.new("route me"),
      state: %State{},
      rules: [],
      labels: labels,
      candidates: candidates,
      context: %Context{}
    }
  end
end
