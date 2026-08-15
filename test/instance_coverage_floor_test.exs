defmodule SpectreInstanceCoverageFloorTest.Actions do
  @moduledoc false

  def work(_args, _context), do: {:ok, "worked"}
end

defmodule SpectreInstanceCoverageFloorTest.Agent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreInstanceCoverageFloorTest.Actions)

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :coverage do
    on :PING, regex: ~r/^ping$/ do
      run(:pong)
    end

    on :WORK, regex: ~r/^work$/ do
      action(:work)
    end
  end

  def pong(_input, _ctx), do: "pong"
end

defmodule SpectreInstanceCoverageFloorTest.RaisingDefinitionAgent do
  @moduledoc false

  def __spectre_definition__ do
    if Process.get({__MODULE__, :raise_definition?}, false) do
      raise "definition failed"
    else
      SpectreInstanceCoverageFloorTest.Agent.__spectre_definition__()
    end
  end
end

defmodule SpectreInstanceCoverageFloorTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(_ref, opts), do: Keyword.get(opts, :load_reply, :not_found)

  @impl true
  def compare_and_swap(_ref, checkpoint, expected, revision, opts) do
    if pid = Keyword.get(opts, :pid) do
      send(pid, {:checkpoint_store_write, checkpoint, expected, revision})
    end

    Keyword.get(opts, :persist_reply, :ok)
  end
end

defmodule SpectreInstanceCoverageFloorTest.InvalidInfoServer do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:instance_info, _from, state), do: {:reply, :invalid, state}
end

defmodule SpectreInstanceCoverageFloorTest.HistorySummary do
  @moduledoc false

  def raises(_current, _evicted), do: raise("summary failed")
  def throws(_current, _evicted), do: throw(:summary_failed)
  def ok_tuple(_current, _evicted), do: {:ok, "tuple summary"}
  def invalid(_current, _evicted), do: :invalid
end

defmodule SpectreInstanceCoverageFloorTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Runs
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Progress
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Selection
  alias Spectre.Inference.StreamCheckpoint
  alias Spectre.Inference.Usage
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Prompt.Plan
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.InferenceContinuation
  alias Spectre.State
  alias Spectre.Subject

  @agent SpectreInstanceCoverageFloorTest.Agent

  test "Checkpoint reduces unambiguous failures, task DOWNs, and reconciliation outcomes" do
    data = instance_state()
    canonical_one = canonical(data.ref, data.state, 1)
    canonical_two = canonical(data.ref, data.state, 2)
    canonical_three = canonical(data.ref, data.state, 3)
    inflight = checkpoint_inflight(canonical_two, 1)

    failure_tag = make_ref()

    failed =
      Checkpoint.persist_failed(
        %{
          data
          | canonical: canonical_two,
            checkpoint_revision: 1,
            checkpoint_waiters: [{{self(), failure_tag}, 2}]
        },
        inflight,
        :store_down
      )

    assert failed.checkpoint_error == :store_down
    assert failed.checkpoint_pending == canonical_two
    assert failed.checkpoint_waiters == []
    assert_receive {^failure_tag, {:error, :store_down}}

    for reason <- [:conflict, {:conflict, :cas}, {:stale, 1, 2}] do
      reconciled =
        Checkpoint.persist_failed(
          %{data | canonical: canonical_two, checkpoint_revision: 1},
          inflight,
          reason
        )

      assert reconciled.checkpoint_reconciliation.revision == 2
      assert reconciled.checkpoint_pending == canonical_two
    end

    task = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(task)

    down =
      Checkpoint.task_down(
        %{
          data
          | canonical: canonical_two,
            checkpoint_revision: 1,
            checkpoint_inflight: %{inflight | pid: task, monitor: monitor}
        },
        :killed
      )

    assert down.checkpoint_inflight == nil
    assert down.checkpoint_reconciliation.reason == {:checkpoint_task_down, :killed}
    Process.exit(task, :kill)

    reconcile_tag = make_ref()
    reconcile_task = spawn(fn -> Process.sleep(:infinity) end)
    reconcile_monitor = Process.monitor(reconcile_task)

    reconciliation_down =
      Checkpoint.reconciliation_task_down(
        %{
          data
          | checkpoint_reconcile_inflight: %{
              pid: reconcile_task,
              monitor: reconcile_monitor,
              from: {self(), reconcile_tag}
            }
        },
        :shutdown
      )

    assert reconciliation_down.checkpoint_reconcile_inflight == nil

    assert_receive {^reconcile_tag, {:error, {:checkpoint_reconciliation_task_down, :shutdown}}}

    Process.exit(reconcile_task, :kill)

    reconciliation = %{
      revision: 2,
      expected_revision: 1,
      canonical: canonical_two,
      base: canonical_one,
      reason: {:ambiguous, :timeout}
    }

    reconcile_data = %{
      data
      | canonical: canonical_two,
        checkpoint_revision: 1,
        checkpoint_persisted: canonical_one,
        checkpoint_reconciliation: reconciliation
    }

    assert {:ok, committed, 2} =
             Checkpoint.apply_reconciliation(
               reconcile_data,
               {:ok, encode_canonical(canonical_two)}
             )

    assert committed.checkpoint_reconciliation == nil
    assert committed.checkpoint_persisted == canonical_two

    assert {:ok, not_committed, 1} =
             Checkpoint.apply_reconciliation(
               reconcile_data,
               {:ok, encode_canonical(canonical_one)}
             )

    assert not_committed.checkpoint_reconciliation == nil

    assert {:error, conflict, {:checkpoint_reconciliation_conflict, 1, 2, 3}} =
             Checkpoint.apply_reconciliation(
               reconcile_data,
               {:ok, encode_canonical(canonical_three)}
             )

    assert conflict.checkpoint_error == {:checkpoint_reconciliation_conflict, 1, 2, 3}

    assert {:error, missing, {:checkpoint_reconciliation_missing_base, 1}} =
             Checkpoint.apply_reconciliation(reconcile_data, :not_found)

    assert missing.checkpoint_error == {:checkpoint_reconciliation_missing_base, 1}

    assert {:error, load_failed, {:checkpoint_reconciliation_load_failed, :offline}} =
             Checkpoint.apply_reconciliation(reconcile_data, {:error, :offline})

    assert load_failed.checkpoint_error ==
             {:checkpoint_reconciliation_load_failed, :offline}

    zero_base = put_in(reconcile_data.checkpoint_reconciliation.expected_revision, 0)
    zero_base = %{zero_base | checkpoint_revision: 0}
    assert {:ok, _next, 0} = Checkpoint.apply_reconciliation(zero_base, :not_found)
  end

  test "Checkpoint queues, starts, acknowledges, and coalesces canonical writes" do
    data = instance_state()
    canonical_one = canonical(data.ref, data.state, 1)
    canonical_two = canonical(data.ref, data.state, 2)

    store =
      {SpectreInstanceCoverageFloorTest.CheckpointStore, [pid: self(), persist_reply: :ok]}

    write_data = %{
      data
      | canonical: canonical_one,
        checkpoint_store: store,
        checkpoint_mode: :async,
        checkpoint_revision: 0
    }

    started = Checkpoint.force(write_data)
    assert %{revision: 1, canonical: ^canonical_one} = started.checkpoint_inflight
    assert_receive {:checkpoint_store_write, encoded, 0, 1}
    assert is_binary(encoded)
    assert_receive {:spectre, :checkpoint_result, token, 1, :ok}
    assert token == started.checkpoint_inflight.token

    finished = Checkpoint.finish_task(started)
    persisted = Checkpoint.persisted(finished, started.checkpoint_inflight, 1)
    assert persisted.checkpoint_revision == 1
    assert persisted.checkpoint_persisted == canonical_one

    immediate_tag = make_ref()

    immediate =
      Checkpoint.force(%{
        persisted
        | checkpoint_waiters: [{{self(), immediate_tag}, 1}]
      })

    assert immediate.checkpoint_waiters == []
    assert_receive {^immediate_tag, {:ok, 1}}

    pending_reconciliation =
      Checkpoint.maybe_enqueue(%{
        write_data
        | canonical: canonical_two,
          checkpoint_reconciliation: %{reason: :ambiguous}
      })

    assert pending_reconciliation.checkpoint_pending == canonical_two

    pending_inflight =
      Checkpoint.maybe_enqueue(%{
        write_data
        | canonical: canonical_two,
          checkpoint_inflight: checkpoint_inflight(canonical_one, 0)
      })

    assert pending_inflight.checkpoint_pending == canonical_two
  end

  test "Runs validates fallback outcomes and prunes terminal retention into bounded tombstones" do
    initial = initial_run("runs-initial")
    other = initial_run("runs-other")
    failed = Runs.terminalize_failed_run(initial, :failed)
    terminal_other = Runs.terminalize_failed_run(other, :failed)

    assert {:error, {:unknown_instance_run, "missing"}} =
             Runs.owned_run(%InstanceState{}, run_ref("missing", 0))

    assert {:error, :result_has_no_run_reference} =
             Runs.owned_result_run(%InstanceState{}, %Result{})

    assert :ok =
             Runs.validate_move_outcome(
               {:error, :failed, initial},
               initial,
               %{operation: {:start, "ping"}}
             )

    mismatched_state = %{initial | state: %{initial.state | revision: 1}}

    assert {:error, :state_revision_mismatch} =
             Runs.validate_move_outcome(
               {:error, :failed, mismatched_state},
               initial,
               %{operation: {:start, "ping"}}
             )

    rebased =
      Runs.rebase_run(
        %{failed | result: %Result{metadata: %{}, state: failed.state}},
        %{failed.state | revision: 2}
      )

    assert rebased.result.metadata == %{}
    assert rebased.result.state.revision == 2

    data = %InstanceState{
      max_runs: 1,
      max_tombstones: 0,
      runs: %{failed.id => failed, terminal_other.id => terminal_other},
      completed: :queue.in("already-pruned", :queue.new()),
      tombstones: %{"orphan" => %{id: "orphan"}},
      tombstone_order: :queue.new()
    }

    pruned = Runs.record_terminal(data, failed)
    assert map_size(pruned.runs) == 1
    assert pruned.tombstones == %{}
    refute MapSet.member?(pruned.terminal_recorded, failed.id)

    complete_result = %Result{reply_text: "done"}
    complete_run = %{failed | status: :complete, result: complete_result}

    assert ^complete_result =
             Runs.step_result({:complete, complete_result, complete_run})
  end

  test "Runs validates receipt shape, unchanged errors, and invalid advanced revisions" do
    {:continue, started} = Spectre.Runtime.start(@agent, "work", run_id: "receipt-run")
    {:await, %Invocation{} = invocation, awaiting} = Spectre.Runtime.advance(started)

    capability = make_ref()

    ownership = %{
      invocation_id: invocation.id,
      run_id: awaiting.id,
      run_revision: awaiting.revision,
      generation: "generation",
      dispatch_id: "dispatch",
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
      generation: "generation",
      dispatch_id: "dispatch",
      capability: capability,
      outcome: {:error, :failed, awaiting}
    }

    assert {:ok, ^ownership} =
             Runs.validate_invocation_receipt(data, invocation.id, receipt)

    invalid_shape = %{receipt | outcome: :invalid}

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(data, invocation.id, invalid_shape)

    invalid_revision = %{
      receipt
      | outcome: {:error, :failed, %{awaiting | revision: awaiting.revision + 2}}
    }

    assert {:error, :invalid_receipt_outcome} =
             Runs.validate_invocation_receipt(data, invocation.id, invalid_revision)
  end

  test "Runtime converts start/advance exceptions and bad history summarizers into stable results" do
    assert {:error, {:run_start_failed, Protocol.UndefinedError}, %Run{status: :failed}} =
             Spectre.Runtime.start(@agent, fn -> :not_stringable end)

    raising =
      Run.new(
        SpectreInstanceCoverageFloorTest.RaisingDefinitionAgent,
        Spectre.Input.new("ping"),
        %State{}
      )

    Process.put(
      {SpectreInstanceCoverageFloorTest.RaisingDefinitionAgent, :raise_definition?},
      true
    )

    on_exit(fn ->
      Process.delete(
        {SpectreInstanceCoverageFloorTest.RaisingDefinitionAgent, :raise_definition?}
      )
    end)

    assert {:error, {:run_advance_failed, ArgumentError}, %Run{status: :failed}} =
             Spectre.Runtime.advance(raising)

    Process.delete({SpectreInstanceCoverageFloorTest.RaisingDefinitionAgent, :raise_definition?})

    history = [%{user: "old", assistant: "reply"}]
    state = %State{data: %{chat_history: history}}

    for summarizer <- [
          {SpectreInstanceCoverageFloorTest.HistorySummary, :raises},
          {SpectreInstanceCoverageFloorTest.HistorySummary, :throws},
          {SpectreInstanceCoverageFloorTest.HistorySummary, :invalid},
          :invalid,
          fn _current, _evicted -> raise "function summary failed" end,
          fn _current, _evicted -> throw(:function_summary_failed) end
        ] do
      assert {:ok, result} =
               Spectre.ask(@agent, "ping",
                 state: state,
                 chat_history_limit: 1,
                 history_summary: summarizer
               )

      refute Map.has_key?(result.state.data, :chat_summary)
    end

    assert {:ok, tuple_summary} =
             Spectre.ask(@agent, "ping",
               state: state,
               chat_history_limit: 1,
               history_summary: {SpectreInstanceCoverageFloorTest.HistorySummary, :ok_tuple}
             )

    assert tuple_summary.state.data.chat_summary == "tuple summary"

    assert {:ok, fallback_limit} =
             Spectre.ask(@agent, "ping", state: state, chat_history_limit: :invalid)

    assert length(fallback_limit.state.data.chat_history) == 2
  end

  test "Instance callbacks reject busy, stale, non-waiting, and locked Run transitions" do
    assert :transition in Instance.canonical_vocabulary()

    invalid_info =
      start_supervised!(SpectreInstanceCoverageFloorTest.InvalidInfoServer)

    assert {:error, {:invalid_instance_info, :invalid}} = Instance.trace_id(invalid_info)

    {:continue, started} = Spectre.Runtime.start(@agent, "ping", run_id: "reply-run")
    {:boundary, _boundary, reply_run} = Spectre.Runtime.advance(started)
    reply_run_id = reply_run.id
    reply_ref = reply_run.waiting.ref
    data = instance_state(runs: %{reply_run.id => reply_run})
    from = {self(), make_ref()}

    assert {:reply, {:error, {:run_already_active, ^reply_run_id}}, _data} =
             Instance.handle_call(
               {:instance_resume, reply_ref, {:input, "ping"}, []},
               from,
               %{data | active: %{run_id: reply_run.id}}
             )

    assert {:noreply, queued} =
             Instance.handle_call(
               {:instance_resume, reply_ref, {:input, "ping"}, []},
               from,
               data
             )

    assert MapSet.member?(queued.queued, reply_run.id)
    assert_receive {:spectre, :advance, ^reply_run_id}

    assert {:reply, {:error, {:run_not_waiting_for_invocation, ^reply_run_id}}, _data} =
             Instance.handle_call({:execute, reply_run.result, []}, from, data)

    assert {:reply, {:error, :result_has_no_run_reference}, _data} =
             Instance.handle_call({:execute, %Result{}, []}, from, data)

    assert {:reply, {:error, :run_not_waiting_for_policy}, _data} =
             Instance.handle_call(
               {:resolve_policy, reply_run.result, {:accept, :ok}, []},
               from,
               data
             )

    {:complete, completed_result, completed_run} = Spectre.Runtime.advance(reply_run)
    completed_data = %{data | runs: %{completed_run.id => completed_run}}

    assert {:reply, {:error, :run_not_waiting_for_policy}, _data} =
             Instance.handle_call(
               {:resolve_policy, completed_result, {:accept, :ok}, []},
               from,
               completed_data
             )

    assert {:reply, {:error, {:run_not_waiting_for_invocation, ^reply_run_id}}, _data} =
             Instance.handle_call(
               {:instance_resume, reply_ref, {:execute, reply_ref.boundary_id}, []},
               from,
               data
             )

    {:continue, action_started} =
      Spectre.Runtime.start(@agent, "work", run_id: "action-run")

    {:await, %Invocation{} = invocation, action_run} =
      Spectre.Runtime.advance(action_started)

    action_run_id = action_run.id
    action_data = instance_state(runs: %{action_run.id => action_run})

    assert {:reply, {:error, {:run_already_active, ^action_run_id}}, _data} =
             Instance.handle_call(
               {:execute, action_run.result, []},
               from,
               %{action_data | active: %{run_id: action_run.id}}
             )

    assert {:reply, {:error, {:instance_busy, "other-run"}}, _data} =
             Instance.handle_call(
               {:execute, action_run.result, []},
               from,
               %{action_data | active: %{run_id: "other-run"}}
             )

    assert {:reply, {:error, :instance_state_locked}, _data} =
             Instance.handle_call(
               {:execute, action_run.result, []},
               from,
               %{action_data | state_lock: %{run_id: "locked"}}
             )

    assert invocation == action_run.waiting
  end

  test "Instance callbacks cover checkpoint fences, stale mailbox events, capacity, and shutdown" do
    {:continue, started} = Spectre.Runtime.start(@agent, "ping", run_id: "capacity-run")
    started_id = started.id
    data = instance_state(runs: %{started.id => started}, max_runs: 1)
    from = {self(), make_ref()}

    assert {:reply, {:error, :instance_run_capacity_reached}, _data} =
             Instance.handle_call({:handle, "ping", []}, from, data)

    empty = instance_state()

    assert {:reply, {:error, _reason}, _data} =
             Instance.handle_call({:handle, "ping", [run_id: self()]}, from, empty)

    duplicate = instance_state(tombstones: %{started.id => %{id: started.id}})

    assert {:reply, {:error, {:duplicate_instance_run, ^started_id}}, _data} =
             Instance.handle_call(
               {:handle, "ping", [run_id: started.id]},
               from,
               duplicate
             )

    reconcile_busy = %{
      empty
      | checkpoint_store: {SpectreInstanceCoverageFloorTest.CheckpointStore, []},
        checkpoint_reconciliation: %{reason: :ambiguous},
        checkpoint_inflight: %{revision: 1}
    }

    assert {:reply, {:error, :checkpoint_operation_in_progress}, _data} =
             Instance.handle_call(:reconcile_canonical_checkpoint, from, reconcile_busy)

    assert {:noreply, ^empty} =
             Instance.handle_info({:spectre, :checkpoint_result, "stale", 9, :ok}, empty)

    assert {:noreply, ^empty} =
             Instance.handle_info(
               {:spectre, :checkpoint_reconcile_result, "stale", :not_found},
               empty
             )

    assert {:noreply, scheduled_empty} =
             Instance.handle_info({:spectre, :operation_schedule}, empty)

    refute scheduled_empty.operation_scheduled

    stale_active = %{
      run_id: "other",
      dispatch_id: "dispatch",
      capability: :capability,
      pid: self(),
      entry: %{}
    }

    stale_data = %{empty | active: stale_active}

    assert {:noreply, ^stale_data} =
             Instance.handle_info(
               {:spectre, :advance_result, "run", "dispatch", :capability, :invalid},
               stale_data
             )

    missing_active = %{stale_active | run_id: "missing"}

    assert {:noreply, missing_result} =
             Instance.handle_info(
               {:spectre, :advance_result, "missing", "dispatch", :capability, :invalid},
               %{empty | active: missing_active}
             )

    assert missing_result.active == missing_active

    invalid_run_active = %{stale_active | run_id: started.id, entry: %{operation: :resume}}

    assert {:noreply, invalid_result} =
             Instance.handle_info(
               {:spectre, :advance_result, started.id, "dispatch", :capability, :invalid},
               %{empty | active: invalid_run_active, runs: %{started.id => started}}
             )

    assert invalid_result.active == invalid_run_active

    unknown_monitor = make_ref()

    assert {:noreply, ^empty} =
             Instance.handle_info(
               {:DOWN, unknown_monitor, :process, self(), :unknown},
               empty
             )

    assert {:noreply, exit_data} =
             Instance.handle_info(
               {:EXIT, self(), :normal},
               %{empty | workers: %{self() => %{monitor: make_ref()}}}
             )

    assert map_size(exit_data.workers) == 1

    busy_idle = %{empty | idle_generation: 7, active: %{run_id: "busy"}}
    assert {:noreply, rearmed} = Instance.handle_info({:idle_shutdown, 7}, busy_idle)
    assert rearmed.idle_generation == 8

    empty_generation = empty.idle_generation

    assert {:stop, :normal, stopped} =
             Instance.handle_info({:idle_shutdown, empty_generation}, empty)

    assert stopped.idle_timer == nil
    assert {:noreply, ^empty} = Instance.handle_info({:idle_shutdown, 999}, empty)
  end

  test "Instance covers queue, monitor, ownership, and initialization edge branches" do
    empty = instance_state()
    from = {self(), make_ref()}

    assert {:noreply, ^empty} =
             Instance.handle_info({:spectre, :advance, "missing"}, empty)

    out_of_order = %{empty | ready: :queue.in("other", :queue.new())}

    assert {:noreply, rescheduled} =
             Instance.handle_info({:spectre, :advance, "expected"}, out_of_order)

    assert rescheduled.ready == out_of_order.ready
    assert rescheduled.scheduled

    runner_view = %{
      empty
      | operation_runners: %{
          "attempt" => %{loop_id: "loop", operation: :execute}
        }
    }

    assert {:reply, %{operation_runners: operation_runners}, _data} =
             Instance.handle_call(:instance_info, from, runner_view)

    assert operation_runners == %{
             "attempt" => %{loop_id: "loop", operation: :execute}
           }

    checkpoint_monitor = make_ref()

    checkpoint =
      empty.canonical
      |> checkpoint_inflight(0)
      |> Map.merge(%{pid: self(), monitor: checkpoint_monitor})

    checkpoint_data = %{empty | checkpoint_inflight: checkpoint}

    assert {:noreply, ^checkpoint_data} =
             Instance.handle_info(
               {:DOWN, checkpoint_monitor, :process, self(), :normal},
               checkpoint_data
             )

    assert {:noreply, checkpoint_failed} =
             Instance.handle_info(
               {:DOWN, checkpoint_monitor, :process, self(), :checkpoint_crashed},
               checkpoint_data
             )

    assert checkpoint_failed.checkpoint_inflight == nil

    assert checkpoint_failed.checkpoint_reconciliation.reason ==
             {:checkpoint_task_down, :checkpoint_crashed}

    reconciliation_monitor = make_ref()
    reconciliation_tag = make_ref()

    reconciliation = %{
      token: "reconciliation",
      pid: self(),
      monitor: reconciliation_monitor,
      from: {self(), reconciliation_tag}
    }

    reconciliation_data = %{empty | checkpoint_reconcile_inflight: reconciliation}

    assert {:noreply, ^reconciliation_data} =
             Instance.handle_info(
               {:DOWN, reconciliation_monitor, :process, self(), :normal},
               reconciliation_data
             )

    assert {:noreply, reconciliation_failed} =
             Instance.handle_info(
               {:DOWN, reconciliation_monitor, :process, self(), :reconciliation_crashed},
               reconciliation_data
             )

    assert reconciliation_failed.checkpoint_reconcile_inflight == nil

    assert_receive {^reconciliation_tag,
                    {:error, {:checkpoint_reconciliation_task_down, :reconciliation_crashed}}}

    operation_monitor = make_ref()
    unknown_operation = %{empty | operation_monitors: %{self() => "missing-attempt"}}

    assert {:noreply, ^unknown_operation} =
             Instance.handle_info(
               {:DOWN, operation_monitor, :process, self(), :runner_crashed},
               unknown_operation
             )

    worker_monitor = make_ref()

    worker_data = %{
      empty
      | active: %{pid: self(), run_id: "missing-run"},
        workers: %{
          self() => %{
            monitor: worker_monitor,
            kind: :advance,
            run_id: "missing-run"
          }
        }
    }

    assert {:noreply, worker_failed} =
             Instance.handle_info(
               {:DOWN, worker_monitor, :process, self(), :worker_crashed},
               worker_data
             )

    assert worker_failed.active == nil
    assert worker_failed.workers == %{}

    {:continue, started} = Spectre.Runtime.start(@agent, "ping", run_id: "nil-waiting")
    {:boundary, _boundary, reply_run} = Spectre.Runtime.advance(started)
    reply_ref = reply_run.waiting.ref
    no_waiting = %{reply_run | waiting: nil}
    no_waiting_data = instance_state(runs: %{no_waiting.id => no_waiting})

    assert {:reply, {:error, {:run_not_waiting_for_invocation, "nil-waiting"}}, _data} =
             Instance.handle_call(
               {:instance_resume, reply_ref, {:execute, reply_ref.boundary_id}, []},
               from,
               no_waiting_data
             )

    reply_data = instance_state(runs: %{reply_run.id => reply_run})

    assert {:noreply, metadata_normalized} =
             Instance.handle_call(
               {:instance_resume, reply_ref, {:input, "again"}, [run_metadata: :invalid]},
               from,
               reply_data
             )

    assert is_map(metadata_normalized.entries[reply_run.id].opts[:run_metadata])
    assert_receive {:spectre, :advance, "nil-waiting"}

    assert %{id: {Instance, _key}} =
             Instance.child_spec(
               agent: @agent,
               agent_id: "coverage-agent",
               subject: "coverage-child-spec"
             )

    registry = SpectreInstanceCoverageFloorTest.InitRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    agent_ref = AgentRef.new(@agent)
    subject = Subject.new("coverage-init-subject")
    ref = InstanceRef.new(agent_ref, subject)

    init_opts = [
      agent: @agent,
      agent_ref: agent_ref,
      subject: subject,
      instance_ref: ref,
      registry: registry,
      state: %State{},
      operation_terminal_loop_retention: :unlimited,
      operation_correlation_retention: :unlimited
    ]

    previous_trap = Process.flag(:trap_exit, true)

    assert {:stop, :instance_registry_registration_lost} = Instance.init(init_opts)
    assert {:ok, _owner} = Registry.register(registry, ref.key, nil)
    assert {:ok, initialized} = Instance.init(init_opts)
    Process.demonitor(initialized.registry_monitor, [:flush])

    invalid_options = [
      {[max_runs: 0], {:invalid_instance_max_runs, 0}},
      {[max_tombstones: -1], {:invalid_instance_max_tombstones, -1}},
      {[max_operation_runners: 0], {:invalid_instance_max_runs, 0}},
      {[max_stream_sessions: 0], {:invalid_instance_option, :max_stream_sessions, 0}},
      {[
         operation_terminal_loop_retention: :invalid
       ], {:invalid_instance_retention, :operation_terminal_loop_retention, :invalid}},
      {[
         operation_correlation_retention: -1
       ], {:invalid_instance_retention, :operation_correlation_retention, -1}},
      {[inference_observer_lane: :enabled], {:invalid_inference_observer_lane, :enabled}},
      {[
         inference_progress_commit_interval: 0
       ], {:invalid_inference_progress_commit_interval, 0}},
      {[inference_progress_limit: 0], {:invalid_inference_progress_limit, 0}},
      {[
         inference_stream_checkpoint_interval: 0
       ], {:invalid_inference_stream_checkpoint_interval, 0}},
      {[receipt_mode: :unknown], {:invalid_receipt_mode, :unknown}},
      {[receipt_mode: :observational], :receipt_sink_required},
      {[receipt_mode: :required], :receipt_sink_required},
      {[
         receipt_outbox_limit: 0
       ], {:invalid_instance_option, :receipt_outbox_limit, 0}}
    ]

    Enum.each(invalid_options, fn {overrides, reason} ->
      assert {:stop, ^reason} = Instance.init(Keyword.merge(init_opts, overrides))
    end)

    assert {:stop, :instance_registry_unavailable} =
             Instance.init(
               Keyword.put(
                 init_opts,
                 :registry,
                 SpectreInstanceCoverageFloorTest.MissingRegistry
               )
             )

    Process.flag(:trap_exit, previous_trap)
  end

  test "Instance terminate stops both checkpoint task classes" do
    checkpoint_task = spawn(fn -> Process.sleep(:infinity) end)
    reconciliation_task = spawn(fn -> Process.sleep(:infinity) end)
    checkpoint_monitor = Process.monitor(checkpoint_task)
    reconciliation_monitor = Process.monitor(reconciliation_task)

    data = %{
      instance_state()
      | checkpoint_inflight: %{pid: checkpoint_task},
        checkpoint_reconcile_inflight: %{pid: reconciliation_task}
    }

    assert :ok = Instance.terminate(:shutdown, data)
    assert_receive {:DOWN, ^checkpoint_monitor, :process, ^checkpoint_task, :shutdown}
    assert_receive {:DOWN, ^reconciliation_monitor, :process, ^reconciliation_task, :shutdown}
  end

  test "Instance contains receipt task DOWNs and ignores late delivery races" do
    data = instance_state(receipt_mode: :required)
    staging_monitor = make_ref()
    staging_tag = make_ref()

    staging = %{
      token: "staging-token",
      pid: self(),
      monitor: staging_monitor,
      run: nil,
      resume: {:authority_decision, {self(), staging_tag}, :ignored},
      prepared: nil,
      attempt: 0
    }

    staging_data = %{
      data
      | receipt_staging: %{staging.token => staging},
        state_lock: %{receipt_id: "staging"}
    }

    assert {:noreply, ^staging_data} =
             Instance.handle_info(
               {:DOWN, staging_monitor, :process, self(), :normal},
               staging_data
             )

    assert {:noreply, staging_failed} =
             Instance.handle_info(
               {:DOWN, staging_monitor, :process, self(), :payload_task_crashed},
               staging_data
             )

    assert staging_failed.receipt_staging == %{}
    assert staging_failed.state_lock == nil

    assert_receive {^staging_tag,
                    {:error, {:required_receipt_payload_task_down, :payload_task_crashed}}}

    delivery_monitor = make_ref()

    observational = %{
      id: "observational-receipt",
      pid: self(),
      monitor: delivery_monitor,
      mode: :observational
    }

    observational_data = %{
      data
      | receipt_deliveries: %{observational.id => observational}
    }

    assert {:noreply, ^observational_data} =
             Instance.handle_info(
               {:DOWN, delivery_monitor, :process, self(), :normal},
               observational_data
             )

    assert {:noreply, observational_failed} =
             Instance.handle_info(
               {:DOWN, delivery_monitor, :process, self(), :sink_crashed},
               observational_data
             )

    assert observational_failed.receipt_deliveries == %{}
    assert observational_failed.receipt_retry_timers == %{}

    required = %{observational | id: "required-receipt", mode: :required}
    required_data = %{data | receipt_deliveries: %{required.id => required}}

    assert {:noreply, required_failed} =
             Instance.handle_info(
               {:DOWN, delivery_monitor, :process, self(), :sink_crashed},
               required_data
             )

    assert required_failed.receipt_deliveries == %{}
    assert Map.has_key?(required_failed.receipt_retry_timers, required.id)

    Enum.each(required_failed.receipt_retry_timers, fn {_id, timer} ->
      Process.cancel_timer(timer)
    end)
  end

  test "Instance heartbeats validate every stream fence and commit bounded recovery state" do
    {data, run, ownership, progress, checkpoint} = inference_heartbeat_fixture()
    invocation_id = ownership.invocation.id

    assert {:noreply, live} =
             Instance.handle_info(
               {:spectre, :inference_heartbeat, invocation_id, progress},
               data
             )

    assert live.inference_liveness_clock[invocation_id].sequence == progress.sequence

    stale_cases = [
      {%{data | stream_sessions: %{}}, progress, checkpoint},
      {%{data | invocations: %{invocation_id => %{ownership | dispatch_id: "other"}}}, progress,
       checkpoint},
      {data, %{progress | inference_id: "other"}, checkpoint},
      {data, %{progress | generation: "other"}, checkpoint},
      {data, %{progress | control_revision: progress.control_revision + 1}, checkpoint},
      {%{data | inference_liveness_clock: %{invocation_id => %{sequence: 2}}},
       %{progress | sequence: 1}, checkpoint},
      {data, %{progress | state: :invalid}, checkpoint},
      {data, progress, %{checkpoint | output_bytes: checkpoint.output_bytes + 1}},
      {data, progress, :invalid_checkpoint}
    ]

    Enum.each(stale_cases, fn {candidate, stale_progress, stale_checkpoint} ->
      assert {:noreply, rejected} =
               Instance.handle_info(
                 {:spectre, :inference_heartbeat, invocation_id, stale_progress,
                  stale_checkpoint},
                 candidate
               )

      assert rejected.inference_liveness_clock == candidate.inference_liveness_clock
    end)

    committing = %{
      data
      | base_opts:
          Keyword.merge(data.base_opts,
            inference_observer_lane: true,
            inference_progress_commit_interval: 1,
            inference_stream_checkpoint_interval: 1
          )
    }

    assert {:noreply, committed} =
             Instance.handle_info(
               {:spectre, :inference_heartbeat, invocation_id, progress, checkpoint},
               committing
             )

    assert committed.canonical.revision == committing.canonical.revision + 1
    assert committed.runs[run.id].inference_continuation.provider_status == :streaming

    assert {:ok, committed_progress_entries} =
             Canonical.fetch(committed.canonical, :inference_progress)

    committed_progress = Map.fetch!(committed_progress_entries, progress.inference_id)

    assert committed_progress.canonical_revision == committed.canonical.revision

    # A second identical cursor is not a meaningful checkpoint change, while
    # the liveness clock remains current.
    assert {:noreply, duplicate} =
             Instance.handle_info(
               {:spectre, :inference_heartbeat, invocation_id, progress, checkpoint},
               committed
             )

    assert duplicate.runs[run.id] == committed.runs[run.id]
  end

  test "Instance turns abnormal inference and effect worker exits into durable terminal receipts" do
    {base, inference_run, inference_ownership, _progress, _checkpoint} =
      inference_heartbeat_fixture()

    inference_pid = self()
    inference_monitor = make_ref()

    inference_ownership = %{
      inference_ownership
      | mode: :one_shot,
        pid: inference_pid,
        monitor: inference_monitor
    }

    inference_worker = Map.put(inference_ownership, :kind, :invocation)

    inference_data = %{
      base
      | invocations: %{inference_ownership.invocation.id => inference_ownership},
        stream_sessions: %{},
        workers: %{inference_pid => inference_worker},
        state_lock: %{
          run_id: inference_run.id,
          invocation_id: inference_ownership.invocation.id
        }
    }

    assert {:noreply, inference_failed} =
             Instance.handle_info(
               {:DOWN, inference_monitor, :process, inference_pid, :provider_crashed},
               inference_data
             )

    assert inference_failed.workers == %{}
    assert inference_failed.invocations == %{}
    assert inference_failed.runs[inference_run.id].status == :failed

    data = instance_state()
    opts = [run_id: "effect-worker-down"]

    assert {:ok, admitted} =
             Spectre.Runtime.admit(
               @agent,
               Spectre.Input.new("work"),
               data.state,
               opts,
               opts
             )

    assert {:await, %Invocation{kind: :effect} = invocation, awaiting} =
             Spectre.Runtime.advance(admitted, opts)

    effect_pid = self()
    effect_monitor = make_ref()

    entry = %{
      run_id: awaiting.id,
      operation: :advance,
      projection: :result,
      input: awaiting.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false
    }

    effect_ownership = %{
      kind: :invocation,
      invocation_id: invocation.id,
      invocation: invocation,
      run_id: awaiting.id,
      run_revision: awaiting.revision,
      generation: data.generation,
      dispatch_id: "effect-worker-dispatch",
      capability: make_ref(),
      pid: effect_pid,
      monitor: effect_monitor,
      entry: entry
    }

    effect_data = %{
      data
      | runs: %{awaiting.id => awaiting},
        invocations: %{invocation.id => effect_ownership},
        workers: %{effect_pid => effect_ownership},
        state_lock: %{run_id: awaiting.id, invocation_id: invocation.id}
    }

    assert {:noreply, effect_failed} =
             Instance.handle_info(
               {:DOWN, effect_monitor, :process, effect_pid, :executor_crashed},
               effect_data
             )

    assert effect_failed.workers == %{}
    assert effect_failed.invocations == %{}
    assert effect_failed.runs[awaiting.id].status == :failed
    assert {:effect_worker_down, :executor_crashed} = effect_failed.runs[awaiting.id].last_error
  end

  test "Instance receipts a policy worker crash and contains unexpected worker code" do
    data = instance_state()
    opts = [run_id: "policy-worker-down"]

    assert {:ok, admitted} =
             Spectre.Runtime.admit(
               @agent,
               Spectre.Input.new("ping"),
               data.state,
               opts,
               opts
             )

    boundary_ref = Run.ref(admitted, :policy, "policy-worker-boundary")

    boundary = %Boundary{
      id: "policy-worker-boundary",
      kind: :needs,
      ref: boundary_ref
    }

    policy_run = %{admitted | status: :boundary, cursor: :policy, waiting: boundary}
    policy_pid = self()
    policy_monitor = make_ref()

    entry = %{
      run_id: policy_run.id,
      operation: {:resume, {:policy, boundary_ref, {:accept, :approved}}},
      projection: :result,
      input: policy_run.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: false
    }

    worker = %{
      kind: :advance,
      run_id: policy_run.id,
      pid: policy_pid,
      monitor: policy_monitor,
      entry: entry
    }

    policy_data = %{
      data
      | runs: %{policy_run.id => policy_run},
        workers: %{policy_pid => worker},
        active: worker
    }

    assert {:noreply, policy_failed} =
             Instance.handle_info(
               {:DOWN, policy_monitor, :process, policy_pid, :classifier_crashed},
               policy_data
             )

    assert policy_failed.active == nil
    assert policy_failed.workers == %{}
    assert policy_failed.runs[policy_run.id].status == :failed

    unexpected_opts = [run_id: "unexpected-worker-code"]

    assert {:ok, unexpected_run} =
             Spectre.Runtime.admit(
               @agent,
               Spectre.Input.new("ping"),
               data.state,
               unexpected_opts,
               unexpected_opts
             )

    unexpected_entry = %{
      run_id: unexpected_run.id,
      operation: :unsupported_test_operation,
      projection: :result,
      input: unexpected_run.input,
      opts: unexpected_opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false
    }

    queued = %{
      data
      | runs: %{unexpected_run.id => unexpected_run},
        ready: :queue.in(unexpected_run.id, :queue.new()),
        queued: MapSet.new([unexpected_run.id]),
        entries: %{unexpected_run.id => unexpected_entry},
        scheduled: true
    }

    assert {:noreply, running} =
             Instance.handle_info({:spectre, :advance, unexpected_run.id}, queued)

    assert_receive {:spectre, :advance_result, run_id, dispatch_id, capability,
                    {:error, {:instance_worker_exception, FunctionClauseError}, failed}, samples},
                   1_000

    assert run_id == unexpected_run.id
    assert failed.status == :failed

    assert {:noreply, contained} =
             Instance.handle_info(
               {:spectre, :advance_result, run_id, dispatch_id, capability,
                {:error, failed.last_error, failed}, samples},
               running
             )

    assert contained.runs[unexpected_run.id].status == :failed
  end

  defp instance_state(overrides \\ []) do
    agent_ref = AgentRef.new(@agent)
    subject = Subject.new("instance-coverage-subject")
    ref = InstanceRef.new(agent_ref, subject)
    state = %State{conversation_id: ref.key}
    canonical = canonical(ref, state, 0)

    owner_lease =
      Lease.new!(
        owner_id: "instance-coverage-owner",
        fencing_token: 1,
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
      definition_store: nil,
      owner: {Spectre.Instance.Owner.Local, []},
      owner_lease: owner_lease,
      base_opts: [conversation_id: ref.key],
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      max_stream_sessions: 4,
      stream_registry: Spectre.Inference.StreamRegistry,
      stream_capacity: Spectre.Inference.StreamCapacity,
      generation: "instance-coverage-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0,
      receipt_mode: :disabled,
      receipt_sink: nil,
      max_receipt_outbox: 16
    }

    struct!(InstanceState, Map.merge(defaults, Map.new(overrides)))
  end

  defp canonical(ref, state, revision) do
    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    %{canonical | revision: revision}
  end

  defp encode_canonical(canonical) do
    {:ok, encoded} = CanonicalCodec.encode_json(canonical)
    encoded
  end

  defp checkpoint_inflight(canonical, expected_revision) do
    %{
      token: "checkpoint-token",
      revision: canonical.revision,
      expected_revision: expected_revision,
      canonical: canonical,
      pid: self(),
      monitor: make_ref()
    }
  end

  defp initial_run(id) do
    Run.new(@agent, Spectre.Input.new("ping"), %State{}, run_id: id)
  end

  defp inference_heartbeat_fixture do
    data = instance_state()
    inference_id = "heartbeat-inference"

    request =
      InferenceRequest.new(
        id: inference_id,
        purpose: :response_generation,
        plan: %Plan{rendered: "heartbeat"},
        constraints: Constraints.new([]),
        metadata: %{}
      )

    descriptor = Descriptor.from_request(request, streaming?: true)

    selection =
      Selection.new(
        request_id: inference_id,
        level: :default,
        model: @agent,
        reason: :test,
        selector: Spectre.Inference.Selector.Default
      )

    frozen = FrozenSelection.from_selection(selection)
    continuation = InferenceContinuation.new(descriptor, frozen_selection: frozen)
    run = Run.new(@agent, Spectre.Input.new("heartbeat"), data.state, run_id: "heartbeat-run")
    run = %{run | revision: 1}
    invocation = Invocation.from_inference(run, continuation, streaming?: true)

    continuation = %{
      continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch,
        provider_status: :dispatching
    }

    run = %{
      run
      | status: :awaiting,
        cursor: :inference,
        waiting: invocation,
        inference_continuation: continuation
    }

    ownership = %{
      mode: :stream,
      invocation_id: invocation.id,
      invocation_kind: :inference,
      invocation: invocation,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: "heartbeat-dispatch",
      capability: make_ref(),
      pid: self(),
      monitor: make_ref()
    }

    usage = %Usage{input_tokens: 2, output_tokens: 1, total_tokens: 3, output_bytes: 4}

    {:ok, checkpoint} =
      StreamCheckpoint.new("provider-request", %{offset: 4},
        provider_sequence: 2,
        usage: usage,
        usage_quality: :provider,
        output_bytes: 4
      )

    progress =
      Progress.new(
        inference_id: inference_id,
        invocation_id: invocation.id,
        attempt_id: invocation.attempt_id,
        run_revision: run.revision,
        generation: data.generation,
        dispatch_id: ownership.dispatch_id,
        control_revision: invocation.control_revision,
        stream_epoch: invocation.stream_epoch,
        sequence: 1,
        provider_request_digest: checkpoint.provider_request_digest,
        provider_cursor_digest: checkpoint.resume_cursor_digest,
        state: :streaming,
        at: 1,
        output_bytes: 4,
        usage: usage,
        usage_quality: :provider
      )

    data = %{
      data
      | runs: %{run.id => run},
        invocations: %{invocation.id => ownership},
        stream_sessions: %{invocation.id => ownership}
    }

    {data, run, ownership, progress, checkpoint}
  end

  defp run_ref(run_id, revision) do
    Spectre.Run.Ref.new(run_id, revision, :reply, "boundary-#{run_id}")
  end
end
