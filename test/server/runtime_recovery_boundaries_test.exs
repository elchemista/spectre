# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
defmodule Spectre.Server.RuntimeRecoveryBoundariesTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.RuntimeRecoveryBoundariesTest.App
  end

  defmodule Router do
    def route(agent, input, _opts) do
      route = %Spectre.Route{
        flow: :test,
        label: input.text,
        owner: agent,
        handler: {:server, {[:test], input.text}, []},
        accepted?: true
      }

      {:ok, {:test, input.text}, %{route: route, reason: nil}}
    end
  end

  defmodule Bridge do
    def propose(_operation, _args, _context, opts) do
      config = opts[:bridge_config]
      send(config[:test], {:proposal_started, self()})

      case config[:mode] do
        :hold ->
          receive do
            :release -> {:governed, %{outcome: %{status: :succeeded}}}
          end

        :crash ->
          exit(:transport_lost)

        :show_hold ->
          receive do
            :release -> {:pending, %{operation: :operate, presentation: %{identity: "one"}}}
          end

        _ ->
          {:pending, %{operation: :operate, presentation: %{identity: "one"}}}
      end
    end

    def resume(pending, _input, _context, opts) do
      send(opts[:bridge_config][:test], {:reshown, self()})
      {:pending, Map.put(pending, :presentation, %{identity: "two"})}
    end

    def confirm(_pending, input, _context, opts) do
      send(opts[:bridge_config][:test], {:confirmed_original, input.text})
      {:governed, %{outcome: %{status: :succeeded}}}
    end
  end

  defmodule Classifier do
    def classify(_request, context, _opts) do
      send(context.options[:test_pid], {:classifying, self()})

      receive do
        :release -> {:classified, :confirm}
      end
    end
  end

  # Trusted fixture port for operation coordination; GAM fact authenticity and
  # scope checks are exercised separately by server_gam_test.exs.
  defmodule FactBridge do
    def propose(_name, _args, _context, _opts), do: result("ambiguous", :ambiguous)

    def resolve_result(%{act_ref: "late-act", outcome_ref: ref}, _context, _opts) do
      status = if String.starts_with?(ref, "settled"), do: :succeeded, else: :ambiguous
      result(ref, status)
    end

    def result(ref, status) do
      {:governed,
       %{
         decision: %{ref: "late-decision"},
         act: %{
           ref: "late-act",
           candidate_identity_key: "late-candidate",
           scope_ref: "late-scope",
           material_digest: "late-material"
         },
         outcome: %{ref: ref, status: status}
       }}
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:test, "operate"}, _input, ctx),
      do: propose(ctx, :operate, %{}, on_result: :operated)

    def handle_flow({:test, "explode"}, _input, _ctx), do: raise("application handler failed")
    def handle_flow({:test, "no_step"}, _input, ctx), do: ctx
    def handle_flow({:test, "echo"}, _input, ctx), do: respond(ctx, "echo")

    def handle_flow({:test, "background"}, _input, ctx),
      do: await_reply(ctx, "actor", timeout: 5_000)

    def handle_flow(route, input, ctx), do: super(route, input, ctx)

    def handle_pending(pending, input, ctx),
      do: classify(ctx, input, on_result: {:confirmation, pending.id})

    def handle_result({:confirmation, id}, {:classified, :confirm}, ctx),
      do: confirm_pending(ctx, id)

    def handle_result(:operated, {:governed_unknown, _}, ctx),
      do: ctx |> assign(:unknown, true) |> respond("under verification")

    def handle_result(:operated, {:consent, :stale_input}, ctx),
      do: respond(ctx, "Please confirm the current presentation.")

    def handle_result(:operated, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
      do:
        ctx
        |> assign(:done, true)
        |> assign(:observations, Map.get(ctx.assigns, :observations, []) ++ [:succeeded])
        |> respond("done")

    def handle_result(:operated, {:governed, %{outcome: %{status: :ambiguous}}}, ctx),
      do:
        ctx
        |> assign(:observations, Map.get(ctx.assigns, :observations, []) ++ [:ambiguous])
        |> no_response()

    def handle_result(_tag, _result, ctx), do: no_response(ctx)
    def handle_cast({:resume, id}, ctx), do: {:noreply, resume_pending(ctx, id)}

    def handle_call(:seen_order, _from, ctx),
      do: {:reply, Map.get(ctx.assigns, :seen_order, []), ctx}
  end

  defp store do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-runtime-recovery-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        agent: Agent,
        consumer: self(),
        test_pid: self(),
        services: [router: Router, classify: Classifier]
      ],
      extra
    )
  end

  defp wait(check, retries \\ 500)
  defp wait(_check, 0), do: flunk("expected state was not reached")

  defp wait(check, retries) do
    unless check.() do
      Process.sleep(5)
      wait(check, retries - 1)
    end
  end

  test "a governed deadline preserves the command and accepts the eventual real result" do
    options =
      opts(
        checkpoint: {store(), "operation"},
        worker_timeout: 30,
        gam: {Bridge, test: self(), mode: :hold}
      )

    server = start_supervised!({Spectre.Server.Runtime, options})
    {:ok, id} = Server.input(server, "operate")
    assert_receive {:proposal_started, worker}, 2_000
    assert_receive {Server, ^server, {:recovery_required, _command, :propose}}, 2_000
    assert_receive {Server, ^server, {:response, ^id, "under verification", _}}, 2_000
    assert Process.alive?(worker)
    wait(fn -> Server.status(server).outbox_size == 1 end)
    assert Server.status(server).outbox_size == 1
    send(worker, :release)
    assert_receive {Server, ^server, {:response, ^id, "done", _}}, 2_000
    wait(fn -> Server.status(server).outbox_size == 0 end)
    assert Server.status(server).assigns.done
  end

  @tag :capture_log
  test "a crashed governed worker is uncertain and remains available for reconciliation" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime,
         opts(checkpoint: {store(), "crashed"}, gam: {Bridge, test: self(), mode: :crash})}
      )

    {:ok, id} = Server.input(server, "operate")
    assert_receive {Server, ^server, {:recovery_required, _command, :propose}}, 2_000
    assert_receive {Server, ^server, {:response, ^id, "under verification", _}}, 2_000
    wait(fn -> Server.status(server).outbox_size == 1 end)
    assert Server.status(server).outbox_size == 1
    refute Server.status(server).assigns[:done]
  end

  test "failing conversational callbacks are quarantined once across restart" do
    options = opts(checkpoint: {store(), "callbacks"})
    {:ok, server} = Spectre.Server.Runtime.start_link(options)

    for text <- ["explode", "no_step", "missing"] do
      {:ok, id} = Server.input(server, text)
      assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2_000
    end

    assert map_size(Server.status(server).dead_letters) == 3
    assert Process.alive?(server)
    GenServer.stop(server)
    {:ok, restored} = Spectre.Server.Runtime.start_link(options)
    assert map_size(Server.status(restored).dead_letters) == 3
    {:ok, id} = Server.input(restored, "echo")
    assert_receive {Server, ^restored, {:response, ^id, "echo", _}}, 2_000
    GenServer.stop(restored)
  end

  test "a stale classifier reply cannot approve a newer presentation" do
    server = start_supervised!({Spectre.Server.Runtime, opts(gam: {Bridge, test: self()})})
    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [pending] = Server.status(server).pending
    {:ok, stale_id} = Server.input(server, "yes")
    assert_receive {:classifying, classifier}, 2_000
    GenServer.cast(server, {:resume, pending.id})
    assert_receive {:reshown, _worker}, 2_000
    wait(fn -> hd(Server.status(server).pending).revision == 2 end)
    send(classifier, :release)

    assert_receive {Server, ^server,
                    {:response, ^stale_id, "Please confirm the current presentation.", _}},
                   2_000

    assert Server.status(server).dead_letters == %{}
    refute_receive {:confirmed_original, _}, 30
    {:ok, fresh_id} = Server.input(server, "yes")
    assert_receive {:classifying, fresh_classifier}, 2_000
    send(fresh_classifier, :release)
    assert_receive {:confirmed_original, "yes"}, 2_000
    assert_receive {Server, ^server, {:response, ^fresh_id, "done", _}}, 2_000
  end

  test "an input accepted before show completion cannot become its confirmation" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime, opts(gam: {Bridge, test: self(), mode: :show_hold})}
      )

    Server.input(server, "operate")
    assert_receive {:proposal_started, showing}, 2_000
    {:ok, early_id} = Server.input(server, "yes")
    send(showing, :release)
    assert_receive {:classifying, classifier}, 2_000
    send(classifier, :release)

    assert_receive {Server, ^server,
                    {:response, ^early_id, "Please confirm the current presentation.", _}},
                   2_000

    assert Server.status(server).dead_letters == %{}
    refute_receive {:confirmed_original, _}, 30
  end

  test "actor waits stay in the background and cannot absorb the next user input" do
    server = start_supervised!({Spectre.Server.Runtime, opts()})
    Server.input(server, "background")
    wait(fn -> Server.status(server).pending != [] end)
    assert [%{status: :background}] = Server.status(server).pending
    {:ok, id} = Server.input(server, "echo")
    assert_receive {Server, ^server, {:response, ^id, "echo", _}}, 2_000
  end

  test "unverified governed payloads cannot consume a pending continuation" do
    server =
      start_supervised!(
        {Spectre.Server.Runtime,
         opts(checkpoint: {store(), "delivery"}, gam: {Bridge, test: self()})}
      )

    Server.input(server, "operate")
    wait(fn -> Server.status(server).pending != [] end)
    [pending] = Server.status(server).pending

    assert {:error, :unverified_governed_result} =
             Server.deliver(
               server,
               "fake",
               {:pending, pending.id},
               {:governed, %{outcome: %{status: :succeeded}}}
             )

    assert {:error, :durable_result_reference_required} =
             Server.deliver(server, "fake-two", {:pending, pending.id}, :anything)

    assert length(Server.status(server).pending) == 1
    refute Server.status(server).assigns[:done]
  end

  test "late observations retain their registered operation across restart and bounded dedup retention" do
    options = opts(checkpoint: {store(), "late"}, max_seen_events: 2, gam: {FactBridge, []})
    {:ok, first} = Spectre.Server.Runtime.start_link(options)
    Server.input(first, "operate")

    wait(fn ->
      map_size(Server.status(first).operations) == 1 and not Server.status(first).busy
    end)

    [command_id] = Map.keys(Server.status(first).operations)
    assert Server.status(first).assigns.observations == [:ambiguous]
    GenServer.stop(first)
    {:ok, restored} = Spectre.Server.Runtime.start_link(options)

    Enum.each(1..4, fn _ ->
      {:ok, id} = Server.input(restored, "echo")
      assert_receive {Server, ^restored, {:response, ^id, "echo", _}}, 2_000
    end)

    reference = %{decision_ref: "late-decision", act_ref: "late-act", outcome_ref: "ambiguous"}

    assert :ok =
             Server.deliver(
               restored,
               "old-ambiguous",
               {:command, command_id},
               {:governed_ref, reference}
             )

    assert Server.status(restored).assigns.observations == [:ambiguous]

    assert :ok =
             Server.deliver(
               restored,
               "late-settled",
               {:command, command_id},
               {:governed_ref, %{reference | outcome_ref: "settled"}}
             )

    assert Server.status(restored).assigns.observations == [:ambiguous, :succeeded]
    assert Server.status(restored).operations == %{}

    Enum.each(1..4, fn _ ->
      {:ok, id} = Server.input(restored, "echo")
      assert_receive {Server, ^restored, {:response, ^id, "echo", _}}, 2_000
    end)

    assert map_size(:sys.get_state(restored).seen_events) <= 2

    assert {:error, :unknown_command_continuation} =
             Server.deliver(
               restored,
               "unregistered-late",
               {:command, command_id},
               {:governed_ref, %{reference | outcome_ref: "settled-new"}}
             )

    assert Server.status(restored).assigns.observations == [:ambiguous, :succeeded]
    GenServer.stop(restored)
  end
end
