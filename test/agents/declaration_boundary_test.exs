defmodule Spectre.Agents.DeclarationBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.{Definition, Router}
  alias Spectre.Agent.{Declaration, Publication, Wiring}

  defmodule Request do
    def prepare(_, _, _, _), do: raise("wiring must never execute a request")
  end

  defmodule Classifier do
    def evaluate(_, _), do: {:ok, []}
  end

  defmodule EmptyExtension do
    @behaviour Spectre.Extension

    @impl true
    def configure(opts), do: {:ok, %{data: %{received: opts}, ports: %{}}}
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "boundary", name: "assistant"
    adapter(:request, :writer, Request)
    prompt(:hello, "Hello, <%= @name %>!")

    flow :support do
      router(via: [:regex])
      route(:hello, match: [regex: ~r/^hello$/])
    end
  end

  defmodule Unwired do
    use Spectre.Agent, namespace: "boundary", name: "unwired"
    history(:chat, keep: 5)
  end

  defmodule Child do
    use Spectre.Skill, namespace: "boundary", name: "child"
    flow :lookup do
      route(:find, match: [regex: ~r/^find$/])
    end
  end

  defmodule Parent do
    use Spectre.Agent, namespace: "boundary", name: "parent"
    skill(Child, as: :child)
  end

  test "mounted Definitions must be actual publications of the declared child code", c do
    child = Child.definition(revision: 1, declared_at: 0)
    definition = Parent.definition(revision: 1, declared_at: 0, components: %{child: child})
    assert {:ok, _, %{"child" => ^child}} = Publication.verify(Parent, definition)
    assert {:error, :invalid_component_definitions} = Publication.definition(Parent, revision: 1, declared_at: 0, components: [])
    assert {:error, {:component_definition, "child", :authoring_definition_mismatch}} =
             Publication.definition(Parent, revision: 1, declared_at: 0, components: %{child: c.definition})
    assert {:error, :invalid_authoring_definition} = Publication.verify(Parent, %{})
    assert {:error, :not_an_authoring_definition} = Publication.children(nil)
    flow = Child.__spectre_plan__().flows["lookup"]
    assert %{"routing" => %{"rules" => %{"find" => _}, "config" => config}} = Publication.flow_body(flow)
    assert config["via"] != []
  end

  defmodule LocalClassifier do
    use Spectre.Agent, namespace: "boundary", name: "classifier"
    adapter(:classifier, :intent, Classifier)

    flow :support do
      router(via: [:local_classifier], classifier: :intent)
      route(:hello, classify: true)
    end
  end

  setup do
    definition = Assistant.definition(revision: 1, declared_at: 0)
    %{definition: definition}
  end

  test "a portable Definition cannot invent executable flows, routes, templates or prompts", c do
    assert {:ok, _} = Declaration.read(c.definition)
    assert {:error, :not_an_agent_declaration} = Declaration.read(nil)
    plan = c.definition.body["authoring"]["plan"]

    for {key, value, reason} <- [
          {:requests, [], :invalid_agent_entries},
          {:flows, %{"support" => %{}}, :invalid_agent_flow},
          {:prompts, %{"hello" => %{text: 42}}, :invalid_prompt_declaration}
        ] do
      assert {:error, ^reason} =
               Declaration.read(changed_plan(c.definition, Map.put(plan, key, value)))
    end

    flow = plan.flows["support"]
    bad_route = %{flow | routes: %{"hello" => %{}}}

    assert {:error, :invalid_agent_route} =
             Declaration.read(
               changed_plan(c.definition, put_in(plan.flows["support"], bad_route))
             )

    bad_config = %{flow | routing: %{"via" => ["regex"]}}

    assert {:error, :invalid_agent_routing} =
             Declaration.read(
               changed_plan(c.definition, put_in(plan.flows["support"], bad_config))
             )

    assert {:error, :not_an_agent_declaration} =
             Declaration.read(changed_plan(c.definition, %{plan | asks: []}))
  end

  test "pipeline paths are bounded, portable, unique and explicit" do
    assert :ok = Declaration.pipeline_names(["text", "skill/normalizer"])
    assert {:error, :duplicate_flow_pipeline} = Declaration.pipeline_names(["text", "text"])
    assert {:error, :invalid_flow_pipelines} = Declaration.pipeline_names(nil)

    assert {:error, :invalid_flow_pipelines} =
             Declaration.pipeline_names(Enum.map(1..65, &"p#{&1}"))

    assert {:error, _} = Declaration.pipeline_names([self()])
    assert {:error, _} = Declaration.pipeline_names(["broken//name"])
  end

  test "wiring cannot replace static modules, reserved declarations or undeclared ports" do
    assert {:ok, wiring} = Wiring.resolve(Assistant, request: [writer: Request])
    assert wiring.ports["request/writer"] == {Request, []}

    assert {:error, {:invalid_port, "request/writer", :declared_adapter_mismatch}} =
             Wiring.resolve(Assistant, request: [writer: {String, []}])

    assert {:error, {:invalid_port, "request/writer", :invalid_port_binding}} =
             Wiring.resolve(Assistant, request: [writer: 42])

    assert {:error, {:invalid_port, "request/writer", {:reserved_adapter_option, :declaration}}} =
             Wiring.resolve(Assistant, request: [writer: [declaration: %{}]])

    assert {:error, {:invalid_port, "history/chat", :adapter_module_required}} =
             Wiring.resolve(Unwired, history: [chat: []])

    assert {:error, _} = Wiring.resolve(Assistant, request: nil)
    assert {:error, :invalid_adapter_registry} = Wiring.registry(nil)
    assert {:error, :invalid_adapter_key} = Wiring.registry(%{42 => Request})

    assert {:error, {:duplicate_adapter_key, "writer"}} =
             Wiring.registry(writer: Request, writer: Request)

    assert {:error, _} = Wiring.registry(%{"broken//writer" => Request})

    assert {:error, {:unwired_semantic_cache, :routing}} =
             Wiring.cache(:routing, "definition", "support", %{ports: %{}}, "")
  end

  test "a local classifier is an explicit Router adapter, never a governed provider call" do
    definition = LocalClassifier.definition(revision: 1, declared_at: 0)
    assert {:ok, wiring} = Wiring.resolve(LocalClassifier, [])
    entry = LocalClassifier.__spectre_plan__().flows["support"]
    assert {:ok, _flow} = Wiring.flow(entry, definition.ref, "support", wiring, "")

    assert {:error, {:unwired_classifier, :intent}} =
             Wiring.flow(entry, definition.ref, "support", %{ports: %{}}, "")

    {:ok, routing} = Router.configuration(via: [:regex])

    assert {:error, :classifier_method_required} =
             Wiring.flow(%{entry | routing: routing}, definition.ref, "support", wiring, "")
  end

  test "compile-time DSL diagnostics reject invalid resources before publishing code" do
    cases = [
      {"prompt_root(42)", ":invalid_prompt_root"},
      {"semantic_cache(:routing, learn: :automatic)", ":invalid_cache_learning_policy"},
      {"adapter(:request, :writer, \"not-a-module\")", ":invalid_adapter_module"},
      {"install(Spectre.MissingExtension, [])", ":extension_unavailable"},
      {"prompt(:hello, file: \"prompt.txt\")", ":prompt_requires_eex_file"},
      {"prompt(:hello, file: \"missing.txt.eex\")", ":prompt_file"},
      {"adapter(:request, :writer, String, override: true)", ":nothing_to_override"}
    ]

    for {{declaration, diagnostic}, index} <- Enum.with_index(cases) do
      module = "Spectre.DiagnosticAgent#{index}"

      source = """
      defmodule #{module} do
        use Spectre.Agent, namespace: "diagnostic", name: "agent-#{index}"
        #{declaration}
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(source, "diagnostic_agent.ex") end
      assert Exception.message(error) =~ diagnostic
    end
  end

  test "the shared DSL accepts concise injection and declarative extension blocks" do
    suffix = System.unique_integer([:positive])
    module = "Spectre.ValidDslAgent#{suffix}"

    source = """
    defmodule #{module} do
      use Spectre.Agent, namespace: "diagnostic", name: "valid-#{suffix}"
      prompt(:hello, "Hello from a compiled prompt")
      inject(:hello)

      install Spectre.Agents.DeclarationBoundaryTest.EmptyExtension do
        profile(:support)
        option(:bounded, 8)
      end
    end
    """

    assert [{compiled, _bytecode}] = Code.compile_string(source, "valid_dsl_agent.ex")
    plan = compiled.__spectre_plan__()
    assert [%{prompt: :hello, position: :end, into: nil}] = plan.injections

    assert %{received: [profile: [:support], option: [:bounded, 8]]} =
             plan.extensions[Atom.to_string(EmptyExtension)]
  end

  test "extension blocks reject expressions that are not declarations" do
    source = """
    defmodule Spectre.InvalidExtensionBlock#{System.unique_integer([:positive])} do
      use Spectre.Agent, namespace: "diagnostic", name: "invalid-extension-block"

      install Spectre.Agents.DeclarationBoundaryTest.EmptyExtension do
        :not_a_declaration
      end
    end
    """

    assert_raise ArgumentError, "extension blocks contain declarations only", fn ->
      Code.compile_string(source, "invalid_extension_block.ex")
    end
  end

  defp changed_plan(definition, plan) do
    body = put_in(definition.body, ["authoring", "plan"], plan)
    {:ok, changed} = Definition.new(%{definition | ref: nil, body: body})
    changed
  end
end
