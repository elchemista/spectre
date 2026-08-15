defmodule SpectreReflectiveInstanceSequencerTest.Renderer do
  @moduledoc false
  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreReflectiveInstanceSequencerTest.Actions do
  @moduledoc false

  def teach(args, context) do
    if pid = Keyword.get(context.opts, :test_pid), do: send(pid, {:taught, args})
    {:ok, %{stored: args.fact}}
  end
end

defmodule SpectreReflectiveInstanceSequencerTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :reflective_instance_sequencer_agent

  actions SpectreReflectiveInstanceSequencerTest.Actions do
    protect(:teach, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
    attempts(2, then: :cancel_pending)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :learning do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreReflectiveInstanceSequencerTest.Renderer, :render})
    end

    on :TEACH, regex: ~r/^teach refunds$/i do
      action(:teach,
        args: %{fact: "refunds"},
        reply: :approve_learning,
        renderer: {SpectreReflectiveInstanceSequencerTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreReflectiveInstanceSequencerTest.SchemaRegistry do
  @moduledoc false
  @behaviour Spectre.Event.SchemaRegistry

  @impl true
  def compatible?(_definition_ref, envelope, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:schema_verified, envelope.id})

    if envelope.payload_schema_ref == "spectre.test/global/1",
      do: :ok,
      else: {:error, :schema_mismatch}
  end
end

defmodule SpectreReflectiveInstanceSequencerTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Event.Envelope
  alias Spectre.Instance
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Validator, as: CanonicalValidator
  alias Spectre.Instance.Events
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref, as: RunRef
  alias Spectre.Skill.StateBinding
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn
  alias SpectreReflectiveInstanceSequencerTest.Agent
  alias SpectreReflectiveInstanceSequencerTest.SchemaRegistry

  @digest String.duplicate("c", 64)
  @other_digest String.duplicate("d", 64)

  test "a real Instance preserves turn order while policy gates learning and dispatches once" do
    instance =
      start_supervised!(
        {Instance,
         agent: Agent,
         subject: Subject.new("real-learning-sequencer"),
         idle: false,
         max_runs: 16,
         max_tombstones: 16}
      )

    assert {:ok, %Turn{observable: {:reply, "hello:hello", hello_ref}}} =
             Spectre.turn(instance, "hello")

    assert {:ok, %Turn{observable: {:needs, request}} = teach_turn} =
             Spectre.turn(instance, "teach refunds", test_pid: self())

    assert request.kind == :needs
    assert request.request.kind == :policy
    assert request.request.name == :confirmation
    refute teach_turn.ref.run_id == hello_ref.run_id
    refute_receive {:taught, _}

    assert {:ok, %Turn{observable: {:needs, retry_request}}} =
             Spectre.turn(instance, "maybe", test_pid: self())

    assert retry_request.request.attempts == 1
    refute_receive {:taught, _}

    assert {:ok, %Turn{observable: {:awaiting, %RunRef{} = execution_ref}}} =
             Spectre.turn(instance, "yes", test_pid: self())

    assert {:ok, %Turn{ref: completed_ref}} =
             Spectre.resume(
               instance,
               execution_ref,
               {:execute, execution_ref},
               test_pid: self()
             )

    assert completed_ref.run_id == teach_turn.ref.run_id
    assert_receive {:taught, %{fact: "refunds"}}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, execution_ref.run_id))
    end)

    assert {:ok, %Turn{observable: {:reply, "hello:hello", final_ref}}} =
             Spectre.turn(instance, "hello")

    refute final_ref.run_id in [hello_ref.run_id, teach_turn.ref.run_id]
    assert %State{revision: revision} = Spectre.state(instance)
    assert revision >= 4

    info = Instance.info(instance)
    assert info.active_run == nil
    assert info.ready == []
    assert Enum.all?(info.runs, fn {_id, run} -> run.status == :complete end)
  end

  test "the public Instance boundary sequences events, lifecycle fences and durable state errors" do
    instance =
      start_supervised!(
        {Instance,
         agent: Agent,
         subject: Subject.new("public-instance-boundary"),
         idle: false,
         max_runs: 8,
         max_tombstones: 8}
      )

    assert Instance.agent(instance) == Agent
    assert Instance.definition_store(instance) == nil
    assert Instance.activation(instance) == nil
    assert {:ok, trace_id} = Instance.trace_id(instance)
    assert is_binary(trace_id)

    assert {:error, {:skill_state_not_found, "learner"}} =
             Instance.skill_state(instance, :learner)

    assert {:error, {:skill_state_not_found, "learner"}} =
             Instance.skill_state_branches(instance, :learner)

    assert {:error, {:skill_state_not_found, "learner"}} =
             Instance.update_skill_state(instance, :learner, %{"facts" => []})

    assert {:error, {:skill_state_not_found, "learner"}} =
             Instance.transition_skill_state_retention(
               instance,
               :learner,
               "branch",
               :gc_eligible
             )

    event = pending_event("public-input", :input)
    assert {:ok, admitted} = Instance.admit_event(instance, event, admitted_at: 400)
    assert admitted.status == :admitted
    assert [^admitted] = Instance.admitted_events(instance)
    assert [] == Instance.quarantined_events(instance)

    assert {:error, {:invalid_event_envelope, :atom}} =
             Instance.admit_event(instance, :not_an_event)

    assert {:ok, lifecycle} = Instance.definition_lifecycle(instance)
    assert lifecycle.activation == :active
    assert lifecycle.admission == :accepting

    assert {:ok, draining} =
             Instance.drain_definition(instance, :active,
               expected_revision: lifecycle.revision,
               changed_at: 401
             )

    assert draining.admission == :draining

    blocked = pending_event("drained-input", :input)
    assert {:ok, quarantined} = Instance.admit_event(instance, blocked, admitted_at: 402)
    assert quarantined.status == :quarantined

    assert {:lifecycle_blocked, {:definition_admission_blocked, _, :draining}} =
             quarantined.quarantine_reason

    assert [^quarantined] = Instance.quarantined_events(instance, limit: 1)

    assert {:ok, revoked} =
             Instance.revoke_definition(instance, :active,
               expected_revision: draining.revision,
               changed_at: 403
             )

    assert revoked.authority == :revoked

    assert {:error, {:stale_definition_lifecycle, 0, _}} =
             Instance.transition_definition_lifecycle(
               instance,
               :active,
               :admission,
               :closed,
               expected_revision: 0
             )

    assert {:error, {:invalid_definition_ref, "invalid"}} =
             Instance.definition_lifecycle(instance, "invalid")

    candidate_ref = "candidate:sha256:" <> @digest

    assert {:error, :definition_store_not_configured} =
             Instance.activate(instance, candidate_ref, expected_generation: 0)

    assert {:error, :definition_store_not_configured} =
             Instance.rollback(instance, candidate_ref, expected_generation: 0)

    assert {:error, {:invalid_data_driven_execution_start, :atom, :list}} =
             Instance.start_execution(instance, :invalid)
  end

  test "the event sequencer admits, deduplicates, quarantines and binds continuations" do
    data = instance_state(event_schema_registry: {SchemaRegistry, [pid: self()]})
    definition_ref = Run.definition_ref(Agent)

    input = pending_event("input-1", :input)
    assert {:ok, admitted, data} = Events.admit(data, input, admitted_at: 10)
    assert admitted.status == :admitted
    assert admitted.owner_definition_ref == definition_ref
    assert Events.list(data, :admitted) == [admitted]
    assert Events.list(data, :admitted, event_class: :reply) == []
    assert Events.list(data, :admitted, limit: 0) == []
    assert Events.list(data, :admitted, limit: :invalid) == [admitted]

    assert {:ok, ^admitted, same_data} = Events.admit(data, input, [])
    assert same_data.canonical.revision == data.canonical.revision

    conflict = %{input | payload: %{"changed" => true}}
    assert {:error, {:event_id_conflict, "input-1"}} = Events.admit(data, conflict, [])

    assert {:error, {:event_already_admitted, "input-1", :admitted}} =
             Events.admit(data, admitted, [])

    unexpected =
      pending_event("input-with-continuation", :input,
        continuation_ref: run_ref("missing", :reply),
        correlation_id: "unexpected"
      )

    assert {:ok, quarantined, data} = Events.admit(data, unexpected, admitted_at: 11)
    assert quarantined.status == :quarantined
    assert quarantined.quarantine_reason == :unexpected_continuation
    assert quarantined.owner_definition_ref == nil

    global =
      pending_event("global-1", :global,
        payload_schema_ref: "spectre.test/global/1",
        correlation_id: "global"
      )

    assert {:ok, global_admitted, data} = Events.admit(data, global, admitted_at: 12)
    assert global_admitted.status == :admitted
    assert_receive {:schema_verified, "global-1"}

    incompatible =
      pending_event("global-2", :global,
        payload_schema_ref: "spectre.test/global/2",
        correlation_id: "global-2"
      )

    assert {:ok, global_quarantine, data} = Events.admit(data, incompatible, admitted_at: 13)

    assert global_quarantine.quarantine_reason ==
             {:payload_schema_incompatible, :schema_mismatch}

    run = waiting_run("policy-run", "policy-correlation", :policy)
    data = %{data | runs: %{run.id => run}}
    policy_ref = run.waiting.ref

    policy =
      pending_event("policy-1", :policy_answer,
        continuation_ref: policy_ref,
        correlation_id: "policy-correlation"
      )

    assert {:ok, policy_admitted, data} = Events.admit(data, policy, admitted_at: 14)
    assert policy_admitted.status == :admitted
    assert policy_admitted.continuation_ref == policy_ref

    implicit =
      pending_event("policy-implicit", :policy_answer, correlation_id: "policy-correlation")

    assert {:ok, implicit_admitted, data} = Events.admit(data, implicit, admitted_at: 15)
    assert implicit_admitted.continuation_ref == policy_ref

    mismatch =
      pending_event("reply-mismatch", :reply,
        continuation_ref: policy_ref,
        correlation_id: "policy-correlation"
      )

    assert {:ok, mismatch_quarantine, data} = Events.admit(data, mismatch, admitted_at: 16)
    assert mismatch_quarantine.quarantine_reason == :continuation_mismatch

    missing =
      pending_event("missing-run", :reply,
        continuation_ref: run_ref("missing", :reply),
        correlation_id: "missing"
      )

    assert {:ok, missing_quarantine, data} = Events.admit(data, missing, admitted_at: 17)
    assert missing_quarantine.quarantine_reason == :continuation_not_found

    expired_data = %{data | tombstones: %{"expired" => %{id: "expired"}}}

    expired =
      pending_event("expired-run", :reply,
        continuation_ref: run_ref("expired", :reply),
        correlation_id: "expired"
      )

    assert {:ok, expired_quarantine, _data} = Events.admit(expired_data, expired, [])
    assert expired_quarantine.quarantine_reason == :continuation_expired

    second_run = waiting_run("policy-run-2", "policy-correlation", :policy)
    ambiguous_data = %{data | runs: Map.put(data.runs, second_run.id, second_run)}

    ambiguous =
      pending_event("ambiguous-policy", :policy_answer, correlation_id: "policy-correlation")

    assert {:ok, ambiguous_quarantine, _data} = Events.admit(ambiguous_data, ambiguous, [])
    assert {:ambiguous_continuation, refs} = ambiguous_quarantine.quarantine_reason
    assert length(refs) == 2
  end

  test "operation events require a pinned Definition and reject cross-kind continuations" do
    data = instance_state()
    definition_ref = Run.definition_ref(Agent)
    loop = operation_loop(:work, definition_ref)
    data = put_section(data, :work, %{loop.id => loop})
    ref = OperationRef.from_loop(loop)

    progress =
      pending_event("work-progress", :work_progress,
        continuation_ref: ref,
        correlation_id: loop.correlation_id
      )

    assert {:ok, admitted, data} = Events.admit(data, progress, [])
    assert admitted.status == :admitted
    assert admitted.owner_definition_ref == definition_ref

    implicit =
      pending_event("work-implicit", :work_completion, correlation_id: loop.correlation_id)

    assert {:ok, implicit_admitted, data} = Events.admit(data, implicit, [])
    assert implicit_admitted.continuation_ref == ref

    wrong_kind =
      pending_event("vigil-on-work", :vigil_progress,
        continuation_ref: ref,
        correlation_id: loop.correlation_id
      )

    assert {:ok, wrong_quarantine, data} = Events.admit(data, wrong_kind, [])
    assert wrong_quarantine.quarantine_reason == :continuation_mismatch

    missing_pin = %{loop | id: "missing-pin", metadata: %{}}
    data = put_section(data, :work, %{loop.id => loop, missing_pin.id => missing_pin})

    missing_pin_event =
      pending_event("missing-pin-event", :work_progress,
        continuation_ref: OperationRef.from_loop(missing_pin),
        correlation_id: missing_pin.correlation_id
      )

    assert {:ok, pin_quarantine, data} = Events.admit(data, missing_pin_event, [])
    assert pin_quarantine.quarantine_reason == :operation_definition_ref_missing
    assert pin_quarantine.owner_definition_ref == nil

    not_found =
      pending_event("operation-missing", :work_progress,
        continuation_ref: %OperationRef{
          id: "missing",
          kind: :work,
          subject_id: data.subject.id,
          correlation_id: "missing"
        },
        correlation_id: "missing"
      )

    assert {:ok, missing_quarantine, _data} = Events.admit(data, not_found, [])
    assert missing_quarantine.quarantine_reason == :continuation_not_found
  end

  test "canonical restore validation detects corrupted runs, lifecycles and event evidence" do
    data = instance_state()
    assert :ok = CanonicalValidator.validate(data.canonical, data.ref)
    assert :ok = CanonicalValidator.validate(data.canonical, data.ref, event_limit: :invalid)

    assert {:error, {:invalid_canonical_activation, :invalid}} =
             data
             |> put_section(:activation, :invalid)
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_runs, []}} =
             data
             |> put_section(:runs, [])
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_run_entry, "run"}} =
             data
             |> put_section(:runs, %{"run" => :invalid})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_run_checkpoint, "run", _reason}} =
             data
             |> put_section(:runs, %{"run" => "invalid"})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    opts = [run_id: "actual-run", correlation_id: "canonical-correlation"]

    assert {:ok, run} =
             Spectre.Runtime.admit(
               Agent,
               Spectre.Input.new("canonical"),
               %State{},
               opts,
               opts
             )

    assert {:ok, checkpoint} = Run.checkpoint(run)

    assert {:error, {:canonical_run_id_mismatch, "different-run", "actual-run"}} =
             data
             |> put_section(:runs, %{"different-run" => checkpoint})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_lifecycles, []}} =
             data
             |> put_section(:lifecycles, [])
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    definition_ref = Run.definition_ref(Agent)
    lifecycle = Spectre.Instance.Lifecycle.new!(definition_ref: definition_ref)

    assert {:error, {:invalid_canonical_lifecycle_entry, "definition"}} =
             data
             |> put_section(:lifecycles, %{"definition" => :invalid})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:canonical_lifecycle_key_mismatch, "wrong"}} =
             data
             |> put_section(:lifecycles, %{"wrong" => lifecycle})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    corrupt_lifecycle = %{lifecycle | revision: -1}

    assert {:error, {:invalid_canonical_lifecycle, _, _reason}} =
             data
             |> put_section(:lifecycles, %{
               Spectre.Instance.Lifecycle.key(lifecycle) => corrupt_lifecycle
             })
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    event = pending_event("canonical-event", :input)
    assert {:ok, admitted, event_data} = Events.admit(data, event, admitted_at: 500)
    assert :ok = CanonicalValidator.validate(event_data.canonical, event_data.ref)

    assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
             CanonicalValidator.validate(event_data.canonical, event_data.ref, event_limit: 0)

    {:ok, window} = Canonical.fetch(event_data.canonical, :event_admissions)

    assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
             event_data
             |> put_section(:event_admissions, %{window | records: [admitted, admitted]})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
             event_data
             |> put_section(:event_admissions, %{
               window
               | records: [%{admitted | status: :quarantined}]
             })
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_event_envelopes, :admitted}} =
             event_data
             |> put_section(:event_admissions, %{window | ids: %{"canonical-event" => %{}}})
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:ok, duplicate_quarantine} =
             Envelope.admit(event,
               owner_definition_ref: nil,
               admitted_activation_generation: 0,
               authority_epoch: 0,
               owner_fencing_token: 10,
               admission_revision: event_data.canonical.revision,
               status: :quarantined,
               quarantine_reason: :duplicate_evidence,
               admitted_at: 501
             )

    quarantine_window = %{
      records: [duplicate_quarantine],
      ids: %{
        duplicate_quarantine.id => %{
          intent_digest: Envelope.intent_digest(duplicate_quarantine),
          admission_receipt: duplicate_quarantine.admission_receipt
        }
      }
    }

    assert {:error, :event_envelope_admission_quarantine_conflict} =
             event_data
             |> put_section(:event_quarantine, quarantine_window)
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))

    assert {:error, {:invalid_canonical_event_envelopes, :quarantined}} =
             event_data
             |> put_section(:event_quarantine, [])
             |> then(&CanonicalValidator.validate(&1.canonical, &1.ref))
  end

  test "Skill state activation branches are explicit, owner-bound and retention-safe" do
    target_a = definition_ref(@digest)
    target_b = definition_ref(@other_digest)
    data = instance_state()

    assert {:ok, states_a, pointers_a} =
             SkillStates.prepare_activation(data, target_a,
               activated_at: 100,
               skill_state_transitions: %{
                 learner: {:init, "spectre.test/learner/1", %{"facts" => ["refunds"]}}
               }
             )

    activation_a = activation(target_a, 1, pointers_a)
    data = data |> put_section(:skill_states, states_a) |> Map.put(:activation, activation_a)

    assert :ok = SkillStates.validate(states_a)
    assert :ok = SkillStates.validate_activation(states_a, activation_a)
    assert SkillStates.definition_referenced?(data, target_a)
    refute SkillStates.definition_referenced?(data, target_b)

    assert {:ok, branch_a} = SkillStates.fetch(data, :learner)
    assert branch_a.state == %{"facts" => ["refunds"]}
    assert {:ok, [^branch_a]} = SkillStates.list(data, "learner")
    assert {:ok, ^branch_a} = SkillStates.fetch(data, :learner, branch_id: branch_a.branch_id)

    assert {:error, {:invalid_skill_state_id, 42}} = SkillStates.fetch(data, 42)

    assert {:error, {:skill_state_branch_not_found, "missing"}} =
             SkillStates.fetch(data, :learner, branch_id: "missing")

    assert {:error, {:invalid_skill_state_branch, :latest}} =
             SkillStates.fetch(data, :learner, branch_id: :latest)

    assert {:ok, updated, data} =
             SkillStates.update(data, :learner, %{"facts" => ["refunds", "returns"]},
               expected_generation: 1,
               expected_revision: 0,
               state_schema_ref: "spectre.test/learner/1",
               updated_at: 101
             )

    assert updated.revision == 1

    assert {:error, {:invalid_skill_state_options, :map}} =
             SkillStates.update(data, :learner, %{}, %{})

    assert {:ok, states_b, pointers_b} =
             SkillStates.prepare_activation(data, target_b,
               activated_at: 102,
               skill_state_transitions: %{
                 "learner" =>
                   {:fork, "spectre.test/learner/1", %{"facts" => ["refunds", "returns"]}}
               }
             )

    activation_b = activation(target_b, 2, pointers_b)
    data_b = data |> put_section(:skill_states, states_b) |> Map.put(:activation, activation_b)

    assert {:ok, branch_b} = SkillStates.fetch(data_b, :learner)
    assert branch_b.parent_branch_id == branch_a.branch_id
    assert branch_b.state_generation == 2
    assert {:ok, branches} = SkillStates.list(data_b, :learner)
    assert Enum.map(branches, & &1.state_generation) == [2, 1]

    assert {:error, {:skill_state_transition_required, "learner", [branch_id]}} =
             SkillStates.prepare_activation(data_b, target_a, activated_at: 103)

    assert branch_id == branch_a.branch_id

    assert {:ok, resumed_states, resumed_pointers} =
             SkillStates.prepare_activation(data_b, target_a,
               activated_at: 103,
               skill_state_transitions: %{learner: {:resume, branch_a.branch_id}}
             )

    resumed = activation(target_a, 3, resumed_pointers)

    resumed_data =
      data_b |> put_section(:skill_states, resumed_states) |> Map.put(:activation, resumed)

    assert {:ok, resumed_a} = SkillStates.fetch(resumed_data, :learner)
    assert resumed_a.branch_id == branch_a.branch_id
    assert resumed_a.status == :active

    assert {:error, {:skill_state_fork_schema_mismatch, "spectre.test/learner/2", _}} =
             SkillStates.prepare_activation(resumed_data, target_b,
               activated_at: 104,
               skill_state_transitions: %{
                 learner: {:fork, "spectre.test/learner/2", %{}}
               }
             )

    assert {:error, {:invalid_skill_state_transition, "learner", :invented}} =
             SkillStates.prepare_activation(resumed_data, target_b,
               activated_at: 104,
               skill_state_transitions: %{learner: :invented}
             )

    assert {:error, {:invalid_skill_state_transitions, :list}} =
             SkillStates.prepare_activation(resumed_data, target_b, skill_state_transitions: [])

    assert {:error, {:skill_state_retention_referenced, "learner", _, :active_branch}} =
             SkillStates.transition_retention(
               resumed_data,
               :learner,
               resumed_a.branch_id,
               :gc_eligible,
               expected_revision: resumed_a.revision
             )

    assert {:error, {:invalid_skill_state_retention, :deleted}} =
             SkillStates.transition_retention(
               resumed_data,
               :learner,
               resumed_a.branch_id,
               :deleted,
               []
             )

    assert {:ok, merged} =
             SkillStates.merge_activation_bindings(
               %{"legacy" => %{"kind" => "other"}},
               pointers_a
             )

    assert Map.has_key?(merged, "legacy")
    assert Map.has_key?(merged, "learner")

    assert {:error, {:skill_state_activation_binding_conflict, "learner"}} =
             SkillStates.merge_activation_bindings(
               %{"learner" => %{"legacy" => true}},
               pointers_a
             )

    assert {:error, {:invalid_skill_state_activation_bindings, :list, :map}} =
             SkillStates.merge_activation_bindings([], %{})
  end

  test "Skill state validation rejects key, parent, active and activation drift" do
    target = definition_ref(@digest)
    binding = state_binding("branch-a", target, 1, :active)
    dormant = state_binding("branch-b", target, 2, :dormant, parent_branch_id: "branch-a")
    orphan = state_binding("branch-b", target, 2, :dormant, parent_branch_id: "missing")
    valid = %{"learner" => %{active_branch: "branch-a", branches: %{"branch-a" => binding}}}

    assert :ok = SkillStates.validate(valid)
    assert {:error, {:invalid_skill_states, :list}} = SkillStates.validate([])

    assert {:error, {:invalid_skill_state_entry, "learner"}} =
             SkillStates.validate(%{"learner" => :invalid})

    assert {:error, {:invalid_skill_state_branch, "learner", "branch-a"}} =
             SkillStates.validate(%{
               "learner" => %{active_branch: nil, branches: %{"branch-a" => :invalid}}
             })

    assert {:error, {:skill_state_branch_key_mismatch, "learner", "wrong-key"}} =
             SkillStates.validate(%{
               "learner" => %{active_branch: "wrong-key", branches: %{"wrong-key" => binding}}
             })

    assert {:error, {:invalid_skill_state_parent, "branch-b", "missing"}} =
             SkillStates.validate(%{
               "learner" => %{
                 active_branch: nil,
                 branches: %{"branch-b" => orphan}
               }
             })

    assert {:error, :skill_state_active_branch_missing} =
             SkillStates.validate(%{
               "learner" => %{active_branch: nil, branches: %{"branch-a" => binding}}
             })

    assert {:error, {:invalid_skill_state_active_branch, "branch-b"}} =
             SkillStates.validate(%{
               "learner" => %{
                 active_branch: "branch-b",
                 branches: %{"branch-a" => binding, "branch-b" => dormant}
               }
             })

    assert {:error, {:invalid_skill_state_active_branch, :active}} =
             SkillStates.validate(%{
               "learner" => %{active_branch: :active, branches: %{"branch-a" => binding}}
             })

    assert {:error, :skill_state_active_without_activation} =
             SkillStates.validate_activation(valid, nil)

    activation = activation(target, 1, %{})

    assert {:error, :skill_state_activation_binding_mismatch} =
             SkillStates.validate_activation(valid, activation)

    assert {:error, {:invalid_skill_state_activation, :invalid}} =
             SkillStates.validate_activation(%{}, :invalid)
  end

  test "every Skill state branch transition is explicit and mutation-sensitive" do
    target_a = definition_ref(@digest)
    target_b = definition_ref(@other_digest)
    target_c = definition_ref(String.duplicate("e", 64))
    target_d = definition_ref(String.duplicate("f", 64))
    data0 = instance_state()

    assert {:error, {:duplicate_skill_state_transition, "learner"}} =
             SkillStates.prepare_activation(data0, target_a,
               skill_state_transitions: %{"learner" => :resume, learner: :resume}
             )

    assert {:error, {:skill_state_source_required, "learner", :fork}} =
             SkillStates.prepare_activation(data0, target_a,
               skill_state_transitions: %{
                 learner: {:fork, "spectre.test/learner/1", %{"facts" => []}}
               }
             )

    {:ok, states_a, pointers_a} =
      SkillStates.prepare_activation(data0, target_a,
        activated_at: 200,
        skill_state_transitions: %{
          learner: {:init, "spectre.test/learner/1", %{"facts" => ["refunds"]}}
        }
      )

    active_a = states_a["learner"].branches[states_a["learner"].active_branch]

    data_a =
      data0
      |> put_section(:skill_states, states_a)
      |> Map.put(:activation, activation(target_a, 1, pointers_a))

    assert {:error, {:skill_state_init_requires_no_dormant_branch, "learner"}} =
             SkillStates.prepare_activation(data_a, target_a,
               skill_state_transitions: %{
                 learner: {:init, "spectre.test/learner/1", %{}}
               }
             )

    {:ok, states_b, pointers_b} =
      SkillStates.prepare_activation(data_a, target_b,
        activated_at: 201,
        skill_state_transitions: %{
          learner: {:migrate, "spectre.test/learner/2", %{"facts" => ["refunds"], "v" => 2}}
        }
      )

    active_b = states_b["learner"].branches[states_b["learner"].active_branch]
    assert active_b.parent_branch_id == active_a.branch_id
    assert active_b.state_schema_ref == "spectre.test/learner/2"

    data_b =
      data_a
      |> put_section(:skill_states, states_b)
      |> Map.put(:activation, activation(target_b, 2, pointers_b))

    {:ok, resumed_states, resumed_pointers} =
      SkillStates.prepare_activation(data_b, target_a,
        activated_at: 202,
        skill_state_transitions: %{learner: :resume}
      )

    assert resumed_states["learner"].active_branch == active_a.branch_id

    resumed_data =
      data_b
      |> put_section(:skill_states, resumed_states)
      |> Map.put(:activation, activation(target_a, 3, resumed_pointers))

    {:ok, abandoned_states, abandoned_pointers} =
      SkillStates.prepare_activation(resumed_data, target_b,
        activated_at: 203,
        skill_state_transitions: %{learner: :abandon}
      )

    assert abandoned_states["learner"].branches[active_b.branch_id].retention == :abandoned
    assert abandoned_pointers == %{}

    abandoned_data =
      resumed_data
      |> put_section(:skill_states, abandoned_states)
      |> Map.put(:activation, activation(target_b, 4, abandoned_pointers))

    assert {:error, {:skill_state_source_unavailable, _, :fork, :abandoned}} =
             SkillStates.prepare_activation(abandoned_data, target_c,
               skill_state_transitions: %{
                 learner: {:fork, active_b.branch_id, "spectre.test/learner/2", %{"bad" => true}}
               }
             )

    {:ok, forked_states, forked_pointers} =
      SkillStates.prepare_activation(abandoned_data, target_c,
        activated_at: 204,
        skill_state_transitions: %{
          learner: {:fork, active_a.branch_id, "spectre.test/learner/1", %{"facts" => ["forked"]}}
        }
      )

    forked = forked_states["learner"].branches[forked_states["learner"].active_branch]
    assert forked.parent_branch_id == active_a.branch_id

    forked_data =
      abandoned_data
      |> put_section(:skill_states, forked_states)
      |> Map.put(:activation, activation(target_c, 5, forked_pointers))

    {:ok, migrated_states, _migrated_pointers} =
      SkillStates.prepare_activation(forked_data, target_d,
        activated_at: 205,
        skill_state_transitions: %{
          learner:
            {:migrate, active_a.branch_id, "spectre.test/learner/3", %{"facts" => ["migrated"]}}
        }
      )

    migrated = migrated_states["learner"].branches[migrated_states["learner"].active_branch]
    assert migrated.parent_branch_id == active_a.branch_id
    assert migrated.state_schema_ref == "spectre.test/learner/3"

    assert {:error, {:skill_state_target_branch_not_found, :resume}} =
             SkillStates.prepare_activation(forked_data, target_d,
               skill_state_transitions: %{learner: :resume}
             )

    assert {:error, {:invalid_skill_state_target_branch, :resume, _}} =
             SkillStates.prepare_activation(forked_data, target_d,
               skill_state_transitions: %{learner: {:resume, active_a.branch_id}}
             )

    dormant_one = state_binding("dormant-one", target_d, 1, :dormant)
    dormant_two = state_binding("dormant-two", target_d, 2, :dormant)

    ambiguous_states = %{
      "learner" => %{
        active_branch: nil,
        branches: %{"dormant-one" => dormant_one, "dormant-two" => dormant_two}
      }
    }

    ambiguous_data = put_section(data0, :skill_states, ambiguous_states)

    assert {:error, {:ambiguous_skill_state_branch, :resume, branch_ids}} =
             SkillStates.prepare_activation(ambiguous_data, target_d,
               skill_state_transitions: %{learner: :resume}
             )

    assert Enum.sort(branch_ids) == ["dormant-one", "dormant-two"]
  end

  test "Skill state retention cannot erase live lineage and purges only orphaned branches" do
    target = definition_ref(@digest)
    parent = state_binding("parent", target, 1, :dormant)
    child = state_binding("child", target, 2, :dormant, parent_branch_id: "parent")

    states = %{
      "learner" => %{
        active_branch: nil,
        branches: %{"parent" => parent, "child" => child}
      }
    }

    data = put_section(instance_state(), :skill_states, states)

    assert {:error, {:skill_state_retention_referenced, "learner", "parent", :child_branch}} =
             SkillStates.transition_retention(data, :learner, "parent", :gc_eligible,
               expected_revision: 0
             )

    assert {:ok, eligible_child, data} =
             SkillStates.transition_retention(data, :learner, "child", :gc_eligible,
               expected_revision: 0,
               updated_at: 300
             )

    assert eligible_child.retention == :gc_eligible

    assert {:ok, purged_child, purged_data} =
             SkillStates.transition_retention(data, :learner, "child", :purged,
               expected_revision: eligible_child.revision,
               updated_at: 301
             )

    assert purged_child.retention == :purged
    assert {:ok, [^parent]} = SkillStates.list(purged_data, :learner)

    assert {:ok, [^purged_child, ^parent]} =
             SkillStates.list(purged_data, :learner, include_purged?: true)

    activation_data =
      data
      |> Map.put(
        :activation,
        activation(target, 1, %{"learner" => StateBinding.activation_pointer(parent)})
      )

    assert {:error, {:skill_state_retention_referenced, "learner", "parent", :activation}} =
             SkillStates.transition_retention(activation_data, :learner, "parent", :purged,
               expected_revision: 0
             )

    run = %{waiting_run("retained-run", "retained-correlation", :reply) | definition_ref: target}
    run_data = %{put_section(instance_state(), :skill_states, states) | runs: %{run.id => run}}

    assert {:error, {:skill_state_retention_referenced, "learner", "parent", :run}} =
             SkillStates.transition_retention(run_data, :learner, "parent", :purged,
               expected_revision: 0
             )

    wrong_owner = definition_ref(@other_digest)
    active = state_binding("active", target, 1, :active)
    active_states = %{"learner" => %{active_branch: "active", branches: %{"active" => active}}}

    owner_data =
      instance_state()
      |> put_section(:skill_states, active_states)
      |> Map.put(:activation, activation(wrong_owner, 1, %{}))

    assert {:error, {:skill_state_owner_violation, "learner", "active"}} =
             SkillStates.update(owner_data, :learner, %{},
               expected_generation: 1,
               expected_revision: 0
             )

    dormant_states = %{
      "learner" => %{active_branch: nil, branches: %{"parent" => parent}}
    }

    dormant_data = put_section(instance_state(), :skill_states, dormant_states)

    assert {:error, {:skill_state_not_active, "parent", :dormant, :retained}} =
             SkillStates.update(dormant_data, :learner, %{},
               branch_id: "parent",
               expected_generation: 1,
               expected_revision: 0
             )
  end

  defp instance_state(opts \\ []) do
    agent_ref = AgentRef.new(Agent)
    subject = Subject.new("sequencer-state-#{System.unique_integer([:positive])}")
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
        owner_id: "sequencer-owner",
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
      base_opts: opts,
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      generation: "sequencer-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0
    }
  end

  defp put_section(%InstanceState{} = data, name, value) do
    {:ok, %Section{} = current} = Sections.fetch(data.canonical.sections, name)
    section = %Section{current | value: value}
    sections = Sections.put(data.canonical.sections, name, section)
    %{data | canonical: %{data.canonical | sections: sections}}
  end

  defp pending_event(id, event_class, opts \\ []) do
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
    opts = [run_id: id, correlation_id: correlation_id]

    {:ok, run} =
      Spectre.Runtime.admit(
        Agent,
        Spectre.Input.new("waiting"),
        %State{},
        opts,
        opts
      )

    ref = Run.ref(run, kind, "boundary-#{id}")
    boundary = %Boundary{id: "boundary-#{id}", kind: :needs, ref: ref}
    %{run | status: :boundary, cursor: :policy, waiting: boundary}
  end

  defp run_ref(id, kind), do: RunRef.new(id, 0, kind, "boundary-#{id}")

  defp operation_loop(kind, definition_ref) do
    %Loop{
      id: "#{kind}-loop",
      kind: kind,
      controller: __MODULE__,
      controller_id: :sequencer_loop,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{},
      subject_id: "sequencer-subject",
      correlation_id: "#{kind}-correlation",
      created_at: 1,
      updated_at: 1,
      budget: Budget.new(nil, 1),
      metadata: %{spectre_definition_ref: definition_ref}
    }
  end

  defp definition_ref(digest) do
    {:ok, ref} = DefinitionRef.parse("sha256:" <> digest)
    ref
  end

  defp activation(definition_ref, generation, state_bindings) do
    {:ok, candidate_ref} = CandidateRef.parse("candidate:sha256:" <> @digest)

    {:ok, activation} =
      Activation.build(%{
        definition_ref: definition_ref,
        candidate_ref: candidate_ref,
        manifest_digest: @digest,
        publication_id: "publication-#{generation}",
        closure_digest: @other_digest,
        state_bindings: state_bindings,
        generation: generation,
        authority_epoch: generation,
        owner_fencing_token: 10,
        activated_at: 100 + generation,
        provenance: %{}
      })

    activation
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
      state: %{},
      created_at: generation,
      updated_at: generation
    )
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
