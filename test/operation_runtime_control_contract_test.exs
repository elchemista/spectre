defmodule SpectreOperationRuntimeControlContractTest.Agent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreOperationRuntimeControlContractTest.Operations do
  @moduledoc false
  def execute(input, _context), do: {:ok, input}
  def reconcile(receipt, _context), do: {:ok, receipt}
end

defmodule SpectreOperationRuntimeControlContractTest.Work do
  @moduledoc false

  use Spectre.Work,
    id: :runtime_control_contract,
    version: 1,
    input: :map,
    state: :map,
    update: :map,
    update_fields: [:items],
    branches: %{selected: [:echo]},
    waits: [:external],
    triggers: [:external, :human],
    blockers: [:approval],
    on_budget_exhausted: :controller,
    security: %{allow_immediate_pause: true},
    artifact_policy: %{allowed_kinds: [:report], max_count: 2}

  operation(:echo, {SpectreOperationRuntimeControlContractTest.Operations, :execute},
    input: :map,
    output: :map,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  operation(:idempotent, {SpectreOperationRuntimeControlContractTest.Operations, :execute},
    input: :map,
    output: :map,
    side_effect: :idempotent,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  operation(:reconcilable, {SpectreOperationRuntimeControlContractTest.Operations, :execute},
    input: :map,
    output: :map,
    side_effect: :reconcilable,
    reconcile: {SpectreOperationRuntimeControlContractTest.Operations, :reconcile}
  )

  operation(:non_idempotent, {SpectreOperationRuntimeControlContractTest.Operations, :execute},
    input: :map,
    output: :map,
    side_effect: :non_idempotent
  )

  @impl true
  def init(%{init_reply: :error}, _context), do: {:error, :init_failed}
  def init(%{init_reply: :invalid}, _context), do: :invalid_init
  def init(%{init_reply: :invalid_state}, _context), do: {:ok, :invalid_state}
  def init(%{init_reply: :nonportable}, _context), do: {:ok, %{pid: self()}}

  def init(input, _context) do
    {:ok,
     Map.merge(
       %{
         mode: :run,
         operation: :echo,
         items: Map.get(input, :items, []),
         done?: false,
         value: nil,
         completion: :complete,
         transition_opts: %{}
       },
       input
     )}
  end

  @impl true
  def next(%{mode: :wait}, _context), do: wait(:external)
  def next(%{mode: :invalid_wait}, _context), do: wait(:timer)
  def next(%{mode: :block}, _context), do: blocked(:approval)
  def next(%{mode: :invalid_block}, _context), do: blocked(:undeclared)
  def next(%{mode: :direct_complete, value: value}, _context), do: complete(value)
  def next(%{mode: :direct_error}, _context), do: fail(:declared_failure)

  def next(%{mode: :triple_run, operation: operation} = state, _context),
    do: {:run, operation, %{items: state.items}}

  def next(%{mode: :selected_branch} = state, _context),
    do: run(:echo, %{items: state.items}, branch: :selected)

  def next(%{mode: :outside_branch} = state, _context),
    do: run(:idempotent, %{items: state.items}, branch: :selected)

  def next(%{mode: :unknown_branch} = state, _context),
    do: run(:echo, %{items: state.items}, branch: :unknown)

  def next(%{mode: :invalid_next}, _context), do: :invalid_next
  def next(%{mode: :raise_next}, _context), do: raise("next failed")
  def next(%{mode: :throw_next}, _context), do: throw(:next_failed)

  def next(%{mode: :run, operation: operation} = state, _context),
    do: run(operation, %{items: state.items}, phase: :executing)

  @impl true
  def apply_result(%{reducer_error: reason}, _request, _result, _context),
    do: {:error, reason}

  def apply_result(%{reducer_reply: :invalid}, _request, _result, _context),
    do: :invalid_reducer

  def apply_result(%{reducer_reply: :invalid_options} = state, _request, result, _context),
    do: {:ok, %{state | done?: true, value: result.value}, [:not_keyword]}

  def apply_result(%{reducer_reply: :keyword} = state, _request, result, _context),
    do: {:ok, %{state | done?: true, value: result.value}, phase: :keyword_reducer}

  def apply_result(%{reducer_reply: :invalid_state}, _request, _result, _context),
    do: {:ok, :invalid_state}

  def apply_result(%{reducer_reply: :nonportable_state} = state, _request, _result, _context),
    do: {:ok, Map.put(state, :pid, self())}

  def apply_result(state, _request, result, _context) do
    {:ok, %{state | done?: true, value: result.value}, state.transition_opts}
  end

  @impl true
  def complete(%{done?: false}, _context), do: :continue
  def complete(%{completion: :continue}, _context), do: :continue
  def complete(%{completion: false}, _context), do: false
  def complete(%{completion: :block}, _context), do: blocked(:approval)
  def complete(%{completion: :error}, _context), do: fail(:completion_failed)
  def complete(%{completion: :invalid}, _context), do: :invalid_decision
  def complete(%{completion: :raise}, _context), do: raise("completion failed")
  def complete(%{completion: :throw}, _context), do: throw(:completion_failed)
  def complete(%{value: value}, _context), do: complete(value)

  @impl true
  def apply_update(_state, _input, %{payload: %{reply: :error}}, _context),
    do: {:error, :update_failed}

  def apply_update(_state, _input, %{payload: %{reply: :invalid}}, _context),
    do: :invalid_update

  def apply_update(state, input, %{payload: %{reply: :invalid_options} = payload}, _context),
    do: {:ok, %{state | items: payload.items}, %{input | items: payload.items}, [:not_keyword]}

  def apply_update(state, input, %{payload: %{reply: :keyword} = payload}, _context),
    do:
      {:ok, %{state | items: payload.items}, %{input | items: payload.items},
       [phase: :keyword_update]}

  def apply_update(state, input, update, _context) do
    updated_input = Map.put(input, :items, update.payload.items)

    updated_input =
      if Map.get(update.payload, :change_undeclared?, false),
        do: Map.put(updated_input, :undeclared, true),
        else: updated_input

    opts = %{
      invalidations: Map.get(update.payload, :invalidations, []),
      cognitive: Map.get(update.payload, :cognitive, %{})
    }

    {:ok, %{state | items: update.payload.items, done?: false}, updated_input, opts}
  end

  @impl true
  def handle_trigger(_state, {:external, :callback_error}, _context),
    do: {:error, :trigger_failed}

  def handle_trigger(_state, {:external, :callback_invalid}, _context),
    do: :invalid_trigger

  def handle_trigger(state, {:external, :callback_invalid_options}, _context),
    do: {:ok, state, [:not_keyword]}

  def handle_trigger(state, {:external, :callback_keyword}, _context),
    do: {:ok, %{state | mode: :direct_complete}, phase: :triggered_phase}

  def handle_trigger(state, {_type, next_mode}, _context),
    do: {:ok, %{state | mode: next_mode}}

  def handle_trigger(state, _trigger, _context), do: {:ok, state}

  @impl true
  def budget_exhausted(%{budget_decision: :nonportable_reason}, _exhaustion, _context),
    do: {:terminate, self()}

  def budget_exhausted(%{budget_decision: :nonportable_metadata}, _exhaustion, _context),
    do: {:terminate, :limit, %{pid: self()}}

  def budget_exhausted(%{budget_decision: :raise}, _exhaustion, _context),
    do: raise("budget failed")

  def budget_exhausted(%{budget_decision: :throw}, _exhaustion, _context),
    do: throw(:budget_failed)

  def budget_exhausted(%{budget_decision: decision}, _exhaustion, _context), do: decision
  def budget_exhausted(_state, _exhaustion, _context), do: :terminate
end

defmodule SpectreOperationRuntimeControlContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Operation.Artifact
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime

  @agent SpectreOperationRuntimeControlContractTest.Agent
  @work SpectreOperationRuntimeControlContractTest.Work

  test "declared wait, blocker, completion and failure boundaries are deterministic" do
    env = env()

    {:ok, waiting_loop, waiting_control, _events} =
      Runtime.start(:work, @work, %{mode: :wait}, [], env)

    assert {:transition, waiting, ^waiting_control, [%{type: :waiting}]} =
             Runtime.prepare(waiting_loop, waiting_control, env)

    assert waiting.status == :waiting
    assert waiting.wait.kind == :external

    assert {:error, {:stale_loop_trigger_generation, 99, 0}} =
             Runtime.trigger(
               waiting,
               waiting_control,
               {:external, :direct_complete},
               [generation: 99],
               env
             )

    assert {:error, {:stale_loop_wait, "wrong"}} =
             Runtime.trigger(
               waiting,
               waiting_control,
               {:external, :direct_complete},
               [wait_id: "wrong"],
               env
             )

    assert {:ok, triggered, ^waiting_control, [%{type: :triggered}]} =
             Runtime.trigger(
               waiting,
               waiting_control,
               {:external, :direct_complete},
               [wait_id: waiting.wait.id, generation: waiting.trigger_generation],
               env
             )

    assert triggered.status == :queued
    assert triggered.wait == nil

    assert {:transition, terminal, terminal_control, [%{type: :completed}]} =
             Runtime.prepare(triggered, waiting_control, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :completed
    assert terminal_control.state == :terminal

    {:ok, blocked_loop, blocked_control, _events} =
      Runtime.start(:work, @work, %{mode: :block}, [], env)

    assert {:transition, blocked, ^blocked_control, [%{type: :blocked}]} =
             Runtime.prepare(blocked_loop, blocked_control, env)

    assert blocked.status == :waiting
    assert blocked.blocker == :approval
    assert blocked.wait.kind == :human

    assert {:ok, unblocked, ^blocked_control, [%{type: :triggered}]} =
             Runtime.trigger(
               blocked,
               blocked_control,
               {:human, :direct_complete},
               [wait_id: blocked.wait.id, generation: blocked.trigger_generation],
               env
             )

    assert unblocked.blocker == nil

    Enum.each(
      [
        {%{mode: :direct_error}, :declared_failure},
        {%{mode: :invalid_wait}, {:undeclared_operational_wait, :timer}},
        {%{mode: :invalid_block}, {:undeclared_operational_blocker, :undeclared}}
      ],
      fn {input, reason} ->
        {:ok, loop, control, _events} = Runtime.start(:work, @work, input, [], env)

        assert {:transition, failed, failed_control, [%{type: :failed}]} =
                 Runtime.prepare(loop, control, env)

        assert failed.outcome.category == :failed
        assert failed.outcome.reason == reason
        assert failed_control.state == :terminal
      end
    )
  end

  test "safe and immediate controls preserve boundaries, fencing and terminal stop" do
    env = env()
    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{mode: :wait}, [], env)
    {:transition, waiting, control, _events} = Runtime.prepare(loop, control, env)

    pause = Command.new(waiting.id, :pause, id: "safe-pause", correlation_id: "safe")

    assert {:ok, paused, paused_control, :keep_runner, [%{type: :paused}]} =
             Runtime.request_control(waiting, control, pause, env)

    assert paused.status == :paused
    assert paused.wait == waiting.wait
    assert paused_control.state == :paused

    assert {:duplicate, ^paused, ^paused_control} =
             Runtime.request_control(paused, paused_control, pause, env)

    resume = Command.new(paused.id, :resume, id: "resume", correlation_id: "resume")

    assert {:ok, resumed, resumed_control, :keep_runner, [%{type: :resumed}]} =
             Runtime.request_control(paused, paused_control, resume, env)

    assert resumed.status == :waiting
    assert resumed.wait == waiting.wait
    assert resumed_control.state == :active
    assert resumed_control.generation > paused_control.generation

    stale =
      Command.new(resumed.id, :renew,
        id: "stale-renew",
        correlation_id: "stale",
        payload: %{expires_at: env.now + 1_000},
        base_revision: resumed.revision - 1
      )

    assert {:error, {:stale_loop_control_revision, _, _}} =
             Runtime.request_control(resumed, resumed_control, stale, env)

    renew =
      Command.new(resumed.id, :renew,
        id: "renew",
        correlation_id: "renew",
        payload: %{expires_at: env.now + 1_000}
      )

    assert {:ok, renewed, renewed_control, :keep_runner, [%{type: :renewed}]} =
             Runtime.request_control(resumed, resumed_control, renew, env)

    assert renewed.expires_at == env.now + 1_000

    stop =
      Command.new(renewed.id, :stop,
        id: "stop",
        correlation_id: "stop",
        payload: :user_cancelled
      )

    assert {:ok, stopped, stopped_control, :keep_runner, [%{type: :cancelled}]} =
             Runtime.request_control(renewed, renewed_control, stop, env)

    assert stopped.status == :terminal
    assert stopped.outcome.category == :cancelled
    assert stopped.wait == nil
    assert stopped_control.state == :terminal

    assert {:error, :loop_terminal} =
             Runtime.request_control(stopped, stopped_control, resume, env)

    {:ok, run_loop, run_control, _events} =
      Runtime.start(:work, @work, %{operation: :idempotent}, [], env)

    {:run, active, attempt, _spec, _request, false, _events} =
      Runtime.prepare(run_loop, run_control, env)

    immediate =
      Command.new(active.id, :pause,
        id: "immediate",
        correlation_id: "immediate",
        mode: :immediate
      )

    assert {:ok, interrupted, interrupted_control, {:terminate_runner, attempt_id}, events} =
             Runtime.request_control(active, run_control, immediate, env)

    assert attempt_id == attempt.id
    assert interrupted.status == :paused
    assert interrupted.attempt == nil
    assert Enum.map(events, & &1.type) == [:paused]

    stale_result = Result.new(attempt, :ok, %{items: []})

    assert {:error, :loop_has_no_active_attempt} =
             Runtime.apply_result(interrupted, interrupted_control, stale_result, env)

    immediate_resume =
      Command.new(interrupted.id, :resume,
        id: "immediate-resume",
        correlation_id: "immediate-resume"
      )

    assert {:ok, requeued, active_control, :keep_runner, _events} =
             Runtime.request_control(
               interrupted,
               interrupted_control,
               immediate_resume,
               env
             )

    assert requeued.status == :queued
    assert active_control.state == :active
  end

  test "safe pause waits for the Result commit before applying the pending command" do
    env = env()

    {:ok, loop, control, _events} =
      Runtime.start(:work, @work, %{completion: :continue}, [], env)

    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    pause = Command.new(active.id, :pause, id: "boundary-pause", correlation_id: "boundary")

    assert {:ok, pause_requested, pending_control, :keep_runner, [%{type: :pause_requested}]} =
             Runtime.request_control(active, control, pause, env)

    assert pause_requested.status == :pause_requested
    assert pending_control.pending.id == pause.id

    result = Result.new(attempt, :ok, %{items: []})

    assert {:ok, evaluating, ^pending_control, [%{type: :attempt_committed}]} =
             Runtime.apply_result(pause_requested, pending_control, result, env)

    assert {:ok, boundary, ^pending_control, [%{type: :safe_boundary_reached}]} =
             Runtime.evaluate(evaluating, pending_control, env)

    assert boundary.status == :paused

    assert {:ok, paused, paused_control, [%{type: :paused}]} =
             Runtime.advance_control(boundary, pending_control, env)

    assert paused.status == :paused
    assert paused_control.pending == nil
    assert paused_control.last_command.id == pause.id
  end

  test "failure, retry, reconciliation and unknown side effects take distinct paths" do
    env = env()

    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{}, [], env)
    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    timeout = Result.new(attempt, :error, :timeout)

    assert {:ok, waiting, ^control, [%{type: :retry_scheduled}]} =
             Runtime.apply_result(active, control, timeout, env)

    assert waiting.wait.kind == :retry
    assert waiting.retries == 1

    assert {:ok, retry_queued, ^control, [%{type: :triggered}]} =
             Runtime.trigger(
               waiting,
               control,
               {:timer, waiting.wait.id},
               [wait_id: waiting.wait.id, generation: waiting.trigger_generation],
               env
             )

    assert {:run, retrying, retry_attempt, _spec, _request, false, _events} =
             Runtime.prepare(retry_queued, control, env)

    assert retry_attempt.retry_number == 1

    final_timeout = Result.new(retry_attempt, :error, :timeout)

    assert {:ok, failed, failed_control, events} =
             Runtime.apply_result(retrying, control, final_timeout, env)

    assert failed.outcome.category == :failed
    assert failed_control.state == :terminal
    assert Enum.map(events, & &1.type) == [:attempt_failed, :failed]

    {:ok, recon_loop, recon_control, _events} =
      Runtime.start(:work, @work, %{operation: :reconcilable}, [], env)

    {:run, recon_active, recon_attempt, _spec, _request, false, _events} =
      Runtime.prepare(recon_loop, recon_control, env)

    ambiguous = Result.new(recon_attempt, :ambiguous, :connection_lost)

    assert {:ok, reconciling, ^recon_control, [%{type: :reconciliation_required}]} =
             Runtime.apply_result(recon_active, recon_control, ambiguous, env)

    assert reconciling.status == :reconciling

    assert {:run, _active_reconciliation, _attempt, _spec, request, true, _events} =
             Runtime.prepare(reconciling, recon_control, env)

    assert request.phase == :reconciliation

    {:ok, unknown_loop, unknown_control, _events} =
      Runtime.start(:work, @work, %{operation: :non_idempotent}, [], env)

    {:run, unknown_active, unknown_attempt, _spec, _request, false, _events} =
      Runtime.prepare(unknown_loop, unknown_control, env)

    unknown = Result.new(unknown_attempt, :ambiguous, :connection_lost)

    assert {:ok, unknown_wait, ^unknown_control, [%{type: :side_effect_outcome_unknown}]} =
             Runtime.apply_result(unknown_active, unknown_control, unknown, env)

    assert unknown_wait.status == :waiting
    assert unknown_wait.wait.kind == :reconciliation

    assert {:ok, stopped, stopped_control, {:terminate_runner, stopped_attempt}, events} =
             Runtime.request_control(
               unknown_active,
               unknown_control,
               Command.new(unknown_active.id, :stop,
                 id: "unknown-stop",
                 correlation_id: "unknown-stop"
               ),
               env
             )

    assert stopped_attempt == unknown_attempt.id
    assert stopped.outcome.category == :unknown_side_effect
    assert stopped_control.state == :terminal
    assert Enum.map(events, & &1.type) == [:side_effect_outcome_unknown]
  end

  test "updates are revisioned, field-limited, idempotent and provenance preserving" do
    env = env()

    {:ok, loop, control, _events} =
      Runtime.start(:work, @work, %{mode: :wait, items: [1]}, [], env)

    {:transition, waiting, control, _events} = Runtime.prepare(loop, control, env)

    update =
      Command.new(waiting.id, :update_and_resume,
        id: "update",
        correlation_id: "update-correlation",
        causation_id: "message",
        provenance: %{source: :chat},
        payload: %{items: [1, 2], invalidations: [:old_result]}
      )

    assert {:ok, updated, updated_control, :keep_runner, events} =
             Runtime.request_control(waiting, control, update, env)

    assert updated.status == :queued
    assert updated.context_revision == 1
    assert updated.effective_input.items == [1, 2]
    assert updated.last_update.provenance == %{source: :chat}
    assert updated.invalidations == [:old_result]
    assert updated_control.state == :active
    assert Enum.map(events, & &1.type) == [:update_applied, :resumed]

    assert {:duplicate, ^updated, ^updated_control} =
             Runtime.request_control(updated, updated_control, update, env)

    invalid =
      Command.new(updated.id, :update,
        id: "invalid-update",
        correlation_id: "invalid-update",
        payload: %{items: [3], change_undeclared?: true}
      )

    assert {:ok, rejected, rejected_control, :keep_runner, [%{type: :control_rejected}]} =
             Runtime.request_control(updated, updated_control, invalid, env)

    assert rejected.status == :paused
    assert rejected.context_revision == 1
    assert rejected.last_update.status == :rejected
    assert rejected_control.last_command.status == :rejected

    resume =
      Command.new(rejected.id, :resume,
        id: "resume-rejected",
        correlation_id: "resume-rejected"
      )

    assert {:ok, resumed, _control, :keep_runner, _events} =
             Runtime.request_control(rejected, rejected_control, resume, env)

    assert resumed.status == :queued
  end

  test "artifact policy and budget exhaustion fail closed with typed outcomes" do
    env = env()
    artifact = Artifact.new(kind: :report)

    {:ok, loop, control, _events} =
      Runtime.start(
        :work,
        @work,
        %{transition_opts: %{artifacts: [artifact]}},
        [],
        env
      )

    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)
    result = Result.new(attempt, :ok, %{items: []})

    assert {:ok, committed, ^control, [%{type: :attempt_committed}]} =
             Runtime.apply_result(active, control, result, env)

    assert committed.artifacts == [artifact]

    {:ok, invalid_loop, invalid_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{transition_opts: %{artifacts: [%{kind: :secret}]}},
        [],
        env
      )

    {:run, invalid_active, invalid_attempt, _spec, _request, false, _events} =
      Runtime.prepare(invalid_loop, invalid_control, env)

    assert {:error, {:operation_artifact_kind_not_allowed, :secret}} =
             Runtime.apply_result(
               invalid_active,
               invalid_control,
               Result.new(invalid_attempt, :ok, %{}),
               env
             )

    {:ok, budget_loop, budget_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{budget_decision: {:terminate, :custom_limit, %{policy: :controller}}},
        [budget: [attempts: 0]],
        env
      )

    assert {:transition, exhausted, exhausted_control, [%{type: :budget_exhausted}]} =
             Runtime.prepare(budget_loop, budget_control, env)

    assert exhausted.outcome.category == :budget_exhausted
    assert exhausted.outcome.reason == :custom_limit
    assert exhausted.outcome.metadata.behavior == :controller
    assert exhausted.outcome.metadata.policy == :controller
    assert exhausted_control.state == :terminal

    {:ok, expiring, expiring_control, _events} =
      Runtime.start(:work, @work, %{}, [expires_at: env.now], env)

    assert {:transition, expired, terminal_control, [%{type: :budget_exhausted}]} =
             Runtime.prepare(expiring, expiring_control, env)

    assert expired.outcome.category == :expired
    assert terminal_control.state == :terminal
  end

  test "startup and preparation reject malformed controller and option boundaries" do
    env = env()

    assert {:error, {:loop_definition_kind_mismatch, :vigil, :work}} =
             Runtime.start(:vigil, @work, %{}, [], env)

    assert {:error, {:invalid_operation_value, {:loop_input, :runtime_control_contract}, :map, _}} =
             Runtime.start(:work, @work, :invalid_input, [], env)

    assert {:error, {:nonportable_operational_value, _reason}} =
             Runtime.start(:work, @work, %{pid: self()}, [], env)

    assert {:error, :init_failed} =
             Runtime.start(:work, @work, %{init_reply: :error}, [], env)

    assert {:error, {:invalid_controller_init, :invalid_init}} =
             Runtime.start(:work, @work, %{init_reply: :invalid}, [], env)

    assert {:error, {:invalid_operation_value, {:loop_state, :runtime_control_contract}, :map, _}} =
             Runtime.start(:work, @work, %{init_reply: :invalid_state}, [], env)

    assert {:error, {:nonportable_operational_value, _reason}} =
             Runtime.start(:work, @work, %{init_reply: :nonportable}, [], env)

    assert {:error, {:invalid_operational_budget, _message}} =
             Runtime.start(:work, @work, %{}, [budget: :invalid], env)

    assert {:error, {:invalid_operational_map_option, :cognitive}} =
             Runtime.start(:work, @work, %{}, [cognitive: [:not_keyword]], env)

    assert {:error, {:invalid_operational_map_option, :metadata}} =
             Runtime.start(:work, @work, %{}, [metadata: :invalid], env)

    assert {:ok, normalized, _control, _events} =
             Runtime.start(
               :work,
               @work,
               %{},
               [cognitive: [temperature: 0], metadata: [source: :test]],
               env
             )

    assert normalized.cognitive == %{temperature: 0}
    assert normalized.metadata.source == :test

    assert {:error, :duplicate_operational_authorized_origin} =
             Runtime.start(
               :work,
               @work,
               %{},
               [authorized_origins: [:one, :one]],
               env
             )

    assert {:error, :duplicate_operational_destination} =
             Runtime.start(:work, @work, %{}, [destinations: [:one, :one]], env)

    assert {:error, {:operational_visibility_not_authorized, :private}} =
             Runtime.start(:work, @work, %{}, [visibility: :private], env)

    {:ok, terminal_candidate, terminal_control, _events} =
      Runtime.start(:work, @work, %{mode: :direct_complete}, [], env)

    {:transition, terminal, terminal_control, _events} =
      Runtime.prepare(terminal_candidate, terminal_control, env)

    assert {:error, :loop_terminal} = Runtime.prepare(terminal, terminal_control, env)

    {:ok, queued, active_control, _events} = Runtime.start(:work, @work, %{}, [], env)

    assert {:error, {:loop_not_active, :paused}} =
             Runtime.prepare(queued, %{active_control | state: :paused}, env)

    {:run, active, _attempt, _spec, _request, false, _events} =
      Runtime.prepare(queued, active_control, env)

    assert {:error, {:loop_attempt_already_active, _attempt_id}} =
             Runtime.prepare(active, active_control, env)

    for mode <- [:triple_run, :selected_branch] do
      {:ok, loop, control, _events} = Runtime.start(:work, @work, %{mode: mode}, [], env)

      assert {:run, _active, _attempt, _spec, _request, false, _events} =
               Runtime.prepare(loop, control, env)
    end

    failures = [
      outside_branch: {:operation_outside_declared_branch, :selected, :idempotent},
      unknown_branch: {:undeclared_work_branch, :unknown},
      invalid_next: {:invalid_controller_next, :invalid_next}
    ]

    Enum.each(failures, fn {mode, expected} ->
      {:ok, loop, control, _events} = Runtime.start(:work, @work, %{mode: mode}, [], env)

      assert {:transition, failed, _control, [%{type: :failed}]} =
               Runtime.prepare(loop, control, env)

      assert failed.outcome.reason == expected
    end)

    for {mode, failure_kind} <- [
          raise_next: :controller_callback_exception,
          throw_next: :controller_callback_failure
        ] do
      {:ok, loop, control, _events} = Runtime.start(:work, @work, %{mode: mode}, [], env)
      assert {:transition, failed, _control, _events} = Runtime.prepare(loop, control, env)
      assert elem(failed.outcome.reason, 0) == failure_kind
    end
  end

  test "result reducers and completion callbacks normalize all supported reply shapes" do
    env = env()

    reducer_errors = [
      {%{reducer_error: :declared}, :declared},
      {%{reducer_reply: :invalid}, {:invalid_controller_reducer, :invalid_reducer}},
      {%{reducer_reply: :invalid_options}, {:invalid_controller_reducer_options, [:not_keyword]}},
      {%{reducer_reply: :invalid_state},
       {:invalid_operation_value, {:loop_state, :runtime_control_contract}, :map, :atom}}
    ]

    Enum.each(reducer_errors, fn {input, expected} ->
      {:ok, loop, control, _events} = Runtime.start(:work, @work, input, [], env)

      {:run, active, attempt, _spec, _request, false, _events} =
        Runtime.prepare(loop, control, env)

      assert {:error, ^expected} =
               Runtime.apply_result(active, control, Result.new(attempt, :ok, %{}), env)
    end)

    {:ok, loop, control, _events} =
      Runtime.start(:work, @work, %{reducer_reply: :nonportable_state}, [], env)

    {:run, active, attempt, _spec, _request, false, _events} =
      Runtime.prepare(loop, control, env)

    assert {:error, {:nonportable_operational_value, _reason}} =
             Runtime.apply_result(active, control, Result.new(attempt, :ok, %{}), env)

    {:ok, keyword_loop, keyword_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{reducer_reply: :keyword, completion: :continue},
        [],
        env
      )

    {:run, keyword_active, keyword_attempt, _spec, _request, false, _events} =
      Runtime.prepare(keyword_loop, keyword_control, env)

    assert {:ok, keyword_result, ^keyword_control, _events} =
             Runtime.apply_result(
               keyword_active,
               keyword_control,
               Result.new(keyword_attempt, :ok, %{selection: :chosen},
                 metadata: %{cognitive_fallback: true}
               ),
               env
             )

    assert keyword_result.phase == :keyword_reducer
    assert keyword_result.cognitive == %{fallback?: true, effective_selection: :chosen}

    {:ok, cost_loop, cost_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{transition_opts: %{cost: :invalid}},
        [],
        env
      )

    {:run, cost_active, cost_attempt, _spec, _request, false, _events} =
      Runtime.prepare(cost_loop, cost_control, env)

    assert {:error, {:invalid_operation_cost, :invalid}} =
             Runtime.apply_result(
               cost_active,
               cost_control,
               Result.new(cost_attempt, :ok, %{}),
               env
             )

    {:ok, string_artifact_loop, string_artifact_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{transition_opts: %{artifacts: [%{"kind" => :report}]}},
        [],
        env
      )

    {:run, string_artifact_active, string_artifact_attempt, _spec, _request, false, _events} =
      Runtime.prepare(string_artifact_loop, string_artifact_control, env)

    assert {:ok, accepted_artifact, ^string_artifact_control, _events} =
             Runtime.apply_result(
               string_artifact_active,
               string_artifact_control,
               Result.new(string_artifact_attempt, :ok, %{}),
               env
             )

    assert accepted_artifact.artifacts == [%{"kind" => :report}]

    {:ok, unknown_artifact_loop, unknown_artifact_control, _events} =
      Runtime.start(
        :work,
        @work,
        %{transition_opts: %{artifacts: [:unknown_shape]}},
        [],
        env
      )

    {:run, unknown_artifact_active, unknown_artifact_attempt, _spec, _request, false, _events} =
      Runtime.prepare(unknown_artifact_loop, unknown_artifact_control, env)

    assert {:error, {:operation_artifact_kind_not_allowed, nil}} =
             Runtime.apply_result(
               unknown_artifact_active,
               unknown_artifact_control,
               Result.new(unknown_artifact_attempt, :ok, %{}),
               env
             )

    for {completion, failure_kind} <- [
          raise: :controller_callback_exception,
          throw: :controller_callback_failure
        ] do
      {:ok, completion_loop, completion_control, _events} =
        Runtime.start(:work, @work, %{completion: completion}, [], env)

      {:run, completion_active, completion_attempt, _spec, _request, false, _events} =
        Runtime.prepare(completion_loop, completion_control, env)

      {:ok, evaluating, completion_control, _events} =
        Runtime.apply_result(
          completion_active,
          completion_control,
          Result.new(completion_attempt, :ok, %{}),
          env
        )

      assert {:ok, failed, terminal_control, [%{type: :failed}]} =
               Runtime.evaluate(evaluating, completion_control, env)

      assert elem(failed.outcome.reason, 0) == :completion_callback_failed
      assert elem(elem(failed.outcome.reason, 1), 0) == failure_kind
      assert terminal_control.state == :terminal
    end

    assert {:error, {:loop_not_awaiting_evaluation, :queued}} =
             Runtime.evaluate(keyword_loop, keyword_control, env)
  end

  test "trigger and update callbacks contain invalid replies and support keyword options" do
    env = env()

    fresh_wait = fn ->
      {:ok, loop, control, _events} =
        Runtime.start(:work, @work, %{mode: :wait, items: [1]}, [], env)

      {:transition, waiting, control, _events} = Runtime.prepare(loop, control, env)
      {waiting, control}
    end

    for {payload, expected} <- [
          callback_error: :trigger_failed,
          callback_invalid: {:invalid_controller_trigger, :invalid_trigger},
          callback_invalid_options: {:invalid_controller_trigger_options, [:not_keyword]}
        ] do
      {waiting, control} = fresh_wait.()

      assert {:error, ^expected} =
               Runtime.trigger(waiting, control, {:external, payload}, [], env)
    end

    {waiting, control} = fresh_wait.()

    assert {:ok, triggered, ^control, [%{type: :triggered}]} =
             Runtime.trigger(waiting, control, {:external, :callback_keyword}, [], env)

    assert triggered.phase == :triggered_phase

    {waiting, control} = fresh_wait.()

    assert {:error, {:nonportable_operational_value, _reason}} =
             Runtime.trigger(waiting, control, %{type: :external, pid: self()}, [], env)

    assert {:error, {:loop_not_active, :paused}} =
             Runtime.trigger(waiting, %{control | state: :paused}, :external, [], env)

    assert {:error, {:loop_not_waiting_for_trigger, :queued}} =
             Runtime.trigger(%{waiting | status: :queued, wait: nil}, control, :external, [], env)

    {waiting, control} = fresh_wait.()

    trigger_command =
      Command.new(waiting.id, :trigger,
        id: "pending-trigger",
        correlation_id: "pending-trigger",
        payload: {:external, :direct_complete}
      )

    assert {:ok, pending_trigger} = Control.request(control, trigger_command)

    assert {:ok, trigger_queued, trigger_control, [%{type: :triggered}]} =
             Runtime.advance_control(waiting, pending_trigger, env)

    assert trigger_queued.status == :queued
    assert trigger_control.last_command.status == :applied

    {waiting, control} = fresh_wait.()

    rejected_trigger =
      Command.new(waiting.id, :trigger,
        id: "rejected-trigger",
        correlation_id: "rejected-trigger",
        payload: {:external, :callback_error}
      )

    assert {:ok, pending_rejected_trigger} = Control.request(control, rejected_trigger)

    assert {:ok, rejected_waiting, rejected_control, [%{type: :control_rejected}]} =
             Runtime.advance_control(waiting, pending_rejected_trigger, env)

    assert rejected_waiting.status == :waiting
    assert rejected_waiting.wait == waiting.wait
    assert rejected_control.last_command.status == :rejected

    {waiting, control} = fresh_wait.()
    stop = Command.new(waiting.id, :stop, id: "pending-stop", correlation_id: "pending-stop")
    assert {:ok, pending_stop} = Control.request(control, stop)

    assert {:ok, stopped, stopped_control, [%{type: :cancelled}]} =
             Runtime.advance_control(waiting, pending_stop, env)

    assert stopped.status == :terminal
    assert stopped_control.state == :terminal

    {:ok, active_loop, active_control, _events} = Runtime.start(:work, @work, %{}, [], env)

    {:run, active_loop, _attempt, _spec, _request, false, _events} =
      Runtime.prepare(active_loop, active_control, env)

    assert {:error, {:loop_not_quiescent_for_control, _loop_id}} =
             Runtime.advance_control(active_loop, active_control, env)

    for {reply, expected} <- [
          error: :update_failed,
          invalid: {:invalid_controller_update, :invalid_update},
          invalid_options: {:invalid_controller_update_options, [:not_keyword]}
        ] do
      {waiting, control} = fresh_wait.()

      update =
        Command.new(waiting.id, :update,
          id: "update-#{reply}",
          correlation_id: "update-#{reply}",
          payload: %{items: [2], reply: reply}
        )

      assert {:ok, rejected, rejected_control, :keep_runner, [%{type: :control_rejected}]} =
               Runtime.request_control(waiting, control, update, env)

      assert rejected.status == :paused
      assert rejected_control.last_command.rejection == expected
    end

    {waiting, control} = fresh_wait.()

    keyword_update =
      Command.new(waiting.id, :update_and_resume,
        id: "keyword-update",
        correlation_id: "keyword-update",
        payload: %{items: [2], reply: :keyword}
      )

    assert {:ok, updated, updated_control, :keep_runner, _events} =
             Runtime.request_control(waiting, control, keyword_update, env)

    assert updated.phase == :keyword_update
    assert updated.status == :queued
    assert updated_control.state == :active
  end

  test "checkpoint validation fences control, subject and code-owned contracts" do
    env = env()
    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{}, [], env)
    assert :ok = Runtime.validate_checkpoint(loop, control, env)

    assert {:error, :operation_control_loop_mismatch} =
             Runtime.validate_checkpoint(loop, %{control | loop_id: "other-loop"}, env)

    assert {:error, :nonterminal_loop_with_terminal_control} =
             Runtime.validate_checkpoint(loop, %{control | state: :terminal}, env)

    assert {:error, :operational_loop_subject_mismatch} =
             Runtime.validate_checkpoint(loop, control, %{env | subject_id: "other-subject"})

    assert {:error, :operational_checkpoint_subject_missing} =
             Runtime.validate_checkpoint(loop, control, Map.delete(env, :subject_id))

    assert {:error, {:loop_definition_identity_mismatch, :stored, :runtime_control_contract}} =
             Runtime.validate_checkpoint(%{loop | controller_id: :stored}, control, env)

    assert {:error, {:incompatible_loop_definition, 999, 1}} =
             Runtime.validate_checkpoint(%{loop | controller_version: 999}, control, env)

    assert {:error, {:loop_definition_kind_mismatch, :vigil, :work}} =
             Runtime.validate_checkpoint(%{loop | kind: :vigil}, control, env)

    {:run, active, _attempt, _spec, _request, false, _events} =
      Runtime.prepare(loop, control, env)

    incompatible_attempt = %{active.attempt | timeout: active.attempt.timeout + 1}

    assert {:error, {:incompatible_operation_attempt, :echo}} =
             Runtime.validate_checkpoint(%{active | attempt: incompatible_attempt}, control, env)

    pause = Command.new(active.id, :pause, id: "checkpoint-pause", correlation_id: "checkpoint")

    assert {:ok, pause_requested, pause_control, :keep_runner, _events} =
             Runtime.request_control(active, control, pause, env)

    assert {:error, :pause_requested_loop_without_matching_control} =
             Runtime.validate_checkpoint(pause_requested, %{pause_control | state: :active}, env)

    assert {:error, :pause_requested_control_without_matching_loop} =
             Runtime.validate_checkpoint(active, pause_control, env)

    {:ok, waiting_loop, waiting_control, _events} =
      Runtime.start(:work, @work, %{mode: :wait}, [], env)

    {:transition, waiting, waiting_control, _events} =
      Runtime.prepare(waiting_loop, waiting_control, env)

    assert :ok = Runtime.validate_checkpoint(waiting, waiting_control, env)

    retry_wait = %{waiting.wait | kind: :retry}
    reconciliation_wait = %{waiting.wait | kind: :reconciliation}
    assert :ok = Runtime.validate_checkpoint(%{waiting | wait: retry_wait}, waiting_control, env)

    assert :ok =
             Runtime.validate_checkpoint(
               %{waiting | wait: reconciliation_wait},
               waiting_control,
               env
             )

    {:ok, terminal_loop, terminal_control, _events} =
      Runtime.start(:work, @work, %{mode: :direct_complete}, [], env)

    {:transition, terminal_loop, terminal_control, _events} =
      Runtime.prepare(terminal_loop, terminal_control, env)

    refreshed_terminal =
      %{terminal_loop | metadata: Map.put(terminal_loop.metadata, :publication, %{})}

    assert {:ok, recovered, ^terminal_control, [%{type: :definition_policy_refreshed}]} =
             Runtime.recover(refreshed_terminal, terminal_control, env)

    assert recovered.outcome.last_revision == recovered.revision
  end

  test "controller budget decisions remain portable and fail closed" do
    env = env()

    decisions = [
      {:terminate, {:budget_exhausted, :attempts}, :terminate},
      {{:terminate, :custom}, :custom, :controller},
      {{:terminate, :custom, [source: :controller]}, :custom, :controller},
      {:invalid, {:budget_exhausted, :attempts}, :terminate},
      {:nonportable_reason, {:budget_exhausted, :attempts}, :terminate},
      {:nonportable_metadata, {:budget_exhausted, :attempts}, :terminate},
      {:raise, {:budget_exhausted, :attempts}, :terminate},
      {:throw, {:budget_exhausted, :attempts}, :terminate}
    ]

    Enum.each(decisions, fn {decision, expected_reason, expected_behavior} ->
      {:ok, loop, control, _events} =
        Runtime.start(
          :work,
          @work,
          %{budget_decision: decision},
          [budget: [attempts: 0]],
          env
        )

      assert {:transition, exhausted, terminal_control, [%{type: :budget_exhausted}]} =
               Runtime.prepare(loop, control, env)

      assert exhausted.outcome.reason == expected_reason
      assert exhausted.outcome.metadata.behavior == expected_behavior
      assert terminal_control.state == :terminal
    end)
  end

  defp env do
    %{
      agent: @agent,
      subject_id: "runtime-control-subject",
      epoch: "runtime-control-epoch",
      snapshot_id: "runtime-control-snapshot",
      canonical_revision: 10,
      committed: %{},
      now: 10_000
    }
  end
end
