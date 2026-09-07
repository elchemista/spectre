defmodule Spectre.CoreTest.AgentFlowTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Definition, Router}
  alias Spectre.Agent.Flow
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText

  defmodule BinaryMatcher do
    use Spectre.Router.Adapter
    @impl true
    def evaluate(request, opts) do
      if opts[:observer], do: send(opts[:observer], :matcher_called)
      {:ok, for(rule <- request.rules, rule.data === request.input, do: result(rule, 1.0))}
    end
  end

  defmodule StopPlug do
    @behaviour Spectre.Input.Plug
    @impl true
    def call(value, opts), do: {Keyword.fetch!(opts, :status), value}
  end

  defmodule Billing do
    use Spectre.Skill, namespace: "flows", name: "billing", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue")

    flow "request" do
      pipe_through("text")
      router(via: [:regex])
      route("refund", to: "refund", match: %{regex: ~r/^refund$/})
    end
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "flows", name: "assistant", revision: 1, declared_at: 0
    install(Billing, as: "billing")
    candidate("order", class: "order.lookup")
    candidate("status", class: "device.status")
    router(via: [:regex])
    route("root", to: "order", match: %{regex: ~r/^root$/})

    flow "support" do
      pipe_through("text")
      router(via: [:regex, :string_bag])

      route("order",
        to: "order",
        match: %{regex: ~r/^order (?<id>[0-9]+)$/, string_bag: ["find my order"]}
      )

      flow "raw" do
      end
    end

    flow "device" do
      router(via: [:binary])
      route("status", to: "status", match: %{binary: <<0, 1>>})
    end

    flow "ambiguous" do
      router(via: [:regex])
      route("first", to: "order", match: %{regex: ~r/.*/})
      route("second", to: "status", match: %{regex: ~r/.*/})
    end
  end

  test "flows keep independent methods and normalization, while root routing still works" do
    {:ok, text} = Pipeline.new([{NormalizeText, case: :downcase}])
    assert {:ok, support} = Assistant.flow("support", pipelines: %{"text" => text})

    assert {:ok, %{candidate: "order", via: "regex", matched: %{"id" => "42"}}} =
             Flow.route(support, "  ORDER 42  ")

    assert {:ok, %{via: "string_bag"}} = Flow.route(support, "find my order")
    assert :no_match = Flow.route(support, "ROOT")
    assert {:ok, root} = Assistant.router()
    assert {:ok, %{rule: "root"}} = Router.route(root, "root")

    assert {:ok, device} = Assistant.flow("device", adapters: [binary: BinaryMatcher])
    assert {:ok, %{candidate: "status", via: "binary"}} = Flow.route(device, <<0, 1>>)
    assert :no_match = Flow.route(device, "find my order")
  end

  test "nested names do not silently inherit a parent router or pipeline" do
    assert {:ok, plain} = Assistant.flow("support/raw")
    assert {:unrouted, "  ROOT  "} = Flow.route(plain, "  ROOT  ")
  end

  test "Skill installation namespaces flows, pipeline bindings and Candidate targets together" do
    {:ok, text} = Pipeline.new([{NormalizeText, case: :downcase}])

    assert {:error, {:unwired_flow_pipeline, "billing/text"}} =
             Assistant.flow("billing/request", pipelines: %{"text" => text})

    assert {:ok, billing} =
             Assistant.flow("billing/request", pipelines: %{"billing/text" => text})

    assert {:ok, %{candidate: "billing/refund"}} = Flow.route(billing, "REFUND")
  end

  test "portable definitions do not load pipeline or matcher modules after a round trip" do
    definition = Assistant.definition()
    assert definition.body["format"] == "spectre-agent-declaration-v2"
    assert {:ok, restored} = definition |> Definition.canonical() |> Definition.from_canonical()
    assert restored === definition
    refute inspect(restored.body) =~ "BinaryMatcher"
    assert {:error, {:unknown_router_method, "binary"}} = Agent.flow(restored, "device", [])
    assert {:error, {:unwired_flow_pipeline, "text"}} = Agent.flow(restored, "support", [])
    assert Assistant.flows() == definition.body["flows"]
  end

  test "unknown flows, malformed registries and invalid bindings fail explicitly" do
    assert {:error, {:unknown_agent_flow, "missing"}} = Assistant.flow("missing")
    assert {:error, :invalid_flow_pipeline_registry} = Assistant.flow("support", pipelines: [])

    assert {:error, {:invalid_flow_pipeline, "text"}} =
             Assistant.flow("support", pipelines: %{"text" => NormalizeText})

    assert {:error, _} = Assistant.flow("device", via: [:regex])
  end

  test "pipeline halt and failure remain distinct from a router miss or ambiguity" do
    for status <- [:halt, :error] do
      {:ok, pipeline} = Pipeline.new([{StopPlug, status: status}])
      assert {:ok, support} = Assistant.flow("support", pipelines: %{"text" => pipeline})

      if status == :halt do
        assert {:halt, "order 42"} = Flow.route(support, "order 42")
      else
        assert {:error, {:input_plug_failed, StopPlug, "order 42"}} =
                 Flow.route(support, "order 42")
      end
    end

    assert {:ok, ambiguous} = Assistant.flow("ambiguous")
    assert {:ambiguous, ["first", "second"]} = Flow.route(ambiguous, "anything")
  end

  test "input resource limits reject oversized values before custom matchers run" do
    {:ok, flow} = Assistant.flow("device", adapters: [binary: {BinaryMatcher, observer: self()}])
    assert {:error, _} = Flow.route(flow, :binary.copy("x", 65_537))
    refute_receive :matcher_called
    assert {:ok, _} = Flow.route(flow, <<0, 1>>)
    assert_receive :matcher_called
  end

  test "flow schema rejects unknown fields, malformed paths and nonexistent templates" do
    original = Assistant.definition()

    for flow <- [
          %{"pipelines" => [], "authority" => "grant"},
          %{"pipelines" => ["a", "a"]},
          %{"pipelines" => ["a//b"]},
          %{"pipelines" => [], "routing" => %{"rules" => %{}, "config" => %{}}},
          put_in(
            original.body["flows"]["support"],
            ["routing", "rules", "order", "to"],
            "missing"
          )
        ] do
      body = put_in(original.body, ["flows", "support"], flow)
      assert {:ok, changed} = Definition.revise(original, body, 1)
      assert {:error, _} = Agent.flow(changed, "support", [])
    end
  end

  test "DSL diagnoses duplicate and misplaced declarations at their source" do
    for body <- [
          "flow \"a\" do end\nflow \"a\" do end",
          "pipe_through \"a\"",
          "flow \"a\" do\npipe_through []\npipe_through []\nend",
          "flow \"a\" do\nrouter via: [:regex]\nrouter via: [:regex]\nend",
          "flow \"a\" do\ncandidate \"x\", class: \"x\"\nend",
          "flow \"a\" do\nroute \"r\", to: \"missing\", match: %{regex: \".*\"}\nend"
        ] do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule Spectre.InvalidFlowDeclaration do
          use Spectre.Agent, namespace: "test", name: "bad-flow", revision: 1, declared_at: 0
          #{body}
        end
        """)
      end
    end
  end
end
