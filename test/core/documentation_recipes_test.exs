defmodule Spectre.CoreTest.DocumentationRecipesTest do
  use ExUnit.Case, async: false

  alias Spectre.Agent.{Classification, Flow, Prompt, Publication, RequestBuilder, Turn}
  alias Spectre.Agent.Runtime, as: AgentRuntime
  alias Spectre.{Instance, Surface}
  alias Spectre.Test.{Documentation, DocumentationRuntime}
  alias Spectre.V04Test.{Fixture, Runtime}

  @moduletag capture_log: true

  test "the complete guide example is exactly the distributed source and compiles in its declared location" do
    path = Path.expand("../../examples/authoring.exs", __DIR__)

    assert Documentation.examples!()["complete_authoring"].code ==
             String.trim_trailing(File.read!(path))

    {{:module, publication, _, _}, _} = Documentation.eval!("complete_authoring", [], file: path)
    definitions = publication.definitions(Fixture.default_now())

    assert {:ok, _, %{"faq" => _}} =
             Publication.verify(Spectre.Example.Support, definitions.agent)

    assert {:ok, _, %{}} = Publication.verify(Spectre.Example.OrderWorker, definitions.worker)
    assert {:ok, _, %{}} = Publication.verify(Spectre.Example.QueueVigil, definitions.vigil)
  end

  test "the no-Router recipe handles local state and governs a structured lookup" do
    Documentation.eval!("direct_handler")
    definition = publish(MyApp.DirectOrders)
    {fixture, bindings} = DocumentationRuntime.activate(definition)

    instance =
      start_supervised!(
        {MyApp.DirectOrders,
         Keyword.take(bindings, [:scope, :definition]) ++
           [bindings: bindings[:class_bindings], state: %{}]}
      )

    assert {:ok, %{requests: []}} = Instance.turn(instance, %{"note" => "Call after lunch"})
    assert %{value: %{note: "Call after lunch"}} = Instance.state(instance)
    refute_receive {:handler_execution, _, _, _}

    assert {:ok, %{requests: [request]}} = Instance.turn(instance, %{"order_id" => "42"})
    refute_receive {:handler_execution, _, _, _}
    assert {:ok, %{result: %{status: :done}}} = Instance.advance(instance, request)
    assert_receive {:handler_execution, _, %{consequence: %{"order_id" => "42"}}, _}

    assert {:error, :unsupported_input} = Instance.turn(instance, %{"order_id" => 42})
    refute_receive {:handler_execution, _, _, _}
    assert_replay(fixture)
  end

  test "the documented class bindings execute only the target covered by the actual Mandate" do
    Documentation.eval!("direct_handler")
    definition = publish(MyApp.DirectOrders)
    {fixture, binding} = DocumentationRuntime.activate(definition)
    [mandate] = fixture.additional_mandates
    occurrence = binding[:class_bindings]["orders.lookup"]

    {class_bindings, variables} =
      Documentation.eval!(
        "lookup_bindings",
        [lookup_mandate: mandate] ++
          Map.to_list(Map.drop(occurrence, [:requested_mandate_ref, :observation_window_ms]))
      )

    surface = variables[:lookup_surface]
    assert {:ok, row} = Surface.classify(surface, "orders.lookup")
    assert Spectre.Row.dimensions(row) == [:attempt, :read]
    assert {:error, :unknown_class} = Surface.classify(surface, "orders.delete")
    assert class_bindings["orders.lookup"] === occurrence

    instance =
      start_supervised!(
        {MyApp.DirectOrders,
         [scope: binding[:scope], definition: definition, bindings: class_bindings, state: %{}]}
      )

    assert {:ok, %{requests: [allowed]}} = Instance.turn(instance, %{"order_id" => "42"})
    assert allowed.candidate.row == row
    assert allowed.candidate.target_refs == ["42"]
    assert :ok = Surface.validate_consequence(surface, allowed.candidate)
    assert {:ok, %{result: %{status: :done}}} = Instance.advance(instance, allowed)
    assert_receive {:handler_execution, _, _, _}

    assert {:ok, %{requests: [denied]}} = Instance.turn(instance, %{"order_id" => "43"})
    assert {:ok, %{result: %{status: :refused}}} = Instance.advance(instance, denied)
    refute_receive {:handler_execution, _, _, _}
    assert_replay(fixture)
  end

  test "the model recipe renders and prepares the advertised data without calling a model" do
    {{:module, agent, _, _}, _} = Documentation.eval!("draft_agent")
    definition = publish(MyApp.DraftAssistant)
    {:ok, plan, %{}} = Publication.verify(MyApp.DraftAssistant, definition)
    owner = %{module: MyApp.DraftAssistant, plan: plan}
    turn = turn(definition)
    question = "Can you explain how to find my order?"

    assert {:ask, :reply, assigns, %{}} = agent.handle_turn(question, turn, %{})
    assert {:ok, rendered} = Prompt.render(owner, turn, :reply, assigns)
    assert Enum.map(rendered["parts"], & &1["name"]) == ["policy", "question"]
    assert List.last(rendered["parts"])["text"] == "Customer question: " <> question
    assert rendered["configuration"][:model_ref] == "support-writer"
    assert rendered["configuration"][:max_tokens] == 300

    assert {:ok, %{class: "model.generate", consequence: ^rendered}} =
             RequestBuilder.prepare({:ask, :reply}, rendered, turn,
               declaration: plan.asks["reply"]
             )

    # This is a rendering/contract test, not a fabricated provider integration.
    # The guide makes the host's model executor and result shape prerequisites.
    assert {:ok, %{draft: "An observed draft"}} =
             agent.handle_result(
               {:ask, :reply},
               %{status: :done, data: "An observed draft"},
               turn,
               %{}
             )

    assert {:ok, %{last_status: :unclear}} =
             agent.handle_result(
               {:ask, :reply},
               %{status: :unclear, data: nil},
               turn,
               %{}
             )
  end

  test "the classifier recipe skips inference on an exact route and stops after an uncertain classification" do
    {{:module, agent, _, _}, _} = Documentation.eval!("classifier_agent")
    definition = publish(MyApp.IntentAssistant)
    assert {:ok, runtime, _} = AgentRuntime.new(MyApp.IntentAssistant, definition, [], %{}, %{})
    flow = runtime.flows["support"]
    assert {:ok, %{candidate: "help", via: "regex"}} = Flow.route(flow.prepared, "help")
    assert :no_match = Flow.route(flow.prepared, "I need to speak to someone")

    turn = %{
      turn(definition)
      | flow: :support,
        routing: %{name: "support", declaration: flow.declaration}
    }

    assert {:classify, :intent, input, %{}} =
             agent.handle_turn({:support, :no_match, turn.input}, turn, %{})

    owner = %{plan: agent.__spectre_plan__()}
    assert {:ok, payload} = Classification.prepare(owner, turn, :intent, input)
    assert payload["labels"] == ["support/contact", "support/help"]

    for {labels, expected} <- [
          {[%{"label" => "support/help", "score" => 0.95}],
           {:request, "support.help", %{"target_ref" => "support:help"}, %{}}},
          {[%{"label" => "support/help", "score" => 0.2}], {:error, :clarification_needed, %{}}},
          {[
             %{"label" => "support/help", "score" => 0.95},
             %{"label" => "support/contact", "score" => 0.95}
           ], {:error, :clarification_needed, %{}}}
        ] do
      result = %{
        status: :done,
        turn_ref: turn.ref,
        operation: {:classify, :intent},
        data: %{"labels" => labels}
      }

      completed = %{turn | result: result}

      assert agent.handle_result({:classify, :intent}, result, completed, %{}) ==
               expected
    end
  end

  test "the reusable component example pins its Skill and runs it in the parent Instance" do
    {definition, _} =
      Documentation.eval!("reusable_components", published_at: Fixture.default_now())

    assert {:ok, plan, children} = Publication.verify(MyApp.SupportTeam, definition)
    assert children["faq"] == publish(MyApp.HelpSkill)
    assert plan.jobs["orders"].kind == :worker
    assert plan.jobs["queue"].kind == :vigil
    Process.register(self(), MyApp.Metrics)

    {fixture, bindings} = DocumentationRuntime.activate(definition)

    instance =
      start_supervised!(
        {MyApp.SupportTeam,
         [
           scope: bindings[:scope],
           definition: definition,
           bindings: bindings[:class_bindings],
           state: %{}
         ]}
      )

    assert {:ok, %{requests: [request]}} =
             Instance.turn(instance, "help with orders", flow: "faq/questions")

    assert {:ok, %{result: %{status: :done}}} = Instance.advance(instance, request)
    assert_receive {:handler_execution, _, _, _}
    assert_receive {:spectre_agent_event, [:spectre, :agent | _], _, _}

    assert %{value: %{}, components: %{"faq" => %{value: %{last_status: :done}}}} =
             Instance.state(instance)

    assert_replay(fixture)
  end

  test "the README assistant renders its prompt locally and delivers as a separate effect" do
    {{:module, agent, _, _}, _} = Documentation.eval!("readme_assistant")
    definition = publish(MyApp.Assistant)
    {:ok, plan, %{}} = Publication.verify(MyApp.Assistant, definition)
    owner = %{module: MyApp.Assistant, plan: plan}
    turn = turn(definition)

    assert {:ask, :answer, assigns, %{}} =
             agent.handle_turn(
               {:support, :question, %{"text" => "Where is my order?"}},
               turn,
               %{}
             )

    # Rendering is local and ordered: system policy first, task second.
    assert {:ok, rendered} = Prompt.render(owner, turn, :answer, assigns)
    assert Enum.map(rendered["parts"], & &1["name"]) == ["policy", "question"]
    assert List.last(rendered["parts"])["text"] == "Customer asked: Where is my order?"

    # A completed inference proposes delivery; returning text never delivers it.
    assert {:request, "chat.send", %{"text" => "It ships today."}, %{}} =
             agent.handle_result(
               {:ask, :answer},
               %{status: :done, data: %{"text" => "It ships today."}},
               turn,
               %{}
             )
  end

  defp publish(module), do: module.definition(revision: 1, declared_at: Fixture.default_now())

  defp turn(definition),
    do: %Turn{
      ref: "turn:documented-recipe",
      definition_ref: definition.ref,
      input: "Help with my order",
      flow: nil,
      owner: "",
      mind_turn: nil,
      context: %{history: [], memory: []}
    }

  defp assert_replay(fixture) do
    {:ok, export} = Spectre.Ledger.export(fixture.store_config, fixture.refs.domain)
    assert {:ok, _} = Spectre.Audit.verify(export, fixture.constitution, Runtime.now())
  end
end
