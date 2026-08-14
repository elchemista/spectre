defmodule SpectreInstanceEventsSkillStatesInternalTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :instance_events_skill_states_internal_agent
end

defmodule SpectreInstanceEventsSkillStatesInternalTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Event.Envelope
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Events
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Skill.StateBinding
  alias Spectre.State
  alias Spectre.Subject

  alias SpectreInstanceEventsSkillStatesInternalTest.Agent

  @digest_a String.duplicate("a", 64)
  @digest_b String.duplicate("b", 64)

  test "Event reads and lifecycle epochs fail closed on malformed canonical sections" do
    data = instance_state()

    corrupt_events = put_section(data, :event_admissions, :corrupt)
    assert Events.list(corrupt_events, :admitted) == []

    target = definition_ref(@digest_a)

    lifecycle =
      Lifecycle.new!(
        definition_ref: target,
        authority_epoch: 4,
        changed_at: 1
      )

    mixed_lifecycles = %{
      Lifecycle.key(target) => lifecycle,
      "malformed" => %{authority_epoch: 999}
    }

    assert 4 ==
             data
             |> put_section(:lifecycles, mixed_lifecycles)
             |> Events.current_authority_epoch()

    assert 0 ==
             data
             |> put_section(:lifecycles, [])
             |> Events.current_authority_epoch()

    assert {:error, {:invalid_event_class, nil}} =
             Events.admit(data, struct(Envelope), [])

    assert {:error, {:invalid_definition_lifecycle_transition, :activation, :active}} =
             Events.transition_lifecycle(data, target, :activation, :active, [])
  end

  test "Event continuation ownership rejects cross-family references and reports ambiguity" do
    data = instance_state()
    detached_loop = operation_loop(:work, definition_ref(@digest_a), id: "detached")

    wrong_run_ref =
      pending_event("reply-with-operation-ref", :reply,
        continuation_ref: OperationRef.from_loop(detached_loop)
      )

    assert {:ok, wrong_run, data} = Events.admit(data, wrong_run_ref, admitted_at: 10)
    assert wrong_run.status == :quarantined
    assert wrong_run.quarantine_reason == :invalid_continuation_class

    detached_run = waiting_run("detached-run", "detached-run-correlation", :reply)

    wrong_operation_ref =
      pending_event("work-with-run-ref", :work_progress,
        continuation_ref: detached_run.waiting.ref
      )

    assert {:ok, wrong_operation, data} =
             Events.admit(data, wrong_operation_ref, admitted_at: 11)

    assert wrong_operation.status == :quarantined
    assert wrong_operation.quarantine_reason == :invalid_continuation_class

    idle_run =
      Run.new(Agent, Spectre.Input.new("idle"), %State{},
        run_id: "idle-run",
        correlation_id: "implicit-missing"
      )

    implicit_missing =
      pending_event("implicit-run-missing", :reply, correlation_id: "implicit-missing")

    assert {:ok, missing, data} =
             Events.admit(%{data | runs: %{idle_run.id => idle_run}}, implicit_missing,
               admitted_at: 12
             )

    assert missing.quarantine_reason == :continuation_not_found

    reply_run = waiting_run("reply-run", "reply-correlation", :reply)
    implicit_reply = pending_event("implicit-reply", :reply, correlation_id: "reply-correlation")

    assert {:ok, admitted_reply, data} =
             Events.admit(%{data | runs: %{reply_run.id => reply_run}}, implicit_reply,
               admitted_at: 13
             )

    assert admitted_reply.status == :admitted
    assert admitted_reply.continuation_ref == reply_run.waiting.ref

    invocation_run = invocation_run("invocation-run", "flow-correlation")

    implicit_flow =
      pending_event("implicit-flow", :flow_progress, correlation_id: "flow-correlation")

    assert {:ok, admitted_flow, data} =
             Events.admit(%{data | runs: %{invocation_run.id => invocation_run}}, implicit_flow,
               admitted_at: 14
             )

    assert admitted_flow.status == :admitted
    assert admitted_flow.continuation_ref == invocation_run.waiting.ref

    loop_b =
      operation_loop(:work, definition_ref(@digest_a), id: "loop-b", correlation_id: "same")

    loop_a =
      operation_loop(:work, definition_ref(@digest_a), id: "loop-a", correlation_id: "same")

    operation_data = put_section(data, :work, %{loop_b.id => loop_b, loop_a.id => loop_a})
    implicit_operation = pending_event("implicit-work", :work_progress, correlation_id: "same")

    assert {:ok, ambiguous, _data} =
             Events.admit(operation_data, implicit_operation, admitted_at: 15)

    assert ambiguous.status == :quarantined
    assert ambiguous.quarantine_reason == {:ambiguous_continuation, ["loop-a", "loop-b"]}

    vigil = operation_loop(:vigil, definition_ref(@digest_a), id: "vigil")
    vigil_data = put_section(data, :vigil, %{vigil.id => vigil})

    assert {:ok, vigil_event, _data} =
             Events.admit(
               vigil_data,
               pending_event("vigil-completed", :vigil_completion,
                 continuation_ref: OperationRef.from_loop(vigil)
               ),
               admitted_at: 16
             )

    assert vigil_event.status == :admitted

    directive = operation_loop(:directive, definition_ref(@digest_a), id: "directive")
    directive_data = put_section(data, :directive, %{directive.id => directive})

    assert {:ok, directive_event, _data} =
             Events.admit(
               directive_data,
               pending_event("directive-work", :work_progress,
                 continuation_ref: OperationRef.from_loop(directive)
               ),
               admitted_at: 17
             )

    assert directive_event.quarantine_reason == :continuation_mismatch
  end

  test "quarantined replay identity survives after its inspection record is removed" do
    data = instance_state()
    pending = pending_event("quarantine-window", :reply, correlation_id: "missing-run")

    assert {:ok, quarantined, data} = Events.admit(data, pending, admitted_at: 20)
    assert quarantined.status == :quarantined
    receipt = quarantined.admission_receipt

    {:ok, window} = Canonical.fetch(data.canonical, :event_quarantine)
    aged_out = put_section(data, :event_quarantine, %{window | records: []})

    assert {:error,
            {:event_replay_already_committed, "quarantine-window", :quarantined, ^receipt}} =
             Events.admit(aged_out, pending, [])
  end

  test "Definition purge and Skill-state GC fail closed on unowned operation loops" do
    target = definition_ref(@digest_a)

    lifecycle =
      Lifecycle.new!(
        definition_ref: target,
        activation: :inactive,
        changed_at: 1
      )

    unowned_loop = operation_loop(:work, nil, id: "unowned-loop")

    data =
      instance_state()
      |> put_section(:lifecycles, %{Lifecycle.key(target) => lifecycle})
      |> put_section(:work, %{unowned_loop.id => unowned_loop})

    assert {:error, :operation_definition_ref_missing} =
             Events.operation_definition_ref(data, unowned_loop)

    assert {:error, {:definition_retention_referenced, lifecycle_key}} =
             Events.transition_lifecycle(data, target, :retention, :purged,
               expected_revision: 0,
               changed_at: 2
             )

    assert lifecycle_key == Lifecycle.key(target)

    branch = state_binding("retained", target, 1, :dormant)

    skill_data =
      data
      |> put_section(:skill_states, %{
        "learner" => %{active_branch: nil, branches: %{branch.branch_id => branch}}
      })

    assert {:error, {:skill_state_retention_referenced, "learner", "retained", :operation}} =
             SkillStates.transition_retention(
               skill_data,
               :learner,
               branch.branch_id,
               :gc_eligible,
               expected_revision: branch.revision
             )
  end

  test "Skill-state reads and activation filtering reject malformed or foreign state" do
    data = instance_state()
    target_a = definition_ref(@digest_a)
    target_b = definition_ref(@digest_b)
    active = state_binding("active-a", target_a, 1, :active)

    corrupt_section = put_section(data, :skill_states, [])

    assert {:error, {:skill_state_not_found, "learner"}} =
             SkillStates.fetch(corrupt_section, :learner)

    assert {:error, {:skill_state_not_found, "learner"}} =
             SkillStates.list(corrupt_section, :learner)

    refute SkillStates.definition_referenced?(corrupt_section, target_a)

    corrupt_entry = put_section(data, :skill_states, %{"learner" => :corrupt})

    assert {:error, {:invalid_skill_state_entry, "learner"}} =
             SkillStates.fetch(corrupt_entry, :learner)

    states = %{
      "learner" => %{active_branch: active.branch_id, branches: %{active.branch_id => active}}
    }

    assert %{"learner" => pointer} = SkillStates.activation_bindings(states, target_a)
    assert pointer == StateBinding.activation_pointer(active)
    assert SkillStates.activation_bindings(states, target_b) == %{}

    invalid_binding = %{active | revision: -1}

    assert {:error, {:invalid_skill_state_branch, "learner", "active-a", _reason}} =
             SkillStates.validate(%{
               "learner" => %{
                 active_branch: "active-a",
                 branches: %{"active-a" => invalid_binding}
               }
             })

    hidden_active = %{
      "learner" => %{active_branch: nil, branches: %{active.branch_id => active}}
    }

    assert {:error, {:skill_state_active_owner_mismatch, "learner", "active-a"}} =
             data
             |> put_section(:skill_states, hidden_active)
             |> SkillStates.prepare_activation(target_b, [])
  end

  test "Skill-state public boundaries return stable input-shape errors" do
    data = instance_state()
    target = definition_ref(@digest_a)

    assert {:error, {:invalid_skill_state_id, 42}} =
             SkillStates.prepare_activation(data, target,
               skill_state_transitions: %{42 => :resume}
             )

    assert {:error, {:invalid_skill_state_transitions, :integer}} =
             SkillStates.prepare_activation(data, target, skill_state_transitions: 42)

    assert {:error, {:invalid_skill_state_options, :tuple}} =
             SkillStates.update(data, :learner, %{}, {:not, :options})

    assert {:error, {:invalid_skill_state_activation_bindings, :binary, :atom}} =
             SkillStates.merge_activation_bindings("invalid", :invalid)

    assert {:error, {:invalid_skill_states, :other}} = SkillStates.validate(self())
  end

  test "abandonment preserves state and lineage even when a child branch exists" do
    target = definition_ref(@digest_a)
    parent = state_binding("parent", target, 1, :dormant)
    child = state_binding("child", target, 2, :dormant, parent_branch_id: parent.branch_id)

    data =
      instance_state()
      |> put_section(:skill_states, %{
        "learner" => %{
          active_branch: nil,
          branches: %{parent.branch_id => parent, child.branch_id => child}
        }
      })

    assert {:ok, abandoned, next} =
             SkillStates.transition_retention(
               data,
               :learner,
               parent.branch_id,
               :abandoned,
               expected_revision: parent.revision,
               updated_at: 30
             )

    assert abandoned.retention == :abandoned
    assert abandoned.status == :dormant
    assert abandoned.state == parent.state
    assert SkillStates.definition_referenced?(next, target)

    assert {:ok, branches} = SkillStates.list(next, :learner)

    assert Enum.find(branches, &(&1.branch_id == child.branch_id)).parent_branch_id ==
             parent.branch_id
  end

  defp instance_state do
    agent_ref = AgentRef.new(Agent)
    subject = Subject.new("events-skill-states-#{System.unique_integer([:positive])}")
    ref = InstanceRef.new(agent_ref, subject)
    flow = %State{conversation_id: ref.key}

    {:ok, canonical} =
      Canonical.new(%{
        flow: flow,
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    lease =
      Lease.new!(
        owner_id: "events-skill-states-owner",
        fencing_token: 10,
        issued_at: 0,
        metadata: %{instance_key: ref.key, scope: :single_owner_local}
      )

    %InstanceState{
      agent: Agent,
      agent_ref: agent_ref,
      subject: subject,
      ref: ref,
      state: flow,
      canonical: canonical,
      activation: nil,
      owner: {Spectre.Instance.Owner.Local, []},
      owner_lease: lease,
      base_opts: [],
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      generation: "events-skill-states-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0
    }
  end

  defp put_section(%InstanceState{} = data, name, value) do
    {:ok, %Section{} = current} = Sections.fetch(data.canonical.sections, name)
    sections = Sections.put(data.canonical.sections, name, %{current | value: value})
    %{data | canonical: %{data.canonical | sections: sections}}
  end

  defp pending_event(id, event_class, opts) do
    Envelope.new!(
      Keyword.merge(
        [
          id: id,
          event_class: event_class,
          correlation_id: "correlation-#{id}",
          payload_schema_ref: "spectre.test/#{event_class}/1",
          payload: %{"id" => id},
          emitted_at: 1
        ],
        opts
      )
    )
  end

  defp waiting_run(id, correlation_id, kind) do
    run =
      Run.new(Agent, Spectre.Input.new("waiting"), %State{},
        run_id: id,
        correlation_id: correlation_id
      )

    ref = Run.ref(run, kind, "boundary-#{id}")
    boundary = %Boundary{id: "boundary-#{id}", kind: :needs, ref: ref}
    %{run | status: :boundary, cursor: :policy, waiting: boundary}
  end

  defp invocation_run(id, correlation_id) do
    run =
      Run.new(Agent, Spectre.Input.new("invocation"), %State{},
        run_id: id,
        correlation_id: correlation_id
      )

    ref = Run.ref(run, :invocation, "invocation-#{id}")

    invocation = %Invocation{
      id: "invocation-#{id}",
      run_id: run.id,
      run_revision: run.revision,
      ref: ref,
      kind: :effect,
      operation: {:action, :coverage},
      subject_id: "events-skill-states-subject",
      idempotency_key: "idempotency-#{id}"
    }

    %{run | status: :boundary, cursor: :flow, waiting: invocation}
  end

  defp operation_loop(kind, definition_ref, opts) do
    id = Keyword.fetch!(opts, :id)
    correlation_id = Keyword.get(opts, :correlation_id, "correlation-#{id}")
    metadata = if definition_ref, do: %{spectre_definition_ref: definition_ref}, else: %{}

    %Loop{
      id: id,
      kind: kind,
      controller: __MODULE__,
      controller_id: :contract_loop,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{},
      subject_id: "events-skill-states-subject",
      correlation_id: correlation_id,
      created_at: 1,
      updated_at: 1,
      budget: Budget.new(nil, 1),
      metadata: metadata
    }
  end

  defp state_binding(branch_id, definition_ref, generation, status, opts \\ []) do
    StateBinding.new!(
      skill_id: "learner",
      state_schema_ref: "spectre.test/learner/1",
      state_generation: generation,
      branch_id: branch_id,
      parent_branch_id: Keyword.get(opts, :parent_branch_id),
      owning_definition_ref: definition_ref,
      fencing_token: 10,
      status: status,
      retention: :retained,
      state: %{"branch" => branch_id},
      created_at: generation,
      updated_at: generation
    )
  end

  defp definition_ref(digest) do
    {:ok, ref} = DefinitionRef.parse("sha256:" <> digest)
    ref
  end
end
