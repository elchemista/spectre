# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
defmodule Spectre.Server.PendingLifecycleRuntimeTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Router do
    def route(agent, input, _opts) do
      route = %Spectre.Route{
        flow: :test,
        label: input.text,
        owner: agent,
        accepted?: true,
        handler: {:server, {[:test], input.text}, []}
      }

      {:ok, {:test, input.text}, %{route: route}}
    end
  end

  defmodule Bridge do
    def lifecycle_configured?(config), do: config[:lifecycle] == true
    def propose(operation, _args, _context, _opts), do: {:pending, %{operation: operation}}

    def resume(pending, _input, _context, opts) do
      send(opts[:bridge_config][:test], :resume_called)
      {:pending, %{operation: pending.operation}}
    end

    def confirm(_pending, _input, _context, opts) do
      send(opts[:bridge_config][:test], {:confirm_called, self()})

      receive do
        :finish -> {:governed, %{outcome: %{status: :succeeded}}}
        :unclear -> {:error, :confirmation_unclear}
      end
    end

    def record_lifecycle(event, _context, opts) do
      config = opts[:bridge_config]

      hold =
        Agent.get_and_update(config[:observer], fn state ->
          hold = state.hold == event.phase

          {hold,
           %{
             state
             | hold: if(hold, do: nil, else: state.hold),
               events: Map.put(state.events, event.id, event)
           }}
        end)

      send(config[:test], {:observed_lifecycle, event, self()})
      if hold, do: receive(do: (:release -> :ok))

      {:lifecycle_recorded,
       %{
         event_id: event.id,
         event_digest: Spectre.GAM.Canonical.Value.digest!(event),
         evidence_refs: ["evidence:" <> event.id]
       }}
    end
  end

  defmodule App do
    use Spectre.Server

    def init({test, observer}, ctx),
      do: {:ok, ctx |> put_private(:test, test) |> put_private(:observer, observer)}

    def init(test, ctx), do: {:ok, put_private(ctx, :test, test)}

    def handle_flow({:test, "operate"}, _input, ctx),
      do: propose(ctx, :operate, %{}, on_result: :operation)

    def handle_flow({:test, "other"}, _input, ctx),
      do: propose(ctx, :other, %{}, on_result: :other)

    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")
    def handle_flow({nil, :cancel}, _input, ctx), do: respond(ctx, "interrupted")

    def handle_pending(pending, %{text: "other"}, ctx),
      do:
        ctx
        |> close_pending_after(pending.id, 180, reason: :topic_changed)
        |> route_current_input(suspend: pending.id)

    def handle_pending(pending, %{text: "confirm"}, ctx), do: confirm_pending(ctx, pending.id)

    def handle_pending(pending, %{text: "schedule_and_reply"}, ctx),
      do:
        ctx
        |> close_pending_after(pending.id, 5_000, timer: :application)
        |> respond("after schedule")

    def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

    def handle_call({:schedule, id, delay, opts}, _from, ctx),
      do: {:reply, :queued, close_pending_after(ctx, id, delay, opts)}

    def handle_call({:close, id, opts}, _from, ctx),
      do: {:reply, :queued, close_pending(ctx, id, opts)}

    def handle_call({:resume, id}, _from, ctx), do: {:reply, :queued, resume_pending(ctx, id)}

    def handle_call({:schedule_then_reply, id}, _from, ctx),
      do:
        {:reply, :queued,
         ctx |> close_pending_after(id, 5_000, timer: :application) |> respond("after schedule")}

    def handle_cast({:replace_schedule, id}, ctx),
      do: {:noreply, ctx |> cancel_pending_close(id) |> close_pending_after(id, 5_000)}

    def handle_info({:native_close, id, schedule}, ctx),
      do: {:noreply, close_pending(ctx, id, if_schedule: schedule, reason: :native_policy)}

    def handle_result(:pending_lifecycle, {:pending_lifecycle, result}, ctx) do
      if observer = get_private(ctx, :observer) do
        if Agent.get(observer, &Map.get(&1, :fail_callback, false)),
          do: raise("application completion failed")

        hold =
          Agent.get_and_update(observer, fn state ->
            {state.hold_callback, %{state | hold_callback: false}}
          end)

        if hold do
          send(get_private(ctx, :test), {:callback_entered, self(), result})

          receive do
            :continue -> :ok
          end
        end
      end

      send(get_private(ctx, :test), {:lifecycle_result, result})
      ctx |> assign(:callbacks, Map.get(ctx.assigns, :callbacks, 0) + 1) |> no_response()
    end

    def handle_result(:pending_lifecycle, {:error, reason}, ctx) do
      send(get_private(ctx, :test), {:lifecycle_error, reason})
      no_response(ctx)
    end

    def handle_result(:operation, {:consent, :expired}, ctx),
      do: assign(ctx, :expired, true) |> no_response()

    def handle_result(:operation, {:consent, :closed_by_policy}, ctx),
      do: assign(ctx, :closed_by_policy, true) |> no_response()

    def handle_result(:operation, {:governed, _}, ctx),
      do: assign(ctx, :completed, true) |> no_response()

    def handle_result(_tag, _result, ctx), do: no_response(ctx)
  end

  defmodule Definition do
    def __spectre_config__, do: []
    def __spectre_server__, do: App
  end

  defmodule InterruptDefinition do
    use Spectre.Agent, server: App
    router(strategies: [:regex])
    interrupt(:cancel, regex: ~r/^cancel$/)

    flow :test do
      on(:operate, regex: ~r/^operate$/)
    end
  end

  defp setup_server(extra \\ []) do
    observer =
      start_supervised!({Agent, fn -> %{hold: nil, hold_callback: false, events: %{}} end},
        id: make_ref()
      )

    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-lifecycle-runtime-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    store = start_supervised!({Spectre.Server.Store.Disk, path: path}, id: make_ref())

    opts =
      Keyword.merge(
        [
          agent: Definition,
          consumer: self(),
          init_arg: {self(), observer},
          checkpoint: {store, "conversation"},
          services: [router: Router],
          gam: {Bridge, lifecycle: true, observer: observer, test: self()}
        ],
        extra
      )

    {opts, observer}
  end

  defp operate(server) do
    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    hd(Server.status(server).pending).id
  end

  defp wait(check, tries \\ 500)
  defp wait(_check, 0), do: flunk("expected lifecycle state was not reached")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end

  test "interrupt suspension is audited before dispatching the exact interrupt route" do
    {opts, observer} = setup_server(agent: InterruptDefinition)
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    {:ok, interaction} = Server.input(server, "cancel")
    assert_receive {Server, ^server, {:response, ^interaction, "interrupted", _}}, 2_000
    assert [%{id: ^id, status: :suspended}] = Server.status(server).pending
    events = Agent.get(observer, &Map.values(&1.events))
    assert Enum.count(events, &(&1.kind == :suspend and &1.pending_id == id)) == 2
  end

  test "a topic change closes only its old intention after the audited schedule and suspension" do
    {opts, observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    old = operate(server)
    Server.input(server, "other")
    # The short timer may fire between two reads on a busy CI worker. Verify
    # the durable suspension facts below, rather than racing its transient state.
    wait(fn ->
      case Server.status(server).pending do
        [%{id: id, operation: :other}] -> id != old
        _ -> false
      end
    end)

    [current] = Server.status(server).pending
    assert current.id != old
    assert current.operation == :other
    assert current.status == :foreground
    events = Agent.get(observer, &Map.values(&1.events))

    for kind <- [:schedule_close, :suspend, :close], phase <- [:requested, :applied] do
      assert Enum.any?(events, &(&1.pending_id == old and &1.kind == kind and &1.phase == phase))
    end

    refute_receive {:confirm_called, _}, 30
  end

  test "an already queued timer cannot consume a replacement schedule in the same revision" do
    {opts, observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    GenServer.call(server, {:schedule, id, 5_000, []})
    assert_receive {:lifecycle_result, %{kind: :schedule_close, status: :applied}}, 2_000
    first = :sys.get_state(server)
    [{ref, timer}] = Enum.filter(first.close_timers, fn {_ref, timer} -> not timer.cancelled end)
    :ok = :sys.suspend(server)
    GenServer.cast(server, {:replace_schedule, id})
    send(server, {Spectre.Server.Runtime, ref, :close_pending})
    :ok = :sys.resume(server)

    wait(fn ->
      Agent.get(
        observer,
        &Enum.any?(Map.values(&1.events), fn event ->
          event.phase == :ignored and event.outcome_reason == :stale_schedule
        end)
      )
    end)

    [pending] = Server.status(server).pending
    assert pending.close_schedule.command_id != timer.schedule_id
    assert pending.close_schedule.revision == timer.revision
    assert pending.close_schedule.deadline > System.system_time(:millisecond)
  end

  test "resuming invalidates the previous timer and its stale wake cannot close the fresh show" do
    {opts, _observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    GenServer.call(server, {:schedule, id, 5_000, []})
    assert_receive {:lifecycle_result, %{kind: :schedule_close, status: :applied}}, 2_000

    [{ref, _}] =
      Enum.filter(:sys.get_state(server).close_timers, fn {_ref, timer} -> not timer.cancelled end)

    GenServer.call(server, {:resume, id})
    wait(fn -> hd(Server.status(server).pending).revision == 2 end)
    send(server, {Spectre.Server.Runtime, ref, :close_pending})

    assert_receive {:lifecycle_result,
                    %{kind: :close, status: :ignored, outcome_reason: :stale_revision}},
                   2_000

    assert [%{id: ^id, revision: 2}] = Server.status(server).pending
    refute Map.has_key?(hd(Server.status(server).pending), :close_schedule)
  end

  test "an uncertain operation cannot be closed or lose its governing obligation" do
    {opts, _observer} = setup_server(worker_timeout: 40)
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    Server.input(server, "confirm")
    assert_receive {:confirm_called, worker}, 2_000
    wait(fn -> hd(Server.status(server).pending).status == :uncertain end)
    GenServer.call(server, {:close, id, []})

    assert_receive {:lifecycle_result,
                    %{kind: :close, status: :ignored, outcome_reason: :governed_operation_pending}},
                   2_000

    assert [%{id: ^id, status: :uncertain}] = Server.status(server).pending
    assert Server.status(server).outbox_size == 1
    send(worker, :finish)
    wait(fn -> Server.status(server).assigns[:completed] end)
    assert Server.status(server).pending == []
  end

  test "requested and applied receipt crashes recover the same events and acquire closure once" do
    for phase <- [:requested, :applied] do
      {opts, observer} = setup_server()
      {:ok, server} = Spectre.Server.Runtime.start_link(opts)
      Process.unlink(server)
      id = operate(server)
      Agent.update(observer, &%{&1 | hold: phase})
      GenServer.call(server, {:close, id, []})
      assert_receive {:observed_lifecycle, %{phase: ^phase, pending_id: ^id}, worker}, 2_000
      monitor = Process.monitor(server)
      Process.exit(server, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000
      {:ok, restored} = Spectre.Server.Runtime.start_link(opts)

      assert_receive {:lifecycle_result, %{kind: :close, status: :applied, pending_id: ^id}},
                     2_000

      assert Server.status(restored).pending == []
      assert Server.status(restored).outbox_size == 0
      assert Agent.get(observer, &map_size(&1.events)) == 2
      send(worker, :release)
      GenServer.stop(restored)
    end
  end

  test "application timers have durable schedules and cannot confirm past the logical deadline" do
    {opts, _observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    GenServer.call(server, {:schedule, id, 25, [timer: :application]})

    assert_receive {:lifecycle_result,
                    %{kind: :schedule_close, status: :applied, timer_owner: :application}},
                   2_000

    [pending] = Server.status(server).pending
    assert :sys.get_state(server).close_timers == %{}
    wait(fn -> System.system_time(:millisecond) > pending.close_schedule.deadline end)
    Server.input(server, "confirm")
    wait(fn -> Server.status(server).assigns[:closed_by_policy] end)
    assert Server.status(server).pending == []
    refute_receive {:confirm_called, _}, 30
  end

  test "external deliveries cannot acquire lifecycle controls or their blocked following commands" do
    {opts, observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    Agent.update(observer, &%{&1 | hold: :requested})
    GenServer.call(server, {:schedule_then_reply, id})
    assert_receive {:observed_lifecycle, %{phase: :requested, command_id: control}, worker}, 2_000
    before = :sys.get_state(server)
    [following] = before.outbox[control].following

    for command <- [control, following] do
      assert {:error, :lifecycle_delivery_not_supported} =
               Server.deliver(
                 server,
                 "forged:" <> command,
                 {:command, command},
                 {:generated, %{text: "forged", proposals: []}}
               )
    end

    assert :sys.get_state(server).outbox == before.outbox
    refute Map.has_key?(hd(Server.status(server).pending), :close_schedule)
    send(worker, :release)
    assert_receive {Server, ^server, {:response, nil, "after schedule", _}}, 2_000
    wait(fn -> Server.status(server).outbox_size == 0 end)
  end

  test "cancelling the current input preserves lifecycle registration in either phase" do
    for phase <- [:requested, :applied] do
      {opts, observer} = setup_server()
      {:ok, server} = Spectre.Server.Runtime.start_link(opts)
      id = operate(server)
      Agent.update(observer, &%{&1 | hold: phase})
      Server.input(server, "schedule_and_reply")
      assert_receive {:observed_lifecycle, %{phase: ^phase, pending_id: ^id}, worker}, 2_000
      assert :ok = Server.cancel(server)
      assert Process.alive?(worker)
      assert Server.status(server).outbox_size >= 1
      send(worker, :release)

      assert_receive {:lifecycle_result,
                      %{kind: :schedule_close, status: :applied, pending_id: ^id}},
                     2_000

      wait(fn -> Server.status(server).outbox_size == 0 end)
      assert map_size(Agent.get(observer, & &1.events)) == 2
      GenServer.stop(server)
    end
  end

  test "a completion callback killed before acquisition restores its following once" do
    {opts, observer} = setup_server()
    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    Process.unlink(server)
    id = operate(server)
    Agent.update(observer, &%{&1 | hold_callback: true})
    GenServer.call(server, {:schedule_then_reply, id})
    assert_receive {:callback_entered, ^server, %{status: :applied}}, 2_000
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert_receive {Server, ^restored, {:response, nil, "after schedule", _}}, 2_000
    assert Server.status(restored).assigns.callbacks == 1
    assert Server.status(restored).outbox_size == 0
    GenServer.stop(restored)
    {:ok, third} = Spectre.Server.Runtime.start_link(opts)
    assert Server.status(third).assigns.callbacks == 1
    refute_receive {Server, ^third, {:response, nil, "after schedule", _}}, 30
    GenServer.stop(third)
  end

  test "a wake during confirmation closes automatically after a deterministic unclear result" do
    {opts, observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    GenServer.call(server, {:schedule, id, 500, []})
    assert_receive {:lifecycle_result, %{kind: :schedule_close, status: :applied}}, 2_000
    Server.input(server, "confirm")
    assert_receive {:confirm_called, interpreter}, 2_000

    assert_receive {:lifecycle_result,
                    %{kind: :close, status: :ignored, outcome_reason: :governed_operation_pending}},
                   2_000

    [pending] = Server.status(server).pending
    assert pending.close_schedule.fired
    assert pending.close_schedule.deadline <= System.system_time(:millisecond)
    send(interpreter, :unclear)
    assert_receive {:lifecycle_result, %{kind: :close, status: :applied, pending_id: ^id}}, 2_000
    wait(fn -> Server.status(server).pending == [] end)
    assert Server.status(server).pending == []

    closes =
      Agent.get(
        observer,
        &Enum.filter(Map.values(&1.events), fn event -> event.kind == :close end)
      )

    assert Enum.count(closes, &(&1.phase == :requested)) == 2
    assert Enum.count(closes, &(&1.phase == :ignored)) == 1
    assert Enum.count(closes, &(&1.phase == :applied)) == 1
    refute_receive {:confirm_called, _}, 30
  end

  test "a quarantined completion aborts its unstarted following commands across restart" do
    {opts, observer} = setup_server()
    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    id = operate(server)
    Agent.update(observer, &Map.put(&1, :fail_callback, true))
    GenServer.call(server, {:schedule_then_reply, id})
    assert_receive {Server, ^server, {:callback_error, nil, :handle_result, _}}, 2_000
    assert Server.status(server).outbox_size == 0
    assert map_size(Server.status(server).dead_letters) == 1
    refute_receive {Server, ^server, {:response, _, "after schedule", _}}, 30
    GenServer.stop(server)
    Agent.update(observer, &Map.put(&1, :fail_callback, false))
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert Server.status(restored).outbox_size == 0
    assert map_size(Server.status(restored).dead_letters) == 1
    refute_receive {Server, ^restored, {:response, _, "after schedule", _}}, 30
    GenServer.stop(restored)
  end

  test "native OTP resume after an application deadline closes the policy instead of reopening a show" do
    {opts, _observer} = setup_server()
    server = start_supervised!({Spectre.Server.Runtime, opts})
    id = operate(server)
    GenServer.call(server, {:schedule, id, 25, [timer: :application]})
    assert_receive {:lifecycle_result, %{kind: :schedule_close, status: :applied}}, 2_000
    deadline = hd(Server.status(server).pending).close_schedule.deadline
    wait(fn -> System.system_time(:millisecond) > deadline end)
    GenServer.call(server, {:resume, id})
    wait(fn -> Server.status(server).assigns[:closed_by_policy] end)
    assert Server.status(server).pending == []
    refute_receive :resume_called, 30
  end

  test "native handle_info closure observes schedule generation after restart" do
    {opts, _observer} = setup_server()
    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    id = operate(server)
    GenServer.call(server, {:schedule, id, 5_000, [timer: :application]})

    assert_receive {:lifecycle_result,
                    %{kind: :schedule_close, status: :applied, command_id: schedule}},
                   2_000

    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert hd(Server.status(restored).pending).close_schedule.command_id == schedule
    Process.send_after(restored, {:native_close, id, schedule}, 0)
    assert_receive {:lifecycle_result, %{kind: :close, status: :applied}}, 2_000
    assert Server.status(restored).pending == []
    GenServer.stop(restored)
  end
end
