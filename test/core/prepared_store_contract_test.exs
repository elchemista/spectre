Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.PreparedStoreContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Audit, Ledger, Outcome}
  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.Admission.Planner
  alias Spectre.Domain.Command.Execution
  alias Spectre.Domain.{Projection, Recovery, Sequencer}
  alias Spectre.GovernedAct.{Commit, DispatchState}
  alias Spectre.Kernel.Meter.Account
  alias Spectre.Ledger.Store
  alias Spectre.Ledger.Store.{Disk, Mock}

  # Exercise the same semantic transaction on real storage implementations.
  # Compression changes representation, never the governed facts or receipt.
  # These are ledger-backed contracts, not a simulated current-state backend.
  setup %{store_kind: kind} do
    fixture = Fixture.start(kind, "prepared-#{System.unique_integer([:positive])}", 2, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)
    state = :sys.get_state(fixture.server)
    %{fixture: fixture, state: state, store: fixture.store_config, prefix: state.projection}
  end

  for kind <- [:ets, :ets_compressed, :disk, :disk_compressed] do
    @tag store_kind: kind
    test "#{kind}: preparation cannot publish an Act or spend its reservation", ctx do
      before = snapshot(ctx)
      prepared = prepare(ctx, "admission", [1, 2])

      assert Enum.map(prepared.payloads, & &1["type"]) ===
               List.duplicate(
                 ~w(decision_recorded act_committed meter_reserved dispatch_ready),
                 2
               )
               |> List.flatten()

      assert map_size(prepared.state.acts) === 2
      assert_account(ctx, prepared.state, 0, 2)
      assert_account(ctx, ctx.prefix, 2, 0)
      assert snapshot(ctx) === before

      for act <- Map.values(prepared.state.acts) do
        refute DispatchState.pending?(ctx.prefix, act.ref)
        assert {:error, {:act_not_dispatch_ready, _}} = Execution.mint_grant(ctx.state, act)
      end

      assert :not_found = Ledger.lookup_batch(ctx.store, ctx.prefix.domain_ref, "admission")
      assert {:error, :domain_ledger_disappeared} = confirm(ctx, prepared)
      assert Sequencer.projection(ctx.fixture.server) === ctx.prefix
    end

    @tag store_kind: kind
    test "#{kind}: atomic group commit preserves its prefix and agrees with independent export",
         ctx do
      before = snapshot(ctx)
      prepared = prepare(ctx, "admission", [1, 2])
      assert {:ok, revision} = persist(ctx, prepared)
      assert revision === ctx.prefix.revision + 8
      assert {:ok, confirmed} = confirm(ctx, prepared)
      assert confirmed === prepared.state
      assert Enum.take(snapshot(ctx).entries, ctx.prefix.revision) === before.entries

      assert {:ok, batch} =
               Store.read_batch(ctx.store, ctx.prefix.domain_ref, ctx.prefix.revision + 1)

      assert length(batch.entries) === 8
      assert Enum.all?(batch.entries, &(&1.batch_id === "admission"))

      for act <- Map.values(confirmed.acts) do
        assert confirmed.event_metadata[act.ref].batch_id === "admission"
        assert DispatchState.pending?(confirmed, act.ref)
        assert {:ok, grant} = Execution.mint_grant(%{ctx.state | projection: confirmed}, act)
        assert grant.act_ref === act.ref
      end

      assert_account(ctx, confirmed, 0, 2)
      assert_recovery_and_audit(ctx, confirmed)
    end

    @tag store_kind: kind
    test "#{kind}: competing prepared groups cannot double-spend the last two units", ctx do
      proposals = [prepare(ctx, "writer-a", [1, 2]), prepare(ctx, "writer-b", [3, 4])]
      results = race(proposals, &persist(ctx, &1))
      assert Enum.count(results, &match?({_, {:ok, _}}, &1)) === 1
      assert Enum.count(results, &match?({_, {:error, :conflict}}, &1)) === 1
      {winner, {:ok, _}} = Enum.find(results, &match?({_, {:ok, _}}, &1))
      {loser, {:error, :conflict}} = Enum.find(results, &match?({_, {:error, _}}, &1))
      assert {:ok, committed} = confirm(ctx, winner)
      assert committed === winner.state

      assert :not_found =
               Ledger.lookup_batch(ctx.store, ctx.prefix.domain_ref, loser.receipt.batch_id)

      assert {:error, {:committed_batch_identity_mismatch, _}} = confirm(ctx, loser)
      assert_account(ctx, committed, 0, 2)

      # The losing writer must evaluate again at the new prefix. Reusing its
      # old admission would grant authority that no longer has a Meter budget.
      refreshed = %{ctx | prefix: committed, state: %{ctx.state | projection: committed}}
      retry_ids = if loser.receipt.batch_id === "writer-a", do: [1, 2], else: [3, 4]
      retry = prepare(refreshed, "replanned", retry_ids)
      assert Enum.map(retry.payloads, & &1["type"]) === ~w(decision_recorded decision_recorded)
      assert {:ok, _} = persist(refreshed, retry)
      assert {:ok, final} = confirm(refreshed, retry)

      assert Enum.frequencies_by(Map.values(final.decisions), & &1.outcome) ===
               %{admitted: 2, refused: 2}

      assert map_size(final.acts) === 2
      assert_account(ctx, final, 0, 2)
      assert_recovery_and_audit(ctx, final)
    end

    @tag store_kind: kind
    test "#{kind}: simultaneous retries publish one batch, not eight reservations", ctx do
      prepared = prepare(ctx, "same-operation", [1, 2])
      results = race(List.duplicate(prepared, 8), &persist(ctx, &1))
      expected = prepared.receipt.last_revision
      assert Enum.all?(results, fn {_, reply} -> reply === {:ok, expected} end)
      assert {:ok, confirmed} = confirm(ctx, prepared)
      assert snapshot(ctx).revision === expected
      assert map_size(confirmed.meter_reservations) === 2
      assert_account(ctx, confirmed, 0, 2)
      assert_recovery_and_audit(ctx, confirmed)
    end

    @tag store_kind: kind
    test "#{kind}: lost acknowledgement before commit cannot publish provisional authority",
         ctx do
      before = snapshot(ctx)
      prepared = prepare(ctx, "before-commit", [1, 2])
      assert {:error, :ambiguous} = persist(ctx, prepared, fault_injection: :before_commit)
      assert snapshot(ctx) === before
      assert {:error, :domain_ledger_disappeared} = confirm(ctx, prepared)
      assert {:ok, recovered} = recover(ctx)
      assert recovered === ctx.prefix
      assert_account(ctx, recovered, 2, 0)

      assert {:ok, _} = persist(ctx, prepared)
      assert {:ok, confirmed} = confirm(ctx, prepared)
      assert_recovery_and_audit(ctx, confirmed)
    end

    @tag store_kind: kind
    test "#{kind}: lost acknowledgement after commit recovers every governed fact exactly once",
         ctx do
      prepared = prepare(ctx, "after-commit", [1, 2])
      assert {:error, :ambiguous} = persist(ctx, prepared, fault_injection: :after_commit)
      assert {:ok, confirmed} = confirm(ctx, prepared)
      assert confirmed === prepared.state
      assert {:ok, _} = persist(ctx, prepared)
      assert_account(ctx, confirmed, 0, 2)
      assert_recovery_and_audit(ctx, confirmed)
    end

    @tag store_kind: kind
    test "#{kind}: reusing an identity for different material cannot confirm the wrong state",
         ctx do
      original = prepare(ctx, "identity", [1, 2])
      changed = prepare(ctx, "identity", [3, 4])
      assert original.receipt.entry_count === changed.receipt.entry_count
      assert original.receipt.last_revision === changed.receipt.last_revision
      assert {:ok, _} = persist(ctx, original)
      assert {:error, {:batch_identity_conflict, "identity"}} = persist(ctx, changed)
      assert {:error, {:committed_batch_identity_mismatch, "identity"}} = confirm(ctx, changed)
      assert_recovery_and_audit(ctx, original.state)
    end

    @tag store_kind: kind
    test "#{kind}: retry time cannot rewrite the Decision time or original durable receipt",
         ctx do
      original = prepare(ctx, "retry", [1, 2])
      assert {:ok, _} = persist(ctx, original)
      decided_at = original.recorded_at
      later = decided_at + 1

      assert {:error,
              {:event_time_mismatch, "decision_recorded", "decided_at", ^decided_at, ^later}} =
               Commit.prepare(ctx.prefix, "retry", original.payloads, later)

      # Storage identity is about the original operation. An adapter retry
      # may arrive later, but it must return the existing batch, not retime it.
      assert {:ok, _} =
               Store.append(
                 ctx.store,
                 ctx.prefix.domain_ref,
                 "retry",
                 original.payloads,
                 ctx.prefix.revision,
                 recorded_at: later
               )

      assert {:ok, receipt} = Ledger.lookup_batch(ctx.store, ctx.prefix.domain_ref, "retry")
      assert receipt === original.receipt
      assert {:ok, confirmed} = confirm(ctx, original)
      assert confirmed === original.state
      assert_recovery_and_audit(ctx, confirmed)
    end

    @tag store_kind: kind
    test "#{kind}: post-commit validation can veto publication but cannot roll back history",
         ctx do
      prepared = prepare(ctx, "validation", [1, 2])
      assert {:ok, _} = persist(ctx, prepared)
      owner = self()

      check = fn state, refs ->
        send(owner, {:checked, state.revision, refs})
        {:error, :required_payload_unavailable}
      end

      assert {:error, :required_payload_unavailable} =
               Recovery.confirm_prepared(ctx.store, ctx.prefix, prepared, [], check)

      assert_receive {:checked, revision, []}
      assert revision === prepared.state.revision
      refute_receive {:checked, _, _}, 0
      assert Sequencer.projection(ctx.fixture.server) === ctx.prefix
      assert_recovery_and_audit(ctx, prepared.state)
    end

    @tag store_kind: kind
    test "#{kind}: missing receipt reads a verified suffix including a concurrent later batch",
         ctx do
      first = prepare(ctx, "first", [1])
      assert {:ok, _} = persist(ctx, first)
      advanced = %{ctx | prefix: first.state, state: %{ctx.state | projection: first.state}}
      second = prepare(advanced, "second", [2])
      assert {:ok, _} = persist(advanced, second)
      mock = start_supervised!({Mock, store: ctx.store})
      assert :ok = Mock.push(mock, {:lookup_batch, :before, :not_found})

      assert {:ok, recovered} =
               Recovery.confirm_prepared({Mock, server: mock}, ctx.prefix, first, [])

      assert recovered === second.state
      assert Enum.map(Mock.calls(mock), & &1.operation) === [:lookup_batch, :load_from]
      assert_recovery_and_audit(ctx, recovered)
    end

    @tag store_kind: kind
    test "#{kind}: cached-prefix catch-up cannot skip a concurrent reservation", ctx do
      first = prepare(ctx, "first", [1])
      assert {:ok, _} = persist(ctx, first)
      advanced = %{ctx | prefix: first.state, state: %{ctx.state | projection: first.state}}
      second = prepare(advanced, "second", [2])
      assert {:ok, _} = persist(advanced, second)
      assert {:ok, resumed} = Recovery.resume(ctx.store, ctx.prefix)
      assert resumed === second.state
      assert {:ok, same} = Recovery.resume(ctx.store, resumed)
      assert same === resumed
      assert_account(ctx, resumed, 0, 2)
      assert_recovery_and_audit(ctx, resumed)
    end

    @tag store_kind: kind
    test "#{kind}: restart preserves suspension and late success settles it without disposing the Duty",
         ctx do
      fixture = ctx.fixture

      assert {:ok, %{act: act, grant: grant}} =
               Sequencer.submit(fixture.server, fixture.context, Fixture.candidate(fixture, 1))

      assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(fixture.server, grant)

      assert {:ok, ambiguous} =
               Outcome.new(
                 act_ref: act.ref,
                 attempt_ref: attempt.ref,
                 status: :ambiguous,
                 evidence_refs: [],
                 details_ref: "receipt:lost-before-confirmation",
                 observed_at: System.system_time(:millisecond)
               )

      assert {:ok, ^ambiguous} = Sequencer.record_outcome(fixture.server, ambiguous)
      contained = Sequencer.projection(fixture.server)
      assert [%{class: :ambiguous_outcome, status: :open} = duty] = Map.values(contained.duties)
      account = contained.meters[fixture.mandate.ref][fixture.refs.meter]
      assert :ok = Account.validate(account)

      assert {account.available, account.reserved, account.suspended, account.spent} ===
               {1, 0, 1, 0}

      assert {:ok, ^contained} = recover(ctx)

      GenServer.stop(fixture.server)
      server = start_supervised!({Sequencer, fixture.sequencer_opts})
      assert Sequencer.projection(server) === contained
      assert {:error, _} = Sequencer.consume_grant(server, grant)
      assert Sequencer.projection(server) === contained

      evidence = Fixture.outcome_evidence(fixture, act, attempt)

      assert {:ok, [^evidence]} =
               Sequencer.record_executor_evidence(server, act.ref, attempt.ref, evidence)

      outcome = Fixture.outcome(act, attempt, evidence)
      assert {:ok, ^outcome} = Sequencer.record_outcome(server, outcome)
      final = Sequencer.projection(server)
      assert final.attempts === contained.attempts
      assert final.duties[duty.cause_key] === duty
      assert map_size(final.outcomes) === 2
      settled = final.meters[fixture.mandate.ref][fixture.refs.meter]
      assert :ok = Account.validate(settled)

      assert {settled.available, settled.reserved, settled.suspended, settled.spent} ===
               {1, 0, 0, 1}

      assert final.meter_reservations[act.ref] === :settled
      assert {:ok, ^final} = recover(ctx)
      assert {:ok, export} = Ledger.export(ctx.store, final.domain_ref)
      assert {:ok, report} = Audit.verify(export, final.constitution, final.recorded_at)
      assert length(report.open_duties) === 1
      assert report.counts.attempts === 1
    end

    for {removed, error} <- [
          {"meter_reserved", :act_reservation_not_ready},
          {"dispatch_ready", :act_dispatch_missing_from_admission_batch}
        ] do
      @tag store_kind: kind
      test "#{kind}: a checksummed admission without #{removed} is semantically rejected", ctx do
        prepared = prepare(ctx, "damaged", [1])
        payloads = Enum.reject(prepared.payloads, &(&1["type"] === unquote(removed)))
        [act] = Map.values(prepared.state.acts)
        error = {unquote(error), act.ref}

        assert {:error, ^error} =
                 Commit.prepare(ctx.prefix, "damaged", payloads, ctx.prefix.recorded_at)

        # Simulate an administrator replacing records and recomputing hashes.
        # Byte integrity alone is insufficient; recovery must enforce GAM.
        assert {:ok, _} =
                 Store.append(
                   ctx.store,
                   ctx.prefix.domain_ref,
                   "damaged",
                   payloads,
                   ctx.prefix.revision,
                   recorded_at: ctx.prefix.recorded_at
                 )

        assert {:ok, _} = Ledger.verify_snapshot(snapshot(ctx))
        assert {:error, ^error} = recover(ctx)
        assert {:error, ^error} = Recovery.resume(ctx.store, ctx.prefix)
        assert {:ok, export} = Ledger.export(ctx.store, ctx.prefix.domain_ref)

        assert {:error, {:semantic_violation, %{reason: ^error}}} =
                 Audit.verify(export, ctx.prefix.constitution, ctx.prefix.recorded_at)

        assert Sequencer.projection(ctx.fixture.server) === ctx.prefix
      end
    end
  end

  for kind <- [:disk, :disk_compressed] do
    @tag store_kind: kind
    test "#{kind}: process death after durable commit preserves receipts and pending Acts", ctx do
      prepared = prepare(ctx, "crash-after-commit", [1, 2])
      assert {:error, :ambiguous} = persist(ctx, prepared, fault_injection: :after_commit)
      directory = :sys.get_state(ctx.fixture.store).directory
      GenServer.stop(ctx.fixture.server)
      Process.unlink(ctx.fixture.store)
      monitor = Process.monitor(ctx.fixture.store)
      Process.exit(ctx.fixture.store, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1_000
      # Reopen from disk with the opposite compression setting. Old records
      # describe their encoding; configuration affects only future writes.
      reopened = start_supervised!({Disk, path: directory, compressed: unquote(kind) === :disk})
      restarted = %{ctx | store: {Disk, server: reopened}}
      assert {:ok, confirmed} = confirm(restarted, prepared)
      assert confirmed === prepared.state
      assert confirmed.attempts === %{}
      assert {:ok, _} = persist(restarted, prepared)
      assert_recovery_and_audit(restarted, confirmed)
    end
  end

  defp prepare(ctx, id, sequences) do
    requests =
      Enum.map(sequences, fn sequence ->
        %{
          from: {self(), make_ref()},
          context: ctx.fixture.context,
          candidate: Fixture.candidate(ctx.fixture, sequence)
        }
      end)

    {plans, payloads} = Planner.plan(ctx.state, requests, ctx.prefix.recorded_at)
    assert Enum.all?(plans, &is_nil(&1.error))
    assert {:ok, prepared} = Commit.prepare(ctx.prefix, id, payloads, ctx.prefix.recorded_at)
    prepared
  end

  defp persist(ctx, prepared, opts \\ []) do
    Store.append(
      ctx.store,
      ctx.prefix.domain_ref,
      prepared.receipt.batch_id,
      prepared.payloads,
      prepared.prefix.revision,
      Keyword.put(opts, :recorded_at, prepared.recorded_at)
    )
  end

  defp confirm(ctx, prepared),
    do: Recovery.confirm_prepared(ctx.store, ctx.prefix, prepared, [])

  defp recover(ctx),
    do: Recovery.recover(ctx.store, ctx.prefix.domain_ref, ctx.prefix.constitution, [])

  defp snapshot(ctx) do
    assert {:ok, snapshot} = Ledger.load(ctx.store, ctx.prefix.domain_ref)
    snapshot
  end

  defp assert_account(ctx, projection, available, reserved) do
    account = projection.meters[ctx.fixture.mandate.ref][ctx.fixture.refs.meter]
    assert :ok = Account.validate(account)

    assert Map.take(account, [:ceiling, :available, :reserved, :suspended, :spent, :delegated]) ===
             %{
               ceiling: 2,
               available: available,
               reserved: reserved,
               suspended: 0,
               spent: 0,
               delegated: 0
             }
  end

  defp assert_recovery_and_audit(ctx, expected) do
    assert {:ok, recovered} = recover(ctx)
    assert recovered === expected
    assert {:ok, replayed} = Projection.replay(snapshot(ctx), ctx.prefix.constitution)
    assert replayed === expected
    assert {:ok, export} = Ledger.export(ctx.store, ctx.prefix.domain_ref)
    assert {:ok, report} = Audit.verify(export, expected.constitution, expected.recorded_at)
    assert report.ledger_revision === expected.revision
    assert report.head_digest === expected.head_digest
    assert report.open_duties === []
  end

  defp race(values, operation) do
    owner = self()
    barrier = make_ref()

    tasks =
      Enum.map(values, fn value ->
        Task.async(fn ->
          send(owner, {barrier, :ready, self()})

          receive do
            {^barrier, :go} -> {value, operation.(value)}
          after
            5_000 -> raise "writer barrier timed out"
          end
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {^barrier, :ready, ^pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, {barrier, :go}))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end
end
