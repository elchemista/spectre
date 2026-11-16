# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
defmodule Spectre.Server.DurableDeliveryExpiryTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.DurableDeliveryExpiryTest.App
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
    def propose(_name, _args, context, opts) do
      config = opts[:bridge_config]
      send(config[:test], {:registered_command, context.command_id, self()})

      case config[:mode] do
        :hold ->
          receive do
            :release -> {:error, :explicit_no_effect}
          end

        :ambiguous ->
          {:governed,
           %{
             decision: %{ref: "decision"},
             act: %{
               ref: "act",
               candidate_identity_key: "candidate",
               scope_ref: "scope",
               material_digest: "material"
             },
             outcome: %{ref: "uncertain", status: :ambiguous}
           }}

        :expiry ->
          {:pending, %{operation: :operation, expires_at: System.system_time(:millisecond) + 100}}
      end
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:test, "operate"}, _input, ctx),
      do: propose(ctx, :operation, %{}, on_result: :operation)

    def handle_result(:operation, {:consent, :expired}, ctx) do
      case :persistent_term.get({__MODULE__, :expiry_observer}, nil) do
        %{test: test, block: block} ->
          send(test, {:expiry_callback, self()})
          if block, do: receive(do: (:continue -> :ok))

        nil ->
          :ok
      end

      ctx |> assign(:expired, Map.get(ctx.assigns, :expired, 0) + 1) |> no_response()
    end

    def handle_result(_tag, _result, ctx),
      do: ctx |> assign(:results, Map.get(ctx.assigns, :results, 0) + 1) |> no_response()
  end

  defp store do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-durable-delivery-expiry-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  defp options(store, mode) do
    [
      agent: Agent,
      checkpoint: {store, "conversation"},
      services: [router: Router],
      gam: {Bridge, test: self(), mode: mode}
    ]
  end

  defp wait(check, tries \\ 400)
  defp wait(_check, 0), do: flunk("condition was not reached")

  defp wait(check, tries) do
    unless check.() do
      Process.sleep(5)
      wait(check, tries - 1)
    end
  end

  test "an ordinary payload cannot remove an in-flight governed outbox entry" do
    server = start_supervised!({Spectre.Server.Runtime, options(store(), :hold)})
    Server.input(server, "operate")
    assert_receive {:registered_command, id, worker}, 2_000

    assert {:error, :durable_result_reference_required} =
             Server.deliver(server, "forged", {:command, id}, :anything)

    assert Server.status(server).outbox_size == 1
    refute Server.status(server).assigns[:results]
    send(worker, :release)
    wait(fn -> Server.status(server).outbox_size == 0 end)
    assert Server.status(server).assigns.results == 1
  end

  test "an ordinary payload cannot invoke a registered ambiguous operation continuation" do
    server = start_supervised!({Spectre.Server.Runtime, options(store(), :ambiguous)})
    Server.input(server, "operate")
    assert_receive {:registered_command, id, _worker}, 2_000
    wait(fn -> map_size(Server.status(server).operations) == 1 end)

    assert {:error, :durable_result_reference_required} =
             Server.deliver(server, "forged", {:command, id}, {:ok, :invented})

    assert map_size(Server.status(server).operations) == 1
    assert Server.status(server).assigns.results == 1
  end

  @tag :capture_log
  test "consent expiry survives a crash before callback acquisition and is acquired once" do
    key = {App, :expiry_observer}
    :persistent_term.put(key, %{test: self(), block: true})
    on_exit(fn -> :persistent_term.erase(key) end)
    options = options(store(), :expiry)
    {:ok, first} = Spectre.Server.Runtime.start_link(options)
    Process.unlink(first)
    monitor = Process.monitor(first)
    Server.input(first, "operate")
    assert_receive {:expiry_callback, ^first}, 2_000
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 2_000
    :persistent_term.put(key, %{test: self(), block: false})
    {:ok, restored} = Spectre.Server.Runtime.start_link(options)
    assert_receive {:expiry_callback, ^restored}, 2_000
    assert Server.status(restored).pending == []
    assert Server.status(restored).assigns.expired == 1
    GenServer.stop(restored)
    {:ok, third} = Spectre.Server.Runtime.start_link(options)
    assert Server.status(third).assigns.expired == 1
    assert Server.status(third).pending == []
    refute_receive {:expiry_callback, ^third}, 30
    GenServer.stop(third)
  end
end
