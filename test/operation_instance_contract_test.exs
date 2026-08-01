defmodule SpectreOperationInstanceContractTest.Operations do
  @moduledoc false

  def fetch_page(%{page: page} = input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    runner = context |> callers() |> hd()

    send(test_pid, {:page_attempt, page, context.attempt, runner, self()})

    if Map.get(input, :block?, false) do
      receive do
        {:release_page, ^page} -> :ok
      end
    end

    {:ok, %{page: page, body: "page-#{page}"}}
  end

  def flaky(input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    send(test_pid, {:flaky_attempt, context.attempt, context |> callers() |> hd()})

    if context.attempt.retry_number == 0,
      do: {:error, :timeout},
      else: {:ok, Map.put(input, :retried?, true)}
  end

  def crashable(input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    runner = context |> callers() |> hd()
    send(test_pid, {:crashable_attempt, context.attempt, runner})

    if context.attempt.retry_number == 0 do
      receive do
        :finish_crashable -> :ok
      end
    end

    {:ok, Map.put(input, :recovered?, context.attempt.retry_number > 0)}
  end

  def timeout_once(input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    send(test_pid, {:timeout_attempt, context.attempt, context |> callers() |> hd()})

    if context.attempt.retry_number == 0, do: Process.sleep(200)
    {:ok, Map.put(input, :timed_out_once?, context.attempt.retry_number > 0)}
  end

  def observe(input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    send(test_pid, {:vigil_attempt, context.attempt, context |> callers() |> hd()})
    {:ok, Map.put(input, :observed_at, context.attempt.number)}
  end

  def progress(input, context) do
    send(Keyword.fetch!(context.opts, :test_pid), {:progress_attempt, context.attempt})

    :ok =
      Spectre.Operation.ExecutionContext.progress(
        context,
        %{stage: :halfway, value: Map.get(input, :value)},
        %{source: :contract_test}
      )

    {:ok, Map.put(input, :progressed?, true)}
  end

  def remember(input, _context) do
    {:ok,
     Spectre.Operation.Execution.new(input,
       receipt: %{storage: :source},
       artifacts: [%{kind: :report, id: "memory-report"}]
     )}
  end

  def nested_start(_input, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    {:ok, instance} = Spectre.lookup_instance(context.agent, context.subject)

    result =
      Spectre.start_work(
        instance,
        SpectreOperationInstanceContractTest.WaitingWork,
        %{value: :nested}
      )

    send(test_pid, {:nested_start_result, result})
    {:ok, %{nested_start_result: result}}
  end

  defp callers(context) do
    case Process.get(:"$callers") do
      [_runner | _rest] = callers -> callers
      _missing -> [context.attempt.id]
    end
  end
end

defmodule SpectreOperationInstanceContractTest.Memory do
  @moduledoc false

  def remember_operation(%{value: %{memory_reply: :error}} = payload, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:operation_remembered, payload, opts})
    {:error, :memory_unavailable}
  end

  def remember_operation(%{value: %{memory_reply: :invalid}} = payload, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:operation_remembered, payload, opts})
    :unexpected
  end

  def remember_operation(payload, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:operation_remembered, payload, opts})
    :ok
  end
end

defmodule SpectreOperationInstanceContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  memory(SpectreOperationInstanceContractTest.Memory)

  operation(:fetch_page, {SpectreOperationInstanceContractTest.Operations, :fetch_page},
    input: :map,
    output: :map
  )

  operation(:flaky, {SpectreOperationInstanceContractTest.Operations, :flaky},
    input: :map,
    output: :map,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  operation(:crashable, {SpectreOperationInstanceContractTest.Operations, :crashable},
    input: :map,
    output: :map,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:crash]]
  )

  operation(:timeout_once, {SpectreOperationInstanceContractTest.Operations, :timeout_once},
    input: :map,
    output: :map,
    timeout: 40,
    retry: [max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:timeout]]
  )

  operation(:observe, {SpectreOperationInstanceContractTest.Operations, :observe},
    input: :map,
    output: :map
  )

  operation(:progress, {SpectreOperationInstanceContractTest.Operations, :progress},
    input: :map,
    output: :map
  )

  operation(:remember, {SpectreOperationInstanceContractTest.Operations, :remember},
    input: :map,
    output: :map,
    remember: %{include: [:value, :artifacts, :receipt]}
  )

  operation(:nested_start, {SpectreOperationInstanceContractTest.Operations, :nested_start},
    input: :map,
    output: :map
  )
end

defmodule SpectreOperationInstanceContractTest.RoutedAgent do
  @moduledoc false

  use Spectre.Agent
  route_operation_events(:all)
end

defmodule SpectreOperationInstanceContractTest.InteractionRenderer do
  @moduledoc false
  def render(prompt, input, _context), do: "#{prompt}:#{input.text}"
end

defmodule SpectreOperationInstanceContractTest.InteractionAgent do
  @moduledoc false
  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :operation_instance_interaction do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello,
        renderer: {SpectreOperationInstanceContractTest.InteractionRenderer, :render}
      )
    end
  end
end

defmodule SpectreOperationInstanceContractTest.PagedWork do
  @moduledoc false

  use Spectre.Work,
    id: :paged_work,
    version: 1,
    input: :map,
    state: :map,
    update: :map,
    update_fields: [:pages],
    artifact_policy: %{publish_results: true, publish_artifacts: true}

  uses_operation(:fetch_page)

  @impl true
  def init(input, _context) do
    {:ok,
     %{
       queue: input.pages,
       block?: Map.get(input, :block?, false),
       pages: []
     }}
  end

  @impl true
  def next(%{queue: [page | _], block?: block?}, _context),
    do: run(:fetch_page, %{page: page, block?: block?}, phase: :reading)

  def next(%{queue: []}, _context), do: complete(:pages_read)

  @impl true
  def apply_result(%{queue: [_page | rest]} = state, _request, result, _context) do
    {:ok, %{state | queue: rest, pages: state.pages ++ [result.value]}}
  end

  @impl true
  def complete(%{queue: [], pages: pages}, _context), do: complete(pages)
  def complete(_state, _context), do: :continue

  @impl true
  def apply_update(state, input, update, _context) do
    additions = update.payload.pages
    known = Enum.map(state.pages, & &1.page) ++ state.queue
    additions = Enum.reject(additions, &(&1 in known))
    updated_input = Map.put(input, :pages, Enum.uniq(input.pages ++ additions))
    {:ok, %{state | queue: state.queue ++ additions, block?: false}, updated_input}
  end
end

defmodule SpectreOperationInstanceContractTest.SingleOperationWork do
  @moduledoc false

  use Spectre.Work,
    id: :single_operation_work,
    version: 1,
    input: :map,
    state: :map

  uses_operation(:flaky)
  uses_operation(:crashable)
  uses_operation(:timeout_once)
  uses_operation(:progress)
  uses_operation(:remember)
  uses_operation(:nested_start)

  @impl true
  def init(input, _context), do: {:ok, %{input: input, done?: false, value: nil}}

  @impl true
  def next(%{done?: false, input: %{operation: operation} = input}, _context),
    do: run(operation, Map.delete(input, :operation))

  def next(%{done?: true}, _context), do: complete(:done)

  @impl true
  def apply_result(state, _request, result, _context),
    do: {:ok, %{state | done?: true, value: result.value}}

  @impl true
  def complete(%{done?: true, value: value}, _context), do: complete(value)
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.CompletingWork do
  @moduledoc false

  use Spectre.Work,
    id: :completing_work,
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

defmodule SpectreOperationInstanceContractTest.WaitingWork do
  @moduledoc false

  use Spectre.Work,
    id: :waiting_work,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external]

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: wait(:external)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.CorrelatedWaitingWork do
  @moduledoc false

  use Spectre.Work,
    id: :correlated_waiting_work,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external],
    triggers: [:external],
    security: %{trigger_correlation: :required}

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: wait(:external)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.Vigil do
  @moduledoc false

  use Spectre.Vigil,
    id: :timer_vigil,
    version: 1,
    input: :map,
    state: :map,
    triggers: [:timer]

  uses_operation(:observe)

  @impl true
  def init(input, _context), do: {:ok, %{input: input, ready?: true}}

  @impl true
  def next(%{ready?: true, input: input}, _context), do: observe(:observe, input)
  def next(%{ready?: false}, context), do: wait_for(100, context)

  @impl true
  def apply_result(state, _request, _result, _context),
    do: {:ok, %{state | ready?: false}, significance: :significant}

  @impl true
  def handle_trigger(state, {:timer, _wait_id}, _context), do: {:ok, %{state | ready?: true}}
