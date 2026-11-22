defmodule Spectre.Server.ActivitiesTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.Activities
  alias Spectre.Server.Registry, as: ServerRegistry
  alias Spectre.Server.TaskSupervisor
  alias Spectre.Test.Processes

  @timeout 2_000

  defmodule Fixture do
    use GenServer

    def start_link(opts), do: start_link(opts[:start], opts)

    defp start_link(result, _opts) when result in [:ignore, :invalid], do: result

    defp start_link(nil, opts) do
      with {:ok, child} <- GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name])),
           {:ok, child} <- wait_for_test(child, opts[:barrier], Keyword.fetch!(opts, :observer)) do
        if Keyword.has_key?(opts, :info), do: {:ok, child, opts[:info]}, else: {:ok, child}
      end
    end

    defp wait_for_test(child, nil, _observer), do: {:ok, child}

    defp wait_for_test(child, barrier, observer) do
      send(observer, {:fixture_waiting, barrier, self(), child})

      receive do
        {:release_fixture, ^barrier} -> {:ok, child}
      after
        2_000 ->
          GenServer.stop(child)
          {:error, :fixture_timeout}
      end
    end

    @impl true
    def init(opts), do: {:ok, %{owner: Keyword.fetch!(opts, :observer), ref: nil, count: 0}}

    @impl true
    def handle_info({:spectre_activity, :activate, ref}, %{ref: nil} = state) do
      send(state.owner, {:fixture_activated, ref, self()})
      {:noreply, %{state | ref: ref}}
    end

    @impl true
    def handle_call(:work, _from, %{ref: nil} = state),
      do: {:reply, {:error, :waiting_for_activation}, state}

    def handle_call(:work, _from, state) do
      count = state.count + 1
      {:reply, {:ok, count}, %{state | count: count}}
    end
  end

  defmodule Unavailable do
    use GenServer

    def start_link(_opts), do: {:error, :fixture_unavailable}

    @impl true
    def init(_opts), do: :ignore
  end

  defmodule Callback do
    use Spectre.Server

    def handle_flow({:fixture, :ping}, _input, ctx), do: respond(ctx, "pong")
    def handle_flow(route, input, ctx), do: super(route, input, ctx)

    def handle_call({:launch_fixture, coordinator, command, specification}, _from, ctx),
      do: {:reply, Activities.start(coordinator, command, specification), ctx}

    def handle_call({:hold_start_reply, coordinator, command, specification}, {caller, _}, ctx) do
      send(caller, {:start_reply_held, Activities.start(coordinator, command, specification)})
      {:noreply, ctx}
    end

    def handle_call(request, from, ctx), do: super(request, from, ctx)
  end

  defmodule Definition do
    use Spectre.Agent, server: Callback
    router(strategies: [:regex])

    flow :fixture do
      on(:ping, regex: ~r/^ping$/)
    end
  end

  test "reservations are lazy and concurrent replays activate one child" do
    coordinator = start_coordinator()
    specification = fixture()
    assert {:ok, ref} = Activities.reserve(coordinator, "reserved", specification)

    assert {:error, :activity_command_conflict} =
             Activities.reserve(coordinator, "reserved", fixture(barrier: make_ref()))

    assert is_nil(Activities.supervisor(coordinator))

    starts =
      for _ <- 1..2 do
        Task.async(fn -> Activities.start(coordinator, "reserved", specification) end)
      end

    assert Task.await_many(starts, @timeout) == [{:ok, ref}, {:ok, ref}]
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, %{status: :running, pid: ^child}} = Activities.lookup(coordinator, ref)

    assert [{:undefined, ^child, :worker, _}] =
             DynamicSupervisor.which_children(Activities.supervisor(coordinator))
  end

  test "start recovery only resumes an existing reservation" do
    {:ok, coordinator} = Activities.start_link()
    on_exit(fn -> Processes.stop(coordinator) end)

    assert {:error, :activity_start_outcome_unknown} =
             Activities.recover_start(coordinator, "unknown", nil)

    assert {:error, :unknown_activity} = Activities.resume(coordinator, "unknown")
    assert nil == Activities.supervisor(coordinator)

    assert {:ok, ref} = Activities.reserve(coordinator, "saved", fixture(), as: :report)

    assert {:ok, %{ref: ^ref, key: :report}} =
             Activities.recover_start(coordinator, "saved", :report)

    assert_receive {:fixture_activated, ^ref, child}, @timeout

    assert {:ok, %{ref: ^ref, key: :report}} =
             Activities.recover_start(coordinator, "saved", :report)

    assert {:ok, %{pid: ^child, status: :running}} = Activities.lookup(coordinator, ref)
    refute_received {:fixture_activated, ^ref, _}

    assert :ok = GenServer.stop(coordinator)

    assert {:error, :activity_start_outcome_unknown} =
             Activities.recover_start(coordinator, "saved", :report)
  end

  test "OTP startup info is accepted and ignored or invalid startup never activates" do
    coordinator = start_coordinator()

    assert {:ok, ref} = Activities.start(coordinator, "info", fixture(info: :lease))
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, %{pid: ^child, status: :running}} = Activities.lookup(coordinator, ref)

    for {return, reason} <- [
          ignore: :activity_start_ignored,
          invalid: :invalid_activity_child_start
        ] do
      spec = {Fixture, [start: return]}
      assert {:ok, failed} = Activities.reserve(coordinator, Atom.to_string(return), spec)
      assert {:error, ^reason} = Activities.resume(coordinator, failed)

      assert {:ok, %{status: :failed, pid: nil, reason: ^reason}} =
               Activities.lookup(coordinator, failed)

      refute_received {:fixture_activated, ^failed, _}
    end
  end

  test "a lost coordinator keeps request failures distinct from missing Activity entries" do
    coordinator = start_supervised!({Activities, []}, restart: :temporary)
    input = %Spectre.Input{text: "reply"}
    :sys.suspend(coordinator)

    request = Task.async(fn -> Activities.input(coordinator, nil, input) end)

    eventually(fn ->
      {:messages, messages} = Process.info(coordinator, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:input, nil, ^input}}, &1))
    end)

    Process.exit(coordinator, :kill)
    assert {:error, :activity_input_outcome_unknown} = Task.await(request, @timeout)
    assert {:error, :activity_owner_unavailable} = Activities.input(coordinator, nil, input)
    assert {:error, :activity_owner_unavailable} = Activities.view(coordinator, "old")
    assert {:error, :activity_owner_unavailable} = Activities.presentation(coordinator, "old")
    refute Activities.awaiting_children?(coordinator, "old")
  end

  test "an Activity crash leaves sibling work and the direct Root available" do
    root = start_root()
    assert {:links, links} = Process.info(root, :links)
    assert self() in links
    coordinator = start_coordinator()

    assert {:ok, first_ref} = Activities.start(coordinator, "first", fixture())
    assert {:ok, second_ref} = Activities.start(coordinator, "second", fixture())
    refute first_ref == second_ref
    assert_receive {:fixture_activated, ^first_ref, first}, @timeout
    assert_receive {:fixture_activated, ^second_ref, second}, @timeout

    first_monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :killed}, @timeout
    eventually(fn -> Activities.lookup(coordinator, first_ref) |> failed?() end)

    assert {:ok, %{status: :running, pid: ^second}} = Activities.lookup(coordinator, second_ref)
    assert {:ok, 1} = GenServer.call(second, :work)
    assert_root_responds(root)
    assert {:ok, ^first_ref} = Activities.start(coordinator, "first", fixture())
    assert {:ok, %{status: :failed, pid: nil}} = Activities.lookup(coordinator, first_ref)
  end

  test "the supervised Root survives loss of the Activity supervisor and retains subject ownership" do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    options = [subject: "activity-fixture", consumer: self()]
    assert {:ok, root} = Spectre.Supervisor.summon(supervisor, Definition, options)
    assert {:ok, ^root} = Spectre.Supervisor.summon(supervisor, Definition, options)
    assert_root_responds(root)

    coordinator = start_coordinator()
    assert {:ok, ref} = Activities.start(coordinator, "first", fixture())
    assert_receive {:fixture_activated, ^ref, child}, @timeout

    activity_supervisor = Activities.supervisor(coordinator)
    supervisor_monitor = Process.monitor(activity_supervisor)
    child_monitor = Process.monitor(child)
    Process.exit(activity_supervisor, :kill)
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^activity_supervisor, :killed}, @timeout
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, @timeout
    eventually(fn -> Activities.lookup(coordinator, ref) |> failed?() end)
    eventually(fn -> is_nil(Activities.supervisor(coordinator)) end)

    assert_root_responds(root)
    assert {:ok, ^root} = Spectre.Supervisor.summon(supervisor, Definition, options)
    assert {:ok, replacement} = Activities.start(coordinator, "new", fixture())
    assert_receive {:fixture_activated, ^replacement, replacement_child}, @timeout
    assert replacement_child != child
    assert {:ok, 1} = GenServer.call(replacement_child, :work)
  end

  test "an unspawned reservation can resume after the Root dies" do
    root = start_root()
    coordinator = start_coordinator()
    specification = fixture()
    assert {:ok, ref} = Activities.reserve(coordinator, "interrupted", specification)
    assert is_nil(Activities.supervisor(coordinator))

    kill_root(root)

    replacement = start_root()
    assert_root_responds(replacement)
    assert {:ok, ^ref} = Activities.resume(coordinator, ref)
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, ^ref} = Activities.start(coordinator, "interrupted", specification)
    assert {:ok, 1} = GenServer.call(child, :work)
  end

  test "a child created before Root loss stays inert until activation and retains its ref" do
    root = start_root()
    coordinator = start_coordinator()
    barrier = make_ref()
    specification = fixture(barrier: barrier)

    {:ok, ref} = Activities.reserve(coordinator, "before-activation", specification)

    :gen_server.send_request(
      root,
      {:launch_fixture, coordinator, "before-activation", specification}
    )

    assert_receive {:fixture_waiting, ^barrier, starter, child}, @timeout
    assert {:error, :waiting_for_activation} = GenServer.call(child, :work)

    kill_root(root)
    send(starter, {:release_fixture, barrier})

    assert_receive {:fixture_activated, ^ref, ^child}, @timeout
    assert {:ok, ^ref} = Activities.start(coordinator, "before-activation", specification)
    assert {:ok, %{status: :running, pid: ^child}} = Activities.lookup(coordinator, ref)
    assert {:ok, 1} = GenServer.call(child, :work)
    assert_root_responds(start_root())
  end

  test "a child spawned by a killed launcher is cleaned up and its error is replayed" do
    coordinator = start_coordinator()
    barrier = make_ref()
    specification = fixture(barrier: barrier)
    assert {:ok, ref} = Activities.reserve(coordinator, "lost-launcher", specification)
    request = Task.async(fn -> Activities.resume(coordinator, ref) end)

    assert_receive {:fixture_waiting, ^barrier, supervisor, child}, @timeout
    assert {:error, :waiting_for_activation} = GenServer.call(child, :work)

    child_monitor = Process.monitor(child)
    launcher = launch_task(coordinator)
    launch_monitor = Process.monitor(launcher)
    Process.exit(launcher, :kill)
    assert_receive {:DOWN, ^launch_monitor, :process, ^launcher, :killed}, @timeout

    send(supervisor, {:release_fixture, barrier})

    assert {:error, :killed} = Task.await(request, @timeout)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, @timeout
    assert [] = DynamicSupervisor.which_children(supervisor)
    eventually(fn -> Registry.lookup(ServerRegistry, {Activities, coordinator, ref}) == [] end)

    assert {:ok, %{status: :failed, pid: nil, reason: :killed}} =
             Activities.lookup(coordinator, ref)

    assert {:error, :killed} = Activities.start(coordinator, "lost-launcher", specification)
    refute_received {:fixture_activated, ^ref, _}
  end

  test "a Registry restart preserves a reservation while the old Activity branch is shutting down" do
    registry = start_registry()
    coordinator = start_coordinator(registry: ActivityTestRegistry)
    barrier = make_ref()

    {:ok, blocked_ref} =
      Activities.reserve(coordinator, "blocked-start", fixture(barrier: barrier))

    request = Task.async(fn -> Activities.resume(coordinator, blocked_ref) end)

    assert_receive {:fixture_waiting, ^barrier, old_supervisor, waiting_child}, @timeout
    old_supervisor_monitor = Process.monitor(old_supervisor)
    child_monitor = Process.monitor(waiting_child)
    specification = fixture()
    assert {:ok, ref} = Activities.reserve(coordinator, "retry-after-restart", specification)

    :erlang.trace(coordinator, true, [:receive])
    assert :ok = stop_supervised(ActivityTestRegistry)
    assert_receive {:trace, ^coordinator, :receive, {:DOWN, _, :process, ^registry, _}}, @timeout
    :erlang.trace(coordinator, false, [:receive])

    assert start_registry() != registry
    assert Process.alive?(old_supervisor)

    retry = Task.async(fn -> Activities.resume(coordinator, ref) end)
    assert {:error, reason} = Task.await(retry, @timeout)
    assert reason in [:activity_supervisor_unavailable, :server_registry_unavailable]
    assert {:ok, %{status: :reserved, pid: nil}} = Activities.lookup(coordinator, ref)

    send(old_supervisor, {:release_fixture, barrier})
    assert_receive {:DOWN, ^old_supervisor_monitor, :process, ^old_supervisor, _}, @timeout
    assert_receive {:DOWN, ^child_monitor, :process, ^waiting_child, _}, @timeout
    assert {:error, _} = Task.await(request, @timeout)
    refute_received {:fixture_activated, ^blocked_ref, _}
    eventually(fn -> is_nil(Activities.supervisor(coordinator)) end)

    assert {:ok, ^ref} = Activities.start(coordinator, "retry-after-restart", specification)
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, 1} = GenServer.call(child, :work)
  end

  test "completed work and rejected startup both replay their original outcome" do
    coordinator = start_coordinator()
    specification = fixture()
    assert {:ok, ref} = Activities.start(coordinator, "complete", specification)
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, 1} = GenServer.call(child, :work)
    assert :ok = GenServer.stop(child)

    eventually(fn ->
      match?({:ok, %{status: :completed, pid: nil}}, Activities.lookup(coordinator, ref))
    end)

    assert {:ok, ^ref} = Activities.start(coordinator, "complete", specification)
    failure = {Unavailable, []}
    assert {:ok, failed_ref} = Activities.reserve(coordinator, "unavailable", failure)
    assert {:error, :fixture_unavailable} = Activities.resume(coordinator, failed_ref)
    assert {:error, :fixture_unavailable} = Activities.start(coordinator, "unavailable", failure)

    assert {:ok, %{status: :failed, reason: :fixture_unavailable}} =
             Activities.lookup(coordinator, failed_ref)
  end

  test "Root loss after activation and before its reply adopts the running child" do
    root = start_root()
    coordinator = start_coordinator()
    specification = fixture()

    :gen_server.send_request(root, {:hold_start_reply, coordinator, "lost-reply", specification})

    assert_receive {:start_reply_held, {:ok, ref}}, @timeout
    assert_receive {:fixture_activated, ^ref, child}, @timeout
    assert {:ok, 1} = GenServer.call(child, :work)
    kill_root(root)

    assert_root_responds(start_root())
    assert {:ok, ^ref} = Activities.start(coordinator, "lost-reply", specification)
    assert {:ok, %{status: :running, pid: ^child}} = Activities.lookup(coordinator, ref)
    assert {:ok, 2} = GenServer.call(child, :work)
  end

  defp start_coordinator(opts \\ []), do: start_supervised!({Activities, opts})

  defp start_registry do
    start_supervised!(
      {Registry, keys: :unique, name: ActivityTestRegistry},
      id: ActivityTestRegistry,
      restart: :temporary
    )
  end

  defp launch_task(coordinator) do
    {:monitors, monitors} = Process.info(coordinator, :monitors)

    [launcher] =
      Enum.filter(Task.Supervisor.children(TaskSupervisor), &({:process, &1} in monitors))

    launcher
  end

  defp start_root do
    {:ok, root} = Server.start_link(agent: Definition, consumer: self())
    on_exit(fn -> Processes.stop(root) end)
    root
  end

  defp fixture(opts \\ []), do: {Fixture, [observer: self()] ++ opts}

  defp kill_root(root) do
    Process.unlink(root)
    monitor = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, @timeout
  end

  defp assert_root_responds(root) do
    assert {:ok, id} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^id, "pong", _}}, @timeout
  end

  defp failed?({:ok, %{status: :failed, pid: nil}}), do: true
  defp failed?(_), do: false

  defp eventually(check, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout

    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline, "activity monitor did not settle"
      :erlang.yield()
      eventually(check, deadline)
    end
  end
end
