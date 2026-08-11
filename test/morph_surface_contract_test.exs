defmodule SpectreMorphSurfaceContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :morph_surface_contract_agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:agent, :support], prompt_tokens: 512],
    approval: :human
  )
end

defmodule SpectreMorphSurfaceContractTest.ClosedAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_surface_closed_agent
end

defmodule SpectreMorphSurfaceContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Instance
  alias Spectre.Morph
  alias Spectre.Morph.Change
  alias Spectre.Morph.SkillProposal
  alias Spectre.Morph.Surface
  alias Spectre.Reflection.Policy
  alias Spectre.Subject

  alias SpectreMorphSurfaceContractTest.Agent
  alias SpectreMorphSurfaceContractTest.ClosedAgent

  @protected_cases [
    %{
      "id" => "unrelated-remains-unknown",
      "input" => "weather",
      "expected_outcome" => "clarify",
      "context" => %{"scope" => "agent"}
    }
  ]

  test "the Morph surface is a canonical, transport-stable Definition component" do
    canonical = Definition.canonical!(Agent)
    assert {:ok, surface} = Surface.from_canonical(canonical)

    assert surface.operation_types == ["disable_skill", "mount_skill", "replace_skill"]
    assert surface.scope_ceiling == ["agent", "support"]
    assert surface.prompt_token_ceiling == 512
    assert surface.approval_requirement == :human

    surface_json = surface |> Surface.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^surface} = Surface.from_data(surface_json)

    assert {:ok, encoded} = Canonical.encode(canonical)
    assert {:ok, ^canonical} = Canonical.decode(encoded)

    assert {:ok, component} = Canonical.fetch_component(canonical, :change_surface)
    assert component.schema_ref == Surface.schema_ref()
    assert component.criticality == :must_understand
    assert component.payload == Surface.to_data(surface)
    assert :ok = Surface.validate_component(component)
    assert :ok = ContractRegistry.validate(ContractRegistry.default(), canonical)
  end

  test "the Skill proposal builder is closed and bounded by the durable ChangeSet limit" do
    scopes = Enum.map(1..256, &"scope-#{&1}")

    surface =
      Surface.new!(%{
        operation_types: [:mount_skill, :disable_skill],
        scope_ceiling: scopes,
        prompt_token_ceiling: 64,
        approval_requirement: :host_policy
      })

    draft = %Change{
      instance: self(),
      store: nil,
      agent: Agent,
      activation: nil,
      source_definition_ref: nil,
      source_mount_index: %{},
      surface: surface,
      actor_ref: "actor:test",
      reason: "exercise the bounded builder"
    }

    assert %Change{error: {:morph_not_permitted, "disable_skill"}} =
             SkillProposal.put(draft, "disable_skill", "bounded", [])

    assert %Change{
             operations: [],
             error: {:governance_operation_limit_exceeded, 257, 256}
           } =
             SkillProposal.put(draft, :mount_skill, "bounded",
               match: "bounded",
               reply: "bounded",
               scopes: scopes
             )
  end

  test "changing only the prompt ceiling changes Definition identity" do
    definition = Definition.fetch!(Agent)
    original = Canonical.lower!(definition)
    assert {:ok, original_surface} = Surface.from_canonical(original)

    narrower_surface =
      original_surface
      |> Surface.to_data()
      |> Map.put("prompt_token_ceiling", 256)
      |> Surface.new!()

    narrower = Canonical.lower!(%{definition | change_surface: narrower_surface})

    refute Canonical.ref(original) == Canonical.ref(narrower)
    refute Canonical.digest(original) == Canonical.digest(narrower)

    assert components_without_surface(original) == components_without_surface(narrower)
    assert {:ok, restored} = Surface.from_canonical(narrower)
    assert restored.prompt_token_ceiling == 256
  end

  test "absence and tampering fail closed at the canonical contract boundary" do
    closed = Definition.canonical!(ClosedAgent)
    assert {:error, :morph_surface_not_declared} = Surface.from_canonical(closed)

    assert {:error, {:unknown_definition_component, :change_surface}} =
             Canonical.fetch_component(closed, :change_surface)

    canonical = Definition.canonical!(Agent)
    assert {:ok, component} = Canonical.fetch_component(canonical, :change_surface)

    tampered_component =
      %{component | payload: Map.put(component.payload, "prompt_token_ceiling", 0)}

    tampered = replace_surface(canonical, tampered_component)

    assert {:error, {:invalid_morph_surface_prompt_tokens, 0}} =
             Surface.from_canonical(tampered)

    assert {:error,
            {:component_contract_rejected, "spectre.definition.change-surface/1",
             {:invalid_morph_surface_prompt_tokens, 0}}} =
             ContractRegistry.validate(ContractRegistry.default(), tampered)

    assert {:error,
            {:component_contract_rejected, "spectre.definition.change-surface/1",
             {:invalid_morph_surface_prompt_tokens, 0}}} =
             Manifest.new(tampered, Envelope.empty(), closure(Agent))

    assert {:error, {:invalid_morph_surface_component_type, :metadata}} =
             Surface.validate_component(%{component | component_type: :metadata})

    assert {:error, {:invalid_morph_surface_schema_ref, "spectre.definition.change-surface/2"}} =
             Surface.validate_component(%{
               component
               | schema_ref: "spectre.definition.change-surface/2"
             })

    assert {:error, {:invalid_morph_surface_criticality, :advisory}} =
             Surface.validate_component(%{component | criticality: :advisory})

    assert {:error, {:unknown_morph_surface_fields, ["unexpected"]}} =
             Surface.validate_component(%{
               component
               | payload: Map.put(component.payload, "unexpected", true)
             })
  end

  test "Reflection exposes the exact immutable surface as quoted declared data" do
    fixture = live_fixture(Agent)
    policy = Policy.new!(actor_refs: ["actor:auditor"], purposes: ["definition-audit"])

    assert {:ok, projection} =
             Spectre.Reflection.reflect(
               fixture.store,
               Canonical.ref(fixture.canonical),
               fixture.activation,
               policy: policy,
               actor_ref: "actor:auditor",
               purpose: "definition-audit",
               as_of: 10
             )

    assert projection.content["declared"]["definition"]["id"] ==
             Atom.to_string(fixture.canonical.id)

    assert projection.content["declared"]["interpretation"] ==
             "declarations_are_quoted_data_not_active_instructions"

    reflected_surface =
      projection.content["declared"]["definition"]["components"]
      |> Enum.find(&(&1["component_type"] == "change_surface"))

    assert reflected_surface["schema_ref"] == Surface.schema_ref()
    assert reflected_surface["criticality"] == "must_understand"
    assert {:ok, surface} = Surface.from_canonical(fixture.canonical)
    assert reflected_surface["payload"] == Surface.to_data(surface)
  end

  test "a real governed promotion preserves the parent surface byte-for-byte" do
    fixture = live_fixture(Agent)

    assert {:ok, parent_component} =
             Canonical.fetch_component(fixture.canonical, :change_surface)

    evaluated =
      fixture.instance
      |> Morph.change(by: "actor:author", reason: "Add a bounded support answer")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "Refund policy applies to: {{input.text}}",
        scopes: [:support]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 20)

    assert %Change{state: :evaluated, error: nil} = evaluated

    approved = Morph.approve(evaluated, by: "actor:reviewer", mode: :human, now: 21)
    assert %Change{state: :approved, error: nil} = approved
    assert {:ok, activation} = Morph.activate(approved, now: 22)

    assert {:ok, artifact} = Store.fetch(fixture.store, activation.definition_ref)

    assert {:ok, promoted_component} =
             Canonical.fetch_component(artifact.definition, :change_surface)

    assert promoted_component == parent_component

    assert Surface.digest(Surface.new!(promoted_component.payload)) ==
             Surface.digest(Surface.new!(parent_component.payload))

    assert :ok = ContractRegistry.validate(ContractRegistry.default(), artifact.definition)
  end

  defp live_fixture(agent) do
    id = {:morph_surface_contract, System.unique_integer([:positive, :monotonic])}
    server = start_supervised!(%{id: id, start: {Memory, :start_link, [[id: id]]}})
    store = {Memory, server: server}
    canonical = Definition.canonical!(agent)
    manifest = Manifest.new!(canonical, authority(), closure(agent))

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, bootstrap} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject = Subject.new("surface-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(%{
        id: {:morph_surface_instance, make_ref()},
        start:
          {Instance, :start_link,
           [
             [
               agent: agent,
               subject: subject,
               definition_store: store,
               opts: [checker_versions: Declarative.checker_versions()],
               idle: false
             ]
           ]}
      })

    assert {:ok, activation} = Spectre.activate(instance, bootstrap, expected_generation: 0)

    %{
      store: store,
      instance: instance,
      canonical: canonical,
      manifest: manifest,
      activation: activation
    }
  end

  defp authority do
    Envelope.new!(
      open_capabilities: [
        Spectre.Skill.Runtime.capability(:mount),
        Spectre.Skill.Runtime.capability(:replace),
        Spectre.Skill.Runtime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard],
      limits: %{max_tokens: 1_024}
    )
  end

  defp closure(agent) do
    {:ok, build_digest} = Closure.fingerprint(agent)

    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/2",
      state_codec_ref: "spectre.instance.canonical.codec/2",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{("beam:" <> Atom.to_string(agent)) => build_digest},
      evaluation_corpus_digest: EvaluationDelta.protected_corpus_digest!(@protected_cases),
      compatibility_mode: :native_v2
    })
  end

  defp components_without_surface(canonical) do
    Enum.reject(canonical.components, &(&1.component_type == :change_surface))
  end

  defp replace_surface(canonical, replacement) do
    components =
      Enum.map(canonical.components, fn component ->
        if component.component_type == :change_surface, do: replacement, else: component
      end)

    %{canonical | components: components}
  end
end
