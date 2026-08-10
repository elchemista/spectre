defmodule SpectreGovernanceGateTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :governance_gate_agent
end

defmodule SpectreGovernanceGateTest.InvalidResultHandler do
  @moduledoc false
  @behaviour Spectre.Governance.ChangeSet.Handler

  def operation_types, do: ["invalid_result"]
  def component_classes, do: [:metadata]
  def apply(_operation, _composition, _context), do: {:ok, :not_a_composition}
end

defmodule SpectreGovernanceGateTest.CrashingHandler do
  @moduledoc false
  @behaviour Spectre.Governance.ChangeSet.Handler

  def operation_types, do: ["crashing"]
  def component_classes, do: [:metadata]
  def apply(_operation, _composition, _context), do: raise("handler crash")
end

defmodule SpectreGovernanceGateTest.InvalidTypesHandler do
  @moduledoc false
  def operation_types, do: [42]
  def component_classes, do: [:metadata]
  def apply(_operation, composition, _context), do: {:ok, composition}
end

defmodule SpectreGovernanceGateTest.InvalidClassesHandler do
  @moduledoc false
  def operation_types, do: ["invalid_classes"]
  def component_classes, do: []
  def apply(_operation, composition, _context), do: {:ok, composition}
end

defmodule SpectreGovernanceGateTest.RaisingMetadataHandler do
  @moduledoc false
  def operation_types, do: raise("metadata crash")
  def component_classes, do: [:metadata]
  def apply(_operation, composition, _context), do: {:ok, composition}
end

defmodule SpectreGovernanceGateTest.UndeclaredComponentHandler do
  @moduledoc false
  @behaviour Spectre.Governance.ChangeSet.Handler

  alias Spectre.Governance.Composition

  def operation_types, do: ["undeclared_component"]
  def component_classes, do: [:metadata]

  def apply(_operation, composition, _context) do
    {:ok,
     Composition.mark(
       composition,
       "undeclared_component",
       [:authority],
       :low
     )}
  end
end

defmodule SpectreGovernanceGateTest.HiddenComponentHandler do
  @moduledoc false
  @behaviour Spectre.Governance.ChangeSet.Handler

  alias Spectre.Governance.Composition

  def operation_types, do: ["hidden_component"]
  def component_classes, do: [:metadata]

  def apply(_operation, composition, _context) do
    definition = %{composition.definition | components: tl(composition.definition.components)}
    next = %{composition | definition: definition}

    {:ok, Composition.mark(next, "hidden_component", [:metadata], :low)}
  end
end

defmodule SpectreGovernanceGateTest.CountingStore do
  @moduledoc false
  @behaviour Spectre.Definition.Store

  alias Spectre.Definition.Store.Memory

  @impl true
  def identity(opts), do: Memory.identity(backend_opts(opts))

  @impl true
  def durability(_opts), do: :volatile

  @impl true
  def get(key, opts) do
    send(Keyword.fetch!(opts, :observer), {:definition_store_get, key})
    Memory.get(key, backend_opts(opts))
  end

  @impl true
  def put(key, encoded, opts), do: Memory.put(key, encoded, backend_opts(opts))

  defp backend_opts(opts), do: Keyword.take(opts, [:server])
end

defmodule SpectreGovernanceGateTest.DurableDefinitionStore do
  @moduledoc false
  @behaviour Spectre.Definition.Store

  @impl true
  def identity(opts), do: {:governance_durable, Keyword.fetch!(opts, :id)}

  @impl true
  def durability(_opts), do: :durable

  @impl true
  def get(key, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        {:ok, encoded} -> {:ok, encoded}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def put(key, encoded, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, key) do
        :error -> {{:ok, :created}, Map.put(entries, key, encoded)}
        {:ok, ^encoded} -> {{:ok, :existing}, entries}
        {:ok, _different} -> {{:error, {:immutable_conflict, key}}, entries}
      end
    end)
  end
end

defmodule SpectreGovernanceGateTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn state ->
      case Map.fetch(state.entries, ref.key) do
        {:ok, {_revision, checkpoint}} -> {:ok, checkpoint}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn state ->
      compare_and_swap_state(state, ref.key, checkpoint, expected, revision)
    end)
  end

  def fail_next(server), do: Agent.update(server, &%{&1 | fail_next?: true})

  defp compare_and_swap_state(
         %{fail_next?: true} = state,
         _key,
         _checkpoint,
         _expected,
         _revision
       ),
       do: {{:error, :injected_checkpoint_failure}, %{state | fail_next?: false}}

  defp compare_and_swap_state(state, key, checkpoint, expected, revision) do
    case Map.get(state.entries, key) do
      nil when expected == 0 ->
        {:ok, put_in(state, [:entries, key], {revision, checkpoint})}

      {^expected, _current} ->
        {:ok, put_in(state, [:entries, key], {revision, checkpoint})}

      {current, _checkpoint} ->
        {{:error, {:stale, expected, current}}, state}

      nil ->
        {{:error, {:stale, expected, :not_found}}, state}
    end
  end
end

