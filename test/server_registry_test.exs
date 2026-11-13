defmodule Spectre.ServerRegistryTest.Callbacks do
  use Spectre.Server
  def handle_flow({:support, :pricing}, _input, ctx), do: respond(ctx, "price")
end

defmodule Spectre.ServerRegistryTest.StoppedCallbacks do
  use Spectre.Server
  def init(_arg, _ctx), do: {:stop, :configured_stop}
end

defmodule Spectre.ServerRegistryTest.Agent do
  use Spectre.Agent, server: Spectre.ServerRegistryTest.Callbacks

  flow :support do
    on(:pricing, regex: ~r/^price$/)
  end
end

defmodule Spectre.ServerRegistryTest.OtherAgent do
  use Spectre.Agent, server: Spectre.ServerRegistryTest.Callbacks
end

defmodule Spectre.ServerRegistryTest.StoppedAgent do
  use Spectre.Agent, server: Spectre.ServerRegistryTest.StoppedCallbacks
end

defmodule Spectre.ServerRegistryTest do
  use ExUnit.Case, async: false
  alias Spectre.Server.Registry, as: ServerRegistry
  @agent Spectre.ServerRegistryTest.Agent
  @registry __MODULE__.Owners

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, supervisor: supervisor, opts: [server_registry: @registry]}
  end

  test "concurrent subject summons return one local owner", %{supervisor: supervisor, opts: opts} do
    pids =
      1..20
      |> Task.async_stream(fn _ ->
        ServerRegistry.ensure_started(supervisor, @agent, "account-1", opts)
      end)
      |> Enum.map(fn {:ok, {:ok, pid}} -> pid end)

    assert [pid] = Enum.uniq(pids)
    assert DynamicSupervisor.count_children(supervisor).active == 1

    assert {:ok, ^pid} =
             ServerRegistry.lookup(@agent, Spectre.Subject.new("account-1"), @registry)

    assert ServerRegistry.key(@agent, "account-1") ==
             ServerRegistry.key(
               @agent,
               Spectre.Subject.new("account-1", metadata: %{note: "same subject"})
             )
  end

  test "different subjects and Agents have separate owners and terminated owners can restart", %{
    supervisor: supervisor,
    opts: opts
  } do
    assert {:ok, first} = ServerRegistry.ensure_started(supervisor, @agent, "first", opts)
    assert {:ok, second} = ServerRegistry.ensure_started(supervisor, @agent, "second", opts)

    assert {:ok, other} =
             ServerRegistry.ensure_started(
               supervisor,
               Spectre.ServerRegistryTest.OtherAgent,
               "first",
               opts
             )

    assert length(Enum.uniq([first, second, other])) == 3
    assert :ok = DynamicSupervisor.terminate_child(supervisor, first)
    assert {:error, :server_not_found} = ServerRegistry.lookup(@agent, "first", @registry)
    assert {:ok, restarted} = ServerRegistry.ensure_started(supervisor, @agent, "first", opts)
    refute restarted == first
  end

  test "invalid ownership configuration and callback startup failures remain explicit", %{
    supervisor: supervisor,
    opts: opts
  } do
    assert {:error, :subject_server_name_conflict} =
             ServerRegistry.ensure_started(
               supervisor,
               @agent,
               "first",
               opts ++ [name: :conflicting_name]
             )

    assert {:error, :server_registry_unavailable} =
             ServerRegistry.lookup(@agent, "first", __MODULE__.Missing)

    assert {:error, :server_registry_unavailable} =
             ServerRegistry.ensure_started(supervisor, @agent, "first",
               server_registry: __MODULE__.Missing
             )

    assert {:error, :configured_stop} =
             ServerRegistry.ensure_started(
               supervisor,
               Spectre.ServerRegistryTest.StoppedAgent,
               "first",
               opts
             )

    assert DynamicSupervisor.count_children(supervisor).active == 0
  end
end
