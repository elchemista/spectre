Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.CommittedBatchTest.WrongAcknowledgement do
  alias Spectre.Ledger.Store.ETS
  # Deliberately broken host adapter: persists the right batch, returns the
  # wrong revision. Store.Mock correctly refuses to synthesize append success.
  def append(domain, batch, payloads, expected, opts) do
    {:ok, revision} = ETS.append(domain, batch, payloads, expected, opts)
    {:ok, revision + 1}
  end
end

defmodule Spectre.Core.CommittedBatchTest do
  use ExUnit.Case, async: true

  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.{Event, Projection, Recovery, Sequencer, Transaction}
  alias Spectre.{Evidence, Ledger}
  alias Spectre.GovernedAct.Fold
  alias Spectre.Ledger.{Entry, Store}
  alias Spectre.Ledger.Store.Mock

  setup do
    fixture = Fixture.start(:ets, "batch-#{System.unique_integer([:positive])}", 3, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)
    mock = start_supervised!({Mock, store: fixture.store_config})
    state = :sys.get_state(fixture.server)
    state = %{state | store: {Mock, server: mock}}

    {:ok, evidence} =
      Evidence.new(
        proposition: "received",
        issuer_ref: fixture.evidence.issuer_ref,
        source_ref: fixture.evidence.source_ref,
        provenance: :observed,
        observed_at: state.projection.recorded_at,
        bindings: fixture.evidence.bindings,
        payload: %{"value" => "new"},
        provisional: false
      )

    {:ok, event} = Event.record(:evidence, evidence)
    %{fixture: fixture, state: state, mock: mock, payloads: [event], evidence: evidence}
  end

  test "confirmed append reads only its durable index and agrees with full replay", ctx do
    assert :ok = Mock.push(ctx.mock, {:load, :before, {:error, :unexpected_full_load}})
    assert {:ok, next} = append(ctx)
    assert next.evidence[ctx.evidence.ref] == ctx.evidence
    assert operations(ctx.mock) == [:append, :lookup_batch]
    assert_replay(ctx.fixture, next)
  end

  test "uncertainty before or after commit cannot duplicate the batch", ctx do
    assert :ok =
             Mock.push(ctx.mock, [
               {:append, :before, {:error, :ambiguous}},
               {:append, :after, {:error, :ambiguous}}
             ])

    assert {:ok, next} = append(ctx)
    assert next.revision == ctx.state.projection.revision + 1
    assert Enum.count(operations(ctx.mock), &(&1 == :append)) == 2
    refute :load in operations(ctx.mock)
    assert_replay(ctx.fixture, next)
  end

  test "missing index acknowledgement falls back to the canonical ledger", ctx do
    assert :ok = Mock.push(ctx.mock, {:lookup_batch, :before, :not_found})
    assert {:ok, next} = append(ctx)
    assert operations(ctx.mock) == [:append, :lookup_batch, :load]
    assert_replay(ctx.fixture, next)
  end

  test "an index for another batch cannot replace verification of the committed history", ctx do
    assert :ok = Mock.push(ctx.mock, {:lookup_batch, :before, {:ok, %{batch_id: "foreign"}}})
    assert {:ok, next} = append(ctx)
    assert :load in operations(ctx.mock)
    assert_replay(ctx.fixture, next)
  end

  test "an identical retry uses the original durable acquisition time", ctx do
    prefix = ctx.state.projection

    assert {:ok, _} =
             Store.append(
               ctx.fixture.store_config,
               prefix.domain_ref,
               "batch",
               ctx.payloads,
               prefix.revision,
               recorded_at: prefix.recorded_at
             )

    assert {:ok, next} =
             Transaction.append_exact(ctx.state, "batch", ctx.payloads, prefix.recorded_at + 1)

    assert next.recorded_at == prefix.recorded_at
    assert :load in operations(ctx.mock)
    assert_replay(ctx.fixture, next)
  end

  test "missing history cannot confirm an unindexed append", ctx do
    assert :ok =
             Mock.push(ctx.mock, [
               {:lookup_batch, :before, :not_found},
               {:load, :before, :not_found}
             ])

    assert {:error, {:durable_recovery_failed, :domain_ledger_disappeared}} = append(ctx)
    assert Sequencer.projection(ctx.fixture.server) == ctx.state.projection
  end

  test "fallback still verifies all ledger hashes before confirming an append", ctx do
    assert {:ok, _} = append(ctx)
    assert {:ok, snapshot} = Ledger.load(ctx.fixture.store_config, ctx.fixture.refs.domain)
    [first | rest] = snapshot.entries
    corrupt = %{snapshot | entries: [%{first | digest: String.duplicate("f", 64)} | rest]}

    assert :ok =
             Mock.push(ctx.mock, [
               {:lookup_batch, :before, :not_found},
               {:load, :before, {:ok, corrupt}}
             ])

    assert {:error, {:durable_recovery_failed, {:ledger_entry_digest_mismatch, 1}}} = append(ctx)
  end

  test "a different committed batch cannot satisfy confirmation of the requested batch", ctx do
    prefix = ctx.state.projection

    assert {:ok, _} =
             Store.append(
               ctx.fixture.store_config,
               prefix.domain_ref,
               "different-batch",
               ctx.payloads,
               prefix.revision,
               recorded_at: prefix.recorded_at
             )

    assert {:error, {:committed_batch_identity_mismatch, "batch"}} =
             Recovery.confirm_append(
               ctx.fixture.store_config,
               prefix,
               "batch",
               ctx.payloads,
               prefix.recorded_at,
               []
             )
  end

  test "an incorrect append acknowledgement cannot be promoted to committed state", ctx do
    state = %{ctx.state | store: {__MODULE__.WrongAcknowledgement, server: ctx.fixture.store}}

    assert {:error, {:durable_recovery_failed, {:unexpected_append_revision, _}}} =
             Transaction.append_exact(state, "batch", ctx.payloads, state.projection.recorded_at)

    assert Sequencer.projection(ctx.fixture.server) == state.projection
  end

  test "the live sequencer stops without a Grant when post-commit confirmation fails", ctx do
    :sys.replace_state(ctx.fixture.server, fn _ -> ctx.state end)
    Process.unlink(ctx.fixture.server)
    monitor = Process.monitor(ctx.fixture.server)

    assert :ok =
             Mock.push(ctx.mock, [
               {:lookup_batch, :before, :not_found},
               {:load, :before, :not_found}
             ])

    assert {:error, {:durable_recovery_failed, :domain_ledger_disappeared}} =
             Sequencer.submit(
               ctx.fixture.server,
               ctx.fixture.context,
               Fixture.candidate(ctx.fixture, 1)
             )

    assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000

    # The batch did commit, but no capability was returned. Recovery can still
    # reconstruct its pending Act; no attempt was silently started.
    assert {:ok, recovered} =
             Recovery.recover(
               ctx.fixture.store_config,
               ctx.fixture.refs.domain,
               ctx.state.projection.constitution,
               []
             )

    assert map_size(recovered.acts) == 1
    assert map_size(recovered.attempts) == 0
  end

  test "unresolved ambiguity cannot promote a provisional projection", ctx do
    script =
      List.duplicate({:append, :before, {:error, :ambiguous}}, ctx.state.ambiguous_retries + 1)

    assert :ok = Mock.push(ctx.mock, script)
    assert {:error, :ambiguous_commit_unresolved} = append(ctx)

    assert :not_found =
             Ledger.lookup_batch(ctx.fixture.store_config, ctx.fixture.refs.domain, "batch")

    assert_replay(ctx.fixture, ctx.state.projection)
  end

  test "CAS conflict leaves the previously verified projection untouched", ctx do
    prefix = ctx.state.projection

    assert {:ok, _} =
             Store.append(
               ctx.fixture.store_config,
               prefix.domain_ref,
               "other-writer",
               ctx.payloads,
               prefix.revision,
               recorded_at: prefix.recorded_at
             )

    assert :conflict = append(ctx)
    assert :not_found = Ledger.lookup_batch(ctx.fixture.store_config, prefix.domain_ref, "batch")
    assert Sequencer.projection(ctx.fixture.server) == prefix
  end

  test "a valid full ledger cannot silently replace the cached predecessor", ctx do
    assert {:ok, _} = append(ctx)
    prefix = %{ctx.state.projection | head_digest: String.duplicate("1", 64)}

    assert {:error, {:committed_batch_predecessor_mismatch, "batch"}} =
             Recovery.confirm_append(
               ctx.fixture.store_config,
               prefix,
               "batch",
               ctx.payloads,
               prefix.recorded_at,
               []
             )
  end

  test "incremental fold equals full replay at every atomic boundary, including Duty derivation",
       ctx do
    f = ctx.fixture

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(f.server, f.context, Fixture.candidate(f, 1))

    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)

    {:ok, outcome} =
      Spectre.Outcome.new(
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: :ambiguous,
        evidence_refs: [],
        observed_at: System.system_time(:millisecond),
        details_ref: "interrupted"
      )

    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    constitution = ctx.state.projection.constitution

    {incremental, _} =
      snapshot.entries
      |> Enum.chunk_by(& &1.batch_id)
      |> Enum.reduce({Projection.new(f.refs.domain, constitution), []}, fn batch,
                                                                           {state, history} ->
        assert {:ok, next} = Fold.append_batch(state, batch)
        history = history ++ batch

        prefix = %{
          snapshot
          | entries: history,
            revision: next.revision,
            head_digest: next.head_digest
        }

        assert {:ok, ^next} = Projection.replay(prefix, constitution)
        {next, history}
      end)

    assert incremental == Sequencer.projection(f.server)
    assert map_size(incremental.duties) == 1
  end

  test "incremental fold rejects foreign Domains, chain mismatches, partial batches and time regression",
       ctx do
    prefix = ctx.state.projection

    {:ok, entries} =
      Entry.build_batch(
        prefix.domain_ref,
        "batch",
        ctx.payloads,
        prefix.revision,
        prefix.recorded_at,
        prefix.head_digest
      )

    assert {:ok, _} = Fold.append_batch(prefix, entries)
    assert {:error, _} = Fold.append_batch(%{prefix | domain_ref: "foreign"}, entries)
    assert {:error, _} = Fold.append_batch(%{prefix | revision: prefix.revision + 1}, entries)

    assert {:error, _} =
             Fold.append_batch(%{prefix | head_digest: String.duplicate("1", 64)}, entries)

    assert {:error, {:ledger_time_regression, _, _}} =
             Fold.append_batch(%{prefix | recorded_at: prefix.recorded_at + 1}, entries)

    {:ok, batch} =
      Entry.build_batch(
        prefix.domain_ref,
        "batch",
        ctx.payloads ++ ctx.payloads,
        prefix.revision,
        prefix.recorded_at,
        prefix.head_digest
      )

    assert {:error, :ledger_batch_coordinates_mismatch} =
             Fold.append_batch(prefix, Enum.take(batch, 1))

    assert {:error, :empty_ledger_batch} = Fold.append_batch(prefix, [])
    [entry] = entries

    assert {:error, {:ledger_entry_digest_mismatch, _}} =
             Fold.append_batch(prefix, [%{entry | digest: String.duplicate("f", 64)}])
  end

  defp append(ctx),
    do:
      Transaction.append_exact(ctx.state, "batch", ctx.payloads, ctx.state.projection.recorded_at)

  defp operations(mock), do: Enum.map(Mock.calls(mock), & &1.operation)

  defp assert_replay(fixture, projection) do
    assert {:ok, snapshot} = Ledger.load(fixture.store_config, fixture.refs.domain)
    assert {:ok, ^projection} = Projection.replay(snapshot, projection.constitution)
  end
end
