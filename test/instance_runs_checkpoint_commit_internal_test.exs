defmodule SpectreInstanceRunsCheckpointCommitInternalTest.Actions do
  @moduledoc false

  def work(_args, _context), do: {:ok, "worked"}
end

defmodule SpectreInstanceRunsCheckpointCommitInternalTest.Work do
  @moduledoc false

  use Spectre.Work,
    id: :instance_commit_internal,
    version: 1,
    input: :map,
    state: :map

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(state, _context), do: complete(state)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(state, _context), do: complete(state)
end

defmodule SpectreInstanceRunsCheckpointCommitInternalTest.Agent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreInstanceRunsCheckpointCommitInternalTest.Actions)

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :instance_contract do
    on :WORK, regex: ~r/^work$/ do
      action(:work)
    end
  end
end

defmodule SpectreInstanceRunsCheckpointCommitInternalTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(ref, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:checkpoint_load, ref, opts})
    Keyword.get(opts, :load_reply, :not_found)
  end

  @impl true
  def compare_and_swap(_ref, _checkpoint, _expected, _revision, _opts), do: :ok
end

defmodule SpectreInstanceRunsCheckpointCommitInternalTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Validator
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Runs
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Inference.Progress
  alias Spectre.Inference.Prepared, as: PreparedInference
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Invocation.WorkerReceipt
  alias Spectre.Operation.Control
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Runtime, as: OperationRuntime
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.State
  alias Spectre.Subject

  @agent SpectreInstanceRunsCheckpointCommitInternalTest.Agent
  @work SpectreInstanceRunsCheckpointCommitInternalTest.Work
  @store SpectreInstanceRunsCheckpointCommitInternalTest.CheckpointStore

  test "invocation receipts enforce every ownership fence before accepting an outcome" do
    {invocation, awaiting} = awaiting_run("receipt-fences")

    assert {:boundary, %Boundary{}, returned} =
             outcome = Spectre.Runtime.resume(awaiting, {:execute, invocation.ref})

    capability = make_ref()

    ownership = %{
      invocation_id: invocation.id,
      run_id: awaiting.id,
      run_revision: awaiting.revision,
      generation: "generation-1",
      dispatch_id: "dispatch-1",
      capability: capability
    }

    data = %InstanceState{
      runs: %{awaiting.id => awaiting},
      invocations: %{invocation.id => ownership}
    }

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: awaiting.id,
      run_revision: awaiting.revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: capability,
      outcome: outcome
    }

    assert {:ok, ^ownership} =
             Runs.validate_invocation_receipt(data, invocation.id, receipt)

    assert {:error, :unknown_invocation} =
             Runs.validate_invocation_receipt(data, "missing", receipt)

    assert {:error, :invocation_id_mismatch} =
             Runs.validate_invocation_receipt(
               data,
               invocation.id,
               %{receipt | invocation_id: "foreign"}
             )

    assert {:error, :run_fence_mismatch} =
             Runs.validate_invocation_receipt(
               data,
               invocation.id,
               %{receipt | run_revision: awaiting.revision + 1}
             )

    assert {:error, :dispatch_fence_mismatch} =
             Runs.validate_invocation_receipt(
               data,
               invocation.id,
               %{receipt | generation: "generation-2"}
             )

    assert {:error, :invalid_receipt_capability} =
             Runs.validate_invocation_receipt(
               data,
               invocation.id,
               %{receipt | capability: make_ref()}
             )

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(
               %{data | runs: %{}},
               invocation.id,
               receipt
             )

    assert Runs.step_run(outcome) == returned
    assert Runs.step_result(outcome) == returned.result

    prepared = %PreparedInference{
      descriptor: nil,
      selection: nil,
      frozen_selection: nil,
      provider_opts: []
    }

    dispatch = {:dispatch, invocation, awaiting, prepared}
    assert Runs.step_run(dispatch) == awaiting
    assert Runs.step_result(dispatch) == nil

    mismatched_kind =
      struct!(WorkerReceipt, Map.merge(Map.from_struct(receipt), %{kind: :inference}))

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(data, invocation.id, mismatched_kind)
  end

  test "inference worker receipts reject malformed usage and incompatible Run cursors" do
    {effect_invocation, awaiting} = awaiting_run("inference-receipt-shape")
    capability = make_ref()

    invocation = %{
      effect_invocation
      | kind: :inference,
        inference_id: "inference",
        attempt_id: "attempt",
        control_revision: 0,
        stream_epoch: "epoch"
    }

    inference_run = %{awaiting | cursor: :inference, waiting: invocation}

    ownership = %{
      invocation_id: invocation.id,
      run_id: inference_run.id,
      run_revision: inference_run.revision,
      generation: "generation",
      dispatch_id: "dispatch",
      capability: capability
    }

    data = %InstanceState{
      runs: %{inference_run.id => inference_run},
      invocations: %{invocation.id => ownership}
    }

    receipt = %WorkerReceipt{
      invocation_id: invocation.id,
      run_id: inference_run.id,
      run_revision: inference_run.revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: capability,
      kind: :inference,
      attempt_id: invocation.attempt_id,
      control_revision: invocation.control_revision,
      stream_epoch: invocation.stream_epoch,
      provider_started: true,
      usage: %{input_tokens: self()},
      metadata: %{},
      outcome: {:error, :provider_failed}
    }

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(data, invocation.id, receipt)

    invalid_quality = %{receipt | usage: %{}, usage_quality: :guessed}

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(data, invocation.id, invalid_quality)

    wrong_cursor = %{inference_run | cursor: :effect}
    wrong_cursor_data = %{data | runs: %{wrong_cursor.id => wrong_cursor}}
    valid_usage = %{receipt | usage: %{input_tokens: 1}}

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(wrong_cursor_data, invocation.id, valid_usage)
  end

  test "move and Result ownership validation fail closed for forged lineage" do
    current = Run.new(@agent, Spectre.Input.new("work"), %State{}, run_id: "lineage-current")
    advanced = %{current | revision: current.revision + 1}
    entry = %{operation: :advance}

    assert :ok = Runs.validate_move_outcome({:continue, advanced}, current, entry)

    foreign = %{advanced | trace_id: "foreign-trace"}

    assert {:error, :run_lineage_mismatch} =
             Runs.validate_move_outcome({:continue, foreign}, current, entry)

    invalid_result = %{advanced | result: :forged}

    assert {:error, :result_lineage_mismatch} =
             Runs.validate_move_outcome({:continue, invalid_result}, current, entry)

    data = %InstanceState{runs: %{current.id => current}}
    assert {:error, :result_has_no_run_reference} = Runs.owned_result_run(data, %Result{})

    referenced = %Result{metadata: %{run: %{id: current.id}}}
    assert {:error, :result_has_no_run_reference} = Runs.owned_result_run(data, referenced)

    assert {:error, :result_has_no_run_reference} =
             Runs.owned_result_run(data, referenced, true)

    assert {:error, {:unknown_instance_run, "unknown"}} =
             Runs.owned_result_run(
               data,
               %Result{metadata: %{run: %{id: "unknown"}}}
             )
  end

  test "run ownership accepts current references and only replays equivalent terminal results" do
    {invocation, awaiting} = awaiting_run("owned-results")

    assert {:boundary, %Boundary{} = boundary, replied} =
             Spectre.Runtime.resume(awaiting, {:execute, invocation.ref})

    live = %InstanceState{runs: %{replied.id => replied}}
    assert {:ok, ^replied} = Runs.owned_run(live, boundary.ref)

    stale_ref = %{boundary.ref | revision: boundary.ref.revision - 1}

    assert {:error, {:stale_instance_run_reference, replied_id, _, replied_revision}} =
             Runs.owned_run(live, stale_ref)

    assert replied_id == replied.id
    assert replied_revision == replied.revision
    assert {:ok, ^replied} = Runs.owned_result_run(live, replied.result)
    assert Runs.terminal_result?(replied.result)

    assert {:complete, %Result{} = result, completed} = Spectre.Runtime.advance(replied)
    terminal = %InstanceState{runs: %{completed.id => completed}}

    assert {:error, {:instance_run_terminal, completed_id, :complete}} =
             Runs.owned_run(terminal, get_in(result.metadata, [:run, :ref]))

    assert completed_id == completed.id

    assert {:error, {:stale_instance_run_reference, ^completed_id}} =
             Runs.owned_result_run(terminal, replied.result)

    assert {:ok, ^completed} = Runs.owned_result_run(terminal, replied.result, true)

    failed = Runs.terminalize_failed_run(replied, {:provider_failed, :timeout})
    lineage = get_in(failed.result.metadata, [:run])
    failed_id = failed.id
    failed_revision = failed.revision

    assert %{id: ^failed_id, revision: ^failed_revision, status: :failed, cursor: :complete} =
             lineage

    assert lineage.ref.run_id == failed.id
    assert lineage.ref.revision == failed.revision
    assert Runs.run_projection(failed).waiting == nil
  end

  test "run retention skips stale queue entries and bounds durable tombstones" do
    oldest = failed_run("oldest")
    newest = failed_run("newest")

    data = %InstanceState{
      max_runs: 1,
      max_tombstones: 1,
      runs: %{oldest.id => oldest, newest.id => newest},
      completed: :queue.from_list(["already-evicted", oldest.id]),
      terminal_recorded: MapSet.new([oldest.id, newest.id]),
      tombstones: %{"previous" => %{id: "previous"}},
      tombstone_order: :queue.from_list(["previous"])
    }

    pruned = Runs.prune_for_new_run(data)

    assert Map.keys(pruned.runs) == [newest.id]
    assert pruned.tombstones == %{oldest.id => Runs.run_projection(oldest)}
    refute MapSet.member?(pruned.terminal_recorded, oldest.id)

    assert Runs.record_terminal(pruned, newest) == pruned
  end

  test "canonical commits are owner-fenced and persist the fencing token atomically" do
    data = instance_state()
    next_flow = %{data.state | revision: data.state.revision + 1}

    assert {:ok, committed} =
             Commit.canonical_sections(data, %{flow: next_flow},
               correlation_id: "flow-commit",
               checkpoint: :defer
             )

    assert committed.state == next_flow
    assert committed.canonical.revision == data.canonical.revision + 1
    assert committed.checkpoint_pending == nil
    assert {:ok, correlations} = Canonical.fetch(committed.canonical, :correlations)
    assert correlations.owner_fencing_token == data.owner_lease.fencing_token

    stale_lease = %{data.owner_lease | metadata: %{instance_key: "foreign"}}
    stale = %{data | owner_lease: stale_lease}

    assert {:error, {:owner_fence_lost, :commit, :owner_lease_instance_mismatch}} =
             Commit.canonical_sections(stale, %{flow: next_flow},
               correlation_id: "stale-flow-commit",
               checkpoint: :defer
             )

    assert stale.canonical.revision == data.canonical.revision
  end

  test "run commits store a restorable continuation and redact encoding failures" do
    data = instance_state()

    opts = [run_id: "committed-run", correlation_id: "run-correlation"]

    assert {:ok, run} =
             Spectre.Runtime.admit(
               @agent,
               Spectre.Input.new("work"),
               data.state,
               opts,
               opts
             )

    assert {:ok, committed} = Commit.run_state(data, run.state, run)
    assert {:ok, runs} = Canonical.fetch(committed.canonical, :runs)
    assert {:ok, %Run{id: "committed-run"}} = Run.restore(runs["committed-run"])

    sentinel = "private-run-state-must-not-leak"
    nonportable = %{run | state: %{run.state | data: %{secret: sentinel, pid: self()}}}

    assert {:error, {:canonical_run_commit_failed, run_reason}} =
             Commit.run_state(data, nonportable.state, nonportable)

    assert {:error, {:canonical_flow_commit_failed, {:canonical_run_commit_failed, flow_reason}}} =
             Commit.flow_state(data, nonportable.state, nonportable)

    refute inspect(run_reason) =~ sentinel
    refute inspect(flow_reason) =~ sentinel
  end

  test "operational commits reject malformed batches and preserve event idempotency" do
    data = instance_state()
    {loop, control, event_specs} = operation_start(data, "loop-1")
    entry = %{loop: loop, control: control, event_specs: event_specs, opts: []}

    assert {:error, :empty_operational_transition} = Commit.operational_batch(data, [], [])

    assert {:error, :duplicate_operational_loop_in_transition} =
             Commit.operational_batch(data, [entry, entry], [])

    assert {:error, :invalid_operational_loop_id} =
             Commit.operational(data, %{loop | id: ""}, control, [], [])

    assert {:error, :invalid_operation_control_state} =
             Commit.operational(data, loop, %{control | state: :invalid}, [], [])

    assert {:ok, committed, [event]} =
             Commit.operational(data, loop, control, event_specs,
               correlation_id: loop.correlation_id,
               transition: :started
             )

    assert :ok = Validator.validate(committed.canonical, committed.ref)
    assert :ok = Commit.validate_operation_events(committed, [event])

    assert {:error, :duplicate_operation_event_id} =
             Commit.validate_operation_events(data, [event, event])

    assert {:error, {:operation_event_id_conflict, event_id}} =
             Commit.validate_operation_events(committed, [%{event | payload: :changed}])

    assert event_id == event.id

    wrong_revision =
      OperationEvent.new(loop, :wrong_revision,
        id: "wrong-revision",
        agent_id: AgentRef.key(data.agent_ref),
        revision: data.canonical.revision,
        timestamp: 1,
        provenance: %{}
      )

    assert {:error, {:invalid_operation_event_revision, 0}} =
             Commit.validate_operation_events(data, [wrong_revision])

    assert Commit.append_events(committed, [event]).records == [event]
  end

  test "canonical validation rejects corrupt operational fences and evidence" do
    data = instance_state()
    {loop, control, event_specs} = operation_start(data, "validated-loop")

    assert {:ok, committed, [event]} =
             Commit.operational(data, loop, control, event_specs,
               correlation_id: loop.correlation_id,
               transition: :started
             )

    canonical = committed.canonical

    corruptions = [
      {put_section(canonical, :control, %{}), :canonical_loop_control_set_mismatch},
      {put_section(canonical, :control, %{loop.id => %{control | loop_id: "foreign"}}),
       {:invalid_canonical_loop_control, loop.id}},
      {put_section(canonical, :events, %{records: [event, event], ids: %{}}),
       :duplicate_canonical_operation_event},
      {put_section(canonical, :events, %{
         records: [%{event | loop_kind: :vigil}],
         ids: %{event.id => event.revision}
       }), {:operation_event_loop_mismatch, event.id}},
      {put_section(canonical, :correlations, %{
         instance_key: data.ref.key,
         owner_fencing_token: 0
       }), :invalid_canonical_owner_fencing_token},
      {put_section(canonical, :correlations, %{instance_key: "foreign"}),
       :canonical_checkpoint_instance_mismatch}
    ]

    Enum.each(corruptions, fn {corrupt, reason} ->
      assert {:error, ^reason} = Validator.validate(corrupt, data.ref)
    end)
  end

  test "checkpoint recovery keeps revision fences and exposes only redacted ambiguity" do
    data = instance_state()
    canonical = %{data.canonical | revision: 3}
    assert {:ok, encoded} = CanonicalCodec.encode_json(canonical)

    assert {:ok, restored_state, restored, 2} =
             Checkpoint.restore_canonical(
               [
                 instance_ref: data.ref,
                 canonical_checkpoint: encoded,
                 checkpoint_expected_revision: 2
               ],
               data.state,
               nil,
               []
             )

    assert restored_state == data.state
    assert restored == canonical

    progress =
      Progress.new(
        inference_id: "checkpoint-inference",
        invocation_id: "checkpoint-invocation",
        attempt_id: "checkpoint-attempt",
        run_revision: 0,
        generation: "checkpoint-generation",
        dispatch_id: "checkpoint-dispatch",
        control_revision: 0,
        stream_epoch: "checkpoint-epoch",
        sequence: 1,
        state: :streaming,
        at: 1,
        canonical_revision: 3
      )

    bounded_progress = %{
      progress.inference_id => progress,
      "checkpoint-inference-two" => %{progress | inference_id: "checkpoint-inference-two"}
    }

    bounded_canonical = put_section(canonical, :inference_progress, bounded_progress)
    assert {:ok, bounded_encoded} = CanonicalCodec.encode_json(bounded_canonical)

    assert {:error, {:canonical_inference_progress_limit_exceeded, 2, 1}} =
             Checkpoint.restore_canonical(
               [instance_ref: data.ref, canonical_checkpoint: bounded_encoded],
               data.state,
               nil,
               inference_progress_limit: 1
             )

    assert {:ok, _state, ^bounded_canonical, 0} =
             Checkpoint.restore_canonical(
               [instance_ref: data.ref, canonical_checkpoint: bounded_encoded],
               data.state,
               nil,
               inference_progress_limit: 2
             )

    foreign_ref = InstanceRef.new(data.agent_ref, Subject.new("foreign-subject"))

    assert {:error, :canonical_checkpoint_instance_mismatch} =
             Checkpoint.restore_canonical(
               [instance_ref: foreign_ref, canonical_checkpoint: encoded],
               data.state,
               nil,
               []
             )

    reconciliation = %{
      revision: 3,
      expected_revision: 2,
      reason: {:ambiguous, {:secret_adapter_reason, "must-not-leak"}}
    }

    assert Checkpoint.reconciliation_status(nil) == nil

    assert Checkpoint.reconciliation_status(reconciliation) == %{
             revision: 3,
             expected_revision: 2,
             reason: :ambiguous
           }

    reconciling = %{data | checkpoint_reconciliation: reconciliation}

    assert Checkpoint.reconciliation_error(reconciling) ==
             {:checkpoint_reconciliation_required, 3, :ambiguous}
  end

  test "checkpoint reconciliation loads under the current owner fencing token" do
    data =
      instance_state(
        checkpoint_store: {@store, [test_pid: self(), load_reply: :not_found]},
        checkpoint_reconciliation: %{
          revision: 1,
          expected_revision: 0,
          canonical: nil,
          base: nil,
          reason: {:ambiguous, :timeout}
        }
      )

    from = {self(), make_ref()}
    started = Checkpoint.start_reconciliation(data, from)
    inflight = started.checkpoint_reconcile_inflight

    assert inflight.from == from

    assert_receive {:checkpoint_load, ref, opts}, 1_000
    assert ref == data.ref
    assert opts[:owner_fencing_token] == data.owner_lease.fencing_token

    assert_receive {:spectre, :checkpoint_reconcile_result, token, :not_found}, 1_000
    assert token == inflight.token
    assert Checkpoint.finish_reconciliation_task(started).checkpoint_reconcile_inflight == nil
  end

  defp instance_state(overrides \\ []) do
    agent_ref = AgentRef.new(@agent)
    subject = Subject.new("instance-contract-#{System.unique_integer([:positive])}")
    ref = InstanceRef.new(agent_ref, subject)
    state = %State{conversation_id: ref.key}

    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    owner_lease =
      Lease.new!(
        owner_id: "instance-contract-owner",
        fencing_token: 7,
        issued_at: 0,
        metadata: %{instance_key: ref.key, scope: :single_owner_local}
      )

    defaults = %{
      agent: @agent,
      agent_ref: agent_ref,
      subject: subject,
      ref: ref,
      state: state,
      canonical: canonical,
      activation: nil,
      owner: {Spectre.Instance.Owner.Local, []},
      owner_lease: owner_lease,
      base_opts: [now: 1],
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      generation: "instance-contract-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0
    }

    struct!(InstanceState, Map.merge(defaults, Map.new(overrides)))
  end

  defp awaiting_run(id) do
    assert {:continue, started} = Spectre.Runtime.start(@agent, "work", run_id: id)
    assert {:await, %Invocation{} = invocation, awaiting} = Spectre.Runtime.advance(started)
    {invocation, awaiting}
  end

  defp failed_run(id) do
    @agent
    |> Run.new(Spectre.Input.new("work"), %State{}, run_id: id)
    |> Runs.terminalize_failed_run(:failed)
  end

  defp operation_start(data, id) do
    env = %{
      agent: data.agent,
      subject_id: data.subject.id,
      epoch: "operation-epoch",
      snapshot_id: "operation-snapshot",
      canonical_revision: data.canonical.revision,
      committed: %{},
      now: 1
    }

    assert {:ok, loop, %Control{} = control, event_specs} =
             OperationRuntime.start(
               :work,
               @work,
               %{value: id},
               [id: id, correlation_id: "correlation-#{id}"],
               env
             )

    {loop, control, event_specs}
  end

  defp put_section(canonical, name, value) do
    assert {:ok, %Section{} = current} = Sections.fetch(canonical.sections, name)
    section = %Section{current | value: value}
    %{canonical | sections: Sections.put(canonical.sections, name, section)}
  end
end
