defmodule Spectre.Server.ManagedResetTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.GAM.Managed.Gate

  defmodule BlockingStore do
    def fetch(_, _), do: :not_found

    def list(observer, _, _) do
      send(observer, {:approval_io_started, self()})

      receive do
        :release -> {:ok, [], nil}
      end
    end
  end

  defmodule BlockingBootstrapStore do
    def fetch(observer, _) do
      send(observer, {:bootstrap_store_started, self()})
      receive do: (:release -> :not_found)
    end

    def put_new(_, _, _), do: {:error, :unused}
    def compare_and_swap(_, _, _, _), do: {:error, :unused}
    def delete(_, _, _), do: {:error, :unused}
  end

  defp start_managed(extra \\ []) do
    opts = [
      runtime: self(),
      consumer: self(),
      agent: __MODULE__,
      identity: %{subject: "reset-#{System.unique_integer([:positive])}"},
      operations: %{}
    ]

    spec = Supervisor.child_spec({Managed, Keyword.merge(opts, extra)}, restart: :temporary)
    start_supervised!(spec)
  end

  defp runtime_loop do
    receive do
      {:invoke, from, operation} ->
        send(from, {:runtime_result, operation.()})
        runtime_loop()
    end
  end

  defp invoke_runtime(runtime, operation) do
    send(runtime, {:invoke, self(), operation})
    assert_receive {:runtime_result, result}
    result
  end

  test "only the owning Runtime may reserve, resume, or adopt a reset" do
    runtime = spawn(fn -> runtime_loop() end)
    on_exit(fn -> Process.exit(runtime, :kill) end)
    managed = start_managed(runtime: runtime)
    session = :sys.get_state(managed).session

    for operation <- [
          fn -> Managed.session(managed) end,
          fn -> Managed.prepare_reset(managed) end,
          fn -> Managed.resume_reset(managed) end,
          fn -> Managed.adopt_reset(managed, session) end
        ] do
      assert {:error, :untrusted_reset_transport} = operation.()
    end

    assert ^session = invoke_runtime(runtime, fn -> Managed.session(managed) end)
    assert {:ok, _} = invoke_runtime(runtime, fn -> Managed.prepare_reset(managed) end)
    assert :ok = invoke_runtime(runtime, fn -> Managed.resume_reset(managed) end)
  end

  test "a reset task needs the owning Runtime's exact control proof" do
    control = make_ref()
    managed = start_managed(runtime_control: control)

    assert {:error, :untrusted_reset_transport} =
             Task.async(fn -> Managed.prepare_reset(managed, make_ref()) end) |> Task.await()

    assert {:ok, _} =
             Task.async(fn -> Managed.prepare_reset(managed, control) end) |> Task.await()

    assert {:error, :untrusted_reset_transport} =
             Task.async(fn -> Managed.resume_reset(managed) end) |> Task.await()

    assert :ok = Task.async(fn -> Managed.resume_reset(managed, control) end) |> Task.await()
  end

  test "an active bridge worker refuses reset without reserving its Gate" do
    managed = start_managed()
    {:ok, snapshot} = GenServer.call(managed, :checkout)

    assert {:error, :reset_busy} = Managed.prepare_reset(managed)
    assert is_nil(:sys.get_state(snapshot.gate).reset_token)
    GenServer.cast(managed, {:checkin, self()})

    assert {:ok, %{session: session, domain: domain}} = Managed.prepare_reset(managed)
    assert session.domain == domain
    assert :ok = Managed.resume_reset(managed)
  end

  test "a reservation blocks new checkouts and consent operations until resumed" do
    managed = start_managed()
    gate = :sys.get_state(managed).gate
    material = %{"presentation_ref" => "pending-before-reset"}
    assert :ok = Gate.show(gate, material, self())

    assert {:ok, _} = Managed.prepare_reset(managed)
    assert {:error, :reset_busy} = GenServer.call(managed, :checkout)
    assert {:error, :reset_busy} = Gate.presented(gate, material["presentation_ref"], self())
    assert {:error, :reset_busy} = Gate.show(gate, %{"presentation_ref" => "new"}, self())
    assert {:error, :reset_busy} = Gate.receive_message(gate, %{})
    assert Map.has_key?(:sys.get_state(gate).shows, material["presentation_ref"])

    assert :ok = Managed.resume_reset(managed)
    assert :ok = Gate.presented(gate, material["presentation_ref"], self())
    assert {:ok, _} = GenServer.call(managed, :checkout)
    GenServer.cast(managed, {:checkin, self()})
  end

  test "a failed authoritative preflight releases its reservation without removing consent" do
    managed = start_managed()
    %{scope: scope, gate: gate, session: session} = :sys.get_state(managed)
    material = %{"presentation_ref" => "retained-on-read-failure"}
    assert :ok = Gate.show(gate, material, self())
    shows = :sys.get_state(gate).shows

    unavailable =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :unresolved_duties} -> GenServer.reply(from, {:error, :offline})
        end
      end)

    :sys.replace_state(managed, fn state ->
      %{state | scope: %{scope | domain: %{scope.domain | server: unavailable}}}
    end)

    assert {:error, {:gam_storage_unavailable, _}} = Managed.prepare_reset(managed)
    assert is_nil(:sys.get_state(gate).reset_token)
    assert :sys.get_state(gate).shows == shows
    assert :sys.get_state(managed).session == session
    :sys.replace_state(managed, &%{&1 | scope: scope})

    assert {:ok, _} = Managed.prepare_reset(managed)
    assert :ok = Managed.resume_reset(managed)
  end

  test "storage recovery waits for a failed reset to release its reservation" do
    managed = start_managed()
    before = :sys.get_state(managed)
    assert {:ok, _} = Managed.prepare_reset(managed)
    assert :ok = Managed.recover_storage(managed, :memory)

    reserved = :sys.get_state(managed)
    assert reserved.domain == before.domain
    assert reserved.reset_storage_recovery == {:memory, 0}
    refute Map.has_key?(reserved, :storage_recovery)
    assert :ok = Managed.resume_reset(managed)

    assert_receive {Spectre.Server.Runtime, _, :gam_storage_recovered, recovered}, 5_000
    assert recovered.previous_domain == before.refs.domain
    assert recovered.domain != before.refs.domain
    refute Map.has_key?(:sys.get_state(managed), :reset_storage_recovery)
  end

  test "an active approval Store operation refuses reset and stays in flight" do
    managed = start_managed()
    gate = :sys.get_state(managed).gate
    observer = self()

    :sys.replace_state(gate, fn state ->
      Map.merge(state, %{
        approvals: %{address: "reset-inbox", io_workers: 1, io_timeout: 5_000},
        store: {BlockingStore, observer}
      })
    end)

    tag = make_ref()
    assert :ok = Gate.io(gate, {:list, []}, {self(), tag})
    assert_receive {:approval_io_started, worker}
    assert {:error, :reset_busy} = Managed.prepare_reset(managed)
    assert Process.alive?(worker)
    assert is_nil(:sys.get_state(gate).reset_token)

    send(worker, :release)
    assert_receive {^tag, {:ok, %{entries: []}}}
    assert {:ok, _} = Managed.prepare_reset(managed)
    assert :ok = Managed.resume_reset(managed)
  end

  test "a staging owner exiting closes an unadopted Managed integration" do
    staging_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    managed = start_managed(bootstrap_owner: staging_owner)
    monitor = Process.monitor(managed)
    send(staging_owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^managed, :normal}
  end

  test "a cancelled staging task cannot leave a Managed process blocked during bootstrap" do
    observer = self()

    task =
      Task.async(fn ->
        Managed.start_link(
          runtime: observer,
          bootstrap_owner: self(),
          consumer: observer,
          agent: __MODULE__,
          identity: %{subject: "blocked-reset-#{System.unique_integer([:positive])}"},
          operations: %{},
          storage: :ledger,
          store: {BlockingBootstrapStore, observer}
        )
      end)

    assert_receive {:bootstrap_store_started, managed}
    monitor = Process.monitor(managed)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^managed, :killed}
  end

  test "adoption installs the activated session and detaches the staging owner" do
    staging_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    managed = start_managed(bootstrap_owner: staging_owner)
    session = :sys.get_state(managed).session
    activated = %{session | revision: 7}

    assert :ok = Managed.adopt_reset(managed, activated)
    send(staging_owner, :stop)
    assert {:ok, %{session: ^activated}} = Managed.prepare_reset(managed)
    assert :ok = Managed.resume_reset(managed)
  end
end
