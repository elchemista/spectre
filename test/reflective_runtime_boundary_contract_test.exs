defmodule SpectreReflectiveRuntimeBoundaryContractTest.MigrationStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    Agent.get(Keyword.fetch!(opts, :server), fn entries ->
      case Map.fetch(entries, ref.key) do
        {:ok, checkpoint} -> {:ok, checkpoint}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def migrate_instance_key(_legacy, stable, _legacy_checkpoint, migrated, opts) do
    opts
    |> Keyword.get(:mode, :ok)
    |> migrate(stable, migrated, Keyword.fetch!(opts, :server))
  end

  defp migrate(mode, stable, migrated, server) when mode in [:ok, :moved, :aliased] do
    Agent.update(server, &Map.put(&1, stable.key, migrated))
    migration_status(mode)
  end

  defp migrate(:different, stable, _migrated, server) do
    Agent.update(server, &Map.put(&1, stable.key, "different"))
    :ok
  end

  defp migrate(:invisible, _stable, _migrated, _server), do: :ok
  defp migrate(:error, _stable, _migrated, _server), do: {:error, :migration_rejected}
  defp migrate(:invalid, _stable, _migrated, _server), do: :committed_maybe
  defp migrate(:raise, _stable, _migrated, _server), do: raise("migration crashed")
  defp migrate(:throw, _stable, _migrated, _server), do: throw(:migration_threw)

  defp migration_status(:ok), do: :ok
  defp migration_status(status), do: {:ok, status}
end

defmodule SpectreReflectiveRuntimeBoundaryContractTest.NoMigrationStore do
  @moduledoc false
end

defmodule SpectreReflectiveRuntimeBoundaryContractTest.MigrationAgent do
  @moduledoc false
  use Spectre.Agent, id: :reflective_boundary_migration_agent
end

defmodule SpectreReflectiveRuntimeBoundaryContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Event.Envelope
  alias Spectre.Instance.Activation
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Run.Ref, as: RunRef
  alias Spectre.Skill.StateBinding
  alias Spectre.Subject
  alias SpectreReflectiveRuntimeBoundaryContractTest.MigrationStore
  alias SpectreReflectiveRuntimeBoundaryContractTest.MigrationAgent
  alias SpectreReflectiveRuntimeBoundaryContractTest.NoMigrationStore

  @digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)

  test "owner leases reject invalid durable fences and expire at the exact boundary" do
    assert {:ok, lease} =
             Lease.new(
               owner_id: "node-a",
               fencing_token: 7,
               issued_at: 100,
               expires_at: 120,
               metadata: %{"region" => "eu"}
             )

    assert Lease.current?(lease, 100)
    assert Lease.current?(lease, 119)
    refute Lease.current?(lease, 120)
    assert Lease.current?(%{lease | expires_at: nil}, 10_000)

    invalid = [
      {%{owner_id: "node", fencing_token: 1, issued_at: 0, schema_version: 2},
       {:unsupported_owner_lease_schema, 2}},
      {%{owner_id: "", fencing_token: 1, issued_at: 0},
       {:invalid_owner_lease_field, :owner_id, ""}},
      {%{owner_id: "node", fencing_token: 0, issued_at: 0},
       {:invalid_owner_lease_field, :fencing_token, 0}},
      {%{owner_id: "node", fencing_token: 1, issued_at: -1},
       {:invalid_owner_lease_field, :issued_at, -1}},
      {%{owner_id: "node", fencing_token: 1, issued_at: 5, expires_at: 5},
       {:invalid_owner_lease_field, :expires_at, 5}},
      {%{owner_id: "node", fencing_token: 1, issued_at: 5, expires_at: "later"},
       {:invalid_owner_lease_field, :expires_at, "later"}},
      {%{owner_id: "node", fencing_token: 1, issued_at: 0, metadata: []},
       {:invalid_owner_lease_field, :metadata, :list}}
    ]

    Enum.each(invalid, fn {attrs, reason} ->
      assert {:error, ^reason} = Lease.new(attrs)
    end)

    assert {:error, {:nonportable_owner_lease_metadata, _reason}} =
             Lease.new(owner_id: "node", fencing_token: 1, issued_at: 0, metadata: %{pid: self()})

    assert {:error, {:invalid_instance_owner_lease, :atom}} = Lease.new(:invalid)

    assert_raise ArgumentError, ~r/invalid Instance owner lease/, fn ->
      Lease.new!(owner_id: nil, fencing_token: 1, issued_at: 0)
    end
  end

  test "Activation transport and CAS reject stale generation, authority and owner fences" do
    assert Activation.schema_version() == 1
    first = activation(1, authority_epoch: 3, owner_fencing_token: 10)

    assert Activation.generation(nil) == 0
    assert Activation.authority_epoch(nil) == 0
    assert Activation.generation(first) == 1
    assert Activation.authority_epoch(first) == 3
    assert {:ok, ^first} = Activation.compare_and_swap(nil, 0, first)
    assert {:ok, encoded} = Activation.encode(first)
    assert {:ok, ^first} = Activation.decode(encoded)
    assert {:ok, ^first} = first |> Activation.to_data() |> Activation.from_data()

    second = activation(2, authority_epoch: 4, owner_fencing_token: 11)
    assert {:ok, ^second} = Activation.compare_and_swap(first, 1, second)

    assert {:error, {:stale_activation_generation, 0, 1}} =
             Activation.compare_and_swap(first, 0, second)

    invalid_generation = activation(3, authority_epoch: 4, owner_fencing_token: 11)

    assert {:error, {:invalid_activation_generation, 3, 2}} =
             Activation.compare_and_swap(first, 1, invalid_generation)

    stale_epoch = activation(2, authority_epoch: 2, owner_fencing_token: 11)

    assert {:error, {:stale_authority_epoch, 2, 3}} =
             Activation.compare_and_swap(first, 1, stale_epoch)

    stale_owner = activation(2, authority_epoch: 3, owner_fencing_token: 9)

    assert {:error, {:stale_owner_fencing_token, 9, 10}} =
             Activation.compare_and_swap(first, 1, stale_owner)

    assert {:error, {:invalid_activation_compare_and_swap, -1}} =
             Activation.compare_and_swap(first, -1, second)

    assert {:error, {:invalid_instance_activation_binary, :list}} = Activation.decode([])
    assert {:error, {:invalid_instance_activation_data, :atom}} = Activation.from_data(:bad)
    assert {:error, {:invalid_instance_activation, :tuple}} = Activation.build({:bad})

    base = first |> Map.from_struct() |> Map.delete(:activation_receipt)

    invalid = [
      {Map.put(base, :schema_version, 2), {:unsupported_instance_activation_schema, 2}},
      {Map.put(base, :definition_ref, nil), :invalid_activation_definition_ref},
      {Map.put(base, :candidate_ref, nil), :invalid_activation_candidate_ref},
      {Map.put(base, :manifest_digest, "short"),
       {:invalid_activation_digest, :manifest_digest, "short"}},
      {Map.put(base, :publication_id, ""), {:invalid_activation_field, :publication_id, ""}},
      {Map.put(base, :closure_digest, String.upcase(@digest)), :invalid_activation_digest},
      {Map.put(base, :state_bindings, []), {:invalid_activation_field, :state_bindings, :list}},
      {Map.put(base, :generation, 0), {:invalid_activation_field, :generation, 0}},
      {Map.put(base, :authority_epoch, -1), {:invalid_activation_field, :authority_epoch, -1}},
      {Map.put(base, :owner_fencing_token, 0),
       {:invalid_activation_field, :owner_fencing_token, 0}},
      {Map.put(base, :activated_at, -1), {:invalid_activation_field, :activated_at, -1}},
      {Map.put(base, :provenance, []), {:invalid_activation_field, :provenance, :list}}
    ]

    Enum.each(invalid, fn {attrs, reason} ->
      assert {:error, ^reason} = Activation.build(attrs)
    end)

    assert {:error, {:nonportable_activation_field, :state_bindings, _}} =
             Activation.build(Map.put(base, :state_bindings, %{callback: fn -> :ok end}))

    assert {:error, {:unknown_instance_activation_fields, [:unknown]}} =
             Activation.build(Map.put(base, :unknown, true))

    assert {:error, {:activation_receipt_mismatch, "forged", _expected}} =
             Activation.build(Map.put(base, :activation_receipt, "forged"))
  end

  test "Definition lifecycle enforces all four independent monotonic axes" do
    definition_ref = definition_ref()
    assert Lifecycle.schema_version() == 1

    lifecycle =
      Lifecycle.new!(
        definition_ref: definition_ref,
        activation: :active,
        changed_at: 10,
        provenance: %{"source" => "test"}
      )

    assert Lifecycle.key(lifecycle) == DefinitionRef.to_string(definition_ref)
    assert Lifecycle.fetch(%{}, definition_ref).activation == :inactive
    assert Lifecycle.fetch(%{}, definition_ref, activation: :active).activation == :active
    assert :ok = Lifecycle.authorize(lifecycle, :new_admission)
    assert :ok = Lifecycle.authorize(lifecycle, :continuation)
    assert :ok = Lifecycle.authorize(lifecycle, :dispatch)
    assert :ok = Lifecycle.authorize(lifecycle, :commit)
    assert {:ok, ^lifecycle} = Lifecycle.transition(lifecycle, :admission, :accepting)

    assert {:ok, draining} =
             Lifecycle.transition(lifecycle, :admission, :draining,
               expected_revision: 0,
               changed_at: 11,
               reason: :maintenance
             )

    assert draining.revision == 1

    assert {:error, {:definition_admission_blocked, _, :draining}} =
             Lifecycle.authorize(draining, :new_admission)

    assert :ok = Lifecycle.authorize(draining, :continuation)

    assert {:error, {:lifecycle_transition_not_authorized, :authorize_reopen?}} =
             Lifecycle.transition(draining, :admission, :accepting)

    assert {:ok, reopened} =
             Lifecycle.transition(draining, :admission, :accepting, authorize_reopen?: true)

    assert {:error, {:stale_definition_lifecycle, 0, 2}} =
             Lifecycle.transition(reopened, :admission, :closed, expected_revision: 0)

    assert {:ok, closed} = Lifecycle.transition(reopened, :admission, :closed)

    assert {:error, {:definition_continuation_closed, _}} =
             Lifecycle.authorize(closed, :continuation)

    assert {:error, {:invalid_admission_transition, :closed, :accepting}} =
             Lifecycle.transition(closed, :admission, :accepting, authorize_reopen?: true)

    assert {:ok, restricted} =
             Lifecycle.transition(lifecycle, :authority, :restricted, authority_epoch: 4)

    assert restricted.authority_epoch == 4

    for operation <- [:new_admission, :dispatch] do
      assert {:error, {:definition_authority_restricted, _, 4, ^operation}} =
               Lifecycle.authorize(restricted, operation)
    end

    assert :ok = Lifecycle.authorize(restricted, :continuation)
    assert :ok = Lifecycle.authorize(restricted, :commit)

    assert {:error, {:lifecycle_transition_not_authorized, :authorize_restore?}} =
             Lifecycle.transition(restricted, :authority, :granted)

    assert {:ok, restored} =
             Lifecycle.transition(restricted, :authority, :granted,
               authorize_restore?: true,
               authority_epoch: 5
             )

    assert restored.authority_epoch == 5

    assert {:error, {:stale_lifecycle_authority_epoch, 5, 5}} =
             Lifecycle.transition(restored, :authority, :revoked, authority_epoch: 5)

    assert {:ok, revoked} = Lifecycle.transition(restored, :authority, :revoked)

    assert {:error, {:definition_authority_revoked, _, 6, :commit}} =
             Lifecycle.authorize(revoked, :commit)

    assert {:ok, inactive} = Lifecycle.transition(lifecycle, :activation, :inactive)

    assert {:error, {:definition_not_active, _}} =
             Lifecycle.authorize(inactive, :new_admission)

    assert {:ok, eligible} =
             inactive
             |> Lifecycle.transition(:retention, :gc_eligible)

    assert {:ok, purged} = Lifecycle.transition(eligible, :retention, :purged)

    assert {:error, {:definition_retention_purged, _}} = Lifecycle.authorize(purged, :commit)

    assert {:error, {:invalid_retention_transition, :purged, :retained}} =
             Lifecycle.transition(purged, :retention, :retained)

    assert {:error, {:invalid_definition_lifecycle_transition, :unknown, :state}} =
             Lifecycle.transition(lifecycle, :unknown, :state)

    assert {:ok, encoded_data} = lifecycle |> Lifecycle.to_data() |> Jason.encode()
    assert {:ok, restored_data} = encoded_data |> Jason.decode!() |> Lifecycle.from_data()
    assert restored_data == lifecycle

    Enum.each(
      [
        {"admission", "invented", {:invalid_definition_lifecycle_field, :admission, "invented"}},
        {"authority", "invented", {:invalid_definition_lifecycle_field, :authority, "invented"}},
        {"retention", "invented", {:invalid_definition_lifecycle_field, :retention, "invented"}},
        {"activation", "invented", {:invalid_definition_lifecycle_field, :activation, "invented"}}
      ],
      fn {field, value, reason} ->
        assert {:error, ^reason} =
                 lifecycle
                 |> Lifecycle.to_data()
                 |> Map.put(field, value)
                 |> Lifecycle.from_data()
      end
    )

    assert {:error, {:invalid_definition_lifecycle_data, :list}} = Lifecycle.from_data([])
    assert {:error, {:invalid_definition_lifecycle, :tuple}} = Lifecycle.new({:invalid})

    assert {:error, {:unknown_definition_lifecycle_fields, [:unknown]}} =
             lifecycle |> Map.from_struct() |> Map.put(:unknown, true) |> Lifecycle.new()
  end

  test "Definition activation moves the lifecycle fence without reviving revoked data" do
    first = activation(1, authority_epoch: 1, owner_fencing_token: 10)
    second = activation(2, authority_epoch: 2, owner_fencing_token: 11)

    assert {:ok, lifecycles} = Lifecycle.activate(%{}, nil, first, changed_at: 101)
    first_lifecycle = Map.fetch!(lifecycles, DefinitionRef.to_string(first.definition_ref))
    assert first_lifecycle.activation == :active
    assert first_lifecycle.authority_epoch == 1

    assert {:ok, same_definition} = Lifecycle.activate(lifecycles, first, second)
    assert Map.fetch!(same_definition, Lifecycle.key(first_lifecycle)).activation == :active

    other =
      activation(3,
        authority_epoch: 3,
        owner_fencing_token: 12,
        definition_ref: definition_ref(@other_digest)
      )

    assert {:ok, switched} = Lifecycle.activate(same_definition, second, other, changed_at: 103)
    previous = Map.fetch!(switched, DefinitionRef.to_string(first.definition_ref))
    current = Map.fetch!(switched, DefinitionRef.to_string(other.definition_ref))
    assert {previous.activation, previous.admission} == {:inactive, :draining}
    assert {current.activation, current.admission} == {:active, :accepting}

    assert {:ok, closed} = Lifecycle.transition(previous, :admission, :closed)
    assert closed.admission == :closed

    assert {:ok, restricted} = Lifecycle.transition(current, :authority, :restricted)
    assert {:ok, revoked} = Lifecycle.transition(restricted, :authority, :revoked)

    assert {:error, {:definition_authority_revoked, _, _, :activation}} =
             Lifecycle.activate(Map.put(switched, Lifecycle.key(revoked), revoked), nil, other)

    assert {:ok, inactive} = Lifecycle.transition(current, :activation, :inactive)
    assert {:ok, eligible} = Lifecycle.transition(inactive, :retention, :gc_eligible)
    assert {:ok, purged} = Lifecycle.transition(eligible, :retention, :purged)

    assert {:error, {:definition_retention_purged, _}} =
             Lifecycle.activate(Map.put(switched, Lifecycle.key(purged), purged), nil, other)

    assert {:error, {:invalid_authority_transition, :granted, :unknown}} =
             Lifecycle.transition(current, :authority, :unknown)

    for lifecycle <- [previous, closed, restricted, revoked, eligible, purged] do
      assert {:ok, restored} = lifecycle |> Lifecycle.to_data() |> Lifecycle.from_data()
      assert restored == lifecycle
    end

    base = current |> Map.from_struct()

    invalid = [
      {Map.put(base, :definition_ref, "invalid"), {:invalid_lifecycle_definition_ref, "invalid"}},
      {Map.put(base, :schema_version, 2), {:unsupported_definition_lifecycle_schema, 2}},
      {Map.put(base, :revision, -1), {:invalid_definition_lifecycle_field, :revision, -1}},
      {Map.put(base, :provenance, []), {:invalid_definition_lifecycle_field, :provenance, :list}}
    ]

    Enum.each(invalid, fn {attrs, reason} ->
      assert {:error, ^reason} = Lifecycle.new(attrs)
    end)

    assert {:error, {:nonportable_definition_lifecycle_field, :reason, _}} =
             Lifecycle.new(Map.put(base, :reason, self()))

    assert {:error, {:invalid_definition_lifecycle_data, :binary}} =
             Lifecycle.from_data("invalid")

    assert {:error, {:invalid_definition_lifecycle, :other}} = Lifecycle.new(1.5)

    assert_raise ArgumentError, ~r/invalid Definition lifecycle/, fn ->
      Lifecycle.new!(definition_ref: nil)
    end
  end

  test "event envelopes prove ownership receipts across every class and continuation kind" do
    definition_ref = definition_ref()
    assert Envelope.schema_version() == 1

    Enum.each(Envelope.classes(), fn event_class ->
      pending = pending_event(event_class)
      assert pending.class_ref == "spectre.event/#{event_class}/1"
      refute Envelope.admitted?(pending)
      assert {:ok, ^pending} = pending |> Envelope.to_data() |> Envelope.from_data()
    end)

    run_refs =
      Enum.map([:reply, :policy, :invocation, :complete, :error], fn kind ->
        %RunRef{
          run_id: "run-#{kind}",
          revision: 2,
          kind: kind,
          boundary_id: "boundary-#{kind}",
          subject_id: "subject"
        }
      end)

    operation_refs =
      Enum.map([:work, :vigil, :directive], fn kind ->
        %OperationRef{
          id: "operation-#{kind}",
          kind: kind,
          subject_id: "subject",
          correlation_id: "correlation-#{kind}"
        }
      end)

    Enum.each(run_refs ++ operation_refs, fn continuation ->
      pending = pending_event(:flow_progress, continuation_ref: continuation)
      assert {:ok, encoded} = Envelope.encode(pending)
      assert {:ok, ^pending} = Envelope.decode(encoded)
    end)

    pending =
      pending_event(:work_completion,
        origin_definition_ref: definition_ref,
        causation_id: "cause"
      )

    intent = Envelope.intent_digest(pending)

    assert {:ok, admitted} =
             Envelope.admit(pending,
               owner_definition_ref: definition_ref,
               admitted_activation_generation: 2,
               authority_epoch: 3,
               owner_fencing_token: 4,
               admission_revision: 5,
               status: :admitted,
               admitted_at: 20
             )

    assert Envelope.admitted?(admitted)
    assert Envelope.intent_digest(admitted) == intent
    assert is_binary(admitted.admission_receipt)
    assert {:ok, ^admitted} = admitted |> Envelope.to_data() |> Envelope.from_data()

    admitted_id = admitted.id

    assert {:error, {:event_already_admitted, ^admitted_id, :admitted}} =
             Envelope.admit(admitted, %{})

    assert {:error, {:invalid_event_admission, :list}} = Envelope.admit(pending, [:not_keyword])

    assert {:ok, quarantined} =
             Envelope.admit(pending,
               owner_definition_ref: nil,
               admitted_activation_generation: 2,
               authority_epoch: 3,
               owner_fencing_token: 4,
               admission_revision: 6,
               status: :quarantined,
               quarantine_reason: :unknown_continuation,
               admitted_at: 21
             )

    assert Envelope.admitted?(quarantined)
    assert quarantined.owner_definition_ref == nil

    assert {:error, :pending_event_has_admission_fields} =
             pending |> Map.from_struct() |> Map.put(:authority_epoch, 1) |> Envelope.new()

    assert {:error, {:pending_event_has_admission_receipt, "forged"}} =
             pending
             |> Map.from_struct()
             |> Map.put(:admission_receipt, "forged")
             |> Envelope.new()

    admitted_attrs = admitted |> Map.from_struct() |> Map.put(:admission_receipt, nil)

    assert {:error, {:invalid_event_owner, :admitted, nil}} =
             admitted_attrs |> Map.put(:owner_definition_ref, nil) |> Envelope.new()

    assert {:error, {:admitted_event_has_quarantine_reason, :bad}} =
             admitted_attrs |> Map.put(:quarantine_reason, :bad) |> Envelope.new()

    assert {:error, :quarantined_event_requires_reason} =
             admitted_attrs
             |> Map.put(:status, :quarantined)
             |> Map.put(:quarantine_reason, nil)
             |> Envelope.new()

    assert {:error, {:event_admission_receipt_mismatch, "forged", _}} =
             admitted
             |> Map.from_struct()
             |> Map.put(:admission_receipt, "forged")
             |> Envelope.new()

    malformed_data = Envelope.to_data(pending)

    assert {:error, {:invalid_event_envelope_data_fields, _}} =
             malformed_data |> Map.delete("payload") |> Envelope.from_data()

    assert {:error, {:invalid_event_continuation_data, :map}} =
             malformed_data
             |> Map.put("continuation_ref", %{"type" => "unknown"})
             |> Envelope.from_data()

    assert {:error, {:invalid_event_run_kind, "unknown"}} =
             malformed_data
             |> Map.put("continuation_ref", %{
               "type" => "run",
               "run_id" => "run",
               "revision" => 0,
               "kind" => "unknown",
               "boundary_id" => "boundary",
               "subject_id" => nil
             })
             |> Envelope.from_data()

    assert {:error, {:invalid_event_operation_kind, "unknown"}} =
             malformed_data
             |> Map.put("continuation_ref", %{
               "type" => "operation",
               "id" => "op",
               "kind" => "unknown",
               "subject_id" => "subject",
               "correlation_id" => nil
             })
             |> Envelope.from_data()

    assert {:error, {:invalid_event_envelope_binary, :atom}} = Envelope.decode(:bad)
    assert {:error, {:invalid_event_envelope_data, :list}} = Envelope.from_data([])
    assert {:error, {:invalid_event_envelope, :tuple}} = Envelope.new({:bad})
  end

  test "Skill state transport binds schema, owner, generation, revision, fence and retention" do
    definition_ref = definition_ref()
    other_ref = definition_ref(@other_digest)
    assert StateBinding.schema_version() == 1

    binding =
      StateBinding.new!(
        skill_id: "learner",
        state_schema_ref: "spectre.test/learner/1",
        state_generation: 1,
        branch_id: "branch-a",
        owning_definition_ref: definition_ref,
        fencing_token: 5,
        state: %{"facts" => ["refunds"]},
        created_at: 10,
        updated_at: 10
      )

    assert StateBinding.activation_pointer?(StateBinding.activation_pointer(binding))
    refute StateBinding.activation_pointer?(%{"kind" => "other"})
    assert {:ok, encoded} = StateBinding.encode(binding)
    assert {:ok, ^binding} = StateBinding.decode(encoded)
    assert {:ok, ^binding} = binding |> StateBinding.to_data() |> StateBinding.from_data()

    update_opts = [
      expected_generation: 1,
      expected_revision: 0,
      state_schema_ref: "spectre.test/learner/1",
      owning_definition_ref: definition_ref,
      fencing_token: 6,
      updated_at: 11
    ]

    assert {:ok, updated} =
             StateBinding.update(binding, %{"facts" => ["refunds", "returns"]}, update_opts)

    assert updated.revision == 1
    assert updated.fencing_token == 6

    assert {:error, {:stale_skill_state_generation, nil, 1}} =
             StateBinding.update(binding, %{}, Keyword.delete(update_opts, :expected_generation))

    assert {:error, {:stale_skill_state_revision, nil, 0}} =
             StateBinding.update(binding, %{}, Keyword.delete(update_opts, :expected_revision))

    assert {:error, :skill_state_schema_ref_required} =
             StateBinding.update(binding, %{}, Keyword.put(update_opts, :state_schema_ref, nil))

    assert {:error, :skill_state_owner_required} =
             StateBinding.update(
               binding,
               %{},
               Keyword.put(update_opts, :owning_definition_ref, nil)
             )

    assert {:error, {:skill_state_owner_violation, _}} =
             StateBinding.update(
               binding,
               %{},
               Keyword.put(update_opts, :owning_definition_ref, other_ref)
             )

    assert {:error, {:invalid_skill_state_owner, "owner"}} =
             StateBinding.update(
               binding,
               %{},
               Keyword.put(update_opts, :owning_definition_ref, "owner")
             )

    assert {:error, {:stale_skill_state_fence, 4, 5}} =
             StateBinding.update(binding, %{}, Keyword.put(update_opts, :fencing_token, 4))

    assert {:error, {:invalid_skill_state_options, :map}} =
             StateBinding.update(binding, %{}, %{})

    assert {:ok, dormant} =
             StateBinding.transition_status(binding, :dormant,
               expected_revision: 0,
               fencing_token: 5,
               updated_at: 11
             )

    assert {:ok, ^dormant} =
             StateBinding.transition_status(dormant, :dormant,
               expected_revision: 1,
               fencing_token: 5
             )

    assert {:error, {:skill_state_not_mutable, :dormant, :retained}} =
             StateBinding.update(dormant, %{},
               expected_generation: 1,
               expected_revision: 1,
               state_schema_ref: "spectre.test/learner/1",
               owning_definition_ref: definition_ref,
               fencing_token: 5
             )

    assert {:error, {:invalid_skill_state_status, :paused}} =
             StateBinding.transition_status(binding, :paused, [])

    assert {:error, :active_skill_state} =
             StateBinding.transition_retention(binding, :gc_eligible,
               expected_revision: 0,
               fencing_token: 5
             )

    assert {:ok, abandoned} =
             StateBinding.transition_retention(dormant, :abandoned,
               expected_revision: 1,
               fencing_token: 6,
               updated_at: 12
             )

    assert {:error, {:skill_state_not_retained, :abandoned}} =
             StateBinding.transition_status(abandoned, :active,
               expected_revision: 2,
               fencing_token: 6
             )

    assert {:ok, eligible} =
             StateBinding.transition_retention(abandoned, :gc_eligible,
               expected_revision: 2,
               fencing_token: 7,
               updated_at: 13
             )

    assert {:ok, purged} =
             StateBinding.transition_retention(eligible, :purged,
               expected_revision: 3,
               fencing_token: 8,
               updated_at: 14
             )

    assert purged.state == nil
    assert purged.status == :dormant

    assert {:ok, ^purged} =
             StateBinding.transition_retention(purged, :purged,
               expected_revision: 4,
               fencing_token: 8
             )

    assert {:error, {:invalid_skill_state_retention_transition, :purged, :retained}} =
             StateBinding.transition_retention(purged, :retained,
               expected_revision: 4,
               fencing_token: 8
             )

    assert {:error, {:invalid_skill_state_retention, :deleted}} =
             StateBinding.transition_retention(binding, :deleted, [])

    base = binding |> Map.from_struct() |> Map.delete(:binding_receipt)

    invalid = [
      {Map.put(base, :schema_version, 2), {:unsupported_skill_state_binding_schema, 2}},
      {Map.put(base, :skill_id, ""), {:invalid_skill_state_field, :skill_id, ""}},
      {Map.put(base, :state_generation, 0), {:invalid_skill_state_field, :state_generation, 0}},
      {Map.put(base, :parent_branch_id, "branch-a"), :skill_state_self_parent},
      {Map.put(base, :fencing_token, 0), {:invalid_skill_state_field, :fencing_token, 0}},
      {Map.put(base, :status, :paused), {:invalid_skill_state_field, :status, :paused}},
      {Map.put(base, :retention, :deleted), {:invalid_skill_state_field, :retention, :deleted}},
      {Map.put(base, :updated_at, 9), {:invalid_skill_state_timestamps, 10, 9}},
      {Map.put(base, :provenance, []), {:invalid_skill_state_field, :provenance, :list}},
      {base |> Map.put(:status, :active) |> Map.put(:retention, :gc_eligible),
       {:invalid_skill_state_lifecycle, :active, :gc_eligible}}
    ]

    Enum.each(invalid, fn {attrs, reason} ->
      assert {:error, ^reason} = StateBinding.new(attrs)
    end)

    assert {:error, {:skill_state_binding_receipt_mismatch, "forged", _}} =
             StateBinding.new(Map.put(base, :binding_receipt, "forged"))

    assert {:error, {:invalid_skill_state_binding_binary, :list}} = StateBinding.decode([])
    assert {:error, {:invalid_skill_state_binding_data, :atom}} = StateBinding.from_data(:bad)
    assert {:error, {:invalid_skill_state_binding, :tuple}} = StateBinding.new({:bad})

    invalid_data = binding |> StateBinding.to_data() |> Map.put("status", "paused")

    assert {:error, {:invalid_skill_state_status, "paused"}} =
             StateBinding.from_data(invalid_data)

    invalid_data = binding |> StateBinding.to_data() |> Map.put("retention", "deleted")

    assert {:error, {:invalid_skill_state_retention, "deleted"}} =
             StateBinding.from_data(invalid_data)
  end

  test "checkpoint key migration is atomic, read back and ambiguity-safe" do
    {:ok, server} = Agent.start_link(fn -> %{} end)
    legacy = InstanceRef.new(MigrationAgent, Subject.new("legacy"))
    stable = InstanceRef.new(MigrationAgent, Subject.new("stable"))
    store = {MigrationStore, server: server}

    assert :ok =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               %{"checkpoint_version" => 1},
               "migrated",
               mode: :ok
             )

    for mode <- [:moved, :aliased] do
      Agent.update(server, fn _ -> %{} end)

      assert :ok =
               CheckpointStore.migrate_instance_key(
                 store,
                 legacy,
                 stable,
                 "legacy",
                 "migrated",
                 mode: mode
               )
    end

    Agent.update(server, fn _ -> %{} end)

    assert {:error, :instance_key_migration_readback_mismatch} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :different
             )

    Agent.update(server, fn _ -> %{} end)

    assert {:error, :instance_key_migration_not_visible} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :invisible
             )

    assert {:error, :migration_rejected} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :error
             )

    assert {:error,
            {:ambiguous, {:invalid_checkpoint_migration_reply, MigrationStore, :committed_maybe}}} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :invalid
             )

    assert {:error,
            {:ambiguous, {:instance_key_migration_exception, MigrationStore, RuntimeError}}} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :raise
             )

    assert {:error,
            {:ambiguous,
             {:instance_key_migration_failure, MigrationStore, :throw, :migration_threw}}} =
             CheckpointStore.migrate_instance_key(
               store,
               legacy,
               stable,
               "legacy",
               "migrated",
               mode: :throw
             )

    assert {:error,
            {:checkpoint_store_callback_missing, NoMigrationStore, :migrate_instance_key, 5}} =
             CheckpointStore.migrate_instance_key(
               {NoMigrationStore, []},
               legacy,
               stable,
               "legacy",
               "migrated",
               []
             )

    unloaded = SpectreReflectiveRuntimeBoundaryContractTest.UnloadedMigrationStore

    assert {:error, {:checkpoint_store_not_loaded, ^unloaded}} =
             CheckpointStore.migrate_instance_key(
               {unloaded, []},
               legacy,
               stable,
               "legacy",
               "migrated",
               []
             )
  end

  defp definition_ref(digest \\ @digest) do
    {:ok, ref} = DefinitionRef.parse("sha256:" <> digest)
    ref
  end

  defp candidate_ref do
    {:ok, ref} = CandidateRef.parse("candidate:sha256:" <> @digest)
    ref
  end

  defp activation(generation, opts) do
    attrs = %{
      definition_ref: Keyword.get(opts, :definition_ref, definition_ref()),
      candidate_ref: candidate_ref(),
      manifest_digest: @digest,
      publication_id: "publication-#{generation}",
      closure_digest: @other_digest,
      state_bindings: %{},
      generation: generation,
      authority_epoch: Keyword.fetch!(opts, :authority_epoch),
      owner_fencing_token: Keyword.fetch!(opts, :owner_fencing_token),
      activated_at: 100 + generation,
      provenance: %{"test" => true}
    }

    {:ok, activation} = Activation.build(attrs)
    activation
  end

  defp pending_event(event_class, opts \\ []) do
    defaults = [
      id: "event-#{event_class}-#{System.unique_integer([:positive])}",
      event_class: event_class,
      correlation_id: "correlation-#{event_class}",
      payload_schema_ref: "spectre.test/#{event_class}/1",
      payload: %{"event" => Atom.to_string(event_class)},
      emitted_at: 10
    ]

    Envelope.new!(Keyword.merge(defaults, opts))
  end
end
