defmodule Spectre.Core.PayloadIncrementalRecoveryTest.Payloads do
  @behaviour Spectre.Payload.Store
  alias Spectre.Portable

  @impl true
  def verify(ref, opts) do
    table = Keyword.fetch!(opts, :table)
    :ets.update_counter(table, {:calls, ref}, {2, 1}, {{:calls, ref}, 0})

    case :ets.lookup(table, {:payload, ref}) do
      [{{:payload, ^ref}, body}] ->
        if Portable.content_ref!(:payload, body) === ref, do: :ok, else: {:error, :corrupt}

      [] ->
        {:error, :not_found}
    end
  end
end

defmodule Spectre.Core.PayloadIncrementalRecoveryTest do
  use ExUnit.Case, async: false

  alias Spectre.Core.PayloadIncrementalRecoveryTest.Payloads
  alias Spectre.Domain.{Configuration, Projection, Sequencer, Startup, Transaction}
  alias Spectre.Ledger.Store.Mock
  alias Spectre.Portable
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    table = :ets.new(__MODULE__, [:set, :public])
    f = Fixture.start_domain(payload_store: {Payloads, table: table}, mock_store: true)
    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, table: table}
  end

  test "thirty external observations perform sixty verifications, not 495", c do
    refs =
      for n <- 1..30 do
        {ref, evidence} = observe(c, "payload-#{n}", "unrelated-#{n}")
        assert evidence.payload_ref === ref
        assert calls(c, ref) === 2
        ref
      end

    assert Enum.map(refs, &calls(c, &1)) === List.duplicate(2, 30)
    assert Enum.sum(Enum.map(refs, &calls(c, &1))) === 60
  end

  test "unrelated writes do not poll old payloads, but cold recovery detects their disappearance",
       c do
    {old_ref, _} = observe(c, "old body", "unrelated-old")
    :ets.delete(c.table, {:payload, old_ref})
    {new_ref, _} = observe(c, "new body", "unrelated-new")
    assert calls(c, old_ref) === 2
    assert calls(c, new_ref) === 2
    assert {:ok, config} = Configuration.new(c.f.sequencer_opts)
    assert {:error, {:unexpected_missing_payload, ^old_ref}} = Startup.load(config)
  end

  @tag capture_log: true
  test "a disappeared old payload still blocks a Grant when that Evidence is used", c do
    {ref, evidence} = observe(c, "payment", "order.paid:" <> c.f.refs.order)
    # Use the fixture's exact condition proposition and bindings.
    assert {:ok, paid} =
             Fixture.paid_evidence(c.f, %{payload: nil, payload_ref: ref})
             |> then(fn paid -> Fixture.observe_payment(c.f, paid) end)

    assert paid.payload_ref === evidence.payload_ref
    :ets.delete(c.table, {:payload, ref})
    candidate = Fixture.refund_candidate(c.f, 10, evidence_refs: [paid.ref])

    context = Fixture.context(c.f)
    Process.unlink(c.f.server)
    monitor = Process.monitor(c.f.server)

    assert {:error, {:durable_recovery_failed, {:unexpected_missing_payload, ^ref}}} =
             Sequencer.submit(c.f.server, context, candidate)

    assert_receive {:DOWN, ^monitor, :process, _, _}

    assert {:ok, recovered} =
             Projection.replay(Fixture.snapshot(c.f), c.f.constitution)

    assert recovered.attempts === %{}
  end

  test "incremental catch-up verifies only the actual new refs on native and fallback adapters",
       c do
    {old, _} = observe(c, "prefix", "unrelated-prefix")
    prefix = :sys.get_state(c.f.server)
    {new, _} = observe(c, "suffix", "unrelated-suffix")
    final = Sequencer.projection(c.f.server)
    :ets.delete(c.table, {:payload, old})

    for store <- [c.f.store_config, {Spectre.Ledger.Store.ETS, server: c.f.store}] do
      assert {:ok, ^final} = Transaction.recover_verified(%{prefix | store: store})
    end

    assert calls(c, old) === 2
    assert calls(c, new) === 4
    :ets.delete(c.table, {:payload, new})
    assert {:error, {:unexpected_missing_payload, ^new}} = Transaction.recover_verified(prefix)
  end

  test "ambiguous acknowledgement checks recovered new refs without rereading old bodies", c do
    {old, _} = observe(c, "old", "unrelated-old")
    assert :ok = Mock.push(c.f.mock, {:append, :after, {:error, :ambiguous}})
    {new, _} = observe(c, "new", "unrelated-new")
    assert calls(c, old) === 2
    assert calls(c, new) === 2
  end

  defp observe(c, body, proposition) do
    ref = Portable.content_ref!(:payload, body)
    :ets.insert(c.table, {{:payload, ref}, body})

    evidence =
      Fixture.paid_evidence(c.f, %{proposition: proposition, payload: nil, payload_ref: ref})

    assert {:ok, ^evidence} = Fixture.observe_payment(c.f, evidence)
    {ref, evidence}
  end

  defp calls(c, ref) do
    [{{:calls, ^ref}, n}] = :ets.lookup(c.table, {:calls, ref})
    n
  end
end
