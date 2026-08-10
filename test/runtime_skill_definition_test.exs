defmodule SpectreRuntimeSkillDefinitionTest.Operations do
  @moduledoc false
  def lookup(input), do: input
end

defmodule SpectreRuntimeSkillDefinitionTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :runtime_skill_host

  operation(:lookup, {SpectreRuntimeSkillDefinitionTest.Operations, :lookup},
    input: :any,
    output: :any
  )
end

defmodule SpectreRuntimeSkillDefinitionTest.CompiledSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :lookup,
    version: 1,
    applicability: %{
      scopes: [:support],
      positive: ["lookup"],
      negative: ["admin"]
    }

  requires_operation(:lookup)

  flow :support do
    on :LOOKUP, check: {:text, "lookup"} do
      call_operation(:lookup, input: :text)
    end
  end
end

defmodule SpectreRuntimeSkillDefinitionTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Operation.Registry
  alias Spectre.Projection
  alias Spectre.Projection.Routing
  alias Spectre.Router.IndexProfile
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias SpectreRuntimeSkillDefinitionTest.Agent
  alias SpectreRuntimeSkillDefinitionTest.CompiledSkill

  test "compiled and runtime Skills converge on one origin-neutral semantic IR" do
    assert {:ok, compiled} = SkillDefinition.from_compiled(CompiledSkill)
    assert {:ok, runtime} = SkillDefinition.new(operation_skill())

    assert SkillDefinition.origin(compiled) == :compiled
    assert SkillDefinition.origin(runtime) == :runtime
    assert SkillDefinition.equivalent?(compiled, runtime)
    assert SkillDefinition.semantic_ir(compiled) == SkillDefinition.semantic_ir(runtime)
    refute SkillDefinition.ref(compiled) == SkillDefinition.ref(runtime)

    definition = Definition.fetch!(CompiledSkill)

    assert definition.requirements == [
             %{kind: :operation, name: :lookup, mode: :read, opts: []}
           ]

    assert Registry.registered?(Agent, :lookup)
    refute Registry.registered?(Agent, :missing)
  end

  test "operation handlers use the explicit Skill Runtime instead of the legacy Agent runner" do
    assert_raise ArgumentError, ~r/runtime_skill_operation_handler_is_skill_only/, fn ->
      Code.compile_string("""
      defmodule SpectreRuntimeSkillDefinitionTest.DirectOperationAgent do
        use Spectre.Agent
        operation :lookup, {SpectreRuntimeSkillDefinitionTest.Operations, :lookup}

        flow :root do
          on :LOOKUP, check: {:text, "lookup"} do
            call_operation :lookup
          end
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/runtime_operation_skill_requires_skill_runtime/, fn ->
      Code.compile_string("""
      defmodule SpectreRuntimeSkillDefinitionTest.LegacyMountedOperationAgent do
        use Spectre.Agent
        skill SpectreRuntimeSkillDefinitionTest.CompiledSkill, as: :lookup
      end
      """)
    end
  end

  test "runtime construction accepts JSON-shaped data without creating executable references" do
    data = %{
      "id" => "lookup",
      "declared_version" => 1,
      "publisher_ref" => "host:fixture",
      "applicability" => %{
        "scopes" => ["support"],
        "positive" => ["lookup"],
        "negative" => ["admin"]
      },
      "operation_refs" => ["lookup"],
      "flows" => [
        %{
          "id" => "support",
          "routes" => [
            %{
              "label" => "LOOKUP",
              "match" => %{"kind" => "exact", "value" => "lookup"},
              "handler" => %{
                "kind" => "operation",
                "operation_ref" => "lookup",
                "input" => "text"
              }
            }
          ]
        }
      ]
    }

    assert {:ok, definition} = SkillDefinition.new(data)
    assert definition.canonical.id == "lookup"
    assert SkillDefinition.operation_refs(definition) == ["lookup"]
    refute inspect(Canonical.to_data(definition.canonical)) =~ "compiled_only"
    refute inspect(Canonical.to_data(definition.canonical)) =~ "code_ref"
  end

  test "runtime canonical Definitions reject smuggled compiled code references" do
    definition = SkillDefinition.new!(operation_skill())
    canonical = SkillDefinition.canonical(definition)

    runtime_component =
      Enum.find(canonical.components, &(&1.component_type == :compiled_runtime))

    tampered_component =
      Component.new!(
        component_type: :compiled_runtime,
        schema_ref: runtime_component.schema_ref,
        criticality: runtime_component.criticality,
        payload:
          Map.put(runtime_component.payload, :executor, %{
            "$spectre_type" => "code_ref",
            "module" => "Elixir.Untrusted"
          })
      )

    tampered =
      Canonical.new!(
        kind: :skill,
        id: canonical.id,
        declared_version: canonical.declared_version,
        origin: :runtime,
        components:
          Enum.map(canonical.components, fn component ->
            if component.component_type == :compiled_runtime,
              do: tampered_component,
              else: component
          end)
      )

    assert {:error, {:runtime_skill_contains_code_ref, _path}} =
             SkillDefinition.from_canonical(tampered)
  end

  test "structured applicability and route conflicts fail closed" do
    assert {:error, {:conflicting_skill_applicability_value, "lookup"}} =
             operation_skill()
             |> put_in([:applicability, :negative], ["lookup"])
             |> SkillDefinition.new()

    conflicting =
      update_in(operation_skill().flows, fn [flow] ->
        duplicate = flow.routes |> hd() |> Map.put(:label, :DUPLICATE)
        [%{flow | routes: flow.routes ++ [duplicate]}]
      end)

    assert {:error, {:conflicting_skill_route, :LOOKUP, :DUPLICATE}} =
             SkillDefinition.new(conflicting)

    hijacking =
      operation_skill()
      |> put_in([:applicability, :positive], ["not-routed"])
      |> SkillDefinition.new!()

    assert {:error,
            {:skill_anti_hijack_failed,
             %{positive_unmatched: ["not-routed"], negative_matched: []}}} =
             SkillDefinition.anti_hijack(hijacking)
  end

  test "runtime prompts are closed, capped, and fail on executable or oversized content" do
    reply = SkillDefinition.new!(reply_skill())
    assert [fragment] = SkillDefinition.prompt_fragments(reply)
    assert fragment.content == "Hello {{input.text}}"
    assert fragment.token_cap == 16
    assert SkillDefinition.prompt_budget(reply).reserved_tokens == 16

    assert {:error, {:invalid_runtime_prompt_fragment, 0, :executable_prompt_template}} =
             reply_skill()
             |> put_in(
               [:prompt_fragments, Access.at(0), :content],
               "<%= System.cmd(\"id\", []) %>"
             )
             |> SkillDefinition.new()

    assert {:error, {:skill_prompt_budget_exceeded, 32, 16}} =
             reply_skill()
             |> Map.put(:prompt_budget, 16)
             |> put_in([:prompt_fragments, Access.at(0), :token_cap], 32)
             |> SkillDefinition.new()
  end

  test "Routing projection is deterministic and binds a versioned index profile" do
    definition = SkillDefinition.new!(reply_skill())
    canonical = SkillDefinition.canonical(definition)

    assert {:ok, first} = Projection.generate(canonical, Routing)
    assert {:ok, second} = Projection.generate(canonical, Routing)
    assert first == second
    assert first.generator_id == "spectre.projection.routing"
    assert first.generator_version == 1
    assert first.content.index_profile.version == 1
    refute inspect(first.content) =~ "Hello {{input.text}}"

    profile = IndexProfile.new!(%{id: "spectre.routing.exact.v2", version: 2})

    assert {:ok, changed} =
             Projection.generate(canonical, Routing, index_profile: profile)

    refute changed.digest == first.digest
    refute changed.content.cache_key == first.content.cache_key
    assert :ok = Projection.verify(changed, canonical)
  end

  test "the 0.2.7 fixture pins runtime Skill and Routing projection identities" do
    fixture =
      "test/fixtures/compatibility/0.2.7/runtime-skill-routing-v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert fixture["schema_version"] == 1
    assert fixture["release"] == "0.2.7"
    assert {:ok, definition} = SkillDefinition.new(fixture["skill"])
    assert {:ok, projection} = Projection.generate(definition.canonical, Routing)

    expected = fixture["expected"]

    assert to_string(definition.ref) == expected["definition_ref"]
    assert Value.digest!(SkillDefinition.semantic_ir(definition)) == expected["semantic_digest"]
    assert projection.digest == expected["routing_projection_digest"]
    assert projection.content.cache_key == expected["routing_cache_key"]

    matrix = Spectre.Foundation.Conformance.matrix()
    assert matrix.release == "0.2.7"
    assert matrix.skill_runtime.definition_schema == 1
    assert matrix.skill_runtime.applicability_schema == 1
    assert matrix.skill_runtime.prompt_budget_schema == 1
    assert matrix.skill_runtime.routing_projection == 1
    assert matrix.skill_runtime.index_profile == 1

    Enum.each(matrix.golden_path, fn {module, function, arity} ->
      assert function_exported?(module, function, arity)
    end)
  end

  defp operation_skill(overrides \\ %{}) do
    Map.merge(
      %{
        id: :lookup,
        declared_version: 1,
        publisher_ref: "host:test",
        applicability: %{
          scopes: [:support],
          positive: ["lookup"],
          negative: ["admin"]
        },
        operation_refs: [:lookup],
        flows: [
          %{
            id: :support,
            routes: [
              %{
                label: :LOOKUP,
                match: {:exact, "lookup"},
                handler: {:operation, :lookup},
                input: :text
              }
            ]
          }
        ]
      },
      overrides
    )
  end

  defp reply_skill do
    %{
      id: :hello,
      declared_version: 1,
      publisher_ref: "host:test",
      applicability: %{scopes: [:chat], positive: ["hello"], negative: ["bye"]},
      prompt_budget: 64,
      prompt_fragments: [
        %{id: :hello_prompt, content: "Hello {{input.text}}", token_cap: 16}
      ],
      flows: [
        %{
          id: :chat,
          routes: [
            %{label: :HELLO, match: {:exact, "hello"}, handler: {:reply, :hello_prompt}}
          ]
        }
      ]
    }
  end
end
