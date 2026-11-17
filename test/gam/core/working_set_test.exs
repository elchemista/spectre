Code.require_file("../helper.exs", __DIR__)
Code.require_file("../support/projection_store.ex", __DIR__)

defmodule Spectre.GAM.Core.WorkingSetTest do
  use ExUnit.Case, async: false
  alias Spectre.GAM.Domain.{Projection, Sequencer}
  alias Spectre.GAM.Domain.{Event, Recovery, Transaction}
  alias Spectre.GAM.GovernedAct.Commit
  alias Spectre.GAM.Ledger.Store.Mock
  alias Spectre.GAM.Test.ProjectionStore
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule Mind do
    @behaviour Spectre.GAM.Mind
    def ref, do: "mind:working-set"
    def deliberate(_, _), do: {:ok, []}
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    {:ok, storage} = ProjectionStore.start_link()

    f =
      Fixture.start_domain(
        projection_store: {ProjectionStore, server: storage},
        mind: Mind,
        mock_store: Map.get(tags, :native_mock, false)
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, storage: storage}
  end

  test "ordinary commits discard history and replay agrees with the complete pure fold", %{f: f} do
    assert {:ok, false} = GenServer.call(f.server, :unresolved_duties)
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    assert_same_history(f)
    context = Fixture.context(f)

    for n <- 1..30 do
      assert {:ok, [_]} =
               Sequencer.observe(
                 f.server,
                 context,
                 Fixture.paid_evidence(f, %{
                   proposition: "irrelevant-#{n}",
                   payload: "private-#{n}"
                 })
                 |> Map.from_struct()
                 |> Map.delete(:ref)
               )
    end

    assert_same_history(f)
    live = :sys.get_state(f.server)
    assert live.projection.evidence == %{}
    assert live.projection.read_index.batches == MapSet.new()
    candidate = Fixture.refund_candidate(f, 10, evidence_refs: [paid.ref])

    assert {:ok, %{decision: %{outcome: :admitted}, act: act, grant: grant}} =
             Sequencer.submit(f.server, context, candidate)

    assert_same_history(f)
    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    assert_same_history(f)
    assert {:error, _} = Sequencer.consume_grant(f.server, grant)

    {:ok, receipt} =
      Spectre.GAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
        payload: %{receipt: "ok"}
      )

    assert {:ok, ^receipt} = Fixture.record_receipt(f, receipt)
    outcome = Fixture.outcome(f, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    expected = assert_same_history(f)
    Fixture.stop_process(f.server)
    recovered = Fixture.restart_domain(f)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert Sequencer.projection(recovered.server) == expected
    assert :sys.get_state(recovered.server).projection.evidence == %{}
  end

  test "archived counterproof remains visible to admission", %{f: f} do
    paid = Fixture.paid_evidence(f)
    {:ok, ^paid} = Fixture.observe_payment(f, paid)
    denied = Fixture.paid_evidence(f, %{stance: :contradicts, payload: %{correction: true}})
    assert {:ok, ^denied} = Fixture.observe_payment(f, denied)
    assert :sys.get_state(f.server).projection.evidence == %{}
    candidate = Fixture.refund_candidate(f, 10, evidence_refs: [paid.ref, denied.ref])

    assert {:ok, %{decision: %{outcome: result}, act: nil}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    assert result != :admitted
    assert_same_history(f)
  end

  test "ingress completion reloads the original turn's archived context", %{f: f} do
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    assert :sys.get_state(f.server).projection.evidence == %{}

    input = Fixture.paid_evidence(f, %{proposition: "new-observation"})
    input = input |> Map.from_struct() |> Map.delete(:ref)

    assert {:ok, {_mind, turn}} =
             Sequencer.begin_turn(f.server, Fixture.context(f), input, [paid.ref])

    assert paid.ref in Spectre.GAM.Mind.Turn.evidence_refs(turn)
    assert :sys.get_state(f.server).projection.evidence == %{}
    assert_same_history(f)
  end

  test "a later commit derives archived deadline work and removes its persisted timer", %{
    f: f,
    storage: storage
  } do
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    candidate = Fixture.refund_candidate(f, 10, evidence_refs: [paid.ref])

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(f.server, Fixture.context(f), candidate)

    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    deadline = attempt.started_at + act.observation_window_ms
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    assert state.projection.attempts == %{}
    Runtime.set_time(deadline + 1)
    attrs = paid |> Map.from_struct() |> Map.delete(:ref)

    {:ok, tick_evidence} =
      Spectre.GAM.Evidence.new(%{
        attrs
        | observed_at: Runtime.now(),
          proposition: "deadline-tick"
      })

    {:ok, tick} = Spectre.GAM.Domain.Event.record(:evidence, tick_evidence)

    # Preparation loads a later deadline than the retained prefix. Its diff
    # must emit that timer's deletion, including when Duty repair follows.
    assert {:ok, repaired} =
             Spectre.GAM.Domain.Transaction.append_exact(
               state,
               "deadline-tick",
               [tick],
               Runtime.now()
             )

    assert Enum.any?(repaired.duties, fn {_, duty} ->
             duty.act_ref == act.ref and duty.class == :ambiguous_outcome
           end)

    assert {:ok, true} =
             Spectre.GAM.Domain.Query.unresolved_duties(%{
               projection: Spectre.GAM.Domain.Projection.Live.retain(repaired)
             })

    rows = Agent.get(storage, & &1[f.refs.domain].rows)
    refute Map.has_key?(rows, {:duty_deadlines, {deadline, :attempt, attempt.ref}})
    assert {:ok, expected} = Projection.replay(Fixture.snapshot(f), f.constitution)

    assert {:ok, actual} =
             Spectre.GAM.Domain.Projection.WorkingSet.extend(
               %{state | projection: repaired},
               :projection,
               Runtime.now()
             )

    assert actual == expected
  end

  test "Duty derivation refuses an unloaded subscription group", %{f: f} do
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    projection = Sequencer.projection(f.server)
    projection = Spectre.GAM.GovernedAct.Reads.mark(projection, MapSet.new())

    assert catch_throw(
             Spectre.GAM.Duty.Frontier.record(projection, %{
               type: "evidence_recorded",
               identity: paid.ref
             })
           ) ==
             {:projection_not_loaded, {:page, :evidence_subscriptions, [group: paid.proposition]}}
  end

  test "a corrupt persisted record fails the read without advancing the Domain", %{
    f: f,
    storage: storage
  } do
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    context = Fixture.context(f)

    {:ok, scope} =
      Spectre.GAM.Scope.new(Spectre.GAM.Domain.handle(f.server, f.refs.domain), context)

    {:ok, head} = Sequencer.head(f.server)
    key = {:evidence, paid.ref}
    bytes = Agent.get(storage, & &1[f.refs.domain].rows[key])
    Agent.update(storage, &put_in(&1[f.refs.domain].rows[key], <<0>>))
    request = {:query, scope, {:selected_view, %{evidence_refs: [paid.ref]}}}
    assert {:error, _} = GenServer.call(f.server, request)
    assert {:ok, ^head} = Sequencer.head(f.server)
    Agent.update(storage, &put_in(&1[f.refs.domain].rows[key], bytes))
    assert {:ok, view} = GenServer.call(f.server, request)
    assert paid in view.evidence
  end

  test "an external canonical suffix resumes the persisted projection exactly once", %{f: f} do
    evidence = Fixture.paid_evidence(f)
    {:ok, event} = Spectre.GAM.Domain.Event.record(:evidence, evidence)
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)

    assert {:ok, _} =
             Spectre.GAM.Ledger.Store.append(
               state.store,
               f.refs.domain,
               "external-suffix",
               [event],
               state.projection.revision,
               recorded_at: Runtime.now()
             )

    assert {:ok, recovered} = Transaction.recover_verified(state)
    assert recovered.revision > state.projection.revision
    resumed = %{state | projection: recovered}
    assert {:ok, ^recovered} = Transaction.recover_with_repair(resumed)
    assert {:ok, expected} = Projection.replay(Fixture.snapshot(f), f.constitution)
    assert {:ok, complete} = Projection.WorkingSet.extend(resumed, :projection, Runtime.now())
    assert complete == expected
  end

  @tag :native_mock
  test "a missing receipt acknowledgement confirms the native batch without applying its rows twice",
       %{f: f} do
    {:ok, event} = Event.record(:evidence, Fixture.paid_evidence(f))
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    before_calls = length(Mock.calls(f.mock))
    assert :ok = Mock.push(f.mock, {:lookup_batch, :before, :not_found})

    assert {:ok, recovered} =
             Transaction.append_exact(state, "missing-receipt", [event], Runtime.now())

    assert new_operations(f, before_calls) == [:append, :lookup_batch]
    assert_persisted_once(f, state, recovered)
  end

  @tag :native_mock
  test "ambiguity before and after persistence retries without duplicating the native batch",
       %{f: f} do
    {:ok, event} = Event.record(:evidence, Fixture.paid_evidence(f))
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    before_calls = length(Mock.calls(f.mock))

    assert :ok =
             Mock.push(f.mock, [
               {:append, :before, {:error, :ambiguous}},
               {:append, :after, {:error, :ambiguous}}
             ])

    assert {:ok, recovered} =
             Transaction.append_exact(state, "ambiguous-native", [event], Runtime.now())

    assert new_operations(f, before_calls) == [
             :append,
             :lookup_batch,
             :append,
             :lookup_batch,
             :lookup_batch
           ]

    assert_persisted_once(f, state, recovered)
  end

  @tag :native_mock
  test "a different canonical batch cannot confirm prepared intent or invoke its resume callback",
       %{f: f} do
    {:ok, expected_event} = Event.record(:evidence, Fixture.paid_evidence(f))

    {:ok, actual_event} =
      Event.record(:evidence, Fixture.paid_evidence(f, %{proposition: "external-observation"}))

    prefix = Sequencer.projection(f.server)
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    {:ok, prepared} = Commit.prepare(prefix, "expected-batch", [expected_event], Runtime.now())

    assert {:ok, _} =
             Spectre.GAM.Ledger.Store.append(
               state.store,
               f.refs.domain,
               "actual-batch",
               [actual_event],
               prefix.revision,
               recorded_at: Runtime.now()
             )

    assert {:error, {:ambiguous_batch_identity_mismatch, "actual-batch"}} =
             Recovery.classify_ambiguous(
               state.store,
               f.refs.domain,
               "actual-batch",
               [expected_event],
               prefix.revision
             )

    assert {:ok, standalone} = Recovery.recover(state.store, f.refs.domain)
    assert Map.has_key?(standalone.evidence, actual_event["identity"])

    resume = fn ->
      send(self(), :unexpected_projection_resume)
      {:ok, prepared.state}
    end

    assert {:error, {:committed_batch_identity_mismatch, "expected-batch"}} =
             Recovery.confirm_prepared(
               state.store,
               prefix,
               prepared,
               state.ledger_opts,
               nil,
               resume
             )

    refute_received :unexpected_projection_resume
    {:ok, persisted} = Projection.Store.head(state.projection_store, f.refs.domain)
    assert persisted.cursor == Map.take(prefix, [:revision, :head_digest])
    assert {:ok, recovered} = Transaction.recover_verified(state)
    assert_persisted_once(f, state, recovered)
  end

  test "a verified complete prefix can initialize the per-record persistence bridge", %{
    f: f,
    storage: storage
  } do
    paid = Fixture.paid_evidence(f)
    assert {:ok, ^paid} = Fixture.observe_payment(f, paid)
    complete = Sequencer.projection(f.server)
    state = :sys.get_state(f.server)
    Fixture.stop_process(f.server)
    assert {:ok, initialized} = Projection.Persistence.initialize(%{state | projection: complete})
    refute initialized.projection_handle == state.projection_handle
    {:ok, %{cursor: cursor}} = ProjectionStore.head(f.refs.domain, server: storage)
    assert cursor.revision == complete.revision
    assert cursor.head_digest == complete.head_digest
  end

  test "archived history supports paged audit, proposition and authority reads without retention",
       %{f: f} do
    for n <- 1..105 do
      evidence =
        Fixture.paid_evidence(f, %{proposition: "archived-#{n}", payload: "private-audit-#{n}"})

      assert {:ok, ^evidence} = Fixture.observe_payment(f, evidence)
    end

    {:ok, scope} =
      Spectre.GAM.Scope.new(
        Spectre.GAM.Domain.handle(f.server, f.refs.domain),
        Fixture.context(f)
      )

    assert {:ok, [evidence]} =
             Sequencer.query(f.server, scope, {:evidence_proposition, "archived-105"})

    assert evidence.payload == "private-audit-105"
    assert {:ok, authority} = Sequencer.query(f.server, scope, :authority)
    assert is_map(authority)
    assert {:ok, audit} = Sequencer.query(f.server, scope, {:diagnostics, [limit: 1]})
    refute inspect(audit) =~ "private-audit-"
    assert_same_history(f)
    assert :sys.get_state(f.server).projection.evidence == %{}

    status = f.server |> :sys.get_status() |> inspect(limit: :infinity)
    assert status =~ "revision:"
    refute status =~ "projection_store"
    refute status =~ "private-audit-"
  end

  defp assert_same_history(f) do
    assert {:ok, expected} = Projection.replay(Fixture.snapshot(f), f.constitution)
    assert Sequencer.projection(f.server) == expected
    expected
  end

  defp new_operations(f, before_calls) do
    f.mock |> Mock.calls() |> Enum.drop(before_calls) |> Enum.map(& &1.operation)
  end

  defp assert_persisted_once(f, state, recovered) do
    snapshot = Fixture.snapshot(f)
    assert snapshot.revision == state.projection.revision + 1
    assert recovered.revision == snapshot.revision
    {:ok, persisted} = Projection.Store.head(state.projection_store, f.refs.domain)
    assert persisted.handle == state.projection_handle
    assert persisted.cursor == Map.take(recovered, [:revision, :head_digest])
    assert {:ok, expected} = Projection.replay(snapshot, f.constitution)

    assert {:ok, complete} =
             Projection.WorkingSet.extend(
               %{state | projection: recovered},
               :projection,
               Runtime.now()
             )

    assert complete == expected
  end
end
