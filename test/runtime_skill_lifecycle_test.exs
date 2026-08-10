defmodule SpectreRuntimeSkillLifecycleTest.Operations do
  @moduledoc false
  def lookup(input), do: input
end

defmodule SpectreRuntimeSkillLifecycleTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :runtime_lifecycle_host

  operation(:lookup, {SpectreRuntimeSkillLifecycleTest.Operations, :lookup},
    input: :any,
    output: :any
  )
end

defmodule SpectreRuntimeSkillLifecycleTest.CompiledSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :compiled_lookup,
    version: 1,
    applicability: %{scopes: [:support], positive: ["lookup"], negative: ["admin"]}

  requires_operation(:lookup)

  flow :support do
    on :LOOKUP, check: {:text, "lookup"} do
      call_operation(:lookup, input: :text)
    end
  end
end

defmodule SpectreRuntimeSkillLifecycleTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Operation.Request
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime
  alias Spectre.Skill.Runtime.Response
  alias SpectreRuntimeSkillLifecycleTest.Agent
  alias SpectreRuntimeSkillLifecycleTest.CompiledSkill

  test "mount and operation response require host authority and CAS" do
    runtime = runtime()
    skill = operation_skill()

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.mount(runtime, :lookup, skill)

    assert {:error, {:stale_skill_runtime_revision, 1, 0}} =
             Runtime.mount(runtime, :lookup, skill, expected_revision: 1)

    assert {:ok, runtime} =
             Runtime.mount(runtime, :lookup, skill, expected_revision: 0)

    assert runtime.revision == 1
    assert {:ok, %{state: :active}} = Runtime.status(runtime, :lookup)

    assert {:ok, %Response{} = response, runtime} =
             Runtime.respond(runtime, "lookup", %{scope: :support}, expected_revision: 1)

    assert response.kind == :operation
    assert %Request{operation: :lookup, input: "lookup"} = response.operation_request
    assert response.continuation_id == response.operation_request.id
    assert runtime.revision == 2
  end

  test "missing lifecycle and operation grants fail closed" do
    no_mount =
      Runtime.new!(Agent, authority(open_capabilities: []),
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 256
      )

    assert {:error, {:skill_runtime_capability_not_granted, "spectre.skill.runtime.mount"}} =
             Runtime.mount(no_mount, :lookup, operation_skill(), expected_revision: 0)

    no_operation =
      Runtime.new!(Agent, authority(operations: []),
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 256
      )

    assert {:error, {:skill_operation_not_authorized, :lookup}} =
             Runtime.mount(no_operation, :lookup, operation_skill(), expected_revision: 0)

    missing = operation_skill(id: :missing, operation: :missing)

    missing_authority =
      Runtime.new!(Agent, authority(operations: [:lookup, :missing]),
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 256
      )

    assert {:error, {:skill_operation_not_registered, :missing}} =
             Runtime.mount(missing_authority, :missing, missing, expected_revision: 0)
  end

  test "ambiguous applicability and declared conflicts reject routing or mount" do
    runtime = runtime()

    assert {:ok, runtime} =
             Runtime.mount(runtime, :one, operation_skill(id: :one), expected_revision: 0)

    assert {:ok, runtime} =
             Runtime.mount(runtime, :two, operation_skill(id: :two), expected_revision: 1)

    assert {:error, {:ambiguous_skill_applicability, [:one, :two]}} =
             Runtime.route(runtime, "lookup", %{scope: :support})

    conflict_runtime = runtime()

    assert {:ok, conflict_runtime} =
             Runtime.mount(
               conflict_runtime,
               :one,
               operation_skill(id: :one),
               expected_revision: 0
             )

    conflicting = operation_skill(id: :two, conflicts: [:one])

    assert {:error, {:conflicting_skill_applicability, :two, :one}} =
             Runtime.mount(conflict_runtime, :two, conflicting, expected_revision: 1)
  end

  test "forbidden tags cannot inflate routing specificity" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :honest, operation_skill(id: :honest), expected_revision: 0)

    inflated_tags = Enum.map(1..50, &"not-present-#{&1}")

    assert {:ok, runtime} =
             Runtime.mount(
               runtime,
               :inflated,
               operation_skill(id: :inflated, forbidden_tags: inflated_tags),
               expected_revision: 1
             )

    assert {:error, {:ambiguous_skill_applicability, [:honest, :inflated]}} =
             Runtime.route(runtime, "lookup", %{scope: :support})
  end

  test "a large Skill cannot consume the kernel prompt reserve" do
    constrained =
      Runtime.new!(Agent, authority(limits: %{max_tokens: 256}),
        max_prompt_tokens: 256,
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 256
      )

    assert {:error, {:skill_prompt_window_exceeded, 256, 128}} =
             Runtime.mount(constrained, :large, reply_skill(256), expected_revision: 0)

    no_prompt_grant =
      Runtime.new!(Agent, authority(prompt_budget_classes: []),
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 256
      )

    assert {:error, {:skill_prompt_budget_class_not_authorized, :standard}} =
             Runtime.mount(no_prompt_grant, :reply, reply_skill(16), expected_revision: 0)
  end

  test "disable drains owned continuations and completes after the last release" do
    runtime = runtime()

    {:ok, runtime} =
      Runtime.mount(runtime, :lookup, operation_skill(), expected_revision: 0)

    {:ok, response, runtime} =
      Runtime.respond(runtime, "lookup", %{scope: :support}, expected_revision: 1)

    assert {:ok, runtime} = Runtime.disable(runtime, :lookup, expected_revision: 2)

    assert {:ok, %{state: :draining, continuation_count: 1}} =
             Runtime.status(runtime, :lookup)

    assert {:error, :runtime_skill_route_not_found} =
             Runtime.route(runtime, "lookup", %{scope: :support})

    assert {:ok, pinned} = Runtime.continuation(runtime, response.continuation_id)
    assert pinned.ref == response.definition_ref

    assert {:ok, runtime} =
             Runtime.release_continuation(runtime, response.continuation_id, expected_revision: 3)

    assert {:ok, %{state: :disabled, continuation_count: 0}} =
             Runtime.status(runtime, :lookup)
  end

  test "replace preserves the old generation until its continuations drain" do
    runtime = runtime()
    old = operation_skill(version: 1)
    new = operation_skill(version: 2)

    {:ok, runtime} = Runtime.mount(runtime, :lookup, old, expected_revision: 0)

    {:ok, response, runtime} =
      Runtime.respond(runtime, "lookup", %{scope: :support}, expected_revision: 1)

    old_ref = response.definition_ref

    assert {:ok, runtime} = Runtime.replace(runtime, :lookup, new, expected_revision: 2)
    assert map_size(runtime.retired) == 1

    assert {:ok, current} = Runtime.status(runtime, :lookup)
    assert current.state == :active
    refute current.definition_ref == to_string(old_ref)

    assert {:ok, pinned} = Runtime.continuation(runtime, response.continuation_id)
    assert pinned.ref == old_ref

    assert {:ok, runtime} =
             Runtime.release_continuation(runtime, response.continuation_id, expected_revision: 3)

    assert runtime.retired == %{}

    assert {:error, {:unknown_skill_continuation, _id}} =
             Runtime.continuation(runtime, response.continuation_id)
  end

  test "closed runtime reply is rendered without an operation continuation" do
    runtime = runtime()

    assert {:ok, runtime} =
             Runtime.mount(runtime, :reply, reply_skill(16), expected_revision: 0)

    assert {:ok, response, unchanged} =
             Runtime.respond(runtime, "hello", %{scope: :chat}, expected_revision: 1)

    assert response.kind == :reply
    assert response.output == "Hello hello"
    assert response.continuation_id == nil
    assert unchanged.revision == runtime.revision
  end

  test "composite placeholder values fail closed instead of crashing the host" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :reply, reply_skill(16, "Value: {{input}}"),
               expected_revision: 0
             )

    assert {:error, {:non_scalar_runtime_prompt_value, "input", :map}} =
             Runtime.respond(runtime, "hello", %{scope: :chat}, expected_revision: 1)
  end

  test "JSON operation references resolve only through the host registry" do
    skill =
      SkillDefinition.new!(%{
        "id" => "lookup-json",
        "publisher_ref" => "host:test",
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
      })

    assert SkillDefinition.operation_refs(skill) == ["lookup"]

    {:ok, canonical} =
      skill.canonical
      |> Spectre.Definition.Canonical.encode!()
      |> Spectre.Definition.Canonical.decode()

    assert {:ok, skill} = SkillDefinition.from_canonical(canonical)

    assert {:ok, runtime} =
             Runtime.mount(runtime(), :json, skill, expected_revision: 0)

    assert {:ok, response, _runtime} =
             Runtime.respond(runtime, "lookup", %{scope: "support"}, expected_revision: 1)

    assert %Request{operation: :lookup, input: "lookup"} = response.operation_request
  end

  test "anti-hijack evaluation is enforced during mount" do
    hijacking = operation_skill(positive: ["unmatched"])

    assert {:error,
            {:skill_anti_hijack_failed,
             %{positive_unmatched: ["unmatched"], negative_matched: []}}} =
             Runtime.mount(runtime(), :lookup, hijacking, expected_revision: 0)
  end

  test "manual continuations obey identity, lifecycle, and revision gates" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :lookup, operation_skill(), expected_revision: 0)

    assert {:error, {:invalid_skill_continuation_id, ""}} =
             Runtime.claim_continuation(runtime, :lookup, "", expected_revision: 1)

    assert {:error, {:unknown_skill_mount, :missing}} =
             Runtime.claim_continuation(runtime, :missing, "manual", expected_revision: 1)

    assert {:ok, runtime} =
             Runtime.claim_continuation(runtime, :lookup, "manual", expected_revision: 1)

    assert {:error, {:duplicate_skill_continuation, "manual"}} =
             Runtime.claim_continuation(runtime, :lookup, "manual", expected_revision: 2)

    assert {:ok, pinned} = Runtime.continuation(runtime, "manual")
    assert SkillDefinition.ref(pinned) == SkillDefinition.ref(operation_skill())

    assert {:error, {:unknown_skill_continuation, "missing"}} =
             Runtime.release_continuation(runtime, "missing", expected_revision: 2)

    assert {:ok, runtime} =
             Runtime.release_continuation(runtime, "manual", expected_revision: 2)

    assert {:error, {:unknown_skill_continuation, "manual"}} =
             Runtime.continuation(runtime, "manual")
  end

  test "immediate disable and replacement without continuations retain no generations" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :lookup, operation_skill(), expected_revision: 0)

    assert [%{mount_id: :lookup, state: :active}] = Runtime.mounts(runtime)

    assert {:error, {:duplicate_skill_mount, :lookup}} =
             Runtime.mount(runtime, :lookup, operation_skill(), expected_revision: 1)

    assert {:ok, replaced} =
             Runtime.replace(
               runtime,
               :lookup,
               operation_skill(version: 2),
               expected_revision: 1
             )

    assert replaced.retired == %{}

    assert {:ok, %{state: :active, continuation_count: 0}} =
             Runtime.status(replaced, :lookup)

    assert {:ok, disabled} = Runtime.disable(replaced, :lookup, expected_revision: 2)
    assert {:ok, %{state: :disabled}} = Runtime.status(disabled, :lookup)

    assert {:error, {:skill_mount_not_active, :disabled}} =
             Runtime.disable(disabled, :lookup, expected_revision: 3)

    assert {:error, {:skill_mount_not_active, :disabled}} =
             Runtime.claim_continuation(disabled, :lookup, "late", expected_revision: 3)

    assert {:error, {:unknown_skill_mount, :missing}} = Runtime.status(disabled, :missing)

    assert {:error, {:unknown_skill_mount, :missing}} =
             Runtime.replace(disabled, :missing, operation_skill(), expected_revision: 3)

    assert {:error, {:invalid_skill_routing_context, :invalid}} =
             Runtime.route(disabled, "lookup", :invalid)
  end

  test "runtime construction and mount sources fail closed at their boundaries" do
    assert {:error, {:invalid_skill_runtime_agent, 42}} = Runtime.new(42, authority())
    assert {:error, :invalid_skill_runtime_options} = Runtime.new(Agent, authority(), [:bad])

    assert {:error, {:unknown_skill_runtime_options, [:unknown]}} =
             Runtime.new(Agent, authority(), unknown: true)

    assert {:error, {:invalid_routing_index_profile_version, 0}} =
             Runtime.new(Agent, authority(), index_profile: %{version: 0})

    assert {:error, {:invalid_skill_runtime_prompt_window, {0, 1_024}}} =
             Runtime.new(Agent, authority(), max_prompt_tokens: 0)

    assert {:error, {:invalid_skill_runtime_kernel_budget, 1_025, 1_024}} =
             Runtime.new(Agent, authority(), kernel_prompt_tokens: 1_025)

    assert {:error, {:invalid_skill_runtime_per_skill_budget, 1_025, 1_024}} =
             Runtime.new(Agent, authority(), per_skill_prompt_cap: 1_025)

    assert_raise ArgumentError, ~r/invalid Skill runtime/, fn ->
      apply(Runtime, :new!, [42, authority()])
    end

    runtime = runtime()

    assert {:error, {:invalid_skill_mount_id, nil}} =
             Runtime.mount(runtime, nil, operation_skill(), expected_revision: 0)

    assert {:error, {:invalid_skill_mount_source, :map}} =
             Runtime.mount(runtime, :lookup, %{}, expected_revision: 0)

    canonical = operation_skill() |> SkillDefinition.canonical()
    assert {:ok, mounted} = Runtime.mount(runtime, "lookup", canonical, expected_revision: 0)
    assert {:ok, %{mount_id: "lookup"}} = Runtime.status(mounted, "lookup")

    forged_compiled =
      canonical
      |> Map.from_struct()
      |> Map.put(:origin, :compiled)
      |> Canonical.new!()

    assert {:error, {:skill_mount_requires_runtime_origin, :compiled}} =
             Runtime.mount(runtime, :forged, forged_compiled, expected_revision: 0)

    constrained =
      Runtime.new!(Agent, authority(),
        kernel_prompt_tokens: 128,
        per_skill_prompt_cap: 8
      )

    assert {:error, {:skill_prompt_cap_exceeded, 16, 8}} =
             Runtime.mount(constrained, :reply, reply_skill(16), expected_revision: 0)
  end

  test "mount revalidates a prebuilt Skill Definition instead of trusting its struct" do
    definition = operation_skill()

    components =
      Enum.map(definition.canonical.components, fn
        %Component{component_type: :routing} = component ->
          Component.new!(
            component_type: component.component_type,
            schema_ref: component.schema_ref,
            criticality: component.criticality,
            payload: Map.put(component.payload, :rules, [42])
          )

        component ->
          component
      end)

    forged_canonical =
      definition.canonical
      |> Map.from_struct()
      |> Map.put(:components, components)
      |> Canonical.new!()

    forged = %{definition | canonical: forged_canonical}

    assert {:error, {:invalid_canonical_skill_route, 0, :other}} =
             Runtime.mount(runtime(), :lookup, forged, expected_revision: 0)
  end

  test "routing and response reject inputs that cannot be normalized" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :lookup, operation_skill(), expected_revision: 0)

    assert {:error, {:invalid_skill_input, :tuple}} =
             Runtime.route(runtime, {:not, :stringable}, %{scope: :support})

    assert {:error, {:invalid_skill_input, :tuple}} =
             Runtime.respond(
               runtime,
               {:not, :stringable},
               %{scope: :support},
               expected_revision: 1
             )
  end

  test "default arities and malformed sources fail closed without changing revision" do
    runtime = runtime()

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.replace(runtime, :lookup, operation_skill())

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.disable(runtime, :lookup)

    assert {:error, :runtime_skill_route_not_found} = Runtime.route(runtime, "lookup")

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.respond(runtime, "lookup")

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.claim_continuation(runtime, :lookup, "continuation")

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.release_continuation(runtime, "continuation")

    assert {:error, {:expected_skill_runtime_revision_required, 0}} =
             Runtime.mount(runtime, :lookup, operation_skill(), %{})

    for {source, shape} <- [
          {[], :list},
          {"bad", :binary},
          {{:bad}, :tuple},
          {42, :other}
        ] do
      assert {:error, {:invalid_skill_mount_source, ^shape}} =
               Runtime.mount(runtime, :lookup, source, expected_revision: 0)
    end

    invalid_definition = %SkillDefinition{canonical: nil, ref: operation_skill().ref}

    assert {:error, {:invalid_skill_mount_source, :map}} =
             Runtime.mount(runtime, :lookup, invalid_definition, expected_revision: 0)
  end

  test "runtime reports ambiguity originating inside one mounted Skill" do
    base = operation_skill()

    [flow] =
      base.canonical |> SkillDefinition.from_canonical() |> elem(1) |> SkillDefinition.routes()

    rules =
      Enum.map([:one, :two], fn id ->
        %{flow | label: id, flow: id, flow_path: [id], checks: [text: "ambiguous"]}
      end)

    ambiguous =
      base.canonical
      |> rewrite_component(:applicability, fn payload ->
        put_in(payload, [:declared], %{
          schema_version: 1,
          scopes: [:support],
          required_tags: [],
          forbidden_tags: [],
          positive: [],
          negative: [],
          conflicts: []
        })
      end)
      |> rewrite_component(:routing, &Map.put(&1, :rules, rules))
      |> SkillDefinition.from_canonical()
      |> then(fn {:ok, definition} -> definition end)

    assert {:ok, runtime} =
             Runtime.mount(runtime(), :ambiguous, ambiguous, expected_revision: 0)

    assert {:error, {:skill_route_failed, :ambiguous, {:ambiguous_skill_route, [:one, :two]}}} =
             Runtime.route(runtime, "ambiguous", %{scope: :support})
  end

  test "compiled mount and operation inputs materialize only host-bound requests" do
    assert {:error, {:skill_runtime_host_not_agent, :skill}} =
             Runtime.new(CompiledSkill, authority())

    assert {:ok, compiled_runtime} =
             Runtime.mount(runtime(), :compiled, CompiledSkill, expected_revision: 0)

    assert {:ok, %Response{operation_request: %Request{input: "lookup"}}, _runtime} =
             Runtime.respond(
               compiled_runtime,
               "lookup",
               %{scope: :support},
               expected_revision: 1
             )

    for {mount_id, input, expected_input} <- [
          {"input-mount", :input, %{text: "lookup", meta: %{tenant: 7}}},
          {42, {:fixed, %{mode: :safe}}, %{mode: :safe}}
        ] do
      assert {:ok, mounted} =
               Runtime.mount(runtime(), mount_id, operation_skill(input: input),
                 expected_revision: 0
               )

      assert {:ok, response, _runtime} =
               Runtime.respond(
                 mounted,
                 %{text: "lookup", meta: %{tenant: 7}},
                 %{scope: :support},
                 expected_revision: 1
               )

      assert response.operation_request.input == expected_input
      assert is_binary(response.operation_request.branch)
    end
  end

  test "prompt rendering supports scalar and nested values and rejects missing paths" do
    assert {:ok, scalar_runtime} =
             Runtime.mount(
               runtime(),
               :scalars,
               reply_skill(32, "{{count}}/{{ratio}}/{{enabled}}"),
               expected_revision: 0
             )

    assert {:ok, %{output: "7/1.5/false"}, _runtime} =
             Runtime.respond(
               scalar_runtime,
               "hello",
               %{scope: :chat, count: 7, ratio: 1.5, enabled: false},
               expected_revision: 1
             )

    assert {:ok, nested_runtime} =
             Runtime.mount(
               runtime(),
               :nested,
               reply_skill(32, "Tenant {{tenant.name}} / {{input.meta.locale}}"),
               expected_revision: 0
             )

    assert {:ok, %{output: "Tenant acme / it"}, _runtime} =
             Runtime.respond(
               nested_runtime,
               %{text: "hello", meta: %{"locale" => "it"}},
               %{"scope" => :chat, "tenant" => %{"name" => "acme"}},
               expected_revision: 1
             )

    assert {:error, {:missing_runtime_prompt_value, "tenant.name"}} =
             Runtime.respond(
               nested_runtime,
               %{text: "hello", meta: %{locale: "it"}},
               %{scope: :chat, tenant: "not-a-map"},
               expected_revision: 1
             )

    unknown = "runtime_value_#{System.unique_integer([:positive])}"

    assert {:ok, missing_runtime} =
             Runtime.mount(runtime(), :missing, reply_skill(32, "{{#{unknown}}}"),
               expected_revision: 0
             )

    assert {:error, {:missing_runtime_prompt_value, ^unknown}} =
             Runtime.respond(
               missing_runtime,
               "hello",
               %{scope: :chat},
               expected_revision: 1
             )
  end

  test "multiple continuations keep drains live and orphaned pins fail closed" do
    assert {:ok, runtime} =
             Runtime.mount(runtime(), :lookup, operation_skill(), expected_revision: 0)

    assert {:ok, runtime} =
             Runtime.claim_continuation(runtime, :lookup, "one", expected_revision: 1)

    assert {:ok, runtime} =
             Runtime.claim_continuation(runtime, :lookup, "two", expected_revision: 2)

    assert {:ok, runtime} = Runtime.disable(runtime, :lookup, expected_revision: 3)
    assert {:ok, runtime} = Runtime.release_continuation(runtime, "one", expected_revision: 4)

    assert {:ok, %{state: :draining, continuation_count: 1}} =
             Runtime.status(runtime, :lookup)

    orphaned =
      put_in(runtime.continuations["two"], %{
        mount_id: :lookup,
        definition_ref: "sha256:orphaned"
      })

    assert {:error, {:orphaned_skill_continuation, :lookup, "sha256:orphaned"}} =
             Runtime.continuation(orphaned, "two")
  end

  test "mount rejects non-declarative selectors even in an otherwise valid canonical Skill" do
    definition = operation_skill()

    tampered =
      definition.canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], fn rule ->
          %{rule | regex: ["lookup"]}
        end)
      end)

    assert {:ok, tampered} = SkillDefinition.from_canonical(tampered)

    assert {:error, {:invalid_runtime_skill_route, 0, :runtime_skill_requires_exact_text_route}} =
             Runtime.mount(runtime(), :lookup, tampered, expected_revision: 0)

    list_check =
      definition.canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], &Map.put(&1, :checks, [["text", "lookup"]]))
      end)

    assert {:ok, list_check} = SkillDefinition.from_canonical(list_check)

    assert {:ok, mounted} =
             Runtime.mount(runtime(), :list_check, list_check, expected_revision: 0)

    assert {:error, :runtime_skill_route_not_found} =
             Runtime.route(mounted, "missing", %{scope: :support})

    invalid_input =
      definition.canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0), :handler], &Map.put(&1, :input, :invalid))
      end)

    assert {:ok, invalid_input} = SkillDefinition.from_canonical(invalid_input)

    assert {:error, {:invalid_runtime_skill_route, 0, {:invalid_skill_operation_input, :invalid}}} =
             Runtime.mount(runtime(), :invalid_input, invalid_input, expected_revision: 0)

    missing_check =
      definition.canonical
      |> rewrite_component(:routing, fn payload ->
        update_in(payload, [:rules, Access.at(0)], &Map.put(&1, :checks, []))
      end)

    assert {:ok, missing_check} = SkillDefinition.from_canonical(missing_check)

    assert {:error, {:invalid_runtime_skill_route, 0, :runtime_skill_requires_exact_text_route}} =
             Runtime.mount(runtime(), :missing_check, missing_check, expected_revision: 0)
  end

  defp runtime do
    Runtime.new!(Agent, authority(),
      max_prompt_tokens: 1_024,
      kernel_prompt_tokens: 256,
      per_skill_prompt_cap: 512
    )
  end

  defp authority(overrides \\ []) do
    defaults = [
      operations: [:lookup],
      open_capabilities: [
        Runtime.capability(:mount),
        Runtime.capability(:replace),
        Runtime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard, :large],
      limits: %{max_tokens: 1_024}
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Envelope.new!()
  end

  defp operation_skill(opts \\ []) do
    id = Keyword.get(opts, :id, :lookup)
    version = Keyword.get(opts, :version, 1)
    operation = Keyword.get(opts, :operation, :lookup)
    conflicts = Keyword.get(opts, :conflicts, [])
    positive = Keyword.get(opts, :positive, ["lookup"])
    forbidden_tags = Keyword.get(opts, :forbidden_tags, [])
    input = Keyword.get(opts, :input, :text)

    SkillDefinition.new!(%{
      id: id,
      declared_version: version,
      publisher_ref: "host:test",
      applicability: %{
        scopes: [:support],
        forbidden_tags: forbidden_tags,
        positive: positive,
        negative: ["admin"],
        conflicts: conflicts
      },
      operation_refs: [operation],
      flows: [
        %{
          id: :support,
          routes: [
            %{
              label: :LOOKUP,
              match: {:exact, "lookup"},
              handler: {:operation, operation},
              input: input
            }
          ]
        }
      ]
    })
  end

  defp reply_skill(fragment_cap, content \\ "Hello {{input.text}}") do
    SkillDefinition.new!(%{
      id: :reply,
      publisher_ref: "host:test",
      applicability: %{scopes: [:chat], positive: ["hello"], negative: ["bye"]},
      prompt_budget: fragment_cap,
      prompt_fragments: [
        %{id: :reply, content: content, token_cap: fragment_cap}
      ],
      flows: [
        %{
          id: :chat,
          routes: [
            %{label: :HELLO, match: {:exact, "hello"}, handler: {:reply, :reply}}
          ]
        }
      ]
    })
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
end
