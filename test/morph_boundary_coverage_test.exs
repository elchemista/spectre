defmodule SpectreMorphBoundaryCoverageTest.StaticSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :morph_boundary_static,
    version: 1,
    applicability: %{scopes: [:agent]}
end

defmodule SpectreMorphBoundaryCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :morph_boundary_agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:support, :agent], prompt_tokens: 256],
    approval: :human
  )
end

defmodule SpectreMorphBoundaryCoverageTest.CompiledAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_boundary_compiled_agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:agent], prompt_tokens: 512],
    approval: :human
  )

  skill(SpectreMorphBoundaryCoverageTest.StaticSkill, as: :compiled)
end

defmodule SpectreMorphBoundaryCoverageTest.DisableOnlyAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_boundary_disable_only

  morph(
    may_propose: [:disable_skill],
    within: [scopes: [:agent], prompt_tokens: 32]
  )
end

defmodule SpectreMorphBoundaryCoverageTest.HostPolicyAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_boundary_host_policy

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:agent], prompt_tokens: 256],
    approval: :host_policy
  )
end

defmodule SpectreMorphBoundaryCoverageTest.ClosedAgent do
  @moduledoc false
  use Spectre.Agent, id: :morph_boundary_closed
end

defmodule SpectreMorphBoundaryCoverageTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.Composer
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.Approval.Policy, as: ApprovalPolicy
  alias Spectre.Instance
  alias Spectre.Morph
  alias Spectre.Morph.Change
  alias Spectre.Morph.Surface
  alias Spectre.Skill.Applicability
  alias Spectre.Subject

  alias SpectreMorphBoundaryCoverageTest.Agent
  alias SpectreMorphBoundaryCoverageTest.ClosedAgent
  alias SpectreMorphBoundaryCoverageTest.CompiledAgent
  alias SpectreMorphBoundaryCoverageTest.DisableOnlyAgent
  alias SpectreMorphBoundaryCoverageTest.HostPolicyAgent

  @protected_cases [
    %{
      "id" => "boundary-unrelated-remains-unknown",
      "input" => "weather",
      "expected_outcome" => "clarify",
      "context" => %{"scope" => "agent"},
      "llm" => "forbidden"
    }
  ]

  test "Surface accepts one normalized vocabulary and rejects ambiguous transport shapes" do
    assert Surface.operation_types() == ["disable_skill", "mount_skill", "replace_skill"]

    assert {:ok, surface} =
             Surface.new(
               operation_types: [:replace_skill, :mount_skill, :mount_skill],
               scope_ceiling: [:support, :agent, :support],
               prompt_token_ceiling: 256,
               approval_requirement: :human
             )

    assert surface.operation_types == ["mount_skill", "replace_skill"]
    assert surface.scope_ceiling == ["agent", "support"]
    assert surface.approval_requirement == :human
    assert {:ok, ^surface} = Surface.new(surface)
    assert {:ok, ^surface} = surface |> Surface.to_data() |> Surface.from_data()
    assert Surface.allows?(surface, :mount_skill)
    assert Surface.allows?(surface, "replace_skill")
    refute Surface.allows?(surface, :disable_skill)
    refute Surface.allows?(surface, :rewrite_kernel)

    assert {:error, {:invalid_morph_surface, :list}} =
             Surface.new(operation_types: [:mount_skill], operation_types: [:replace_skill])

    assert {:error, {:duplicate_morph_surface_field, "operation_types"}} =
             Surface.new(%{
               "operation_types" => ["mount_skill"],
               :operation_types => [:replace_skill],
               "scope_ceiling" => ["agent"],
               "prompt_token_ceiling" => 16
             })

    assert {:error, {:unknown_morph_surface_fields, [:escape_hatch]}} =
             Surface.new(%{
               operation_types: [:mount_skill],
               scope_ceiling: [:agent],
               prompt_token_ceiling: 16,
               escape_hatch: true
             })

    assert {:error, {:unsupported_morph_surface_schema, 2}} =
             Surface.new(%{
               schema_version: 2,
               operation_types: [:mount_skill],
               scope_ceiling: [:agent],
               prompt_token_ceiling: 16
             })

    for {attrs, reason} <- [
          {%{operation_types: [], scope_ceiling: [:agent], prompt_token_ceiling: 16},
           {:invalid_morph_surface_operations, []}},
          {%{
             operation_types: [:rewrite_kernel],
             scope_ceiling: [:agent],
             prompt_token_ceiling: 16
           }, {:unsupported_morph_operation, "rewrite_kernel"}},
          {%{operation_types: [:mount_skill], scope_ceiling: [], prompt_token_ceiling: 16},
           {:invalid_morph_surface_scopes, []}},
          {%{
             operation_types: [:mount_skill],
             scope_ceiling: [:agent, ""],
             prompt_token_ceiling: 16
           }, {:invalid_morph_surface_scopes, [:agent, ""]}},
          {%{operation_types: [:mount_skill], scope_ceiling: [:agent], prompt_token_ceiling: 0},
           {:invalid_morph_surface_prompt_tokens, 0}},
          {%{
             operation_types: [:mount_skill],
             scope_ceiling: [:agent],
             prompt_token_ceiling: 16,
             approval_requirement: :self_approved
           }, {:invalid_morph_surface_approval, "self_approved"}}
        ] do
      assert {:error, ^reason} = Surface.new(attrs)
    end

    assert {:error, {:invalid_morph_surface, :tuple}} = Surface.new({:not, :data})
    assert {:error, {:invalid_morph_surface, :binary}} = Surface.new("not data")

    assert_raise ArgumentError, ~r/invalid Morph surface/, fn ->
      Surface.new!(operation_types: [], scope_ceiling: [:agent], prompt_token_ceiling: 1)
    end

    ceilings = Surface.applicability_ceilings(surface, ["b", "a", "b"])
    assert Map.keys(ceilings) |> Enum.sort() == ["a", "b"]
    assert ceilings["a"].scopes == ["agent", "support"]
    assert ceilings["a"].positive == []

    non_agent = %{Definition.canonical!(Agent) | kind: :skill}
    assert {:error, {:morph_surface_requires_agent, :skill}} = Surface.from_canonical(non_agent)
  end

  test "Surface.constrain computes a meet and fails closed outside the declared proposal ceiling" do
    parent = Definition.canonical!(Agent)
    surface = surface!(parent)
    mount = operation("mount_skill", %{"mount_id" => "refunds"})
    eval = operation("add_eval_case", %{"case" => valid_eval_case()})

    assert {:ok, constrained} =
             Surface.constrain(parent, [mount, eval], prompt_token_ceiling: 80)

    assert constrained[:prompt_token_ceiling] == 80

    assert constrained[:applicability_ceilings]["refunds"].scopes ==
             Surface.applicability_ceilings(surface, ["refunds"])["refunds"].scopes

    assert constrained[:applicability_ceilings]["refunds"].schema_version == 1

    narrower =
      Applicability.new!(scopes: ["agent"])
      |> Applicability.to_data()

    assert {:ok, configured} =
             Surface.constrain(parent, [mount],
               prompt_token_ceiling: 32,
               applicability_ceilings: %{"refunds" => narrower}
             )

    assert configured[:prompt_token_ceiling] == 32
    assert configured[:applicability_ceilings]["refunds"]["scopes"] == ["agent"]

    assert {:error, {:morph_operation_outside_surface, "update_authority"}} =
             Surface.constrain(parent, [operation("update_authority", %{})], [])

    for mount_id <- [nil, "", "Elixir.System"] do
      assert {:error, {:invalid_morph_surface_mount_id, ^mount_id}} =
               Surface.constrain(
                 parent,
                 [operation("mount_skill", %{"mount_id" => mount_id})],
                 []
               )
    end

    assert {:error, {:invalid_morph_prompt_ceiling, :infinity}} =
             Surface.constrain(parent, [mount], prompt_token_ceiling: :infinity)

    assert {:error, {:invalid_morph_constraint_options, :tuple}} =
             Surface.constrain(parent, [mount], {:bad})

    assert {:error, {:invalid_morph_constraint_options, :other}} =
             Surface.constrain(parent, :not_operations, [])

    wildcard = Applicability.new!(scopes: []) |> Applicability.to_data()

    assert {:error, :skill_applicability_ceiling_exceeded} =
             Surface.constrain(parent, [mount], applicability_ceilings: %{"refunds" => wildcard})

    closed = Definition.canonical!(ClosedAgent)
    original_opts = [prompt_token_ceiling: 9_999]

    assert {:ok, ^original_opts} =
             Surface.constrain(closed, [operation("anything", %{})], original_opts)
  end

  test "Surface.verify_candidate re-derives mutations and requires sealed prompt and applicability ceilings" do
    parent = Definition.canonical!(Agent)
    surface = surface!(parent)
    mounted = put_mounts(parent, [%{"id" => "refunds", "definition" => %{}}])
    ceilings = Surface.applicability_ceilings(surface, ["refunds"])

    assert :ok = Surface.verify_candidate(parent, mounted, 128, ceilings)

    assert {:error, {:morph_prompt_ceiling_not_sealed, 257, 256}} =
             Surface.verify_candidate(parent, mounted, 257, ceilings)

    assert {:error, {:morph_applicability_ceiling_not_sealed, "refunds"}} =
             Surface.verify_candidate(parent, mounted, 128, %{})

    too_wide =
      Applicability.new!(scopes: [])
      |> Applicability.to_data()

    assert {:error, :skill_applicability_ceiling_exceeded} =
             Surface.verify_candidate(parent, mounted, 128, %{"refunds" => too_wide})

    narrower_surface =
      Surface.new!(
        operation_types: [:mount_skill],
        scope_ceiling: [:agent],
        prompt_token_ceiling: 32,
        approval_requirement: :human
      )

    assert {:error, :governance_change_surface_is_immutable} =
             Surface.verify_candidate(
               parent,
               replace_surface(mounted, Surface.to_data(narrower_surface)),
               128,
               ceilings
             )

    metadata_changed =
      replace_component(mounted, :metadata, fn component ->
        %{component | payload: Map.put(component.payload, "morph_tamper", true)}
      end)

    assert {:error, :morph_changed_component_outside_surface} =
             Surface.verify_candidate(parent, metadata_changed, 128, ceilings)

    disable_parent = Definition.canonical!(DisableOnlyAgent)
    forbidden_mount = put_mounts(disable_parent, [%{"id" => "refunds"}])

    assert {:error, {:morph_operation_outside_surface, "mount_skill", "refunds"}} =
             Surface.verify_candidate(
               disable_parent,
               forbidden_mount,
               16,
               Surface.applicability_ceilings(surface!(disable_parent), ["refunds"])
             )

    duplicate = put_mounts(parent, [%{"id" => "same"}, %{"id" => "same"}])

    assert {:error, {:duplicate_morph_surface_mount, "same"}} =
             Surface.verify_candidate(parent, duplicate, 128, %{})

    malformed = put_mounts(parent, [%{"id" => ""}])

    assert {:error, {:invalid_morph_surface_mount, ""}} =
             Surface.verify_candidate(parent, malformed, 128, %{})

    closed = Definition.canonical!(ClosedAgent)
    assert :ok = Surface.verify_candidate(closed, closed, nil, nil)

    assert {:error, :governance_change_surface_is_immutable} =
             Surface.verify_candidate(closed, parent, nil, nil)
  end

  test "Morph public boundary preserves the first error and never turns malformed intent into a proposal" do
    %{instance: instance} = baseline(Agent)

    for {opts, expected} <- [
          {:not_keywords, {:invalid_morph_options, :not_keywords}},
          {[123], {:invalid_morph_options, [123]}},
          {[by: "actor", reason: "one", reason: "two"], :duplicate_morph_options},
          {[by: "actor", reason: "why", surprise: true], {:unknown_morph_options, [:surprise]}},
          {[reason: "why"], {:morph_requires, :by, nil}},
          {[by: "actor"], {:morph_requires, :reason, nil}},
          {[by: "actor", reason: "why", evidence: URI.parse("/opaque")],
           {:invalid_morph_field, :evidence, URI.parse("/opaque")}}
        ] do
      assert %Change{error: ^expected} = Morph.change(instance, opts)
    end

    original = Morph.change(instance, by: "actor", reason: "boundary")
    assert Morph.status(original).state == :draft
    assert Morph.status(original).operation_count == 0
    assert {:error, :morph_not_evaluated} = Morph.explain(original)

    for {fun, expected} <- [
          {fn -> Morph.mount_skill(original, nil, match: "x", reply: "y") end,
           {:invalid_morph_skill_id, nil}},
          {fn -> Morph.mount_skill(original, "Elixir.System", match: "x", reply: "y") end,
           {:morph_code_reference_forbidden, "Elixir.System"}},
          {fn -> Morph.mount_skill(original, "x", %{match: "x"}) end,
           {:invalid_morph_options, %{match: "x"}}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: "y", unknown: true) end,
           {:unknown_morph_options, [:unknown]}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: nil) end,
           {:morph_requires, :reply, nil}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: "y", never: :all) end,
           {:invalid_morph_negative_examples, :all}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: "y", never: [""]) end,
           {:invalid_morph_negative_examples, [""]}},
          {fn ->
             Morph.mount_skill(original, "x",
               match: "x",
               reply: "y",
               token_cap: 0,
               scopes: [:agent]
             )
           end, {:morph_prompt_cap_exceeded, 0, 256}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: "{{input.meta}}") end,
           {:unsupported_morph_reply_placeholder, ["input.meta"]}},
          {fn -> Morph.mount_skill(original, "x", match: "x", reply: "{{ input.text }}") end,
           {:unsupported_morph_reply_placeholder, [" input.text "]}},
          {fn -> Morph.replace_skill(original, "absent", match: "x", reply: "y") end,
           {:morph_runtime_skill_not_found, "absent"}},
          {fn -> Morph.disable_skill(original, "absent") end,
           {:morph_runtime_skill_not_found, "absent"}}
        ] do
      assert %Change{error: ^expected} = fun.()
    end

    %{instance: compiled_instance} = baseline(CompiledAgent)
    compiled_draft = Morph.change(compiled_instance, by: "actor", reason: "compiled is immutable")

    assert %Change{error: {:morph_compiled_skill_is_immutable, "compiled"}} =
             Morph.replace_skill(compiled_draft, "compiled", match: "x", reply: "y")

    assert %Change{error: {:morph_compiled_skill_is_immutable, "compiled"}} =
             Morph.disable_skill(compiled_draft, "compiled")

    compiled_and_runtime =
      compiled_draft
      |> Morph.mount_skill("runtime-refunds", match: "refund", reply: "runtime answer")
      |> Morph.evaluate(cases: @protected_cases, now: 9)

    assert %Change{state: :evaluated, error: nil} = compiled_and_runtime
    assert compiled_and_runtime.delta.passed
    assert Enum.any?(compiled_and_runtime.delta.candidate_owned_results, & &1["passed"])

    assert %Change{error: :morph_has_no_changes} = Morph.evaluate(original, now: 10)
    assert %Change{error: {:invalid_morph_options, :bad}} = Morph.evaluate(original, :bad)

    draft =
      Morph.mount_skill(original, "refunds",
        match: "refund",
        reply: "answer",
        scopes: [:agent]
      )

    assert draft.error == nil
    assert length(draft.operations) == 2

    assert %Change{error: {:invalid_morph_prompt_ceiling, :wide}} =
             Morph.evaluate(draft, prompt_token_ceiling: :wide)

    assert %Change{error: :morph_requires_both_receipts_and_delta} =
             Morph.evaluate(draft, receipts: [], now: 11)

    hostile_evidence =
      instance
      |> Morph.change(by: "actor", reason: "non portable evidence", evidence: %{"pid" => self()})
      |> Morph.mount_skill("hostile", match: "hostile", reply: "blocked", scopes: [:agent])
      |> Morph.evaluate(cases: @protected_cases, now: 12)

    assert hostile_evidence.error == :invalid_morph_evidence

    prefailed = Morph.change(instance, :bad)
    assert Morph.mount_skill(prefailed, "ignored", match: "x", reply: "y") == prefailed
    assert Morph.disable_skill(prefailed, "ignored") == prefailed
    assert Morph.evaluate(prefailed) == prefailed
    assert Morph.approve(prefailed) == prefailed
    assert Morph.reject(prefailed) == prefailed
    assert {:error, {:invalid_morph_options, :bad}} = Morph.activate(prefailed)
    assert {:error, {:invalid_morph_options, :bad}} = Morph.explain(prefailed)
  end

  test "change requires a stored active Definition and malformed durable refs fail closed" do
    unstored = start_unstored_instance(Agent)

    assert %Change{error: :morph_requires_definition_store} =
             Morph.change(unstored, by: "actor", reason: "there is no durable anchor")

    %{instance: unactivated} = baseline(Agent, activate?: false)

    assert %Change{error: :morph_requires_activation} =
             Morph.change(unactivated, by: "actor", reason: "activation is still absent")

    %{instance: instance} = baseline(Agent)
    assert %Change{error: {:morph_requires, :by, nil}} = Morph.change(instance)

    draft = Morph.change(instance, by: "actor", reason: "exercise the closed boundary")

    assert %Change{error: {:morph_requires_exact_match, nil}} =
             Morph.mount_skill(draft, "default-options")

    assert %Change{error: {:morph_runtime_skill_not_found, "default-options"}} =
             Morph.replace_skill(draft, "default-options")

    assert %Change{error: {:invalid_morph_options, :bad}} = Morph.approve(draft, :bad)
    assert %Change{error: {:invalid_morph_options, :bad}} = Morph.reject(draft, :bad)
    assert {:error, {:invalid_morph_options, :bad}} = Morph.activate(draft, :bad)

    assert %Change{error: {:invalid_morph_options, [123]}} = Morph.approve(draft, [123])
    assert %Change{error: {:invalid_morph_options, [123]}} = Morph.reject(draft, [123])
    assert {:error, {:invalid_morph_options, [123]}} = Morph.activate(draft, [123])

    {:ok, absent_ref} =
      Spectre.Definition.Ref.parse("sha256:" <> String.duplicate("0", 64))

    absent_definition = %{draft | activation: %{draft.activation | definition_ref: absent_ref}}

    assert %Change{
             error:
               {:morph_change_definition_ref_mismatch, _pinned_definition_ref,
                _absent_definition_ref}
           } =
             Morph.replace_skill(absent_definition, "missing", match: "x", reply: "y")

    malformed_definition = %{draft | activation: %{draft.activation | definition_ref: "bad-ref"}}

    assert %Change{
             error: {:morph_change_definition_ref_mismatch, _pinned_definition_ref, "bad-ref"}
           } =
             Morph.replace_skill(malformed_definition, "missing", match: "x", reply: "y")
  end

  test "core rejects a tampered replacement of a compiled Skill mount" do
    %{instance: instance} = baseline(CompiledAgent)

    draft =
      instance
      |> Morph.change(by: "actor:author", reason: "attempt to replace compiled behaviour")
      |> Morph.mount_skill("compiled", match: "x", reply: "runtime replacement")

    [mount_operation, evaluation_operation] = draft.operations
    forged_operation = Map.put(mount_operation, "type", "replace_skill")

    rejected =
      %{draft | operations: [forged_operation, evaluation_operation]}
      |> Morph.evaluate(cases: @protected_cases, now: 13)

    assert rejected.error == {:morph_compiled_skill_is_immutable, "compiled"}
    assert Instance.activation(instance).generation == 1

    assert {:ok, turn} = Spectre.turn(instance, "x")
    assert {:no_response, _result} = turn.decision
  end

  test "approval is a separate durable commit and rejection cannot change live behavior" do
    %{instance: instance, bootstrap: bootstrap, store: store} = baseline(Agent)

    evaluated =
      instance
      |> Morph.change(by: "actor:author", reason: "learn a bounded answer")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "bounded {{input.text}}",
        scopes: [:agent]
      )
      |> Morph.evaluate(cases: @protected_cases, now: 100)

    assert %Change{state: :evaluated, error: nil} = evaluated
    assert evaluated.delta.passed
    assert {:ok, report} = Morph.explain(evaluated)
    assert report["generator_id"] == "spectre.projection.human-report"
    assert is_binary(report["digest"])
    assert report["structural_changes"] != []

    assert %Change{error: {:morph_state, :draft, :evaluated}} =
             Morph.mount_skill(evaluated, "too-late", match: "late", reply: "late")

    assert %Change{error: {:morph_state, :draft, :evaluated}} =
             Morph.disable_skill(evaluated, "refunds")

    assert %Change{error: {:morph_state, :draft, :evaluated}} =
             Morph.evaluate(evaluated, now: 101)

    assert %Change{error: {:morph_requires_human_approval, :automatic}} =
             Morph.approve(evaluated, mode: :automatic, now: 101)

    assert %Change{error: {:morph_requires, :by, ""}} =
             Morph.approve(evaluated, by: "", mode: :human, now: 101)

    evaluated_resume = Morph.resume(instance, evaluated.ref, by: "actor:reviewer")
    assert evaluated_resume.state == :evaluated
    assert evaluated_resume.ref == evaluated.ref

    {:ok, automatic_policy} =
      ApprovalPolicy.new(%{
        low: :automatic,
        medium: :automatic,
        high: :automatic,
        critical: :automatic
      })

    approved =
      Morph.approve(evaluated,
        by: "actor:reviewer",
        policy: automatic_policy,
        now: 101
      )

    assert approved.state == :approved

    assert {:ok, approved_candidate} = Store.fetch_candidate(store, approved.ref)

    assert {:ok, approval_receipt} =
             Store.fetch_gate_receipt(
               store,
               approved_candidate.governance.approval_receipt_ref
             )

    assert approval_receipt.provenance["mode"] == "human"

    resumed = Morph.resume(instance, approved.ref, by: "actor:operator")
    assert resumed.state == :approved
    assert resumed.ref == approved.ref

    assert {:ok, before_activation} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = before_activation.decision

    assert {:ok, activation} = Morph.activate(resumed, now: 102)
    assert activation.generation == 2

    assert {:ok, learned} = Spectre.turn(instance, "refund", skill_context: %{"scope" => "agent"})
    assert {:reply, "bounded refund", _turn_ref} = learned.observable

    rejected =
      instance
      |> Morph.change(by: "actor:author", reason: "propose a second answer")
      |> Morph.mount_skill("greetings", match: "hello", reply: "hello", scopes: [:agent])
      |> Morph.evaluate(cases: @protected_cases, now: 110)

    assert %Change{error: {:morph_requires, :by, nil}} =
             Morph.reject(rejected, reason: "not wanted", now: 111)

    assert %Change{error: {:morph_requires, :reason, nil}} =
             Morph.reject(rejected, by: "actor:reviewer", now: 111)

    rejected =
      Morph.reject(rejected,
        by: "actor:reviewer",
        reason: "behavior is not desired",
        now: 111
      )

    assert rejected.state == :rejected
    assert Morph.status(rejected).candidate_ref == to_string(rejected.ref)
    assert {:error, {:morph_state, :approved, :rejected}} = Morph.activate(rejected, now: 112)

    resumed_rejection = Morph.resume(instance, rejected.ref)
    assert resumed_rejection.state == :rejected
    assert resumed_rejection.ref == rejected.ref

    assert {:ok, unchanged} =
             Spectre.turn(instance, "hello", skill_context: %{"scope" => "agent"})

    assert {:no_response, _result} = unchanged.decision

    missing_ref = "candidate:sha256:" <> String.duplicate("0", 64)
    assert %Change{error: :governance_candidate_not_found} = Morph.resume(instance, missing_ref)

    assert %Change{error: :candidate_is_not_governed} = Morph.resume(instance, bootstrap)

    assert %Change{error: {:invalid_morph_options, :bad}} =
             Morph.resume(instance, approved.ref, :bad)

    assert %Change{error: {:unknown_morph_options, [:force]}} =
             Morph.resume(instance, approved.ref, force: true)

    assert %Change{error: {:invalid_candidate_ref, "not-a-candidate-ref"}} =
             Morph.resume(instance, "not-a-candidate-ref")
  end

  test "Morph seals the Instance execution profile at activation and at every turn" do
    %{instance: overridden, bootstrap: bootstrap} =
      baseline(Agent,
        activate?: false,
        runtime_opts: [via: [:regex], checker_versions: Declarative.checker_versions()]
      )

    assert {:error, {:morph_instance_execution_profile_overridden, [:via]}} =
             Spectre.activate(overridden, bootstrap, expected_generation: 0)

    %{instance: instance} = baseline(Agent)

    assert {:error, {:morph_turn_execution_profile_overridden, [:input_pipeline, :via]}} =
             Spectre.turn(instance, "refund", via: [:regex], input_pipeline: [])

    assert {:ok, unmodified} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = unmodified.decision
  end

  test "externally replayed gate evidence is accepted only for the identical proposal" do
    %{instance: instance, store: store} = baseline(Agent)

    draft =
      instance
      |> Morph.change(by: "actor:evaluator", reason: "evaluate exact portable evidence")
      |> Morph.mount_skill("evidence",
        match: {:exact, "evidence"},
        reply: "verified {{input.text}}",
        token_cap: 64,
        scopes: [:agent]
      )

    evaluated =
      Morph.evaluate(draft,
        cases: @protected_cases,
        prompt_token_ceiling: 192,
        now: 700
      )

    assert %Change{state: :evaluated, error: nil} = evaluated
    assert evaluated.delta.passed
    assert {:ok, evaluated_candidate} = Store.fetch_candidate(store, evaluated.ref)

    receipts =
      evaluated_candidate.governance.gate_receipt_refs
      |> Enum.map(fn receipt_ref ->
        assert {:ok, receipt} = Store.fetch_gate_receipt(store, receipt_ref)
        receipt
      end)
      |> Enum.filter(&(&1.gate_class in [:replay, :regression]))

    assert Enum.map(receipts, & &1.gate_class) |> MapSet.new() ==
             MapSet.new([:replay, :regression])

    replayed =
      Morph.evaluate(draft,
        cases: @protected_cases,
        prompt_token_ceiling: 192,
        receipts: receipts,
        delta: evaluated.delta,
        now: 700
      )

    assert %Change{state: :evaluated, error: nil} = replayed
    assert replayed.ref == evaluated.ref
    assert replayed.delta == evaluated.delta
    assert replayed.report == evaluated.report

    different =
      instance
      |> Morph.change(by: "actor:evaluator", reason: "different proposal")
      |> Morph.mount_skill("different",
        match: "different",
        reply: "different",
        scopes: [:agent]
      )
      |> Morph.evaluate(
        cases: @protected_cases,
        receipts: receipts,
        delta: evaluated.delta,
        now: 701
      )

    assert different.state == :draft
    assert different.error != nil
    refute different.ref
  end

  test "host-policy approval remains subordinate to the independent risk policy" do
    %{instance: instance} = baseline(HostPolicyAgent)

    evaluated =
      instance
      |> Morph.change(by: "actor:author", reason: "host policy still observes risk")
      |> Morph.mount_skill("host-policy", match: "host", reply: "host answer")
      |> Morph.evaluate(cases: @protected_cases, now: 750)

    assert %Change{state: :evaluated, error: nil} = evaluated

    assert %Change{error: :candidate_risk_requires_human_approval} =
             Morph.approve(evaluated, mode: :automatic, now: 751)

    approved = Morph.approve(evaluated, by: "actor:reviewer", mode: :human, now: 751)
    assert %Change{state: :approved, error: nil} = approved
    assert Morph.status(approved).activation_generation == 1

    assert {:ok, activation} = Morph.activate(approved, now: 752)
    assert activation.generation == 2

    assert {:ok, turn} = Spectre.turn(instance, "host")
    assert {:reply, "host answer", _turn_ref} = turn.observable
  end

  test "rebase revalidates every operation against the currently active canonical surface" do
    %{instance: instance} = baseline(Agent)

    draft =
      instance
      |> Morph.change(by: "actor:author", reason: "portable draft")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "answer",
        scopes: [:agent]
      )

    assert draft.error == nil
    assert %Change{error: {:invalid_morph_options, :bad}} = Morph.rebase(draft, :bad)

    assert %Change{error: :duplicate_morph_options} =
             Morph.rebase(draft, [{:by, "one"}, {:by, "two"}])

    assert %Change{error: {:unknown_morph_options, [:force]}} =
             Morph.rebase(draft, force: true)

    forbidden = %{"type" => "update_authority", "payload" => %{}}
    forged = %{draft | operations: [forbidden | draft.operations]}

    assert %Change{error: {:morph_not_permitted, "update_authority"}} = Morph.rebase(forged)

    malformed_eval = %{
      "type" => "add_eval_case",
      "payload" => %{"case" => %{"id" => "missing-required-fields"}}
    }

    forged_eval = %{draft | operations: [malformed_eval]}
    assert %Change{error: {:morph_not_permitted, "add_eval_case"}} = Morph.rebase(forged_eval)

    rebased = Morph.rebase(draft, reason: "explicitly rebased")
    assert rebased.error == nil
    assert rebased.reason == "explicitly rebased"
    assert rebased.operations == draft.operations
    assert rebased.activation == Spectre.activation(instance)

    assert {:ok, composed_ref} = compose_draft(draft, 800)
    resumed_composed = Morph.resume(instance, composed_ref, by: "actor:reviewer")
    assert resumed_composed.state == :draft
    assert resumed_composed.ref == composed_ref
    assert resumed_composed.report == nil
    assert resumed_composed.error == nil
  end

  defp baseline(agent, opts \\ []) do
    id = {:morph_boundary, System.unique_integer([:positive, :monotonic])}
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

    subject = Subject.new("morph-boundary-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(%{
        id: {:morph_boundary_instance, make_ref()},
        start:
          {Instance, :start_link,
           [
             [
               agent: agent,
               subject: subject,
               definition_store: store,
               opts:
                 Keyword.get(opts, :runtime_opts,
                   checker_versions: Declarative.checker_versions()
                 ),
               idle: false
             ]
           ]}
      })

    if Keyword.get(opts, :activate?, true) do
      assert {:ok, _activation} = Spectre.activate(instance, bootstrap, expected_generation: 0)
    end

    %{store: store, instance: instance, bootstrap: bootstrap, canonical: canonical}
  end

  defp start_unstored_instance(agent) do
    subject = Subject.new("morph-unstored-#{System.unique_integer([:positive, :monotonic])}")

    start_supervised!(%{
      id: {:morph_unstored_instance, make_ref()},
      start:
        {Instance, :start_link,
         [
           [
             agent: agent,
             subject: subject,
             idle: false
           ]
         ]}
    })
  end

  defp compose_draft(%Change{} = change, now) do
    change_set =
      ChangeSet.new!(%{
        base_activation_receipt: change.activation.activation_receipt,
        base_candidate_ref: change.activation.candidate_ref,
        observed_definition_ref: change.activation.definition_ref,
        observed_authority_epoch: change.activation.authority_epoch,
        observed_evidence_digest: ChangeSet.evidence_digest(change.activation, change.evidence),
        operations: change.operations,
        author_ref: change.actor_ref,
        provenance: %{
          "origin" => "spectre.morph.boundary-test",
          "change_surface_digest" => Surface.digest(change.surface)
        },
        reason: change.reason,
        created_at: now
      })

    Composer.compose(change.store, change_set,
      activation: change.activation,
      evidence: change.evidence,
      created_at: now,
      applicability_ceilings: Surface.applicability_ceilings(change.surface, change.mount_ids),
      prompt_token_ceiling: change.surface.prompt_token_ceiling
    )
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

  defp operation(type, payload) do
    assert {:ok, operation} = Operation.new(%{"type" => type, "payload" => payload})
    operation
  end

  defp valid_eval_case do
    %{
      "id" => "boundary-candidate-case",
      "input" => "refund",
      "expected_outcome" => "route",
      "expected_route" => "REFUNDS",
      "expected_output" => "answer",
      "context" => %{"scope" => "agent"},
      "llm" => "forbidden"
    }
  end

  defp surface!(canonical) do
    assert {:ok, surface} = Surface.from_canonical(canonical)
    surface
  end

  defp put_mounts(canonical, mounts) do
    replace_component(canonical, :skills, fn component ->
      %{component | payload: Map.put(component.payload, :mounts, mounts)}
    end)
  end

  defp replace_surface(canonical, payload) do
    replace_component(canonical, :change_surface, fn component ->
      %{component | payload: payload}
    end)
  end

  defp replace_component(canonical, type, mapper) do
    components =
      Enum.map(canonical.components, fn component ->
        if component.component_type == type, do: mapper.(component), else: component
      end)

    %{canonical | components: components}
  end
end
