defmodule SpectreOperationRuntimeContractTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreOperationRuntimeContractTest.Operations do
  @moduledoc false

  def execute(input, _context), do: {:ok, input}
  def reconcile(receipt, _context), do: {:ok, receipt}
end

defmodule SpectreOperationRuntimeContractTest.Work do
  @moduledoc false

  use Spectre.Work,
    id: :runtime_contract,
    version: 1,
    input: :map,
    state: :map,
    update: :map,
    update_fields: [:items]

  operation(:echo, {SpectreOperationRuntimeContractTest.Operations, :execute},
    input: :map,
    output: :map,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  @impl true
  def init(input, _context), do: {:ok, %{input: input, done?: false, value: nil}}

  @impl true
  def next(%{done?: false, input: input}, _context), do: run(:echo, input)
  def next(%{done?: true}, _context), do: complete(:done)

  @impl true
  def apply_result(state, _request, result, _context),
    do: {:ok, %{state | done?: true, value: result.value}}

  @impl true
  def complete(%{done?: true, value: value}, _context), do: complete(value)
  def complete(_state, _context), do: :continue

  @impl true
  def apply_update(state, input, update, _context) do
    updated = Map.put(input, :items, update.payload.items)
    {:ok, %{state | input: updated}, updated}
  end
end

defmodule SpectreOperationRuntimeContractTest.ReconcilableWork do
  @moduledoc false

  use Spectre.Work,
    id: :runtime_reconciliation_contract,
    version: 1,
    input: :map,
    state: :map

  operation(:write, {SpectreOperationRuntimeContractTest.Operations, :execute},
    input: :map,
    output: :map,
    side_effect: :reconcilable,
    reconcile: {SpectreOperationRuntimeContractTest.Operations, :reconcile},
    retry: [max_attempts: 3, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  @impl true
  def init(input, _context), do: {:ok, %{input: input}}

  @impl true
  def next(%{input: input}, _context), do: run(:write, input)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationRuntimeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime

  @agent SpectreOperationRuntimeContractTest.Agent
  @work SpectreOperationRuntimeContractTest.Work
  @reconcilable SpectreOperationRuntimeContractTest.ReconcilableWork

  test "the pure runtime fences a complete deterministic Work cycle" do
    env = env()

    assert {:ok, loop, control, [%{type: :started}]} =
             Runtime.start(:work, @work, %{items: [1]}, [], env)

    assert {:run, active, attempt, spec, request, false, [%{type: :attempt_started}]} =
             Runtime.prepare(loop, control, env)

    assert spec.id == :echo
    assert request.input == %{items: [1]}
    assert attempt.snapshot_id == env.snapshot_id
    assert attempt.epoch == env.epoch
    assert attempt.base_revision == env.canonical_revision

    result = Result.new(attempt, :ok, %{items: [1]})

    assert {:ok, evaluating, ^control, events} =
             Runtime.apply_result(active, control, result, env)

    assert Enum.map(events, & &1.type) == [:attempt_committed]
    assert evaluating.status == :evaluating
    assert evaluating.attempt == nil
    assert evaluating.last_result == result

    assert {:ok, terminal, terminal_control, [%{type: :completed}]} =
             Runtime.evaluate(evaluating, control, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :completed
    assert terminal.outcome.result == %{items: [1]}
    assert terminal.outcome.last_revision == terminal.revision
    assert terminal_control.state == :terminal
  end

  test "stale and duplicate Results cannot replace committed state" do
    env = env()
    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{items: []}, [], env)
    {:run, active, attempt, _spec, _request, false, _events} = Runtime.prepare(loop, control, env)

    stale = %{Result.new(attempt, :ok, %{}) | fencing_token: "stale-fence"}

    assert {:error, :operation_fencing_mismatch} =
             Runtime.apply_result(active, control, stale, env)

    result = Result.new(attempt, :ok, %{}, id: "stable-result")

    assert {:ok, committed, _control, _events} =
             Runtime.apply_result(active, control, result, env)

    assert {:duplicate, ^committed} = Runtime.apply_result(committed, control, result, env)
  end

  test "a reconciliation retry remains a reconciliation after its timer boundary" do
    env = env()

    {:ok, loop, control, _events} =
      Runtime.start(:work, @reconcilable, %{write: 1}, [], env)

    {:run, active, attempt, _spec, _request, false, _events} =
      Runtime.prepare(loop, control, env)

    ambiguous = Result.new(attempt, :ambiguous, :connection_lost)

    assert {:ok, reconciling, ^control, [%{type: :reconciliation_required}]} =
             Runtime.apply_result(active, control, ambiguous, env)

    assert {:run, reconciling, reconciliation_attempt, _spec, request, true, _events} =
             Runtime.prepare(reconciling, control, env)

    assert request.phase == :reconciliation
    assert reconciliation_attempt.metadata.reconcile?

    failed = Result.new(reconciliation_attempt, :error, :timeout)

    assert {:ok, waiting, ^control, [%{type: :retry_scheduled}]} =
             Runtime.apply_result(reconciling, control, failed, env)

    assert waiting.wait.kind == :retry

    assert {:ok, queued, ^control, [%{type: :triggered}]} =
             Runtime.trigger(
               waiting,
               control,
               {:timer, waiting.wait.id},
               [wait_id: waiting.wait.id, generation: waiting.trigger_generation],
               env
             )

    assert {:run, _active, retry_attempt, _spec, retry_request, true, _events} =
             Runtime.prepare(queued, control, env)

    assert retry_request.id == request.id
    assert retry_attempt.metadata.reconcile?
  end

  test "recovery closes a pending safe pause in the same transition" do
    env = env()
    {:ok, loop, control, _events} = Runtime.start(:work, @work, %{items: [1]}, [], env)

    {:run, active, _attempt, _spec, _request, false, _events} =
      Runtime.prepare(loop, control, env)

    command =
      Command.new(active.id, :pause,
        id: "pause-command",
        correlation_id: "pause-correlation"
      )

    assert {:ok, pause_requested, pending_control, :keep_runner, _events} =
             Runtime.request_control(active, control, command, env)

    assert pause_requested.status == :pause_requested
    assert pending_control.state == :pause_requested

    recovered_env = %{env | epoch: "epoch-after-restart", snapshot_id: "snapshot-after-restart"}

    assert {:ok, paused, paused_control, events} =
             Runtime.recover(pause_requested, pending_control, recovered_env)

    assert paused.status == :paused
    assert paused.attempt == nil
    assert paused_control.state == :paused
    assert paused_control.pending == nil
    assert paused_control.last_command.status == :applied
    assert Enum.any?(events, &(&1.type == :attempt_recovered))
    assert Enum.any?(events, &(&1.type == :paused))
  end

  defp env do
    %{
      agent: @agent,
      subject_id: "subject-runtime",
      epoch: "epoch-runtime",
      snapshot_id: "snapshot-runtime",
      canonical_revision: 7,
      committed: %{},
      now: System.system_time(:millisecond)
    }
  end
end
