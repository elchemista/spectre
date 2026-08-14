defmodule SpectreGovernanceContractCoverageTest.PredicateCallbacks do
  @moduledoc false

  def execute(_payload, _context), do: true
  def arity_one(_payload), do: {:ok, true}
  def declared_error(_payload), do: {:error, :predicate_rejected}
end

defmodule SpectreGovernanceContractCoverageTest.MissingPredicateCallback do
  @moduledoc false
end

defmodule SpectreGovernanceContractCoverageTest.PredicateRegistry do
  @moduledoc false

  alias Spectre.Operation.Spec
  alias SpectreGovernanceContractCoverageTest.MissingPredicateCallback
  alias SpectreGovernanceContractCoverageTest.PredicateCallbacks

  def __spectre_config__ do
    [
      operations: [
        predicate(:default_callback, PredicateCallbacks),
        predicate(:arity_one, {PredicateCallbacks, :arity_one}),
        predicate(:declared_error, {PredicateCallbacks, :declared_error}),
        predicate(:missing_callback, {MissingPredicateCallback, :evaluate}),
        predicate(:unloaded_callback, {unloaded_callback(), :evaluate}),
        predicate("string_predicate", {PredicateCallbacks, :arity_one})
      ]
    ]
  end

  defp predicate(id, executor) do
    Spec.new(
      id: id,
      executor: executor,
      input: :map,
      output: :boolean,
      side_effect: :none
    )
  end

  defp unloaded_callback,
    do: SpectreGovernanceContractCoverageTest.UnloadedPredicateCallback
end

defmodule SpectreGovernanceContractCoverageTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :governance_contract_coverage_agent
end

defmodule SpectreGovernanceContractCoverageTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Governance.ChangeSet.Handlers.StateMigration
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Composition
  alias Spectre.Governance.GC.Plan
  alias Spectre.Input
  alias Spectre.Prompt.Predicate
  alias SpectreGovernanceContractCoverageTest.Agent
  alias SpectreGovernanceContractCoverageTest.PredicateRegistry

  @candidate_ref "candidate:sha256:" <> String.duplicate("1", 64)
  @definition_ref "sha256:" <> String.duplicate("2", 64)
  @evidence_digest String.duplicate("3", 64)
  @snapshot_digest String.duplicate("4", 64)

  test "state migration selection accepts only stable fields from the trusted registry" do
    composition = Composition.new(Definition.canonical!(Agent))

    operation = migration_operation("account", "account-v2")

    assert {:ok, migrated} =
             StateMigration.apply(operation, composition, %{
               registered_migrations: [:"account-v2"]
             })

    assert migrated.state_migrations == [
             %{"skill_id" => "account", "migration_ref" => "account-v2"}
           ]

    assert migrated.changed_components == [:state_migrations]
    assert migrated.operation_types == ["select_state_migration"]
    assert migrated.risk == :high

    assert {:error, {:invalid_state_migration_field, :skill_id, nil}} =
             StateMigration.apply(migration_operation(nil, "account-v2"), composition, %{
               registered_migrations: [:"account-v2"]
             })

    assert {:error, :state_migration_code_reference_forbidden} =
             StateMigration.apply(
               migration_operation("account", "Elixir.AccountMigration"),
               composition,
               %{registered_migrations: ["Elixir.AccountMigration"]}
             )

    assert {:error, {:state_migration_not_registered, "account-v2"}} =
             StateMigration.apply(operation, composition, %{registered_migrations: %{}})
  end

  test "prompt predicates preserve the closed callback and reply contract" do
    input = Input.new("inspect")

    assert {:ok, true, %{"matched" => true, "predicate_ref" => "default_callback"}} =
             Predicate.evaluate(
               %{predicate_ref: "default_callback"},
               input,
               %{request_id: "request-1"},
               agent: PredicateRegistry
             )

    assert {:ok, true, %{"matched" => true, "predicate_ref" => "arity_one"}} =
             evaluate_predicate("arity_one", input)

    assert {:ok, true, %{"matched" => true, "predicate_ref" => "string_predicate"}} =
             evaluate_predicate("string_predicate", input)

    assert {:error, :predicate_rejected} = evaluate_predicate("declared_error", input)

    assert {:error, {:prompt_predicate_callback_missing, :missing_callback}} =
             evaluate_predicate("missing_callback", input)

    assert {:error, {:prompt_predicate_not_loaded, :unloaded_callback}} =
             evaluate_predicate("unloaded_callback", input)
  end

  test "GC plan evidence round-trips and rejects nonportable or structurally invalid data" do
    attrs = gc_plan_attrs()

    assert {:ok, plan} = Plan.build(attrs)
    assert :ok = Plan.verify(plan)
    assert {:ok, ^plan} = plan |> Plan.encode() |> elem(1) |> Plan.decode()

    assert {:error, :nonportable_governance_gc_plan} =
             Plan.build(%{attrs | store_identity: %{adapter: "coverage"}})

    data = Plan.to_data(plan)

    assert {:error, :invalid_governance_gc_evidence_digest} =
             data
             |> Map.put("evidence_digest", "not-a-digest")
             |> Plan.from_data()

    assert {:error, :invalid_governance_gc_plan_data} =
             data
             |> Map.put("schema_version", "2")
             |> Plan.from_data()

    invalid = %{plan | evidence_digest: "not-a-digest"}
    redigested = %{invalid | digest: invalid |> unsigned_plan_data() |> Value.digest!()}

    assert {:error, :invalid_governance_gc_evidence_digest} = Plan.verify(redigested)
  end

  test "GC plan decisions fail closed on incomplete inventories and malformed evidence" do
    attrs = gc_plan_attrs()

    assert {:error, :invalid_governance_gc_candidate_decisions} =
             Plan.build(%{attrs | candidate_decisions: []})

    assert {:error, :invalid_governance_gc_definition_decisions} =
             Plan.build(%{attrs | definition_decisions: []})

    assert_candidate_decision_error(attrs, 42, :invalid_decision_shape)

    assert_candidate_decision_error(
      attrs,
      candidate_decision("unknown", []),
      :invalid_candidate_decision
    )

    assert_candidate_decision_error(
      attrs,
      candidate_decision("retained", "not-a-list"),
      :invalid_candidate_decision
    )

    assert_candidate_decision_error(
      attrs,
      candidate_decision("eligible", ["retention_not_gc_eligible"]),
      :invalid_candidate_decision
    )

    assert_candidate_decision_error(
      attrs,
      candidate_decision("retained", []),
      :invalid_candidate_decision
    )

    invalid_prefix =
      candidate_decision("eligible", [])
      |> Map.put("ref", @definition_ref)

    assert_candidate_decision_error(attrs, invalid_prefix, :invalid_candidate_decision)

    invalid_type =
      candidate_decision("eligible", [])
      |> Map.put("ref", 42)

    assert_candidate_decision_error(attrs, invalid_type, :invalid_candidate_decision)
  end

  defp migration_operation(skill_id, migration_ref) do
    %Operation{
      type: "select_state_migration",
      payload: %{"skill_id" => skill_id, "migration_ref" => migration_ref}
    }
  end

  defp evaluate_predicate(ref, input) do
    Predicate.evaluate(
      %{"predicate_ref" => ref},
      input,
      %{},
      agent: PredicateRegistry
    )
  end

  defp gc_plan_attrs do
    %{
      store_identity: %{"adapter" => "coverage", "id" => "governance-contract"},
      inventory_complete: true,
      candidate_inventory: [@candidate_ref],
      definition_inventory: [@definition_ref],
      candidate_decisions: [candidate_decision("eligible", [])],
      definition_decisions: [definition_decision("eligible", [])],
      protected_candidate_refs: [],
      protected_definition_refs: [],
      candidate_lineage_refs: [],
      definition_lineage_refs: [],
      requested_candidate_refs: [@candidate_ref],
      requested_definition_refs: [@definition_ref],
      inventory_snapshot_digest: @snapshot_digest,
      evidence_digest: @evidence_digest
    }
  end

  defp candidate_decision(decision, reasons) do
    %{
      "ref" => @candidate_ref,
      "definition_ref" => @definition_ref,
      "decision" => decision,
      "reasons" => reasons
    }
  end

  defp definition_decision(decision, reasons) do
    %{"ref" => @definition_ref, "decision" => decision, "reasons" => reasons}
  end

  defp assert_candidate_decision_error(attrs, decision, reason) do
    assert {:error, {:invalid_governance_gc_decision, :candidate, 0, ^reason}} =
             Plan.build(%{attrs | candidate_decisions: [decision]})
  end

  defp unsigned_plan_data(plan) do
    plan
    |> Plan.to_data()
    |> Map.delete("digest")
  end
end
