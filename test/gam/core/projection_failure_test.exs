Code.require_file("../helper.exs", __DIR__)
Code.require_file("../support/projection_store.ex", __DIR__)

defmodule Spectre.GAM.Core.ProjectionFailureTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.Domain.{Projection, Sequencer}
  alias Spectre.GAM.Test.ProjectionStore
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule FailingStore do
    @behaviour Spectre.GAM.Domain.Projection.Store

    def open(domain, opts), do: call(:open, [domain], opts)
    def head(domain, opts), do: call(:head, [domain], opts)

    def commit(handle, before, next, changes, opts),
      do: call(:commit, [handle, before, next, changes], opts)

    def fetch(handle, cursor, keys, opts), do: call(:fetch, [handle, cursor, keys], opts)

    def page(handle, cursor, collection, opts),
      do: call(:page, [handle, cursor, collection], opts)

    def select(handle, cursor, collection, selection, opts),
      do: call(:select, [handle, cursor, collection, selection], opts)

    defp call(operation, args, opts) do
      case Agent.get(opts[:fault], & &1) do
        ^operation -> {:error, {:projection_offline, operation}}
        {:raise, ^operation} -> raise "private storage connection detail"
        _ -> apply(ProjectionStore, operation, args ++ [opts])
      end
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    {:ok, fault} = Agent.start_link(fn -> nil end)
    {:ok, storage} = ProjectionStore.start_link()
    f = Fixture.start_domain(projection_store: {FailingStore, server: storage, fault: fault})
    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, fault: fault}
  end

  test "projection failures during cold recovery cannot replace canonical history", c do
    Process.flag(:trap_exit, true)
    snapshot = Fixture.snapshot(c.f)
    Fixture.stop_process(c.f.server)

    for operation <- [:open, :page, :select, :fetch, :commit] do
      Agent.update(c.fault, fn _ -> operation end)

      assert {:error, {:projection_offline, ^operation}} =
               Sequencer.start_link(c.f.sequencer_opts)

      assert Fixture.snapshot(c.f) == snapshot
    end

    Agent.update(c.fault, fn _ -> nil end)
    recovered = Fixture.restart_domain(c.f)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert {:ok, expected} = Projection.replay(snapshot, c.f.constitution)
    assert Sequencer.projection(recovered.server) == expected
  end

  test "temporary read failures preserve the verified prefix and recover without replacing the owner",
       c do
    paid = Fixture.paid_evidence(c.f)
    assert {:ok, ^paid} = Fixture.observe_payment(c.f, paid)

    {:ok, scope} =
      Spectre.GAM.Scope.new(
        Spectre.GAM.Domain.handle(c.f.server, c.f.refs.domain),
        Fixture.context(c.f)
      )

    {:ok, head} = Sequencer.head(c.f.server)
    snapshot = Fixture.snapshot(c.f)
    request = {:query, scope, {:selected_view, %{evidence_refs: [paid.ref]}}}

    for fault <- [:page, :select, :fetch, {:raise, :fetch}] do
      Agent.update(c.fault, fn _ -> fault end)
      query = if fault == :page, do: :projection, else: request
      assert {:error, reason} = GenServer.call(c.f.server, query)
      refute inspect(reason) =~ "private storage connection detail"
      assert {:ok, ^head} = Sequencer.head(c.f.server)
      assert Fixture.snapshot(c.f) == snapshot
    end

    Agent.update(c.fault, fn _ -> nil end)
    assert {:ok, view} = GenServer.call(c.f.server, request)
    assert paid in view.evidence
  end

  test "a failed projection publication after durable admission releases no grant and replays exactly once",
       c do
    Process.flag(:trap_exit, true)
    paid = Fixture.paid_evidence(c.f)
    assert {:ok, ^paid} = Fixture.observe_payment(c.f, paid)
    context = Fixture.context(c.f)
    candidate = Fixture.refund_candidate(c.f, 10, evidence_refs: [paid.ref])
    {:ok, before} = Sequencer.head(c.f.server)
    monitor = Process.monitor(c.f.server)
    Agent.update(c.fault, fn _ -> :commit end)

    assert {:error, {:durable_recovery_failed, {:projection_offline, :commit}}} =
             Sequencer.submit(c.f.server, context, candidate)

    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    snapshot = Fixture.snapshot(c.f)
    assert snapshot.revision > before.revision
    refute Enum.any?(snapshot.entries, &(&1.payload["type"] == "attempt_started"))

    Agent.update(c.fault, fn _ -> nil end)
    recovered = Fixture.restart_domain(c.f)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(recovered.server, Fixture.context(recovered), candidate)

    refute is_nil(grant)
    assert Enum.count(Fixture.snapshot(c.f).entries, &(&1.payload["identity"] == act.ref)) == 1
    assert {:ok, expected} = Projection.replay(Fixture.snapshot(c.f), c.f.constitution)
    assert Sequencer.projection(recovered.server) == expected
  end
end
