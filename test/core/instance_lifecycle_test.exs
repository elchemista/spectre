defmodule Spectre.CoreTest.InstanceLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.{Definition, Instance, Ledger, Store}
  alias Spectre.Domain.Projection
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule WaitingMind do
    @behaviour Spectre.Mind

    @impl true
    def ref, do: "mind:instance-lifecycle"

    @impl true
    def deliberate(_turn, _opts), do: {:ok, []}

    @impl true
    def deliberate(turn, state, opts) do
      token = Keyword.fetch!(opts, :token)
      send(Keyword.fetch!(opts, :observer), {:mind_started, self(), token, state, turn})

      receive do
        {:finish, ^token, {:error, reason}} -> {:error, reason}
        {:finish, ^token, value} -> {:ok, [], value}
      end
    end
  end

  defmodule WaitingStore do
    @behaviour Spectre.Store

    alias Spectre.Store.Memory

    @impl true
    defdelegate get(key, opts), to: Memory

    @impl true
    def compare_and_swap(key, expected, value, opts) do
      send(Keyword.fetch!(opts, :observer), {:checkpoint_started, self()})

      receive do
        :write_checkpoint -> Memory.compare_and_swap(key, expected, value, opts)
      end
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())

    {:ok, definition} =
      Definition.new(
        namespace: "test",
        name: "instance-lifecycle",
        revision: 1,
        declared_at: Runtime.now(),
        body: %{}
      )

    domain_ref = "v0.4:instance-lifecycle:domain"

    fixture =
      Fixture.start_domain(
        namespace: "instance-lifecycle",
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref],
        mind: WaitingMind
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(domain_ref)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    {:ok, governance_scope} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    assert {:ok, result} =
             Spectre.revise_definition(governance_scope, definition,
               identity_key: "register-instance-definition",
               requested_mandate_ref: fixture.governance_mandate.ref,
               accountable_ref: fixture.refs.accountable,
               purpose_ref: fixture.refs.purpose,
               purpose_params: %{"currency" => "EUR"}
             )

    assert result.primary.decision.outcome == :admitted
    %{fixture: fixture, domain: domain, scope: scope, definition: definition}
  end

  test "all four reads stay responsive while a Mind is held at an explicit barrier", c do
    instance = instance(c)
    {caller, worker, token, turn} = begin_turn(c, instance)
    refute worker == instance
    refute worker == c.fixture.server
    assert Process.alive?(worker)

    assert Instance.state(instance, 1_000) == %{revision: 0, value: 0}
    assert Instance.info(instance, 1_000).state_revision == 0
    assert Instance.scope(instance, 1_000) == c.scope
    assert Instance.state(instance, :infinity) == %{revision: 0, value: 0}
    assert Instance.info(instance, :infinity).state_revision == 0
    assert Instance.scope(instance, :infinity) == c.scope
    assert {:ok, definition} = Instance.definition(instance, 1_000)
    assert definition == c.definition
    assert {:ok, []} = Spectre.acts(c.scope)

    send(worker, {:finish, token, 7})
    assert {:ok, %{turn: ^turn, candidates: []}} = Task.await(caller)
    assert Instance.state(instance) == %{revision: 1, value: 7}
  end

  test "the FIFO observes completed state and rejects overflow without starting another Mind",
       c do
    instance = instance(c, max_pending_operations: 1)
    {first, worker, token, _turn} = begin_turn(c, instance)
    second_token = make_ref()

    # Same-sender request/read ordering establishes that the second call has
    # reached the queue. No sleeps or scheduler timing assumptions are needed.
    second = :gen_server.send_request(instance, turn_request(c, second_token))
    assert Instance.state(instance) == %{revision: 0, value: 0}
    refute_receive {:mind_started, _, ^second_token, _, _}, 0
    assert {:error, :instance_busy} = Instance.turn(instance, input(c))

    send(worker, {:finish, token, 1})
    assert {:ok, _} = Task.await(first)
    assert_receive {:mind_started, next, ^second_token, 1, _}, 1_000
    refute worker == next
    assert Instance.state(instance) == %{revision: 1, value: 1}
    send(next, {:finish, second_token, 2})
    assert {:reply, {:ok, _}} = :gen_server.receive_response(second, 1_000)
    assert Instance.state(instance) == %{revision: 2, value: 2}
  end

  test "zero pending capacity admits idle work but refuses every concurrent mutation", c do
    instance = instance(c, max_pending_operations: 0)
    {caller, worker, token, _} = begin_turn(c, instance)

    assert {:error, :instance_busy} = Instance.turn(instance, input(c))
    assert {:error, :instance_busy} = Instance.propose(instance, %{})
    assert {:error, :instance_busy} = Instance.checkpoint(instance, WaitingStore, "key", 0)
    assert Instance.scope(instance) == c.scope
    send(worker, {:finish, token, 0})
    assert {:ok, _} = Task.await(caller)
    assert Instance.state(instance) == %{revision: 0, value: 0}
  end

  test "a queued checkpoint captures the new value and slow storage does not block reads", c do
    instance = instance(c)
    owner = start_supervised!(Store.Memory)
    store = {WaitingStore, server: owner, observer: self()}
    {caller, worker, token, _} = begin_turn(c, instance)
    checkpoint = :gen_server.send_request(instance, {:checkpoint, store, "mind", 0})
    assert Instance.state(instance) == %{revision: 0, value: 0}
    refute_receive {:checkpoint_started, _}, 0

    send(worker, {:finish, token, 12})
    assert {:ok, _} = Task.await(caller)
    assert_receive {:checkpoint_started, writer}, 1_000
    refute writer == instance
    assert Instance.state(instance, 1_000) == %{revision: 1, value: 12}
    assert :not_found = Store.get(store, "mind")

    send(writer, :write_checkpoint)
    assert {:reply, {:ok, 1}} = :gen_server.receive_response(checkpoint, 1_000)
    assert {:ok, 1, record} = Store.get(store, "mind")
    assert record["state_revision"] == 1
    assert record["value"] == 12
    refute Map.has_key?(record, "scope")
  end

  test "a Mind error preserves application state but does not erase observed input", c do
    instance = instance(c)
    {caller, worker, token, turn} = begin_turn(c, instance)
    send(worker, {:finish, token, {:error, :cannot_plan}})
    assert {:error, :cannot_plan} = Task.await(caller)
    assert Instance.state(instance) == %{revision: 0, value: 0}
    assert Process.alive?(instance)
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, state} = Projection.replay(snapshot, c.fixture.constitution)
    for evidence <- turn.evidence, do: assert(state.evidence[evidence.ref] == evidence)
    assert {:ok, []} = Spectre.acts(c.scope)
  end

  test "worker death neither retries the turn nor accepts its stale completion", c do
    instance = instance(c)
    {caller, worker, _token, _turn} = begin_turn(c, instance)
    old_ref = :sys.get_state(instance).job.task.ref
    next_token = make_ref()
    next_call = :gen_server.send_request(instance, turn_request(c, next_token))
    assert Instance.state(instance) == %{revision: 0, value: 0}

    Process.exit(worker, :kill)
    assert {:error, {:instance_operation_stopped, :turn}} = Task.await(caller)
    assert_receive {:mind_started, next, ^next_token, 0, _}, 1_000
    send(instance, {old_ref, {:advance, {:ok, %{}}, 999}})
    assert Instance.state(instance) == %{revision: 0, value: 0}
    send(next, {:finish, next_token, 1})
    assert {:reply, {:ok, _}} = :gen_server.receive_response(next_call, 1_000)
    assert Instance.state(instance) == %{revision: 1, value: 1}
    refute_receive {:mind_started, _, _, _, _}, 0
  end

  test "Domain loss stops a blocked Instance and worker without starting queued work", c do
    instance = instance(c)
    {caller, worker, _token, _turn} = begin_turn(c, instance)
    monitor = Process.monitor(instance)
    worker_monitor = Process.monitor(worker)
    queued_token = make_ref()
    queued = :gen_server.send_request(instance, turn_request(c, queued_token))
    assert Instance.state(instance) == %{revision: 0, value: 0}

    GenServer.stop(c.fixture.server)
    assert_receive {:DOWN, ^monitor, :process, ^instance, {:shutdown, {:domain_down, :normal}}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert {:error, {:domain_down, :normal}} = Task.await(caller)

    assert {:reply, {:error, {:domain_down, :normal}}} =
             :gen_server.receive_response(queued, 1_000)

    refute_receive {:mind_started, _, ^queued_token, _, _}, 0
  end

  test "an abnormal owner exit does not orphan a running Mind", c do
    instance = instance(c)
    {caller, worker, _token, _} = begin_turn(c, instance)
    monitor = Process.monitor(worker)
    Process.exit(instance, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert {:caller_exit, _} = Task.await(caller)
  end

  test "normal owner shutdown also stops its worker", c do
    instance = instance(c)
    {caller, worker, _token, _} = begin_turn(c, instance)
    monitor = Process.monitor(worker)
    GenServer.stop(instance)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert {:caller_exit, _} = Task.await(caller)
  end

  test "caller death does not silently cancel already accepted work", c do
    instance = instance(c)
    observer = self()
    token = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        Instance.turn(instance, input(c), mind_opts: [observer: observer, token: token])
      end)

    assert_receive {:mind_started, worker, ^token, 0, _}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert Process.alive?(worker)
    checkpoint_owner = start_supervised!(Store.Memory)
    store = {Store.Memory, server: checkpoint_owner}
    completed = :gen_server.send_request(instance, {:checkpoint, store, "after-caller-death", 0})
    send(worker, {:finish, token, 3})
    assert {:reply, {:ok, 1}} = :gen_server.receive_response(completed, 1_000)
    assert Instance.state(instance) == %{revision: 1, value: 3}
  end

  test "a completed Mind result is checked against the live Scope before updating state", c do
    instance = instance(c)
    {caller, worker, token, _} = begin_turn(c, instance)
    monitor = Process.monitor(instance)
    rotate_generation(c)
    send(worker, {:finish, token, 999})
    assert {:error, reason} = Task.await(caller)
    assert_receive {:DOWN, ^monitor, :process, ^instance, {:shutdown, {:scope_fenced, ^reason}}}
  end

  test "definition lookup observes the fence while a Mind is still blocked", c do
    instance = instance(c)
    {caller, worker, _token, _} = begin_turn(c, instance)
    monitor = Process.monitor(instance)
    worker_monitor = Process.monitor(worker)
    rotate_generation(c)

    assert {:error, reason} = Instance.definition(instance, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^instance, {:shutdown, {:scope_fenced, ^reason}}}
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 1_000
    assert {:error, {:scope_fenced, ^reason}} = Task.await(caller)
  end

  test "invalid queue capacities are rejected before starting a process", c do
    for invalid <- [-1, 1.0, :infinity, nil, "32"] do
      assert {:error, :invalid_instance_pending_limit} =
               Instance.start_link(
                 scope: c.scope,
                 definition_ref: c.definition.ref,
                 max_pending_operations: invalid
               )
    end
  end

  defp instance(c, opts \\ []) do
    spec =
      Supervisor.child_spec(
        {Instance,
         Keyword.merge([scope: c.scope, definition_ref: c.definition.ref, state: 0], opts)},
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp begin_turn(c, instance) do
    token = make_ref()
    observer = self()

    caller =
      Task.async(fn ->
        try do
          Instance.turn(instance, input(c), mind_opts: [observer: observer, token: token])
        catch
          :exit, reason -> {:caller_exit, reason}
        end
      end)

    assert_receive {:mind_started, worker, ^token, 0, turn}, 1_000
    {caller, worker, token, turn}
  end

  defp turn_request(c, token),
    do: {:turn, input(c), [mind_opts: [observer: self(), token: token]]}

  defp input(c),
    do: c.fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)

  defp rotate_generation(c) do
    # Isolate generation invalidation without killing the Domain: the Instance's
    # Domain monitor alone cannot satisfy either of these Scope-fence tests.
    :sys.replace_state(c.fixture.server, &%{&1 | generation: &1.generation + 1})
  end
end
