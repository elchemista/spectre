defmodule SpectreOperationTerminalControlRegressionTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreOperationTerminalControlRegressionTest.Operations do
  @moduledoc false

  def execute(%{fail: reason}, _context), do: {:error, reason}
  def execute(input, _context), do: {:ok, input}
end

defmodule SpectreOperationTerminalControlRegressionTest.Cognitive do
  @moduledoc false

  def execute(_input, _context), do: {:ok, :outside}
  def fallback(_input, _context), do: :inside
end

defmodule SpectreOperationTerminalControlRegressionTest.Work do
  @moduledoc false

  use Spectre.Work,
    id: :terminal_control_regression,
    version: 1,
    input: :map,
    state: :map

  operation(:step, {SpectreOperationTerminalControlRegressionTest.Operations, :execute},
    input: :map,
    output: :map,
    retry: [max_attempts: 1]
  )

  @impl true
  def init(input, _context), do: {:ok, %{input: input, done?: false}}

  @impl true
  def next(%{done?: false, input: input}, _context), do: run(:step, input)
  def next(%{done?: true}, _context), do: complete(:done)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, %{state | done?: true}}

  @impl true
  def complete(%{done?: true, input: %{keep_open: true}}, _context), do: :continue
  def complete(%{done?: true}, _context), do: complete(:done)
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationTerminalControlRegressionTest.BudgetWork do
  @moduledoc false

  use Spectre.Work,
    id: :terminal_budget_regression,
    version: 1,
    input: :map,
    state: :map,
    budget: [attempts: 1]

  operation(:flaky, {SpectreOperationTerminalControlRegressionTest.Operations, :execute},
    input: :map,
    output: :map,
    retry: [max_attempts: 3, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:flaky]]
  )

  @impl true
  def init(input, _context), do: {:ok, %{input: input}}

  @impl true
  def next(%{input: input}, _context), do: run(:flaky, input)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationTerminalControlRegressionTest.CognitiveWork do
  @moduledoc false

  use Spectre.Work,
    id: :cognitive_retry_regression,
    version: 1,
    input: :any,
    state: :map

  operation(:classify, {SpectreOperationTerminalControlRegressionTest.Cognitive, :execute},
    kind: :cognitive,
    input: :any,
    output: :atom,
    domain: [:inside],
    fallback: {SpectreOperationTerminalControlRegressionTest.Cognitive, :fallback},
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0]
  )

  @impl true
  def init(input, _context), do: {:ok, %{input: input, done?: false, value: nil}}

  @impl true
  def next(%{done?: false, input: input}, _context), do: run(:classify, input)
  def next(%{done?: true}, _context), do: complete(:done)

  @impl true
  def apply_result(state, _request, result, _context),
    do: {:ok, %{state | done?: true, value: result.value}}

  @impl true
  def complete(%{done?: true, value: value}, _context), do: complete(value)
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationTerminalControlRegressionTest do
  use ExUnit.Case, async: true

  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.ExecutionContext
  alias Spectre.Operation.Executor
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime

  @agent SpectreOperationTerminalControlRegressionTest.Agent
  @work SpectreOperationTerminalControlRegressionTest.Work
  @budget_work SpectreOperationTerminalControlRegressionTest.BudgetWork
  @cognitive_work SpectreOperationTerminalControlRegressionTest.CognitiveWork

  test "a terminal failure with a pending safe pause rejects the command and still commits" do
    env = env()

    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{fail: :boom}, [], env)
    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    pause = Command.new(active.id, :pause, id: "race-pause", correlation_id: "race-pause")

    assert {:ok, pause_requested, pending_control, :keep_runner, _events} =
             Runtime.request_control(active, control, pause, env)

    assert pending_control.state == :pause_requested
    assert pending_control.pending.id == pause.id

    failure = Result.new(attempt, :error, :boom)

    assert {:ok, terminal, terminal_control, events} =
             Runtime.apply_result(pause_requested, pending_control, failure, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :failed
    assert terminal_control.state == :terminal
    assert terminal_control.pending == nil
    assert terminal_control.last_command.id == pause.id
    assert terminal_control.last_command.status == :rejected
    assert terminal_control.last_command.rejection == :loop_terminal

    assert Enum.map(events, & &1.type) == [:attempt_failed, :failed, :control_rejected]

    # The committed pair must satisfy both structure validation and the
    # restart checkpoint contract: this is the previously wedged state.
    assert :ok = Loop.validate(terminal)
    assert :ok = Control.validate(terminal_control)
    assert :ok = Runtime.validate_checkpoint(terminal, terminal_control, env)

    # A terminal loop stays terminal: no later command can reopen it.
    resume = Command.new(terminal.id, :resume, id: "post-terminal", correlation_id: "post")

    assert {:error, :loop_terminal} =
             Runtime.request_control(terminal, terminal_control, resume, env)
  end

  test "a fatal Runner crash with a pending safe pause rejects the command and still commits" do
    env = env()

    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{page: 1}, [], env)
    {:run, active, _attempt, spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    pause = Command.new(active.id, :pause, id: "crash-pause", correlation_id: "crash-pause")

    assert {:ok, pause_requested, pending_control, :keep_runner, _events} =
             Runtime.request_control(active, control, pause, env)

    assert {:ok, terminal, terminal_control, events} =
             Runtime.runner_down(pause_requested, pending_control, spec, :killed, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :failed
    assert terminal_control.state == :terminal
    assert terminal_control.pending == nil
    assert terminal_control.last_command.status == :rejected
    assert Enum.map(events, & &1.type) == [:attempt_crashed, :failed, :control_rejected]

    assert :ok = Control.validate(terminal_control)
    assert :ok = Runtime.validate_checkpoint(terminal, terminal_control, env)
  end

  test "the committed intermediate state between Result and pending pause survives restart" do
    env = env()

    {:ok, loop, control, _events} =
      Runtime.start(:work, @work, %{page: 1, keep_open: true}, [], env)

    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    pause = Command.new(active.id, :pause, id: "boundary-pause", correlation_id: "boundary")

    assert {:ok, pause_requested, pending_control, :keep_runner, _events} =
             Runtime.request_control(active, control, pause, env)

    result = Result.new(attempt, :ok, %{page: 1})

    assert {:ok, evaluating, ^pending_control, _events} =
             Runtime.apply_result(pause_requested, pending_control, result, env)

    assert evaluating.status == :evaluating
    assert pending_control.state == :pause_requested

    # This exact pair is committed and may be checkpointed before the pending
    # command advances; a restart must accept it and resume the sequence.
    assert :ok = Runtime.validate_checkpoint(evaluating, pending_control, env)

    assert {:ok, recovered, recovered_control, _events} =
             Runtime.recover(evaluating, pending_control, env)

    assert recovered_control.pending.id == pause.id

    assert {:ok, paused, paused_control, [%{type: :paused}]} =
             Runtime.advance_control(recovered, recovered_control, env)

    assert paused.status == :paused
    assert paused_control.state == :paused
    assert paused_control.pending == nil
    assert :ok = Runtime.validate_checkpoint(paused, paused_control, env)

    # The pure-API safe boundary (loop paused, command still pending) must be
    # restorable as well.
    assert {:ok, boundary, ^pending_control, [%{type: :safe_boundary_reached}]} =
             Runtime.evaluate(evaluating, pending_control, env)

    assert boundary.status == :paused
    assert :ok = Runtime.validate_checkpoint(boundary, pending_control, env)
  end

  test "a retry denied by budget produces a typed budget_exhausted outcome" do
    env = env()

    {:ok, loop, control, _events} = Runtime.start(:work, @budget_work, %{fail: :flaky}, [], env)
    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    failure = Result.new(attempt, :error, :flaky)

    assert {:ok, terminal, terminal_control, events} =
             Runtime.apply_result(active, control, failure, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :budget_exhausted
    assert terminal.outcome.limit == %{dimension: :attempts, value: 1}
    assert terminal.outcome.consumed == %{dimension: :attempts, value: 1}
    assert terminal.last_error == :flaky
    assert terminal_control.state == :terminal
    assert Enum.map(events, & &1.type) == [:attempt_failed, :budget_exhausted]
  end

  test "an out-of-domain cognitive result is retried and the declared fallback fires" do
    env = env()

    {:ok, loop, control, _events} = Runtime.start(:work, @cognitive_work, %{q: 1}, [], env)
    {:run, active, attempt, spec, request, false, _events} = Runtime.prepare(loop, control, env)

    context = execution_context(attempt)

    assert {:error, {:operation_value_outside_domain, {:operation_domain, :classify}, :outside}} =
             Executor.execute(spec, request, context)

    failure =
      Result.new(
        attempt,
        :error,
        {:operation_value_outside_domain, {:operation_domain, :classify}, :outside}
      )

    assert {:ok, waiting, ^control, [%{type: :retry_scheduled}]} =
             Runtime.apply_result(active, control, failure, env)

    assert waiting.status == :waiting
    assert waiting.wait.kind == :retry

    assert {:ok, queued, ^control, [%{type: :triggered}]} =
             Runtime.trigger(
               waiting,
               control,
               {:timer, waiting.wait.id},
               [wait_id: waiting.wait.id, generation: waiting.trigger_generation],
               env
             )

    {:run, retried, retry_attempt, retry_spec, retry_request, false, _events} =
      Runtime.prepare(queued, control, env)

    assert retry_attempt.retry_number == 1

    assert {:ok, execution} =
             Executor.execute(retry_spec, retry_request, execution_context(retry_attempt))

    assert execution.value == :inside
    assert execution.metadata.cognitive_fallback

    fallback_result = Result.new(retry_attempt, :ok, execution.value)

    assert {:ok, evaluating, ^control, [%{type: :attempt_committed}]} =
             Runtime.apply_result(retried, control, fallback_result, env)

    assert evaluating.status == :evaluating
  end

  defp execution_context(attempt) do
    %ExecutionContext{
      agent: @agent,
      subject: "subject-regression",
      loop_id: attempt.loop_id,
      loop_kind: attempt.loop_kind,
      controller: @cognitive_work,
      attempt: attempt,
      input: nil,
      state: %{},
      cognitive: %{},
      progress: fn _value, _metadata -> :ok end,
      opts: [],
      metadata: %{}
    }
  end

  defp env do
    %{
      agent: @agent,
      subject_id: "subject-regression",
      epoch: "epoch-regression",
      snapshot_id: "snapshot-regression",
      canonical_revision: 5,
      committed: %{},
      now: System.system_time(:millisecond)
    }
  end
end
