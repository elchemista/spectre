# Exercise the same deployment used to measure P1, so the benchmark cannot
# silently drift away from the core contracts verified here.
Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.GovernedRuntimeTest do
  use ExUnit.Case, async: true

  alias Spectre.{Audit, Candidate, Kernel, Ledger, Outcome}
  alias Spectre.Audit.Report
  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.Event, as: Event
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Kernel.Authority.Effective
  alias Spectre.Ledger.Store, as: LedgerStore
  alias Spectre.Scope.View

  setup do
    namespace = "core-#{System.unique_integer([:positive])}"
    fixture = Fixture.start(:ets, namespace, 3, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  test "pure admission is deterministic and cannot append or mint a Grant", %{fixture: f} do
    projection = Sequencer.projection(f.server)
    {:ok, candidate} = Candidate.new(Fixture.candidate(f, 1))
    time = projection.recorded_at
    assert {:ok, decision, act} = result = Kernel.evaluate(candidate, f.context, projection, time)
    assert decision.outcome == :admitted
    assert act.decision_ref == decision.ref
    assert act.material_digest == candidate.material_digest
    assert decision.recognition_evidence_refs == [f.evidence.ref]
    assert Kernel.evaluate(candidate, f.context, projection, time) == result
    assert Sequencer.projection(f.server) == projection
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert snapshot.revision == projection.revision
  end

  test "Evidence cannot replace authority and absent Evidence cannot satisfy a Mandate", %{
    fixture: f
  } do
    projection = Sequencer.projection(f.server)
    candidate = Fixture.candidate(f, 1)
    {:ok, no_authority} = Candidate.new(%{candidate | requested_mandate_ref: "missing-mandate"})

    assert {:ok, %{outcome: :refused}, nil} =
             Kernel.evaluate(no_authority, f.context, projection, projection.recorded_at)

    # Remove the fact from a disposable input, not from the ledger. Authority
    # remains intact, but no recognition proof can be obtained from it.
    {:ok, no_evidence} = Candidate.new(%{candidate | evidence_refs: []})
    without_evidence = %{projection | evidence: %{}}

    assert {:ok, %{outcome: :undecidable}, nil} =
             Kernel.evaluate(no_evidence, f.context, without_evidence, projection.recorded_at)
  end

  test "effective authority is candidate-bound and retained revocation does not inherit Conditions",
       %{fixture: f} do
    {:ok, candidate} = Candidate.new(Fixture.candidate(f, 1))
    {:ok, other} = Candidate.new(Fixture.candidate(f, 2))
    authority = Effective.from_mandate(f.mandate, candidate)
    assert {:ok, mandate} = Effective.snapshot(authority, candidate)
    assert mandate == f.mandate

    assert {:error, :effective_authority_candidate_mismatch} =
             Effective.snapshot(authority, other)

    retained = Effective.retained_revocation(f.mandate, candidate, f.mandate.grantor_ref)
    assert {:ok, snapshot} = Effective.snapshot(retained, candidate)
    assert snapshot.conditions == []
    assert snapshot.meters == %{}
    assert snapshot.classes == ["mandate.revoke"]
    assert snapshot.target_refs == [f.mandate.ref]
  end

  test "Act and Attempt are committed before their capability leaves the sequencer", %{fixture: f} do
    assert {:ok, %{decision: decision, act: act, grant: grant}} = submit(f, 1)
    projection = Sequencer.projection(f.server)
    assert projection.acts[act.ref] == act
    assert projection.decisions[decision.ref] == decision
    assert map_size(projection.attempts) == 0
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, ^projection} = Projection.replay(snapshot, projection.constitution)

    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)
    projection = Sequencer.projection(f.server)
    assert projection.attempts[attempt.ref] == attempt
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, ^projection} = Projection.replay(snapshot, projection.constitution)
    assert {:error, _} = Sequencer.consume_grant(f.server, grant)
    assert map_size(Sequencer.projection(f.server).attempts) == 1
  end

  test "Candidate retries do not append again and changed material cannot reuse its identity", %{
    fixture: f
  } do
    assert {:ok, first} = submit(f, 1)
    before = Sequencer.projection(f.server)
    assert {:ok, retry} = submit(f, 1)
    assert retry.decision == first.decision
    assert retry.act == first.act
    assert Sequencer.projection(f.server).revision == before.revision
    changed = %{Fixture.candidate(f, 2) | identity_key: Fixture.candidate(f, 1).identity_key}
    assert {:error, _} = Sequencer.submit(f.server, f.context, changed)
    assert Sequencer.projection(f.server).revision == before.revision
  end

  test "concurrent proposals cannot overspend the shared allocation", %{fixture: f} do
    parent = self()

    tasks =
      for n <- 1..10 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> submit(f, n)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)
    assert Enum.count(results, &match?({:ok, %{decision: %{outcome: :admitted}}}, &1)) == 3

    assert Enum.count(
             results,
             &match?({:ok, %{decision: %{outcome: :refused}, act: nil, grant: nil}}, &1)
           ) == 7

    projection = Sequencer.projection(f.server)
    assert map_size(projection.acts) == 3
    assert map_size(projection.decisions) == 10
    assert account(f, projection).available == 0
    assert account(f, projection).reserved == 3
    assert_replay_and_audit(f, projection)
  end

  test "success settles resources and live state agrees with canonical replay and independent audit",
       %{fixture: f} do
    {:ok, %{act: act, grant: grant}} = submit(f, 1)
    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)
    evidence = Fixture.outcome_evidence(f, act, attempt)

    assert {:ok, [^evidence]} =
             Sequencer.record_executor_evidence(f.server, act.ref, attempt.ref, evidence)

    outcome = Fixture.outcome(act, attempt, evidence)
    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    projection = Sequencer.projection(f.server)
    assert account(f, projection).spent == 1
    assert account(f, projection).reserved == 0
    assert projection.meter_reservations[act.ref] == :settled
    assert_replay_and_audit(f, projection)

    # The lightweight Evidence read must agree with the full scoped view,
    # including executor facts reached through the Act/Attempt relationship.
    assert {:ok, view} = View.from_projection(projection, f.refs.scope)
    refs = Enum.map(view.evidence, & &1.ref) |> Enum.reverse()
    assert evidence.ref in refs
    assert f.evidence.ref in refs
    assert {:ok, selected} = View.evidence(projection, f.refs.scope, refs)
    assert Enum.map(selected, & &1.ref) == refs

    assert {:error, {:evidence_outside_scope, "missing"}} =
             View.evidence(projection, f.refs.scope, ["missing"])

    assert {:error, {:scope_not_open, "other"}} = View.evidence(projection, "other", refs)
  end

  test "ambiguous outcome opens a durable Duty and keeps resources suspended across recovery", %{
    fixture: f
  } do
    {:ok, %{act: act, grant: grant}} = submit(f, 1)
    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)

    {:ok, outcome} =
      Outcome.new(
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: :ambiguous,
        evidence_refs: [],
        observed_at: System.system_time(:millisecond),
        details_ref: "network-interrupted"
      )

    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    projection = Sequencer.projection(f.server)
    assert account(f, projection).suspended == 1
    assert account(f, projection).available == 2
    assert map_size(projection.duties) == 1
    assert_replay_and_audit(f, projection)

    restarted = Fixture.restart(f)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert Sequencer.projection(restarted) == projection
    assert {:error, _} = Sequencer.consume_grant(restarted, grant)
    assert map_size(Sequencer.projection(restarted).attempts) == 1
    assert map_size(Sequencer.projection(restarted).duties) == 1
  end

  test "unsealed contexts cannot cross ingress or write to the ledger", %{fixture: f} do
    before = Sequencer.projection(f.server)

    assert {:error, _} =
             Sequencer.submit(f.server, %{f.context | seal: nil}, Fixture.candidate(f, 1))

    assert {:error, _} =
             Sequencer.submit(
               f.server,
               %{f.context | host_generation: 2},
               Fixture.candidate(f, 1)
             )

    assert Sequencer.projection(f.server) == before
  end

  test "authenticated ingress cannot authorize spoofed principals, scopes or targets", %{
    fixture: f
  } do
    projection = Sequencer.projection(f.server)
    base = Fixture.candidate(f, 1)

    for attrs <- [
          %{base | proposer_ref: "another-principal"},
          %{base | scope_ref: "another-scope"},
          %{
            base
            | target_refs: ["another-target"],
              consequence: Map.put(base.consequence, "target_ref", "another-target")
          }
        ] do
      {:ok, candidate} = Candidate.new(attrs)

      assert {:ok, %{outcome: :refused}, nil} =
               Kernel.evaluate(candidate, f.context, projection, projection.recorded_at)
    end
  end

  test "a modified Grant never creates an Attempt", %{fixture: f} do
    {:ok, %{grant: grant}} = submit(f, 1)
    before = Sequencer.projection(f.server)

    assert {:error, _} =
             Sequencer.consume_grant(f.server, %{grant | executor_ref: "another-executor"})

    assert {:error, _} =
             Sequencer.consume_grant(f.server, %{
               grant
               | material_digest: String.duplicate("0", 64)
             })

    assert Sequencer.projection(f.server) == before
  end

  test "valid ledger hashes cannot legitimize an admitted Decision without its atomic Act", %{
    fixture: f
  } do
    projection = Sequencer.projection(f.server)
    {:ok, candidate} = Candidate.new(Fixture.candidate(f, 1))

    {:ok, decision, _act} =
      Kernel.evaluate(candidate, f.context, projection, projection.recorded_at)

    {:ok, event} = Event.record(:decision, decision)

    # Deliberately bypass the writer's semantic gate to simulate a corrupted
    # store/export with a correctly hashed, but incomplete, logical batch.
    assert {:ok, _} =
             LedgerStore.append(
               f.store_config,
               f.refs.domain,
               "incomplete-admission",
               [event],
               projection.revision,
               recorded_at: projection.recorded_at
             )

    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, exported} = Ledger.export(f.store_config, f.refs.domain)
    assert {:error, _} = Projection.replay(snapshot, projection.constitution)

    assert {:error, {:semantic_violation, _}} =
             Audit.verify(exported, projection.constitution, projection.recorded_at)

    assert Sequencer.projection(f.server) == projection
  end

  test "a foreign proposal imports neither authority nor a Duty into its recipient", %{fixture: f} do
    # This GAM boundary also leaves room for future composed subjects: transport
    # and shared hosting must never stand in for the recipient's own decision.
    candidate = %{Fixture.candidate(f, 1) | requested_mandate_ref: "foreign-mandate"}
    before = Sequencer.projection(f.server)

    assert {:ok, envelope} =
             Spectre.Interop.outbound("foreign-domain", f.refs.domain, candidate, [f.evidence])

    assert {:ok, received} = Spectre.Interop.inbound(envelope, f.refs.domain)
    assert Sequencer.projection(f.server) == before

    assert {:error, :interop_envelope_binding_mismatch} =
             Spectre.Interop.inbound(envelope, "another-domain")

    assert {:error, _} = Spectre.Interop.inbound(Map.put(envelope, "grant", %{}), f.refs.domain)

    assert {:ok, %{decision: %{outcome: :refused}, act: nil, grant: nil}} =
             Sequencer.submit(f.server, f.context, received.candidate)

    after_refusal = Sequencer.projection(f.server)
    assert after_refusal.mandates == before.mandates
    assert after_refusal.duties == before.duties
    assert after_refusal.acts == before.acts
  end

  defp submit(f, n), do: Sequencer.submit(f.server, f.context, Fixture.candidate(f, n))

  defp account(f, projection) do
    {:ok, accounts} = Projection.meter_accounts(projection, f.mandate.ref)
    Map.fetch!(accounts, f.refs.meter)
  end

  defp assert_replay_and_audit(f, projection) do
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, ^projection} = Projection.replay(snapshot, projection.constitution)
    assert {:ok, exported} = Ledger.export(f.store_config, f.refs.domain)
    time = projection.recorded_at
    assert {:ok, expected_report} = Report.build(projection, time)
    assert {:ok, ^expected_report} = Audit.verify(exported, projection.constitution, time)

    [first | rest] = exported["entries"]
    tampered = %{exported | "entries" => [%{first | "payload" => %{}} | rest]}

    assert {:error, {:ledger_integrity_failed, _}} =
             Audit.verify(tampered, projection.constitution, time)
  end
end
