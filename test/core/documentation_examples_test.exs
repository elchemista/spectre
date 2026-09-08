defmodule Spectre.CoreTest.DocumentationExamplesTest do
  use ExUnit.Case, async: false

  alias Spectre.Agent.{Flow, Prompt, Publication, Turn}
  alias Spectre.Agent.Runtime, as: AgentRuntime
  alias Spectre.Input.{Pipeline, Plugs.NormalizeText}
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Exact
  alias Spectre.SemanticCache.Test.CustomerSupport
  alias Spectre.Test.{Documentation, DocumentationRuntime}
  alias Spectre.V04Test.{Fixture, Runtime}

  @moduletag capture_log: true
  @examples ~w(application_store input_pipeline checkout_dependency dynamic_domain
    readme_agent readme_instance guide_agent guide_instance extracted_router prompts
    exact_cache_declaration cache_wiring native_cache_declaration native_cache_child
    foundation supervised_domain doctor_config pending_operation direct_handler draft_agent
    classifier_agent reusable_components lookup_bindings complete_authoring routing_evaluation routed_handler)

  test "every published Elixir block has an explicit tested context" do
    assert Documentation.examples!() |> Map.keys() |> Enum.sort() == Enum.sort(@examples)
  end

  test "removing a marker fails verification instead of silently dropping the example" do
    markdown = "<!-- spectre:example example -->\n```elixir\n:ok\n```"
    assert [%{name: "example"}] = Documentation.parse!(markdown, "guide.md")

    assert_raise RuntimeError, ~r/Unverified Elixir example/, fn ->
      Documentation.parse!(
        String.replace(markdown, "<!-- spectre:example example -->\n", ""),
        "guide.md"
      )
    end
  end

  test "standalone storage and pipeline examples run; dependency tuple is valid" do
    Documentation.eval!("application_store")
    Documentation.eval!("input_pipeline")
    assert {{:spectre, path: "../spectre"}, []} = Documentation.eval!("checkout_dependency")
  end

  test "routing evaluation guide runs against the real Router without agent execution" do
    assert {0, bindings} = Documentation.eval!("routing_evaluation")
    assert %{total: 2, passed: 2, failed: 0} = Keyword.fetch!(bindings, :report)
  end

  test "the routed handler guide derives its actual request from input, not a hand-written message" do
    assert {{:request, "orders.lookup", %{"order_id" => "42"}, %{}}, _bindings} =
             Documentation.eval!("routed_handler")
  end

  for {agent_example, instance_example} <- [
        {"readme_agent", "readme_instance"},
        {"guide_agent", "guide_instance"}
      ] do
    test "#{agent_example} publishes and #{instance_example} actually executes one governed lookup" do
      {definition, _} =
        Documentation.eval!(unquote(agent_example), published_at: Fixture.default_now())

      assert {:ok, _, _} = Spectre.Agent.verify_definition(MyApp.Orders, definition)
      {fixture, bindings} = DocumentationRuntime.activate(definition)
      {reply, binding} = Documentation.eval!(unquote(instance_example), bindings)
      instance = Keyword.fetch!(binding, :instance)
      on_exit(fn -> Fixture.stop_process(instance) end)

      assert completed_status(reply) == :done
      assert %{value: %{last_status: :done}, revision: 2} = Spectre.Instance.state(instance)
      assert_receive {:handler_execution, _, act, _attempt}
      assert act.consequence == %{"order_id" => "42"}
      refute_receive {:handler_execution, _, _, _}

      # A perfectly matched route is still not authority for a different order.
      assert {:ok, denied} = Spectre.Instance.turn(instance, "order 43", flow: :orders)
      assert [request] = denied.requests
      assert {:ok, refused} = Spectre.Instance.advance(instance, request)
      assert refused.result.status == :refused
      refute_receive {:handler_execution, _, _, _}

      assert {:error, :clarification_needed} =
               Spectre.Instance.turn(instance, "unrelated question", flow: :orders)

      if unquote(agent_example) == "guide_agent" do
        assert {:ok, help} = Spectre.Instance.turn(instance, "help with orders", flow: :orders)
        assert [request] = help.requests
        assert {:ok, completed} = Spectre.Instance.advance(instance, request)
        assert completed.result.status == :done
        assert_receive {:handler_execution, _, %{class: "support.help"}, _}
      end

      assert_replay(fixture)
    end
  end

  test "extracted router actually uses both normalization and an application matcher" do
    Documentation.eval!("extracted_router")
    definition = publish(MyApp.RoutedOrders)
    {:ok, pipeline} = Pipeline.new([{NormalizeText, case: :downcase}])

    assert {:ok, runtime, _} =
             AgentRuntime.new(
               MyApp.RoutedOrders,
               definition,
               [pipelines: [normalize: pipeline]],
               %{},
               %{}
             )

    flow = runtime.flows["orders"].prepared
    assert {:ok, %{via: "binary", candidate: "help"}} = Flow.route(flow, " HELP ")
    assert {:ok, %{via: "regex", matched: %{"id" => "42"}}} = Flow.route(flow, "ORDER 42")
    assert :no_match = Flow.route(flow, "unrelated")
  end

  test "prompt fragment compiles the distributed file and renders injection and task" do
    Documentation.eval!("prompts", [], within: MyApp.GuidePrompts)
    definition = publish(MyApp.GuidePrompts)
    {:ok, plan, %{}} = Publication.verify(MyApp.GuidePrompts, definition)
    owner = %{module: MyApp.GuidePrompts, plan: plan}

    turn = %Turn{
      ref: "turn:guide",
      definition_ref: definition.ref,
      flow: nil,
      branch: nil,
      owner: "",
      input: "Where is my order?",
      mind_turn: nil,
      context: %{history: [], memory: []}
    }

    assert {:ok, rendered} =
             Prompt.render(owner, turn, :answer, %{order_id: "42", question: turn.input})

    assert Enum.map(rendered["parts"], & &1["name"]) == ["safety", "system", "question"]
    assert Enum.at(rendered["parts"], 1)["text"] =~ "You help people understand orders."
    assert List.last(rendered["parts"])["text"] == "Order 42: Where is my order?"

    assert {:error, {:missing_prompt_assign, "question", :order_id}} =
             Prompt.render(owner, turn, :answer, %{question: turn.input})
  end

  test "cache declaration and startup wiring really bind reviewable routing" do
    Documentation.eval!("exact_cache_declaration", [], within: MyApp.CachedOrders)
    definition = publish(MyApp.CachedOrders)
    binding = cache_binding(definition, nil)

    start_supervised!(
      {Exact,
       [name: MyApp.Cache, labels: ["support/lookup"], max_entries: 2_000] ++ Map.to_list(binding)}
    )

    {adapters, _} = Documentation.eval!("cache_wiring")

    assert {:ok, runtime, _} =
             AgentRuntime.new(MyApp.CachedOrders, definition, adapters, %{}, %{})

    {:ok, cache} = SemanticCache.bind({Exact, server: MyApp.Cache}, binding)
    {:ok, example} = SemanticCache.put(cache, %{text: "find my order", label: "support/lookup"})
    flow = runtime.flows["support"].prepared
    assert :no_match = Flow.route(flow, "find my order")
    assert {:ok, _} = SemanticCache.verify(cache, example.id, example.revision)

    assert {:ok, %{via: "semantic_cache", candidate: "lookup"}} =
             Flow.route(flow, "find my order")

    assert {:ok, %{via: "regex"}} = Flow.route(flow, "order 42")

    wrong = put_in(adapters, [:semantic_cache, :routing, :namespace], "another-tenant")

    assert {:error, :cache_binding_mismatch} =
             AgentRuntime.new(MyApp.CachedOrders, definition, wrong, %{}, %{})
  end

  test "supplied Vettore child spec starts and queries real model vectors" do
    Documentation.eval!("native_cache_declaration", [], within: MyApp.NativeCache)
    definition = publish(MyApp.NativeCache)
    profile = %{ref: CustomerSupport.profile()}

    {child, _} =
      Documentation.eval!("native_cache_child",
        published_definition: definition,
        encoder_profile: profile
      )

    server = start_supervised!(child)
    binding = cache_binding(definition, profile.ref)
    {:ok, cache} = SemanticCache.bind({Spectre.SemanticCache.Vettore, server: server}, binding)
    {:ok, 384} = ExFastembed.load(CustomerSupport.model())
    text = "Where is the order I placed last week?"
    query = "Can you find my recent purchase?"
    {:ok, [example_vector, query_vector]} = ExFastembed.embed_text([text, query])

    {:ok, example} =
      SemanticCache.put(cache, %{
        text: text,
        label: "support/lookup",
        embedding: example_vector,
        profile_ref: profile.ref
      })

    assert {:ok, _} = SemanticCache.verify(cache, example.id, example.revision)

    assert {:ok, [%{label: "support/lookup", score: score}]} =
             SemanticCache.lookup(cache, %{
               text: query,
               vector: query_vector,
               profile_ref: profile.ref,
               labels: ["support/lookup"]
             })

    assert score > 0.5

    assert {:error, :embedding_required} =
             SemanticCache.lookup(cache, %{text: query, labels: ["support/lookup"]})
  end

  @tag :tmp_dir
  test "foundation and OTP fragments start the real store then its Domain", %{tmp_dir: directory} do
    fixture = DocumentationRuntime.fixture()
    bindings = DocumentationRuntime.host_bindings(fixture)
    {foundation, _} = Documentation.eval!("foundation", bindings)
    assert foundation[:genesis] === fixture.genesis
    Fixture.stop_domain(fixture)
    bindings = bindings ++ [foundation: foundation, directory: directory]
    {{:ok, supervisor}, _} = Documentation.eval!("supervised_domain", bindings)
    on_exit(fn -> Fixture.stop_process(supervisor) end)
    assert {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
    assert is_pid(Spectre.Domain.whereis(domain.ref))

    assert {:ok, _} =
             Spectre.Ledger.load(
               {Spectre.Ledger.Store.Disk, server: MyApp.LedgerStore},
               domain.ref
             )

    assert length(Supervisor.which_children(supervisor)) == 2
  end

  test "README dynamic wiring authenticates and does not turn an unsupported proposal into an Act" do
    fixture = DocumentationRuntime.fixture()
    input = Fixture.refund_candidate(fixture, 100, evidence_refs: [])

    input =
      input
      |> Map.drop([:proposer_ref, :scope_ref])
      |> Map.update!(:row, &Spectre.Row.canonical/1)

    bindings = DocumentationRuntime.host_bindings(fixture)
    Fixture.stop_domain(fixture)

    bindings =
      bindings ++
        [
          mind: DocumentationRuntime.Mind,
          now: Runtime.now(),
          scope_ref: fixture.refs.scope,
          authenticated_request: %{
            principal_ref: fixture.refs.proposer,
            authentication_ref: fixture.refs.authentication,
            session_ref: fixture.refs.session
          },
          input: input,
          select_proposal: fn [candidate] -> candidate end
        ]

    {{:ok, result}, binding} = Documentation.eval!("dynamic_domain", bindings)
    domain = Keyword.fetch!(binding, :domain)
    store = Keyword.fetch!(binding, :store_pid)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(
        Spectre.Domain.Supervisor,
        Spectre.Domain.whereis(domain.ref)
      )

      Fixture.stop_process(store)
    end)

    assert result.primary.decision.outcome == :undecidable
    assert result.primary.act == nil
    refute_receive {:handler_execution, _, _, _}
  end

  test "doctor snippet is a real Config expression, not a second configuration API" do
    example = Documentation.examples!()["doctor_config"]

    config =
      Config.Reader.eval!(example.file, "import Config\nwired_ports = []\n" <> example.code)

    assert config[:spectre][:doctor] == [
             ingress: MyApp.Ingress,
             port_wiring: %{MyApp.SupportAgent => []}
           ]
  end

  test "streaming fragment hands back a ticket and polling cannot resubmit its effect" do
    {definition, _} = Documentation.eval!("guide_agent", published_at: Fixture.default_now())
    {fixture, bindings} = DocumentationRuntime.activate(definition)

    instance =
      start_supervised!(
        {Spectre.Instance,
         [
           agent: MyApp.Orders,
           bindings: bindings[:class_bindings],
           scope: bindings[:scope],
           definition: definition,
           state: %{}
         ]}
      )

    {reply, variables} =
      Documentation.eval!("pending_operation",
        instance: instance,
        input: "order 42",
        flow: :orders
      )

    request = Keyword.fetch!(variables, :chosen)
    assert match?({:watch, _}, reply) or match?({:completed, _}, reply)
    assert_receive {:handler_execution, _, act, _attempt}, 1_000
    assert act.consequence == %{"order_id" => "42"}
    assert {:ok, turn} = await_operation(instance, request.ref, 50)
    assert turn.result.status == :done
    assert Spectre.Instance.operation(instance, request.ref) == {:ok, turn}

    assert {:error, :invalid_or_superseded_instance_request} =
             Spectre.Instance.advance(instance, request)

    refute_receive {:handler_execution, _, _, _}
    assert_replay(fixture)
  end

  defp await_operation(instance, ref, remaining) when remaining > 0 do
    case Spectre.Instance.operation(instance, ref) do
      {:pending, ^ref} ->
        receive do
        after
          10 -> await_operation(instance, ref, remaining - 1)
        end

      complete ->
        complete
    end
  end

  defp await_operation(_instance, _ref, 0), do: flunk("operation did not complete")

  defp completed_status({:ok, turn}), do: turn.result.status
  defp completed_status({:completed, result}), do: result.status

  # These modules are compiled from the actual Markdown during each test.
  defp publish(module), do: module.definition(revision: 1, declared_at: 0)

  defp cache_binding(definition, profile),
    do: %{
      namespace: "tenant-a/support",
      definition_ref: definition.ref,
      flow: "support",
      profile_ref: profile
    }

  defp assert_replay(fixture) do
    {:ok, export} = Spectre.Ledger.export(fixture.store_config, fixture.refs.domain)
    assert {:ok, _} = Spectre.Audit.verify(export, fixture.constitution, Runtime.now())
  end
end
