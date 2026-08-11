defmodule SpectreMorphLoaderCheckerCoverageTest.Renderer do
  @moduledoc false

  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreMorphLoaderCheckerCoverageTest.Operations do
  @moduledoc false

  def lookup(input), do: {:ok, input}
end

defmodule SpectreMorphLoaderCheckerCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :morph_loader_checker_agent

  alias SpectreMorphLoaderCheckerCoverageTest.Operations

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:support], prompt_tokens: 512]
  )

  operation(:lookup, {Operations, :lookup}, input: :any, output: :any)
end

defmodule SpectreMorphLoaderCheckerCoverageTest.MultiScopeAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_loader_checker_multi_scope

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:support, :billing], prompt_tokens: 512]
  )
end

defmodule SpectreMorphLoaderCheckerCoverageTest.CompiledRouteAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_loader_checker_compiled_route

  alias SpectreMorphLoaderCheckerCoverageTest.Renderer

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:support], prompt_tokens: 512]
  )

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :compiled do
    on :COMPILED_ONLY, regex: ~r/^compiled$/ do
      reply(:compiled_reply, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreMorphLoaderCheckerCoverageTest.ClosedAgent do
  @moduledoc false
  use Spectre.Agent, id: :morph_loader_checker_closed
end

defmodule SpectreMorphLoaderCheckerCoverageTest.CompiledSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :morph_loader_compiled_skill,
    version: 1,
    applicability: %{scopes: [:support], positive: [], negative: []}
end

defmodule SpectreMorphLoaderCheckerCoverageTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Context
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Input
  alias Spectre.Morph.Change
  alias Spectre.Morph.SkillProposal
  alias Spectre.Morph.Surface
  alias Spectre.Morph.Surface.EvaluationObligations
  alias Spectre.Morph.Surface.MountIndex
  alias Spectre.Runtime.SkillDispatch
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.State

  alias SpectreMorphLoaderCheckerCoverageTest.Agent
  alias SpectreMorphLoaderCheckerCoverageTest.ClosedAgent
  alias SpectreMorphLoaderCheckerCoverageTest.CompiledRouteAgent
  alias SpectreMorphLoaderCheckerCoverageTest.CompiledSkill
  alias SpectreMorphLoaderCheckerCoverageTest.MultiScopeAgent

  @unknown_case %{
    "id" => "weather-stays-unknown",
    "input" => "weather",
    "expected_outcome" => "clarify",
    "llm" => "forbidden"
  }

  test "Loader restores exact mounts, filters compiled origins, and enforces closure evidence" do
    store = store()
    runtime = reply_skill("refunds", "refund", "Refund {{input.text}}")
    {:ok, compiled} = SkillDefinition.from_compiled(CompiledSkill)

    canonical =
      agent_definition(Agent, [mount("refunds", runtime), mount(7, compiled)])

    ref = publish!(store, canonical, Agent, authority(max_tokens: nil))

    closure_digest =
      canonical
      |> manifest!(Agent, authority(max_tokens: nil))
      |> then(&Closure.digest(&1.execution_closure))

    assert {:ok, loaded} = Loader.load(store, ref, Agent, closure_digest: closure_digest)
    assert MapSet.new(Map.keys(loaded.runtime.mounts)) == MapSet.new(["refunds", 7])
    assert loaded.runtime.max_prompt_tokens == 512

    assert {:ok, runtime_only} = Loader.load(store, to_string(ref), Agent, runtime_only?: true)
    assert Map.keys(runtime_only.runtime.mounts) == ["refunds"]

    assert {:error, {:runtime_skill_closure_mismatch, "bad", ^closure_digest}} =
             Loader.load(store, ref, Agent, closure_digest: "bad")

    assert {:error, {:invalid_runtime_skill_closure_digest, 42}} =
             Loader.load(store, ref, Agent, closure_digest: 42)
  end

  test "Loader rejects every non-positive or fractional token authority grant" do
    for invalid <- [12.5, 0, 0.0, 0.5] do
      store = store()
      canonical = agent_definition(Agent, [])
      ref = publish!(store, canonical, Agent, authority(max_tokens: invalid))

      assert {:error, {:invalid_skill_runtime_authority_prompt_limit, ^invalid}} =
               Loader.load(store, ref, Agent)
    end
  end

  test "a draft caches the canonical mount index and matches integer ids by stable name" do
    runtime = reply_skill("legacy-id", "refund", "Refund {{input.text}}")
    canonical = agent_definition(Agent, [mount(7, runtime)])
    definition_ref = Canonical.ref(canonical)

    assert {:ok, surface} = Surface.from_canonical(canonical)
    assert {:ok, mount_index} = MountIndex.build(canonical)
    assert {:ok, %{"id" => 7}} = MountIndex.fetch(mount_index, "7")

    draft = %Change{
      instance: self(),
      store: nil,
      agent: Agent,
      activation: %{definition_ref: definition_ref},
      source_definition_ref: definition_ref,
      surface: surface,
      source_mount_index: mount_index,
      actor_ref: "actor:test",
      reason: "replace an indexed runtime Skill"
    }

    changed =
      SkillProposal.put(draft, :replace_skill, "7",
        match: "refund",
        reply: "Updated {{input.text}}",
        scopes: [:support]
      )

    assert changed.error == nil

    assert [%{"type" => "replace_skill", "payload" => %{"mount_id" => "7"}} | _cases] =
             changed.operations
  end

  test "disable obligations reject malformed Surface scopes before building cases" do
    skill = reply_skill("refunds", "refund", "Refund {{input.text}}")

    surface =
      Agent
      |> Definition.canonical!()
      |> Surface.from_canonical()
      |> then(fn {:ok, surface} -> %{surface | scope_ceiling: ["support", nil]} end)

    assert {:error, {:morph_evaluation_obligation_not_derivable, "refunds"}} =
             EvaluationObligations.disable_cases(surface, "refunds", skill)
  end

  test "Loader rejects malformed mount envelopes and embedded Definition Ref tampering" do
    store = store()
    skill = reply_skill("refunds", "refund", "ok")
    valid = mount("refunds", skill)

    cases = [
      {[%{"definition" => valid["definition"], "definition_ref" => valid["definition_ref"]}],
       {:invalid_runtime_skill_mount, 0}},
      {[
         %{
           "id" => "refunds",
           "definition" => "not-a-map",
           "definition_ref" => valid["definition_ref"]
         }
       ], {:invalid_runtime_skill_mount, 0}},
      {[Map.put(valid, "definition", %{"kind" => "skill"})],
       {:invalid_runtime_skill_mount, 0, :any}},
      {[Map.put(valid, "definition_ref", nil)],
       {:invalid_runtime_skill_mount, 0, {:invalid_runtime_skill_definition_ref, nil}}},
      {[Map.put(valid, "definition_ref", "sha256:" <> String.duplicate("0", 64))],
       {:invalid_runtime_skill_mount, 0, :mismatch}},
      {["not-a-mount"], {:invalid_runtime_skill_mount, 0}}
    ]

    Enum.each(cases, fn {mounts, expected} ->
      canonical = agent_definition(Agent, mounts)
      ref = publish!(store, canonical, Agent)

      case {Loader.load(store, ref, Agent), expected} do
        {{:error, reason}, {:invalid_runtime_skill_mount, 0, :any}} ->
          assert match?({:invalid_runtime_skill_mount, 0, _}, reason)

        {{:error,
          {:invalid_runtime_skill_mount, 0, {:runtime_skill_definition_ref_mismatch, _, _}}},
         {:invalid_runtime_skill_mount, 0, :mismatch}} ->
          :ok

        {{:error, reason}, reason} ->
          :ok

        {actual, expected} ->
          flunk("unexpected Loader result #{inspect(actual)} for #{inspect(expected)}")
      end
    end)
  end

  test "Loader rejects malformed skill components, duplicate mounts, refs, agents, and options" do
    store = store()

    for payload <- [nil, [], %{mounts: %{}}, %{mounts: {}}] do
      canonical = replace_skills(Definition.canonical!(Agent), payload)
      ref = publish!(store, canonical, Agent)
      assert {:error, {:invalid_runtime_skill_mounts, _shape}} = Loader.load(store, ref, Agent)
    end

    missing =
      Definition.canonical!(Agent)
      |> rebuild(fn components -> Enum.reject(components, &(&1.component_type == :skills)) end)

    missing_ref = publish!(store, missing, Agent)

    assert {:error, {:unknown_definition_component, :skills}} =
             Loader.load(store, missing_ref, Agent)

    duplicate = reply_skill("same", "same", "same")

    duplicate_ref =
      agent_definition(Agent, [mount("same", duplicate), mount("same", duplicate)])
      |> then(&publish!(store, &1, Agent))

    assert {:error, {:duplicate_skill_mount, "same"}} = Loader.load(store, duplicate_ref, Agent)

    assert {:error, {:invalid_definition_ref, %{}}} = Loader.load(store, %{}, Agent)
    assert {:error, {:invalid_definition_ref, _ref}} = Loader.load(store, "not-a-ref", Agent)

    assert {:error, {:invalid_skill_runtime_loader_agent, nil}} =
             Loader.load(store, missing_ref, nil)

    assert {:error, {:invalid_skill_runtime_loader_options, [1, 2]}} =
             Loader.load(store, missing_ref, Agent, [1, 2])
  end

  test "Declarative checker executes protected and owned cases and binds exact outputs" do
    store = store()
    parent = agent_definition(Agent, [])

    proposed =
      agent_definition(Agent, [
        mount("refunds", reply_skill("refunds", "refund", "Refund {{input.text}}"))
      ])

    parent_ref = publish!(store, parent, Agent)
    proposed_ref = publish!(store, proposed, Agent)

    owned = %{
      "id" => "candidate-refund-output",
      "input" => "refund",
      "expected_outcome" => "route",
      "expected_route" => "REFUNDS",
      "expected_output" => "Refund refund",
      "llm" => "forbidden"
    }

    candidate = governed(parent_ref, proposed_ref, [owned])

    assert {:ok, delta, [replay, regression]} =
             Declarative.run(store, candidate, [@unknown_case], agent: Agent, issued_at: 10)

    assert delta.passed

    assert Enum.all?(delta.protected_results, fn result ->
             result["parent"]["passed"] and result["candidate"]["passed"]
           end)

    assert replay.status == :passed
    assert regression.status == :passed
    assert replay.result_digest == regression.result_digest

    wrong = %{
      candidate
      | governance: %{
          candidate.governance
          | candidate_cases: [Map.put(owned, "expected_output", "wrong")]
        }
    }

    assert {:ok, failed, [failed_replay, failed_regression]} =
             Declarative.run(store, wrong, [@unknown_case], agent: Agent, issued_at: 11)

    refute failed.passed
    assert failed_replay.status == :failed
    assert failed_regression.status == :failed
  end

  test "Declarative checker fails closed on malformed and unbound corpora" do
    store = store()
    ref = Agent |> Definition.canonical!() |> then(&publish!(store, &1, Agent))
    candidate = governed(ref, ref, [])

    assert {:error, :declarative_checker_agent_required} =
             Declarative.run(store, candidate, [@unknown_case])

    assert {:error, {:invalid_declarative_eval_case, 0, _reason}} =
             Declarative.run(store, candidate, [%{"id" => "missing-fields"}], agent: Agent)

    mismatched = %{
      candidate
      | governance: %{candidate.governance | candidate_case_ids: ["not-owned"]}
    }

    assert {:error, {:declarative_candidate_cases_mismatch, ["not-owned"], []}} =
             Declarative.run(store, mismatched, [@unknown_case], agent: Agent)

    assert {:error, {:invalid_declarative_check, :map, :list}} =
             Declarative.run(store, candidate, %{}, [])

    assert {:error, {:invalid_declarative_check, :list, :tuple}} =
             Declarative.run(store, candidate, [], {:not, :options})

    assert {:error, {:invalid_declarative_check, :other, :other}} =
             Declarative.run(store, :candidate, :cases, :opts)
  end

  test "Declarative checker requires context for multiple scopes and uses compiled deterministic routes" do
    store = store()

    multi =
      MultiScopeAgent |> Definition.canonical!() |> then(&publish!(store, &1, MultiScopeAgent))

    multi_candidate = governed(multi, multi, [])

    assert {:error, {:declarative_eval_context_required, scopes}} =
             Declarative.run(store, multi_candidate, [@unknown_case], agent: MultiScopeAgent)

    assert MapSet.new(scopes) == MapSet.new(["support", "billing"])

    compiled =
      CompiledRouteAgent
      |> Definition.canonical!()
      |> then(&publish!(store, &1, CompiledRouteAgent))

    compiled_case = %{
      "id" => "compiled-route",
      "input" => "compiled",
      "expected_outcome" => "route",
      "expected_route" => "COMPILED_ONLY",
      "llm" => "forbidden"
    }

    assert {:ok, delta, _receipts} =
             Declarative.run(store, governed(compiled, compiled, []), [compiled_case],
               agent: CompiledRouteAgent
             )

    assert delta.passed
  end

  test "Declarative checker reports runtime ambiguity and compiled/runtime collisions as errors" do
    store = store()

    colliding =
      agent_definition(CompiledRouteAgent, [
        mount("runtime", reply_skill("runtime", "compiled", "runtime"))
      ])

    colliding_ref = publish!(store, colliding, CompiledRouteAgent)

    collision_case = %{
      "id" => "compiled-runtime-collision",
      "input" => "compiled",
      "expected_outcome" => "error",
      "context" => %{"scope" => "support"},
      "llm" => "forbidden"
    }

    assert {:ok, collision_delta, _receipts} =
             Declarative.run(
               store,
               governed(colliding_ref, colliding_ref, []),
               [collision_case],
               agent: CompiledRouteAgent
             )

    assert collision_delta.passed

    ambiguous =
      agent_definition(Agent, [
        mount("first", reply_skill("first", "ambiguous", "first")),
        mount("second", reply_skill("second", "ambiguous", "second"))
      ])

    ambiguous_ref = publish!(store, ambiguous, Agent)

    ambiguity_case = %{
      "id" => "runtime-ambiguity",
      "input" => "ambiguous",
      "expected_outcome" => "error",
      "context" => %{"scope" => "support"},
      "llm" => "forbidden"
    }

    assert {:ok, ambiguity_delta, _receipts} =
             Declarative.run(
               store,
               governed(ambiguous_ref, ambiguous_ref, []),
               [ambiguity_case],
               agent: Agent
             )

    assert ambiguity_delta.passed
  end

  test "Declarative checker refuses operation-bearing runtime Skills and receipt construction errors" do
    store = store()
    plain = Agent |> Definition.canonical!() |> then(&publish!(store, &1, Agent))

    operation =
      SkillDefinition.new!(%{
        id: "lookup-skill",
        declared_version: 1,
        publisher_ref: "test:checker",
        applicability: %{scopes: ["support"], positive: ["lookup"], negative: []},
        operation_refs: ["lookup"],
        flows: [
          %{
            id: "support",
            routes: [
              %{
                label: "LOOKUP",
                match: %{kind: "exact", value: "lookup"},
                handler: %{kind: "operation", operation_ref: "lookup"},
                input: "text"
              }
            ]
          }
        ]
      })

    operation_ref =
      agent_definition(Agent, [mount("lookup", operation)])
      |> then(&publish!(store, &1, Agent, authority(operations: [:lookup])))

    assert {:error, {:not_declarative, "lookup", :operations}} =
             Declarative.run(store, governed(plain, operation_ref, []), [@unknown_case],
               agent: Agent
             )

    assert {:error, {:invalid_gate_receipt_field, :issued_at, -1}} =
             Declarative.run(store, governed(plain, plain, []), [@unknown_case],
               agent: Agent,
               issued_at: -1
             )
  end

  test "SkillDispatch is pinned, closed without a Surface, and propagates loader integrity errors" do
    store = store()
    no_surface = ClosedAgent |> Definition.canonical!() |> then(&publish!(store, &1, ClosedAgent))

    assert :cont = SkillDispatch.dispatch(context(ClosedAgent, store, no_surface, "anything"))

    assert :cont =
             SkillDispatch.dispatch(%{context(Agent, store, no_surface, "anything") | opts: []})

    ref = Agent |> Definition.canonical!() |> then(&publish!(store, &1, Agent))

    assert {:error, {:runtime_skill_closure_mismatch, "bad", _actual}} =
             SkillDispatch.dispatch(context(Agent, store, ref, "anything", closure_digest: "bad"))

    assert {:error, {:invalid_definition_ref, %{}}} =
             SkillDispatch.dispatch(context(Agent, store, %{}, "anything"))
  end

  test "SkillDispatch returns replies, preserves not-found fallback, and rejects operation boundaries" do
    store = store()
    reply = reply_skill("refunds", "refund", "Refund {{input.text}}")

    reply_ref =
      agent_definition(Agent, [mount("refunds", reply)]) |> then(&publish!(store, &1, Agent))

    assert {:reply, result} =
             SkillDispatch.dispatch(
               context(Agent, store, reply_ref, "refund", skill_context: %{"scope" => "support"})
             )

    assert result.reply_text == "Refund refund"
    assert get_in(result.metadata, [:runtime_skill, :mount_id]) == "refunds"
    assert :cont = SkillDispatch.dispatch(context(Agent, store, reply_ref, "weather"))

    assert {:error, {:invalid_runtime_skill_context, [:invalid]}} =
             SkillDispatch.dispatch(
               context(Agent, store, reply_ref, "refund", skill_context: [:invalid])
             )

    operation =
      SkillDefinition.new!(%{
        id: "lookup-skill",
        declared_version: 1,
        publisher_ref: "test:dispatch",
        applicability: %{scopes: ["support"], positive: ["lookup"], negative: []},
        operation_refs: ["lookup"],
        flows: [
          %{
            id: "support",
            routes: [
              %{
                label: "LOOKUP",
                match: %{kind: "exact", value: "lookup"},
                handler: %{kind: "operation", operation_ref: "lookup"},
                input: "text"
              }
            ]
          }
        ]
      })

    operation_ref =
      agent_definition(Agent, [mount("lookup", operation)])
      |> then(&publish!(store, &1, Agent, authority(operations: [:lookup])))

    assert {:error, {:runtime_skill_turn_boundary_unsupported, :operation}} =
             SkillDispatch.dispatch(context(Agent, store, operation_ref, "lookup"))
  end

  test "SkillDispatch detects a compiled/runtime exact ambiguity" do
    store = store()
    runtime = reply_skill("runtime", "compiled", "runtime")

    ref =
      agent_definition(CompiledRouteAgent, [mount("runtime", runtime)])
      |> then(&publish!(store, &1, CompiledRouteAgent))

    assert {:error, {:ambiguous_definition_route, :COMPILED_ONLY}} =
             SkillDispatch.dispatch(context(CompiledRouteAgent, store, ref, "compiled"))
  end

  test "SkillDispatch short-circuits empty mounts and requires context for a multi-scope Surface" do
    store = store()
    empty_ref = Agent |> Definition.canonical!() |> then(&publish!(store, &1, Agent))
    assert :cont = SkillDispatch.dispatch(context(Agent, store, empty_ref, "anything"))

    multi_ref =
      agent_definition(MultiScopeAgent, [
        mount("refunds", reply_skill("refunds", "refund", "refund"))
      ])
      |> then(&publish!(store, &1, MultiScopeAgent))

    assert {:error, {:runtime_skill_context_required, scopes}} =
             SkillDispatch.dispatch(context(MultiScopeAgent, store, multi_ref, "refund"))

    assert MapSet.new(scopes) == MapSet.new(["support", "billing"])
  end

  defp store do
    id = {:morph_loader_checker, System.unique_integer([:positive, :monotonic])}
    server = start_supervised!(%{id: id, start: {Memory, :start_link, [[id: id]]}})
    {Memory, server: server}
  end

  defp reply_skill(id, trigger, reply) do
    SkillDefinition.new!(%{
      id: id,
      declared_version: 1,
      publisher_ref: "test:loader-checker",
      applicability: %{scopes: ["support"], positive: [trigger], negative: []},
      prompt_budget: 256,
      prompt_fragments: [
        %{id: id <> ":prompt", content: reply, token_cap: 128, budget_class: "small"}
      ],
      flows: [
        %{
          id: "support",
          routes: [
            %{
              label: String.upcase(id),
              match: %{kind: "exact", value: trigger},
              handler: %{kind: "reply", prompt: id <> ":prompt"}
            }
          ]
        }
      ]
    })
  end

  defp mount(id, %SkillDefinition{} = definition) do
    %{
      "id" => id,
      "definition" => definition |> SkillDefinition.canonical() |> Canonical.to_data(),
      "definition_ref" => definition |> SkillDefinition.ref() |> to_string()
    }
  end

  defp agent_definition(agent, mounts) do
    agent
    |> Definition.canonical!()
    |> replace_skills(%{"mounts" => mounts})
  end

  defp replace_skills(canonical, payload) do
    rebuild(canonical, fn components ->
      Enum.map(components, fn
        %{component_type: :skills} = component -> %{component | payload: payload}
        component -> component
      end)
    end)
  end

  defp rebuild(canonical, update) do
    canonical
    |> Map.from_struct()
    |> Map.update!(:components, update)
    |> Canonical.new!()
  end

  defp publish!(store, canonical, agent, envelope \\ authority()) do
    manifest = manifest!(canonical, agent, envelope)
    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)
    Canonical.ref(canonical)
  end

  defp manifest!(canonical, agent, envelope) do
    Manifest.new!(canonical, envelope, closure(agent))
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
      evaluation_corpus_digest: String.duplicate("c", 64),
      compatibility_mode: :native_v2
    })
  end

  defp authority(opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 1_024)
    operations = Keyword.get(opts, :operations, [])
    limits = if is_nil(max_tokens), do: %{}, else: %{max_tokens: max_tokens}

    Envelope.new!(
      open_capabilities: [
        Spectre.Skill.Runtime.capability(:mount),
        Spectre.Skill.Runtime.capability(:replace),
        Spectre.Skill.Runtime.capability(:disable)
      ],
      operations: operations,
      prompt_budget_classes: [:small, :standard],
      limits: limits
    )
  end

  defp governed(parent_ref, candidate_ref, candidate_cases) do
    ids = Enum.map(candidate_cases, &Map.fetch!(&1, "id"))
    digest = String.duplicate("a", 64)

    governance =
      struct(CandidateState,
        proposal_digest: String.duplicate("b", 64),
        parent_definition_ref: to_string(parent_ref),
        candidate_definition_ref: to_string(candidate_ref),
        closure_digest: digest,
        evaluation_cases_digest: digest,
        candidate_cases: candidate_cases,
        candidate_case_ids: ids
      )

    %{governance: governance}
  end

  defp context(agent, store, definition_ref, input, extra_opts \\ []) do
    %Context{
      agent: agent,
      input: Input.new(input),
      state: State.new(nil),
      opts:
        [
          instance_definition_store: store,
          definition_ref: definition_ref,
          runtime_skill_dispatch?: true
        ] ++ extra_opts
    }
  end
end
