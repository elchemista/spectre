Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.ManagedBrokerTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Secret.CheckoutReceipt
  alias Spectre.Server.GAM.Managed.{Broker, Executor, Store}
  alias Spectre.Server.Store.Disk

  setup c do
    secret = :crypto.strong_rand_bytes(32)
    now = System.system_time(:millisecond)

    claims =
      c.act
      |> CheckoutReceipt.binding(c.attempt, Broker.ref())
      |> Map.merge(%{
        domain_ref: c.f.refs.domain,
        ledger_revision: 1,
        issued_at: now - 1000,
        expires_at: now + 60_000
      })

    {:ok, capability} = CheckoutReceipt.mint(claims, secret)
    store = start_supervised!({Store, []})

    %{
      capability: capability,
      claims: claims,
      opts: [domain_ref: c.f.refs.domain, checkout_receipt_secret: secret, store: {Store, store}]
    }
  end

  test "unavailable Managed before adapter invocation has definitive no effect", c do
    {:ok, capability} = Broker.checkout(c.capability, c.act, c.attempt, c.opts)
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}

    assert {:error, :definitive_no_effect, %{evidence: [evidence]}} =
             Executor.execute(c.act, c.attempt, capability, broker: c.opts, managed: dead)

    assert evidence.payload == %{reason: :managed_execution_unavailable}
  end

  test "mediated broker claims then consumes exact authority once", c do
    assert Broker.profile() == :mediated
    assert {:ok, capability} = Broker.checkout(c.capability, c.act, c.attempt, c.opts)
    assert {:error, :ambiguous, _} = Broker.checkout(c.capability, c.act, c.attempt, c.opts)
    assert :ok = Broker.consume(capability, c.act, c.attempt, c.opts)

    assert {:error, :invalid_execution_capability} =
             Broker.consume(capability, c.act, c.attempt, c.opts)
  end

  test "unclaimed, forged, expired and substituted material cannot run", c do
    assert {:error, :invalid_execution_capability} =
             Broker.consume(c.capability, c.act, c.attempt, c.opts)

    forged = %{c.capability | mac: String.duplicate("0", 64)}
    assert {:error, :ambiguous, _} = Broker.checkout(forged, c.act, c.attempt, c.opts)

    changed = %{c.act | consequence: Map.put(c.act.consequence, "amount", 999)}
    assert {:error, :ambiguous, _} = Broker.checkout(c.capability, changed, c.attempt, c.opts)

    claims = %{c.claims | issued_at: 1000, expires_at: 2000}
    {:ok, expired} = CheckoutReceipt.mint(claims, c.opts[:checkout_receipt_secret])
    assert {:error, :ambiguous, _} = Broker.checkout(expired, c.act, c.attempt, c.opts)

    assert {:error, :ambiguous, _} = Executor.execute(c.act, c.attempt, :anything, broker: c.opts)
  end

  test "changed attempt or Act after checkout is rejected without consuming valid capability",
       c do
    assert {:ok, capability} = Broker.checkout(c.capability, c.act, c.attempt, c.opts)
    changed = %{c.attempt | generation: c.attempt.generation + 1}

    assert {:error, :invalid_execution_capability} =
             Broker.consume(capability, c.act, changed, c.opts)

    changed_act = %{c.act | authorizer_ref: "another-authorizer"}

    assert {:error, :invalid_execution_capability} =
             Broker.consume(capability, changed_act, c.attempt, c.opts)

    assert :ok = Broker.consume(capability, c.act, c.attempt, c.opts)
  end

  @tag :tmp_dir
  test "consumed disk capability cannot be checked out or replayed after store restart", c do
    path = Path.join(c.tmp_dir, "claims.store")
    {:ok, store} = Disk.start_link(path: path)
    opts = Keyword.put(c.opts, :store, {Disk, store})
    assert {:ok, capability} = Broker.checkout(c.capability, c.act, c.attempt, opts)
    assert :ok = Broker.consume(capability, c.act, c.attempt, opts)
    GenServer.stop(store)

    {:ok, reopened} = Disk.start_link(path: path)
    on_exit(fn -> if Process.alive?(reopened), do: GenServer.stop(reopened) end)
    opts = Keyword.put(opts, :store, {Disk, reopened})
    assert {:error, :ambiguous, _} = Broker.checkout(capability, c.act, c.attempt, opts)

    assert {:error, :invalid_execution_capability} =
             Broker.consume(capability, c.act, c.attempt, opts)
  end

  test "parallel execution consumes a capability at most once", c do
    assert {:ok, capability} = Broker.checkout(c.capability, c.act, c.attempt, c.opts)

    results =
      1..12
      |> Task.async_stream(fn _ -> Broker.consume(capability, c.act, c.attempt, c.opts) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_execution_capability})) == 11
  end
end
