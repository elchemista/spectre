defmodule Spectre.Server.ManagedRevocationTest do
  use ExUnit.Case, async: false

  alias Spectre.Server

  defmodule Effect do
    @behaviour Spectre.Server.GAM.EffectAdapter
    @impl true
    def execute_effect(:deliver, args, _context) do
      send(Spectre.Server.ManagedRevocationTest, {:effect, args})
      {:ok, %{delivered: true}}
    end
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :revocation_test, version: "0.1.0", spectre: "~> 0.4.0"

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

    def handle_flow(:unmatched, input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, on_result: :sent)

    def handle_result(:sent, result, ctx) do
      send(Spectre.Server.ManagedRevocationTest, {:completed, result})
      no_response(ctx)
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  defp options(extra \\ []) do
    [
      agent: Agent,
      identity: %{subject: "revoke-#{System.unique_integer([:positive])}"},
      consumer: self(),
      gam: Keyword.merge([operations: %{deliver: []}], extra)
    ]
  end

  test "only the trusted root consumer can revoke and subsequent effects are refused" do
    server = start_supervised!({Server, options()})

    assert {:error, :untrusted_governance_transport} =
             Task.async(fn -> Spectre.GAM.revoke(server) end) |> Task.await()

    assert {:ok, _} = Server.input(server, "before")
    assert_receive {:effect, %{body: "before"}}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000

    assert {:ok, result} = Spectre.GAM.revoke(server)
    assert result.primary.decision.outcome == :admitted
    assert result.primary.act.class == "mandate.revoke"
    assert is_nil(result.primary.attempt)
    assert {:ok, repeat} = Spectre.GAM.revoke(server)
    assert repeat.primary.act == result.primary.act

    assert {:ok, _} = Server.input(server, "after")
    assert_receive {:completed, {:governed, %{decision: %{outcome: :refused}, act: nil}}}, 5_000
    refute_receive {:effect, _}

    assert {:ok, view} = Server.gam_view(server)
    assert Enum.count(view.acts, &(&1.class == "mandate.revoke")) == 1
  end

  @tag :tmp_dir
  test "revocation survives restart without replacing its genesis or prior effect history", %{
    tmp_dir: path
  } do
    opts = options(storage: {:disk, path})
    {:ok, server} = Server.start_link(opts)
    assert {:ok, _} = Server.input(server, "before restart")
    assert_receive {:effect, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    assert {:ok, revoked} = Spectre.GAM.revoke(server)
    GenServer.stop(server)

    {:ok, restarted} = Server.start_link(opts)
    on_exit(fn -> Spectre.Test.Processes.stop(restarted) end)
    assert {:ok, view} = Server.gam_view(restarted)
    assert Enum.any?(view.acts, &(&1.ref == revoked.primary.act.ref))
    assert {:ok, _} = Server.input(restarted, "after restart")
    assert_receive {:completed, {:governed, %{decision: %{outcome: :refused}, act: nil}}}, 5_000
    refute_receive {:effect, _}
  end

  test "the managed owner does not expose revocation to an unrelated actor" do
    server = start_supervised!({Server, options()})
    managed = :sys.get_state(server).managed_owner
    assert {:error, :untrusted_governance_transport} = Server.GAM.Managed.revoke(managed)
  end
end
