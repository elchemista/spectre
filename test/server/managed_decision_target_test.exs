defmodule Spectre.Server.ManagedDecisionTargetTest do
  use ExUnit.Case, async: false

  alias Spectre.Server

  defmodule Effect do
    @behaviour Spectre.Server.GAM.EffectAdapter

    @impl true
    def execute_effect(:deliver, args, _context) do
      send(Spectre.Server.ManagedDecisionTargetTest, {:effect, args})
      {:ok, %{accepted: true}}
    end
  end

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :decision_target_test,
      version: "0.1.0",
      spectre: "~> 0.4.0"

    @impl true
    def effects(_) do
      %{
        deliver: %{
          contract: 1,
          adapter: Effect,
          operation: :deliver,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
        }
      }
    end
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule App do
    use Spectre.Server

    def handle_flow({:delivery, :send}, input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, on_result: :sent)

    def handle_flow(_, _, ctx), do: no_response(ctx)

    def handle_result(:sent, result, ctx) do
      send(Spectre.Server.ManagedDecisionTargetTest, {:completed, ctx.skill.id, result})
      no_response(ctx)
    end
  end

  defmodule Skill do
    use Spectre.Skill, id: :delivery, server: App

    flow :delivery do
      on(:send, regex: ~r/\Asend\z/, collect_intent: false)
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
    skill(Skill, as: :first, governed: [:deliver])
    skill(Skill, as: :second, governed: [:deliver])
  end

  setup do
    Process.register(self(), __MODULE__)

    server =
      start_supervised!(
        {Server,
         agent: Agent,
         consumer: self(),
         identity: %{subject: "decision-target-#{System.unique_integer([:positive])}"},
         gam: [
           storage: :ephemeral,
           operations: %{deliver: [confirm: true]}
         ]}
      )

    %{server: server}
  end

  for {label, wrong_target} <- [
        {"another active Skill", :second},
        {"an unknown Skill", :missing},
        {"the root without a pending request", nil}
      ] do
    test "targeting #{label} does not consume the real presentation", %{server: server} do
      first = shown_pending(server, :first)
      second = shown_pending(server, :second)

      assert {:error, _reason} =
               Server.decide(server, unquote(wrong_target), first.presentation.ref, :confirm)

      refute_receive {:effect, _}

      # The failed attempt must not mark this presentation as already authorized.
      assert {:ok, _} = Server.decide(server, :first, first.presentation.ref, :confirm)
      assert_receive {:effect, %{body: "send"}}, 5_000

      assert_receive {:completed, :first, {:governed, %{outcome: %{status: :succeeded}}}},
                     5_000

      assert {:error, _} = Server.decide(server, :first, first.presentation.ref, :confirm)
      refute_receive {:effect, _}

      # The other active request retains its own independently usable consent.
      assert {:ok, _} = Server.decide(server, :second, second.presentation.ref, :reject)
      assert_receive {:completed, :second, {:consent, :rejected}}, 5_000
      refute_receive {:effect, _}

      assert {:ok, view} = Server.gam_view(server)
      assert Enum.count(view.acts, &(&1.class != "presentation.show")) == 1
    end
  end

  test "a suspended Skill cannot keep an input caller waiting without a deadline", %{
    server: server
  } do
    assert {:ok, child} = Server.skill_server(server, :first)
    :ok = :sys.suspend(child)

    try do
      caller = Task.async(fn -> Server.input(server, "send", skill: :first) end)
      await_status_query(child)

      assert %{pending: _} = Server.status(server)
      assert {:ok, sibling} = Server.skill_server(server, :second)
      assert %{pending: _} = Server.status(sibling)
      assert {:error, {:skill_unavailable, _}} = Task.await(caller, 5_000)
      refute_receive {:effect, _}
    after
      :sys.resume(child)
    end
  end

  test "a Skill killed during the input query replies with an error and leaves its sibling usable",
       %{
         server: server
       } do
    assert {:ok, child} = Server.skill_server(server, :first)
    assert {:ok, sibling} = Server.skill_server(server, :second)
    :ok = :sys.suspend(child)
    monitor = Process.monitor(child)
    caller = Task.async(fn -> Server.input(server, "send", skill: :first) end)
    await_status_query(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 5_000
    assert {:error, {:skill_unavailable, _}} = Task.await(caller, 5_000)
    assert %{pending: _} = Server.status(server)
    assert %{pending: _} = Server.status(sibling)
    assert {:ok, view} = Server.gam_view(server)
    assert view.acts == []
    refute_receive {:effect, _}
  end

  test "a forged relay token returns an explicit error without dispatching input or consent", %{
    server: server
  } do
    assert {:ok, child} = Server.skill_server(server, :first)
    token = make_ref()

    for request <- [
          {:input, "send", [], nil},
          {:decision, "presentation:forged", :confirm, "forged-proof"}
        ] do
      assert {:error, :untrusted_consent_transport} =
               GenServer.call(child, {Spectre.Server.Runtime, :relay, token, request}, 1_000)
    end

    refute_receive {Server.GAM.Managed, _, {:presentation, _}}
    refute_receive {:effect, _}
    assert %{pending: []} = Server.status(child)
  end

  @spec await_status_query(pid(), non_neg_integer()) :: :ok
  defp await_status_query(child, attempts \\ 100)
  defp await_status_query(_child, 0), do: flunk("Skill did not receive its status query")

  defp await_status_query(child, attempts) do
    {:messages, messages} = Process.info(child, :messages)

    if Enum.any?(messages, fn
         {:"$gen_call", _, {Spectre.Server.Runtime, :status}} -> true
         _ -> false
       end) do
      :ok
    else
      receive do
      after
        5 -> await_status_query(child, attempts - 1)
      end
    end
  end

  test "a restarted Skill inherits diagnostic subscription and preserves the shared Domain", %{
    server: server
  } do
    assert :ok = Server.subscribe(server)
    assert {:ok, child} = Server.skill_server(server, :first)
    assert {:ok, sibling} = Server.skill_server(server, :second)
    root_bridge = :sys.get_state(server).gam
    assert :sys.get_state(child).gam == root_bridge
    assert :sys.get_state(sibling).gam == root_bridge
    assert {:error, :untrusted_audit_transport} = Server.inspect(child)
    assert {:error, :untrusted_audit_transport} = Server.subscribe(child)
    monitor = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, 5_000

    replacement = subscribed_replacement(server, child)
    assert :sys.get_state(replacement).gam == root_bridge
    assert :sys.get_state(server).gam == root_bridge
    assert Process.alive?(sibling)
    pending = shown_pending(server, :first)
    assert_receive {Server, ^server, {:diagnostics_changed, %{source: :gam}}}, 5_000
    assert {:ok, _} = Server.gam_inspect(server)
    assert {:ok, _} = Server.decide(server, :first, pending.presentation.ref, :reject)
    assert_receive {:completed, :first, {:consent, :rejected}}, 5_000
  end

  defp subscribed_replacement(server, old, attempts \\ 100)
  defp subscribed_replacement(_, _, 0), do: flunk("Skill subscription was not restored")

  defp subscribed_replacement(server, old, attempts) do
    case Server.skill_server(server, :first) do
      {:ok, child} when child != old ->
        if :sys.get_state(child).opts[:diagnostics_notifications] do
          child
        else
          Process.sleep(10)
          subscribed_replacement(server, old, attempts - 1)
        end

      _ ->
        Process.sleep(10)
        subscribed_replacement(server, old, attempts - 1)
    end
  end

  @spec shown_pending(GenServer.server(), atom()) :: map()
  defp shown_pending(server, skill) do
    assert {:ok, _} = Server.input(server, "send", skill: skill)
    assert_receive {Server.GAM.Managed, _, {:presentation, material}}, 5_000
    ref = material["presentation_ref"]
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:skill, ^skill, {:pending, _, pending_id}}}, 5_000
    assert {:ok, child} = Server.skill_server(server, skill)
    Enum.find(Server.status(child).pending, &(&1.id == pending_id))
  end
end
