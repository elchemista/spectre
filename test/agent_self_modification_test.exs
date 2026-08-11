defmodule SpectreAgentSelfModificationTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :self_modifying_agent
end

defmodule SpectreAgentSelfModificationTest.RefundCritic do
  @moduledoc """
  Compiled critic that turns an observed routing miss into a falsifiable case.

  The prose is opinion; only the eval case can become evidence, and only after
  an independent oracle approves it.
  """

  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.refund-contract-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:refund-contract"

  @impl true
  def critique(reflection, snapshot, _opts) do
    {:ok,
     %{
       "opinion" => "A refund route must also decide what an empty input does.",
       "eval_case" => %{
         "id" => "forge-refund-empty-input",
         "input" => "",
         "expected_outcome" => "unknown",
         "llm" => "forbidden",
         "tags" => ["forge", "routing"]
       },
       "oracle_ref" => "oracle:contract:refund-v1",
       "provenance" => %{
         "reflection_digest" => reflection["digest"],
         "snapshot_digest" => snapshot["digest"]
       }
     }}
  end
end

defmodule SpectreAgentSelfModificationTest.ProseOnlyCritic do
  @moduledoc "Compiled critic that only ever produces prose."

  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.refund-prose-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:refund-prose"

  @impl true
  def critique(_reflection, _snapshot, _opts) do
    {:ok,
     %{
       "opinion" => "You should definitely mount a refund skill, trust me.",
       "provenance" => %{"source" => "model"}
     }}
  end
end