defmodule SpectreGovernanceGateTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Foundation.Conformance
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.Approval
  alias Spectre.Governance.Approval.Policy, as: ApprovalPolicy
  alias Spectre.Governance.Authority, as: GovernanceAuthority
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.ChangeSet.Registry
  alias Spectre.Governance.Composer
  alias Spectre.Governance.Composition
  alias Spectre.Governance.Constraints
  alias Spectre.Governance.Data, as: GovernanceData
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.GC
  alias Spectre.Governance.GC.Plan, as: GCPlan
  alias Spectre.Governance.Review
  alias Spectre.Instance
  alias Spectre.Projection.HumanReport
  alias Spectre.Skill.Applicability
  alias Spectre.Subject

  alias SpectreGovernanceGateTest.Agent
  alias SpectreGovernanceGateTest.CheckpointStore
  alias SpectreGovernanceGateTest.CountingStore
  alias SpectreGovernanceGateTest.DurableDefinitionStore

  @digest String.duplicate("a", 64)
  @checker_versions %{
    replay: {"test.replay", 1},
    regression: {"test.regression", 1}
  }

  test "the 0.2.9 fixture pins every portable governance identity" do
    fixture =
      "test/fixtures/compatibility/0.2.9/governance-v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert fixture["schema_version"] == 1
    assert fixture["release"] == "0.2.9"

    assert {:ok, change_set} = ChangeSet.from_data(fixture["change_set"])
    assert {:ok, governance} = CandidateState.new(fixture["candidate_state"])
    assert {:ok, receipt} = Receipt.new(fixture["gate_receipt"])
    assert {:ok, delta} = EvaluationDelta.from_data(fixture["evaluation_delta"])
    assert {:ok, report} = HumanReport.from_data(fixture["human_report"])
    assert {:ok, gc_plan} = GCPlan.from_data(fixture["gc_plan"])

    expected = fixture["expected"]

    assert ChangeSet.digest(change_set) == expected["change_set_digest"]
    assert governance.proposal_digest == expected["proposal_digest"]
    assert to_string(Receipt.ref(receipt)) == expected["gate_receipt_ref"]
    assert EvaluationDelta.digest(delta) == expected["evaluation_delta_digest"]
    assert report.digest == expected["human_report_digest"]
    assert gc_plan.digest == expected["gc_plan_digest"]
    assert :ok = Receipt.verify_binding(receipt, governance)
    assert :ok = HumanReport.verify(report)
    assert :ok = GCPlan.verify(gc_plan)

    assert {:ok, ^change_set} = change_set |> ChangeSet.encode() |> elem(1) |> ChangeSet.decode()
    assert {:ok, ^receipt} = receipt |> Receipt.encode() |> elem(1) |> Receipt.decode()
    assert {:ok, ^report} = report |> HumanReport.encode() |> elem(1) |> HumanReport.decode()
    assert {:ok, ^gc_plan} = gc_plan |> GCPlan.encode() |> elem(1) |> GCPlan.decode()

    matrix = Conformance.matrix()
    assert matrix.release == "0.2.9"

    assert fixture["schemas"] == %{
             "change_set" => matrix.governance.change_set_schema,
             "candidate_state" => matrix.governance.candidate_state_schema,
             "gate_receipt" => matrix.governance.gate_receipt_schema,
             "evaluation_delta" => matrix.governance.evaluation_delta_schema,
             "human_report_generator" => matrix.governance.human_report_generator,
             "gc_plan" => matrix.governance.gc_plan_schema
           }

    Enum.each(matrix.golden_path, fn {module, function, arity} ->
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, function, arity)
    end)
  end

  test "host flow composes, evaluates, approves, activates and rolls back with exact lineage" do
    %{store: store, instance: instance, activation: activation, candidate: base_candidate} =
      baseline()

    change_set = change_set(activation, [mount_operation()])

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set,
               activation: activation,
               created_at: 2,
               required_gates: [:structural],
               applicability_ceilings: %{
                 "lookup" => %{
                   scopes: ["support"],
                   required_tags: [],
                   forbidden_tags: [],
                   conflicts: []
                 }
               }
             )

    assert {:ok, %Candidate{governance: governance} = composed} =
             Store.fetch_candidate(store, composed_ref)

    assert composed.parent_ref == base_candidate
    assert governance.state == :composed
    assert governance.risk == :medium
    assert governance.base_candidate_ref == to_string(base_candidate)
    assert governance.candidate_case_ids == []

    assert governance.required_gates ==
             CandidateState.constitutional_gates(:medium) |> Enum.sort()

    assert governance.applicability_ceilings["lookup"]["scopes"] == ["support"]
    assert length(governance.gate_receipt_refs) == 5

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true, score: 1.0}],
        [%{case_id: "protected", passed: true, score: 1.0}],
        candidate_case_ids: []
      )

    receipts = [
      receipt(governance, :replay, 3, profile_ref: "recording:governance"),
      receipt(governance, :regression, 3)
    ]

    assert {:ok, reviewed_ref, report} =
             Review.evaluate(store, composed_ref, delta, receipts,
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert report.parent_definition_ref == governance.parent_definition_ref
    assert report.candidate_definition_ref == governance.candidate_definition_ref
    assert report.structural_changes != []
    assert report.digest == report |> Map.fetch!(:digest)

    assert {:ok, %Candidate{governance: reviewed_governance}} =
             Store.fetch_candidate(store, reviewed_ref)

    assert reviewed_governance.report == report
    assert reviewed_governance.report.evaluation_delta == EvaluationDelta.to_data(delta)

    report_data = report |> HumanReport.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^report} = HumanReport.from_data(report_data)
    assert {:ok, ^report} = report |> HumanReport.encode() |> elem(1) |> HumanReport.decode()

    assert {:error, :candidate_risk_requires_human_approval} =
             Approval.approve(store, reviewed_ref,
               mode: :automatic,
               approved_at: 6
             )

    assert {:ok, approved_ref} =
             Approval.approve(store, reviewed_ref,
               mode: :human,
               actor_ref: "operator:alice",
               approved_at: 6
             )

    assert {:ok, approved} = Store.fetch_candidate(store, approved_ref, now: 7)
    assert approved.governance.state == :approved
    assert approved.governance.approval_receipt_ref in approved.governance.gate_receipt_refs

    assert {:ok, activated} =
             Spectre.activate(instance, approved_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert activated.generation == 2
    assert to_string(activated.definition_ref) == governance.candidate_definition_ref
    assert activated.candidate_ref == approved_ref

    assert {:ok, rolled_back} =
             Spectre.rollback(instance, base_candidate,
               expected_generation: 2,
               now: 8
             )

    assert rolled_back.generation == 3
    assert rolled_back.definition_ref == activation.definition_ref
    assert rolled_back.provenance.external_effects_rolled_back == false
  end

  test "stale ChangeSets and ungranted operations fail before publication" do
    %{store: store, activation: activation} = baseline()
    stale = change_set(activation, [mount_operation()])
    forged_activation = %{activation | authority_epoch: activation.authority_epoch + 1}

    assert {:error, :stale_governance_authority_epoch} =
             Composer.compose(store, stale,
               activation: forged_activation,
               created_at: 2
             )

    unauthorized =
      mount_operation()
      |> put_in(["payload", "definition", "operation_refs"], ["delete_everything"])
      |> put_in(
        [
          "payload",
          "definition",
          "flows",
          Access.at(0),
          "routes",
          Access.at(0),
          "handler",
          "operation_ref"
        ],
        "delete_everything"
      )

    assert {:error,
            {:governance_operation_failed, 0,
             {:governance_operation_authority_exceeded, "delete_everything"}}} =
             Composer.compose(store, change_set(activation, [unauthorized]),
               activation: activation,
               created_at: 2
             )
  end

  test "Candidate-owned eval cases add obligations but never positive score" do
    assert {:ok, delta} =
             EvaluationDelta.new(
               [%{case_id: "protected", passed: true, score: 1.0}],
               [
                 %{case_id: "protected", passed: false, score: 0.0},
                 %{case_id: "candidate-owned", passed: true, score: 100.0}
               ],
               candidate_case_ids: ["candidate-owned"]
             )

    refute delta.passed
    assert delta.parent_score == 1.0
    assert delta.candidate_score == 0.0
    assert delta.score_delta == -1.0
    assert delta.regressions == ["protected"]

    assert {:ok, restored} = delta |> EvaluationDelta.to_data() |> EvaluationDelta.from_data()
    assert restored == delta

    pair = hd(delta.protected_results)

    duplicate =
      delta
      |> EvaluationDelta.to_data()
      |> Map.put("protected_results", [pair, pair])
      |> Map.put("protected_cases_digest", Value.digest!(["protected", "protected"]))
      |> Map.put("regressions", ["protected", "protected"])

    assert {:error, {:duplicate_evaluation_case_result, :parent, "protected"}} =
             EvaluationDelta.from_data(duplicate)
  end

  test "constitutional gate floors cannot be reduced and failed extra evidence rejects" do
    %{store: store, activation: activation} = baseline()

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set(activation, [mount_operation()]),
               activation: activation,
               created_at: 2,
               required_gates: [:structural]
             )

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    assert governance.required_gates ==
             CandidateState.constitutional_gates(:medium) |> Enum.sort()

    reduced =
      governance
      |> CandidateState.to_data()
      |> Map.delete("proposal_digest")
      |> Map.put("required_gates", ["structural"])

    assert {:error, {:governance_required_gate_floor_violated, missing}} =
             CandidateState.new(reduced)

    assert :replay in missing
    assert :regression in missing
    assert :evaluation_delta in missing

    critical =
      governance
      |> CandidateState.to_data()
      |> Map.delete("proposal_digest")
      |> Map.put("risk", "critical")

    assert {:error, {:governance_required_gate_floor_violated, [:semantic_live]}} =
             CandidateState.new(critical)

    assert {:ok, %{risk: :critical}} =
             critical
             |> Map.update!("required_gates", &["semantic_live" | &1])
             |> CandidateState.new()

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    receipts = [
      receipt(governance, :replay, 3, profile_ref: "recording:test"),
      receipt(governance, :regression, 3),
      receipt(governance, :semantic_live, 3,
        profile_ref: "model:live",
        expires_at: 10,
        status: :failed,
        provenance: %{
          source: :test_checker,
          variability: %{
            sample_count: 3,
            measure_digest: Value.digest!(%{scores: [0.1, 0.9, 0.2]})
          }
        }
      )
    ]

    assert {:ok, rejected_ref, _report} =
             Review.evaluate(store, composed_ref, delta, receipts,
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert {:ok, %Candidate{governance: %{state: :rejected}}} =
             Store.fetch_candidate(store, rejected_ref)
  end

  test "activation rejects any attached failed receipt even outside the required set" do
    %{store: store, instance: instance, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)
    assert {:ok, approved} = Store.fetch_candidate(store, approved_ref, now: 7)

    failed =
      receipt(approved.governance, :semantic_live, 6,
        profile_ref: "model:live",
        expires_at: 20,
        status: :failed,
        provenance: %{
          source: :test_checker,
          variability: %{
            sample_count: 2,
            measure_digest: Value.digest!(%{scores: [0.0, 1.0]})
          }
        }
      )

    assert {:ok, failed_ref} = Store.publish_gate_receipt(store, failed)

    gate_receipt_refs =
      Enum.sort(approved.governance.gate_receipt_refs ++ [to_string(failed_ref)])

    assert {:ok, parent_artifact} =
             Store.fetch(store, approved.governance.parent_definition_ref)

    assert {:ok, candidate_artifact} =
             Store.fetch(store, approved.governance.candidate_definition_ref)

    assert {:ok, delta} =
             EvaluationDelta.from_data(approved.governance.report.evaluation_delta)

    assert {:ok, report} =
             HumanReport.project(parent_artifact.definition, candidate_artifact.definition,
               evaluation_delta: delta,
               lineage_refs: approved.governance.report.lineage_refs,
               gate_receipt_refs:
                 List.delete(gate_receipt_refs, approved.governance.approval_receipt_ref)
             )

    assert {:ok, evaluated} = Store.fetch_candidate(store, approved.parent_ref)

    evaluated_governance = %{
      evaluated.governance
      | gate_receipt_refs:
          List.delete(gate_receipt_refs, approved.governance.approval_receipt_ref),
        report: report,
        report_digest: report.digest
    }

    forged_evaluated =
      evaluated
      |> Map.from_struct()
      |> Map.put(:governance, evaluated_governance)
      |> Map.put(:created_at, evaluated.created_at + 1)
      |> Candidate.new!()

    assert {:ok, forged_evaluated_ref} = Store.publish_candidate(store, forged_evaluated)

    original_evaluated_ref = to_string(approved.parent_ref)

    governance = %{
      approved.governance
      | gate_receipt_refs: gate_receipt_refs,
        report: report,
        report_digest: report.digest,
        lineage_refs:
          approved.governance.lineage_refs
          |> List.delete(original_evaluated_ref)
          |> Kernel.++([to_string(forged_evaluated_ref)])
          |> Enum.sort()
    }

    forged =
      approved
      |> Map.from_struct()
      |> Map.put(:parent_ref, forged_evaluated_ref)
      |> Map.put(:governance, governance)
      |> Map.put(:created_at, approved.created_at + 1)
      |> Candidate.new!()

    assert {:ok, forged_ref} = Store.publish_candidate(store, forged)

    assert {:error, {:gate_receipt_failed, :semantic_live}} =
             Spectre.activate(instance, forged_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )
  end

  test "activation rejects a content-addressed but forged approval receipt" do
    %{store: store, instance: instance, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)
    assert {:ok, approved} = Store.fetch_candidate(store, approved_ref, now: 7)
    governance = approved.governance

    forged_approval =
      Receipt.new!(%{
        gate_class: :approval,
        candidate_digest: governance.proposal_digest,
        parent_definition_ref: governance.parent_definition_ref,
        candidate_definition_ref: governance.candidate_definition_ref,
        closure_digest: governance.closure_digest,
        checker_id: "spectre.approval.human",
        checker_version: 1,
        evaluation_cases_digest: governance.evaluation_cases_digest,
        profile_ref: nil,
        issued_at: 6,
        expires_at: nil,
        status: :passed,
        result_digest: Value.digest!(%{forged: true}),
        provenance: %{
          source: :host_approval,
          mode: :human,
          actor_ref: "operator:attacker",
          risk: governance.risk
        }
      })

    assert {:ok, forged_receipt_ref} = Store.publish_gate_receipt(store, forged_approval)
    forged_receipt_ref = to_string(forged_receipt_ref)

    governance = %{
      governance
      | gate_receipt_refs:
          governance.gate_receipt_refs
          |> List.delete(governance.approval_receipt_ref)
          |> Kernel.++([forged_receipt_ref])
          |> Enum.sort(),
        approval_receipt_ref: forged_receipt_ref
    }

    forged =
      approved
      |> Map.from_struct()
      |> Map.put(:governance, governance)
      |> Map.put(:created_at, approved.created_at + 1)
      |> Candidate.new!()

    assert {:ok, forged_ref} = Store.publish_candidate(store, forged)

    assert {:error, :approval_receipt_result_mismatch} =
             Spectre.activate(instance, forged_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )
  end

  test "review binds the delta to the protected corpus sealed in the closure" do
    %{store: store, activation: activation} = baseline()

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set(activation, [mount_operation()]),
               activation: activation,
               created_at: 2
             )

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    partial =
      EvaluationDelta.new!(
        [%{case_id: "different-protected-case", passed: true}],
        [%{case_id: "different-protected-case", passed: true}]
      )

    assert {:error, {:evaluation_delta_protected_corpus_mismatch, expected, actual}} =
             Review.evaluate(store, composed_ref, partial, [])

    assert expected == governance.protected_cases_digest
    assert actual == partial.protected_cases_digest
  end

  test "ChangeSet and gate receipt identities survive canonical transport" do
    %{activation: activation} = baseline()
    change_set = change_set(activation, [mount_operation()])

    assert {:ok, decoded} = change_set |> ChangeSet.encode() |> elem(1) |> ChangeSet.decode()
    assert decoded == change_set
    assert ChangeSet.digest(decoded) == ChangeSet.digest(change_set)

    governance = governance_fixture(change_set)
    receipt = receipt(governance, :replay, 3, profile_ref: "recording:test")

    assert {:ok, decoded_receipt} = receipt |> Receipt.encode() |> elem(1) |> Receipt.decode()
    assert decoded_receipt == receipt
    assert Receipt.ref(decoded_receipt) == Receipt.ref(receipt)

    json_change_set = change_set |> ChangeSet.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^change_set} = ChangeSet.from_data(json_change_set)

    json_receipt = receipt |> Receipt.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^receipt} = Receipt.new(json_receipt)

    json_governance =
      governance |> CandidateState.to_data() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, ^governance} = CandidateState.new(json_governance)
    assert CandidateState.proposal_digest(json_governance) == governance.proposal_digest
  end

  test "Candidate parent verification is linear instead of recursively rewalking ancestry" do
    server =
      start_supervised!({Memory, id: {:counted_governance, System.unique_integer([:positive])}})

    store = {CountingStore, server: server, observer: self()}
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.new!(operations: ["lookup"]), closure())

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, base_ref} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, base} = Store.fetch_candidate(store, base_ref)

    {last_ref, _last} =
      Enum.reduce(2..8, {base_ref, base}, fn created_at, {parent_ref, parent} ->
        child =
          parent
          |> Map.from_struct()
          |> Map.put(:parent_ref, parent_ref)
          |> Map.put(:created_at, created_at)
          |> Candidate.new!()

        assert {:ok, child_ref} = Store.publish_candidate(store, child)
        {child_ref, child}
      end)

    drain_store_gets()
    assert {:ok, _candidate} = Store.fetch_candidate(store, last_ref)

    candidate_gets =
      collect_store_gets()
      |> Enum.filter(&String.starts_with?(&1, "candidate/"))

    assert length(candidate_gets) == 2
  end

  test "administered GC retains every live Activation reference" do
    %{store: store, activation: activation, candidate: candidate} = baseline()

    assert {:ok, plan} =
             GC.plan(store, [candidate],
               activation: activation,
               definition_refs: [activation.definition_ref],
               gc_eligible_candidate_refs: [candidate],
               gc_eligible_definition_refs: [activation.definition_ref],
               inventory_complete?: true
             )

    assert :ok = GCPlan.verify(plan)

    assert [%{"decision" => "retained", "reasons" => candidate_reasons}] =
             plan.candidate_decisions

    assert "live_reference" in candidate_reasons

    assert [%{"decision" => "retained", "reasons" => definition_reasons}] =
             plan.definition_decisions

    assert "live_reference" in definition_reasons

    plan_data = plan |> GCPlan.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^plan} = GCPlan.from_data(plan_data)
    assert {:ok, ^plan} = plan |> GCPlan.encode() |> elem(1) |> GCPlan.decode()
  end

  test "the complete built-in vocabulary remains declarative and bounded" do
    canonical = Definition.canonical!(Agent)
    registry = Registry.default()
    authority = Envelope.new!(operations: ["lookup"], limits: %{max_tokens: 512})

    context = %{
      authority: authority,
      prompt_token_ceiling: 256,
      mutable_config_paths: %{"lookup" => ["feature.enabled"]},
      applicability_ceilings: %{
        "lookup" => %{
          scopes: ["support"],
          required_tags: [],
          forbidden_tags: [],
          conflicts: []
        }
      },
      registered_migrations: ["lookup-v2"]
    }

    operations = [
      mount_operation(),
      %{
        type: :update_skill_config,
        payload: %{
          mount_id: :lookup,
          changes: %{"feature.enabled" => true}
        }
      },
      %{
        "type" => "update_applicability",
        "payload" => %{
          "mount_id" => "lookup",
          "applicability" => %{
            "scopes" => ["support"],
            "required_tags" => ["verified"],
            "positive" => ["lookup"],
            "negative" => ["delete everything"]
          }
        }
      },
      put_in(mount_operation(), ["type"], "replace_skill"),
      %{
        "type" => "add_eval_case",
        "payload" => %{
          "case" => %{
            "id" => "candidate-lookup",
            "input" => "lookup",
            "expected_route" => "LOOKUP",
            "llm" => "forbidden"
          }
        }
      },
      %{
        "type" => "replace_eval_case",
        "payload" => %{
          "case" => %{
            "id" => "candidate-lookup",
            "input" => "lookup again",
            "expected_route" => "LOOKUP",
            "llm" => "forbidden"
          }
        }
      },
      %{
        "type" => "select_state_migration",
        "payload" => %{"skill_id" => "lookup", "migration_ref" => "lookup-v2"}
      },
      %{"type" => "disable_skill", "payload" => %{"mount_id" => "lookup"}}
    ]

    assert {:ok, operations} = normalize_operations(operations)

    assert {:ok, composition} =
             Registry.apply(registry, operations, Composition.new(canonical), context)

    assert composition.risk == :high
    assert composition.eval_cases |> Enum.map(& &1["id"]) == ["candidate-lookup"]

    assert composition.state_migrations == [
             %{"skill_id" => "lookup", "migration_ref" => "lookup-v2"}
           ]

    assert composition.operation_types == [
             "mount_skill",
             "update_skill_config",
             "update_applicability",
             "replace_skill",
             "add_eval_case",
             "replace_eval_case",
             "select_state_migration",
             "disable_skill"
           ]

    assert {:ok, %{payload: payload}} = Canonical.fetch_component(composition.definition, :skills)
    assert Map.get(payload, :mounts, Map.get(payload, "mounts")) == []
  end

  test "operation input rejects ambiguity, executable references and excessive depth" do
    assert {:error, {:ambiguous_governance_operation_fields, [:type]}} =
             Operation.new(%{
               :type => :mount_skill,
               "type" => "disable_skill",
               :payload => %{}
             })

    assert {:error,
            {:invalid_governance_operation_payload, {:duplicate_governance_data_key, "mode"}}} =
             Operation.new(
               type: :mount_skill,
               payload: %{:mode => :safe, "mode" => "unsafe"}
             )

    assert {:error,
            {:invalid_governance_operation_payload,
             {:governance_data_code_reference, ["handler"]}}} =
             Operation.new(type: :mount_skill, payload: %{handler: Enum})

    assert {:error,
            {:invalid_governance_operation_payload,
             {:governance_data_code_reference, ["handler"]}}} =
             Operation.new(
               type: :mount_skill,
               payload: %{handler: %{"$spectre_type" => "code_ref"}}
             )

    too_deep = Enum.reduce(1..66, %{}, fn _index, nested -> %{"next" => nested} end)

    assert {:error,
            {:invalid_governance_operation_payload, {:governance_data_depth_exceeded, _path, 64}}} =
             Operation.new(type: :mount_skill, payload: too_deep)
  end

  test "authority comparison treats a removed ceiling as an expansion" do
    parent = Envelope.new!(operations: ["lookup"], limits: %{max_tokens: 100, max_cost: 5})
    narrower = Envelope.new!(operations: ["lookup"], limits: %{max_tokens: 50, max_cost: 5})

    added_limit =
      Envelope.new!(
        operations: ["lookup"],
        limits: %{max_tokens: 100, max_cost: 5, max_risk: :low}
      )

    removed = Envelope.new!(operations: ["lookup"], limits: %{max_cost: 5})
    wider = Envelope.new!(operations: ["lookup"], limits: %{max_tokens: 101, max_cost: 5})

    assert :ok = GovernanceAuthority.no_expansion(parent, narrower)
    assert :ok = GovernanceAuthority.no_expansion(parent, added_limit)

    assert {:error, {:candidate_authority_limit_removed, :max_tokens, 100}} =
             GovernanceAuthority.no_expansion(parent, removed)

    assert {:error, {:candidate_authority_limit_expansion, :max_tokens, 101}} =
             GovernanceAuthority.no_expansion(parent, wider)
  end

  test "checker versions are mandatory and approval policies reject duplicate aliases" do
    %{activation: activation} = baseline()
    governance = activation |> change_set([mount_operation()]) |> governance_fixture()
    receipt = receipt(governance, :replay, 3, profile_ref: "recording:test")

    assert {:error, {:untrusted_gate_checker, :replay, "test.replay"}} =
             Receipt.verify(receipt, governance, now: 4)

    assert :ok =
             Receipt.verify(receipt, governance,
               now: 4,
               checker_versions: %{replay: {"test.replay", 1}}
             )

    assert {:error, {:duplicate_governance_approval_risk, :low}} =
             ApprovalPolicy.new(
               low: :automatic,
               low: :human,
               medium: :human,
               high: :human,
               critical: :human
             )

    assert {:ok, policy} =
             ApprovalPolicy.new(%{
               "low" => "automatic",
               "medium" => "human",
               "high" => "human",
               "critical" => "human"
             })

    assert ApprovalPolicy.allows?(policy, :low, :human)
    refute ApprovalPolicy.allows?(policy, :high, :automatic)

    default_policy = ApprovalPolicy.default()
    assert {:ok, ^default_policy} = ApprovalPolicy.new(default_policy)

    assert {:error, {:invalid_governance_approval_policy, :invalid}} =
             ApprovalPolicy.new(:invalid)

    assert {:error, {:invalid_governance_approval_policy, :invalid_list}} =
             ApprovalPolicy.new([:invalid])

    assert {:error, :incomplete_governance_approval_policy} = ApprovalPolicy.new(%{low: :human})

    assert {:error, {:unknown_governance_risk, :unknown}} =
             ApprovalPolicy.required_mode(default_policy, :unknown)

    refute ApprovalPolicy.allows?(default_policy, :unknown, :human)
    refute ApprovalPolicy.allows?(default_policy, :low, :invalid)

    assert {:error, {:invalid_governance_approval_field, :risk, "unknown"}} =
             ApprovalPolicy.new(%{"unknown" => "human"})

    assert {:error, {:invalid_governance_approval_field, :mode, "unknown"}} =
             ApprovalPolicy.new(%{"low" => "unknown"})
  end

  test "candidate-owned evaluation data cannot exploit atom/string aliases" do
    assert {:error, {:invalid_evaluation_case_result, :parent, 0, reason}} =
             EvaluationDelta.new(
               [%{:case_id => "protected", "case_id" => "different", :passed => true}],
               [%{case_id: "protected", passed: true}]
             )

    assert match?({:invalid_evaluation_result_fields, _fields}, reason)

    assert {:error, {:evaluation_delta_case_mismatch, ["protected"], ["new", "protected"]}} =
             EvaluationDelta.new(
               [%{case_id: "protected", passed: true}],
               [
                 %{case_id: "protected", passed: true},
                 %{case_id: "new", passed: true}
               ],
               candidate_case_ids: []
             )
  end

  test "registry contains handler failures and rejects unregistered operations" do
    canonical = Definition.canonical!(Agent)
    composition = Composition.new(canonical)

    assert {:ok, registry} =
             Registry.new([
               SpectreGovernanceGateTest.InvalidResultHandler,
               SpectreGovernanceGateTest.CrashingHandler
             ])

    assert {:ok, invalid_result} = Operation.new(%{type: "invalid_result", payload: %{}})

    assert {:error, {:invalid_governance_handler_result, 0, :other}} =
             Registry.apply(registry, [invalid_result], composition, %{})

    assert {:ok, crashing} = Operation.new(%{type: "crashing", payload: %{}})

    assert {:error,
            {:governance_operation_failed, 0,
             {:governance_handler_exception, SpectreGovernanceGateTest.CrashingHandler,
              RuntimeError}}} = Registry.apply(registry, [crashing], composition, %{})

    assert {:ok, unknown} = Operation.new(%{type: "unknown", payload: %{}})

    assert {:error,
            {:governance_operation_failed, 0, {:unregistered_governance_operation, "unknown"}}} =
             Registry.apply(registry, [unknown], composition, %{})
  end

  test "review rejects receipts from checkers absent from host policy" do
    %{store: store, activation: activation} = baseline()

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set(activation, [mount_operation()]),
               activation: activation,
               created_at: 2
             )

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    receipts = [
      receipt(governance, :replay, 3, profile_ref: "recording:test"),
      receipt(governance, :regression, 3)
    ]

    assert {:error, {:untrusted_gate_checker, gate, _checker}} =
             Review.evaluate(store, composed_ref, delta, receipts, reviewed_at: 4, now: 5)

    assert gate in [:replay, :regression]
  end

  test "a previously approved Candidate becomes stale after activation" do
    %{store: store, instance: instance, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)

    assert {:ok, active} =
             Spectre.activate(instance, approved_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert {:error, :stale_governance_activation_receipt} =
             Spectre.activate(instance, approved_ref,
               expected_generation: active.generation,
               now: 8,
               checker_versions: @checker_versions
             )
  end

  test "a governed activation is fully reverified during checkpoint recovery" do
    context = durable_baseline()

    approved_ref =
      approved_candidate(context.store, context.activation, "lookup",
        checkpoint_store: context.checkpoint_store
      )

    assert {:ok, activated} =
             Spectre.activate(context.instance, approved_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert activated.generation == 2
    assert :ok = stop_supervised(context.instance_id)

    {restarted, _restarted_id} =
      start_governance_instance(context.subject, context.store, context.checkpoint_store)

    assert %Instance.Activation{candidate_ref: ^approved_ref, generation: 2} =
             Spectre.activation(restarted)
  end

  test "checkpoint failure after durable publication leaves a safe orphan Candidate" do
    context = durable_baseline()

    approved_ref =
      approved_candidate(context.store, context.activation, "lookup",
        checkpoint_store: context.checkpoint_store
      )

    CheckpointStore.fail_next(context.checkpoint_server)

    assert {:error, :injected_checkpoint_failure} =
             Spectre.activate(context.instance, approved_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert Spectre.activation(context.instance) == context.activation

    assert {:ok, %Candidate{governance: %{state: :approved}}} =
             Store.fetch_candidate(context.store, approved_ref,
               checkpoint_store: context.checkpoint_store
             )

    assert :ok = stop_supervised(context.instance_id)

    {restarted, _restarted_id} =
      start_governance_instance(context.subject, context.store, context.checkpoint_store)

    assert Spectre.activation(restarted) == context.activation
  end

  test "activation revalidates promotion lineage and ChangeSet provenance" do
    %{store: store, instance: instance, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)

    assert {:ok, approved} = Store.fetch_candidate(store, approved_ref, now: 7)
    assert {:ok, evaluated} = Store.fetch_candidate(store, approved.parent_ref, now: 7)

    skipped =
      approved
      |> Map.from_struct()
      |> Map.put(:parent_ref, evaluated.parent_ref)
      |> Map.put(:created_at, approved.created_at + 1)
      |> Candidate.new!()

    assert {:ok, skipped_ref} = Store.publish_candidate(store, skipped, now: 7)

    assert {:error, {:governance_candidate_parent_missing, :composed}} =
             Spectre.activate(instance, skipped_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    unbound =
      approved
      |> Map.from_struct()
      |> Map.put(:provenance_refs, ["changeset:sha256:" <> @digest])
      |> Map.put(:created_at, approved.created_at + 2)
      |> Candidate.new!()

    assert {:ok, unbound_ref} = Store.publish_candidate(store, unbound, now: 7)

    assert {:error, :governed_candidate_change_set_provenance_mismatch} =
             Spectre.activate(instance, unbound_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )
  end

  test "complete administered GC can mark an unreferenced branch eligible" do
    %{store: store, candidate: candidate, activation: activation} = baseline()

    assert {:ok, plan} =
             GC.plan(store, [candidate],
               definition_refs: [activation.definition_ref],
               gc_eligible_candidate_refs: [candidate],
               gc_eligible_definition_refs: [activation.definition_ref],
               inventory_complete?: true
             )

    assert [%{"decision" => "eligible"}] =
             Enum.map(plan.candidate_decisions, &Map.take(&1, ["decision"]))

    assert [%{"decision" => "eligible"}] =
             Enum.map(plan.definition_decisions, &Map.take(&1, ["decision"]))
  end

  test "human reports quote every canonical type and distinguish add from removal" do
    parent =
      Agent
      |> Definition.canonical!()
      |> replace_metadata(%{
        :atom_key => :old_atom,
        "description" => "old text",
        "bytes" => <<255, 0>>,
        "list" => [1, 2],
        "removed" => %{"nested" => true},
        "tuple" => {:old, 1}
      })

    candidate =
      Agent
      |> Definition.canonical!()
      |> replace_metadata(%{
        :atom_key => :new_atom,
        "added" => %{"nested" => true},
        "bytes" => <<254, 0>>,
        "description" => "new text",
        "list" => [1],
        "tuple" => {:new, 2}
      })

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    assert HumanReport.id() == "spectre.projection.human-report"
    assert HumanReport.version() == 1

    assert {:ok, report} = HumanReport.project(parent, candidate, evaluation_delta: delta)
    assert :ok = HumanReport.verify(report)

    kinds = report.structural_changes |> Enum.map(& &1["change"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(["added", "removed", "changed"]), kinds)
    assert Enum.any?(report.textual_changes, &(&1["before"] == "old text"))
    assert {:ok, _json} = report |> HumanReport.to_data() |> Jason.encode()

    assert Enum.any?(report.structural_changes, fn change ->
             match?(%{"$spectre_value" => "bytes"}, Map.get(change, "before"))
           end)

    assert Enum.any?(report.structural_changes, fn change ->
             match?(%{"$spectre_value" => "tuple"}, Map.get(change, "before"))
           end)

    assert {:ok, reverse} = HumanReport.project(candidate, parent, evaluation_delta: delta)
    assert Enum.any?(reverse.structural_changes, &(&1["change"] == "added"))

    tampered = %{report | digest: String.duplicate("0", 64)}
    assert {:error, {:human_report_digest_mismatch, _, _}} = HumanReport.verify(tampered)

    inconsistent =
      report
      |> HumanReport.to_data()
      |> Map.put("textual_changes", [])
      |> then(fn data -> Map.put(data, "digest", Value.digest!(Map.delete(data, "digest"))) end)

    assert {:error, :human_report_textual_diff_mismatch} =
             HumanReport.from_data(inconsistent)

    assert {:error, {:invalid_human_report, _reason}} =
             HumanReport.verify(%{report | evaluation_delta: %{pid: self()}})

    assert {:error, :human_report_requires_evaluation_delta} =
             HumanReport.project(parent, candidate)

    assert {:error, {:invalid_human_report_definitions, :other, :map}} =
             HumanReport.project(:invalid, %{})

    assert {:error, {:invalid_human_report_data, :list}} = HumanReport.from_data([])
    assert {:error, {:invalid_human_report_binary, :map}} = HumanReport.decode(%{})
  end

  test "gate receipts fail closed across binding, time and checker policy" do
    %{activation: activation} = baseline()
    governance = activation |> change_set([mount_operation()]) |> governance_fixture()
    replay = receipt(governance, :replay, 3, profile_ref: "recording:test")
    policy = %{replay: {"test.replay", 1}}

    failed = %{replay | status: :failed}

    assert {:error, {:gate_receipt_failed, :replay}} =
             Receipt.verify(failed, governance, now: 4, checker_versions: policy)

    assert {:error, {:gate_receipt_not_yet_valid, :replay}} =
             Receipt.verify(replay, governance, now: 2, checker_versions: policy)

    expiring = Receipt.new!(%{Receipt.to_data(replay) | "expires_at" => 4})

    assert {:error, {:gate_receipt_expired, :replay}} =
             Receipt.verify(expiring, governance, now: 4, checker_versions: policy)

    assert {:error, {:invalid_gate_verification_time, -1}} =
             Receipt.verify(replay, governance, now: -1, checker_versions: policy)

    assert {:error, :gate_receipt_candidate_mismatch} =
             Receipt.verify_binding(%{replay | candidate_digest: @digest}, governance)

    assert {:error, :gate_receipt_parent_mismatch} =
             Receipt.verify_binding(
               %{replay | parent_definition_ref: "sha256:" <> String.duplicate("c", 64)},
               governance
             )

    assert {:error, :gate_receipt_definition_mismatch} =
             Receipt.verify_binding(
               %{replay | candidate_definition_ref: "sha256:" <> String.duplicate("c", 64)},
               governance
             )

    assert {:error, :gate_receipt_closure_mismatch} =
             Receipt.verify_binding(
               %{replay | closure_digest: String.duplicate("c", 64)},
               governance
             )

    assert {:error, :gate_receipt_evaluation_cases_mismatch} =
             Receipt.verify_binding(
               %{replay | evaluation_cases_digest: String.duplicate("c", 64)},
               governance
             )

    assert :ok =
             Receipt.verify(replay, governance,
               now: 4,
               checker_versions: %{"replay" => %{"id" => "test.replay", "version" => 1}}
             )

    assert {:error, {:gate_checker_mismatch, :replay}} =
             Receipt.verify(replay, governance,
               now: 4,
               checker_versions: %{replay: {"wrong", 1}}
             )

    assert {:error, {:invalid_gate_checker_policy, []}} =
             Receipt.verify(replay, governance, now: 4, checker_versions: [])

    assert {:error, {:gate_receipt_profile_required, :replay}} =
             replay |> Receipt.to_data() |> Map.put("profile_ref", nil) |> Receipt.new()

    semantic =
      replay
      |> Receipt.to_data()
      |> Map.put("gate_class", "semantic_live")
      |> Map.put("checker_id", "test.semantic_live")

    assert {:error, :semantic_live_receipt_expiry_required} = Receipt.new(semantic)

    assert {:error, :semantic_live_receipt_variability_required} =
             semantic |> Map.put("expires_at", 10) |> Receipt.new()

    assert {:ok, live} =
             semantic
             |> Map.put("expires_at", 10)
             |> Map.put("provenance", %{
               "source" => "test_checker",
               "variability" => %{
                 "sample_count" => 3,
                 "measure_digest" => Value.digest!(%{scores: [0.2, 0.4, 0.8]})
               }
             })
             |> Receipt.new()

    assert {:error, {:gate_receipt_expired, :semantic_live}} =
             Receipt.verify(live, governance,
               now: 10,
               checker_versions: %{semantic_live: {"test.semantic_live", 1}}
             )

    assert {:error, {:invalid_gate_receipt_window, 3, 3}} =
             replay |> Receipt.to_data() |> Map.put("expires_at", 3) |> Receipt.new()

    assert {:error, {:ambiguous_gate_receipt_fields, [:status]}} =
             replay |> Receipt.to_data() |> Map.put(:status, :failed) |> Receipt.new()

    assert {:error, {:unknown_gate_receipt_fields, ["unknown"]}} =
             replay |> Receipt.to_data() |> Map.put("unknown", true) |> Receipt.new()

    assert {:error, {:invalid_gate_receipt_binary, :tuple}} = Receipt.decode({:bad})
  end

  test "gate receipt constructors reject every malformed portable field" do
    %{activation: activation} = baseline()
    governance = activation |> change_set([mount_operation()]) |> governance_fixture()
    replay = receipt(governance, :replay, 3, profile_ref: "recording:test")
    data = Receipt.to_data(replay)

    assert {:ok, ^replay} = replay |> Map.from_struct() |> Map.to_list() |> Receipt.new()

    assert {:error, {:invalid_gate_receipt_struct, ArgumentError}} =
             replay |> Map.put(:status, "passed") |> Receipt.new()

    assert_raise ArgumentError, fn -> Receipt.new!(%{}) end

    Enum.each([:invalid, "invalid", {:invalid}], fn value ->
      assert {:error, {:invalid_gate_receipt, _shape}} = Receipt.new(value)
    end)

    invalid_fields = [
      {"schema_version", 2},
      {"gate_class", "unknown"},
      {"candidate_digest", String.duplicate("z", 64)},
      {"parent_definition_ref", 42},
      {"candidate_definition_ref", "invalid"},
      {"checker_id", ""},
      {"checker_version", 0},
      {"profile_ref", ""},
      {"issued_at", -1},
      {"expires_at", -1},
      {"status", "unknown"},
      {"result_digest", "short"},
      {"provenance", []},
      {"provenance", %{"handler" => Enum}}
    ]

    Enum.each(invalid_fields, fn {field, value} ->
      assert {:error, _reason} = data |> Map.put(field, value) |> Receipt.new()
    end)

    assert {:error, {:invalid_gate_receipt_digest, _value}} =
             data
             |> Map.put("candidate_digest", String.upcase(data["candidate_digest"]))
             |> Receipt.new()

    assert :ok =
             Receipt.verify(replay, governance,
               now: 4,
               checker_versions: %{replay: %{id: "test.replay", version: 1}}
             )
  end

  test "evaluation delta reconstruction rejects noncanonical evidence" do
    assert {:error, :evaluation_delta_protected_corpus_required} =
             EvaluationDelta.new([], [], min_score_delta: 0)

    assert_raise ArgumentError, fn -> EvaluationDelta.new!([%{}], []) end

    assert {:error, {:invalid_evaluation_delta_input, :other, :list}} =
             EvaluationDelta.new(:invalid, [])

    assert {:error, {:invalid_evaluation_delta_field, :candidate_case_ids, :invalid}} =
             EvaluationDelta.new([], [], candidate_case_ids: :invalid)

    assert {:error, :invalid_evaluation_delta_case_ids} =
             EvaluationDelta.new([], [], candidate_case_ids: ["duplicate", "duplicate"])

    assert {:error, :invalid_evaluation_delta_threshold} =
             EvaluationDelta.new([], [], max_regressions: -1)

    assert {:error, :invalid_evaluation_delta_threshold} =
             EvaluationDelta.new(
               [%{case_id: "protected", passed: true}],
               [%{case_id: "protected", passed: false}],
               max_regressions: 1
             )

    assert {:error, :invalid_evaluation_delta_threshold} =
             EvaluationDelta.new(
               [%{case_id: "protected", passed: true}],
               [%{case_id: "protected", passed: false}],
               min_score_delta: -1.0
             )

    assert {:error, :invalid_evaluation_delta_threshold} =
             EvaluationDelta.new([], [], min_score_delta: 1.0e308)

    assert {:error, :evaluation_delta_protected_corpus_required} =
             EvaluationDelta.new(
               [],
               [%{case_id: "candidate-owned", passed: true}],
               candidate_case_ids: ["candidate-owned"]
             )

    assert {:error, {:invalid_evaluation_case_result, :parent, 0, _reason}} =
             EvaluationDelta.new([:invalid], [])

    assert {:ok, failed_owned} =
             EvaluationDelta.new(
               [%{case_id: "protected", passed: true}],
               [
                 %{case_id: "protected", passed: true},
                 %{case_id: "owned", passed: false}
               ],
               candidate_case_ids: ["owned"]
             )

    assert failed_owned.candidate_case_failures == ["owned"]
    refute failed_owned.passed

    valid =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    data = EvaluationDelta.to_data(valid)

    assert {:error, {:invalid_evaluation_delta_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> EvaluationDelta.from_data()

    assert {:error, {:invalid_evaluation_delta_fields, ["passed"]}} =
             data |> Map.delete("passed") |> EvaluationDelta.from_data()

    assert {:error, {:unsupported_evaluation_delta_schema, 2}} =
             data |> Map.put("schema_version", 2) |> EvaluationDelta.from_data()

    assert {:error, :invalid_evaluation_delta_data} =
             data |> Map.put("schema_version", "1") |> EvaluationDelta.from_data()

    assert {:error, :invalid_evaluation_delta_protected_results} =
             data |> Map.put("protected_results", [42]) |> EvaluationDelta.from_data()

    pair = hd(data["protected_results"])
    mismatched = put_in(pair, ["candidate", "case_id"], "different")

    assert {:error, :invalid_evaluation_delta_protected_results} =
             data |> Map.put("protected_results", [mismatched]) |> EvaluationDelta.from_data()

    assert {:error, :invalid_evaluation_delta_candidate_results} =
             data |> Map.put("candidate_owned_results", [42]) |> EvaluationDelta.from_data()

    Enum.each([[], {}, :invalid], fn value ->
      assert {:error, {:invalid_evaluation_delta_data, _shape}} =
               EvaluationDelta.from_data(value)
    end)
  end

  test "ChangeSet and Candidate state constructors reject stale or ambiguous evidence" do
    %{store: store, activation: activation, candidate: candidate_ref} = baseline()
    change_set = change_set(activation, [mount_operation()])

    assert {:ok, bootstrap} = Store.fetch_candidate(store, candidate_ref)

    assert {:error, :governed_candidate_requires_governance_state} =
             bootstrap
             |> Map.from_struct()
             |> Map.put(:source, :governed_host)
             |> Candidate.new()

    assert ChangeSet.schema_version() == 1
    assert {:ok, ^change_set} = ChangeSet.new(change_set)

    assert {:error, :governance_change_set_requires_activation} =
             ChangeSet.verify_base(change_set, nil)

    assert {:error, :stale_governance_activation_receipt} =
             ChangeSet.verify_base(change_set, %{activation | activation_receipt: "other"})

    assert {:error, :stale_governance_candidate_ref} =
             ChangeSet.verify_base(change_set, %{activation | candidate_ref: candidate_ref("c")})

    assert {:error, :stale_governance_definition_ref} =
             ChangeSet.verify_base(change_set, %{activation | definition_ref: definition_ref("c")})

    assert {:error, :stale_governance_evidence_digest} =
             ChangeSet.verify_base(change_set, %{
               activation
               | activated_at: activation.activated_at + 1
             })

    assert {:error, {:ambiguous_governance_change_set_fields, [:reason]}} =
             change_set |> ChangeSet.to_data() |> Map.put(:reason, "other") |> ChangeSet.new()

    assert {:error, {:unknown_governance_change_set_fields, ["unknown"]}} =
             change_set |> ChangeSet.to_data() |> Map.put("unknown", true) |> ChangeSet.new()

    assert {:error, {:invalid_governance_change_set, :list}} =
             ChangeSet.new(reason: "one", reason: "two")

    assert {:error, {:invalid_governance_change_set_binary, :tuple}} =
             ChangeSet.decode({:bad})

    governance = governance_fixture(change_set)

    assert {:error, {:candidate_governance_requires_governed_source, :trusted_host}} =
             bootstrap
             |> Map.from_struct()
             |> Map.put(:source, :trusted_host)
             |> Map.put(:governance, governance)
             |> Candidate.new()

    assert CandidateState.schema_version() == 1
    assert :replay in CandidateState.gate_classes()
    assert {:ok, ^governance} = CandidateState.new(governance)

    assert {:error, {:invalid_governance_candidate_transition, :composed, :approved}} =
             CandidateState.transition(governance, :approved)

    assert {:ok, ^governance} = CandidateState.transition(governance, :composed)

    assert {:error, {:governance_candidate_proposal_digest_mismatch, _, _}} =
             governance
             |> CandidateState.to_data()
             |> Map.put("proposal_digest", String.duplicate("0", 64))
             |> CandidateState.new()

    assert {:error, {:ambiguous_governance_candidate_fields, [:risk]}} =
             governance
             |> CandidateState.to_data()
             |> Map.put(:risk, :high)
             |> CandidateState.new()

    assert {:error, {:invalid_governance_candidate_state, :list}} =
             CandidateState.new(risk: :low, risk: :high)
  end

  test "Candidate transport rejects ambiguous and out-of-schema data" do
    %{store: store, candidate: candidate_ref} = baseline()
    assert {:ok, candidate} = Store.fetch_candidate(store, candidate_ref)
    attrs = Map.from_struct(candidate)
    data = Candidate.to_data(candidate)

    assert Candidate.schema_version() == 1
    assert {:ok, ^candidate} = Candidate.new(candidate)
    assert {:ok, ^candidate} = attrs |> Map.to_list() |> Candidate.new()

    assert {:error, {:invalid_definition_candidate, :list}} = Candidate.new([:invalid])

    assert {:error, {:invalid_definition_candidate, :list}} =
             Candidate.new(definition_ref: candidate.definition_ref, definition_ref: :duplicate)

    assert_raise ArgumentError, fn -> Candidate.new!(%{}) end
    assert {:error, {:invalid_candidate_resolution, :atom}} = Candidate.from_resolution(:invalid)

    assert {:error, {:unknown_definition_candidate_data_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> Candidate.from_data()

    assert {:ok, %Candidate{source: :trusted_host}} =
             data |> Map.put("source", "trusted_host") |> Candidate.from_data()

    assert {:error, {:invalid_candidate_source, "unknown"}} =
             data |> Map.put("source", "unknown") |> Candidate.from_data()

    assert {:error, {:invalid_candidate_parent_ref, 42}} =
             data |> Map.put("parent_ref", 42) |> Candidate.from_data()

    Enum.each([%{}, [], {}, :invalid, 42, 1.5], fn value ->
      assert {:error, {:invalid_definition_candidate_data, _shape}} = Candidate.from_data(value)
    end)

    assert {:error, {:invalid_definition_candidate_binary, :tuple}} = Candidate.decode({:bad})

    invalid_attrs = [
      {:schema_version, 2},
      {:definition_ref, 42},
      {:manifest_digest, String.duplicate("z", 64)},
      {:manifest_digest, "short"},
      {:publication_id, ""},
      {:source, :external},
      {:parent_ref, 42},
      {:provenance_refs, :invalid},
      {:governance, :invalid},
      {:created_at, -1}
    ]

    Enum.each(invalid_attrs, fn {field, value} ->
      assert {:error, _reason} = attrs |> Map.put(field, value) |> Candidate.new()
    end)

    assert {:error, {:unknown_definition_candidate_fields, [:unknown]}} =
             attrs |> Map.put(:unknown, true) |> Candidate.new()
  end

  test "Candidate governance load validation is canonical and bounded" do
    %{activation: activation} = baseline()
    governance = activation |> change_set([mount_operation()]) |> governance_fixture()
    base = governance |> CandidateState.to_data() |> Map.delete("proposal_digest")

    evaluation_case = %{
      "id" => "candidate-owned",
      "input" => "lookup",
      "expected_route" => "LOOKUP",
      "expected_strategy" => nil,
      "expected_outcome" => "route",
      "allowed_routes" => [],
      "llm" => "forbidden",
      "state" => %{},
      "tags" => ["governed"],
      "max_duration_us" => 1_000
    }

    assert {:ok, with_case} =
             base
             |> Map.put("candidate_cases", [evaluation_case])
             |> Map.put("candidate_case_ids", ["candidate-owned"])
             |> CandidateState.new()

    assert CandidateState.proposal_digest(with_case) == with_case.proposal_digest

    assert {:ok, with_migration} =
             base
             |> Map.put("state_migrations", [
               %{"skill_id" => "lookup", "migration_ref" => "lookup-v2"}
             ])
             |> CandidateState.new()

    assert with_migration.state_migrations != []

    assert {:ok, ^governance} =
             governance |> Map.from_struct() |> Map.to_list() |> CandidateState.new()

    assert {:error, {:invalid_governance_candidate_state_struct, ArgumentError}} =
             governance |> Map.put(:risk, "low") |> CandidateState.new()

    assert_raise ArgumentError, fn -> CandidateState.new!(%{}) end

    Enum.each([:invalid, "invalid", {:invalid}], fn value ->
      assert {:error, {:invalid_governance_candidate_state, _shape}} = CandidateState.new(value)
    end)

    invalid_fields = [
      {"schema_version", 2},
      {"change_set_digest", String.duplicate("z", 64)},
      {"base_activation_receipt", ""},
      {"base_candidate_ref", "candidate:sha256:bad"},
      {"observed_authority_epoch", -1},
      {"risk", "unknown"},
      {"required_gates", []},
      {"required_gates", "replay"},
      {"required_gates", ["unknown"]},
      {"state", "unknown"},
      {"candidate_case_ids", :invalid},
      {"candidate_cases", :invalid},
      {"state_migrations", :invalid},
      {"gate_receipt_refs", :invalid},
      {"gate_receipt_refs", ["gate:sha256:bad"]},
      {"approval_receipt_ref", 42},
      {"report_digest", "short"},
      {"lineage_refs", ["candidate:sha256:bad"]}
    ]

    Enum.each(invalid_fields, fn {field, value} ->
      assert {:error, _reason} = base |> Map.put(field, value) |> CandidateState.new()
    end)

    assert {:error, {:invalid_governance_candidate_digest, _value}} =
             base
             |> Map.put("change_set_digest", String.upcase(base["change_set_digest"]))
             |> CandidateState.new()

    assert {:error, {:noncanonical_governance_candidate_case, 0}} =
             base
             |> Map.put("candidate_cases", [%{"id" => "case", "input" => "lookup"}])
             |> Map.put("candidate_case_ids", ["case"])
             |> CandidateState.new()

    assert {:error, {:invalid_governance_candidate_case, 0, _reason}} =
             base
             |> Map.put("candidate_cases", [%{"id" => "case"}])
             |> Map.put("candidate_case_ids", ["case"])
             |> CandidateState.new()

    assert {:error, {:invalid_governance_candidate_case, 0}} =
             base
             |> Map.put("candidate_cases", [42])
             |> Map.put("candidate_case_ids", [])
             |> CandidateState.new()

    assert {:error, :invalid_governance_candidate_case_ids} =
             base
             |> Map.put("candidate_cases", [evaluation_case, evaluation_case])
             |> Map.put("candidate_case_ids", ["candidate-owned"])
             |> CandidateState.new()

    assert {:error, {:governance_candidate_case_ids_mismatch, [], ["candidate-owned"]}} =
             base
             |> Map.put("candidate_cases", [evaluation_case])
             |> Map.put("candidate_case_ids", [])
             |> CandidateState.new()

    assert {:error, :governance_state_migration_code_reference_forbidden} =
             base
             |> Map.put("state_migrations", [
               %{"skill_id" => "lookup", "migration_ref" => "Elixir.Unsafe"}
             ])
             |> CandidateState.new()

    assert {:error, {:duplicate_governance_state_migration, "lookup"}} =
             base
             |> Map.put("state_migrations", [
               %{"skill_id" => "lookup", "migration_ref" => "lookup-v1"},
               %{"skill_id" => "lookup", "migration_ref" => "lookup-v2"}
             ])
             |> CandidateState.new()

    assert {:error, {:invalid_governance_state_migration, 0}} =
             base
             |> Map.put("state_migrations", [%{"skill_id" => "lookup"}])
             |> CandidateState.new()

    too_many_receipts =
      Enum.map(0..10, fn index ->
        digest = index |> Integer.to_string(16) |> String.pad_leading(64, "0")
        "gate:sha256:" <> digest
      end)

    assert {:error, {:governance_candidate_ref_limit_exceeded, :gate_receipt_refs, 11, 10}} =
             base |> Map.put("gate_receipt_refs", too_many_receipts) |> CandidateState.new()
  end

  test "persisted review evidence cannot be detached from its Candidate" do
    %{store: store, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)

    assert {:ok, approved} = Store.fetch_candidate(store, approved_ref)

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, approved.parent_ref)

    data = governance |> CandidateState.to_data() |> Map.delete("proposal_digest")

    assert {:error, {:governance_candidate_report_required, :evaluated}} =
             data
             |> Map.put("report", nil)
             |> Map.put("report_digest", nil)
             |> CandidateState.new()

    assert {:error, :composed_governance_candidate_cannot_have_report} =
             data |> Map.put("state", "composed") |> CandidateState.new()

    assert {:error, :governance_candidate_report_digest_mismatch} =
             data
             |> Map.put("report_digest", String.duplicate("0", 64))
             |> CandidateState.new()

    assert {:error, :governance_candidate_report_definition_mismatch} =
             data
             |> Map.put("parent_definition_ref", to_string(definition_ref("e")))
             |> CandidateState.new()

    assert {:error, :governance_candidate_report_corpus_mismatch} =
             data
             |> Map.put("protected_cases_digest", String.duplicate("e", 64))
             |> CandidateState.new()

    extra_receipt = "gate:sha256:" <> String.duplicate("e", 64)

    assert {:error, :governance_candidate_report_receipts_mismatch} =
             data
             |> Map.update!("gate_receipt_refs", &[extra_receipt | &1])
             |> CandidateState.new()

    assert {:error, :governance_candidate_report_lineage_mismatch} =
             data |> Map.put("lineage_refs", []) |> CandidateState.new()

    assert {:error, {:invalid_governance_candidate_field, :report, :other}} =
             data |> Map.put("report", 42) |> CandidateState.new()
  end

  test "GC plan transport detects schema, field and digest corruption" do
    %{store: store, candidate: candidate, activation: activation} = baseline()

    assert {:ok, plan} =
             GC.plan(store, [candidate],
               activation: activation,
               definition_refs: [activation.definition_ref]
             )

    data = GCPlan.to_data(plan)

    assert {:error, {:unsupported_governance_gc_plan_schema, 99}} =
             data |> Map.put("schema_version", 99) |> GCPlan.from_data()

    assert {:error, {:invalid_governance_gc_plan_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> GCPlan.from_data()

    assert {:error, :governance_gc_plan_integrity_mismatch} =
             data |> Map.put("digest", String.duplicate("0", 64)) |> GCPlan.from_data()

    assert {:error, {:governance_gc_plan_digest_mismatch, _, _}} =
             GCPlan.verify(%{plan | digest: String.duplicate("0", 64)})

    unsafe =
      plan
      |> Map.from_struct()
      |> Map.delete(:digest)
      |> Map.update!(:candidate_decisions, fn [decision] ->
        [%{decision | "decision" => "eligible", "reasons" => []}]
      end)

    assert {:error, {:unsafe_governance_gc_decision, _ref}} = GCPlan.build(unsafe)

    assert {:error, {:invalid_governance_gc_plan, _reason}} =
             GCPlan.verify(%{plan | store_identity: self()})

    assert {:error, {:invalid_governance_gc_plan_data, :list}} = GCPlan.from_data([])
    assert {:error, {:invalid_governance_gc_plan_binary, :tuple}} = GCPlan.decode({:bad})
  end

  test "built-in handlers fail closed on every mutable boundary" do
    canonical = Definition.canonical!(Agent)
    registry = Registry.default()
    authority = Envelope.new!(operations: ["lookup"], limits: %{max_tokens: 512})

    base_context = %{
      authority: authority,
      prompt_token_ceiling: 256,
      mutable_config_paths: %{"lookup" => ["feature", "feature.enabled"]},
      applicability_ceilings: %{
        "lookup" => %{
          scopes: ["support"],
          required_tags: [],
          forbidden_tags: [],
          conflicts: []
        }
      },
      registered_migrations: ["lookup-v2", "lookup-v3"]
    }

    base = Composition.new(canonical)
    assert {:ok, mounted} = apply_operation(registry, base, mount_operation(), base_context)

    assert_operation_error(
      registry,
      mounted,
      mount_operation(),
      base_context,
      {:skill_mount_already_exists, "lookup"}
    )

    assert_operation_error(
      registry,
      base,
      put_in(mount_operation(), ["payload", "unknown"], true),
      base_context,
      {:unknown_skill_governance_fields, ["unknown"]}
    )

    assert_operation_error(
      registry,
      base,
      put_in(mount_operation(), ["payload", "mount_id"], "Elixir.System"),
      base_context,
      {:skill_governance_code_reference_forbidden, :mount_id}
    )

    assert_operation_error(
      registry,
      base,
      put_in(mount_operation(), ["payload", "bindings"], []),
      base_context,
      {:invalid_skill_governance_field, :bindings, :list}
    )

    assert_operation_error(
      registry,
      base,
      mount_operation(),
      %{base_context | authority: nil},
      :governance_authority_required
    )

    assert_operation_error(
      registry,
      base,
      %{"type" => "replace_skill", "payload" => mount_operation()["payload"]},
      base_context,
      {:skill_mount_not_found, "lookup"}
    )

    assert_operation_error(
      registry,
      base,
      %{"type" => "disable_skill", "payload" => %{"mount_id" => "lookup"}},
      base_context,
      {:skill_mount_not_found, "lookup"}
    )

    config = %{
      "type" => "update_skill_config",
      "payload" => %{
        "mount_id" => "lookup",
        "changes" => %{"feature.enabled" => true}
      }
    }

    assert_operation_error(
      registry,
      mounted,
      config,
      %{base_context | mutable_config_paths: %{}},
      {:skill_config_not_mutable, "lookup"}
    )

    assert_operation_error(
      registry,
      mounted,
      put_in(config, ["payload", "changes"], %{"forbidden" => true}),
      base_context,
      {:skill_config_path_not_mutable, "forbidden"}
    )

    assert_operation_error(
      registry,
      base,
      config,
      base_context,
      {:skill_mount_not_found, "lookup"}
    )

    root_config = put_in(config, ["payload", "changes"], %{"feature" => true})
    assert {:ok, scalar_config} = apply_operation(registry, mounted, root_config, base_context)

    assert_operation_error(
      registry,
      scalar_config,
      config,
      base_context,
      {:skill_config_path_conflict, "feature"}
    )

    applicability = %{
      "type" => "update_applicability",
      "payload" => %{
        "mount_id" => "lookup",
        "applicability" => %{
          "scopes" => ["support"],
          "positive" => ["lookup"],
          "negative" => ["delete everything"]
        }
      }
    }

    assert_operation_error(
      registry,
      mounted,
      applicability,
      %{base_context | applicability_ceilings: %{}},
      {:skill_applicability_ceiling_required, "lookup"}
    )

    assert_operation_error(
      registry,
      mounted,
      put_in(applicability, ["payload", "applicability", "scopes"], ["admin"]),
      base_context,
      :skill_applicability_ceiling_exceeded
    )

    assert_operation_error(
      registry,
      mounted,
      put_in(applicability, ["payload", "applicability", "scopes"], []),
      base_context,
      :skill_applicability_ceiling_exceeded
    )

    wildcard_mount =
      put_in(mount_operation(), ["payload", "definition", "applicability", "scopes"], [])

    assert_operation_error(
      registry,
      base,
      wildcard_mount,
      base_context,
      :skill_applicability_ceiling_exceeded
    )

    assert_operation_error(
      registry,
      mounted,
      put_in(applicability, ["payload", "applicability", "positive"], ["never matches"]),
      base_context,
      {:skill_anti_hijack_failed, %{positive_unmatched: ["never matches"], negative_matched: []}}
    )

    prompt_mount = put_in(mount_operation(), ["payload", "definition"], prompt_skill())
    no_prompt_grant = %{base_context | authority: Envelope.new!(operations: ["lookup"])}

    assert_operation_error(
      registry,
      base,
      prompt_mount,
      %{no_prompt_grant | prompt_token_ceiling: nil},
      :governance_prompt_budget_not_granted
    )

    assert_operation_error(
      registry,
      base,
      prompt_mount,
      %{base_context | prompt_token_ceiling: 1},
      {:governance_prompt_budget_exceeded, 8, 1}
    )

    assert_operation_error(
      registry,
      base,
      prompt_mount,
      base_context,
      {:governance_prompt_budget_class_not_granted, :small}
    )

    prompt_authority = %{
      base_context
      | authority:
          Envelope.new!(
            operations: ["lookup"],
            prompt_budget_classes: [:small],
            limits: %{max_tokens: 512}
          )
    }

    assert {:ok, _prompt_mounted} =
             apply_operation(registry, base, prompt_mount, prompt_authority)

    eval_case = %{
      "type" => "add_eval_case",
      "payload" => %{"case" => %{"id" => "new", "input" => "lookup"}}
    }

    assert {:ok, with_case} = apply_operation(registry, base, eval_case, base_context)

    assert_operation_error(
      registry,
      with_case,
      eval_case,
      base_context,
      {:duplicate_candidate_eval_case, "new"}
    )

    assert_operation_error(
      registry,
      base,
      put_in(eval_case, ["type"], "replace_eval_case"),
      base_context,
      {:candidate_eval_case_not_found, "new"}
    )

    assert_operation_error(
      registry,
      base,
      put_in(eval_case, ["payload", "unknown"], true),
      base_context,
      {:unknown_eval_case_governance_fields, ["unknown"]}
    )

    migration = %{
      "type" => "select_state_migration",
      "payload" => %{"skill_id" => "lookup", "migration_ref" => "lookup-v2"}
    }

    assert {:ok, with_migration} = apply_operation(registry, base, migration, base_context)

    assert_operation_error(
      registry,
      with_migration,
      put_in(migration, ["payload", "migration_ref"], "lookup-v3"),
      base_context,
      {:duplicate_skill_state_migration, "lookup"}
    )

    assert_operation_error(
      registry,
      base,
      put_in(migration, ["payload", "migration_ref"], "unknown"),
      base_context,
      {:state_migration_not_registered, "unknown"}
    )

    assert_operation_error(
      registry,
      base,
      put_in(migration, ["payload", "unknown"], true),
      base_context,
      {:unknown_state_migration_governance_fields, ["unknown"]}
    )
  end

  test "governed composition enforces the aggregate prompt window" do
    authority =
      Envelope.new!(
        operations: ["lookup"],
        prompt_budget_classes: [:small],
        limits: %{max_tokens: 12}
      )

    %{store: store, activation: activation} = baseline(authority: authority)

    first = put_in(mount_operation(), ["payload", "definition"], prompt_skill())

    second =
      first
      |> put_in(["payload", "mount_id"], "lookup-secondary")
      |> put_in(["payload", "definition", "id"], "lookup-secondary")

    assert {:error, {:governance_prompt_window_exceeded, 16, 12}} =
             Composer.compose(store, change_set(activation, [first, second]),
               activation: activation,
               prompt_token_ceiling: 1_000,
               created_at: 2
             )
  end

  test "constitutional constraints are normalized once and reverify mounted skills" do
    authority =
      Envelope.new!(
        operations: ["lookup"],
        prompt_budget_classes: [:small],
        limits: %{max_tokens: 20}
      )

    ceiling = %{
      scopes: ["support"],
      required_tags: ["staff"],
      forbidden_tags: ["suspended"],
      conflicts: ["legacy"]
    }

    assert {:ok,
            %Constraints{
              prompt_token_ceiling: 10,
              applicability_ceilings: %{"lookup" => normalized_ceiling}
            }} =
             Constraints.new(authority,
               prompt_token_ceiling: 10,
               applicability_ceilings: %{lookup: ceiling}
             )

    assert normalized_ceiling["scopes"] == ["support"]
    assert normalized_ceiling["required_tags"] == ["staff"]

    assert {:ok, %Constraints{prompt_token_ceiling: 20}} = Constraints.new(authority, [])

    assert {:ok, %Constraints{prompt_token_ceiling: 10}} =
             Constraints.new(Envelope.empty(), prompt_token_ceiling: 10)

    assert {:ok, %Constraints{prompt_token_ceiling: nil}} =
             Constraints.new(Envelope.empty(), [])

    assert {:error, {:invalid_governance_constraint_options, :invalid}} =
             Constraints.new(authority, :invalid)

    assert {:error, {:invalid_governance_prompt_token_ceiling, -1}} =
             Constraints.new(authority, prompt_token_ceiling: -1)

    assert {:error, {:governance_data_map_required, :list}} =
             Constraints.normalize_applicability_ceilings([])

    assert {:error, {:invalid_governance_data_key, [], ""}} =
             Constraints.normalize_applicability_ceilings(%{"" => ceiling})

    assert {:error, {:invalid_skill_applicability_ceiling_mount, "Elixir.System"}} =
             Constraints.normalize_applicability_ceilings(%{"Elixir.System" => ceiling})

    assert {:error, {:invalid_skill_applicability_ceiling, "lookup", _reason}} =
             Constraints.normalize_applicability_ceilings(%{
               "lookup" => Map.put(ceiling, :scopes, :all)
             })

    finite = Applicability.new!(ceiling)

    assert :ok =
             Constraints.within_applicability_ceiling(
               Applicability.new!(%{
                 scopes: ["support"],
                 required_tags: ["staff", "on_call"],
                 forbidden_tags: ["suspended", "banned"],
                 conflicts: ["legacy", "deprecated"]
               }),
               finite
             )

    assert :ok =
             Constraints.within_applicability_ceiling(
               Applicability.new!(scopes: []),
               Applicability.new!(scopes: [])
             )

    assert :ok =
             Constraints.within_applicability_ceiling(
               Applicability.new!(
                 scopes: [:support],
                 required_tags: [:staff],
                 forbidden_tags: [:suspended],
                 conflicts: [:legacy]
               ),
               finite
             )

    assert :ok =
             Constraints.within_applicability_ceiling(
               Applicability.new!(scopes: [1]),
               Applicability.new!(scopes: [1])
             )

    nonportable = %{Applicability.new!(%{}) | scopes: [self()]}

    assert {:error, :skill_applicability_ceiling_exceeded} =
             Constraints.within_applicability_ceiling(nonportable, nonportable)

    for widened <- [
          Applicability.new!(scopes: []),
          Applicability.new!(scopes: ["admin"]),
          Applicability.new!(scopes: ["support"], required_tags: []),
          Applicability.new!(scopes: ["support"], required_tags: ["staff"], forbidden_tags: []),
          Applicability.new!(
            scopes: ["support"],
            required_tags: ["staff"],
            forbidden_tags: ["suspended"],
            conflicts: []
          )
        ] do
      assert {:error, :skill_applicability_ceiling_exceeded} =
               Constraints.within_applicability_ceiling(widened, finite)
    end

    registry = Registry.default()
    base = Composition.new(Definition.canonical!(Agent))

    context = %{
      authority: authority,
      prompt_token_ceiling: 20,
      mutable_config_paths: %{},
      applicability_ceilings: %{},
      registered_migrations: []
    }

    assert {:ok, plain} = apply_operation(registry, base, mount_operation(), context)

    assert :ok =
             Constraints.verify_definition(
               plain.definition,
               Envelope.new!(operations: ["lookup"]),
               %Constraints{prompt_token_ceiling: nil, applicability_ceilings: %{}}
             )

    wildcard_mount =
      put_in(mount_operation(), ["payload", "definition", "applicability", "scopes"], [])

    assert {:ok, wildcard} = apply_operation(registry, base, wildcard_mount, context)

    assert {:ok, persisted_scope_ceiling} =
             Constraints.restore(nil, %{
               "lookup" => %{
                 scopes: ["support"],
                 required_tags: [],
                 forbidden_tags: [],
                 conflicts: []
               }
             })

    assert {:error, :skill_applicability_ceiling_exceeded} =
             Constraints.verify_definition(
               wildcard.definition,
               Envelope.new!(operations: ["lookup"]),
               persisted_scope_ceiling
             )

    prompt_mount = put_in(mount_operation(), ["payload", "definition"], prompt_skill())
    assert {:ok, prompted} = apply_operation(registry, base, prompt_mount, context)

    assert {:error, {:governance_operation_authority_exceeded, "lookup"}} =
             Constraints.verify_definition(
               prompted.definition,
               Envelope.new!(prompt_budget_classes: [:small]),
               %Constraints{prompt_token_ceiling: 20, applicability_ceilings: %{}}
             )

    assert {:error, {:governance_prompt_budget_class_not_granted, :small}} =
             Constraints.verify_definition(
               prompted.definition,
               Envelope.new!(operations: ["lookup"]),
               %Constraints{prompt_token_ceiling: 20, applicability_ceilings: %{}}
             )

    assert {:error, :governance_prompt_budget_not_granted} =
             Constraints.verify_definition(
               prompted.definition,
               authority,
               %Constraints{prompt_token_ceiling: nil, applicability_ceilings: %{}}
             )

    assert :ok =
             Constraints.verify_definition(
               prompted.definition,
               authority,
               %Constraints{prompt_token_ceiling: 8, applicability_ceilings: %{}}
             )
  end

  test "portable governance data rejects non-JSON runtime shapes without raising" do
    assert {:ok, %{"mode" => "safe"}} = GovernanceData.normalize(%{mode: :safe})
    assert {:error, {:governance_data_map_required, :list}} = GovernanceData.normalize_map([])

    assert {:error, {:nonportable_governance_data, [], :tuple}} =
             GovernanceData.normalize({:tuple})

    assert {:error, {:nonportable_governance_data, [], :function}} =
             GovernanceData.normalize(fn -> :ok end)

    assert {:error, {:nonportable_governance_data, [], :pid}} =
             GovernanceData.normalize(self())

    assert {:error, {:nonportable_governance_data, [], :reference}} =
             GovernanceData.normalize(make_ref())

    assert {:ok, quoted} =
             GovernanceData.quote(%{:atom => {:tuple, <<255>>}, "list" => [:value]})

    assert {:ok, _json} = Jason.encode(quoted)

    oversized = String.duplicate("x", 1_048_577)

    assert {:error, {:governance_data_too_large, _size, 1_048_576}} =
             GovernanceData.normalize(%{"oversized" => oversized})
  end

  test "operation and registry constructors close malformed extension points" do
    assert {:ok, operation} = Operation.new(%{type: :mount_skill, payload: %{safe: true}})
    assert {:ok, ^operation} = Operation.new(operation)
    assert Operation.to_data(operation)["payload"] == %{"safe" => true}

    assert {:error, {:unknown_governance_operation_fields, [:unknown]}} =
             Operation.new(%{type: :mount_skill, payload: %{}, unknown: true})

    assert {:error, {:invalid_governance_operation_type, "UPPER"}} =
             Operation.new(%{type: "UPPER", payload: %{}})

    assert {:error, {:invalid_governance_operation_type, nil}} =
             Operation.new(%{payload: %{}})

    assert {:error, {:invalid_governance_operation_payload, :list}} =
             Operation.new(%{type: "mount_skill", payload: []})

    assert {:error, {:invalid_governance_operation, :tuple}} = Operation.new({:bad})

    assert {:error, {:invalid_governance_operation, :list}} =
             Operation.new(type: "one", type: "two")

    assert {:error, {:invalid_governance_handler_registry, :other}} = Registry.new(:bad)
    assert {:error, {:invalid_governance_handler, 42}} = Registry.register(Registry.default(), 42)

    assert {:error, {:governance_handler_callback_missing, Agent, :operation_types, 0}} =
             Registry.register(Registry.default(), Agent)

    assert {:error,
            {:invalid_governance_handler_types, SpectreGovernanceGateTest.InvalidTypesHandler}} =
             Registry.new([SpectreGovernanceGateTest.InvalidTypesHandler])

    assert {:error,
            {:invalid_governance_handler_classes, SpectreGovernanceGateTest.InvalidClassesHandler}} =
             Registry.new([SpectreGovernanceGateTest.InvalidClassesHandler])

    assert {:error,
            {:governance_handler_exception, SpectreGovernanceGateTest.RaisingMetadataHandler,
             RuntimeError}} =
             Registry.new([SpectreGovernanceGateTest.RaisingMetadataHandler])

    assert {:error, {:duplicate_governance_operation_handler, "invalid_result"}} =
             Registry.new([
               SpectreGovernanceGateTest.InvalidResultHandler,
               SpectreGovernanceGateTest.InvalidResultHandler
             ])

    assert {:ok, undeclared_registry} =
             Registry.new([SpectreGovernanceGateTest.UndeclaredComponentHandler])

    assert {:ok, undeclared_operation} =
             Operation.new(%{type: "undeclared_component", payload: %{}})

    assert {:error,
            {:governance_operation_failed, 0,
             {:governance_handler_undeclared_component_classes, [:authority]}}} =
             Registry.apply(
               undeclared_registry,
               [undeclared_operation],
               Composition.new(Definition.canonical!(Agent)),
               %{}
             )

    assert {:ok, hidden_registry} =
             Registry.new([SpectreGovernanceGateTest.HiddenComponentHandler])

    assert {:ok, hidden_operation} =
             Operation.new(%{type: "hidden_component", payload: %{}})

    assert {:error,
            {:governance_operation_failed, 0,
             {:governance_handler_unreported_component_classes, [_component]}}} =
             Registry.apply(
               hidden_registry,
               [hidden_operation],
               Composition.new(Definition.canonical!(Agent)),
               %{}
             )

    assert {:error, :invalid_governance_registry_application} =
             Registry.apply(
               Registry.default(),
               :invalid,
               Composition.new(Definition.canonical!(Agent)),
               %{}
             )

    assert_raise ArgumentError, ~r/invalid ChangeSet handler registry/, fn ->
      Registry.new!([Agent])
    end
  end

  test "review and approval state transitions reject incomplete evidence" do
    %{store: store, activation: activation, candidate: bootstrap_ref} = baseline()
    change_set = change_set(activation, [mount_operation()])

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set, activation: activation, created_at: 2)

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    replay = receipt(governance, :replay, 3, profile_ref: "recording:test")
    regression = receipt(governance, :regression, 3)

    assert {:error, {:invalid_governance_review_delta, :other}} =
             Review.evaluate(store, composed_ref, :invalid, [], [])

    assert {:error, :candidate_is_not_governed} =
             Review.evaluate(store, bootstrap_ref, delta, [], [])

    assert {:error, {:review_cannot_supply_gate_class, 0, :structural}} =
             Review.evaluate(
               store,
               composed_ref,
               delta,
               [receipt(governance, :structural, 3)],
               []
             )

    assert {:error, {:invalid_review_gate_receipt, 0, :other}} =
             Review.evaluate(store, composed_ref, delta, [42], [])

    assert {:error, {:required_gate_receipt_missing, :regression}} =
             Review.evaluate(store, composed_ref, delta, [replay],
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    second_replay = receipt(governance, :replay, 4, profile_ref: "recording:test")

    assert {:error, {:ambiguous_gate_receipts, :replay}} =
             Review.evaluate(store, composed_ref, delta, [replay, second_replay, regression],
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    failed_delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: false}]
      )

    assert {:ok, rejected_ref, _report} =
             Review.evaluate(store, composed_ref, failed_delta, [replay, regression],
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert {:error, {:candidate_not_evaluated, :rejected}} =
             Approval.approve(store, rejected_ref, mode: :human, actor_ref: "operator:test")

    assert {:ok, reviewed_ref, _report} =
             Review.evaluate(store, composed_ref, delta, [replay, regression],
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert {:error, {:candidate_not_composed, :evaluated}} =
             Review.evaluate(store, reviewed_ref, delta, [replay, regression],
               checker_versions: @checker_versions
             )

    assert {:error, {:invalid_governance_approval_actor, :human, nil}} =
             Approval.approve(store, reviewed_ref, mode: :human)

    assert {:error, {:invalid_governance_approval_mode, :robot}} =
             Approval.approve(store, reviewed_ref, mode: :robot)

    assert {:error, {:invalid_governance_approval_options, :bad}} =
             Approval.approve(store, reviewed_ref, :bad)

    assert {:error, {:invalid_governance_rejection_actor, nil}} =
             Approval.reject(store, reviewed_ref, reason: "unsafe")

    assert {:error, {:invalid_governance_rejection_reason, nil}} =
             Approval.reject(store, reviewed_ref, actor_ref: "operator:test")

    assert {:error, {:invalid_governance_rejection_options, :bad}} =
             Approval.reject(store, reviewed_ref, :bad)

    assert {:ok, explicitly_rejected_ref} =
             Approval.reject(store, reviewed_ref,
               actor_ref: "operator:test",
               reason: "Protected behavior needs another review",
               rejected_at: 6
             )

    assert {:ok, %Candidate{governance: %{state: :rejected}}} =
             Store.fetch_candidate(store, explicitly_rejected_ref)

    assert {:error, {:candidate_not_evaluated, :rejected}} =
             Approval.approve(store, explicitly_rejected_ref,
               mode: :human,
               actor_ref: "operator:test"
             )

    assert {:error, :governance_candidate_not_found} =
             Approval.approve(store, candidate_ref("d"), mode: :human, actor_ref: "operator:test")
  end

  test "rollback rejects missing, current and sibling activation targets" do
    %{store: store, instance: instance, activation: activation, candidate: base_candidate} =
      baseline()

    assert {:error, :rollback_target_already_active} =
             Spectre.rollback(instance, base_candidate, expected_generation: 1)

    sibling = approved_candidate(store, activation, "sibling")
    active = approved_candidate(store, activation, "active")

    assert {:ok, bootstrap} = Store.fetch_candidate(store, base_candidate)

    lookalike =
      bootstrap
      |> Map.from_struct()
      |> Map.put(:created_at, bootstrap.created_at + 100)
      |> Map.put(:provenance_refs, bootstrap.provenance_refs ++ ["lookalike:test"])
      |> Candidate.new!()

    assert {:ok, lookalike_ref} = Store.publish_candidate(store, lookalike)
    assert lookalike_ref != base_candidate

    assert sibling != active

    assert {:ok, activated} =
             Spectre.activate(instance, active,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert {:error, :rollback_target_is_not_ancestor} =
             Spectre.rollback(instance, sibling,
               expected_generation: activated.generation,
               now: 8,
               checker_versions: @checker_versions
             )

    assert {:error, :rollback_target_is_not_ancestor} =
             Spectre.rollback(instance, lookalike_ref,
               expected_generation: activated.generation,
               now: 8,
               checker_versions: @checker_versions
             )

    fresh_subject = Subject.new("rollback-empty-#{System.unique_integer([:positive])}")

    fresh_instance =
      start_supervised!(
        {Instance,
         agent: Agent,
         subject: fresh_subject,
         definition_store: store,
         opts: [checker_versions: @checker_versions],
         idle: false}
      )

    assert {:error, :rollback_requires_current_activation} =
             Spectre.rollback(fresh_instance, base_candidate, expected_generation: 0)
  end

  test "rollback restores narrowed authority only with an explicit host grant" do
    %{store: store, instance: instance, activation: activation, candidate: base_candidate} =
      baseline()

    eval_operation = %{
      "type" => "add_eval_case",
      "payload" => %{"case" => %{"id" => "candidate-owned", "input" => "lookup"}}
    }

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set(activation, [eval_operation]),
               activation: activation,
               authority_ceiling: Envelope.empty(),
               created_at: 2
             )

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [
          %{case_id: "protected", passed: true},
          %{case_id: "candidate-owned", passed: true}
        ],
        candidate_case_ids: ["candidate-owned"]
      )

    receipts = [
      receipt(governance, :replay, 3, profile_ref: "recording:test"),
      receipt(governance, :regression, 3)
    ]

    assert {:ok, evaluated_ref, _report} =
             Review.evaluate(store, composed_ref, delta, receipts,
               reviewed_at: 4,
               now: 5,
               checker_versions: @checker_versions
             )

    assert {:ok, approved_ref} =
             Approval.approve(store, evaluated_ref,
               mode: :human,
               actor_ref: "operator:test",
               approved_at: 6
             )

    assert {:ok, narrowed} =
             Spectre.activate(instance, approved_ref,
               expected_generation: 1,
               now: 7,
               checker_versions: @checker_versions
             )

    assert {:error, {:candidate_authority_expansion, :operations, "lookup"}} =
             Spectre.rollback(instance, base_candidate,
               expected_generation: narrowed.generation,
               now: 8
             )

    assert {:ok, restored} =
             Spectre.rollback(instance, base_candidate,
               expected_generation: narrowed.generation,
               allow_authority_restore?: true,
               now: 8
             )

    assert restored.definition_ref == activation.definition_ref
  end

  test "complete GC inventory must close over Candidate and Definition lineage" do
    %{store: store, activation: activation} = baseline()
    approved = approved_candidate(store, activation)

    assert {:error, {:incomplete_gc_inventory, :candidate, missing}} =
             GC.plan(store, [approved], inventory_complete?: true)

    assert missing != []
    assert to_string(activation.candidate_ref) in missing

    assert {:error, {:invalid_gc_candidate_refs, :other}} =
             GC.plan(store, [approved],
               protected_candidate_refs: :invalid,
               inventory_complete?: true
             )

    assert {:error, {:invalid_gc_definition_refs, :other}} =
             GC.plan(store, [approved],
               protected_definition_refs: :invalid,
               inventory_complete?: true
             )
  end

  test "transported GC plans preserve exact lineage reasons and Candidate live classes" do
    %{store: store, activation: activation} = baseline()
    approved_ref = approved_candidate(store, activation)
    candidate_refs = candidate_chain(store, approved_ref)

    definition_refs =
      Enum.map(candidate_refs, fn ref ->
        assert {:ok, candidate} = Store.fetch_candidate(store, ref)
        to_string(candidate.definition_ref)
      end)
      |> Enum.uniq()

    base_ref = to_string(activation.candidate_ref)

    assert {:ok, plan} =
             GC.plan(store, candidate_refs,
               definition_refs: definition_refs,
               gc_eligible_candidate_refs: candidate_refs,
               gc_eligible_definition_refs: definition_refs,
               run_candidate_refs: [base_ref],
               inventory_complete?: true
             )

    assert base_ref in plan.protected_candidate_refs
    assert base_ref in plan.candidate_lineage_refs

    attrs =
      plan
      |> Map.from_struct()
      |> Map.delete(:digest)
      |> Map.update!(:candidate_decisions, fn decisions ->
        Enum.map(decisions, fn
          %{"ref" => ^base_ref} = decision ->
            Map.update!(decision, "reasons", &List.delete(&1, "candidate_lineage_reference"))

          decision ->
            decision
        end)
      end)

    assert {:error, {:unsafe_governance_gc_decision, ^base_ref}} = GCPlan.build(attrs)
  end

  test "ChangeSets cap the operation vocabulary before composition" do
    %{activation: activation} = baseline()
    data = activation |> change_set([mount_operation()]) |> ChangeSet.to_data()
    operations = List.duplicate(mount_operation(), 257)

    assert {:error, {:governance_operation_limit_exceeded, 257, 256}} =
             data |> Map.put("operations", operations) |> ChangeSet.from_data()
  end

  defp baseline(opts \\ []) do
    server = start_supervised!({Memory, id: {:governance, System.unique_integer([:positive])}})
    store = {Memory, server: server}
    canonical = Definition.canonical!(Agent)
    authority = Keyword.get(opts, :authority, Envelope.new!(operations: ["lookup"]))
    manifest = Manifest.new!(canonical, authority, closure())

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, candidate} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject = Subject.new("governance-#{System.unique_integer([:positive, :monotonic])}")

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

  defp approved_candidate(store, activation, mount_id \\ "lookup", opts \\ []) do
    operation = put_in(mount_operation(), ["payload", "mount_id"], mount_id)

    assert {:ok, composed_ref} =
             Composer.compose(
               store,
               change_set(activation, [operation]),
               Keyword.merge([activation: activation, created_at: 2], opts)
             )

    assert {:ok, %Candidate{governance: governance}} =
             Store.fetch_candidate(store, composed_ref)

    delta =
      EvaluationDelta.new!(
        [%{case_id: "protected", passed: true}],
        [%{case_id: "protected", passed: true}]
      )

    receipts = [
      receipt(governance, :replay, 3, profile_ref: "recording:test"),
      receipt(governance, :regression, 3)
    ]

    assert {:ok, reviewed_ref, _report} =
             Review.evaluate(
               store,
               composed_ref,
               delta,
               receipts,
               Keyword.merge(
                 [reviewed_at: 4, now: 5, checker_versions: @checker_versions],
                 opts
               )
             )

    assert {:ok, approved_ref} =
             Approval.approve(
               store,
               reviewed_ref,
               Keyword.merge(
                 [mode: :human, actor_ref: "operator:test", approved_at: 6],
                 opts
               )
             )

    approved_ref
  end

  defp durable_baseline do
    definition_server =
      start_supervised!(
        Supervisor.child_spec({Elixir.Agent, fn -> %{} end},
          id: {:governance_definition_entries, make_ref()}
        )
      )

    checkpoint_server =
      start_supervised!(
        Supervisor.child_spec(
          {Elixir.Agent, fn -> %{entries: %{}, fail_next?: false} end},
          id: {:governance_checkpoint_entries, make_ref()}
        )
      )

    store =
      {DurableDefinitionStore,
       server: definition_server, id: System.unique_integer([:positive, :monotonic])}

    checkpoint_store = {CheckpointStore, server: checkpoint_server}
    canonical = Definition.canonical!(Agent)
    authority = Envelope.new!(operations: ["lookup"])
    manifest = Manifest.new!(canonical, authority, closure())

    assert {:ok, _publication} =
             Store.publish(store, canonical, manifest, checkpoint_store: checkpoint_store)

    assert {:ok, candidate} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1,
               checkpoint_store: checkpoint_store
             )

    subject = Subject.new("governance-recovery-#{System.unique_integer([:positive, :monotonic])}")
    {instance, instance_id} = start_governance_instance(subject, store, checkpoint_store)

    assert {:ok, activation} = Spectre.activate(instance, candidate, expected_generation: 0)

    %{
      store: store,
      checkpoint_store: checkpoint_store,
      checkpoint_server: checkpoint_server,
      subject: subject,
      instance: instance,
      instance_id: instance_id,
      activation: activation,
      candidate: candidate
    }
  end

  defp start_governance_instance(subject, store, checkpoint_store) do
    id = {:governance_recovery_instance, make_ref()}

    spec =
      {Instance,
       agent: Agent,
       subject: subject,
       definition_store: store,
       checkpoint_store: checkpoint_store,
       opts: [checker_versions: @checker_versions],
       idle: false}
      |> Supervisor.child_spec(id: id, restart: :temporary)

    {start_supervised!(spec), id}
  end

  defp normalize_operations(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, operations} ->
      case Operation.new(value) do
        {:ok, operation} -> {:cont, {:ok, [operation | operations]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, _reason} = error -> error
    end)
  end

  defp replace_metadata(%Canonical{} = canonical, payload) do
    assert {:ok, component} = Canonical.fetch_component(canonical, :metadata)
    assert {:ok, replacement} = Component.new(%{component | payload: payload})

    components =
      Enum.map(canonical.components, fn
        %{component_type: :metadata} -> replacement
        other -> other
      end)

    assert {:ok, rebuilt} =
             canonical |> Map.from_struct() |> Map.put(:components, components) |> Canonical.new()

    rebuilt
  end

  defp apply_operation(registry, composition, operation, context) do
    with {:ok, operation} <- Operation.new(operation) do
      Registry.apply(registry, [operation], composition, context)
    end
  end

  defp assert_operation_error(registry, composition, operation, context, reason) do
    assert {:error, {:governance_operation_failed, 0, ^reason}} =
             apply_operation(registry, composition, operation, context)
  end

  defp candidate_ref(digit) do
    {:ok, ref} = CandidateRef.parse("candidate:sha256:" <> String.duplicate(digit, 64))
    ref
  end

  defp definition_ref(digit) do
    {:ok, ref} = DefinitionRef.parse("sha256:" <> String.duplicate(digit, 64))
    ref
  end

  defp change_set(activation, operations) do
    ChangeSet.new!(%{
      base_activation_receipt: activation.activation_receipt,
      base_candidate_ref: activation.candidate_ref,
      observed_definition_ref: activation.definition_ref,
      observed_authority_epoch: activation.authority_epoch,
      observed_evidence_digest: ChangeSet.evidence_digest(activation),
      operations: operations,
      author_ref: "host:test",
      provenance: %{test: "governance"},
      reason: "Mount a reviewed lookup capability",
      created_at: 2
    })
  end

  defp mount_operation do
    %{
      "type" => "mount_skill",
      "payload" => %{
        "mount_id" => "lookup",
        "definition" => %{
          "id" => "lookup",
          "declared_version" => 1,
          "publisher_ref" => "host:test",
          "applicability" => %{
            "scopes" => ["support"],
            "positive" => ["lookup"],
            "negative" => ["delete everything"]
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
      }
    }
  end

  defp prompt_skill do
    mount_operation()["payload"]["definition"]
    |> Map.put("prompt_budget", 64)
    |> Map.put("prompt_fragments", [
      %{
        "id" => "guide",
        "content" => "Use lookup",
        "token_cap" => 8,
        "budget_class" => "small"
      }
    ])
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
      expires_at: Keyword.get(opts, :expires_at),
      status: Keyword.get(opts, :status, :passed),
      result_digest: Value.digest!(%{gate: gate, passed: true}),
      provenance: Keyword.get(opts, :provenance, %{source: :test_checker})
    })
  end

  defp governance_fixture(change_set) do
    CandidateState.new!(%{
      change_set_digest: ChangeSet.digest(change_set),
      base_activation_receipt: change_set.base_activation_receipt,
      base_candidate_ref: to_string(change_set.base_candidate_ref),
      parent_definition_ref: to_string(change_set.observed_definition_ref),
      candidate_definition_ref: "sha256:" <> String.duplicate("b", 64),
      observed_authority_epoch: change_set.observed_authority_epoch,
      observed_evidence_digest: change_set.observed_evidence_digest,
      closure_digest: @digest,
      evaluation_cases_digest: @digest,
      protected_cases_digest: Value.digest!(["protected"]),
      prompt_token_ceiling: nil,
      applicability_ceilings: %{},
      candidate_cases: [],
      candidate_case_ids: [],
      state_migrations: [],
      risk: :low,
      required_gates: CandidateState.constitutional_gates(:low),
      state: :composed,
      gate_receipt_refs: [],
      approval_receipt_ref: nil,
      report_digest: nil,
      lineage_refs: [to_string(change_set.base_candidate_ref)]
    })
  end

  defp drain_store_gets do
    receive do
      {:definition_store_get, _key} -> drain_store_gets()
    after
      0 -> :ok
    end
  end

  defp collect_store_gets(acc \\ []) do
    receive do
      {:definition_store_get, key} -> collect_store_gets([key | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp candidate_chain(store, ref, refs \\ []) do
    ref = to_string(ref)
    assert {:ok, candidate} = Store.fetch_candidate(store, ref)
    refs = [ref | refs]

    case candidate.parent_ref do
      nil -> Enum.reverse(refs)
      parent_ref -> candidate_chain(store, parent_ref, refs)
    end
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/4",
      state_codec_ref: "spectre.instance.canonical.codec/4",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:Agent" => @digest},
      evaluation_corpus_digest: Value.digest!(["protected"]),
      compatibility_mode: :native_v2
    })
  end
end
