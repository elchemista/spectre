defmodule Spectre.Server.ResetTest do
  use ExUnit.Case, async: false

  alias Spectre.Server
  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.Runtime
  alias Spectre.Server.Skills
  alias Spectre.Test.Processes, as: TestProcesses

  defmodule Service do
    def generate(%{prompt: :hold}, context, _) do
      send(Spectre.Server.ResetTest, {:service_started, self(), context.session})
      receive do: (:release -> {:generated, %{text: "retired service result", proposals: []}})
    end
  end

  defmodule App do
    use Spectre.Server

    def init(arg, ctx) do
      send(Spectre.Server.ResetTest, {:initialized, self(), arg, ctx.assigns, ctx.private})
      {:ok, assign(ctx, :init_arg, arg)}
    end

    def handle_flow(:unmatched, %{text: "hold"}, ctx),
      do: generate(ctx, :hold, on_result: :held)

    def handle_flow(:unmatched, %{text: "wait"}, ctx) do
      send(Spectre.Server.ResetTest, {:awaiting_reply, self()})
      await_reply(ctx, "reply", on_result: :replied, timeout: :infinity)
    end

    def handle_flow(:unmatched, %{text: "run " <> mode}, ctx),
      do: propose(ctx, :run, %{mode: mode}, on_result: :ran)

    def handle_flow(:unmatched, input, ctx),
      do: ctx |> assign(:last_input, input.text) |> respond(input.text)

    def handle_call(:mutate, _from, ctx) do
      ctx = ctx |> assign(:runtime_only, true) |> put_private(:runtime_ref, make_ref())
      {:reply, :ok, ctx}
    end

    def handle_call(:snapshot, _from, ctx),
      do: {:reply, %{assigns: ctx.assigns, private: ctx.private, pending: ctx.pending_by_id}, ctx}

    def handle_call(request, from, ctx), do: super(request, from, ctx)

    def handle_result(:external, result, ctx) do
      send(Spectre.Server.ResetTest, {:external_result, self(), result})
      no_response(ctx)
    end

    def handle_result(:ran, result, ctx) do
      send(Spectre.Server.ResetTest, {:governed_result, self(), result})
      no_response(ctx)
    end

    def handle_result(:replied, result, ctx) do
      send(Spectre.Server.ResetTest, {:reply_result, self(), result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_info(message, ctx) do
      send(Spectre.Server.ResetTest, {:application_info, self(), message})
      {:noreply, ctx}
    end

    def terminate(reason, ctx) do
      if observer = Process.whereis(Spectre.Server.ResetTest),
        do: send(observer, {:terminated, self(), reason, ctx.assigns, ctx.private})

      :ok
    end
  end

  defmodule Agent do
    use Spectre.Agent, server: App
  end

  defmodule EchoSkill do
    use Spectre.Skill, id: :echo, server: App
  end

  defmodule SkilledAgent do
    use Spectre.Agent, server: App
    skill(EchoSkill, as: :echo)
  end

  defmodule Effect do
    def execute_effect(:run, %{mode: "hold"}, _) do
      send(Spectre.Server.ResetTest, {:effect_started, self()})

      receive do
        :release -> {:ok, %{completed: true}}
      end
    end

    def execute_effect(:run, args, _) do
      send(Spectre.Server.ResetTest, {:effect_executed, args})
      {:ok, %{completed: true}}
    end
  end

  defmodule Effects do
    use Spectre.Stack.Installable, id: :reset_effect, version: "0.1.0", spectre: "~> 0.4.0"

    def effects(_),
      do: %{
        run: %{
          contract: 1,
          adapter: Effect,
          operation: :run,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [],
          schema_hash: nil,
          config: %{}
        }
      }
  end

  defmodule Stack do
    use Spectre.Stack
    install(Effects)
  end

  defmodule GovernedAgent do
    use Spectre.Agent, server: App, stack: Stack
  end

  defmodule ControlledStore do
    @behaviour Spectre.Server.Store

    def fetch(ref, key) do
      case Elixir.Agent.get(ref.control, & &1) do
        :online ->
          Managed.Store.fetch(ref.journal, key)

        {:reply_lost, _observer} ->
          Managed.Store.fetch(ref.journal, key)

        :offline ->
          {:error, :offline}

        {:block, observer} ->
          send(observer, {:store_blocked, self(), key})
          receive do: (:release -> Managed.Store.fetch(ref.journal, key))
      end
    end

    def put_new(ref, key, value),
      do: mutation_result(ref, key, Managed.Store.put_new(ref.journal, key, value))

    def compare_and_swap(ref, key, revision, value),
      do:
        mutation_result(
          ref,
          key,
          Managed.Store.compare_and_swap(ref.journal, key, revision, value)
        )

    def delete(ref, key, revision), do: Managed.Store.delete(ref.journal, key, revision)
    def gam_ledger(ref), do: {:ok, {Spectre.GAM.Ledger.Store.ETS, server: ref.ledger}}

    defp mutation_result(ref, {:spectre_server_session, _} = key, {:ok, _} = acquired) do
      case Elixir.Agent.get(ref.control, & &1) do
        {:reply_lost, observer} ->
          send(observer, {:session_pointer_acquired, key})
          {:error, :reply_lost}

        _ ->
          acquired
      end
    end

    defp mutation_result(_ref, _key, result), do: result
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  test "reset keeps the supervised root and initializes fresh context while retiring queued work" do
    server = start_server()
    assert_receive {:initialized, ^server, :startup, %{initial: true}, %{}}
    assert :ok = GenServer.call(server, :mutate)
    assert {:ok, old_interaction} = Server.input(server, "old conversation")
    assert_receive {Server, ^server, {:response, ^old_interaction, "old conversation", _}}, 5_000
    assert {:ok, held} = Server.input(server, "hold")
    assert_receive {:service_started, worker, old_session}, 5_000
    on_exit(fn -> send(worker, :release) end)
    monitor = Process.monitor(worker)
    assert {:ok, queued} = Server.input(server, "queued old work")
    before = :sys.get_state(server)
    assert before.history != []
    assert :queue.len(before.queue) == 1
    [{worker_ref, _}] = Map.to_list(before.workers)

    assert :ok = Server.reset(server)
    assert_receive {:terminated, ^server, :reset, %{runtime_only: true}, %{runtime_ref: _}}, 5_000
    assert_receive {:initialized, ^server, :startup, %{initial: true}, %{}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_receive {Server, ^server, {:reset, reset}}, 5_000
    assert reset.session != old_session
    assert reset.domain != reset.previous_domain
    assert Process.alive?(server)

    status = Server.status(server)
    assert status.session == reset.session
    refute status.resetting
    assert status.assigns == %{initial: true, init_arg: :startup}
    assert status.pending == []
    assert status.queued == 0
    assert status.workers == 0
    fresh = :sys.get_state(server)
    assert fresh.history == []
    assert fresh.private == %{}
    assert fresh.current == nil

    send(server, {Runtime, worker_ref, :result, {:generated, %{text: "late", proposals: []}}})
    send(server, {Runtime, before.control, :skill_started, :echo, worker})
    assert GenServer.call(server, :snapshot).assigns == %{initial: true, init_arg: :startup}
    refute_receive {Server, ^server, {:response, ^held, _, _}}, 30
    refute_receive {Server, ^server, {:response, ^queued, _, _}}, 30
    refute_receive {:application_info, ^server, {Runtime, _, _, _, _}}, 30

    assert {:ok, fresh_interaction} = Server.input(server, "fresh conversation")

    assert_receive {Server, ^server, {:response, ^fresh_interaction, "fresh conversation", _}},
                   5_000
  end

  test "reset replaces mounted Skill state and ignores output from retired children" do
    server =
      start_server(
        agent: SkilledAgent,
        skill_options: %{echo: [assigns: %{skill_default: 1}, init_arg: :skill_start]}
      )

    assert {:ok, child} = Server.skill_server(server, :echo)
    assert :ok = GenServer.call(child, :mutate)
    assert {:ok, interaction} = Server.input(server, "skill history", skill: :echo)

    assert_receive {Server, ^server,
                    {:skill, :echo, {:response, ^interaction, "skill history", _}}},
                   5_000

    assert :sys.get_state(child).history != []
    assert {:ok, _} = Server.input(server, "hold", skill: :echo)
    assert_receive {:service_started, held_worker, _}, 5_000
    on_exit(fn -> send(held_worker, :release) end)
    worker_monitor = Process.monitor(held_worker)
    monitor = Process.monitor(child)

    assert :ok = Server.reset(server)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^held_worker, _}, 5_000
    assert {:ok, fresh_child} = Server.skill_server(server, :echo)
    refute fresh_child == child

    assert GenServer.call(fresh_child, :snapshot) == %{
             assigns: %{initial: true, skill_default: 1, init_arg: :skill_start},
             private: %{},
             pending: %{}
           }

    fresh = :sys.get_state(fresh_child)
    assert fresh.history == []
    assert fresh.managed_owner == nil
    root = :sys.get_state(server)
    assert fresh.gam == root.gam
    assert fresh.opts[:checkpoint] == Skills.checkpoint(root.opts[:checkpoint], :echo)

    send(server, {Server, child, {:response, "old", "retired output", []}})
    assert GenServer.call(server, :snapshot).assigns == %{initial: true, init_arg: :startup}
    refute_receive {:application_info, ^server, {Server, ^child, _}}, 30
    refute_receive {Server, ^server, {:skill, :echo, {:response, "old", _, _}}}, 30
  end

  @tag :tmp_dir
  test "disk reset selects a fresh generation across repeated resets and cold restart", %{
    tmp_dir: path
  } do
    opts = server_options(gam: [storage: {:disk, path}], identity: %{subject: "durable-reset"})
    assert {:ok, server} = Server.start_link(opts)
    on_exit(fn -> TestProcesses.stop(server) end)
    assert {:ok, old} = Server.input(server, "old durable history")
    assert_receive {Server, ^server, {:response, ^old, _, _}}, 5_000
    original = :sys.get_state(server)
    original_domain = Managed.info(original.managed_owner).domain
    assert {:ok, old_profile} = File.read(Path.join(path, "authority.profile"))

    assert :ok = Server.reset(server)
    first = Server.status(server).session
    assert :ok = GenServer.call(server, :mutate)
    assert :ok = Server.reset(server)
    second = Server.status(server).session
    assert second != first
    selected = :sys.get_state(server)
    assert selected.history == []
    assert selected.assigns == %{initial: true, init_arg: :startup}
    domain = Managed.info(selected.managed_owner).domain
    refute domain == original_domain
    assert {:ok, ^old_profile} = File.read(Path.join(path, "authority.profile"))
    assert :ok = GenServer.stop(server)

    assert {:ok, restarted} = Server.start_link(opts)
    on_exit(fn -> TestProcesses.stop(restarted) end)
    assert Server.status(restarted).session == second
    restored = :sys.get_state(restarted)
    assert restored.history == []
    assert restored.assigns == %{initial: true, init_arg: :startup}
    assert Managed.info(restored.managed_owner).domain == domain
    assert :ok = Server.reset(restarted)
    assert Server.status(restarted).session != second
  end

  test "only the consumer can reset and a mounted Skill requires its root" do
    server = start_server(agent: SkilledAgent)
    session = Server.status(server).session

    assert {:error, :untrusted_reset_transport} =
             Task.async(fn -> Server.reset(server) end) |> Task.await(5_000)

    assert {:ok, child} = Server.skill_server(server, :echo)
    assert {:error, :reset_through_root_agent} = Server.reset(child)
    assert {:error, :invalid_reset_options} = Server.reset(server, force: true)
    assert Server.status(server).session == session
    assert :ok = Server.reset(server)
  end

  test "external deliveries require the fresh session and retired continuations cannot run" do
    server = start_server()
    old_session = Server.status(server).session
    assert :ok = Server.deliver(server, "before", :external, :before)
    assert_receive {:external_result, ^server, :before}, 5_000
    assert {:ok, _} = Server.input(server, "wait")
    assert_receive {:awaiting_reply, ^server}, 5_000
    assert [%{id: pending_id}] = Server.status(server).pending
    assert :ok = Server.reset(server)

    assert {:error, :stale_session} =
             Server.deliver(server, "old-external", :external, :stale, session: old_session)

    assert {:error, :session_required} = Server.deliver(server, "bare", :external, :bare)

    assert {:error, :session_required} =
             Server.deliver(server, "retired-pending", {:pending, pending_id}, :retired)

    session = Server.status(server).session

    assert {:error, :unknown_pending_continuation} =
             Server.deliver(server, "unknown-pending", {:pending, pending_id}, :retired,
               session: session
             )

    assert {:ok, _} = Server.input(server, "wait")
    assert_receive {:awaiting_reply, ^server}, 5_000
    assert [%{id: ^pending_id}] = Server.status(server).pending

    assert {:error, :stale_session} =
             Server.deliver(server, "reused-old-pending", {:pending, pending_id}, :stale,
               session: old_session
             )

    assert {:error, :session_required} =
             Server.deliver(server, "reused-bare-pending", {:pending, pending_id}, :bare)

    assert [%{id: ^pending_id}] = Server.status(server).pending

    assert :ok =
             Server.deliver(server, "reused-fresh-pending", {:pending, pending_id}, :fresh_reply,
               session: session
             )

    assert_receive {:reply_result, ^server, :fresh_reply}, 5_000
    assert Server.status(server).pending == []

    assert :ok =
             Server.deliver(server, "fresh", :external, :fresh,
               session: Server.status(server).session
             )

    assert_receive {:external_result, ^server, :fresh}, 5_000
    refute_receive {:external_result, ^server, :stale}, 30
    refute_receive {:external_result, ^server, :bare}, 30
  end

  test "an executing governed effect refuses reset and completes in its original session" do
    server = start_server(agent: GovernedAgent, gam: [operations: %{run: [confirm: false]}])
    session = Server.status(server).session
    assert {:ok, _} = Server.input(server, "run hold")
    assert_receive {:effect_started, effect}, 5_000
    on_exit(fn -> send(effect, :release) end)

    assert {:error, :reset_busy} = Server.reset(server)
    assert Process.alive?(effect)
    assert Server.status(server).session == session
    refute Server.status(server).resetting
    send(effect, :release)

    assert_receive {:governed_result, ^server, {:governed, %{outcome: %{status: :succeeded}}}},
                   5_000

    assert eventually(fn ->
             status = Server.status(server)
             managed = :sys.get_state(:sys.get_state(server).managed_owner)
             not status.busy and status.workers == 0 and map_size(managed.workers) == 0
           end)

    assert :ok = Server.reset(server)
    assert Server.status(server).session != session
  end

  test "a displayed consent is retired and cannot approve an operation in the new session" do
    server = start_server(agent: GovernedAgent, gam: [operations: %{run: [confirm: true]}])
    assert {:ok, old_input} = Server.input(server, "run old")
    assert_receive {Managed, _, {:presentation, material}}, 5_000
    old_presentation = material["presentation_ref"]
    assert :ok = Server.presented(server, old_presentation)
    assert_receive {Server, ^server, {:pending, ^old_input, _}}, 5_000

    assert :ok = Server.reset(server)
    assert Server.status(server).pending == []
    assert {:error, :stale_presentation} = Server.decide(server, nil, old_presentation, :confirm)
    refute_receive {:effect_executed, %{mode: "old"}}, 30

    assert {:ok, fresh_input} = Server.input(server, "run fresh")
    assert_receive {Managed, _, {:presentation, fresh_material}}, 5_000
    fresh_presentation = fresh_material["presentation_ref"]
    assert fresh_presentation != old_presentation
    assert :ok = Server.presented(server, fresh_presentation)
    assert_receive {Server, ^server, {:pending, ^fresh_input, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, fresh_presentation, :confirm)
    assert_receive {:effect_executed, %{mode: "fresh"}}, 5_000
  end

  test "an unavailable database refuses configured reset while explicit RAM needs no database" do
    ref = controlled_store()

    server =
      start_server(
        identity: %{subject: "offline-reset"},
        gam: [storage: :ledger, store: {ControlledStore, ref}]
      )

    session = Server.status(server).session
    assert :ok = GenServer.call(server, :mutate)
    Elixir.Agent.update(ref.control, fn _ -> :offline end)
    assert {:error, :offline} = Server.reset(server)
    assert Server.status(server).session == session
    assert Server.status(server).assigns.runtime_only
    refute Server.status(server).resetting

    assert :ok = Server.reset(server, storage: :ephemeral)
    assert Server.status(server).session != session
    root = :sys.get_state(server)
    assert :sys.get_state(root.managed_owner).ephemeral
    assert root.assigns == %{initial: true, init_arg: :startup}
    assert Process.alive?(ref.journal)
    assert Process.alive?(ref.ledger)
  end

  test "a blocked provider times out reset and leaves the running session available" do
    ref = controlled_store()

    server =
      start_server(
        identity: %{subject: "slow-reset"},
        gam: [storage: :ledger, store: {ControlledStore, ref}]
      )

    session = Server.status(server).session

    probe =
      Task.async(fn ->
        receive do
          {:store_blocked, blocked, {:managed_authority, _}} ->
            assert Server.status(server).resetting
            assert {:error, :reset_busy} = Server.input(server, "during reset")
            assert {:error, :reset_busy} = Server.deliver(server, "during-reset", :external, :old)
            blocked
        end
      end)

    Elixir.Agent.update(ref.control, fn _ -> {:block, probe.pid} end)
    assert {:error, :reset_timeout} = Server.reset(server, timeout: 500)
    blocked = Task.await(probe, 5_000)
    monitor = Process.monitor(blocked)
    assert_receive {:DOWN, ^monitor, :process, ^blocked, _}, 5_000
    Elixir.Agent.update(ref.control, fn _ -> :online end)
    assert Server.status(server).session == session
    refute Server.status(server).resetting
    assert {:ok, input} = Server.input(server, "after timeout")
    assert_receive {Server, ^server, {:response, ^input, "after timeout", _}}, 5_000
  end

  @tag :capture_log
  test "an acquired activation with a lost reply stops the old root and restores the selected generation" do
    ref = controlled_store()
    name = __MODULE__.RestartedServer

    server =
      start_server(
        name: name,
        identity: %{subject: "activation-unknown"},
        gam: [storage: :ledger, store: {ControlledStore, ref}]
      )

    old_session = Server.status(server).session
    assert {:ok, input} = Server.input(server, "old generation history")
    assert_receive {Server, ^server, {:response, ^input, _, _}}, 5_000
    monitor = Process.monitor(server)
    observer = self()
    Elixir.Agent.update(ref.control, fn _ -> {:reply_lost, observer} end)

    assert {:error, {:session_activation_unknown, :reply_lost}} = Server.reset(server)
    assert_receive {:session_pointer_acquired, _}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^server, {:reset_failed, _}}, 5_000
    assert eventually(fn -> is_pid(Process.whereis(name)) and Process.whereis(name) != server end)
    replacement = Process.whereis(name)
    assert Server.status(replacement).session != old_session
    assert Server.status(replacement).assigns == %{initial: true, init_arg: :startup}
    assert :sys.get_state(replacement).history == []
    refute Server.status(replacement).resetting
  end

  test "a queued timeout aborts bootstrap before activation is acknowledged by the root" do
    ref = controlled_store()

    consumer =
      Task.async(fn ->
        receive do
          {:reset, server} -> Server.reset(server, timeout: 1_000)
        end
      end)

    server =
      start_server(
        consumer: consumer.pid,
        identity: %{subject: "activation-ack-race"},
        gam: [storage: :ledger, store: {ControlledStore, ref}]
      )

    session = Server.status(server).session
    observer = self()
    Elixir.Agent.update(ref.control, fn _ -> {:block, observer} end)
    send(consumer.pid, {:reset, server})
    assert_receive {:store_blocked, candidate, {:managed_authority, _}}, 5_000
    monitor = Process.monitor(candidate)
    reset = :sys.get_state(server).reset_request
    remaining = Process.read_timer(reset.timer)
    assert is_integer(remaining)
    assert :ok = :sys.suspend(server)

    try do
      # Queue the timeout before the stage's activation request, while keeping
      # the candidate free to finish its bootstrap on the same Store.
      Process.sleep(remaining + 25)
      Elixir.Agent.update(ref.control, fn _ -> {:reply_lost, observer} end)
      send(candidate, :release)
      refute_receive {:session_pointer_acquired, _}, 50
    after
      :sys.resume(server)
    end

    assert {:error, :reset_timeout} = Task.await(consumer, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^candidate, _}, 5_000
    assert Server.status(server).session == session
    refute Server.status(server).resetting
    refute_receive {:session_pointer_acquired, _}, 30
    assert {:ok, _} = Server.input(server, "after activation timeout")

    assert eventually(fn ->
             Server.status(server).assigns[:last_input] == "after activation timeout"
           end)
  end

  test "a frozen Skill cannot restart into the old generation while reset is staged" do
    ref = controlled_store()

    consumer =
      Task.async(fn ->
        receive do
          {:reset, server} -> Server.reset(server, timeout: 500)
        end
      end)

    server =
      start_server(
        agent: SkilledAgent,
        consumer: consumer.pid,
        identity: %{subject: "frozen-skill"},
        gam: [storage: :ledger, store: {ControlledStore, ref}]
      )

    assert {:ok, child} = Server.skill_server(server, :echo)
    assert_receive {:initialized, ^server, _, _, _}, 5_000
    assert_receive {:initialized, ^child, _, _, _}, 5_000
    session = Server.status(server).session
    observer = self()
    Elixir.Agent.update(ref.control, fn _ -> {:block, observer} end)
    send(consumer.pid, {:reset, server})
    assert_receive {:store_blocked, _, {:managed_authority, _}}, 5_000
    monitor = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 5_000
    Elixir.Agent.update(ref.control, fn _ -> :online end)
    refute_receive {:initialized, _, _, _, _}, 50
    assert Server.status(server).resetting

    assert {:error, :reset_timeout} = Task.await(consumer, 5_000)
    assert Server.status(server).session == session
    refute Server.status(server).resetting
    assert_receive {:initialized, restarted, _, _, _}, 5_000
    assert restarted != child
    assert {:ok, ^restarted} = Server.skill_server(server, :echo)
    assert :sys.get_state(restarted).gam == :sys.get_state(server).gam
  end

  defp controlled_store do
    %{
      control: start_supervised!({Elixir.Agent, fn -> :online end}),
      journal: start_supervised!({Managed.Store, []}),
      ledger: start_supervised!({Spectre.GAM.Ledger.Store.ETS, []})
    }
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end

  defp start_server(opts \\ []), do: start_supervised!({Server, server_options(opts)})

  defp server_options(opts) do
    Keyword.merge(
      [
        agent: Agent,
        consumer: self(),
        assigns: %{initial: true},
        init_arg: :startup,
        services: [generate: Service]
      ],
      opts
    )
  end
end
