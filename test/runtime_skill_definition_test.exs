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
    assert Registry.registered?(Agent, "lookup")
    assert {:ok, :lookup} = Registry.resolve_id(Agent, "lookup")
    refute Registry.registered?(Agent, :missing)

    unknown = "runtime-operation-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, {:operation_not_registered, ^unknown}} = Registry.resolve_id(Agent, unknown)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    refute Registry.registered?(42, :lookup)
    assert {:error, {:operation_not_registered, :lookup}} = Registry.resolve_id(42, :lookup)
  end

  test "runtime construction aliases and public shapes are closed" do
    attrs = operation_skill()

    assert {:ok, keyword_definition} = SkillDefinition.new(Map.to_list(attrs))
    assert {:ok, runtime_definition} = SkillDefinition.runtime(attrs)
    assert SkillDefinition.equivalent?(keyword_definition, runtime_definition)

    assert {:error, {:invalid_runtime_skill, :list}} = SkillDefinition.new([:bad])

    for {value, shape} <- [
          {URI.parse("/"), :map},
          {"bad", :binary},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_runtime_skill, ^shape}} = SkillDefinition.new(value)
      assert {:error, {:invalid_canonical_skill, ^shape}} = SkillDefinition.from_canonical(value)
    end

    assert_raise ArgumentError, ~r/invalid runtime Skill/, fn ->
      attrs |> Map.delete(:publisher_ref) |> SkillDefinition.new!()
    end

    assert {:error, {:canonical_definition_is_not_skill, :agent}} =
             Agent |> Definition.canonical!() |> SkillDefinition.from_canonical()
  end

  test "runtime declarations reject malformed metadata, fragments, budgets, flows, and refs" do
    base = operation_skill()

    assert {:error, {:missing_runtime_skill_field, :id}} =
             base |> Map.delete(:id) |> SkillDefinition.new()

    assert {:error, {:missing_runtime_skill_field, :id}} =
             base |> Map.put(:id, nil) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_skill_version, 0}} =
             base |> Map.put(:declared_version, 0) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_skill_publisher_ref, nil}} =
             base |> Map.delete(:publisher_ref) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_skill_description, 42}} =
             base |> Map.put(:description, 42) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_skill_metadata, :list}} =
             base |> Map.put(:metadata, []) |> SkillDefinition.new()

    assert {:error, {:nonportable_runtime_skill_metadata, _reason}} =
             base |> Map.put(:metadata, %{pid: self()}) |> SkillDefinition.new()

    assert {:error, {:unknown_runtime_skill_fields, [:unknown]}} =
             base |> Map.put(:unknown, true) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_prompt_fragments, :binary}} =
             base |> Map.put(:prompt_fragments, "bad") |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_prompt_fragment, 0, _reason}} =
             base |> Map.put(:prompt_fragments, [42]) |> SkillDefinition.new()

    assert {:error,
            {:invalid_runtime_prompt_fragment, 0,
             :runtime_prompt_fragment_requires_closed_content}} =
             base
             |> Map.put(:prompt_fragments, [%{id: :bad, content: nil, token_cap: 1}])
             |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_prompt_fragment, 0, {:invalid_runtime_skill_enum, _, _}}} =
             base
             |> Map.put(:prompt_fragments, [
               %{id: :bad, content: "safe", token_cap: 4, visibility: "root"}
             ])
             |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_skill_prompt_budget, :bad}} =
             base |> Map.put(:prompt_budget, :bad) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_flows, :binary}} =
             base |> Map.put(:flows, "bad") |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_flow, :other}}} =
             base |> Map.put(:flows, [42]) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_flow_routes, :other}}} =
             base |> Map.put(:flows, [%{id: :bad}]) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_operation_refs, :other}} =
             base |> Map.put(:operation_refs, :bad) |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_operation_ref, nil}} =
             base |> Map.put(:operation_refs, [nil]) |> SkillDefinition.new()
  end

  test "runtime fragments, handlers, and operation inputs cover every declarative form" do
    reply_attrs = reply_skill()
    reply_definition = SkillDefinition.new!(reply_attrs)
    [fragment] = SkillDefinition.prompt_fragments(reply_definition)

    assert {:ok, from_fragment_struct} =
             reply_attrs
             |> Map.put(:prompt_fragments, [fragment])
             |> SkillDefinition.new()

    assert SkillDefinition.equivalent?(reply_definition, from_fragment_struct)

    assert {:ok, budget_map} =
             reply_attrs
             |> Map.put(:prompt_budget, %{token_cap: 64, reserved_tokens: 20})
             |> SkillDefinition.new()

    assert SkillDefinition.prompt_budget(budget_map).reserved_tokens == 20

    duplicate_fragments =
      Map.put(reply_attrs, :prompt_fragments, [
        hd(reply_attrs.prompt_fragments),
        hd(reply_attrs.prompt_fragments)
      ])

    assert {:error, {:duplicate_runtime_prompt_fragment, :hello_prompt}} =
             SkillDefinition.new(duplicate_fragments)

    [flow] = operation_skill().flows
    [route] = flow.routes

    assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, _reason}}} =
             operation_skill()
             |> Map.put(:flows, [%{flow | routes: [42]}])
             |> SkillDefinition.new()

    assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, _reason}}} =
             operation_skill()
             |> Map.put(:flows, [%{flow | routes: [%{route | match: nil}]}])
             |> SkillDefinition.new()

    for handler <- [%{kind: :unknown}, 42] do
      assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, _reason}}} =
               operation_skill()
               |> Map.put(:flows, [%{flow | routes: [%{route | handler: handler}]}])
               |> SkillDefinition.new()
    end

    assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, _reason}}} =
             operation_skill()
             |> Map.put(:flows, [
               %{flow | routes: [%{route | handler: {:operation, :undeclared}}]}
             ])
             |> SkillDefinition.new()

    assert {:ok, tuple_opts} =
             operation_skill()
             |> Map.put(:flows, [
               %{
                 flow
                 | routes: [
                     %{route | handler: {:operation, :lookup, [input: :input]}, input: nil}
                   ]
               }
             ])
             |> SkillDefinition.new()

    assert [%{handler: %{input: :input}}] = SkillDefinition.routes(tuple_opts)

    for input <- [
          {:fixed, %{mode: :safe}},
          %{"kind" => "fixed", "value" => ["safe"]},
          %{kind: :fixed, value: 42}
        ] do
      assert {:ok, fixed} =
               operation_skill()
               |> Map.put(:flows, [%{flow | routes: [%{route | input: input}]}])
               |> SkillDefinition.new()

      assert [%{handler: %{input: {:fixed, _value}}}] = SkillDefinition.routes(fixed)
    end

    for input <- [{:fixed, self()}, :invalid] do
      assert {:error, {:invalid_runtime_flow, 0, {:invalid_runtime_route, 0, _reason}}} =
               operation_skill()
               |> Map.put(:flows, [%{flow | routes: [%{route | input: input}]}])
               |> SkillDefinition.new()
    end

    [reply_flow] = reply_attrs.flows
    [reply_route] = reply_flow.routes

    assert {:ok, map_reply} =
             reply_attrs
             |> Map.put(:flows, [
               %{
                 reply_flow
                 | routes: [
                     %{reply_route | handler: %{"kind" => "reply", "prompt" => :hello_prompt}}
                   ]
               }
             ])
             |> SkillDefinition.new()

    assert {:ok, _report} = SkillDefinition.anti_hijack(map_reply)
    assert %{handler: %{kind: :reply}} = SkillDefinition.semantic_ir(map_reply).routes |> hd()
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

  test "anti-hijack rejects negative examples that ambiguously match multiple routes" do
    base = operation_skill()

    admin_flows =
      Enum.map([:admin_one, :admin_two], fn flow_id ->
        %{
          id: flow_id,
          routes: [
            %{
              label: flow_id,
              match: {:exact, "admin"},
              handler: {:operation, :lookup},
              input: :text
            }
          ]
        }
      end)

    definition =
      base
      |> Map.put(:flows, base.flows ++ admin_flows)
      |> SkillDefinition.new!()

    assert {:error, {:ambiguous_skill_route, [:admin_one, :admin_two]}} =
             SkillDefinition.route(definition, "admin")

    assert {:error,
            {:skill_anti_hijack_failed, %{positive_unmatched: [], negative_matched: ["admin"]}}} =
             SkillDefinition.anti_hijack(definition)
  end

  test "canonical load rejects malformed portable route and requirement entries" do
    canonical = operation_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    malformed_routes =
      canonical
      |> rewrite_component(:routing, &Map.put(&1, :rules, [42]))
      |> round_trip_canonical()

    assert {:error, {:invalid_canonical_skill_route, 0, :other}} =
             SkillDefinition.from_canonical(malformed_routes)

    malformed_requirements =
      canonical
      |> rewrite_component(:requirements, &Map.put(&1, :requested, [42]))
      |> round_trip_canonical()

    assert {:error, {:invalid_canonical_skill_requirement, 0, :other}} =
             SkillDefinition.from_canonical(malformed_requirements)
  end

  test "canonical load revalidates in-memory envelope headers" do
    canonical = operation_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()
    forged = %{canonical | canonicalization_version: 99}

    assert {:error, {:unsupported_definition_canonicalization_version, 99}} =
             SkillDefinition.from_canonical(forged)
  end

  test "canonical load validates component presence, payload shapes, budgets, and handlers" do
    canonical = operation_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    without_policies =
      canonical
      |> Map.from_struct()
      |> Map.update!(:components, fn components ->
        Enum.reject(components, &(&1.component_type == :policies))
      end)
      |> Canonical.new!()

    assert {:error, {:missing_skill_definition_component, :policies}} =
             SkillDefinition.from_canonical(without_policies)

    invalid_payload =
      canonical
      |> rewrite_component(:applicability, fn _payload -> [] end)
      |> round_trip_canonical()

    assert {:error, {:invalid_skill_component_payload, :applicability}} =
             SkillDefinition.from_canonical(invalid_payload)

    invalid_fragments =
      canonical
      |> rewrite_component(:prompt_fragments, &Map.put(&1, :fragments, :bad))
      |> round_trip_canonical()

    assert {:error, {:invalid_canonical_skill_prompt_fragments, :bad}} =
             SkillDefinition.from_canonical(invalid_fragments)

    invalid_fragment =
      canonical
      |> rewrite_component(:prompt_fragments, &Map.put(&1, :fragments, [42]))
      |> round_trip_canonical()

    assert {:error,
            {:invalid_canonical_skill_prompt_fragment, 0, {:invalid_prompt_fragment_data, :other}}} =
             SkillDefinition.from_canonical(invalid_fragment)

    invalid_publisher =
      canonical
      |> rewrite_component(:identity, &put_in(&1, [:owner_ref], %{}))
      |> round_trip_canonical()

    assert {:error, {:invalid_runtime_skill_publisher_ref, nil}} =
             SkillDefinition.from_canonical(invalid_publisher)

    missing_budget =
      canonical
      |> rewrite_component(:prompt_fragments, &Map.delete(&1, :budget))
      |> round_trip_canonical()

    assert {:error, :runtime_skill_missing_prompt_budget} =
             SkillDefinition.from_canonical(missing_budget)

    invalid_requirements =
      canonical
      |> rewrite_component(:requirements, &Map.put(&1, :requested, :bad))
      |> round_trip_canonical()

    assert {:error, {:invalid_canonical_skill_requirements, :bad}} =
             SkillDefinition.from_canonical(invalid_requirements)

    invalid_routing =
      canonical
      |> rewrite_component(:routing, &Map.put(&1, :rules, :bad))
      |> round_trip_canonical()

    assert {:error, {:invalid_canonical_skill_routing, :bad}} =
             SkillDefinition.from_canonical(invalid_routing)

    invalid_handler =
      canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], &Map.put(&1, :handler, 42))
      end)
      |> round_trip_canonical()

    assert {:error, {:invalid_skill_handler, 0, {:invalid_canonical_skill_handler, 42}}} =
             SkillDefinition.from_canonical(invalid_handler)
  end

  test "canonical list checks route safely and compiled Skills derive a missing legacy budget" do
    canonical = operation_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    list_check =
      canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], &Map.put(&1, :checks, [["text", "lookup"]]))
      end)
      |> round_trip_canonical()

    assert {:ok, definition} = SkillDefinition.from_canonical(list_check)
    assert {:ok, %{label: :LOOKUP}} = SkillDefinition.route(definition, "lookup")

    unsupported_check =
      canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], &Map.put(&1, :checks, [["other", "lookup"]]))
      end)
      |> round_trip_canonical()

    assert {:ok, definition} = SkillDefinition.from_canonical(unsupported_check)
    assert {:error, :skill_route_not_found} = SkillDefinition.route(definition, "lookup")

    assert {:ok, compiled} = SkillDefinition.from_compiled(CompiledSkill)

    legacy =
      compiled.canonical
      |> rewrite_component(:prompt_fragments, &Map.delete(&1, :budget))
      |> round_trip_canonical()

    assert {:ok, restored} = SkillDefinition.from_canonical(legacy)
    assert SkillDefinition.prompt_budget(restored).fragment_count == 0

    compiled_action =
      compiled.canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], fn rule ->
          Map.put(rule, :handler, %{kind: :action, action: :compiled_only})
        end)
      end)
      |> round_trip_canonical()

    assert {:ok, restored_action} = SkillDefinition.from_canonical(compiled_action)

    assert %{handler: %{kind: :action}} =
             SkillDefinition.semantic_ir(restored_action).routes |> hd()
  end

  test "anti-hijack counts a single negative route match as a failure" do
    base = operation_skill()
    [flow] = base.flows
    [route] = flow.routes

    definition =
      base
      |> put_in([:applicability, :positive], ["safe"])
      |> put_in([:applicability, :negative], ["lookup"])
      |> Map.put(:flows, [
        %{
          flow
          | routes: [
              route,
              %{route | label: :SAFE, match: {:exact, "safe"}}
            ]
        }
      ])
      |> SkillDefinition.new!()

    assert {:error,
            {:skill_anti_hijack_failed, %{positive_unmatched: [], negative_matched: ["lookup"]}}} =
             SkillDefinition.anti_hijack(definition)
  end

  test "Skill routing rejects inputs that cannot be normalized" do
    definition = SkillDefinition.new!(operation_skill())

    assert {:error, {:invalid_skill_input, :tuple}} =
             SkillDefinition.route(definition, {:not, :stringable})
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

  test "runtime prompt governance is host-owned at construction and canonical load" do
    authored =
      reply_skill()
      |> put_in(
        [:prompt_fragments, Access.at(0)],
        Map.merge(hd(reply_skill().prompt_fragments), %{
          scope: :constitution,
          target: :instructions,
          position: :replace,
          source: %{kind: :spoofed},
          trust: :data,
          placeholders: %{},
          provenance: %{publisher_ref: "attacker"},
          requested_priority: :high,
          granted_priority: :high
        })
      )
      |> SkillDefinition.new!()

    assert [fragment] = SkillDefinition.prompt_fragments(authored)
    assert fragment.scope == :skill
    assert fragment.target == :task
    assert fragment.position == :end
    assert fragment.source == %{kind: :runtime_authored, publisher_ref: "host:test"}
    assert fragment.trust == :instruction
    assert fragment.provenance == %{publisher_ref: "host:test"}
    assert fragment.requested_priority == :high
    assert fragment.granted_priority == :normal

    tampered =
      authored.canonical
      |> rewrite_component(:prompt_fragments, fn payload ->
        [data] = payload.fragments

        %{payload | fragments: [%{data | target: :instructions, granted_priority: :high}]}
      end)
      |> round_trip_canonical()

    assert {:error,
            {:runtime_skill_prompt_governance_violation, 0,
             %{granted_priority: :high, target: :instructions}}} =
             SkillDefinition.from_canonical(tampered)
  end

  test "canonical runtime prompt budgets are recomputed from fragment evidence" do
    canonical = reply_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    understated =
      rewrite_component(canonical, :prompt_fragments, fn payload ->
        put_in(payload, [:budget, :reserved_tokens], 1)
      end)
      |> round_trip_canonical()

    assert {:error, {:canonical_skill_prompt_budget_mismatch, _declared, _derived}} =
             SkillDefinition.from_canonical(understated)

    oversized =
      rewrite_component(canonical, :prompt_fragments, fn payload ->
        [fragment] = payload.fragments

        fragment =
          fragment
          |> Map.put(:content, String.duplicate("x", 40_000))
          |> Map.put(:placeholders, %{})
          |> Map.put(:token_cap, 1)

        %{
          payload
          | fragments: [fragment],
            budget: %{
              schema_version: 1,
              token_cap: 64,
              reserved_tokens: 1,
              estimated_tokens: 1,
              fragment_count: 1
            }
        }
      end)
      |> round_trip_canonical()

    assert {:error, {:skill_prompt_fragment_over_budget, 0, 10_000, 1}} =
             SkillDefinition.from_canonical(oversized)
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

  test "Routing projection rejects malformed portable routing payloads" do
    canonical = reply_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    assert {:error, {:invalid_routing_projection_options, %{}}} =
             Routing.project(canonical, %{})

    for {value, shape} <- [
          {:not_a_list, :atom},
          {%{}, :map},
          {"not-a-list", :binary},
          {{:not, :a_list}, :tuple},
          {42, :other}
        ] do
      malformed =
        canonical
        |> rewrite_component(:routing, &Map.put(&1, :rules, value))
        |> round_trip_canonical()

      assert {:error, {:invalid_routing_projection_routes, ^shape}} =
               Routing.project(malformed, [])
    end

    malformed_route =
      canonical
      |> rewrite_component(:routing, &Map.put(&1, :rules, [[]]))
      |> round_trip_canonical()

    assert {:error, {:invalid_routing_projection_route, 0, :list}} =
             Routing.project(malformed_route, [])

    malformed_fragments =
      canonical
      |> rewrite_component(:prompt_fragments, &Map.put(&1, :fragments, :not_a_list))
      |> round_trip_canonical()

    assert {:error, {:invalid_routing_projection_prompt_fragments, :atom}} =
             Routing.project(malformed_fragments, [])

    malformed_fragment =
      canonical
      |> rewrite_component(:prompt_fragments, &Map.put(&1, :fragments, ["bad"]))
      |> round_trip_canonical()

    assert {:error, {:invalid_routing_projection_prompt_fragment, 0, :binary}} =
             Routing.project(malformed_fragment, [])

    invalid_payload =
      canonical
      |> rewrite_component(:applicability, fn _payload -> [] end)
      |> round_trip_canonical()

    assert {:error, {:invalid_routing_projection_component, :applicability}} =
             Routing.project(invalid_payload, [])

    without_routing =
      canonical
      |> Map.from_struct()
      |> Map.update!(:components, fn components ->
        Enum.reject(components, &(&1.component_type == :routing))
      end)
      |> Canonical.new!()

    assert {:error, {:unknown_definition_component, :routing}} =
             Routing.project(without_routing, [])
  end

  test "Routing projection summarizes compiled handler kinds without executable references" do
    canonical = reply_skill() |> SkillDefinition.new!() |> SkillDefinition.canonical()

    handlers = [
      action: %{kind: :action, action: %{id: :safe_action}},
      ask: %{kind: :ask, prompt: :ask_prompt},
      reason: %{kind: :reason, prompt: :reason_prompt},
      act: %{kind: :act, prompt: :act_prompt},
      run: %{kind: :run, callback: %{module: "Hidden"}},
      work: %{kind: :work, callback: %{module: "Hidden"}},
      custom: %{kind: :custom, executable: "hidden"},
      unknown: 42
    ]

    rules =
      Enum.map(handlers, fn {label, handler} ->
        %{label: label, flow_path: [:compiled], checks: [], handler: handler}
      end)

    projected =
      canonical
      |> rewrite_component(:routing, &Map.put(&1, :rules, rules))
      |> round_trip_canonical()

    assert {:ok, projection} = Routing.project(projected, [])

    assert Enum.map(projection.routes, & &1.handler) == [
             %{kind: :action, action: %{id: :safe_action}},
             %{kind: :ask, prompt: :ask_prompt},
             %{kind: :reason, prompt: :reason_prompt},
             %{kind: :act, prompt: :act_prompt},
             %{kind: :run, executable_ref: :compiled_definition_only},
             %{kind: :work, executable_ref: :compiled_definition_only},
             %{kind: :custom},
             %{kind: :unknown}
           ]

    refute inspect(projection.routes) =~ "Hidden"
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
    assert matrix.release == "0.3.2"
    assert matrix.skill_runtime.definition_schema == 1
    assert matrix.skill_runtime.applicability_schema == 1
    assert matrix.skill_runtime.prompt_budget_schema == 1
    assert matrix.skill_runtime.routing_projection == 1
    assert matrix.skill_runtime.index_profile == 1

    Enum.each(matrix.golden_path, fn {module, function, arity} ->
      assert Code.ensure_loaded?(module)
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

  defp rewrite_component(%Canonical{} = canonical, type, update) do
    components =
      Enum.map(canonical.components, fn component ->
        if component.component_type == type do
          Component.new!(
            component_type: component.component_type,
            schema_ref: component.schema_ref,
            criticality: component.criticality,
            payload: update.(component.payload)
          )
        else
          component
        end
      end)

    canonical
    |> Map.from_struct()
    |> Map.put(:components, components)
    |> Canonical.new!()
  end

  defp round_trip_canonical(%Canonical{} = canonical) do
    {:ok, decoded} = canonical |> Canonical.encode!() |> Canonical.decode()
    decoded
  end
end
