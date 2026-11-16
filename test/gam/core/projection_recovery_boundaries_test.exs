Code.require_file("../helper.exs", __DIR__)
Code.require_file("../support/projection_store.ex", __DIR__)

defmodule Spectre.GAM.Core.ProjectionRecoveryBoundariesTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.Domain.{Configuration, Event, Projection, Startup, Transaction}
  alias Spectre.GAM.Portable
  alias Spectre.GAM.Test.ProjectionStore
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule Payloads do
    @behaviour Spectre.GAM.Payload.Store

    def verify(ref, opts) do
      table = Keyword.fetch!(opts, :table)
      :ets.update_counter(table, {:calls, ref}, {2, 1}, {{:calls, ref}, 0})

      case :ets.lookup(table, {:payload, ref}) do
        [{{:payload, ^ref}, body}] ->
          if Portable.content_ref!(:payload, body) == ref, do: :ok, else: {:error, :corrupt}

        [] ->
          {:error, :not_found}
      end
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    table = :ets.new(__MODULE__, [:set, :public])
    {:ok, rows} = ProjectionStore.start_link()

    f =
      Fixture.start_domain(
        projection_store: {ProjectionStore, server: rows},
        payload_store: {Payloads, table: table}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, table: table}
  end

  test "cold recovery checks payloads beyond its first archive page and rejects a missing body",
       c do
    refs =
      for n <- 1..51 do
        {ref, evidence} = payload_evidence(c, "body-#{n}", "unrelated-#{n}")
        assert {:ok, ^evidence} = Fixture.observe_payment(c.f, evidence)
        ref
      end

    snapshot = Fixture.snapshot(c.f)
    Fixture.stop_process(c.f.server)
    Enum.each(refs, &:ets.insert(c.table, {{:calls, &1}, 0}))
    {:ok, config} = Configuration.new(c.f.sequencer_opts)
    assert {:ok, projection, handle} = Startup.load_runtime(config)
    assert Enum.all?(refs, &(calls(c.table, &1) == 1))
    cursor = Map.take(projection, [:revision, :head_digest])

    assert {:ok, first, next} =
             Projection.Store.page(config.projection_store, handle, cursor, :payload_refs)

    assert length(first) == 50
    refute is_nil(next)

    assert {:ok, [{{:payload_refs, later_ref}, _}], nil} =
             Projection.Store.page(config.projection_store, handle, cursor, :payload_refs,
               after: next
             )

    [{{:payload, ^later_ref}, body}] = :ets.lookup(c.table, {:payload, later_ref})
    :ets.delete(c.table, {:payload, later_ref})
    assert {:error, {:unexpected_missing_payload, ^later_ref}} = Startup.load_runtime(config)
    assert Fixture.snapshot(c.f) == snapshot

    :ets.insert(c.table, {{:payload, later_ref}, body})
    assert {:ok, repaired, _handle} = Startup.load_runtime(config)
    assert Map.take(repaired, [:revision, :head_digest]) == cursor
    assert Fixture.snapshot(c.f) == snapshot
  end

  test "incremental recovery rejects corrupt new payloads and cold recovery succeeds after repair",
       c do
    {_, old} = payload_evidence(c, "old body", "unrelated-old")
    assert {:ok, ^old} = Fixture.observe_payment(c.f, old)
    {ref, evidence} = payload_evidence(c, "new body", "unrelated-new")
    {:ok, event} = Event.record(:evidence, evidence)
    state = :sys.get_state(c.f.server)
    Fixture.stop_process(c.f.server)

    assert {:ok, _} =
             Spectre.GAM.Ledger.Store.append(
               state.store,
               c.f.refs.domain,
               "external-payload",
               [event],
               state.projection.revision,
               recorded_at: Runtime.now()
             )

    snapshot = Fixture.snapshot(c.f)
    :ets.insert(c.table, {{:payload, ref}, "corrupted body"})

    assert {:error, {:payload_verification_failed, ^ref, :corrupt}} =
             Transaction.recover_verified(state)

    assert Fixture.snapshot(c.f) == snapshot

    :ets.insert(c.table, {{:payload, ref}, "new body"})
    {:ok, config} = Configuration.new(c.f.sequencer_opts)
    assert {:ok, recovered, handle} = Startup.load_runtime(config)
    assert recovered.revision == state.projection.revision + 1
    assert {:ok, expected} = Projection.replay(snapshot, c.f.constitution)
    resumed = %{state | projection: recovered, projection_handle: handle}
    assert {:ok, complete} = Projection.WorkingSet.extend(resumed, :projection, Runtime.now())
    assert complete == expected
  end

  defp payload_evidence(c, body, proposition) do
    ref = Portable.content_ref!(:payload, body)
    :ets.insert(c.table, {{:payload, ref}, body})

    evidence =
      Fixture.paid_evidence(c.f, %{proposition: proposition, payload: nil, payload_ref: ref})

    {ref, evidence}
  end

  defp calls(table, ref), do: :ets.lookup_element(table, {:calls, ref}, 2)
end
