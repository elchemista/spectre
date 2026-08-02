defmodule NestedFlowTest do
  use ExUnit.Case, async: true

  alias Spectre.Input
  alias Spectre.Router
  alias Spectre.Router.LLMClassifier
  alias Spectre.Rule
  alias Spectre.State

  defp compile_agent(source) do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Spectre.Agent

      #{source}
    end
    """

    Code.compile_string(source)
    module
  end

  defp compiled_rules(agent) do
    agent |> Spectre.Definition.rules() |> Enum.map(&Rule.new/1)
  end

  defp rule(agent, label) do
    Enum.find(compiled_rules(agent), &(&1.label == label))
  end

  describe "nested flow declarations" do
    test "nested flows compile and keep the full flow path" do
      agent =
        compile_agent("""
        flow :checkout do
          on :PAY_CARD, regex: ~r/card/i do
            reply :pay_card
          end

          flow :shipping do
            on :TRACK_PARCEL, regex: ~r/track/i do
              reply :track_parcel
            end

            flow :address do
              on :CHANGE_ADDRESS, regex: ~r/address/i do
                reply :change_address
              end
            end
          end
        end

        flow :support do
          on :REFUND, regex: ~r/refund/i do
            reply :refund
          end
        end
        """)

      assert %Rule{flow: :checkout, flow_path: [:checkout]} = rule(agent, :PAY_CARD)

      assert %Rule{flow: :shipping, flow_path: [:checkout, :shipping]} =
               rule(agent, :TRACK_PARCEL)

      assert %Rule{flow: :address, flow_path: [:checkout, :shipping, :address]} =
               rule(agent, :CHANGE_ADDRESS)

      assert %Rule{flow: :support, flow_path: [:support]} = rule(agent, :REFUND)
    end

    test "top-level flows keep the historical single-name shape" do
      agent =
        compile_agent("""
        flow :sales do
          on :QUOTE, regex: ~r/quote/i do
            reply :quote
          end
        end

        interrupt :CANCEL, regex: ~r/cancel/i do
          reply :cancel
        end
        """)

      assert %Rule{flow: :sales, flow_path: [:sales], global?: false} = rule(agent, :QUOTE)
      assert %Rule{flow: nil, flow_path: [], global?: true} = rule(agent, :CANCEL)
    end

    test "nested flows still route deterministically" do
      agent =
        compile_agent("""
        flow :checkout do
          flow :shipping do
            on :TRACK_PARCEL, regex: ~r/track/i do
              reply :track_parcel
            end
          end
        end
        """)

      input = Input.new("track my parcel")

      assert {:ok, route} =
               Router.route(input, %Spectre.Context{
                 agent: agent,
                 input: input,
                 state: %State{},
                 opts: []
               })

      assert route.accepted?
      assert route.label == :TRACK_PARCEL
      assert route.flow == :shipping
    end

    test "invalid declarations inside a nested flow fail at compile time" do
      assert_raise ArgumentError, ~r/invalid flow declaration/, fn ->
        compile_agent("""
        flow :outer do
          flow :inner do
            reply :not_a_rule
          end
        end
        """)
      end
    end

    test "duplicate labels across nested flows are rejected at compile time" do
      assert_raise ArgumentError, ~r/duplicate_rule_label, :SAME/, fn ->
        compile_agent("""
        flow :outer do
          on :SAME, regex: ~r/one/ do
            reply :one
          end

          flow :inner do
            on :SAME, regex: ~r/two/ do
              reply :two
            end
          end
        end
        """)
      end
    end

    test "nested flows inherit inject declarations from ancestors" do
      agent =
        compile_agent("""
        flow :outer do
          inject :outer_note, into: :context

          on :OUTER_RULE, regex: ~r/outer/ do
            reply :outer
          end

          flow :inner do
            inject :inner_note, into: :context

            on :INNER_RULE, regex: ~r/inner/ do
              reply :inner
            end
          end
        end
        """)

      outer_ids = for injection <- rule(agent, :OUTER_RULE).injections, do: injection.id
      inner_ids = for injection <- rule(agent, :INNER_RULE).injections, do: injection.id

      assert outer_ids == [:outer_note]
      assert inner_ids == [:outer_note, :inner_note]
    end
  end

  describe "current_flow prioritization with nested flows" do
    defp checkout_agent do
      compile_agent("""
      flow :checkout do
        on :PAY_CARD, regex: ~r/pay/i do
          reply :pay_card
        end

        flow :shipping do
          on :TRACK_PARCEL, regex: ~r/track/i do
            reply :track_parcel
          end
        end
      end

      flow :support do
        on :REFUND, regex: ~r/refund/i do
          reply :refund
        end
      end

      interrupt :CANCEL, regex: ~r/cancel/i do
        reply :cancel
      end
      """)
    end

    test "current_flow prioritizes the whole subtree, interrupts stay first" do
      agent = checkout_agent()

      labels =
        agent
        |> Router.candidate_rules(%State{current_flow: :checkout})
        |> Enum.map(& &1.label)

      assert labels == [:CANCEL, :PAY_CARD, :TRACK_PARCEL, :REFUND]
    end

    test "current_flow set to a nested flow prioritizes only that branch" do
      agent = checkout_agent()

      labels =
        agent
        |> Router.candidate_rules(%State{current_flow: :shipping})
        |> Enum.map(& &1.label)

      assert labels == [:CANCEL, :TRACK_PARCEL, :PAY_CARD, :REFUND]
    end

    test "without current_flow the declaration order is preserved" do
      agent = checkout_agent()

      labels =
        agent
        |> Router.candidate_rules(%State{})
        |> Enum.map(& &1.label)

      assert labels == [:CANCEL, :PAY_CARD, :TRACK_PARCEL, :REFUND]
    end
  end

  describe "evaluation flow resolution" do
    test "string current_flow resolves nested flow names" do
      agent =
        compile_agent("""
        flow :checkout do
          flow :shipping do
            on :TRACK_PARCEL, regex: ~r/track/i do
              reply :track_parcel
            end
          end
        end
        """)

      assert {:ok, receipt} =
               Router.evaluate(agent, "track my parcel", state: %{current_flow: "shipping"})

      assert receipt.label == :TRACK_PARCEL
    end
  end

  describe "label_tree/2" do
    test "groups labels under their flow path" do
      agent =
        compile_agent("""
        flow :checkout do
          on :PAY_CARD, regex: ~r/card/i do
            reply :pay_card
          end

          flow :shipping do
            on :TRACK_PARCEL, regex: ~r/track/i do
              reply :track_parcel
            end
          end
        end

        flow :support do
          on :REFUND, regex: ~r/refund/i do
            reply :refund
          end
        end

        interrupt :CANCEL, regex: ~r/cancel/i do
          reply :cancel
        end
        """)

      rules = compiled_rules(agent)
      labels = Enum.map(rules, & &1.label)

      assert LLMClassifier.label_tree(labels, rules) ==
               String.trim_trailing("""
               CANCEL
               checkout/
                 PAY_CARD
                 shipping/
                   TRACK_PARCEL
               support/
                 REFUND
               """)
    end

    test "renders a flat list when no rule declares a flow" do
      rules = [
        Rule.new(%{label: :PING, regex: ~r/ping/}),
        Rule.new(%{label: :HELP, regex: ~r/help/})
      ]

      assert LLMClassifier.label_tree([:PING, :HELP], rules) == "PING\nHELP"
    end

    test "labels without a matching rule stay at the root level" do
      rules = [Rule.new(%{label: :KNOWN, flow: :sales, regex: ~r/known/})]

      assert LLMClassifier.label_tree([:KNOWN, :UNKNOWN], rules) ==
               "UNKNOWN\nsales/\n  KNOWN"
    end

    test "labels carry declared example phrases, capped and deduplicated" do
      rules = [
        Rule.new(%{
          label: :PAY_CARD,
          flow_path: [:checkout],
          embedding: ["pay by card", "use my visa", "third example"]
        }),
        Rule.new(%{label: :REFUND, flow_path: [:support], bag: ["i want a refund"]})
      ]

      tree = LLMClassifier.label_tree([:PAY_CARD, :REFUND], rules)

      assert tree ==
               String.trim_trailing("""
               checkout/
                 PAY_CARD — e.g. "pay by card"; "use my visa"
               support/
                 REFUND — e.g. "i want a refund"
               """)

      refute tree =~ "third example"
    end

    test "examples can be disabled" do
      rules = [Rule.new(%{label: :PAY_CARD, flow_path: [:checkout], embedding: ["pay by card"]})]

      assert LLMClassifier.label_tree([:PAY_CARD], rules, examples: 0) ==
               "checkout/\n  PAY_CARD"
    end
  end

  describe "classifier prompt context" do
    test "classify renders agent context, active flow and label examples" do
      rules = [
        Rule.new(%{
          label: :PAY_CARD,
          flow_path: [:checkout],
          embedding: ["pay by card", "use my visa"]
        }),
        Rule.new(%{
          label: :TRACK_PARCEL,
          flow_path: [:checkout, :shipping],
          embedding: ["where is my parcel?"]
        }),
        Rule.new(%{label: :REFUND, flow_path: [:support], bag: ["i want a refund"]})
      ]

      test_pid = self()

      model = fn prompt, _opts ->
        send(test_pid, {:classifier_prompt, prompt})
        {:ok, "REFUND"}
      end

      assert {:ok, route} =
               LLMClassifier.classify(
                 "give me my money back",
                 [:PAY_CARD, :TRACK_PARCEL, :REFUND],
                 model: model,
                 spectre_rules: rules,
                 classifier: [context: "Support agent for the Acme web shop."],
                 classifier_assigns: %{state: %State{current_flow: :shipping}}
               )

      assert route.label == :REFUND
      assert_received {:classifier_prompt, prompt}

      assert prompt =~ "Available labels, grouped by conversation flow."
      assert prompt =~ "The quoted phrases after a label are examples"
      assert prompt =~ ~s(PAY_CARD — e.g. "pay by card"; "use my visa")
      assert prompt =~ "Agent context:\nSupport agent for the Acme web shop."
      assert prompt =~ "Active conversation flow: checkout/shipping"
      assert prompt =~ "Prefer labels inside this flow"
    end

    test "a flat agent without flows keeps the plain prompt sections" do
      rules = [
        Rule.new(%{label: :PING, regex: ~r/ping/}),
        Rule.new(%{label: :HELP, regex: ~r/help/})
      ]

      test_pid = self()

      model = fn prompt, _opts ->
        send(test_pid, {:classifier_prompt, prompt})
        {:ok, "HELP"}
      end

      assert {:ok, _route} =
               LLMClassifier.classify("how does this work?", [:PING, :HELP],
                 model: model,
                 spectre_rules: rules
               )

      assert_received {:classifier_prompt, prompt}

      assert prompt =~ "Available labels:\nPING\nHELP"
      refute prompt =~ "grouped by conversation flow"
      refute prompt =~ "Agent context:"
      refute prompt =~ "Active conversation flow:"
    end
  end
end
