defmodule Spectre.CoreTest.AgentFlowTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Definition}
  alias Spectre.Agent.{Flow, Wiring}
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
    use Spectre.Skill, namespace: "flows", name: "billing"
    use Spectre.Test.Authoring

    flow :refunds do
      pipe_through(:text)
      router(via: [:regex])
      route(:refund, match: [regex: ~r/^refund$/])
    end
  end

  defmodule Routes do
    use Spectre.Router

    flow :support do
      pipe_through(:text)
      router(via: [:regex, :string_bag])
      route(:order, match: [regex: ~r/^order (?<id>[0-9]+)$/, string_bag: ["find my order"]])
    end
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "flows", name: "assistant"
    use Spectre.Test.Authoring
    skill(Billing, as: :billing)
    router(Routes)

    flow :raw do
    end

    flow :device do
      router(via: [:binary])
      route(:status, match: [binary: <<0, 1>>])
    end

    flow :uncertain do
      router(via: [:regex])
      route(:first, match: [regex: ~r/.*/])
      route(:second, match: [regex: ~r/.*/])
    end
  end

  defmodule Inline do
    use Spectre.Agent, namespace: "flows", name: "inline"

    flow :support do
      pipe_through(:text)
      router(via: [:regex, :string_bag])
      route(:order, match: [regex: ~r/^order (?<id>[0-9]+)$/, string_bag: ["find my order"]])
    end
  end

  test "inline and extracted flows have one identical declaration and independent code pins" do
    assert Assistant.__spectre_plan__().flows["support"] ===
             Inline.__spectre_plan__().flows["support"]

    assert {:ok, _, _} = Agent.verify_definition(Assistant, Assistant.definition())
    assert {:error, _} = Agent.verify_definition(Inline, Assistant.definition())
  end

  test "independent flow policies use the same low-level Pipeline and Router" do
    {:ok, text} = Pipeline.new([{NormalizeText, case: :downcase}])
    {:ok, support} = flow("support", pipelines: %{"text" => text})

    assert {:ok, %{candidate: "order", via: "regex", matched: %{"id" => "42"}}} =
             Flow.route(support, "  ORDER 42  ")

    assert {:ok, %{via: "string_bag"}} = Flow.route(support, "find my order")
    assert :no_match = Flow.route(support, "unrelated")

    {:ok, device} = flow("device", adapters: [binary: BinaryMatcher])
    assert {:ok, %{candidate: "status", via: "binary"}} = Flow.route(device, <<0, 1>>)
    assert :no_match = Flow.route(device, "find my order")
    {:ok, raw} = flow("raw")
    assert {:unrouted, "  RAW  "} = Flow.route(raw, "  RAW  ")
  end

  test "Skill pipeline and rule refs are namespaced without inheriting parent policy" do
    {:ok, text} = Pipeline.new([{NormalizeText, case: :downcase}])

    assert {:error, {:unwired_flow_pipeline, "billing/text"}} =
             flow("billing/refunds", pipelines: %{"text" => text})

    {:ok, billing} = flow("billing/refunds", pipelines: %{"billing/text" => text})

    assert {:ok, %{candidate: "refund", rule: "billing/refunds/refund"}} =
             Flow.route(billing, "REFUND")
  end

  test "serialized Definitions do not automatically execute their declared adapter modules" do
    definition = Assistant.definition()
    assert {:ok, restored} = definition |> Definition.canonical() |> Definition.from_canonical()
    assert restored === definition
    assert {:error, {:unknown_router_method, "binary"}} = Agent.flow(restored, "device")
    assert {:error, {:unwired_flow_pipeline, "text"}} = Agent.flow(restored, "support")
  end

  test "unknown flows and malformed host bindings fail without changing routing policy" do
    assert {:error, {:unknown_agent_flow, "missing"}} = flow("missing")
    assert {:error, :invalid_flow_pipeline_registry} = flow("support", pipelines: [])

    assert {:error, {:invalid_flow_pipeline, "text"}} =
             flow("support", pipelines: %{"text" => NormalizeText})

    assert {:error, _} = flow("device", via: [:regex])
    assert {:error, _} = Wiring.resolve(Assistant, %{router: [regex: BinaryMatcher]})
  end

  test "pipeline halt and error remain distinct from a miss or ambiguous route" do
    for status <- [:halt, :error] do
      {:ok, pipeline} = Pipeline.new([{StopPlug, status: status}])
      {:ok, support} = flow("support", pipelines: %{"text" => pipeline})

      case status do
        :halt ->
          assert {:halt, "order 42"} = Flow.route(support, "order 42")

        :error ->
          assert {:error, {:input_plug_failed, StopPlug, "order 42"}} =
                   Flow.route(support, "order 42")
      end
    end

    {:ok, ambiguous} = flow("uncertain")

    assert {:ambiguous, ["uncertain/first", "uncertain/second"]} =
             Flow.route(ambiguous, "anything")
  end

  test "input limits run before custom matcher invocation" do
    {:ok, device} = flow("device", adapters: [binary: {BinaryMatcher, observer: self()}])
    assert {:error, _} = Flow.route(device, :binary.copy("x", 65_537))
    refute_receive :matcher_called
    assert {:ok, _} = Flow.route(device, <<0, 1>>)
    assert_receive :matcher_called
  end

  test "duplicate, nested and misplaced declarations fail at their source" do
    for body <- [
          "flow :a do end\nflow :a do end",
          "pipe_through :a",
          "flow :a do\nflow :b do end\nend",
          "flow :a do\nrouter via: [:regex]\nrouter via: [:regex]\nend",
          "flow :a do\nrequest :x, class: \"x\"\nend",
          "flow :a do\nroute :r, to: :hidden, match: [regex: \".*\"]\nend"
        ] do
      assert_raise CompileError, fn ->
        module = "Spectre.InvalidFlow#{System.unique_integer([:positive])}"

        Code.compile_string("""
        defmodule #{module} do
          use Spectre.Agent, namespace: "test", name: "invalid"
          #{body}
        end
        """)
      end
    end
  end

  defp flow(name, opts \\ []), do: Agent.flow(Assistant.definition(), name, opts)
end
