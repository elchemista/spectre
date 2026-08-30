defmodule SpectreSkillStateSemanticsTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :skill_state_agent
end

defmodule SpectreSkillStateSemanticsTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope, as: AuthorityEnvelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Instance
  alias Spectre.Instance.Lifecycle
  alias Spectre.Skill.StateBinding
  alias Spectre.Subject

  alias SpectreSkillStateSemanticsTest.Agent

  @skill_id "planner"
  @schema_v1 "spectre.test/planner-state/1"
  @schema_v2 "spectre.test/planner-state/2"

  test "Skill StateBinding round-trips and enforces schema, generation, revision and fence" do
    {:ok, definition_ref} =
      DefinitionRef.parse("sha256:" <> String.duplicate("f", 64))

    binding =
      StateBinding.new!(
        skill_id: @skill_id,
        state_schema_ref: @schema_v1,
        state_generation: 3,
        branch_id: "planner-branch",
        parent_branch_id: "planner-parent",
        owning_definition_ref: definition_ref,
        revision: 4,
        fencing_token: 7,
        status: :active,
        retention: :retained,
        state: %{"step" => 1},
        created_at: 10,
        updated_at: 11,
        provenance: %{"test" => true}
      )

    assert is_binary(binding.binding_receipt)
    assert {:ok, encoded} = StateBinding.encode(binding)
    assert {:ok, ^binding} = StateBinding.decode(encoded)
    assert {:ok, ^binding} = binding |> StateBinding.to_data() |> StateBinding.from_data()

    assert {:ok, updated} =
             StateBinding.update(binding, %{"step" => 2},
               expected_generation: 3,
               expected_revision: 4,
               state_schema_ref: @schema_v1,
               owning_definition_ref: definition_ref,
               fencing_token: 8,
               updated_at: 12
             )

    assert updated.revision == 5
    assert updated.fencing_token == 8
    assert updated.state == %{"step" => 2}

    assert {:error, {:stale_skill_state_revision, 4, 5}} =
             StateBinding.update(updated, %{},
               expected_generation: 3,
               expected_revision: 4,
               state_schema_ref: @schema_v1,
               owning_definition_ref: definition_ref,
               fencing_token: 8
             )

    assert {:error, {:skill_state_schema_violation, @schema_v2, @schema_v1}} =
             StateBinding.update(updated, %{},
               expected_generation: 3,
               expected_revision: 5,
               state_schema_ref: @schema_v2,
               owning_definition_ref: definition_ref,
               fencing_token: 8
             )
  end

  test "rollback A from B requires an explicit branch choice and never merges state" do
    store = definition_store()
    {definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(store)
    instance = start_instance(store, "skill-rollback")

    assert {:ok, activation_a} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 0,
               activated_at: 100,
               skill_state_transitions: %{
                 @skill_id => {:init, @schema_v1, %{"owner" => "A", "value" => 1}}
               }
             )

    assert {:ok, %StateBinding{} = branch_a} = Spectre.skill_state(instance, @skill_id)
    assert branch_a.owning_definition_ref == definition_a
    assert branch_a.state_generation == 1
    assert activation_a.state_bindings[@skill_id] == StateBinding.activation_pointer(branch_a)

    assert {:ok, branch_a_updated} =
             Spectre.update_skill_state(
               instance,
               @skill_id,
               %{
                 "owner" => "A",
                 "value" => 2
               },
               expected_generation: 1,
               expected_revision: 0,
               state_schema_ref: @schema_v1,
               updated_at: 101
             )

    assert {:ok, activation_b} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 1,
               activated_at: 102,
               skill_state_transitions: %{
                 @skill_id => {:fork, @schema_v1, %{"owner" => "B", "value" => 10}}
               }
             )

    assert {:ok, %StateBinding{} = branch_b} = Spectre.skill_state(instance, @skill_id)
    assert branch_b.owning_definition_ref == definition_b
    assert branch_b.state_generation == 2
    assert branch_b.parent_branch_id == branch_a.branch_id
    assert activation_b.state_bindings[@skill_id] == StateBinding.activation_pointer(branch_b)

    assert {:ok, branch_b_updated} =
             Spectre.update_skill_state(
               instance,
               @skill_id,
               %{
                 "owner" => "B",
                 "value" => 20
               },
               expected_generation: 2,
               expected_revision: 0,
               state_schema_ref: @schema_v1,
               updated_at: 103
             )

    assert {:error, {:skill_state_transition_required, @skill_id, [branch_id]}} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 2,
               activated_at: 104
             )

    assert branch_id == branch_a.branch_id
    assert Spectre.activation(instance) == activation_b

    assert {:ok, activation_a_rollback} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 2,
               activated_at: 105,
               skill_state_transitions: %{@skill_id => {:resume, branch_a.branch_id}}
             )

    assert {:ok, resumed_a} = Spectre.skill_state(instance, @skill_id)
    assert resumed_a.branch_id == branch_a.branch_id
    assert resumed_a.state == branch_a_updated.state
    assert resumed_a.state != branch_b_updated.state

    assert activation_a_rollback.state_bindings[@skill_id] ==
             StateBinding.activation_pointer(resumed_a)

    assert {:ok, branches} = Spectre.skill_state_branches(instance, @skill_id)
    assert Enum.map(branches, & &1.state_generation) == [2, 1]
    assert Enum.find(branches, &(&1.branch_id == branch_b.branch_id)).status == :dormant

    assert {:error, {:skill_state_not_active, _, :dormant, :retained}} =
             Spectre.update_skill_state(instance, @skill_id, %{},
               branch_id: branch_b.branch_id,
               expected_generation: 2,
               expected_revision: branch_b_updated.revision,
               state_schema_ref: @schema_v1
             )
  end

  test "migration creates a new generation while abandon is explicit" do
    store = definition_store()
    {_definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(store)
    instance = start_instance(store, "skill-migrate")

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 0,
               activated_at: 200,
               skill_state_transitions: %{
                 @skill_id => {:init, @schema_v1, %{"history" => ["A"]}}
               }
             )

    assert {:ok, branch_a} = Spectre.skill_state(instance, @skill_id)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 1,
               activated_at: 201,
               skill_state_transitions: %{
                 @skill_id => {:fork, @schema_v1, %{"history" => ["A", "B-old"]}}
               }
             )

    assert {:ok, branch_b_old} = Spectre.skill_state(instance, @skill_id)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 2,
               activated_at: 202,
               skill_state_transitions: %{@skill_id => {:resume, branch_a.branch_id}}
             )

    assert {:ok, activation_b_migrated} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 3,
               activated_at: 203,
               skill_state_transitions: %{
                 @skill_id =>
                   {:migrate, branch_a.branch_id, @schema_v2,
                    %{"history" => ["A", "B-new"], "migrated" => true}}
               }
             )

    assert {:ok, branch_b_new} = Spectre.skill_state(instance, @skill_id)
    assert branch_b_new.owning_definition_ref == definition_b
    assert branch_b_new.state_generation == 3
    assert branch_b_new.state_schema_ref == @schema_v2
    assert branch_b_new.parent_branch_id == branch_a.branch_id
    assert branch_b_new.branch_id != branch_b_old.branch_id

    assert activation_b_migrated.state_bindings[@skill_id] ==
             StateBinding.activation_pointer(branch_b_new)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 4,
               activated_at: 204,
               skill_state_transitions: %{@skill_id => {:abandon, branch_a.branch_id}}
             )

    assert {:error, :active_skill_state_not_found} = Spectre.skill_state(instance, @skill_id)
    assert {:ok, branches} = Spectre.skill_state_branches(instance, @skill_id)
    assert Enum.find(branches, &(&1.branch_id == branch_a.branch_id)).retention == :abandoned

    assert {:error, {:skill_state_source_unavailable, branch_id, :migrate, :abandoned}} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 5,
               activated_at: 205,
               skill_state_transitions: %{
                 @skill_id =>
                   {:migrate, branch_a.branch_id, @schema_v2, %{"should" => "not commit"}}
               }
             )

    assert branch_id == branch_a.branch_id
    assert Spectre.activation(instance).generation == 5
    assert {:error, :active_skill_state_not_found} = Spectre.skill_state(instance, @skill_id)
  end

  test "retention is conservative, reference-safe and preserves purged tombstones" do
    store = definition_store()
    {definition_a, candidate_a, definition_b, candidate_b} = publish_lineage(store)
    instance = start_instance(store, "skill-retention")

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 0,
               activated_at: 300,
               skill_state_transitions: %{
                 @skill_id => {:init, @schema_v1, %{"owner" => "A"}}
               }
             )

    assert {:ok, branch_a} = Spectre.skill_state(instance, @skill_id)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 1,
               activated_at: 301,
               skill_state_transitions: %{
                 @skill_id => {:fork, @schema_v1, %{"owner" => "B"}}
               }
             )

    assert {:ok, branch_b} = Spectre.skill_state(instance, @skill_id)

    assert {:error, {:skill_state_retention_referenced, @skill_id, branch_a_id, :child_branch}} =
             Spectre.transition_skill_state_retention(
               instance,
               @skill_id,
               branch_a.branch_id,
               :gc_eligible,
               expected_revision: branch_a.revision + 1
             )

    assert branch_a_id == branch_a.branch_id

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 2,
               activated_at: 302,
               skill_state_transitions: %{@skill_id => {:resume, branch_a.branch_id}}
             )

    assert {:ok, branches} = Spectre.skill_state_branches(instance, @skill_id)
    dormant_b = Enum.find(branches, &(&1.branch_id == branch_b.branch_id))

    assert {:ok, gc_eligible} =
             Spectre.transition_skill_state_retention(
               instance,
               @skill_id,
               dormant_b.branch_id,
               :gc_eligible,
               expected_revision: dormant_b.revision,
               updated_at: 303
             )

    assert {:ok, purged} =
             Spectre.transition_skill_state_retention(
               instance,
               @skill_id,
               gc_eligible.branch_id,
               :purged,
               expected_revision: gc_eligible.revision,
               updated_at: 304
             )

    assert purged.state == nil
    assert purged.retention == :purged

    assert {:ok, visible} = Spectre.skill_state_branches(instance, @skill_id)
    refute Enum.any?(visible, &(&1.branch_id == purged.branch_id))

    assert {:ok, all} =
             Spectre.skill_state_branches(instance, @skill_id, include_purged?: true)

    assert Enum.find(all, &(&1.branch_id == purged.branch_id)).binding_receipt ==
             purged.binding_receipt

    assert {:ok, %Lifecycle{} = lifecycle_b} =
             Spectre.definition_lifecycle(instance, definition_b)

    assert {:ok, lifecycle_b} =
             Spectre.transition_definition_lifecycle(
               instance,
               definition_b,
               :retention,
               :gc_eligible,
               expected_revision: lifecycle_b.revision
             )

    assert {:ok, %Lifecycle{retention: :purged}} =
             Spectre.transition_definition_lifecycle(
               instance,
               definition_b,
               :retention,
               :purged,
               expected_revision: lifecycle_b.revision
             )

    assert definition_a == branch_a.owning_definition_ref
  end

  test "schema 3 checkpoint restores the selected branch and dormant history" do
    store = definition_store()
    {_definition_a, candidate_a, _definition_b, candidate_b} = publish_lineage(store)
    subject = Subject.new("skill-restart-#{System.unique_integer([:positive])}")
    instance = start_instance(store, subject)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_a,
               expected_generation: 0,
               activated_at: 400,
               skill_state_transitions: %{
                 @skill_id => {:init, @schema_v1, %{"checkpoint" => "A"}}
               }
             )

    assert {:ok, branch_a} = Spectre.skill_state(instance, @skill_id)

    assert {:ok, _activation} =
             Spectre.activate(instance, candidate_b,
               expected_generation: 1,
               activated_at: 401,
               skill_state_transitions: %{
                 @skill_id => {:fork, @schema_v1, %{"checkpoint" => "B"}}
               }
             )

    assert {:ok, branch_b} = Spectre.skill_state(instance, @skill_id)
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)

    assert %{
             "format" => "spectre/instance-checkpoint",
             "checkpoint_version" => 3,
             "state_schema_version" => 3
           } = Spectre.JSON.decode!(checkpoint)

    :ok = GenServer.stop(instance, :normal)

    {:ok, restarted} =
      Instance.start_link(
        agent: Agent,
        subject: subject,
        definition_store: store,
        canonical_checkpoint: checkpoint,
        idle: false
      )

    Process.unlink(restarted)

    assert {:ok, restored_b} = Spectre.skill_state(restarted, @skill_id)
    assert restored_b.branch_id == branch_b.branch_id
    assert restored_b.state == %{"checkpoint" => "B"}

    assert {:ok, restored_branches} = Spectre.skill_state_branches(restarted, @skill_id)
    assert Enum.any?(restored_branches, &(&1.branch_id == branch_a.branch_id))
    assert Enum.any?(restored_branches, &(&1.branch_id == branch_b.branch_id))
    :ok = GenServer.stop(restarted, :normal)
  end

  defp definition_store do
    id = {:skill_state_store, System.unique_integer([:positive])}
    server = start_supervised!({Spectre.Definition.Store.Memory, id: id})
    {Spectre.Definition.Store.Memory, server: server}
  end

  defp publish_lineage(store) do
    base = Definition.canonical!(Agent)
    definition_a = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 251))
    definition_b = Canonical.new!(Map.put(Map.from_struct(base), :declared_version, 252))
    closure = closure()
    manifest_a = Manifest.new!(definition_a, AuthorityEnvelope.empty(), closure)

    manifest_b =
      Manifest.new!(definition_b, AuthorityEnvelope.empty(), closure,
        parent_refs: [Canonical.ref(definition_a)]
      )

    assert {:ok, _receipt} = Store.publish(store, definition_a, manifest_a)

    assert {:ok, candidate_a} =
             Resolver.bootstrap_candidate(store, Canonical.ref(definition_a),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, _receipt} = Store.publish(store, definition_b, manifest_b)

    assert {:ok, candidate_b} =
             Resolver.bootstrap_candidate(store, Canonical.ref(definition_b),
               source: :compiled,
               parent_ref: candidate_a,
               created_at: 2
             )

    {Canonical.ref(definition_a), candidate_a, Canonical.ref(definition_b), candidate_b}
  end

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
      evaluation_corpus_digest: nil,
      compatibility_mode: :native_v2
    })
  end

  defp start_instance(store, %Subject{} = subject) do
    {:ok, instance} =
      Instance.start_link(agent: Agent, subject: subject, definition_store: store, idle: false)

    Process.unlink(instance)
    instance
  end

  defp start_instance(store, suffix) do
    subject = Subject.new("#{suffix}-#{System.unique_integer([:positive])}")
    instance = start_instance(store, subject)
    on_exit(fn -> if Process.alive?(instance), do: GenServer.stop(instance, :normal) end)
    instance
  end
end
