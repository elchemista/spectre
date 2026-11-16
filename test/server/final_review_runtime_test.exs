# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
defmodule Spectre.Server.FinalReviewRuntimeTest do
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
    def propose(name, _args, context, opts) do
      test = opts[:bridge_config][:test]
      send(test, {:proposing, name, context.command_id, self()})
      if name == :held, do: receive(do: (:release -> :ok))
      pending = %{operation: name}
      ttl = opts[:bridge_config][:ttl]

      pending =
        if ttl,
          do: Map.put(pending, :expires_at, System.system_time(:millisecond) + ttl),
          else: pending

      {:pending, pending}
    end

    def confirm(pending, _input, _context, opts), do: resolve(:confirm, pending, opts)
    def explain(pending, _input, _context, opts), do: resolve(:explain, pending, opts)
    def resume(pending, _input, _context, opts), do: resolve(:resume, pending, opts)

    defp resolve(kind, pending, opts) do
      config = opts[:bridge_config]
      send(config[:test], {:resolving, kind, self()})

      case config[:mode] do
        :crash ->
          if kind == :confirm,
            do: raise("confirmation interpreter unavailable"),
            else: exit(:presentation_builder_unavailable)

        :hold ->
          receive do
            :release -> {:governed, %{outcome: %{status: :succeeded}}}
            :late_error -> {:error, :scope_unavailable}
          end

        :show ->
          {:pending, %{operation: pending.operation}}
      end
    end

    def recover_command(_id, _context, opts) do
      send(opts[:bridge_config][:test], :recovering_command)

      case opts[:bridge_config][:recovery] do
        :show ->
          {:pending, %{operation: :held}}

        :fact ->
          {:governed,
           %{
             decision: %{ref: "confirmed-decision"},
             act: %{
               ref: "confirmed-act",
               candidate_identity_key: "confirmed-candidate",
               scope_ref: "confirmed-scope",
               material_digest: "confirmed-material"
             },
             outcome: %{ref: "confirmed-outcome", status: :succeeded}
           }}

        _ ->
          {:error, :recovery_unavailable}
      end
    end

    def release_command(id, _context, opts) do
      send(opts[:bridge_config][:test], {:releasing_journal, self()})
      send(opts[:bridge_config][:test], {:released_command, id})
      if opts[:bridge_config][:hold_cleanup], do: receive(do: (:release -> :ok))
      :ok
    end
  end

  defmodule Cognitive do
    def generate(_request, context, _opts) do
      send(context.options[:test_pid], {:generating, context.command_id, self()})

      receive do
        :release -> {:generated, %{text: "live answer", proposals: []}}
      end
    end
  end

  # The trusted query port supplies durable facts. The real Scope/proof checks
  # are covered by server_gam_test; these cases isolate Runtime correlation.
  defmodule DeliveryBridge do
    def propose(name, args, context, opts) do
      {:pending, pending} = Bridge.propose(name, args, context, opts)
      candidate = %{identity_key: "confirmed-candidate", scope_ref: "confirmed-scope"}
      {:pending, Map.put(pending, :candidate, candidate)}
    end

    defdelegate confirm(pending, input, context, opts), to: Bridge
    defdelegate recover_command(id, context, opts), to: Bridge
    defdelegate release_command(id, context, opts), to: Bridge

    def resolve_result(%{act_ref: "confirmed-act"}, _context, _opts) do
      {:governed,
       %{
         decision: %{ref: "confirmed-decision"},
         act: %{
           ref: "confirmed-act",
           candidate_identity_key: "confirmed-candidate",
           scope_ref: "confirmed-scope",
           material_digest: "confirmed-material"
         },
         outcome: %{ref: "confirmed-outcome", status: :succeeded}
       }}
    end
  end

  defmodule App do
    use Spectre.Server
    def init(:foreground, ctx), do: {:ok, await_input(ctx, "front", timeout: :infinity)}
    def init(_arg, ctx), do: {:ok, ctx}

    def handle_flow({:test, "operate"}, _input, ctx),
      do: propose(ctx, :operate, %{}, on_result: :operation)

    def handle_flow({:test, "held"}, _input, ctx),
      do: propose(ctx, :held, %{}, on_result: :operation)

    def handle_flow({:test, "wait"}, _input, ctx),
      do: await_input(ctx, "front", timeout: :infinity, on_result: :front)

    def handle_flow({:test, "actor"}, _input, ctx),
      do: await_reply(ctx, "actor", timeout: :infinity, on_result: :actor)

    def handle_flow({:test, "generate"}, _input, ctx), do: generate(ctx, :answer)
    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")
    def handle_pending(pending, %{text: "confirm"}, ctx), do: confirm_pending(ctx, pending.id)

    def handle_pending(pending, %{text: "double_confirm"}, ctx),
      do: ctx |> confirm_pending(pending.id) |> confirm_pending(pending.id)

    def handle_pending(pending, %{text: "explain"}, ctx), do: explain_pending(ctx, pending.id)

    def handle_pending(pending, %{text: "wait"}, ctx),
      do: route_current_input(ctx, suspend: pending.id)

    def handle_pending(pending, input, ctx), do: super(pending, input, ctx)
    def handle_result(:operation, {:governed_unknown, _}, ctx), do: respond(ctx, "uncertain")

    def handle_result(:operation, {:governed, _}, ctx),
      do:
        ctx |> assign(:completions, Map.get(ctx.assigns, :completions, 0) + 1) |> respond("done")

    def handle_result(:operation, {:error, _}, ctx), do: no_response(ctx)

    def handle_result(:actor, result, ctx),
      do: ctx |> assign(:actor_result, result) |> no_response()

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
    def handle_cast({:resume, id}, ctx), do: {:noreply, resume_pending(ctx, id)}
  end

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: App
  end

  defp store do
    path =
      Path.join(System.tmp_dir!(), "spectre-final-runtime-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  defp options(extra \\ []) do
    Keyword.merge(
      [
        agent: Agent,
        consumer: self(),
        test_pid: self(),
        services: [router: Router, generate: Cognitive],
        gam: {Bridge, test: self(), mode: :show}
      ],
      extra
    )
  end

  defp wait(check, tries \\ 400)
  defp wait(_check, 0), do: flunk("condition was not reached")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end

  @tag :capture_log
  test "crashed confirm, explain and resume leave a nonblocking uncertain continuation" do
    for kind <- [:confirm, :explain, :resume] do
      {:ok, server} =
        Spectre.Server.Runtime.start_link(options(gam: {Bridge, test: self(), mode: :crash}))

      Server.input(server, "operate")
      wait(fn -> Server.status(server).pending != [] end)
      [pending] = Server.status(server).pending

      if kind == :resume,
        do: GenServer.cast(server, {:resume, pending.id}),
        else: Server.input(server, Atom.to_string(kind))

      assert_receive {:resolving, ^kind, _}, 2_000
      assert_receive {Server, ^server, {:response, _, "uncertain", _}}, 2_000
      assert [%{status: :uncertain}] = Server.status(server).pending
      assert Server.status(server).outbox_size == 1
      {:ok, id} = Server.input(server, "echo")
      assert_receive {Server, ^server, {:response, ^id, "echo", _}}, 2_000
      assert Server.status(server).queued == 0
      GenServer.stop(server)
    end
  end

  test "a confirm deadline frees the input queue and its eventual result keeps the original input" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime,
         options(
           worker_timeout: 50,
           gam: {Bridge, test: self(), mode: :hold, ttl: 120}
         )}
      )

    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    {:ok, confirmation} = Server.input(server, "confirm")
    assert_receive {:resolving, :confirm, worker}, 2_000
    assert_receive {Server, ^server, {:response, ^confirmation, "uncertain", _}}, 2_000
    [pending] = Server.status(server).pending
    wait(fn -> System.system_time(:millisecond) > pending.expires_at end)
    {:ok, other} = Server.input(server, "echo")
    assert_receive {Server, ^server, {:response, ^other, "echo", _}}, 2_000
    assert [%{status: :uncertain}] = Server.status(server).pending
    assert Process.alive?(worker)
    send(worker, :release)
    assert_receive {Server, ^server, {:response, ^confirmation, "done", _}}, 2_000
    wait(fn -> Server.status(server).outbox_size == 0 end)
    assert Server.status(server).pending == []
  end

  test "a background resume cannot replace an existing foreground reply wait" do
    server = start_supervised!({Spectre.Server.Runtime, options()})
    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [consent] = Server.status(server).pending
    Server.input(server, "wait")
    wait(fn -> length(Server.status(server).pending) == 2 end)
    GenServer.cast(server, {:resume, consent.id})
    assert_receive {:resolving, :resume, _}, 2_000

    wait(fn ->
      Enum.any?(
        Server.status(server).pending,
        &(&1.id == consent.id and Map.get(&1, :revision) == 2)
      )
    end)

    state = :sys.get_state(server)
    assert state.foreground == "front"
    assert state.pending[consent.id].status == :suspended
    assert state.pending["front"].status == :foreground
  end

  test "a show arriving after its deadline stays suspended behind a newer foreground" do
    server = start_supervised!({Spectre.Server.Runtime, options(worker_timeout: 50)})
    {:ok, original} = Server.input(server, "held")
    assert_receive {:proposing, :held, _command, showing}, 2_000
    assert_receive {Server, ^server, {:response, ^original, "uncertain", _}}, 2_000
    Server.input(server, "wait")
    wait(fn -> Enum.any?(Server.status(server).pending, &(&1.id == "front")) end)
    send(showing, :release)
    wait(fn -> length(Server.status(server).pending) == 2 end)
    state = :sys.get_state(server)
    assert state.foreground == "front"
    assert state.pending["front"].status == :foreground

    assert Enum.any?(state.pending, fn {id, pending} ->
             id != "front" and pending.status == :suspended
           end)
  end

  test "a recovered show preserves a foreground created by application init" do
    opts =
      options(
        checkpoint: {store(), "recovered-show"},
        gam: {Bridge, test: self(), mode: :show, recovery: :show}
      )

    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    Server.input(server, "held")
    assert_receive {:proposing, :held, _command, old_worker}, 2_000
    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(Keyword.put(opts, :init_arg, :foreground))
    assert_receive :recovering_command, 2_000
    wait(fn -> length(Server.status(restored).pending) == 2 end)
    state = :sys.get_state(restored)
    assert state.foreground == "front"
    assert state.pending["front"].status == :foreground

    assert Enum.any?(state.pending, fn {id, pending} ->
             id != "front" and pending.status == :suspended
           end)

    send(old_worker, :release)
    GenServer.stop(restored)
  end

  test "an actor result delivered by pending id removes its infinite wait across restart" do
    opts = options(checkpoint: {store(), "delivered-wait"})
    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    Server.input(server, "actor")
    wait(fn -> Server.status(server).pending != [] end)
    assert :ok = Server.deliver(server, "actor-message", {:pending, "actor"}, {:ok, :delivered})
    assert :ok = Server.deliver(server, "actor-message", {:pending, "actor"}, {:ok, :delivered})
    assert Server.status(server).pending == []
    assert Server.status(server).outbox_size == 0
    assert Server.status(server).workers == 0
    assert Server.status(server).assigns.actor_result == {:ok, :delivered}
    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert Server.status(restored).pending == []
    assert Server.status(restored).outbox_size == 0
    assert Server.status(restored).assigns.actor_result == {:ok, :delivered}
    GenServer.stop(restored)
  end

  @tag :capture_log
  test "pending delivery after a crashed confirmation keeps its confirmation input and retires the outbox" do
    opts =
      options(
        checkpoint: {store(), "crashed-confirm-delivery"},
        gam: {DeliveryBridge, test: self(), mode: :crash}
      )

    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [pending] = Server.status(server).pending
    {:ok, confirmation} = Server.input(server, "confirm")
    assert_receive {Server, ^server, {:response, ^confirmation, "uncertain", _}}, 2_000
    wait(fn -> Server.status(server).workers == 0 end)
    assert Server.status(server).outbox_size == 1

    reference = %{
      decision_ref: "confirmed-decision",
      act_ref: "confirmed-act",
      outcome_ref: "confirmed-outcome"
    }

    assert :ok =
             Server.deliver(
               server,
               "after-confirm-crash",
               {:pending, pending.id},
               {:governed_ref, reference}
             )

    assert_receive {Server, ^server, {:response, ^confirmation, "done", _}}, 2_000
    assert Server.status(server).outbox_size == 0
    assert Server.status(server).pending == []
    assert Server.status(server).assigns.completions == 1
    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)

    assert :ok =
             Server.deliver(
               restored,
               "same-fact-after-restart",
               {:pending, pending.id},
               {:governed_ref, reference}
             )

    assert Server.status(restored).outbox_size == 0
    assert Server.status(restored).assigns.completions == 1
    refute_receive :recovering_command, 30
    refute_receive {Server, ^restored, {:response, _, "done", _}}, 30
    GenServer.stop(restored)
  end

  @tag :capture_log
  test "pending delivery refuses to choose between multiple crashed confirmation commands" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime,
         options(
           checkpoint: {store(), "ambiguous-confirm-delivery"},
           gam: {DeliveryBridge, test: self(), mode: :crash}
         )}
      )

    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [pending] = Server.status(server).pending
    Server.input(server, "double_confirm")
    wait(fn -> Server.status(server).workers == 0 and Server.status(server).outbox_size == 2 end)

    reference = %{
      decision_ref: "confirmed-decision",
      act_ref: "confirmed-act",
      outcome_ref: "confirmed-outcome"
    }

    assert {:error, :ambiguous_pending_continuation} =
             Server.deliver(
               server,
               "ambiguous-confirm-crash",
               {:pending, pending.id},
               {:governed_ref, reference}
             )

    assert Server.status(server).outbox_size == 2
    refute Server.status(server).assigns[:completions]
    assert [%{id: id, status: :uncertain}] = Server.status(server).pending
    assert id == pending.id
  end

  test "external cognitive completion consumes the live command exactly once" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime, options(checkpoint: {store(), "delivered-generate"})}
      )

    {:ok, input_id} = Server.input(server, "generate")
    assert_receive {:generating, command, worker}, 2_000
    monitor = Process.monitor(worker)
    result = {:generated, %{text: "external answer", proposals: []}}
    assert :ok = Server.deliver(server, "external-message", {:command, command}, result)
    assert_receive {Server, ^server, {:response, ^input_id, "external answer", _}}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    assert :ok = Server.deliver(server, "same-command-again", {:command, command}, result)
    refute_receive {Server, ^server, {:response, ^input_id, _, _}}, 30
    assert Server.status(server).outbox_size == 0
  end

  test "journal release runs only for governed commands and does not enter the durable inbox" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime,
         options(
           checkpoint: {store(), "cleanup"},
           gam: {Bridge, test: self(), mode: :show, hold_cleanup: true}
         )}
      )

    Server.input(server, "generate")
    assert_receive {:generating, _command, generation}, 2_000
    send(generation, :release)
    assert_receive {Server, ^server, {:response, _, "live answer", _}}, 2_000
    refute_receive {:releasing_journal, _}, 30
    Server.input(server, "operate")
    assert_receive {:releasing_journal, cleanup}, 2_000
    before = :sys.get_state(server)
    send(cleanup, :release)
    wait(fn -> Server.status(server).workers == 0 end)
    after_cleanup = :sys.get_state(server)
    assert after_cleanup.seen_events == before.seen_events
    assert after_cleanup.checkpoint_revision == before.checkpoint_revision
    assert after_cleanup.inbox == %{}
  end

  test "late and recovered transport errors preserve the governed obligation until facts are recovered" do
    opts =
      options(
        checkpoint: {store(), "failed-recovery"},
        worker_timeout: 50,
        gam: {Bridge, test: self(), mode: :hold}
      )

    {:ok, server} = Spectre.Server.Runtime.start_link(opts)
    Server.input(server, "operate")
    assert_receive {:proposing, :operate, proposal, _}, 2_000
    wait(fn -> Server.status(server).pending != [] end)
    assert_receive {:released_command, ^proposal}, 2_000
    {:ok, confirmation} = Server.input(server, "confirm")
    assert_receive {:resolving, :confirm, worker}, 2_000
    assert_receive {Server, ^server, {:response, ^confirmation, "uncertain", _}}, 2_000
    send(worker, :late_error)
    wait(fn -> Server.status(server).workers == 0 end)
    assert Server.status(server).outbox_size == 1
    assert [%{status: :uncertain}] = Server.status(server).pending
    [command] = Map.keys(:sys.get_state(server).outbox)
    refute_receive {:released_command, ^command}, 30
    GenServer.stop(server)

    {:ok, restored} = Spectre.Server.Runtime.start_link(opts)
    assert_receive :recovering_command, 2_000
    assert_receive {Server, ^restored, {:response, ^confirmation, "uncertain", _}}, 2_000
    wait(fn -> Server.status(restored).workers == 0 end)
    assert Server.status(restored).outbox_size == 1
    assert [%{status: :uncertain}] = Server.status(restored).pending
    assert :sys.get_state(restored).foreground == nil
    assert Map.has_key?(:sys.get_state(restored).outbox, command)
    refute_receive {:released_command, ^command}, 30
    refute_receive :recovering_command, 30
    {:ok, id} = Server.input(restored, "echo")
    assert_receive {Server, ^restored, {:response, ^id, "echo", _}}, 2_000
    GenServer.stop(restored)

    available = Keyword.put(opts, :gam, {Bridge, test: self(), mode: :hold, recovery: :fact})
    {:ok, reconciled} = Spectre.Server.Runtime.start_link(available)
    assert_receive :recovering_command, 2_000
    assert_receive {Server, ^reconciled, {:response, ^confirmation, "done", _}}, 2_000
    assert_receive {:released_command, ^command}, 2_000
    assert Server.status(reconciled).outbox_size == 0
    assert Server.status(reconciled).pending == []
    assert Server.status(reconciled).assigns.completions == 1
    refute_receive {:resolving, :confirm, _}, 30
    GenServer.stop(reconciled)
  end
end
