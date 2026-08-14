defmodule SpectreMorphForgeReflectionBoundaryContractTest.ReflectionGenerator do
  @moduledoc false
  @behaviour Spectre.Projection

  @impl true
  def id, do: "spectre.projection.reflection"

  @impl true
  def version, do: 1

  @impl true
  def project(_canonical, _opts), do: {:ok, %{"plane" => "reflection"}}
end

defmodule SpectreMorphForgeReflectionBoundaryContractTest.OtherGenerator do
  @moduledoc false
  @behaviour Spectre.Projection

  @impl true
  def id, do: "spectre.projection.other"

  @impl true
  def version, do: 1

  @impl true
  def project(_canonical, _opts), do: {:ok, %{"plane" => "other"}}
end

defmodule SpectreMorphForgeReflectionBoundaryContractTest.OptionCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.boundary-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "test:boundary-profile"

  @impl true
  def critique(_reflection, _snapshot, opts), do: {:ok, Keyword.fetch!(opts, :reply)}
end

defmodule SpectreMorphForgeReflectionBoundaryContractTest.MetadataCrashCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: raise("metadata unavailable")

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "test:unused-profile"

  @impl true
  def critique(_reflection, _snapshot, _opts), do: {:ok, %{"opinion" => "unused"}}
end

defmodule SpectreMorphForgeReflectionBoundaryContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Forge.Critic
  alias Spectre.Governance.ChangeSet
  alias Spectre.Instance.Activation
  alias Spectre.Morph.Change
  alias Spectre.Morph.StableName
  alias Spectre.Morph.Surface
  alias Spectre.Morph.Surface.EvaluationObligations
  alias Spectre.Morph.Surface.MountIndex
  alias Spectre.Projection
  alias Spectre.Reflection
  alias Spectre.Skill.Definition, as: SkillDefinition

  alias __MODULE__.MetadataCrashCritic
  alias __MODULE__.OptionCritic
  alias __MODULE__.OtherGenerator
  alias __MODULE__.ReflectionGenerator

  test "Morph DSL rejects ambiguous declarations before they enter Definition identity" do
    for {suffix, declaration, message} <- [
          {"NonKeyword", "morph(:invalid)", ~r/morph expects a keyword list/},
          {"DuplicateOption",
           "morph(may_propose: [:mount_skill], may_propose: [:disable_skill], within: [scopes: [:agent], prompt_tokens: 8])",
           ~r/morph does not accept duplicate options/},
          {"UnknownOption", "morph(unknown: true, within: [scopes: [:agent], prompt_tokens: 8])",
           ~r/morph received unknown options/},
          {"UnknownWithin", "morph(within: [scopes: [:agent], prompt_tokens: 8, unknown: true])",
           ~r/morph :within received unknown options/}
        ] do
      assert_raise ArgumentError, message, fn -> compile_agent(suffix, declaration) end
    end

    assert_raise ArgumentError, ~r/morph may be declared only once/, fn ->
      compile_agent(
        "DuplicateDeclaration",
        """
        morph(within: [scopes: [:agent], prompt_tokens: 8])
        morph(within: [scopes: [:agent], prompt_tokens: 8])
        """
      )
    end
  end

  test "MountIndex fails closed on malformed canonical components and lookup identities" do
    assert {:error, {:unknown_definition_component, :skills}} =
             MountIndex.build(canonical([]))

    for payload <- [[], %{"mounts" => :not_a_list}] do
      assert {:error, :invalid_morph_surface_skill_component} =
               MountIndex.build(canonical([skills_component(payload)]))
    end

    assert {:error, {:invalid_morph_surface_mount, nil}} =
             MountIndex.build(canonical([skills_component(%{"mounts" => [nil]})]))

    assert {:ok, index} =
             MountIndex.build(
               canonical([skills_component(%{"mounts" => [%{"id" => 7, "value" => "kept"}]})])
             )

    assert {:ok, %{"value" => "kept"}} = MountIndex.fetch(index, "7")
    assert :error = MountIndex.fetch(index, nil)
    assert :error = MountIndex.fetch(index, "")
  end

  test "MountIndex derives a deterministic add, replace and disable diff" do
    same = %{"id" => "same", "definition_ref" => "sha256:same"}
    old = %{"id" => "changed", "definition_ref" => "sha256:old"}
    replacement = %{"id" => "changed", "definition_ref" => "sha256:new"}
    removed = %{"id" => "removed", "definition_ref" => "sha256:removed"}
    added = %{"id" => "added", "definition_ref" => "sha256:added"}

    parent = mounted_canonical([same, old, removed])
    candidate = mounted_canonical([replacement, added, same])

    assert {:ok, mutations} = MountIndex.mutations(parent, candidate)

    assert Enum.map(mutations, &{&1.mount_id, &1.operation}) == [
             {"added", :mount_skill},
             {"changed", :replace_skill},
             {"removed", :disable_skill}
           ]

    assert Enum.at(mutations, 1).parent == old
    assert Enum.at(mutations, 1).candidate == replacement
  end

  test "evaluation obligations reject malformed embedded runtime Skills without guessing" do
    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.runtime_skill(nil, "billing")

    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.runtime_skill(%{"definition" => "invalid"}, "billing")

    assert {:error, {:invalid_canonical_definition_fields, _fields}} =
             EvaluationObligations.runtime_skill(%{"definition" => %{}}, "billing")

    skill = reply_skill(scopes: ["billing"])
    mount = runtime_mount("billing", skill) |> Map.put("definition_ref", nil)

    assert {:error, {:invalid_morph_skill_definition_ref, "billing", nil}} =
             EvaluationObligations.runtime_skill(mount, "billing")
  end

  test "evaluation obligations require usable examples, scopes and one exact reply route" do
    surface = surface()
    empty_skill = reply_skill(scopes: ["billing"], positive: [], routes: [])

    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.disable_cases(surface, "billing", empty_skill)

    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.reply_cases(surface, "billing", empty_skill)

    invalid_surface = %{surface | scope_ceiling: nil}

    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.disable_cases(
               invalid_surface,
               "billing",
               reply_skill(scopes: ["billing"])
             )

    assert {:error, :skill_applicability_ceiling_exceeded} =
             EvaluationObligations.reply_cases(
               surface,
               "billing",
               reply_skill(scopes: [nil])
             )
  end

  test "evaluation obligations preserve stable atom scope identity and canonical case bytes" do
    assert {:ok, [evaluation_case]} =
             EvaluationObligations.reply_cases(
               surface(),
               :billing,
               reply_skill(scopes: [:billing])
             )

    assert evaluation_case["context"] == %{"scope" => "billing"}
    assert evaluation_case["input"] == "refund"
    assert evaluation_case["expected_output"] == "approved"
    assert evaluation_case["id"] == EvaluationObligations.case_id(:billing, "billing", "reply")
  end

  test "evaluation obligations accept the transported exact-check vector and reject other shapes" do
    skill = reply_skill(scopes: ["billing"])

    assert {:ok, [evaluation_case]} =
             EvaluationObligations.reply_cases(
               surface(),
               "billing",
               replace_route_checks(skill, [["text", "refund"]])
             )

    assert evaluation_case["input"] == "refund"

    assert {:error, {:morph_evaluation_obligation_not_derivable, "billing"}} =
             EvaluationObligations.reply_cases(
               surface(),
               "billing",
               replace_route_checks(skill, [["regex", "refund"]])
             )
  end

  test "supplied evaluation cases reject duplicates and malformed corpus entries" do
    evaluation_case = %{
      "id" => "duplicate",
      "input" => "refund",
      "expected_outcome" => "clarify",
      "llm" => "forbidden"
    }

    assert {:error, {:duplicate_morph_evaluation_obligation, 1}} =
             EvaluationObligations.verify(surface(), [], [evaluation_case, evaluation_case])

    assert {:error, {:invalid_morph_evaluation_obligation, 0, _reason}} =
             EvaluationObligations.verify(surface(), [], [%{"id" => "incomplete"}])
  end

  test "StableName comparisons never coerce malformed identities" do
    refute StableName.equal?(nil, "nil")
    refute StableName.equal?("", "")
    refute StableName.equal?([], "[]")
  end

  test "a Morph Change preserves its operation bound on empty, invalid and overflowing appends" do
    change = %Change{
      instance: self(),
      store: nil,
      agent: nil,
      activation: nil,
      source_definition_ref: nil,
      source_mount_index: %{},
      surface: surface(),
      actor_ref: nil,
      reason: nil
    }

    assert Change.append_operations(change, []) == change

    assert {:error, {:invalid_morph_operation_count, -1}} =
             Change.ensure_operation_capacity(change, -1)

    limit = ChangeSet.operation_limit()
    full = %{change | operations: List.duplicate(%{"type" => "mount_skill"}, limit)}
    overflowed = Change.append_operations(full, [%{"type" => "disable_skill"}])

    assert overflowed.operations == full.operations
    assert overflowed.error == {:governance_operation_limit_exceeded, limit + 1, limit}
  end

  test "Forge Critic classifies non-map adapter shapes and metadata failures" do
    %{reflection: reflection, snapshot: snapshot} = critic_fixture()

    for {reply, shape} <- [
          {%URI{scheme: "test"}, :map},
          {[], :list},
          {{:reply}, :tuple},
          {123, :other}
        ] do
      assert {:error, {:forge_critic_failed, 0, {:invalid_forge_critic_response, ^shape}}} =
               Critic.run([OptionCritic], reflection, snapshot, critic_opts: [reply: reply])
    end

    assert {:error, {:forge_critic_failed, 0, {:invalid_forge_critic_adapter, "critic"}}} =
             Critic.run(["critic"], reflection, snapshot)

    assert {:error,
            {:forge_critic_failed, 0,
             {:forge_critic_exception, MetadataCrashCritic, RuntimeError}}} =
             Critic.run([MetadataCrashCritic], reflection, snapshot)
  end

  test "Forge Critic verifies projection integrity and the exact Reflection generator" do
    fixture = critic_fixture()

    assert {:ok, other} = Projection.generate(fixture.canonical, OtherGenerator)

    assert {:error, :invalid_forge_reflection_projection} =
             Critic.run([], other, fixture.snapshot)

    altered = %{fixture.reflection | digest: String.duplicate("0", 64)}
    assert {:error, :projection_digest_mismatch} = Critic.run([], altered, fixture.snapshot)
  end

  test "Reflection validates request shapes, map policies and registry-bearing fetches" do
    assert {:error, {:invalid_reflection_request, :map, :list}} =
             Reflection.reflect(nil, nil, %{})

    assert {:error, {:invalid_reflection_request, :tuple, :map}} =
             Reflection.reflect(nil, nil, {:activation}, %{})

    activation = struct(Activation)

    assert {:error, :reflection_actor_not_authorized} =
             Reflection.reflect(nil, nil, activation,
               policy: %{actor_refs: [], purposes: []},
               actor_ref: "operator:test",
               purpose: "inspect",
               as_of: 0
             )

    policy = %{
      actor_refs: ["operator:test"],
      purposes: ["inspect"],
      max_evidence: 1
    }

    assert {:error, {:invalid_definition_store, 123}} =
             Reflection.reflect(123, nil, activation,
               policy: policy,
               actor_ref: "operator:test",
               purpose: "inspect",
               as_of: 0,
               component_registry: ContractRegistry.default()
             )
  end

  defp compile_agent(suffix, declaration) do
    Code.compile_string("""
    defmodule SpectreMorphForgeReflectionBoundaryContractTest.#{suffix} do
      use Spectre.Agent, id: :#{Macro.underscore(suffix)}
      #{declaration}
    end
    """)
  end

  defp critic_fixture do
    canonical = canonical([])
    assert {:ok, reflection} = Projection.generate(canonical, ReflectionGenerator)
    assert {:ok, snapshot} = ExperienceStore.empty_snapshot(Canonical.ref(canonical), 0)
    %{canonical: canonical, reflection: reflection, snapshot: snapshot}
  end

  defp surface do
    Surface.new!(
      operation_types: [:mount_skill, :replace_skill, :disable_skill],
      scope_ceiling: ["billing"],
      prompt_token_ceiling: 256,
      approval_requirement: :human
    )
  end

  defp reply_skill(opts) do
    scopes = Keyword.fetch!(opts, :scopes)
    positive = Keyword.get(opts, :positive, ["refund"])

    routes =
      Keyword.get(opts, :routes, [
        %{
          label: "REFUND",
          match: %{kind: "exact", value: "refund"},
          handler: %{kind: "reply", prompt: "billing:reply"}
        }
      ])

    SkillDefinition.new!(%{
      id: "billing",
      declared_version: 1,
      publisher_ref: "test:morph-boundary",
      applicability: %{scopes: scopes, positive: positive, negative: []},
      prompt_budget: 256,
      prompt_fragments: [
        %{
          id: "billing:reply",
          content: "approved",
          token_cap: 64,
          budget_class: "small"
        }
      ],
      flows: [%{id: "billing", routes: routes}]
    })
  end

  defp runtime_mount(id, %SkillDefinition{} = skill) do
    %{
      "id" => id,
      "definition" => skill |> SkillDefinition.canonical() |> Canonical.to_data(),
      "definition_ref" => skill |> SkillDefinition.ref() |> to_string()
    }
  end

  defp replace_route_checks(%SkillDefinition{} = skill, checks) do
    canonical = SkillDefinition.canonical(skill)

    components =
      Enum.map(canonical.components, fn
        %Component{component_type: :routing} = component ->
          [route] = component.payload.rules
          %{component | payload: %{component.payload | rules: [%{route | checks: checks}]}}

        component ->
          component
      end)

    rewritten = Canonical.new!(%{canonical | components: components})
    assert {:ok, rewritten_skill} = SkillDefinition.from_canonical(rewritten)
    rewritten_skill
  end

  defp mounted_canonical(mounts),
    do: canonical([skills_component(%{"mounts" => mounts})])

  defp skills_component(payload) do
    Component.new!(
      component_type: :skills,
      schema_ref: "spectre.definition.skills/1",
      criticality: :must_understand,
      payload: payload
    )
  end

  defp canonical(components) do
    Canonical.new!(
      kind: :agent,
      id: :morph_forge_reflection_boundary,
      declared_version: 1,
      origin: :runtime,
      components: components
    )
  end
end
