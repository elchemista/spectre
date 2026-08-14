defmodule SpectreGovernanceRuntimeContractCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :governance_runtime_contract_coverage_agent
end

defmodule SpectreGovernanceRuntimeContractCoverageTest.UnavailableStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  @impl true
  def identity(_opts), do: :governance_runtime_unavailable

  @impl true
  def durability(_opts), do: :volatile

  @impl true
  def get(_key, _opts), do: {:error, :governance_store_unavailable}

  @impl true
  def put(_key, _encoded, _opts), do: {:error, :governance_store_unavailable}
end

defmodule SpectreGovernanceRuntimeContractCoverageTest.ReceiptFailingStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  alias Spectre.Definition.Store.Memory

  @impl true
  def identity(opts), do: Memory.identity(opts)

  @impl true
  def durability(opts), do: Memory.durability(opts)

  @impl true
  def get(key, opts), do: Memory.get(key, opts)

  @impl true
  def put("gate-receipt/" <> _ref, _encoded, _opts),
    do: {:error, :governance_receipt_write_failed}

  def put("candidate/" <> _ref = key, encoded, opts) do
    send(Keyword.fetch!(opts, :test_pid), :candidate_write_attempted)
    Memory.put(key, encoded, opts)
  end

  def put(key, encoded, opts), do: Memory.put(key, encoded, opts)
end

defmodule SpectreGovernanceRuntimeContractCoverageTest.MissingArtifactStore do
  @moduledoc false

  @behaviour Spectre.Definition.Store

  alias Spectre.Definition.Store.Memory

  @impl true
  def identity(opts), do: Memory.identity(opts)

  @impl true
  def durability(opts), do: Memory.durability(opts)

  @impl true
  def get(key, opts) do
    if key == Keyword.fetch!(opts, :missing_key), do: :not_found, else: Memory.get(key, opts)
  end

  @impl true
  def put(key, encoded, opts), do: Memory.put(key, encoded, opts)
end

