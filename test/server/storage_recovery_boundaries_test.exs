defmodule Spectre.Server.StorageRecoveryBoundariesTest do
  use ExUnit.Case, async: false

  alias Spectre.Server
  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.Runtime

  defmodule App do
    use Spectre.Server

    def handle_flow(:unmatched, %{text: "run " <> label}, ctx),
      do: propose(ctx, :run, %{label: label}, on_result: :ran)

    def handle_flow(:unmatched, input, ctx), do: respond(ctx, input.text)

    def handle_result(:ran, result, ctx) do
      send(Spectre.Server.StorageRecoveryBoundariesTest, {:effect_result, result})
      no_response(ctx)
    end
  end

  defmodule Effect do
    def execute_effect(:run, arguments, _) do
      send(Spectre.Server.StorageRecoveryBoundariesTest, {:effect_executed, arguments})
      {:ok, %{completed: true}}
    end
  end

  defmodule Effects do
    use Spectre.Stack.Installable,
      id: :storage_recovery_boundary,
      version: "0.1.0",
      spectre: "~> 0.4.0"

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

  defmodule Definition do
    use Spectre.Agent, server: App, stack: Stack
  end

  defmodule EchoSkill do
    use Spectre.Skill, id: :echo, server: App
  end

  defmodule SkilledDefinition do
    use Spectre.Agent, server: App, stack: Stack
    skill(EchoSkill, as: :echo)
  end

  defmodule ControlledRetry do
    @behaviour Spectre.GAM.Domain.Recovery.Policy

    def check(_, _), do: :ok

    def recover(incident, opts) do
      observer = opts[:observer]
      monitor = Process.monitor(observer)
      send(observer, {:storage_retry_incident, self(), incident})

      receive do
        {:recover, decision} ->
          Process.demonitor(monitor, [:flush])
          decision

        {:DOWN, ^monitor, :process, ^observer, _} ->
          :wait
      end
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  test "reset invalidates a displayed consent while preserving the agent and allowing fresh approval" do
    server =
      start_supervised!(
        {Server,
         agent: Definition,
         consumer: self(),
         identity: %{subject: "pending-consent-reset"},
         gam: [consent_ttl_ms: 60_000, operations: %{run: [confirm: true]}]}
      )

    assert {:ok, _} = Server.input(server, "run old")
    old_ref = presentation()
    assert :ok = Server.presented(server, old_ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    previous = :sys.get_state(server)
    pending_id = previous.foreground
    assert previous.pending[pending_id].kind == :consent

    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, %{domain: fresh}}}, 5_000
    current = :sys.get_state(server)
    assert current.managed_owner == previous.managed_owner
    assert current.identity == previous.identity
    assert current.foreground == nil
    assert current.pending[pending_id].status == :uncertain
    assert Managed.info(current.managed_owner).domain == fresh
    assert {:error, :stale_presentation} = Server.decide(server, nil, old_ref, :confirm)
    refute_receive {:effect_executed, _}

    assert {:ok, _} = Server.input(server, "run fresh")
    new_ref = presentation()
    refute new_ref == old_ref
    assert :ok = Server.presented(server, new_ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, new_ref, :confirm)
    assert_receive {:effect_executed, %{label: "fresh"}}, 5_000
    assert_receive {:effect_result, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    refute_receive {:effect_executed, %{label: "old"}}
  end

  test "a Skill independently rebinds a retired checkpoint before receiving its recovery notice" do
    server = start_supervised!({Server, agent: SkilledDefinition, consumer: self()})
    root = :sys.get_state(server)
    {:ok, child} = Server.Skills.lookup(root.skill_supervisor, :echo)
    previous = :sys.get_state(child)
    {_, old_store, _} = previous.opts[:checkpoint]
    retired = Process.monitor(old_store)

    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, %{domain: fresh}}}, 5_000
    assert_receive {Server, ^server, {:skill, :echo, {:storage_recovered, _}}}, 5_000
    assert_receive {:DOWN, ^retired, :process, ^old_store, _}, 5_000
    root_checkpoint = :sys.get_state(server).opts[:checkpoint]
    current = :sys.get_state(child)
    {module, store, key} = current.opts[:checkpoint]
    assert :ok = module.delete(store, key, current.checkpoint_revision)

    # Recreate only the child's binding before its notification. The parent
    # already uses the new Store, so it cannot repair the child by rebinding.
    :sys.replace_state(child, fn state ->
      opts =
        Keyword.merge(state.opts, Keyword.take(previous.opts, [:checkpoint, :checkpoint_domain]))

      %{state | opts: opts, checkpoint_revision: previous.checkpoint_revision}
    end)

    assert {:ok, _} = Server.input(server, "child saves first", skill: :echo)

    assert_receive {Server, ^server,
                    {:skill, :echo,
                     {:storage_recovered, %{previous_domain: previous_domain, domain: ^fresh}}}},
                   5_000

    assert previous_domain == elem(previous.opts[:checkpoint_domain], 1)

    assert_receive {Server, ^server, {:skill, :echo, {:response, _, "child saves first", _}}},
                   5_000

    restored = :sys.get_state(child)
    assert restored.managed_owner == nil
    assert restored.opts[:checkpoint] == current.opts[:checkpoint]
    assert elem(restored.opts[:checkpoint_domain], 1) == fresh
    assert :sys.get_state(server).opts[:checkpoint] == root_checkpoint
    assert Managed.info(root.managed_owner).domain == fresh
    assert {:ok, _} = Server.inspect(server, skill: :echo)
    assert {:ok, _} = Server.trace(server, "missing-interaction", skill: :echo)
    refute_receive {Server, ^server, {:storage_recovered, _}}
  end

  test "a duplicate recovery notice preserves the checkpoint and work acquired in the new Domain" do
    server = start_supervised!({Server, agent: Definition, consumer: self()})
    before = :sys.get_state(server)
    old_domain = Managed.info(before.managed_owner).domain
    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, %{domain: fresh}}}, 5_000
    assert {:ok, _} = Server.input(server, "new history")
    assert_receive {Server, ^server, {:response, _, "new history", _}}, 5_000
    current = settled_runtime(server)

    send(
      server,
      {Runtime, current.control, :gam_storage_recovered,
       %{checkpoint: current.opts[:checkpoint], previous_domain: old_domain, domain: fresh}}
    )

    unchanged = :sys.get_state(server)
    assert unchanged.checkpoint_revision == current.checkpoint_revision
    assert unchanged.history == current.history
    assert unchanged.opts[:checkpoint] == current.opts[:checkpoint]
    assert Managed.info(unchanged.managed_owner).domain == fresh
    refute_receive {Server, ^server, {:storage_recovered, _}}
    assert {:ok, _} = Server.input(server, "after duplicate")
    assert_receive {Server, ^server, {:response, _, "after duplicate", _}}, 5_000
  end

  @tag :tmp_dir
  test "repeated failed retries preserve the agent and journal until disk repair", %{
    tmp_dir: path
  } do
    server =
      start_supervised!(
        {Server,
         agent: Definition,
         consumer: self(),
         identity: %{subject: "retry-profile-repair"},
         gam: [
           storage: {:disk, path},
           operations: %{run: [confirm: false]},
           recovery_policy: {ControlledRetry, observer: self()}
         ]}
      )

    root = settled_runtime(server)
    owner = root.managed_owner
    previous = :sys.get_state(owner)
    retired = Process.monitor(previous.domain)
    {_, journal} = previous.journal
    profile_path = Path.join(path, "authority.profile")
    profile = File.read!(profile_path)
    [digest | _] = String.split(profile, "\n")
    File.write!(profile_path, digest <> "\ninvalid\n")

    assert :ok = Server.recover_storage(server, :retry)

    assert_receive {:storage_retry_incident, first,
                    %{phase: :runtime, reason: :invalid_managed_authority_profile}},
                   5_000

    assert_receive {:DOWN, ^retired, :process, _, _}, 5_000
    assert %{busy: false, workers: 0, outbox_size: 0} = Server.status(server)
    assert :sys.get_state(server).managed_owner == owner
    assert Process.alive?(journal)
    {:links, first_links} = Process.info(owner, :links)
    send(first, {:recover, {:retry, 0}})

    assert_receive {:storage_retry_incident, second,
                    %{phase: :runtime, reason: :invalid_managed_authority_profile}},
                   5_000

    refute second == first
    {:links, second_links} = Process.info(owner, :links)
    assert MapSet.new(second_links) == MapSet.new(first_links)
    assert :sys.get_state(server).managed_owner == owner
    assert Process.alive?(journal)

    File.write!(profile_path, profile)
    send(second, {:recover, {:retry, 0}})
    domain = previous.refs.domain

    assert_receive {Server, ^server,
                    {:storage_recovered, %{previous_domain: ^domain, domain: ^domain}}},
                   5_000

    recovered = :sys.get_state(owner)
    assert recovered.journal == previous.journal
    refute recovered.domain == previous.domain
    assert :sys.get_state(server).opts[:checkpoint] == root.opts[:checkpoint]
    assert :sys.get_state(server).identity == root.identity
    assert {:ok, _} = Server.input(server, "run repaired")
    assert_receive {:effect_executed, %{label: "repaired"}}, 5_000
    assert_receive {:effect_result, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
  end

  test "bounded diagnostic readers fail independently and close releases their callers" do
    owner = start_supervised!({Managed, agent: Definition, runtime: self(), consumer: self()})
    domain = :sys.get_state(owner).domain
    :ok = :sys.suspend(domain)

    failed_request = :gen_server.send_request(owner, {:diagnostics, [], self()})
    [{_, first}] = Map.to_list(:sys.get_state(owner).diagnostic_reads)
    Process.exit(first.pid, :kill)

    assert {:reply, {:error, :diagnostic_source_unavailable}} =
             :gen_server.receive_response(failed_request, 5_000)

    assert Process.alive?(owner)

    requests =
      for _ <- 1..4,
          do: :gen_server.send_request(owner, {:diagnostics, [], self()})

    reads = :sys.get_state(owner).diagnostic_reads
    assert map_size(reads) == 4
    assert {:error, :diagnostic_source_unavailable} = Managed.diagnostics(owner, [], self())
    assert {:ok, _} = GenServer.call(owner, :checkout, 250)
    GenServer.cast(owner, {:checkin, self()})

    # Closing releases every outstanding caller even while the Domain cannot
    # answer, without waiting for each reader's individual timeout.
    assert :ok = Managed.close(owner)

    for request <- requests do
      assert {:reply, {:error, :diagnostic_source_unavailable}} =
               :gen_server.receive_response(request, 5_000)
    end

    refute Process.alive?(owner)
    refute Process.alive?(domain)
    assert :ok = Managed.close(owner)

    assert {:error, :managed_gate_unavailable} =
             Managed.approval_reply(owner, "closed-request", :confirm, self())
  end

  test "shutdown has a bounded drain even if an acquired worker never checks in" do
    owner =
      start_supervised!(
        {Managed, agent: Definition, runtime: self(), consumer: self(), shutdown_timeout: 100}
      )

    assert {:ok, _} = GenServer.call(owner, :checkout)
    monitor = Process.monitor(owner)
    close_request = :gen_server.send_request(owner, :close)
    assert {:error, :managed_domain_closing} = GenServer.call(owner, :checkout)

    assert {:reply, {:error, :shutdown_drain_timeout}} =
             :gen_server.receive_response(close_request, 5_000)

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    refute Process.alive?(owner)
  end

  test "RAM recovery rejects retry and direct untrusted recovery leaves the Domain unchanged" do
    server = start_supervised!({Server, agent: Definition, consumer: self()})
    owner = :sys.get_state(server).managed_owner
    before = Managed.info(owner)
    assert {:error, :untrusted_storage_recovery} = Managed.recover_storage(owner, :memory)
    assert {:error, :untrusted_audit_transport} = Managed.view(owner)
    assert {:error, :untrusted_audit_transport} = Managed.diagnostics(owner, [], self())

    assert {:error, :ephemeral_history_cannot_be_recovered} =
             Server.recover_storage(server, :retry)

    assert Managed.info(owner) == before
    assert {:ok, _} = Server.input(server, "after refused recovery")
    assert_receive {Server, ^server, {:response, _, "after refused recovery", _}}, 5_000
  end

  defp settled_runtime(server) do
    state = :sys.get_state(server)

    case Map.values(state.workers) do
      [] ->
        assert state.current == nil
        assert :queue.is_empty(state.queue)
        assert state.outbox == %{}
        state

      workers ->
        # The response precedes the detached memory acquisition. Worker exit
        # followed by another state read also waits for its result to be
        # consumed and checkpointed, without relying on a timing window.
        Enum.each(workers, &await_worker/1)
        settled_runtime(server)
    end
  end

  defp await_worker(%{pid: pid}) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end
  end

  defp presentation do
    assert_receive {Managed, _owner, {:presentation, material}}, 5_000
    material["presentation_ref"]
  end
end
