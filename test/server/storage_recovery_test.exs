defmodule Spectre.Server.StorageRecoveryTest do
  use ExUnit.Case, async: false
  alias Spectre.Server

  defmodule Policy do
    @behaviour Spectre.GAM.Domain.Recovery.Policy
    def check(_, _), do: :ok

    def recover(incident, opts) do
      send(opts[:observer], {:storage_incident, incident})
      :memory
    end
  end

  defmodule MissingStore do
    @behaviour Server.Store
    def fetch(_, _), do: {:error, :offline}
    def put_new(_, _, _), do: {:error, :offline}
    def compare_and_swap(_, _, _, _), do: {:error, :offline}
    def delete(_, _, _), do: {:error, :offline}
    def gam_domain(_), do: {:error, :offline}
  end

  defmodule App do
    use Spectre.Server

    def handle_flow(:unmatched, %{text: "run"}, ctx),
      do: propose(ctx, :run, %{}, on_result: :ran)

    def handle_flow(:unmatched, input, ctx), do: respond(ctx, input.text)
    def handle_cast(:run, ctx), do: {:noreply, propose(ctx, :run, %{}, on_result: :ran)}

    def handle_result(:ran, result, ctx) do
      send(Spectre.Server.StorageRecoveryTest, {:effect_result, result})
      no_response(ctx)
    end
  end

  defmodule Effect do
    def execute_effect(:run, _, _) do
      send(Spectre.Server.StorageRecoveryTest, :effect_executed)
      {:ok, %{completed: true}}
    end
  end

  defmodule Effects do
    use Spectre.Stack.Installable, id: :recovery_effect, version: "0.1.0", spectre: "~> 0.4.0"

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

  test "the complete RAM mode needs no Ledger or database" do
    server = start_supervised!({Server, agent: Definition, consumer: self()})
    assert {:ok, _} = Server.input(server, "in memory")
    assert_receive {Server, ^server, {:response, _, "in memory", _}}, 5_000
    managed = :sys.get_state(:sys.get_state(server).managed_owner)
    assert managed.ephemeral
    assert Map.get(managed, :projection_store) == nil
  end

  test "an explicit host policy can start in RAM when the configured store is absent" do
    server =
      start_supervised!(
        {Server,
         agent: Definition,
         consumer: self(),
         identity: %{subject: "survives-storage-loss"},
         gam: [
           storage: :ledger,
           store: {MissingStore, :offline},
           recovery_policy: {Policy, observer: self()}
         ]}
      )

    assert_receive {:storage_incident, %{phase: :startup, reason: :offline}}
    assert {:ok, _} = Server.input(server, "still working")
    assert_receive {Server, ^server, {:response, _, "still working", _}}, 5_000
    state = :sys.get_state(server)
    assert state.identity.subject == "survives-storage-loss"
    assert :sys.get_state(state.managed_owner).ephemeral
  end

  test "a consumer can recover to a fresh RAM Domain without replacing the agent" do
    server = start_supervised!({Server, agent: Definition, consumer: self()})
    state = :sys.get_state(server)
    owner = state.managed_owner
    previous = :sys.get_state(owner)

    assert {:error, :untrusted_storage_recovery} =
             Task.async(fn -> Server.recover_storage(server, :memory) end) |> Task.await()

    assert :ok = Server.recover_storage(server, :memory)

    assert_receive {Server, ^server,
                    {:storage_recovered, %{previous_domain: old, domain: fresh}}},
                   5_000

    assert old == previous.refs.domain
    refute fresh == old
    assert :sys.get_state(server).managed_owner == owner
    assert :sys.get_state(server).identity == state.identity
    refute Process.alive?(previous.domain)
    assert {:ok, _} = Server.input(server, "new domain")
    assert_receive {Server, ^server, {:response, _, "new domain", _}}, 5_000
  end

  test "mounted Skills use the new RAM checkpoint, including after a child restart" do
    server = start_supervised!({Server, agent: SkilledDefinition, consumer: self()})
    root = :sys.get_state(server)
    {:ok, child} = Server.Skills.lookup(root.skill_supervisor, :echo)
    old_checkpoint = :sys.get_state(child).opts[:checkpoint]
    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, _}}, 5_000
    assert_receive {Server, ^server, {:skill, :echo, {:storage_recovered, _}}}, 5_000
    current_checkpoint = :sys.get_state(child).opts[:checkpoint]
    refute current_checkpoint == old_checkpoint
    assert :ok = Supervisor.terminate_child(root.skill_supervisor, :echo)
    assert {:ok, restarted} = Supervisor.restart_child(root.skill_supervisor, :echo)
    assert :sys.get_state(restarted).opts[:checkpoint] == current_checkpoint
    assert {:ok, _} = Server.input(server, "skill after recovery", skill: :echo)

    assert_receive {Server, ^server, {:skill, :echo, {:response, _, "skill after recovery", _}}},
                   5_000
  end

  test "root and Skill checkpoint acquisition survive the old store closing before the recovery notice" do
    server = start_supervised!({Server, agent: SkilledDefinition, consumer: self()})
    root = :sys.get_state(server)
    {:ok, child} = Server.Skills.lookup(root.skill_supervisor, :echo)
    previous = :sys.get_state(child)
    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, %{domain: domain}}}, 5_000
    assert_receive {Server, ^server, {:skill, :echo, {:storage_recovered, _}}}, 5_000

    # Deterministically reproduce a save queued before the notice: both runtimes
    # still hold the previous binding, whose owned Store is already closed.
    for {pid, old} <- [{server, root}, {child, previous}] do
      current = :sys.get_state(pid)
      {module, store, key} = current.opts[:checkpoint]
      assert :ok = module.delete(store, key, current.checkpoint_revision)

      :sys.replace_state(pid, fn state ->
        opts =
          Keyword.merge(state.opts, Keyword.take(old.opts, [:checkpoint, :checkpoint_domain]))

        %{state | opts: opts, checkpoint_revision: old.checkpoint_revision}
      end)
    end

    assert {:ok, _} = Server.input(server, "root survives")
    assert_receive {Server, ^server, {:response, _, "root survives", _}}, 5_000
    assert {:ok, _} = Server.input(server, "skill survives", skill: :echo)
    assert_receive {Server, ^server, {:skill, :echo, {:response, _, "skill survives", _}}}, 5_000
    assert Spectre.Server.GAM.Managed.info(root.managed_owner).domain == domain
    assert elem(:sys.get_state(server).opts[:checkpoint_domain], 1) == domain
    assert elem(:sys.get_state(child).opts[:checkpoint_domain], 1) == domain
  end

  @tag :tmp_dir
  test "disk recovery keeps the running Server's coordination owner", %{tmp_dir: path} do
    server =
      start_supervised!(
        {Server,
         agent: Definition,
         consumer: self(),
         identity: %{subject: "disk-recovery"},
         gam: [storage: {:disk, path}]}
      )

    assert {:ok, _} = Server.input(server, "before retry")
    assert_receive {Server, ^server, {:response, _, "before retry", _}}, 5_000
    previous = :sys.get_state(server)
    before = Spectre.Server.GAM.Managed.info(previous.managed_owner)
    assert :ok = Server.recover_storage(server, :retry)

    assert_receive {Server, ^server, {:storage_recovered, %{previous_domain: old, domain: old}}},
                   5_000

    assert old == before.domain
    assert :sys.get_state(server).opts[:checkpoint] == previous.opts[:checkpoint]
    assert {:ok, _} = Server.input(server, "after retry")
    assert_receive {Server, ^server, {:response, _, "after retry", _}}, 5_000
  end

  test "a command discovering the reset stays blocked before execution; fresh work can proceed" do
    Process.register(self(), __MODULE__)

    server =
      start_supervised!(
        {Server, agent: Definition, consumer: self(), gam: [operations: %{run: [confirm: false]}]}
      )

    previous = :sys.get_state(server)
    assert :ok = Server.recover_storage(server, :memory)
    assert_receive {Server, ^server, {:storage_recovered, _}}, 5_000
    current = :sys.get_state(server)
    {module, store, key} = current.opts[:checkpoint]
    assert :ok = module.delete(store, key, current.checkpoint_revision)

    :sys.replace_state(server, fn state ->
      opts =
        Keyword.merge(state.opts, Keyword.take(previous.opts, [:checkpoint, :checkpoint_domain]))

      %{state | opts: opts, checkpoint_revision: previous.checkpoint_revision}
    end)

    GenServer.cast(server, :run)
    assert_receive {Server, ^server, {:storage_recovered, _}}, 5_000

    assert Enum.any?(:sys.get_state(server).outbox, fn {_, entry} ->
             match?({:domain_reset, _}, Map.get(entry, :blocked_by))
           end)

    refute_receive :effect_executed
    assert {:ok, _} = Server.input(server, "run")
    assert_receive :effect_executed, 5_000
    assert_receive {:effect_result, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
  end
end