defmodule SpectreGovernanceRuntimeContractCoverageTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Execution.Program
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.Approval
  alias Spectre.Governance.Approval.Policy, as: ApprovalPolicy
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Handlers.Skill, as: SkillHandler
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.ChangeSet.Registry
  alias Spectre.Governance.Composer
  alias Spectre.Governance.Composition
  alias Spectre.Governance.Constraints
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.Review
  alias Spectre.Governance.Verifier
  alias Spectre.Instance.Activation
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias SpectreGovernanceRuntimeContractCoverageTest.Agent
  alias SpectreGovernanceRuntimeContractCoverageTest.MissingArtifactStore
  alias SpectreGovernanceRuntimeContractCoverageTest.ReceiptFailingStore
  alias SpectreGovernanceRuntimeContractCoverageTest.UnavailableStore

  @checker_versions %{
    replay: {"coverage.replay", 1},
    regression: {"coverage.regression", 1}
  }

  test "Composer honors an explicit closed registry and fails before publishing without its base" do
    %{store: store, activation: activation} = baseline()
    change_set = change_set(activation, [evaluation_case_operation()])

    assert {:error, :governance_composer_requires_activation} =
             Composer.compose(store, change_set)

    empty_store = memory_store()

    assert {:error, :governance_parent_definition_not_found} =
             Composer.compose(empty_store, change_set,
               activation: activation,
               handler_registry: Registry.default(),
               created_at: 2
             )

    assert {:ok, candidate_ref} =
             Composer.compose(store, change_set,
               activation: activation,
               handler_registry: Registry.default(),
               created_at: 2
             )

    assert {:ok, %{governance: %{state: :composed, risk: :low}}} =
             Store.fetch_candidate(store, candidate_ref)
  end

  test "Composer requires a protected corpus and never publishes a Candidate after receipt failure" do
    no_corpus = %{closure() | evaluation_corpus_digest: nil}
    context = baseline(no_corpus)
    change_set = change_set(context.activation, [evaluation_case_operation()])

    assert {:error, :governance_protected_corpus_required} =
             Composer.compose(context.store, change_set,
               activation: context.activation,
               created_at: 2
             )

    context = baseline()
    change_set = change_set(context.activation, [evaluation_case_operation()])
    failing_store = {ReceiptFailingStore, server: context.server, test_pid: self()}

    assert {:error, :governance_receipt_write_failed} =
             Composer.compose(failing_store, change_set,
               activation: context.activation,
               created_at: 2
             )

    refute_receive :candidate_write_attempted

    assert {:ok, semantic_ref} =
             Composer.compose(context.store, change_set,
               activation: context.activation,
               require_semantic_live?: true,
               created_at: 2
             )

    assert {:ok, %{governance: governance}} =
             Store.fetch_candidate(context.store, semantic_ref)

    assert :semantic_live in governance.required_gates
  end

  test "Verifier accepts automatic low-risk approval and rejects malformed external evidence" do
    context = automatic_approved_candidate()
    governance = context.resolved.candidate.governance

    assert {:ok, approval_receipt} =
             Store.fetch_gate_receipt(context.store, governance.approval_receipt_ref)

    assert approval_receipt.provenance["mode"] == "automatic"
    assert approval_receipt.provenance["actor_ref"] == "spectre:auto-approval"

    assert :ok =
             Verifier.verify_activation(
               context.store,
               context.resolved,
               context.activation,
               verifier_opts(approval_policy: ApprovalPolicy.default())
             )

    assert {:error, :invalid_governance_external_evidence} =
             Verifier.verify_activation(
               context.store,
               context.resolved,
               context.activation,
               verifier_opts(evidence: [])
             )
  end

  test "Verifier distinguishes a missing promotion parent from an unavailable Store" do
    context = automatic_approved_candidate()
    parent_ref = context.resolved.candidate.parent_ref

    assert {:error, {:governance_candidate_parent_not_found, :approved, ^parent_ref}} =
             Verifier.verify_activation(
               memory_store(),
               context.resolved,
               context.activation,
               verifier_opts()
             )

    assert {:error, :governance_store_unavailable} =
             Verifier.verify_activation(
               UnavailableStore,
               context.resolved,
               context.activation,
               verifier_opts()
             )
  end

  test "Verifier never promotes a Candidate whose approval receipt disappeared" do
    context = automatic_approved_candidate()
    receipt_ref = context.resolved.candidate.governance.approval_receipt_ref
    key = "gate-receipt/" <> receipt_ref

    missing_receipt_store =
      {MissingArtifactStore, server: context.server, missing_key: key}

    assert {:error, {:gate_receipt_not_found, ^receipt_ref}} =
             Verifier.verify_activation(
               missing_receipt_store,
               context.resolved,
               context.activation,
               verifier_opts()
             )
  end

  test "Verifier rejects every tampered promotion-lineage invariant" do
    context = automatic_approved_candidate()
    candidate = context.resolved.candidate
    governance = candidate.governance

    assert {:error, :governance_promotion_proposal_mismatch} =
             verify_recovery_with(context, %{
               governance
               | proposal_digest: String.duplicate("f", 64)
             })

    definition_tamper = %{candidate | definition_ref: context.activation.definition_ref}

    assert {:error, :governance_promotion_definition_mismatch} =
             Verifier.verify_recovery(
               context.store,
               put_in(context.resolved, [:candidate], definition_tamper),
               verifier_opts()
             )

    assert {:error, :governance_promotion_base_candidate_mismatch} =
             verify_recovery_with(context, %{
               governance
               | base_candidate_ref: "candidate:sha256:" <> String.duplicate("e", 64)
             })

    assert {:error, :governance_promotion_parent_definition_mismatch} =
             verify_recovery_with(context, %{
               governance
               | parent_definition_ref: "sha256:" <> String.duplicate("d", 64)
             })

    assert {:error, :governance_promotion_lineage_mismatch} =
             verify_recovery_with(context, %{governance | lineage_refs: []})

    assert {:ok, evaluated} = Store.fetch_candidate(context.store, candidate.parent_ref)
    [required_ref | _rest] = evaluated.governance.gate_receipt_refs

    assert {:error, :governance_promotion_receipts_not_monotonic} =
             verify_recovery_with(context, %{
               governance
               | gate_receipt_refs: List.delete(governance.gate_receipt_refs, required_ref)
             })

    assert {:error, :governance_promotion_report_mismatch} =
             verify_recovery_with(context, %{
               governance
               | report_digest: String.duplicate("c", 64)
             })

    assert {:error, :governance_promotion_approval_mismatch} =
             verify_recovery_with(context, %{governance | approval_receipt_ref: nil})
  end

  test "Verifier rejects semantically invalid but correctly stored approval receipts" do
    context = automatic_approved_candidate()
    governance = context.resolved.candidate.governance

    assert {:ok, approval} =
             Store.fetch_gate_receipt(context.store, governance.approval_receipt_ref)

    invalid_mode =
      approval
      |> receipt_with(provenance: Map.put(approval.provenance, "mode", "delegated"))
      |> publish_replacement_approval(context)

    assert {:error, {:invalid_approval_receipt_mode, "delegated"}} =
             Verifier.verify_recovery(
               context.store,
               invalid_mode,
               verifier_opts()
             )

    invalid_provenance =
      approval
      |> receipt_with(provenance: Map.delete(approval.provenance, "actor_ref"))
      |> publish_replacement_approval(context)

    assert {:error, :invalid_approval_receipt_provenance} =
             Verifier.verify_recovery(
               context.store,
               invalid_provenance,
               verifier_opts()
             )

    invalid_result =
      approval
      |> receipt_with(result_digest: String.duplicate("0", 64))
      |> publish_replacement_approval(context)

    assert {:error, :approval_receipt_result_mismatch} =
             Verifier.verify_recovery(
               context.store,
               invalid_result,
               verifier_opts()
             )

    strict_policy = %{
      low: :human,
      medium: :human,
      high: :human,
      critical: :human
    }

    assert {:error, :approval_policy_not_satisfied} =
             Verifier.verify_recovery(
               context.store,
               context.resolved,
               verifier_opts(approval_policy: strict_policy)
             )
  end

  test "Verifier rejects a promotion whose signed report body is missing or malformed" do
    context = automatic_approved_candidate()
    governance = context.resolved.candidate.governance

    assert {:error, :governance_candidate_report_missing} =
             verify_recovery_with(context, %{governance | report: nil})

    malformed_report = %{governance.report | evaluation_delta: %{}}

    assert {:error, {:invalid_evaluation_delta_fields, _fields}} =
             verify_recovery_with(context, %{governance | report: malformed_report})
  end

  test "Skill composition and persisted constraints enforce every execution budget" do
    base = Composition.new(Definition.canonical!(Agent))
    operation = operation!(mount_operation())
    broad = inference_authority()

    assert {:ok, mounted} = SkillHandler.apply(operation, base, handler_context(broad))

    assert mounted.changed_components == [:skills]
    assert mounted.risk == :medium

    checks = [
      {:max_cost, :cost, 10, 9},
      {:max_duration_ms, :duration_ms, 100, 99},
      {:max_pages, :pages, 4, 3}
    ]

    Enum.each(checks, fn {limit, budget, requested, ceiling} ->
      authority = inference_authority(%{limit => ceiling})

      expected =
        {:execution_budget_not_authorized, "governed_inference", budget, requested, ceiling}

      assert {:error, ^expected} =
               SkillHandler.apply(operation, base, handler_context(authority))

      assert {:ok, constraints} = Constraints.new(authority, [])

      assert {:error, ^expected} =
               Constraints.verify_definition(mounted.definition, authority, constraints)
    end)

    without_purpose = %{broad | model_purposes: []}
    assert {:ok, constraints} = Constraints.new(without_purpose, [])

    assert {:error,
            {:execution_model_purpose_not_authorized, "governed_inference", :data_driven_work}} =
             Constraints.verify_definition(mounted.definition, without_purpose, constraints)

    without_profile = %{broad | model_profiles: []}
    assert {:ok, constraints} = Constraints.new(without_profile, [])

    assert {:error, {:execution_model_profile_not_authorized, "governed_inference", "deep"}} =
             Constraints.verify_definition(mounted.definition, without_profile, constraints)
  end

  test "Skill governance rejects unsupported operations and malformed runtime snapshots" do
    base = Composition.new(Definition.canonical!(Agent))
    authority = inference_authority()
    context = handler_context(authority)

    assert {:error, {:unsupported_skill_governance_operation, "delete_skill"}} =
             SkillHandler.apply(
               %Operation{type: "delete_skill", payload: %{}},
               base,
               context
             )

    assert {:error, {:invalid_skill_governance_field, :mount_id, nil}} =
             SkillHandler.apply(
               operation!(put_in(mount_operation(), ["payload", "mount_id"], nil)),
               base,
               context
             )

    assert {:error, {:invalid_skill_governance_field, :changes, %{}}} =
             SkillHandler.apply(
               operation!(%{
                 "type" => "update_skill_config",
                 "payload" => %{"mount_id" => "inference", "changes" => %{}}
               }),
               base,
               context
             )

    runtime_skill = SkillDefinition.new!(runtime_inference_skill())
    skill_composition = Composition.new(SkillDefinition.canonical(runtime_skill))

    assert {:error, {:governance_requires_agent_definition, :skill}} =
             SkillHandler.apply(operation!(mount_operation()), skill_composition, context)

    assert {:error, {:skill_mount_not_found, "missing"}} =
             SkillHandler.apply(
               operation!(put_in(mount_operation(), ["payload", "mount_id"], "missing"))
               |> Map.put(:type, "replace_skill"),
               base,
               context
             )

    assert {:ok, mounted} =
             SkillHandler.apply(operation!(mount_operation()), base, context)

    malformed = corrupt_mounted_runtime_config(mounted.definition, "not-a-map")

    assert {:error, {:invalid_governance_skill_config, :binary}} =
             SkillHandler.apply(
               operation!(%{
                 "type" => "update_skill_config",
                 "payload" => %{
                   "mount_id" => "inference",
                   "changes" => %{"feature.enabled" => true}
                 }
               }),
               %{mounted | definition: malformed},
               Map.put(context, :mutable_config_paths, %{
                 "inference" => ["feature.enabled"]
               })
             )

    missing_snapshot = corrupt_mount_snapshot(mounted.definition, nil)

    assert {:error, {:governance_mount_has_no_runtime_definition, :other}} =
             SkillHandler.apply(
               operation!(%{
                 "type" => "update_skill_config",
                 "payload" => %{
                   "mount_id" => "inference",
                   "changes" => %{"feature.enabled" => true}
                 }
               }),
               %{mounted | definition: missing_snapshot},
               Map.put(context, :mutable_config_paths, %{
                 "inference" => ["feature.enabled"]
               })
             )

    malformed_mounts = replace_skill_mount_collection(mounted.definition, "not-a-list")

    assert {:error, {:invalid_governance_skill_mounts, :binary}} =
             SkillHandler.apply(
               operation!(%{
                 "type" => "disable_skill",
                 "payload" => %{"mount_id" => "inference"}
               }),
               %{mounted | definition: malformed_mounts},
               context
             )

    assert {:ok, constraints} = Constraints.new(authority, [])

    assert {:error, {:invalid_governance_skill_mounts, :binary}} =
             Constraints.verify_definition(malformed_mounts, authority, constraints)

    malformed_entry = replace_skill_mount_collection(mounted.definition, [42])

    assert {:error, {:invalid_governed_skill_mount, 0}} =
             Constraints.verify_definition(malformed_entry, authority, constraints)

    assert {:error, {:skill_config_not_mutable, "inference"}} =
             SkillHandler.apply(
               operation!(%{
                 "type" => "update_skill_config",
                 "payload" => %{
                   "mount_id" => "inference",
                   "changes" => %{"feature.enabled" => true}
                 }
               }),
               mounted,
               Map.put(context, :mutable_config_paths, %{"inference" => [42]})
             )
  end

  test "EvaluationDelta transport rejects missing corpora and malformed result collections" do
    assert {:error, :evaluation_delta_protected_corpus_required} =
             EvaluationDelta.new([], [], protected_cases: [])

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}],
        protected_cases: [protected_case()]
      )

    data = EvaluationDelta.to_data(delta)

    assert {:error, :invalid_evaluation_delta_protected_results} =
             data
             |> Map.put("protected_results", %{})
             |> EvaluationDelta.from_data()

    assert {:error, :invalid_evaluation_delta_candidate_results} =
             data
             |> Map.put("candidate_owned_results", :invalid)
             |> EvaluationDelta.from_data()
  end

  defp automatic_approved_candidate do
    context = baseline()
    change_set = change_set(context.activation, [evaluation_case_operation()])

    assert {:ok, composed_ref} =
             Composer.compose(context.store, change_set,
               activation: context.activation,
               created_at: 2
             )

    assert {:ok, %{governance: governance}} =
             Store.fetch_candidate(context.store, composed_ref)

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [
          %{case_id: "protected", passed: true},
          %{case_id: "candidate-owned", passed: true}
        ],
        protected_cases: [protected_case()],
        candidate_case_ids: ["candidate-owned"]
      )

    receipts = [
      gate_receipt(governance, :replay, profile_ref: "recording:coverage"),
      gate_receipt(governance, :regression)
    ]

    assert {:ok, evaluated_ref, _report} =
             Review.evaluate(context.store, composed_ref, delta, receipts,
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert {:ok, approved_ref} =
             Approval.approve(context.store, evaluated_ref, approved_at: 6)

    assert {:ok, resolved} =
             Resolver.resolve_candidate_for_activation(context.store, approved_ref)

    Map.put(context, :resolved, resolved)
  end

  defp baseline(execution_closure \\ closure()) do
    {store, server} = memory_store_with_server()
    canonical = Definition.canonical!(Agent)
    authority = Envelope.new!(operations: ["lookup"])
    manifest = Manifest.new!(canonical, authority, execution_closure)

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, candidate_ref} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, %{candidate: candidate, resolution: resolution}} =
             Resolver.resolve_candidate_for_activation(store, candidate_ref)

    assert {:ok, activation} =
             Activation.new(candidate, resolution,
               generation: 1,
               authority_epoch: 0,
               owner_fencing_token: 1,
               activated_at: 1
             )

    %{store: store, server: server, activation: activation}
  end

  defp memory_store do
    {store, _server} = memory_store_with_server()
    store
  end

  defp memory_store_with_server do
    id = {:governance_runtime_coverage, System.unique_integer([:positive, :monotonic])}

    server =
      start_supervised!(%{
        id: id,
        start: {Memory, :start_link, [[id: id]]}
      })

    {{Memory, server: server}, server}
  end

  defp change_set(activation, operations) do
    ChangeSet.new!(%{
      base_activation_receipt: activation.activation_receipt,
      base_candidate_ref: activation.candidate_ref,
      observed_definition_ref: activation.definition_ref,
      observed_authority_epoch: activation.authority_epoch,
      observed_evidence_digest: ChangeSet.evidence_digest(activation),
      operations: operations,
      author_ref: "host:coverage",
      provenance: %{source: "governance-runtime-contract"},
      reason: "Exercise the governed promotion contract",
      created_at: 2
    })
  end

  defp evaluation_case_operation do
    %{
      "type" => "add_eval_case",
      "payload" => %{"case" => %{"id" => "candidate-owned", "input" => "lookup"}}
    }
  end

  defp gate_receipt(governance, gate, opts \\ []) do
    Receipt.new!(%{
      gate_class: gate,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: "coverage.#{gate}",
      checker_version: 1,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: Keyword.get(opts, :profile_ref),
      issued_at: 3,
      expires_at: nil,
      status: :passed,
      result_digest: Value.digest!(%{gate: gate, passed: true}),
      provenance: %{source: :coverage_checker}
    })
  end

  defp verifier_opts(extra \\ []) do
    Keyword.merge([now: 7, checker_versions: @checker_versions], extra)
  end

  defp protected_case, do: %{"id" => "protected", "input" => "lookup"}

  defp closure do
    {:ok, build_digest} = Closure.fingerprint(Agent)

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
      build_fingerprints: %{("beam:" <> Atom.to_string(Agent)) => build_digest},
      evaluation_corpus_digest: EvaluationDelta.protected_corpus_digest!([protected_case()]),
      compatibility_mode: :native_v2
    })
  end

  defp mount_operation do
    %{
      "type" => "mount_skill",
      "payload" => %{
        "mount_id" => "inference",
        "definition" => runtime_inference_skill()
      }
    }
  end

  defp runtime_inference_skill do
    program =
      Program.new!(%{
        id: "governed_inference",
        entry: :infer,
        input: :map,
        state: :map,
        initial: :input,
        budget: %{
          steps: 2,
          attempts: 2,
          cost: 10,
          duration_ms: 100,
          pages: 4
        },
        nodes: [
          %{
            id: :infer,
            kind: :infer,
            operation: :infer,
            prompt: :guide,
            profile_ref: :deep,
            next: :done
          },
          %{id: :done, kind: :complete, output: :state}
        ]
      })

    %{
      "id" => "governed-inference",
      "declared_version" => 1,
      "publisher_ref" => "host:coverage",
      "applicability" => %{
        "scopes" => ["support"],
        "positive" => ["infer"],
        "negative" => ["delete everything"]
      },
      "operation_refs" => ["infer"],
      "prompt_budget" => 64,
      "prompt_fragments" => [
        %{
          "id" => "guide",
          "content" => "Use inference",
          "token_cap" => 8,
          "budget_class" => "small"
        }
      ],
      "works" => [Program.to_data(program)],
      "flows" => [
        %{
          "id" => "support",
          "routes" => [
            %{
              "label" => "INFER",
              "match" => %{"kind" => "exact", "value" => "infer"},
              "handler" => %{
                "kind" => "work",
                "work_ref" => "governed_inference",
                "input" => "input"
              }
            }
          ]
        }
      ]
    }
  end

  defp inference_authority(extra_limits \\ %{}) do
    Envelope.new!(
      operations: ["infer"],
      prompt_budget_classes: [:small],
      model_purposes: [:data_driven_work],
      model_profiles: [:deep],
      limits: Map.merge(%{max_tokens: 64}, extra_limits)
    )
  end

  defp handler_context(authority) do
    %{
      authority: authority,
      prompt_token_ceiling: 64,
      mutable_config_paths: %{},
      applicability_ceilings: %{},
      registered_migrations: []
    }
  end

  defp operation!(data) do
    {:ok, operation} = Operation.new(data)
    operation
  end

  defp verify_recovery_with(context, governance) do
    candidate = %{context.resolved.candidate | governance: governance}
    resolved = %{context.resolved | candidate: candidate}
    Verifier.verify_recovery(context.store, resolved, verifier_opts())
  end

  defp receipt_with(receipt, updates) do
    receipt
    |> Map.from_struct()
    |> Map.merge(Map.new(updates))
    |> Receipt.new!()
  end

  defp publish_replacement_approval(receipt, context) do
    assert {:ok, receipt_ref} = Store.publish_gate_receipt(context.store, receipt)
    receipt_ref = to_string(receipt_ref)
    governance = context.resolved.candidate.governance

    refs =
      governance.gate_receipt_refs
      |> List.delete(governance.approval_receipt_ref)
      |> Kernel.++([receipt_ref])

    next_governance = %{
      governance
      | approval_receipt_ref: receipt_ref,
        gate_receipt_refs: refs
    }

    candidate = %{context.resolved.candidate | governance: next_governance}
    %{context.resolved | candidate: candidate}
  end

  defp corrupt_mounted_runtime_config(definition, invalid_config) do
    update_skill_mounts(definition, fn [mount] ->
      {:ok, skill} = mount |> Map.fetch!("definition") |> Canonical.from_data()

      malformed_skill =
        replace_component_payload(skill, :compiled_runtime, &Map.put(&1, :config, invalid_config))

      [
        mount
        |> Map.put("definition_ref", malformed_skill |> Canonical.ref() |> to_string())
        |> Map.put("definition", Canonical.to_data(malformed_skill))
      ]
    end)
  end

  defp corrupt_mount_snapshot(definition, snapshot) do
    update_skill_mounts(definition, fn [mount] -> [Map.put(mount, "definition", snapshot)] end)
  end

  defp replace_skill_mount_collection(definition, mounts) do
    {:ok, component} = Canonical.fetch_component(definition, :skills)
    payload = Map.put(component.payload, :mounts, mounts)
    replacement = Component.new!(%{component | payload: payload})

    components =
      Enum.map(definition.components, fn
        %{component_type: :skills} -> replacement
        component -> component
      end)

    Canonical.new!(%{definition | components: components})
  end

  defp update_skill_mounts(definition, update) do
    {:ok, component} = Canonical.fetch_component(definition, :skills)
    mounts = Map.get(component.payload, :mounts, Map.get(component.payload, "mounts", []))
    payload = Map.put(component.payload, :mounts, update.(mounts))
    replacement = Component.new!(%{component | payload: payload})

    components =
      Enum.map(definition.components, fn
        %{component_type: :skills} -> replacement
        component -> component
      end)

    Canonical.new!(%{definition | components: components})
  end

  defp replace_component_payload(definition, type, update) do
    {:ok, component} = Canonical.fetch_component(definition, type)
    replacement = Component.new!(%{component | payload: update.(component.payload)})

    components =
      Enum.map(definition.components, fn
        %{component_type: ^type} -> replacement
        component -> component
      end)

    Canonical.new!(%{definition | components: components})
  end
end
