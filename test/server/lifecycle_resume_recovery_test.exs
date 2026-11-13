defmodule Spectre.Server.LifecycleResumeRecoveryTest do
  use ExUnit.Case, async: true
  alias Spectre.Server
  alias Spectre.GAM.Canonical.Value

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
    def lifecycle_configured?(opts), do: opts[:lifecycle] == true
    def propose(operation, _args, _context, _opts), do: {:pending, %{operation: operation}}
    def resume(pending, _input, context, opts), do: show(:resume, pending, context, opts)
    def explain(pending, _input, context, opts), do: show(:explain, pending, context, opts)

    defp show(kind, pending, context, opts) do
      config = opts[:bridge_config]

      Agent.update(
        config[:observer],
        &Map.update!(&1, :shows, fn calls -> [{kind, context.command_id} | calls] end)
      )

      send(config[:test], {:show_called, kind, context.command_id})

      if Agent.get(config[:observer], &Map.get(&1, :hold_show, false)) do
        send(config[:test], {:show_held, self()})

        receive do
          :return_error -> {:error, :presentation_failed}
        end
      else
        {:pending, %{operation: pending.operation}}
      end
    end

    def recover_command(id, _context, opts) do
      send(opts[:bridge_config][:test], {:unexpected_recovery, id})
      {:error, :journal_missing}
    end

    def record_lifecycle(event, _context, opts) do
      config = opts[:bridge_config]

      hold =
        Agent.get_and_update(config[:observer], fn state ->
          hold = state.hold == {event.kind, event.phase}
          calls = Map.update(state.calls, {event.kind, event.phase}, 1, &(&1 + 1))

          {hold,
           %{
             state
             | hold: if(hold, do: nil, else: state.hold),
               calls: calls,
               events: Map.put(state.events, event.id, event)
           }}
        end)

      send(config[:test], {:lifecycle_called, event, self()})
      if hold, do: receive(do: (:release -> :ok))

      {:lifecycle_recorded,
       %{
         event_id: event.id,
         event_digest: Value.digest!(event),
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

    def handle_flow({:test, "reply"}, _input, ctx),
      do: await_reply(ctx, "reply", timeout: :infinity)

    def handle_flow({:test, "other"}, _input, ctx), do: respond(ctx, "other")
    def handle_flow({:test, "scheduled_other"}, _input, ctx), do: respond(ctx, "other")

    def handle_pending(pending, %{text: "other"}, ctx),
      do: route_current_input(ctx, suspend: pending.id)

    def handle_pending(pending, %{text: "scheduled_other"}, ctx),
      do:
        ctx
        |> close_pending_after(pending.id, 5_000, timer: :application)
        |> route_current_input(suspend: pending.id)

    def handle_pending(pending, %{text: "explain"}, ctx), do: explain_pending(ctx, pending.id)
    def handle_call({:resume, id}, _from, ctx), do: {:reply, :queued, resume_pending(ctx, id)}

    def handle_call({:schedule, id, delay}, _from, ctx),
      do: {:reply, :queued, close_pending_after(ctx, id, delay, timer: :application)}

    def handle_call({:schedule, id, delay, owner}, _from, ctx),
      do: {:reply, :queued, close_pending_after(ctx, id, delay, timer: owner)}

    def handle_call({:arm_application_close, id}, _from, ctx) do
      schedule = get_pending(ctx, id).close_schedule

      ref =
        Process.send_after(
          self(),
          {:close_deadline, id, schedule.command_id},
          max(0, schedule.deadline - System.system_time(:millisecond))
        )

      {:reply, :armed, put_private(ctx, :timer, ref)}
    end

    def handle_info({:close_deadline, id, schedule}, ctx),
      do: {:noreply, close_pending(ctx, id, if_schedule: schedule)}

    def handle_result(:pending_lifecycle, {:pending_lifecycle, result}, ctx) do
      if result.status == :ignored and
           Agent.get(get_private(ctx, :observer), &Map.get(&1, :poison_ignored, false)),
         do: raise("ignored completion failed")

      send(get_private(ctx, :test), {:lifecycle_completed, result.kind, result.pending_id})
      no_response(ctx)
    end

    def handle_result(:operation, {:consent, :closed_by_policy}, ctx),
      do: ctx |> assign(:closed, true) |> no_response()

    def handle_result(_tag, _result, ctx), do: no_response(ctx)
  end

  defmodule Definition do
    def __spectre_config__, do: []
    def __spectre_server__, do: App
  end

  defmodule Gate do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, %{store: opts[:store], test: opts[:test], mode: nil, blocked: nil}}
    def handle_call({:arm, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

    def handle_call(:release, _from, state) do
      if state.blocked, do: GenServer.reply(elem(state.blocked, 0), elem(state.blocked, 1))
      {:reply, :ok, %{state | blocked: nil}}
    end

    def handle_call(message, from, state) do
      result = GenServer.call(state.store, message, :infinity)

      if intercept?(message, state.mode) do
        send(state.test, {:checkpoint_acquired, state.mode})
        {:noreply, %{state | mode: nil, blocked: {from, result}}}
      else
        {:reply, result, state}
      end
    end

    defp intercept?({:cas, _key, _revision, binary}, mode) when not is_nil(mode) do
      {:ok, projection} =
        Value.decode(binary,
          allowed_structs: [
            Spectre.Input,
            Spectre.Input.Source,
            Spectre.Server.Command,
            Spectre.Route,
            Spectre.Rule,
            Spectre.Flow.Constraint
          ]
        )

      match_projection?(projection, mode)
    end

    defp intercept?(_message, _mode), do: false

    defp match_projection?(projection, :released) do
      Enum.any?(projection.outbox, fn {_id, entry} ->
        entry.command.kind in [:resume_pending, :explain_pending] and
          Map.get(entry, :lifecycle_authorized, false) and not Map.has_key?(entry, :blocked_by) and
          Map.get(entry, :execution_started) == false
      end)
    end

    defp match_projection?(projection, :schedule_completion) do
      Enum.any?(projection.inbox, fn {_id, entry} ->
        match?(
          %{
            worker: %{kind: :lifecycle_completion},
            result: {:pending_lifecycle, %{kind: :schedule_close}}
          },
          entry
        )
      end)
    end
  end

  defp setup_runtime do
    observer =
      start_supervised!({Agent, fn -> %{hold: nil, shows: [], calls: %{}, events: %{}} end})

    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-resume-recovery-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    disk = start_supervised!({Spectre.Server.Store.Disk, path: path})
    gate = start_supervised!({Gate, store: disk, test: self()})

    opts = [
      agent: Definition,
      consumer: self(),
      init_arg: {self(), observer},
      checkpoint: {gate, "agent"},
      services: [router: Router],
      gam: {Bridge, lifecycle: true, test: self(), observer: observer}
    ]

    {opts, observer, gate}
  end

  defp open(server, input \\ "operate") do
    Server.input(server, input)
    wait(fn -> Server.status(server).pending != [] end)
    hd(Server.status(server).pending).id
  end

  defp crash(server) do
    Process.unlink(server)
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000
  end

  defp request_show(server, :resume, id), do: GenServer.call(server, {:resume, id})
  defp request_show(server, :explain, _id), do: Server.input(server, "explain")

  defp arm_application_close(server, :application, id),
    do: GenServer.call(server, {:arm_application_close, id})

  defp arm_application_close(_server, :runtime, _id), do: :ok

  defp wait(check, tries \\ 500)
  defp wait(_check, 0), do: flunk("recovery did not reach the expected state")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end

  test "a crash during requested resume retries the lifecycle without inventing an in-flight effect" do
    {opts, observer, _gate} = setup_runtime()
    {:ok, server} = Server.start_link(opts)
    id = open(server)
    Server.input(server, "other")
    assert_receive {Server, ^server, {:response, _, "other", _}}, 2_000
    Agent.update(observer, &%{&1 | hold: {:resume, :requested}})
    GenServer.call(server, {:resume, id})
    assert_receive {:lifecycle_called, %{kind: :resume, phase: :requested}, held}, 2_000
    crash(server)
    {:ok, restored} = Server.start_link(opts)
    assert_receive {:show_called, :resume, _}, 2_000
    wait(fn -> hd(Server.status(restored).pending).revision == 2 end)
    assert [%{id: ^id, status: :foreground}] = Server.status(restored).pending
    assert length(Agent.get(observer, & &1.shows)) == 1
    refute_receive {:unexpected_recovery, _}, 30
    send(held, :release)
    GenServer.stop(restored)
  end

  for kind <- [:resume, :explain] do
    test "a released but unstarted #{kind} executes once after restart" do
      kind = unquote(kind)
      {opts, observer, gate} = setup_runtime()
      {:ok, server} = Server.start_link(opts)
      id = open(server)
      assert :ok = GenServer.call(gate, {:arm, :released})

      request_show(server, kind, id)

      assert_receive {:checkpoint_acquired, :released}, 2_000
      assert Agent.get(observer, & &1.shows) == []
      crash(server)
      GenServer.call(gate, :release)
      {:ok, restored} = Server.start_link(opts)
      assert_receive {:show_called, ^kind, _}, 2_000
      wait(fn -> hd(Server.status(restored).pending).revision == 2 end)
      assert [%{id: ^id, status: :foreground}] = Server.status(restored).pending
      assert length(Agent.get(observer, & &1.shows)) == 1
      refute_receive {:unexpected_recovery, _}, 30
      GenServer.stop(restored)
    end
  end

  test "an unstarted resume whose application deadline passes while stopped closes without a show" do
    {opts, observer, gate} = setup_runtime()
    {:ok, server} = Server.start_link(opts)
    id = open(server)
    GenServer.call(server, {:schedule, id, 1_000})
    assert_receive {:lifecycle_completed, :schedule_close, ^id}, 2_000
    deadline = hd(Server.status(server).pending).close_schedule.deadline
    GenServer.call(gate, {:arm, :released})
    GenServer.call(server, {:resume, id})
    assert_receive {:checkpoint_acquired, :released}, 2_000
    crash(server)
    GenServer.call(gate, :release)
    wait(fn -> System.system_time(:millisecond) > deadline end)
    {:ok, restored} = Server.start_link(opts)
    wait(fn -> Server.status(restored).assigns[:closed] end)
    assert Server.status(restored).pending == []
    assert Agent.get(observer, & &1.shows) == []

    assert Agent.get(
             observer,
             &Enum.any?(Map.values(&1.events), fn event ->
               event.kind == :close and event.phase == :applied and
                 event.reason == :deadline_elapsed
             end)
           )

    refute_receive {:unexpected_recovery, _}, 30
    GenServer.stop(restored)
  end

  test "a released reply resume remains local after restart" do
    {opts, observer, gate} = setup_runtime()
    {:ok, server} = Server.start_link(opts)
    id = open(server, "reply")
    GenServer.call(gate, {:arm, :released})
    GenServer.call(server, {:resume, id})
    assert_receive {:checkpoint_acquired, :released}, 2_000
    crash(server)
    GenServer.call(gate, :release)
    {:ok, restored} = Server.start_link(opts)
    wait(fn -> hd(Server.status(restored).pending).status == :foreground end)
    assert [%{id: ^id, kind: :reply, status: :foreground}] = Server.status(restored).pending
    assert Agent.get(observer, & &1.shows) == []
    refute_receive {:unexpected_recovery, _}, 30
    assert Server.status(restored).outbox_size == 1
    GenServer.stop(restored)
  end

  for owner <- [:runtime, :application] do
    test "a deferred #{owner} close completes once when the in-flight show fails after its wake" do
      owner = unquote(owner)
      {opts, observer, _gate} = setup_runtime()
      {:ok, server} = Server.start_link(opts)
      id = open(server)
      GenServer.call(server, {:schedule, id, 1_000, owner})
      assert_receive {:lifecycle_completed, :schedule_close, ^id}, 2_000
      arm_application_close(server, owner, id)

      Agent.update(
        observer,
        &(&1 |> Map.put(:hold_show, true) |> Map.put(:hold, {:close, :ignored}))
      )

      GenServer.call(server, {:resume, id})
      assert_receive {:show_held, builder}, 2_000
      assert_receive {:lifecycle_called, %{kind: :close, phase: :ignored}, report}, 2_000
      wait(fn -> get_in(hd(Server.status(server).pending), [:close_schedule, :fired]) == true end)
      assert hd(Server.status(server).pending).status == :resolving
      send(builder, :return_error)
      wait(fn -> hd(Server.status(server).pending).status != :resolving end)
      assert Agent.get(observer, &Map.get(&1.calls, {:close, :requested}, 0)) == 1
      send(report, :release)
      wait(fn -> Server.status(server).pending == [] end)
      wait(fn -> Server.status(server).outbox_size == 0 end)

      closes =
        Agent.get(
          observer,
          &Enum.filter(Map.values(&1.events), fn event -> event.kind == :close end)
        )

      assert Enum.count(closes, &(&1.phase == :ignored)) == 1
      assert Enum.count(closes, &(&1.phase == :applied)) == 1
      assert Enum.count(closes, &(&1.phase == :requested)) == 2
      assert :sys.get_state(server).close_timers == %{}
      GenServer.stop(server)
    end
  end

  test "a quarantined ignored callback preserves and drains its independent expired close" do
    {opts, observer, _gate} = setup_runtime()
    {:ok, server} = Server.start_link(opts)
    id = open(server)
    GenServer.call(server, {:schedule, id, 1_000, :application})
    assert_receive {:lifecycle_completed, :schedule_close, ^id}, 2_000
    arm_application_close(server, :application, id)

    Agent.update(
      observer,
      &(&1
        |> Map.put(:hold_show, true)
        |> Map.put(:hold, {:close, :ignored})
        |> Map.put(:poison_ignored, true))
    )

    GenServer.call(server, {:resume, id})
    assert_receive {:show_held, builder}, 2_000
    assert_receive {:lifecycle_called, %{kind: :close, phase: :ignored}, report}, 2_000
    send(builder, :return_error)
    wait(fn -> hd(Server.status(server).pending).status != :resolving end)
    send(report, :release)
    assert_receive {Server, ^server, {:callback_error, nil, :handle_result, _}}, 2_000
    wait(fn -> Server.status(server).pending == [] end)
    wait(fn -> Server.status(server).outbox_size == 0 end)
    assert map_size(Server.status(server).dead_letters) == 1

    assert Agent.get(
             observer,
             &Enum.count(Map.values(&1.events), fn event ->
               event.kind == :close and event.phase == :applied
             end)
           ) == 1

    assert Process.alive?(server)
    GenServer.stop(server)
  end

  test "inbox replay starts exactly one delayed worker for the following lifecycle" do
    {opts, observer, gate} = setup_runtime()
    {:ok, server} = Server.start_link(opts)
    id = open(server)
    GenServer.call(gate, {:arm, :schedule_completion})
    Server.input(server, "scheduled_other")
    assert_receive {:checkpoint_acquired, :schedule_completion}, 2_000
    crash(server)
    GenServer.call(gate, :release)
    Agent.update(observer, &%{&1 | hold: {:suspend, :requested}})
    {:ok, restored} = Server.start_link(opts)
    assert_receive {:lifecycle_called, %{kind: :suspend, phase: :requested}, held}, 2_000
    wait(fn -> Server.status(restored).workers == 1 end)
    assert Agent.get(observer, &Map.get(&1.calls, {:suspend, :requested}, 0)) == 1
    refute_receive {Server, ^restored, {:response, _, "other", _}}, 30
    send(held, :release)
    assert_receive {Server, ^restored, {:response, _, "other", _}}, 2_000
    assert [%{id: ^id, status: :suspended}] = Server.status(restored).pending
    assert Agent.get(observer, &Map.get(&1.calls, {:suspend, :requested}, 0)) == 1
    refute_receive {Server, ^restored, {:pending_lifecycle_error, _, _}}, 30
    GenServer.stop(restored)
  end
end