end

defmodule SpectreOperationInstanceContractTest.StartingDirectiveController do
  @moduledoc false

  @behaviour Spectre.Operation.Controller

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Request

  @impl true
  def __spectre_loop_definition__ do
    Definition.new(
      id: :directive_starting_work,
      version: 1,
      kind: :directive,
      input: :map,
      state: :map,
      imports: [:fetch_page],
      can_start: [:work]
    )
  end

  @impl true
  def init(input, _context) do
    {:ok,
     %{
       child_id: input.child_id,
       child_controller:
         Map.get(
           input,
           :child_controller,
           SpectreOperationInstanceContractTest.WaitingWork
         ),
       done?: false
     }}
  end

  @impl true
  def next(%{done?: false}, _context), do: {:run, Request.new(:fetch_page, %{page: :seed})}
  def next(%{done?: true, child_id: child_id}, _context), do: {:complete, child_id}

  @impl true
  def apply_result(state, _request, result, _context) do
    child =
      {:work, state.child_controller, %{value: result.value},
       [intent_id: :page_reader, id: state.child_id, metadata: %{source: :directive_test}]}

    {:ok, %{state | done?: true}, start_loops: [child]}
  end

  @impl true
  def complete(%{done?: true, child_id: child_id}, _context),
    do: {:complete, %{work_id: child_id}}

  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.ReproposingDirectiveController do
  @moduledoc false

  @behaviour Spectre.Operation.Controller

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Request

  @impl true
  def __spectre_loop_definition__ do
    Definition.new(
      id: :directive_reproposing_work,
      version: 1,
      kind: :directive,
      input: :map,
      state: :map,
      imports: [:fetch_page],
      can_start: [:work]
    )
  end

  @impl true
  def init(input, _context), do: {:ok, %{child_id: input.child_id, rounds: 0}}

  @impl true
  def next(%{rounds: rounds}, _context) when rounds < 2,
    do: {:run, Request.new(:fetch_page, %{page: :seed})}

  def next(%{child_id: child_id}, _context), do: {:complete, child_id}

  @impl true
  def apply_result(state, _request, result, _context) do
    child =
      {:work, SpectreOperationInstanceContractTest.WaitingWork, %{value: result.value},
       [intent_id: :page_reader, id: state.child_id]}

    {:ok, %{state | rounds: state.rounds + 1}, start_loops: [child]}
  end

  @impl true
  def complete(%{rounds: rounds, child_id: child_id}, _context) when rounds >= 2,
    do: {:complete, %{work_id: child_id}}

  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.DirectiveController do
  @moduledoc false

  @behaviour Spectre.Operation.Controller

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Wait

  @impl true
  def __spectre_loop_definition__ do
    Definition.new(
      id: :directive_no_cascade,
      version: 1,
      kind: :directive,
      input: :map,
      state: :map,
      waits: [:external]
    )
  end

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: {:wait, Wait.new(:external)}

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreOperationInstanceContractTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(_ref, opts) do
    Agent.get(Keyword.fetch!(opts, :store), fn
      %{checkpoint: nil} -> :not_found
      %{checkpoint: checkpoint} -> {:ok, checkpoint}
    end)
  end

  @impl true
  def compare_and_swap(_ref, checkpoint, expected, revision, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :store), fn state ->
      state = Map.update!(state, :writes, &(&1 + 1))

      cond do
        state.revision != expected ->
          {{:error, {:conflict, expected, state.revision}}, state}

        state.behavior == :ambiguous_after_commit ->
          next = %{
            state
            | checkpoint: checkpoint,
              revision: revision,
              behavior: :ok
          }

          {{:error, {:ambiguous, :ack_lost}}, next}

        state.behavior == :ambiguous_without_commit ->
          {{:error, {:ambiguous, :write_unknown}}, %{state | behavior: :ok}}

        true ->
          {:ok, %{state | checkpoint: checkpoint, revision: revision}}
      end
    end)
  end
end

