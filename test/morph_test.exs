defmodule SpectreMorphTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :morph_agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:agent], prompt_tokens: 512],
    approval: :human
  )
end

defmodule SpectreMorphTest.ClosedAgent do
  @moduledoc false
  use Spectre.Agent, id: :morph_closed_agent
end

defmodule SpectreMorphTest.NarrowAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_narrow_agent

  morph(
    may_propose: [:disable_skill],
    within: [scopes: [:agent], prompt_tokens: 128]
  )
end

defmodule SpectreMorphTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
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
  alias Spectre.Morph.Surface
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.Subject

  alias SpectreMorphTest.Agent
  alias SpectreMorphTest.ClosedAgent
  alias SpectreMorphTest.NarrowAgent

  @protected_cases [
    %{
      "id" => "unrelated-remains-unknown",
      "input" => "weather",
      "expected_outcome" => "clarify",
      "context" => %{"scope" => "agent"},
      "llm" => "forbidden"
    }
  ]

  test "a governed Morph changes a real Agent turn and rollback restores its parent" do
    %{store: store, instance: instance, bootstrap: bootstrap, canonical: parent} = baseline(Agent)

    assert {:ok, before_turn} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = before_turn.decision

    evaluated =
      instance
      |> Morph.change(by: "actor:author", reason: "Serve refund questions")
      |> Morph.mount_skill("refunds",
        match: {:exact, "refund"},
        reply: "Refund policy applies to: {{input.text}}"
      )
      |> Morph.evaluate(cases: @protected_cases, now: 100)

    assert %Change{state: :evaluated, error: nil} = evaluated
    assert evaluated.delta.passed
    assert evaluated.delta.candidate_case_failures == []
    assert length(evaluated.delta.candidate_owned_results) == 1
    assert {:ok, report} = Morph.explain(evaluated)
    assert is_map(report)

    resumed = Morph.resume(instance, evaluated.ref, by: "actor:reviewer")
    assert resumed.state == :evaluated
    assert resumed.ref == evaluated.ref
    assert Morph.status(resumed).operation_count == 0

    approved = Morph.approve(resumed, by: "actor:reviewer", mode: :human, now: 110)
    assert approved.state == :approved

    # Approval is evidence, not activation: A still serves the next turn.
    assert {:ok, still_parent} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = still_parent.decision

    assert {:ok, activation} = Morph.activate(approved, now: 120)
    assert activation.generation == 2
    refute activation.definition_ref == Canonical.ref(parent)

    assert {:ok, learned_turn} = Spectre.turn(instance, "refund")
    assert {:reply, "Refund policy applies to: refund", _ref} = learned_turn.observable
    assert {:reply, learned_result} = learned_turn.decision

    assert get_in(learned_result.metadata, [:runtime_skill, :agent_definition_ref]) ==
             to_string(activation.definition_ref)

    assert get_in(learned_result.metadata, [:runtime_skill, :mount_id]) == "refunds"

    # A was never mutated and remains independently resolvable.
    assert {:ok, parent_artifact} = Store.fetch(store, Canonical.ref(parent))
    assert {:ok, skills} = Canonical.fetch_component(parent_artifact.definition, :skills)
    assert fetch(skills.payload, :mounts, []) == []

    assert {:ok, rollback} =
             Spectre.rollback(instance, bootstrap,
               expected_generation: 2,
               now: 130,
               checker_versions: Declarative.checker_versions()
             )

    assert rollback.generation == 3
    assert rollback.definition_ref == Canonical.ref(parent)
    assert {:ok, rolled_back_turn} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = rolled_back_turn.decision

    # B is retained even though it is no longer active.
    assert {:ok, _learned_artifact} = Store.fetch(store, activation.definition_ref)
  end

  test "candidate-owned exact output is digest-bound and catches a mutated reply" do
    %{instance: instance} = baseline(Agent)

    draft =
      instance
      |> Morph.change(by: "actor:author", reason: "Learn an exact answer")
      |> Morph.mount_skill("refunds",
        match: "refund",
        reply: "EXPECTED {{input.text}}"
      )

    [mount, candidate_case] = draft.operations

    mutated_mount =
      put_in(
        mount,
        ["payload", "definition", "prompt_fragments", Access.at(0), "content"],
        "MUTATED {{input.text}}"
      )

    reviewed =
      %{draft | operations: [mutated_mount, candidate_case]}
      |> Morph.evaluate(cases: @protected_cases, now: 200)

    assert reviewed.state == :draft
    assert {:morph_evaluation_obligation_mismatch, _case_id} = reviewed.error
  end

  test "replace and disable operate only on governed runtime Skills and change real turns" do
    %{instance: instance} = baseline(Agent)

    first = morph_reply(instance, "first {{input.text}}", 300)
    assert {:ok, first_activation} = Morph.activate(first, now: 303)
    assert {:ok, first_turn} = Spectre.turn(instance, "refund")
    assert {:reply, "first refund", _ref} = first_turn.observable

    replaced =
      instance
      |> Morph.change(by: "actor:author", reason: "Improve the learned answer")
      |> Morph.replace_skill("refunds", match: "refund", reply: "second {{input.text}}")
      |> Morph.evaluate(cases: @protected_cases, now: 310)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 311)

    assert {:ok, second_activation} = Morph.activate(replaced, now: 312)
    assert second_activation.generation == first_activation.generation + 1
    assert {:ok, second_turn} = Spectre.turn(instance, "refund")
    assert {:reply, "second refund", _ref} = second_turn.observable

    disabled =
      instance
      |> Morph.change(by: "actor:author", reason: "Withdraw the learned answer")
      |> Morph.disable_skill("refunds")
      |> Morph.evaluate(cases: @protected_cases, now: 320)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 321)

    assert {:ok, disabled_activation} = Morph.activate(disabled, now: 322)
    assert disabled_activation.generation == second_activation.generation + 1
    assert {:ok, disabled_turn} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = disabled_turn.decision
  end

  test "the canonical surface is the only Morph door and caller options can only narrow" do
    %{instance: closed} = baseline(ClosedAgent)

    assert %Change{error: {:agent_declares_no_morph, ClosedAgent}} =
             Morph.change(closed, by: "actor:author", reason: "closed")

    %{instance: narrow} = baseline(NarrowAgent)

    assert %Change{error: {:morph_not_permitted, "mount_skill"}} =
             narrow
             |> Morph.change(by: "actor:author", reason: "outside surface")
             |> Morph.mount_skill("refunds", match: "refund", reply: "no")

    surface = Agent |> Definition.canonical!() |> surface!()
    assert Surface.allows?(surface, :mount_skill)
    assert surface.scope_ceiling == ["agent"]
    assert surface.prompt_token_ceiling == 512

    %{instance: open, store: store} = baseline(Agent)

    wider =
      open
      |> Morph.change(by: "actor:author", reason: "caller cannot widen")
      |> Morph.mount_skill("refunds", match: "refund", reply: "answer")
      |> Morph.evaluate(cases: @protected_cases, prompt_token_ceiling: 10_000, now: 500)

    assert wider.error == nil
    assert {:ok, stored} = Store.fetch_candidate(store, wider.ref)
    assert stored.governance.prompt_token_ceiling == 512
  end

  test "mutating the transient Change cannot widen the canonical surface" do
    %{instance: open} = baseline(Agent)

    portable_intent =
      open
      |> Morph.change(by: "actor:author", reason: "Build a portable intent")
      |> Morph.mount_skill("refunds", match: "refund", reply: "answer")

    %{instance: narrow} = baseline(NarrowAgent)

    forged =
      narrow
      |> Morph.change(by: "actor:author", reason: "Try to bypass the sealed surface")
      |> then(fn change ->
        %{
          change
          | surface: portable_intent.surface,
            operations: portable_intent.operations,
            mount_ids: []
        }
      end)
      |> Morph.evaluate(cases: @protected_cases, now: 550)

    assert forged.error == {:morph_operation_outside_surface, "mount_skill"}
    assert forged.state == :draft
  end

  test "rebase preserves typed intent and resume preserves external evidence" do
    %{instance: instance} = baseline(Agent)

    stale_draft =
      instance
      |> Morph.change(
        by: "actor:author",
        reason: "Teach refunds after another activation",
        evidence: %{"ticket" => "refund-42"}
      )
      |> Morph.mount_skill("refunds", match: "refund", reply: "rebased {{input.text}}")

    intervening =
      instance
      |> Morph.change(by: "actor:author", reason: "Install an independent skill")
      |> Morph.mount_skill("greetings", match: "hello", reply: "hello")
      |> Morph.evaluate(cases: @protected_cases, now: 600)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 601)

    assert {:ok, _activation} = Morph.activate(intervening, now: 602)

    evaluated =
      stale_draft
      |> Morph.rebase()
      |> Morph.evaluate(cases: @protected_cases, now: 610)

    assert evaluated.error == nil
    assert evaluated.state == :evaluated

    resumed =
      Morph.resume(instance, evaluated.ref,
        by: "actor:reviewer",
        evidence: %{"ticket" => "refund-42"}
      )

    approved = Morph.approve(resumed, by: "actor:reviewer", mode: :human, now: 611)
    assert {:ok, _activation} = Morph.activate(approved, now: 612)

    assert {:ok, learned} = Spectre.turn(instance, "refund")
    assert {:reply, "rebased refund", _turn_ref} = learned.observable
  end

  test "DSL and public boundary reject malformed or misleading requests" do
    assert_raise ArgumentError, ~r/morph :within/, fn ->
      defmodule MissingWithin do
        use Spectre.Agent, id: :morph_missing_within
        morph(may_propose: [:mount_skill])
      end
    end

    assert_raise ArgumentError, ~r/unsupported_morph_operation/, fn ->
      defmodule KernelRewrite do
        use Spectre.Agent, id: :morph_kernel_rewrite

        morph(
          may_propose: [:rewrite_kernel],
          within: [scopes: [:agent], prompt_tokens: 64]
        )
      end
    end

    %{instance: instance} = baseline(Agent)

    assert %Change{error: {:invalid_morph_options, [123]}} = Morph.change(instance, [123])

    assert %Change{error: {:morph_requires_exact_match, nil}} =
             instance
             |> Morph.change(by: "actor:author", reason: "missing match")
             |> Morph.mount_skill("refunds", reply: "answer")

    assert %Change{error: {:morph_prompt_cap_exceeded, 513, 512}} =
             instance
             |> Morph.change(by: "actor:author", reason: "too much prompt")
             |> Morph.mount_skill("refunds", match: "refund", reply: "answer", token_cap: 513)

    assert %Change{error: {:unsupported_morph_reply_placeholder, ["input.secret"]}} =
             instance
             |> Morph.change(by: "actor:author", reason: "unsupported placeholder")
             |> Morph.mount_skill("refunds", match: "refund", reply: "{{input.secret}}")

    invalid_surface = %Surface{
      schema_version: 1,
      operation_types: ["mount_skill"],
      scope_ceiling: ["agent"],
      prompt_token_ceiling: 64,
      approval_requirement: "human"
    }

    assert {:ok, %Surface{approval_requirement: :human}} = Surface.new(invalid_surface)

    assert {:error, {:invalid_skill_runtime_loader_options, [123]}} =
             Loader.load(nil, "sha256:invalid", Agent, [123])

    assert {:error, {:invalid_declarative_check, :list, :list}} =
             Declarative.run(nil, %{}, [], [])

    assert %Change{error: {:invalid_morph_options, :bad}} =
             instance
             |> Morph.change(by: "actor:author", reason: "invalid rebase")
             |> Morph.rebase(:bad)
  end

  defp morph_reply(instance, reply, now) do
    instance
    |> Morph.change(by: "actor:author", reason: "Learn refund handling")
    |> Morph.mount_skill("refunds", match: "refund", reply: reply)
    |> Morph.evaluate(cases: @protected_cases, now: now)
    |> Morph.approve(by: "actor:reviewer", mode: :human, now: now + 1)
  end

  defp baseline(agent) do
    id = {:morph, System.unique_integer([:positive, :monotonic])}
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

    subject = Subject.new("morph-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(%{
        id: {:morph_instance, make_ref()},
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

    assert {:ok, _activation} = Spectre.activate(instance, bootstrap, expected_generation: 0)

    %{store: store, instance: instance, bootstrap: bootstrap, canonical: canonical}
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

  defp surface!(canonical) do
    {:ok, surface} = Surface.from_canonical(canonical)
    surface
  end

  defp fetch(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