defmodule SpectreAgentSelfModificationTest do
  @moduledoc """
  End-to-end proof that a Spectre Agent can change its own behaviour only
  through the governed Forge chain, and that the change is real.

  The slice runs Reflection -> Forge proposal -> Composer -> eval gates ->
  approval -> activation CAS, then asserts the Agent answers an input it could
  not answer before, that the parent Definition is untouched, and that every
  constitutional boundary around the loop still fails closed.
  """

  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Experience
  alias Spectre.Experience.Store.Memory, as: ExperienceMemory
  alias Spectre.Forge
  alias Spectre.Forge.Critic, as: ForgeCritic
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Forge.Proposal
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.Approval
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.Composer
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.Review
  alias Spectre.Instance
  alias Spectre.Reflection.Policy, as: ReflectionPolicy
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime, as: SkillRuntime
  alias Spectre.Subject

  alias SpectreAgentSelfModificationTest.Agent
  alias SpectreAgentSelfModificationTest.ProseOnlyCritic
  alias SpectreAgentSelfModificationTest.RefundCritic

  @checker_versions %{
    replay: {"test.replay", 1},
    regression: {"test.regression", 1}
  }

  @mount_id "refunds"
  @capability_input "refund"

  describe "governed self-modification" do
    test "an Agent gains a capability only through the full Forge chain and then really uses it" do
      %{store: store, instance: instance, activation: parent} = baseline()

      # 1. Before the change the Agent genuinely cannot serve the input.
      assert {:error, {:capability_not_mounted, @mount_id}} =
               exercise_capability(store, parent.definition_ref)

      # 2. Redacted operational evidence of the miss, opt-in only.
      experience = start_experience()

      assert {:ok, _evidence_ref} =
               Experience.record(
                 experience,
                 %{
                   definition_ref: parent.definition_ref,
                   activation_generation: parent.generation,
                   kind: "routing.observation",
                   source_ref: "journal:redacted:self-modification",
                   observed_at: 10,
                   expires_at: 100,
                   retention: :bounded,
                   facts: %{
                     outcome: :route_miss,
                     requested: @capability_input,
                     access_token: "ya29.super-secret"
                   },
                   provenance: %{source: :self_modification_slice}
                 },
                 enabled?: true
               )

      # 3. Reflection: a mechanical, redacted, three-plane self-model.
      assert {:ok, reflection} = reflect(store, parent, experience)

      assert reflection.content["instruction_semantics"] == "quoted_data_only"
      assert reflection.content["observed"]["status"] == "evidence_available"
      assert Map.has_key?(reflection.content, "declared")
      assert Map.has_key?(reflection.content, "effective")
      refute inspect(reflection.content) =~ "ya29.super-secret"

      assert {:ok, snapshot} =
               Experience.snapshot(experience, parent.definition_ref, as_of: 20)

      # 4. A model critique becomes evidence only as an oracle-approved case.
      assert {:ok, [critique]} = ForgeCritic.run([RefundCritic], reflection, snapshot)

      approval =
        OracleApproval.new!(%{
          case_digest: Critique.case_digest(critique),
          oracle_ref: critique.oracle_ref,
          approver_ref: "operator:oracle-review",
          approved_at: 25,
          provenance: %{source: :independent_contract_review}
        })

      # 5. Forge proposes: inert, typed, bound to the exact observed activation.
      assert {:ok, %Proposal{} = proposal} =
               Forge.propose(parent, reflection, snapshot, [mount_operation()],
                 critics: [RefundCritic],
                 oracle_approvals: [approval],
                 author_ref: "forge:self-modification",
                 reason: "Serve refunds through a governed runtime Skill",
                 created_at: 30
               )

      assert :ok = Proposal.verify(proposal)

      assert Enum.map(proposal.change_set.operations, & &1.type) ==
               ["mount_skill", "add_eval_case"]

      assert proposal.change_set.observed_definition_ref == parent.definition_ref
      assert proposal.change_set.provenance["forge"]["reflection_digest"] == reflection.digest

      # Forge owns no activation surface at all.
      refute function_exported?(Forge, :activate, 2)
      refute function_exported?(Forge, :activate, 3)

      evidence = Forge.evidence(reflection, snapshot)

      # 6. The Composer applies ceilings and stores the Candidate.
      assert {:ok, composed_ref} = compose(store, proposal.change_set, parent, evidence)

      assert {:ok, %Candidate{governance: governance}} =
               Store.fetch_candidate(store, composed_ref)

      assert governance.state == :composed
      assert governance.candidate_case_ids == ["forge-refund-empty-input"]

      assert governance.observed_evidence_digest ==
               ChangeSet.evidence_digest(parent, evidence)

      # An unevaluated Candidate can never be activated.
      assert {:error, {:governed_candidate_not_activatable, :governed_host, :composed}} =
               Spectre.activate(instance, composed_ref,
                 expected_generation: 1,
                 evidence: evidence,
                 now: 60,
                 checker_versions: @checker_versions
               )

      # 7. Gates: the Candidate's own case can only add an obligation.
      receipts = [
        receipt(governance, :replay, 40, profile_ref: "recording:self-modification"),
        receipt(governance, :regression, 40)
      ]

      assert {:ok, rejected_ref, _report} =
               Review.evaluate(store, composed_ref, delta(candidate_case: false), receipts,
                 reviewed_at: 45,
                 now: 50,
                 checker_versions: @checker_versions
               )

      assert {:ok, %Candidate{governance: %{state: :rejected}}} =
               Store.fetch_candidate(store, rejected_ref)

      assert {:ok, evaluated_ref, report} =
               Review.evaluate(store, composed_ref, delta(candidate_case: true), receipts,
                 reviewed_at: 45,
                 now: 50,
                 checker_versions: @checker_versions
               )

      # 8. Approval is its own commit, separate from execution.
      assert {:ok, approved_ref} =
               Approval.approve(store, evaluated_ref,
                 mode: :human,
                 actor_ref: "operator:activation-review",
                 approved_at: 55
               )

      assert {:ok, %Candidate{governance: approved_governance}} =
               Store.fetch_candidate(store, approved_ref)

      assert approved_governance.state == :approved
      assert approved_governance.report_digest == report.digest

      # 9. Activation CAS, with the exact evidence composition observed.
      assert {:ok, activated} =
               Spectre.activate(instance, approved_ref,
                 expected_generation: 1,
                 evidence: evidence,
                 now: 60,
                 checker_versions: @checker_versions
               )

      assert activated.generation == 2
      assert activated.candidate_ref == approved_ref
      refute activated.definition_ref == parent.definition_ref

      # 10. THE POINT: the Agent now answers what it could not answer before.
      assert {:ok, response} = exercise_capability(store, activated.definition_ref)
      assert response.kind == :reply
      assert response.output == "Refund policy applies to: refund"

      # 11. The parent Definition is immutable: the old behaviour is unchanged.
      assert {:error, {:capability_not_mounted, @mount_id}} =
               exercise_capability(store, parent.definition_ref)

      # 12. The live Instance reports the new activation as its own.
      assert %{definition_ref: live_ref, generation: 2} = Spectre.activation(instance)
      assert live_ref == activated.definition_ref
    end

    test "a self-proposed change cannot skip a gate, address the kernel or promote itself" do
      %{store: store, instance: instance, activation: parent} = baseline()
      experience = start_experience()

      assert {:ok, _ref} =
               Experience.record(experience, evidence_attrs(parent), enabled?: true)

      assert {:ok, reflection} = reflect(store, parent, experience)
      assert {:ok, snapshot} = Experience.snapshot(experience, parent.definition_ref, as_of: 20)

      # Prose is never a ChangeSet, however confident the model sounds.
      assert {:error, {:invalid_forge_operation, 0, _reason}} =
               Forge.propose(
                 parent,
                 reflection,
                 snapshot,
                 ["please mount the refund skill"],
                 author_ref: "forge:self-modification",
                 reason: "prose",
                 created_at: 30
               )

      # A prose-only critic yields no operation at all.
      assert {:error, :forge_proposal_requires_typed_operation} =
               Forge.propose(parent, reflection, snapshot, [],
                 critics: [ProseOnlyCritic],
                 author_ref: "forge:self-modification",
                 reason: "model consensus",
                 created_at: 30
               )

      # The kernel is not addressable: these types are outside the vocabulary.
      for type <- ~w(update_authority replace_projection_generator update_redaction) do
        operation = %{"type" => type, "payload" => %{"value" => "anything"}}

        assert {:error, {:forge_operation_not_allowed, 0}} =
                 Forge.propose(parent, reflection, snapshot, [operation],
                   author_ref: "forge:self-modification",
                   reason: "kernel reach",
                   created_at: 30
                 )
      end

      # A well-formed proposal still cannot widen authority past the ceiling.
      assert {:ok, proposal} =
               Forge.propose(parent, reflection, snapshot, [mount_operation(["escalate"])],
                 author_ref: "forge:self-modification",
                 reason: "ungranted operation",
                 created_at: 30
               )

      evidence = Forge.evidence(reflection, snapshot)

      assert {:error,
              {:governance_operation_failed, 0,
               {:governance_operation_authority_exceeded, "escalate"}}} =
               compose(store, proposal.change_set, parent, evidence)

      # A ChangeSet observing a superseded activation is stale, never implicit.
      assert {:ok, fresh} =
               Forge.propose(parent, reflection, snapshot, [mount_operation()],
                 author_ref: "forge:self-modification",
                 reason: "valid mount",
                 created_at: 30
               )

      assert {:ok, composed_ref} = compose(store, fresh.change_set, parent, evidence)

      assert {:ok, %Candidate{governance: governance}} =
               Store.fetch_candidate(store, composed_ref)

      receipts = [
        receipt(governance, :replay, 40, profile_ref: "recording:self-modification"),
        receipt(governance, :regression, 40)
      ]

      assert {:ok, evaluated_ref, _report} =
               Review.evaluate(store, composed_ref, delta(), receipts,
                 reviewed_at: 45,
                 now: 50,
                 checker_versions: @checker_versions
               )

      assert {:ok, approved_ref} =
               Approval.approve(store, evaluated_ref,
                 mode: :human,
                 actor_ref: "operator:activation-review",
                 approved_at: 55
               )

      assert {:ok, activated} =
               Spectre.activate(instance, approved_ref,
                 expected_generation: 1,
                 evidence: evidence,
                 now: 60,
                 checker_versions: @checker_versions
               )

      # The same approved Candidate cannot be replayed onto the new activation.
      assert {:error, :stale_governance_activation_receipt} =
               Spectre.activate(instance, approved_ref,
                 expected_generation: 2,
                 evidence: evidence,
                 now: 61,
                 checker_versions: @checker_versions
               )

      # And a proposal rebuilt on the stale parent no longer composes.
      assert {:ok, stale_proposal} =
               Forge.propose(parent, reflection, snapshot, [mount_operation()],
                 author_ref: "forge:self-modification",
                 reason: "built on the superseded activation",
                 created_at: 65
               )

      assert {:error, :stale_governance_activation_receipt} =
               compose(store, stale_proposal.change_set, activated, evidence)
    end

    test "rollback withdraws the learned capability and the Agent stops using it" do
      %{store: store, instance: instance, activation: parent, candidate: bootstrap} = baseline()

      experience = start_experience()
      assert {:ok, _ref} = Experience.record(experience, evidence_attrs(parent), enabled?: true)
      assert {:ok, reflection} = reflect(store, parent, experience)
      assert {:ok, snapshot} = Experience.snapshot(experience, parent.definition_ref, as_of: 20)
      evidence = Forge.evidence(reflection, snapshot)

      assert {:ok, proposal} =
               Forge.propose(parent, reflection, snapshot, [mount_operation()],
                 author_ref: "forge:self-modification",
                 reason: "Serve refunds through a governed runtime Skill",
                 created_at: 30
               )

      assert {:ok, composed_ref} = compose(store, proposal.change_set, parent, evidence)

      assert {:ok, %Candidate{governance: governance}} =
               Store.fetch_candidate(store, composed_ref)

      receipts = [
        receipt(governance, :replay, 40, profile_ref: "recording:self-modification"),
        receipt(governance, :regression, 40)
      ]

      assert {:ok, evaluated_ref, _report} =
               Review.evaluate(store, composed_ref, delta(), receipts,
                 reviewed_at: 45,
                 now: 50,
                 checker_versions: @checker_versions
               )

      assert {:ok, approved_ref} =
               Approval.approve(store, evaluated_ref,
                 mode: :human,
                 actor_ref: "operator:activation-review",
                 approved_at: 55
               )

      assert {:ok, activated} =
               Spectre.activate(instance, approved_ref,
                 expected_generation: 1,
                 evidence: evidence,
                 now: 60,
                 checker_versions: @checker_versions
               )

      assert {:ok, _response} = exercise_capability(store, activated.definition_ref)

      # Rolling back to the bootstrap Candidate withdraws the capability.
      assert {:ok, rolled_back} =
               Spectre.rollback(instance, bootstrap,
                 expected_generation: 2,
                 now: 70,
                 checker_versions: @checker_versions
               )

      assert rolled_back.generation == 3
      assert rolled_back.definition_ref == parent.definition_ref

      assert {:error, {:capability_not_mounted, @mount_id}} =
               exercise_capability(store, rolled_back.definition_ref)

      # The learned Definition is still resolvable: rollback branches, never deletes.
      assert {:ok, _resolution} = Resolver.resolve(store, activated.definition_ref)
      assert {:ok, _response} = exercise_capability(store, activated.definition_ref)
    end
  end

  defp baseline do
    id = {:self_modification, System.unique_integer([:positive, :monotonic])}

    server = start_supervised!(%{id: id, start: {Memory, :start_link, [[id: id]]}})
    store = {Memory, server: server}

    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, authority(), closure())

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, candidate} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject =
      Subject.new("self-modification-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(
        {Instance,
         agent: Agent,
         subject: subject,
         definition_store: store,
         opts: [checker_versions: @checker_versions],
         idle: false}
      )

    assert {:ok, activation} = Spectre.activate(instance, candidate, expected_generation: 0)

    %{store: store, instance: instance, activation: activation, candidate: candidate}
  end

  defp start_experience do
    server =
      start_supervised!(
        {ExperienceMemory, id: {:self_modification, System.unique_integer([:positive])}}
      )

    {ExperienceMemory, server: server}
  end

  defp reflect(store, activation, experience) do
    policy =
      ReflectionPolicy.new!(
        actor_refs: ["operator:self-modification"],
        purposes: ["inspect"],
        max_evidence: 10
      )

    Spectre.Reflection.reflect(store, activation.definition_ref, activation,
      policy: policy,
      actor_ref: "operator:self-modification",
      purpose: "inspect",
      as_of: 20,
      experience_store: experience
    )
  end

  defp compose(store, change_set, activation, evidence) do
    Composer.compose(store, change_set,
      activation: activation,
      evidence: evidence,
      created_at: 30,
      applicability_ceilings: %{
        @mount_id => %{
          scopes: ["support"],
          required_tags: [],
          forbidden_tags: [],
          conflicts: []
        }
      }
    )
  end

  # Rebuilds the mounted runtime Skill from the durable Definition and asks it
  # to serve the input, which is the only observable proof the behaviour moved.
  defp exercise_capability(store, definition_ref) do
    with {:ok, resolution} <- Resolver.resolve(store, definition_ref),
         {:ok, skill} <- mounted_skill(resolution.definition, @mount_id),
         runtime <-
           SkillRuntime.new!(Agent, authority(),
             max_prompt_tokens: 512,
             kernel_prompt_tokens: 64,
             per_skill_prompt_cap: 256
           ),
         {:ok, mounted} <-
           SkillRuntime.mount(runtime, @mount_id, skill, expected_revision: 0),
         {:ok, response, _unchanged} <-
           SkillRuntime.respond(mounted, @capability_input, %{scope: "support"},
             expected_revision: 1
           ) do
      {:ok, response}
    end
  end

  defp mounted_skill(definition, mount_id) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         mounts when is_list(mounts) <- fetch_any(component.payload, :mounts, []),
         mount when is_map(mount) <-
           Enum.find(mounts, &(to_string(fetch_any(&1, :id, nil)) == mount_id)),
         data when is_map(data) <- fetch_any(mount, :definition, nil),
         {:ok, canonical} <- Canonical.from_data(data),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical) do
      {:ok, skill}
    else
      nil -> {:error, {:capability_not_mounted, mount_id}}
      {:error, _reason} = error -> error
      _other -> {:error, {:capability_not_mounted, mount_id}}
    end
  end

  defp fetch_any(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp fetch_any(_map, _key, default), do: default

  defp mount_operation(operation_refs \\ []) do
    definition =
      %{
        "id" => @mount_id,
        "declared_version" => 1,
        "publisher_ref" => "forge:self-modification",
        "applicability" => %{
          "scopes" => ["support"],
          "positive" => [@capability_input],
          "negative" => ["delete everything"]
        },
        "prompt_budget" => 64,
        "prompt_fragments" => [
          %{
            "id" => "refund_reply",
            "content" => "Refund policy applies to: {{input.text}}",
            "token_cap" => 32,
            "budget_class" => "small"
          }
        ],
        "flows" => [
          %{
            "id" => "support",
            "routes" => [
              %{
                "label" => "REFUND",
                "match" => %{"kind" => "exact", "value" => @capability_input},
                "handler" => %{"kind" => "reply", "prompt" => "refund_reply"}
              }
            ]
          }
        ]
      }
      |> maybe_put_operations(operation_refs)

    %{
      "type" => "mount_skill",
      "payload" => %{"mount_id" => @mount_id, "definition" => definition}
    }
  end

  defp maybe_put_operations(definition, []), do: definition

  defp maybe_put_operations(definition, refs),
    do: Map.put(definition, "operation_refs", refs)

  # Without a critic the Candidate carries no case of its own, so the delta must
  # declare exactly the candidate case ids the Composer sealed.
  defp delta(opts \\ []) do
    case Keyword.get(opts, :candidate_case, :none) do
      :none ->
        EvaluationDelta.new!(
          [%{case_id: "protected", passed: true}],
          [%{case_id: "protected", passed: true}],
          protected_cases: [protected_case()],
          candidate_case_ids: []
        )

      passed when is_boolean(passed) ->
        EvaluationDelta.new!(
          [%{case_id: "protected", passed: true}],
          [
            %{case_id: "protected", passed: true},
            %{case_id: "forge-refund-empty-input", passed: passed}
          ],
          protected_cases: [protected_case()],
          candidate_case_ids: ["forge-refund-empty-input"]
        )
    end
  end

  defp receipt(governance, gate, issued_at, opts \\ []) do
    Receipt.new!(%{
      gate_class: gate,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: "test.#{gate}",
      checker_version: 1,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: Keyword.get(opts, :profile_ref),
      issued_at: issued_at,
      status: :passed,
      result_digest: Value.digest!(%{gate: gate, passed: true}),
      provenance: %{source: :test_checker}
    })
  end

  defp evidence_attrs(activation) do
    %{
      definition_ref: activation.definition_ref,
      activation_generation: activation.generation,
      kind: "routing.observation",
      source_ref: "journal:redacted:self-modification",
      observed_at: 10,
      expires_at: 100,
      retention: :bounded,
      facts: %{outcome: :route_miss, requested: @capability_input},
      provenance: %{source: :self_modification_slice}
    }
  end

  defp authority do
    Envelope.new!(
      operations: ["lookup"],
      open_capabilities: [
        SkillRuntime.capability(:mount),
        SkillRuntime.capability(:replace),
        SkillRuntime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard],
      limits: %{max_tokens: 1_024}
    )
  end

  defp closure do
    {:ok, build_digest} = Closure.fingerprint(Agent)

    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [
        %{id: "spectre.projection.audit", version: 1},
        %{id: "spectre.projection.reflection", version: 1}
      ],
      state_schema_ref: "spectre.instance.canonical/2",
      state_codec_ref: "spectre.instance.canonical.codec/2",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{("beam:" <> Atom.to_string(Agent)) => build_digest},
      evaluation_corpus_digest: EvaluationDelta.protected_corpus_digest!([protected_case()]),
      compatibility_mode: :native_v2
    })
  end

  defp protected_case, do: %{"id" => "protected", "input" => @capability_input}
end
