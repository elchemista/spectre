defmodule Spectre.Agents.DeferredOperationTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Instance
  alias Spectre.Store.Memory, as: ApplicationStore
  alias Spectre.Test.HandlerAgentCase
  alias Spectre.V04Test.Fixture

  @moduletag gated: true

  defmodule Assistant do
    use Spectre.Agent,
      namespace: "deferred-operation",
      name: "assistant",
      stack: HandlerAgentCase.Defaults

    router(HandlerAgentCase.Routes)
    request(:refund, class: "refund.issue")

    @impl true
    def handle_turn({:support, :refund, _captures}, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    @impl true
    def handle_result(_operation, result, _turn, state) do
      send(state.observer, {:continuation_started, self()})
      receive do: (:release_continuation -> :ok)
      {:ok, state |> Map.delete(:observer) |> Map.put(:result, result.status)}
    end
  end

  test "a real pending dispatch releases the worker without repeating its effect", c do
    {request, executor, submission} = defer(c)
    before = Sequencer.projection(c.fixture.server)

    for _read <- 1..3 do
      assert :pending = Instance.operation(c.instance, request.ref)
      refute Instance.info(c.instance).busy?
    end

    assert Sequencer.projection(c.fixture.server) === before
    assert Instance.state(c.instance).value.count == 1
    refute_received {:handler_execution, _, _, _}

    store = start_supervised!(ApplicationStore)

    assert {:ok, 1} =
             Instance.checkpoint(c.instance, {ApplicationStore, server: store}, "pending", 0)

    send(executor, :release)
    assert {:ok, _proposal} = Task.await(submission)
    assert {:ok, completed} = Instance.operation(c.instance, request.ref)
    assert completed.result.status == :done
    assert completed.result.request_ref == request.ref
    assert Instance.state(c.instance).value.result == :done
    assert Instance.operation(c.instance, request.ref) === {:ok, completed}
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "a newer turn fences the continuation, not the late durable outcome", c do
    {request, executor, submission} = defer(c)
    {current, _new_request} = prepare(c, "refund 21")
    before = Instance.state(c.instance)
    send(executor, :release)
    assert {:ok, _proposal} = Task.await(submission)

    assert {:error, {:instance_continuation_superseded, result}} =
             Instance.operation(c.instance, request.ref)

    assert result.status == :done
    assert result.request_ref == request.ref
    assert result.details.primary.outcome.status == :succeeded
    assert Instance.state(c.instance) === before
    assert Instance.current_turn(c.instance) === current

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  @tag executor_timeout: 50
  test "a host executor timeout frees the mutation slot but suspends its uncertain allocation",
       c do
    {_turn, request} = prepare(c, "refund 20")
    assert {:pending, ref} = Instance.advance(c.instance, request, wait: 0)
    assert_receive {:handler_execution, _executor, act, _attempt}, 1000

    store = start_supervised!(ApplicationStore)

    assert {:ok, 1} =
             Instance.checkpoint(c.instance, {ApplicationStore, server: store}, "timeout", 0)

    assert {:ok, completed} = Instance.operation(c.instance, ref)
    assert completed.result.status == :unclear
    assert completed.result.details.primary.outcome.status == :ambiguous
    refute Instance.info(c.instance).busy?

    projection = Sequencer.projection(c.fixture.server)

    assert %{reserved: 0, suspended: 20, spent: 0} =
             projection.meters[act.mandate_ref][c.fixture.refs.meter]

    assert Enum.any?(projection.duties, fn {_ref, duty} ->
             duty.act_ref == act.ref and duty.class == :ambiguous_outcome
           end)

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    prepare(c, "refund 21")
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "an executor worker crash releases queued work without fabricating a terminal Outcome",
       c do
    {_turn, request} = prepare(c, "refund 20")
    assert {:pending, ref} = Instance.advance(c.instance, request, wait: 0)
    assert_receive {:handler_execution, executor, act, attempt}, 1000
    before = Sequencer.projection(c.fixture.server)
    store = start_supervised!(ApplicationStore)

    queued =
      :gen_server.send_request(
        c.instance,
        {:checkpoint, {ApplicationStore, server: store}, "crashed-executor", 0}
      )

    # A same-sender read proves the checkpoint reached the FIFO before death.
    assert Instance.info(c.instance).pending_operations == 1
    Process.exit(executor, :kill)
    assert {:reply, {:ok, 1}} = :gen_server.receive_response(queued, 1000)
    assert {:error, {:instance_operation_stopped, :advance}} = Instance.operation(c.instance, ref)
    refute Instance.info(c.instance).busy?
    assert Sequencer.projection(c.fixture.server) === before
    assert before.attempts[attempt.ref] == attempt
    refute Enum.any?(before.outcomes, fn {_ref, outcome} -> outcome.act_ref == act.ref end)

    assert %{reserved: 20, suspended: 0, spent: 0} =
             before.meters[act.mandate_ref][c.fixture.refs.meter]

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, request)

    prepare(c, "refund 21")
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "concurrent claims of one genuine checkout receipt still release only one capability", c do
    {_turn, request} = prepare(c, "refund 20")

    assert {:ok, %{grant: grant}} =
             Sequencer.submit(c.fixture.server, Fixture.context(c.fixture), request.candidate)

    assert {:ok, act, attempt, receipt} = Sequencer.consume_grant(c.fixture.server, grant)
    before = Sequencer.projection(c.fixture.server)
    {broker, opts} = Keyword.fetch!(c.fixture.sequencer_opts, :broker)

    claimants =
      for _caller <- 1..8 do
        Task.async(fn ->
          receive do: (:claim -> broker.checkout(receipt, act, attempt, opts))
        end)
      end

    for task <- claimants, do: send(task.pid, :claim)
    replies = Task.await_many(claimants)
    assert Enum.count(replies, &match?({:ok, :test_only}, &1)) == 1
    assert Enum.count(replies, &match?({:error, :ambiguous, _}, &1)) == 7
    assert {:error, :ambiguous, _} = broker.checkout(receipt, act, attempt, opts)
    assert Sequencer.projection(c.fixture.server) === before
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  @tag handler: Assistant, standard_wiring: true
  test "concurrent reads and an old timer cannot run or interrupt a continuation twice", c do
    c = controlled_instance(c)
    {request, executor, submission} = defer(c)
    send(executor, :release)
    assert {:ok, _proposal} = Task.await(submission)
    recovery = Task.async(fn -> Instance.operation(c.instance, request.ref, :infinity) end)
    assert_receive {:continuation_started, worker}, 1000

    # The original advance has already replied. Its delayed timer must not
    # clear the new recovery caller's reply address for this same request ref.
    send(c.instance, {:advance_wait_elapsed, request.ref, {self(), make_ref()}})
    assert :pending = Instance.operation(c.instance, request.ref)
    assert Instance.state(c.instance, 200).value.count == 1
    assert Task.yield(recovery, 0) == nil
    send(worker, :release_continuation)
    assert {:ok, completed} = Task.await(recovery)
    assert completed.result.status == :done
    assert Instance.operation(c.instance, request.ref) === {:ok, completed}
    refute_received {:continuation_started, _}
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  @tag handler: Assistant, standard_wiring: true
  test "a caller timeout does not retry or cancel an accepted continuation", c do
    c = controlled_instance(c)
    {request, executor, submission} = defer(c)
    send(executor, :release)
    assert {:ok, _proposal} = Task.await(submission)
    caller = Task.async(fn -> catch_exit(Instance.operation(c.instance, request.ref, 50)) end)
    assert_receive {:continuation_started, worker}, 1000
    assert {:timeout, _} = Task.await(caller)
    assert :pending = Instance.operation(c.instance, request.ref)

    store = start_supervised!(ApplicationStore)

    barrier =
      Task.async(fn ->
        Instance.checkpoint(c.instance, {ApplicationStore, server: store}, "complete", 0)
      end)

    send(worker, :release_continuation)
    assert {:ok, 1} = Task.await(barrier)
    assert {:ok, %{result: %{status: :done}}} = Instance.operation(c.instance, request.ref)
    refute_received {:continuation_started, _}
    refute_received {:handler_execution, _, _, _}
  end

  @tag handler: Assistant, standard_wiring: true
  test "Domain loss during recovery replies to the caller and stops the worker", c do
    c = controlled_instance(c)
    {request, executor, submission} = defer(c)
    send(executor, :release)
    assert {:ok, _proposal} = Task.await(submission)
    recovery = Task.async(fn -> Instance.operation(c.instance, request.ref, :infinity) end)
    assert_receive {:continuation_started, worker}, 1000
    monitor = Process.monitor(worker)
    GenServer.stop(c.fixture.server, :normal)
    assert {:error, {:domain_down, :normal}} = Task.await(recovery)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    refute_received {:handler_execution, _, _, _}
  end

  test "deferred tickets are bounded without erasing their durable occurrences", c do
    pending = for _index <- 1..66, do: defer(c)
    [{oldest, _, _} | _] = pending
    {latest, _, _} = List.last(pending)
    assert {:error, :instance_operation_not_retained} = Instance.operation(c.instance, oldest.ref)
    assert :pending = Instance.operation(c.instance, latest.ref)

    # Inspect only the local retention bound, never replace the owner state or
    # fabricate any dispatch fact for this memory regression.
    assert map_size(:sys.get_state(c.instance).operations) == 64

    for {_request, executor, submission} <- pending do
      send(executor, :release)
      assert {:ok, _proposal} = Task.await(submission)
    end

    projection = Sequencer.projection(c.fixture.server)
    assert map_size(projection.attempts) == 66
    assert map_size(projection.outcomes) == 66
    assert {:ok, %{result: %{status: :done}}} = Instance.operation(c.instance, latest.ref)

    assert {:error, :invalid_or_superseded_instance_request} =
             Instance.advance(c.instance, oldest)

    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  defp defer(c) do
    {_turn, request} = prepare(c, "refund 20")
    submission = Task.async(fn -> Spectre.propose(c.scope, request.candidate) end)
    assert_receive {:handler_execution, executor, _act, _attempt}, 1000

    # Reusing this occurrence reads the already-attempted dispatch. This is a
    # genuine pending Proposal, not just the Instance's wait timer expiring.
    assert {:pending, ref} = Instance.advance(c.instance, request, wait: :infinity)
    assert ref == request.ref
    refute Instance.info(c.instance).busy?
    {request, executor, submission}
  end

  defp controlled_instance(c) do
    opts = Keyword.put(c.instance_options, :state, Map.put(c.state, :observer, self()))
    instance = start_supervised!(Supervisor.child_spec({Instance, opts}, id: :controlled))
    %{c | instance: instance}
  end
end