defmodule SpectreOperationInstanceContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Operation.Delivery.Consent
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Ref
  alias Spectre.Operation.View
  alias Spectre.Subject

  @agent SpectreOperationInstanceContractTest.Agent
  @paged_work SpectreOperationInstanceContractTest.PagedWork
  @single_work SpectreOperationInstanceContractTest.SingleOperationWork
  @completing_work SpectreOperationInstanceContractTest.CompletingWork
  @waiting_work SpectreOperationInstanceContractTest.WaitingWork
  @correlated_waiting_work SpectreOperationInstanceContractTest.CorrelatedWaitingWork
  @vigil SpectreOperationInstanceContractTest.Vigil
  @directive SpectreOperationInstanceContractTest.DirectiveController
  @starting_directive SpectreOperationInstanceContractTest.StartingDirectiveController
  @reproposing_directive SpectreOperationInstanceContractTest.ReproposingDirectiveController
  @routed_agent SpectreOperationInstanceContractTest.RoutedAgent
  @interaction_agent SpectreOperationInstanceContractTest.InteractionAgent
  @store SpectreOperationInstanceContractTest.CheckpointStore

  test "a real paginated Work gets one temporary fenced Runner per page" do
    instance = start_instance()

    assert {:ok, %Ref{} = ref, %View{status: :queued}} =
             Spectre.start_work(instance, @paged_work, %{pages: [1, 2]})

    attempts = collect_page_attempts(2)
    assert Enum.map(attempts, & &1.page) == [1, 2]

    assert Enum.uniq_by(attempts, & &1.attempt.id) == attempts
    assert Enum.uniq_by(attempts, & &1.attempt.snapshot_id) == attempts
    assert Enum.uniq_by(attempts, & &1.attempt.fencing_token) == attempts
    assert Enum.uniq_by(attempts, & &1.runner) == attempts
    assert Enum.uniq(Enum.map(attempts, & &1.attempt.epoch)) |> length() == 1

    assert_eventually(fn ->
      Enum.all?(attempts, &(not Process.alive?(&1.runner)))
    end)

    assert {:ok, view} = eventually_loop(instance, ref, &(&1.status == :terminal))
    assert view.terminal_category == :completed
    assert Enum.map(view.partial_results, & &1.page) == [2, 1]
    assert view.attempts == 2
    assert Instance.info(instance).operation_runners == %{}

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, loops} = Canonical.fetch(canonical, :work)

    assert loops[ref.id].outcome.result == [
             %{body: "page-1", page: 1},
             %{body: "page-2", page: 2}
           ]
  end

  test "retry, Runner DOWN and attempt timeout are decided by the Agent" do
    instance = start_instance()

    assert {:ok, flaky_ref, _view} =
             Spectre.start_work(instance, @single_work, %{operation: :flaky, value: 1},
               id: "flaky-loop"
             )

    assert_receive {:flaky_attempt, first_flaky, first_flaky_runner}, 1_000
    assert_receive {:flaky_attempt, second_flaky, second_flaky_runner}, 1_000
    assert first_flaky.retry_number == 0
    assert second_flaky.retry_number == 1
    assert first_flaky.id != second_flaky.id
    assert first_flaky_runner != second_flaky_runner

    assert {:ok, flaky_view} = eventually_loop(instance, flaky_ref, &(&1.status == :terminal))
    assert flaky_view.terminal_category == :completed
    assert flaky_view.retries == 1

    assert {:ok, crash_ref, _view} =
             Spectre.start_work(instance, @single_work, %{operation: :crashable, value: 2},
               id: "crash-loop"
             )

    assert_receive {:crashable_attempt, first_crash, crash_runner}, 1_000
    Process.exit(crash_runner, :kill)
    assert_receive {:crashable_attempt, second_crash, recovered_runner}, 1_000
    assert first_crash.id != second_crash.id
    assert crash_runner != recovered_runner

    assert {:ok, crash_view} = eventually_loop(instance, crash_ref, &(&1.status == :terminal))
    assert crash_view.terminal_category == :completed
    assert crash_view.retries == 1
    assert crash_view.last_crash.reason == :killed

    assert {:ok, timeout_ref, _view} =
             Spectre.start_work(instance, @single_work, %{operation: :timeout_once, value: 3},
               id: "timeout-loop"
             )

    assert_receive {:timeout_attempt, first_timeout, first_timeout_runner}, 1_000
    assert_receive {:timeout_attempt, second_timeout, second_timeout_runner}, 1_000
    assert first_timeout.retry_number == 0
    assert second_timeout.retry_number == 1
    assert first_timeout_runner != second_timeout_runner

    assert {:ok, timeout_view} =
             eventually_loop(instance, timeout_ref, &(&1.status == :terminal), 2_000)

    assert timeout_view.terminal_category == :completed
    assert timeout_view.retries == 1
  end

  test "pause-update-resume commits provenance before the next Runner" do
    instance = start_instance()

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @paged_work, %{pages: [1], block?: true},
               id: "update-loop"
             )

    assert_receive {:page_attempt, 1, first_attempt, _runner, worker}, 1_000

    assert {:ok, %View{pause_requested: true, pending_command: pending}} =
             Spectre.update_and_resume_loop(instance, ref, %{pages: [2]},
               command_id: "update-command",
               correlation_id: "turn-update",
               causation_id: "message-update",
               provenance: %{source: :chat, turn: "turn-update"}
             )

    assert pending.action == :update_and_resume
    send(worker, {:release_page, 1})

    assert_receive {:page_attempt, 2, second_attempt, _runner, _worker}, 1_000
    assert second_attempt.context_revision == 1
    assert second_attempt.control_generation > first_attempt.control_generation

    assert {:ok, view} = eventually_loop(instance, ref, &(&1.status == :terminal))
    assert view.terminal_category == :completed
    assert view.context_revision == 1
    assert view.last_update.id == "update-command"
    assert view.last_update.status == :applied

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, loops} = Canonical.fetch(canonical, :work)
    update = loops[ref.id].last_update
    assert update.correlation_id == "turn-update"
    assert update.causation_id == "message-update"
    assert update.provenance == %{source: :chat, turn: "turn-update"}
    assert loops[ref.id].effective_input.pages == [1, 2]
  end

  test "restart resumes from the checkpoint with a new Agent epoch and fencing" do
    subject = unique_subject("restart")
    instance = start_instance(subject: subject)

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @paged_work, %{pages: [7], block?: true},
               id: "restart-loop"
             )

    assert_receive {:page_attempt, 7, old_attempt, old_runner, _worker}, 1_000
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    child_id = {Instance, Instance.ref(instance).key}
    assert :ok = stop_supervised(child_id)
    refute Process.alive?(old_runner)

    restored = start_instance(subject: subject, canonical_checkpoint: checkpoint)
    assert_receive {:page_attempt, 7, new_attempt, new_runner, new_worker}, 1_000

    assert old_attempt.id != new_attempt.id
    assert old_attempt.snapshot_id != new_attempt.snapshot_id
    assert old_attempt.fencing_token != new_attempt.fencing_token
    assert old_attempt.epoch != new_attempt.epoch
    assert old_runner != new_runner

    send(new_worker, {:release_page, 7})
    assert {:ok, view} = eventually_loop(restored, ref, &(&1.status == :terminal))
    assert view.terminal_category == :completed
  end

  test "pending update recovery is atomic and never retries an unknown effect boundary" do
    subject = unique_subject("pending-control")
    instance = start_instance(subject: subject)

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @paged_work, %{pages: [1], block?: true},
               id: "pending-update-loop"
             )

    assert_receive {:page_attempt, 1, old_attempt, _runner, _worker}, 1_000

    assert {:ok, %View{pause_requested: true}} =
             Spectre.update_and_resume_loop(instance, ref, %{pages: [2]},
               command_id: "pending-update",
               correlation_id: "pending-update-correlation",
               provenance: %{source: :test}
             )

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    child_id = {Instance, Instance.ref(instance).key}
    assert :ok = stop_supervised(child_id)

    restored = start_instance(subject: subject, canonical_checkpoint: checkpoint)
    assert_receive {:page_attempt, 1, recovered_attempt, _runner, recovered_worker}, 1_000
    assert recovered_attempt.context_revision == 1
    assert recovered_attempt.id != old_attempt.id
    send(recovered_worker, {:release_page, 1})

    assert_receive {:page_attempt, 2, next_attempt, _runner, next_worker}, 1_000
    assert next_attempt.context_revision == 1
    send(next_worker, {:release_page, 2})

    assert {:ok, view} = eventually_loop(restored, ref, &(&1.status == :terminal))
    assert view.context_revision == 1
    assert view.last_update.id == "pending-update"
    assert view.terminal_category == :completed
  end

  test "Vigil waits without a Runner, wakes on durable timers and records significance" do
    instance = start_instance()

    assert {:ok, ref, _view} = Spectre.register_vigil(instance, @vigil, %{city: "Rome"})
    assert_receive {:vigil_attempt, first, first_runner}, 1_000
    assert_receive {:vigil_attempt, second, second_runner}, 1_000
    assert first.id != second.id
    assert first_runner != second_runner

    assert {:ok, waiting} = eventually_loop(instance, ref, &(&1.status == :waiting))
    assert waiting.observations >= 2
    assert Instance.info(instance).operation_runners == %{}

    events = Spectre.operation_events(instance)
    assert Enum.any?(events, &(&1.loop_id == ref.id and &1.type == :observation_significant))

    assert {:ok, stopped} = Spectre.stop_loop(instance, ref, :test_complete)
    assert stopped.status == :terminal
    assert stopped.terminal_category == :cancelled
  end

  test "stopping a Directive does not cascade to an independent Work" do
    instance = start_instance()

    assert {:ok, work_ref, _view} =
             Spectre.start_work(instance, @paged_work, %{pages: [1], block?: true})

    assert_receive {:page_attempt, 1, _attempt, runner, worker}, 1_000

    assert {:ok, directive_ref, _view} =
             Spectre.start_controller(instance, @directive, %{linked_work: work_ref.id})

    assert {:ok, _waiting} = eventually_loop(instance, directive_ref, &(&1.status == :waiting))
    assert {:ok, directive} = Spectre.stop_loop(instance, directive_ref, :directive_only)
    assert directive.terminal_category == :cancelled
    assert Process.alive?(runner)

    assert {:ok, work_view} = Spectre.loop(instance, work_ref)
    assert work_view.status == :active

    send(worker, {:release_page, 1})
    assert {:ok, completed} = eventually_loop(instance, work_ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed
  end

  test "a Directive commits declared Work starts atomically with its Result" do
    instance = start_instance()
    parent_id = "directive-parent"
    child_id = "directive-child"

    assert {:ok, parent_ref, _view} =
             Spectre.start_controller(
               instance,
               @starting_directive,
               %{child_id: child_id},
               id: parent_id,
               correlation_id: "directive-parent-correlation",
               origin: :chat,
               authorized_origins: [:admin]
             )

    assert_receive {:page_attempt, :seed, _attempt, _runner, _worker}, 1_000

    assert {:ok, parent} = eventually_loop(instance, parent_ref, &(&1.status == :terminal))
    assert parent.terminal_category == :completed

    assert {:ok, child} = eventually_loop(instance, child_id, &(&1.status == :waiting))
    assert child.kind == :work
    assert child.wait_ref.kind == :external

    assert {:error, :operation_loop_not_visible} =
             Spectre.loop(instance, child_id, origin: :other)

    assert {:ok, ^child} = Spectre.loop(instance, child_id, origin: :chat)
    assert {:ok, ^child} = Spectre.loop(instance, child_id, origin: :admin)

    events = Spectre.operation_events(instance)

    parent_event =
      Enum.find(events, &(&1.loop_id == parent_id and &1.type == :loops_started))

    child_event =
      Enum.find(events, &(&1.loop_id == child_id and &1.type == :started))

    assert parent_event
    assert child_event
    assert parent_event.revision == child_event.revision

    assert parent_event.payload == %{
             loops: [
               %{intent_id: :page_reader, id: child_id, kind: :work, already_started: false}
             ]
           }

    assert child_event.causation_id == parent_event.causation_id

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, directives} = Canonical.fetch(canonical, :directive)
    assert {:ok, works} = Canonical.fetch(canonical, :work)
    assert directives[parent_id].state.done?
    assert works[child_id].metadata.parent_loop_id == parent_id
    assert works[child_id].metadata.loop_start_intent_id == :page_reader
  end

  test "a Runner and its isolated executor cannot call start_work directly" do
    instance = start_instance()

    assert {:ok, ref, _view} =
             Spectre.start_work(
               instance,
               @single_work,
               %{operation: :nested_start},
               id: "nested-start-parent"
             )

    assert_receive {:nested_start_result, {:error, :work_cannot_start_work}}, 1_000
    assert {:ok, completed} = eventually_loop(instance, ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed

    refute Enum.any?(
             elem(Spectre.loops(instance), 1),
             &(&1.id != ref.id and &1.definition == :waiting_work)
           )
  end

  test "a rejected Directive start intent cannot partially create its Work" do
    instance = start_instance()
    parent_id = "invalid-directive-parent"
    child_id = "invalid-directive-child"

    assert {:ok, parent_ref, _view} =
             Spectre.start_controller(
               instance,
               @starting_directive,
               %{child_id: child_id, child_controller: @directive},
               id: parent_id
             )

    assert_receive {:page_attempt, :seed, _attempt, _runner, _worker}, 1_000
    assert {:ok, parent} = eventually_loop(instance, parent_ref, &(&1.status == :terminal))
    assert parent.terminal_category == :failed
    assert {:error, :operation_loop_not_found} = Spectre.loop(instance, child_id)

    refute Enum.any?(
             Spectre.operation_events(instance),
             &(&1.loop_id == child_id and &1.type == :started)
           )
  end

  test "re-proposing an identical start intent is a committed no-op" do
    instance = start_instance()
    parent_id = "reproposing-directive-parent"
    child_id = "reproposed-directive-child"

    assert {:ok, parent_ref, _view} =
             Spectre.start_controller(
               instance,
               @reproposing_directive,
               %{child_id: child_id},
               id: parent_id
             )

    assert_receive {:page_attempt, :seed, _first_attempt, _runner, _worker}, 1_000
    assert_receive {:page_attempt, :seed, _second_attempt, _second_runner, _second_worker}, 1_000

    assert {:ok, parent} = eventually_loop(instance, parent_ref, &(&1.status == :terminal))
    assert parent.terminal_category == :completed

    assert {:ok, child} = eventually_loop(instance, child_id, &(&1.status == :waiting))
    assert child.kind == :work

    events = Spectre.operation_events(instance)

    started_payloads =
      events
      |> Enum.filter(&(&1.loop_id == parent_id and &1.type == :loops_started))
      |> Enum.map(&hd(&1.payload.loops))
      |> Enum.sort_by(& &1.already_started)

    assert [
             %{intent_id: :page_reader, id: ^child_id, already_started: false},
             %{intent_id: :page_reader, id: ^child_id, already_started: true}
           ] = started_payloads

    assert Enum.count(events, &(&1.loop_id == child_id and &1.type == :started)) == 1
  end

  test "a durable trigger command without correlation emits deprecation telemetry" do
    parent = self()

    telemetry_handler = fn event, measurements, metadata ->
      send(parent, {:operation_telemetry, event, measurements, metadata})
    end

    instance =
      start_instance(opts: [test_pid: self(), telemetry_handler: telemetry_handler])

    assert {:ok, ref, _view} = Spectre.start_work(instance, @waiting_work, %{value: :legacy})
    assert {:ok, _waiting} = eventually_loop(instance, ref, &(&1.status == :waiting))

    assert {:ok, _view} =
             GenServer.call(instance, {:operation_control, ref.id, :trigger, :external, []})

    assert_receive {:operation_telemetry, [:spectre, :instance, :uncorrelated_operation_trigger],
                    %{count: 1}, _metadata},
                   1_000

    assert Enum.any?(
             Spectre.operation_events(instance, types: [:triggered]),
             &(&1.loop_id == ref.id and &1.payload.correlation == :legacy)
           )
  end

  test "ambiguous checkpoint writes remain fenced until explicit reconciliation" do
    {:ok, store} =
      start_supervised(
        {Agent,
         fn ->
           %{
             checkpoint: nil,
             revision: 0,
             behavior: :ambiguous_after_commit,
             writes: 0
           }
         end},
        id: {:checkpoint_store, System.unique_integer([:positive])}
      )

    instance =
      start_instance(
        checkpoint_store: {@store, [store: store]},
        checkpoint_mode: :async
      )

    assert {:ok, _ref, _view} = Spectre.start_work(instance, @waiting_work, %{value: 1})

    assert_eventually(fn ->
      not is_nil(Spectre.checkpoint_status(instance).reconciliation_required)
    end)

    writes = Agent.get(store, & &1.writes)
    Process.sleep(50)
    assert Agent.get(store, & &1.writes) == writes

    assert {:error, {:checkpoint_reconciliation_required, _, :ambiguous}} =
             Spectre.flush_checkpoint(instance)

    assert {:ok, committed_revision} = Spectre.reconcile_checkpoint(instance)
    assert committed_revision > 0
    assert {:ok, persisted_revision} = Spectre.flush_checkpoint(instance, timeout: 2_000)
    assert persisted_revision == Spectre.checkpoint_status(instance).canonical_revision
    assert Spectre.checkpoint_status(instance).reconciliation_required == nil
  end

  test "delivery consent, dedupe, receipt transitions and visibility remain separate" do
    instance = start_instance()
    destination = %{channel: :email, address: "subject@example.test"}

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @paged_work, %{pages: []},
               id: "delivery-loop",
               origin: :chat,
               destinations: [destination]
             )

    assert {:ok, _view} = eventually_loop(instance, ref, &(&1.status == :terminal))

    event =
      instance
      |> Spectre.operation_events(origin: :chat)
      |> Enum.find(&(&1.loop_id == ref.id and &1.type == :completed))

    assert event

    subject_id = Instance.ref(instance).subject.id

    consent =
      Consent.new(
        id: "delivery-consent",
        subject_id: subject_id,
        origin: :chat,
        destination: destination,
        channels: [:email]
      )

    assert {:ok, ^consent} = Spectre.put_delivery_consent(instance, consent)

    policy = [event_types: [:completed], channels: [:email], max_deliveries: 2]

    assert {:ok, authorized} =
             Spectre.authorize_delivery(instance, event.id, destination, policy, origin: :chat)

    assert authorized.status == :authorized

    assert {:ok, delivered} =
             Spectre.record_delivery(
               instance,
               authorized.id,
               :delivered,
               %{transport_id: "transport-1"},
               origin: :chat
             )

    assert delivered.status == :delivered

    assert {:ok, ^delivered} =
             Spectre.record_delivery(
               instance,
               delivered.id,
               :delivered,
               %{transport_id: "transport-1"},
               origin: :chat
             )

    assert {:ok, ^delivered} =
             Spectre.authorize_delivery(instance, event.id, destination, policy, origin: :chat)

    denied_destination = %{channel: :email, address: "other@example.test"}

    assert {:error, {:destination_not_authorized, denied}} =
             Spectre.authorize_delivery(instance, event.id, denied_destination, policy,
               origin: :chat
             )

    assert denied.status == :denied

    assert {:error, {:invalid_delivery_receipt_transition, :denied, :delivered}} =
             Spectre.record_delivery(instance, denied.id, :delivered, %{transport_id: "invalid"},
               origin: :chat
             )

    assert Spectre.delivery_receipts(instance, origin: :other) == []

    assert MapSet.new(Enum.map(Spectre.delivery_receipts(instance, origin: :chat), & &1.id)) ==
             MapSet.new([denied.id, delivered.id])
  end

  test "loop discovery, selectors, authorization and public controls are deterministic" do
    instance = start_instance()

    first_opts = [
      id: "discover-first",
      correlation_id: "discover-first-correlation",
      origin: :chat,
      authorized_origins: [:admin],
      turn_id: "turn-first"
    ]

    assert {:ok, first_ref, _view} =
             Spectre.start_work(instance, @waiting_work, %{value: 1}, first_opts)

    assert {:ok, ^first_ref, _view} =
             Spectre.start_work(instance, @waiting_work, %{value: 1}, first_opts)

    assert {:error, {:duplicate_operational_loop, "discover-first"}} =
             Spectre.start_work(
               instance,
               @waiting_work,
               %{value: 2},
               Keyword.put(first_opts, :correlation_id, "different-correlation")
             )

    assert {:ok, second_ref, _view} =
             Spectre.start_work(instance, @waiting_work, %{value: 2},
               id: "discover-second",
               correlation_id: "discover-second-correlation",
               origin: :api,
               visibility: :subject
             )

    assert {:ok, first_waiting} = eventually_loop(instance, first_ref, &(&1.status == :waiting))

    assert {:ok, _second_waiting} =
             eventually_loop(instance, second_ref, &(&1.status == :waiting))

    assert {:error, :operation_loop_not_found} = Spectre.loop(instance, "missing-loop")

    assert {:error, :operation_loop_not_visible} =
             Spectre.loop(instance, first_ref, subject_id: "other-subject")

    assert {:error, :operation_loop_not_visible} =
             Spectre.loop(instance, first_ref, origin: :other)

    assert {:ok, _view} = Spectre.loop(instance, first_ref, origin: :admin)
    assert {:ok, _view} = Spectre.loop(instance, second_ref, origin: :other)

    assert {:ok, all} = Spectre.loops(instance)
    assert MapSet.new(Enum.map(all, & &1.id)) == MapSet.new([first_ref.id, second_ref.id])

    assert {:ok, [%View{id: "discover-first"}]} =
             Spectre.loops(instance,
               kind: :work,
               controller: @waiting_work,
               status: [:waiting]
             )
             |> then(fn
               {:ok, views} -> {:ok, Enum.filter(views, &(&1.id == first_ref.id))}
             end)

    assert {:error, {:ambiguous_operation_loops, candidates}} =
             Spectre.resolve_loop(instance)

    assert length(candidates) == 2
    assert {:ok, %View{id: "discover-first"}} = Spectre.resolve_loop(instance, first_ref)
    assert {:ok, %View{id: "discover-first"}} = Spectre.resolve_loop(instance, first_ref.id)

    assert {:ok, %View{id: "discover-first"}} =
             Spectre.resolve_loop(instance,
               id: first_ref.id,
               kind: :work,
               definition: :waiting_work,
               status: :waiting,
               origin: :chat,
               turn_id: "turn-first",
               correlation_id: "discover-first-correlation",
               active: true
             )

    assert {:ok, %View{id: "discover-second"}} =
             Spectre.resolve_loop(instance, %{
               "controller" => @waiting_work,
               "id" => second_ref.id,
               "phase" => nil,
               "active" => true
             })

    assert {:ok, %View{id: "discover-first"}} =
             Spectre.resolve_loop(instance, %{
               "id" => first_ref.id,
               "kind" => :work,
               "definition" => :waiting_work,
               "status" => :waiting,
               "origin" => :chat,
               "turn_id" => "turn-first",
               "correlation_id" => "discover-first-correlation"
             })

    assert {:error, :operation_loop_not_found} =
             Spectre.resolve_loop(instance, %{unknown: :selector})

    assert {:error, :operation_loop_not_found} = Spectre.resolve_loop(instance, 123)

    assert {:error, :operation_loop_not_visible} =
             Spectre.pause_loop(instance, first_ref, origin: :other)

    assert {:error, :immediate_loop_interruption_not_authorized} =
             Spectre.pause_loop(instance, first_ref, mode: :immediate)

    assert {:error, :immediate_loop_interruption_forbidden_by_definition} =
             Spectre.pause_loop(instance, first_ref,
               mode: :immediate,
               authorize_immediate?: true
             )

    assert {:ok, %View{status: :paused} = paused} =
             Spectre.pause_loop(instance, first_ref,
               command_id: "discovery-pause",
               correlation_id: "discovery-pause"
             )

    assert {:ok, %View{status: :paused}} =
             Spectre.pause_loop(instance, first_ref,
               command_id: "discovery-pause",
               correlation_id: "duplicate-pause"
             )

    assert {:ok, %View{status: :paused, last_update: %{status: :rejected}}} =
             Spectre.update_loop(instance, first_ref, %{value: 3},
               command_id: "unsupported-update",
               correlation_id: "unsupported-update"
             )

    assert {:ok, %View{status: :waiting}} =
             Spectre.resume_loop(instance, first_ref,
               command_id: "discovery-resume",
               correlation_id: "discovery-resume"
             )

    assert {:ok, %View{status: :waiting, revision: rejected_resume_revision}} =
             Spectre.resume_loop(instance, first_ref,
               command_id: "invalid-resume",
               correlation_id: "invalid-resume"
             )

    assert rejected_resume_revision > paused.revision

    expires_at = System.system_time(:millisecond) + 60_000

    assert {:ok, renewed} =
             Spectre.renew_loop(instance, first_ref, expires_at,
               command_id: "valid-renew",
               correlation_id: "valid-renew"
             )

    assert renewed.revision > rejected_resume_revision

    assert {:ok, invalid_renewal} =
             Spectre.renew_loop(instance, first_ref, 0,
               command_id: "invalid-renew",
               correlation_id: "invalid-renew"
             )

    assert invalid_renewal.revision > renewed.revision

    assert {:error, {:stale_loop_control_revision, 0, _current}} =
             Spectre.pause_loop(instance, first_ref,
               command_id: "stale-control",
               correlation_id: "stale-control",
               revision: 0
             )

    assert {:error, {:nonportable_loop_control, _reason}} =
             Spectre.pause_loop(instance, first_ref,
               command_id: "nonportable-control",
               correlation_id: "nonportable-control",
               metadata: %{pid: self()}
             )

    assert {:error, {:stale_loop_trigger_generation, 99, _current}} =
             Spectre.trigger_loop(instance, first_ref, :external, generation: 99)

    assert {:ok, _view} =
             Spectre.trigger_loop(instance, first_ref, :external,
               generation: first_waiting.trigger_generation
             )

    assert {:ok, stopped} = Spectre.stop_loop(instance, first_ref, :discovery_complete)
    assert stopped.terminal_category == :cancelled

    assert {:error, :loop_terminal} = Spectre.pause_loop(instance, first_ref)

    assert {:ok, %View{id: "discover-first"}} =
             Spectre.resolve_loop(instance, %{id: first_ref.id, active: false})

    assert_raise ArgumentError, ~r/invalid operational loop reference/, fn ->
      Spectre.loop(instance, {:invalid, :reference})
    end
  end

  test "Instance warns on legacy triggers and enforces opted-in wait correlation" do
    parent = self()

    telemetry_handler = fn event, measurements, metadata ->
      send(parent, {:operation_telemetry, event, measurements, metadata})
    end

    instance =
      start_instance(opts: [test_pid: self(), telemetry_handler: telemetry_handler])

    assert {:ok, legacy_ref, _view} =
             Spectre.start_work(instance, @waiting_work, %{value: :legacy})

    assert {:ok, legacy_wait} =
             eventually_loop(instance, legacy_ref, &(&1.status == :waiting))

    assert legacy_wait.wait_ref.id
    assert {:ok, _view} = Spectre.trigger_loop(instance, legacy_ref, :external)

    assert_receive {:operation_telemetry, [:spectre, :instance, :uncorrelated_operation_trigger],
                    %{count: 1}, _metadata},
                   1_000

    assert Enum.any?(
             Spectre.operation_events(instance, types: [:triggered]),
             &(&1.loop_id == legacy_ref.id and &1.payload.correlation == :legacy)
           )

    assert {:ok, correlated_ref, _view} =
             Spectre.start_work(instance, @correlated_waiting_work, %{value: :correlated})

    assert {:ok, correlated_wait} =
             eventually_loop(instance, correlated_ref, &(&1.status == :waiting))

    assert {:error, {:operation_trigger_correlation_required, [:wait_id, :generation]}} =
             Spectre.trigger_loop(instance, correlated_ref, :external)

    assert {:ok, _view} =
             Spectre.trigger_loop(instance, correlated_ref, :external,
               wait_id: correlated_wait.wait_ref.id,
               generation: correlated_wait.wait_ref.generation
             )

    refute_receive {:operation_telemetry, [:spectre, :instance, :uncorrelated_operation_trigger],
                    _, _},
                   50

    assert Enum.any?(
             Spectre.operation_events(instance, types: [:triggered]),
             &(&1.loop_id == correlated_ref.id and &1.payload.correlation == :exact)
           )
  end

  test "Instance commits Runner progress and post-commit memory events" do
    instance = start_instance()

    assert {:ok, progress_ref, _view} =
             Spectre.start_work(instance, @single_work, %{operation: :progress, value: 7},
               id: "progress-loop"
             )

    assert_receive {:progress_attempt, progress_attempt}, 1_000

    assert {:ok, progress_view} =
             eventually_loop(instance, progress_ref, &(&1.status == :terminal))

    assert progress_view.progress == %{stage: :halfway, value: 7}
    assert progress_view.terminal_category == :completed

    stale_result = Spectre.Operation.Result.new(progress_attempt, :ok, %{stale: true})
    send(instance, {:spectre, :operation_result, stale_result})

    stale_progress = %Spectre.Operation.Progress{
      id: Spectre.Identity.uuid7(),
      attempt_id: progress_attempt.id,
      loop_id: progress_attempt.loop_id,
      epoch: progress_attempt.epoch,
      fencing_token: progress_attempt.fencing_token,
      context_revision: progress_attempt.context_revision,
      control_generation: progress_attempt.control_generation,
      trigger_generation: progress_attempt.trigger_generation,
      sequence: 99,
      value: :stale,
      at: System.system_time(:millisecond),
      metadata: %{}
    }

    send(instance, {:spectre, :operation_progress, stale_progress})
    send(instance, {:spectre, :operation_runner_terminating, progress_attempt.id, :late})

    send(
      instance,
      {:spectre, :operation_attempt_timeout, progress_ref.id, progress_attempt.id,
       progress_attempt.fencing_token}
    )

    send(instance, {:spectre, :operation_timer, progress_ref.id, "stale-wait", 99})
    send(instance, {:spectre, :unknown_message})

    assert {:ok, remember_ref, _view} =
             Spectre.start_work(instance, @single_work, %{operation: :remember, value: 8},
               id: "remember-loop"
             )

    assert_receive {:operation_remembered, payload, memory_opts}, 1_000
    assert payload.loop_id == remember_ref.id
    assert payload.value == %{value: 8}
    assert payload.receipt == %{storage: :source}
    assert payload.artifacts == [%{kind: :report, id: "memory-report"}]
    assert memory_opts[:operation_loop_id] == remember_ref.id

    assert {:ok, _view} = eventually_loop(instance, remember_ref, &(&1.status == :terminal))

    assert_eventually(fn ->
      instance
      |> Spectre.operation_events(types: [:memory_committed])
      |> Enum.any?(&(&1.loop_id == remember_ref.id))
    end)

    assert {:ok, failed_memory_ref, _view} =
             Spectre.start_work(
               instance,
               @single_work,
               %{operation: :remember, memory_reply: :error},
               id: "failed-memory-loop"
             )

    assert_receive {:operation_remembered, %{loop_id: failed_loop_id}, _memory_opts}, 1_000
    assert failed_loop_id == failed_memory_ref.id

    assert {:ok, _view} =
             eventually_loop(instance, failed_memory_ref, &(&1.status == :terminal))

    assert_eventually(fn ->
      instance
      |> Spectre.operation_events(types: [:memory_commit_failed])
      |> Enum.any?(&(&1.loop_id == failed_memory_ref.id and &1.payload.status == :failed))
    end)

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, loops} = Canonical.fetch(canonical, :work)
    result_id = loops[failed_memory_ref.id].last_result.id

    send(
      instance,
      {:spectre, :operation_memory_result, failed_memory_ref.id, result_id, :unexpected}
    )

    assert_eventually(fn ->
      instance
      |> Spectre.operation_events(types: [:memory_commit_failed])
      |> Enum.count(&(&1.loop_id == failed_memory_ref.id))
      |> Kernel.>=(2)
    end)

    revision = Instance.info(instance).canonical_revision
    send(instance, {:spectre, :operation_memory_result, "missing-loop", "missing-result", :ok})
    Process.sleep(10)
    assert Instance.info(instance).canonical_revision == revision
  end

  test "committed operation events can be routed back through the Agent input scheduler" do
    instance = start_instance(agent: @routed_agent)

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @completing_work, %{value: :routed}, id: "routed-loop")

    assert {:ok, completed} = eventually_loop(instance, ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed

    assert_eventually(fn ->
      runs = Instance.info(instance).runs |> Map.values()
      runs != [] and Enum.all?(runs, &(&1.status in [:complete, :failed]))
    end)

    routed = Instance.info(instance).runs |> Map.values()
    assert Enum.all?(routed, &(&1.status in [:complete, :failed]))

    assert Spectre.operation_events(instance, limit: 0) == []

    completed_events =
      Spectre.operation_events(instance, types: [:completed], limit: :invalid)

    assert Enum.any?(completed_events, &(&1.loop_id == ref.id))
    assert Spectre.operation_events(instance, origin: :not_authorized) == []
  end

  test "delivery APIs reject malformed state and cover revocation, digest, deferral and failure" do
    instance = start_instance()
    destination = %{channel: :email, address: "delivery-matrix@example.test"}

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @completing_work, %{value: :delivery},
               id: "delivery-matrix-loop",
               origin: :chat,
               destinations: [destination]
             )

    assert {:ok, _view} = eventually_loop(instance, ref, &(&1.status == :terminal))

    event =
      instance
      |> Spectre.operation_events(types: [:completed])
      |> Enum.find(&(&1.loop_id == ref.id))

    assert event
    subject_id = Instance.ref(instance).subject.id

    assert {:error, {:invalid_delivery_consent, :invalid}} =
             Spectre.put_delivery_consent(instance, :invalid)

    assert {:error, {:invalid_delivery_consent, _message}} =
             Spectre.put_delivery_consent(instance, %{id: "incomplete"})

    wrong_subject =
      Consent.new(
        id: "wrong-subject",
        subject_id: "another-subject",
        destination: destination
      )

    assert {:error, :delivery_consent_subject_mismatch} =
             Spectre.put_delivery_consent(instance, wrong_subject)

    revoked_before_grant =
      Consent.new(
        id: "revoked-before-grant",
        subject_id: subject_id,
        destination: destination,
        granted_at: 1,
        revoked_at: 1
      )

    assert {:error, :cannot_grant_revoked_delivery_consent} =
             Spectre.put_delivery_consent(instance, revoked_before_grant)

    consent_attrs = [
      id: "delivery-matrix-consent",
      subject_id: subject_id,
      origin: :chat,
      destination: destination,
      channels: [:email]
    ]

    assert {:ok, consent} = Spectre.put_delivery_consent(instance, consent_attrs)
    assert {:ok, ^consent} = Spectre.put_delivery_consent(instance, consent)

    conflicting = %{consent | channels: []}

    assert {:error, {:delivery_consent_id_conflict, "delivery-matrix-consent"}} =
             Spectre.put_delivery_consent(instance, conflicting)

    assert {:error, :invalid_delivery_consent_id} =
             Spectre.revoke_delivery_consent(instance, :invalid)

    assert {:error, :delivery_consent_not_found} =
             Spectre.revoke_delivery_consent(instance, "missing-consent")

    assert {:ok, revoked} =
             Spectre.revoke_delivery_consent(instance, consent.id,
               correlation_id: "consent-revoked"
             )

    assert is_integer(revoked.revoked_at)
    assert {:ok, ^revoked} = Spectre.revoke_delivery_consent(instance, consent.id)

    assert {:error, :operation_event_not_found} =
             Spectre.authorize_delivery(instance, "missing-event", destination, nil)

    assert {:error, {:invalid_delivery_policy, :invalid}} =
             Spectre.authorize_delivery(instance, event.id, destination, :invalid, origin: :chat)

    assert {:error, {:invalid_delivery_policy, _message}} =
             Spectre.authorize_delivery(
               instance,
               event.id,
               destination,
               [max_deliveries: 0],
               origin: :chat
             )

    assert {:error, {:consent_missing_expired_or_revoked, denied}} =
             Spectre.authorize_delivery(
               instance,
               event.id,
               destination,
               [event_types: [:completed], channels: [:email]],
               origin: :chat,
               dedupe_key: "revoked-consent"
             )

    assert denied.status == :denied

    assert {:ok, digest} =
             Spectre.authorize_delivery(
               instance,
               event.id,
               destination,
               [consent_required: false, mode: :digest],
               origin: :chat,
               dedupe_key: "digest"
             )

    assert digest.status == :digest

    assert {:ok, deferred} =
             Spectre.authorize_delivery(
               instance,
               event.id,
               destination,
               [consent_required: false, quiet_hours: {0, 60}],
               origin: :chat,
               now: 0,
               dedupe_key: "deferred"
             )

    assert deferred.status == :deferred
    assert deferred.not_before == 60 * 60_000

    assert {:ok, authorized} =
             Spectre.authorize_delivery(
               instance,
               event.id,
               destination,
               [consent_required: false],
               origin: :chat,
               dedupe_key: "failed-transport"
             )

    assert {:ok, failed} =
             Spectre.record_delivery(
               instance,
               authorized.id,
               :failed,
               :transport_failed,
               origin: :chat
             )

    assert failed.status == :failed

    assert {:error, :invalid_delivery_receipt_id} =
             Spectre.record_delivery(instance, :invalid, :failed, :failure)

    assert {:error, :delivery_receipt_not_found} =
             Spectre.record_delivery(instance, "missing-receipt", :failed, :failure)

    assert {:error, {:invalid_delivery_outcome, :unknown}} =
             Spectre.record_delivery(instance, authorized.id, :unknown, :failure, origin: :chat)

    assert Enum.any?(Spectre.delivery_receipts(instance, limit: :invalid), &(&1.id == failed.id))
  end

  test "Instance default APIs preserve their public contracts" do
    conversational = start_instance(agent: @interaction_agent)

    assert {:ok, %Spectre.Result{reply_text: "hello:hello"}} =
             Instance.ask(conversational, "hello")

    assert {:ok, %Spectre.Turn{ref: turn_ref}} = Instance.turn(conversational, "hello")
    assert @interaction_agent == GenServer.call(conversational, :agent)

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(conversational, turn_ref.run_id))
    end)

    assert {:error, {:instance_run_terminal, _, :complete}} =
             Instance.resume(conversational, turn_ref, :continue)

    instance = start_instance()

    assert {:ok, work_ref, _view} =
             Instance.start_work(instance, @waiting_work, %{value: :defaults})

    assert {:ok, _waiting} = eventually_loop(instance, work_ref, &(&1.status == :waiting))

    assert {:ok, vigil_ref, _view} = Instance.register_vigil(instance, @vigil, %{city: "Rome"})
    assert_receive {:vigil_attempt, _attempt, _runner}, 1_000

    assert {:ok, directive_ref, _view} =
             Instance.start_controller(instance, @directive, %{source: :defaults})

    assert {:ok, _waiting} =
             eventually_loop(instance, directive_ref, &(&1.status == :waiting))

    assert {:ok, %View{id: id}} = Instance.loop(instance, work_ref)
    assert id == work_ref.id
    assert {:ok, views} = Instance.loops(instance)
    assert Enum.any?(views, &(&1.id == work_ref.id))
    assert {:error, {:ambiguous_operation_loops, _candidates}} = Instance.resolve_loop(instance)

    assert {:ok, %View{status: :paused}} = Instance.pause_loop(instance, work_ref)
    assert {:ok, %View{}} = Instance.update_loop(instance, work_ref, %{value: :updated})
    assert {:ok, %View{}} = Instance.resume_loop(instance, work_ref)

    assert {:ok, %View{}} =
             Instance.update_and_resume_loop(instance, work_ref, %{value: :again})

    assert {:ok, %View{}} =
             Instance.renew_loop(
               instance,
               work_ref,
               System.system_time(:millisecond) + 60_000
             )

    assert {:error, _reason} = Instance.trigger_loop(instance, work_ref, :external)
    assert {:ok, %View{terminal_category: :cancelled}} = Instance.stop_loop(instance, work_ref)
    assert {:ok, %View{terminal_category: :cancelled}} = Instance.stop_loop(instance, vigil_ref)

    assert {:ok, %View{terminal_category: :cancelled}} =
             Instance.stop_loop(instance, directive_ref)

    assert {:error, :checkpoint_store_not_configured} = Instance.flush_checkpoint(instance)
    assert {:error, :checkpoint_store_not_configured} = Instance.reconcile_checkpoint(instance)
    assert is_list(Instance.operation_events(instance))

    assert {:error, {:invalid_delivery_consent, :invalid}} =
             Instance.put_delivery_consent(instance, :invalid)

    assert {:error, :invalid_delivery_consent_id} =
             Instance.revoke_delivery_consent(instance, :invalid)

    assert {:error, :operation_event_not_found} =
             Instance.authorize_delivery(instance, "missing", %{}, nil)

    assert {:error, :invalid_delivery_receipt_id} =
             Instance.record_delivery(instance, :invalid, :failed, :failure)

    assert is_list(Instance.delivery_receipts(instance))
  end

  test "manual and ambiguous-uncommitted checkpoint stores expose explicit outcomes" do
    instance = start_instance()
    assert {:error, :checkpoint_store_not_configured} = Spectre.flush_checkpoint(instance)
    assert {:error, :checkpoint_store_not_configured} = Spectre.reconcile_checkpoint(instance)

    {:ok, manual_store} =
      start_supervised(
        {Agent, fn -> %{checkpoint: nil, revision: 0, behavior: :ok, writes: 0} end},
        id: {:manual_checkpoint_store, System.unique_integer([:positive])}
      )

    manual =
      start_instance(
        checkpoint_store: {@store, [store: manual_store]},
        checkpoint_mode: :manual
      )

    assert {:ok, _ref, _view} =
             Spectre.start_work(manual, @waiting_work, %{value: :manual}, id: "manual-loop")

    status = Spectre.checkpoint_status(manual)
    assert status.mode == :manual
    assert status.persisted_revision == 0
    assert status.canonical_revision > 0

    assert {:ok, persisted} = Spectre.flush_checkpoint(manual, timeout: 2_000)
    assert persisted == Spectre.checkpoint_status(manual).canonical_revision
    assert {:ok, ^persisted} = Spectre.flush_checkpoint(manual)
    assert {:ok, ^persisted} = Spectre.reconcile_checkpoint(manual)

    {:ok, ambiguous_store} =
      start_supervised(
        {Agent,
         fn ->
           %{
             checkpoint: nil,
             revision: 0,
             behavior: :ambiguous_without_commit,
             writes: 0
           }
         end},
        id: {:ambiguous_uncommitted_store, System.unique_integer([:positive])}
      )

    ambiguous =
      start_instance(
        checkpoint_store: {@store, [store: ambiguous_store]},
        checkpoint_mode: :async
      )

    assert {:ok, _ref, _view} =
             Spectre.start_work(ambiguous, @waiting_work, %{value: :ambiguous},
               id: "ambiguous-uncommitted-loop"
             )

    assert_eventually(fn ->
      not is_nil(Spectre.checkpoint_status(ambiguous).reconciliation_required)
    end)

    assert {:ok, 0} = Spectre.reconcile_checkpoint(ambiguous, timeout: 2_000)
    assert {:ok, revision} = Spectre.flush_checkpoint(ambiguous, timeout: 2_000)
    assert revision > 0
  end

  test "Instance startup validates ownership and bounded scheduler options" do
    assert_raise ArgumentError, ~r/custom :name is not supported/, fn ->
      Instance.start_link(agent: @agent, subject: unique_subject("named"), name: :forbidden)
    end

    assert_raise ArgumentError, ~r/requires an explicit :subject/, fn ->
      Instance.child_spec(agent: @agent)
    end

    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: invalid_conversation}, _stacktrace}} =
             Instance.start_link(
               agent: @agent,
               subject: unique_subject("invalid-conversation"),
               state_conversation_id: self()
             )

    assert invalid_conversation =~ "invalid Instance state_conversation_id"

    base = [agent: @agent, subject: unique_subject("invalid-options"), idle: false]

    assert {:error, {:invalid_instance_max_runs, 0}} =
             Instance.start_link(Keyword.put(base, :max_runs, 0))

    assert {:error, {:invalid_instance_max_tombstones, -1}} =
             Instance.start_link(
               base
               |> Keyword.put(:subject, unique_subject("invalid-tombstones"))
               |> Keyword.put(:max_tombstones, -1)
             )

    assert {:error, {:invalid_instance_max_runs, 0}} =
             Instance.start_link(
               base
               |> Keyword.put(:subject, unique_subject("invalid-runners"))
               |> Keyword.put(:max_operation_runners, 0)
             )

    assert {:error, {:invalid_checkpoint_mode, :invalid}} =
             Instance.start_link(
               base
               |> Keyword.put(:subject, unique_subject("invalid-checkpoint-mode"))
               |> Keyword.put(:checkpoint_mode, :invalid)
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "Instance rejects semantically corrupt canonical checkpoints" do
    subject = unique_subject("semantic-checkpoint")
    instance = start_instance(subject: subject)

    assert {:ok, ref, _view} =
             Spectre.start_work(instance, @waiting_work, %{value: :checkpoint},
               id: "semantic-checkpoint-loop"
             )

    assert {:ok, _view} = eventually_loop(instance, ref, &(&1.status == :waiting))
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, work} = Canonical.fetch(canonical, :work)
    assert {:ok, controls} = Canonical.fetch(canonical, :control)
    assert {:ok, events} = Canonical.fetch(canonical, :events)
    assert {:ok, correlations} = Canonical.fetch(canonical, :correlations)

    loop = Map.fetch!(work, ref.id)
    control = Map.fetch!(controls, ref.id)
    event = Enum.find(events.records, &(&1.loop_id == ref.id))
    assert event

    assert :ok = stop_supervised({Instance, Instance.ref(instance).key})

    duplicate_vigil = %{loop | kind: :vigil}
    invalid_loop = %{loop | status: :corrupt}
    mismatched_event = %{event | loop_kind: :vigil}
    invalid_event = %{event | id: ""}
    future_event = %{event | revision: canonical.revision + 1}

    wrong_subject_consent =
      Consent.new(
        id: "wrong-subject-consent",
        subject_id: "another-subject",
        destination: %{channel: :email, address: "person@example.test"}
      )

    invalid_consent = %{wrong_subject_consent | id: "", subject_id: subject.id}
    valid_consent = %{wrong_subject_consent | id: "valid-consent", subject_id: subject.id}

    receipt =
      struct!(DeliveryReceipt, %{
        id: "semantic-receipt",
        event_id: event.id,
        loop_id: ref.id,
        subject_id: subject.id,
        destination: %{channel: :email, address: "person@example.test"},
        channel: :email,
        dedupe_key: "semantic-dedupe",
        status: :authorized,
        decided_at: System.system_time(:millisecond)
      })

    corruptions = [
      {put_canonical_section(canonical, :flow, %{}), {:invalid_canonical_flow_state, %{}}},
      {put_canonical_section(canonical, :work, []), {:invalid_canonical_loop_section, :work}},
      {put_canonical_section(canonical, :work, %{"wrong-id" => loop}),
       {:invalid_canonical_loop_entry, :work, "wrong-id"}},
      {put_canonical_section(canonical, :work, %{ref.id => invalid_loop}),
       {:invalid_canonical_loop, ref.id, {:invalid_operational_loop_status, :corrupt}}},
      {put_canonical_section(canonical, :vigil, %{ref.id => duplicate_vigil}),
       :duplicate_canonical_operational_loop},
      {put_canonical_section(canonical, :control, %{}), :canonical_loop_control_set_mismatch},
      {put_canonical_section(canonical, :control, %{ref.id => :invalid}),
       {:invalid_canonical_loop_control, ref.id}},
      {put_canonical_section(canonical, :events, []), :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :events, %{records: nil, ids: %{}}),
       :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :events, %{records: [], ids: nil}),
       :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :events, %{records: [], ids: %{}, extra: true}),
       :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :events, %{
         records: List.duplicate(event, 513),
         ids: %{event.id => event.revision}
       }), :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :events, %{records: [:invalid], ids: %{}}),
       :invalid_canonical_operation_event},
      {put_canonical_section(canonical, :events, %{
         records: [event, event],
         ids: %{event.id => event.revision}
       }), :duplicate_canonical_operation_event},
      {put_canonical_section(canonical, :events, %{
         records: [mismatched_event],
         ids: %{mismatched_event.id => mismatched_event.revision}
       }), {:operation_event_loop_mismatch, event.id}},
      {put_canonical_section(canonical, :events, %{
         records: [invalid_event],
         ids: %{invalid_event.id => invalid_event.revision}
       }), {:invalid_canonical_operation_event, "", :invalid_operation_event_identity}},
      {put_canonical_section(canonical, :events, %{
         records: [future_event],
         ids: %{future_event.id => future_event.revision}
       }), {:operation_event_loop_mismatch, event.id}},
      {put_canonical_section(canonical, :events, %{records: [event], ids: %{}}),
       :invalid_canonical_operation_events},
      {put_canonical_section(canonical, :correlations, []), :invalid_canonical_correlations},
      {put_canonical_section(canonical, :correlations, %{
         correlations
         | instance_key: "wrong-instance"
       }), :canonical_checkpoint_instance_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :wrong_subject_consent, wrong_subject_consent)
       ), :delivery_consent_subject_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :invalid_consent, invalid_consent)
       ), {:invalid_delivery_consent, :delivery_consent_id_required}},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :wrong_consent_key, valid_consent)
       ), :delivery_consent_key_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :mismatched_receipt, %{receipt | loop_id: "missing-loop"})
       ), :delivery_receipt_loop_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :invalid_receipt, %{receipt | id: ""})
       ), {:invalid_delivery_receipt, :invalid_delivery_receipt_identity}},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :wrong_receipt_key, receipt)
       ), :delivery_receipt_key_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, "missing-loop-correlation", %{
           loop_id: "missing-loop",
           loop_kind: :work,
           revision: canonical.revision
         })
       ), :canonical_loop_correlation_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, loop.correlation_id, %{loop_id: ref.id})
       ), :invalid_canonical_loop_correlation},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, "wrong-loop-kind-correlation", %{
           loop_id: ref.id,
           loop_kind: :vigil,
           revision: canonical.revision
         })
       ), :canonical_loop_correlation_mismatch},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, "future-loop-correlation", %{
           loop_id: ref.id,
           loop_kind: :work,
           revision: canonical.revision + 1
         })
       ), :invalid_canonical_loop_correlation},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, "invalid-causation-correlation", %{
           loop_id: ref.id,
           loop_kind: :work,
           revision: canonical.revision,
           causation_id: :invalid
         })
       ), :invalid_canonical_loop_correlation},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, "extra-field-correlation", %{
           loop_id: ref.id,
           loop_kind: :work,
           revision: canonical.revision,
           unexpected: true
         })
       ), :invalid_canonical_loop_correlation},
      {put_canonical_section(
         canonical,
         :correlations,
         Map.put(correlations, :non_binary_correlation_key, %{
           loop_id: ref.id,
           loop_kind: :work,
           revision: canonical.revision
         })
       ), :invalid_canonical_loop_correlation},
      {put_canonical_section(
         canonical,
         :control,
         %{ref.id => %{control | loop_id: "another-loop"}}
       ), {:invalid_canonical_loop_control, ref.id}},
      {put_canonical_section(
         canonical,
         :control,
         %{ref.id => %{control | state: :terminal}}
       ),
       {:invalid_canonical_operational_checkpoint, ref.id,
        :nonterminal_loop_with_terminal_control}}
    ]

    previous_trap_exit = Process.flag(:trap_exit, true)

    Enum.each(corruptions, fn {corrupt, expected_reason} ->
      assert {:ok, encoded} = Codec.encode_json(corrupt)

      assert {:error, ^expected_reason} =
               Instance.start_link(
                 agent: @agent,
                 subject: subject,
                 canonical_checkpoint: encoded,
                 idle: false,
                 opts: [test_pid: self()]
               )
    end)

    extended_correlations =
      correlations
      |> Map.put("delivery:consent:#{valid_consent.id}", valid_consent)
      |> Map.put("delivery:receipt:#{receipt.id}", receipt)
      |> Map.put("extension:scalar", :kept)
      |> Map.put("extension:opaque", %{
        revision: canonical.revision,
        extension_revision: canonical.revision,
        payload: %{status: :kept}
      })

    extended = put_canonical_section(canonical, :correlations, extended_correlations)
    assert {:ok, encoded} = Codec.encode_json(extended)

    assert {:ok, restored} =
             Instance.start_link(
               agent: @agent,
               subject: subject,
               canonical_checkpoint: encoded,
               idle: false,
               opts: [test_pid: self()]
             )

    GenServer.stop(restored)

    Process.flag(:trap_exit, previous_trap_exit)
  end

  defp start_instance(extra \\ []) do
    {subject, extra} = Keyword.pop(extra, :subject, unique_subject("instance"))

    opts =
      [
        agent: @agent,
        subject: subject,
        idle: false,
        opts: [test_pid: self()]
      ]
      |> Keyword.merge(extra)

    start_supervised!({Instance, opts})
  end

  defp unique_subject(prefix) do
    Subject.new("#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp put_canonical_section(canonical, name, value) do
    {:ok, section} = Sections.fetch(canonical.sections, name)
    sections = Sections.put(canonical.sections, name, %{section | value: value})
    %{canonical | sections: sections}
  end

  defp collect_page_attempts(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:page_attempt, page, attempt, runner, _worker}, 1_000
      %{page: page, attempt: attempt, runner: runner}
    end)
  end

  defp eventually_loop(instance, ref, predicate, timeout \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually_loop(instance, ref, predicate, deadline)
  end

  defp do_eventually_loop(instance, ref, predicate, deadline) do
    case Spectre.loop(instance, ref) do
      {:ok, view} = success ->
        if predicate.(view) do
          success
        else
          continue_eventually_loop(instance, ref, predicate, deadline)
        end

      _other ->
        continue_eventually_loop(instance, ref, predicate, deadline)
    end
  end

  defp continue_eventually_loop(instance, ref, predicate, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      do_eventually_loop(instance, ref, predicate, deadline)
    else
      flunk("operational loop did not reach the expected state")
    end
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
