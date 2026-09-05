Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.GAMAdversarialTest do
  use ExUnit.Case, async: true

  alias Spectre.{Audit, Evidence, Interop, Label, Ledger, Outcome, SubmissionContext}
  alias Spectre.Bench.P1.Fixture
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Ledger.Entry

  setup do
    namespace = "gam-adversarial-#{System.unique_integer([:positive])}"
    fixture = Fixture.start(:ets, namespace, 3, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  test "copying a Grant across concurrent callers releases only one checkout receipt", %{
    fixture: f
  } do
    assert {:ok, %{act: act, grant: grant}} = submit(f, 1)
    before = Sequencer.projection(f.server)
    parent = self()

    tasks =
      for _ <- 1..16 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Sequencer.consume_grant(f.server, grant)
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 30_000)
    assert [{:ok, ^act, attempt, receipt}] = Enum.filter(results, &match?({:ok, _, _, _}, &1))
    assert receipt.attempt_ref == attempt.ref

    for result <- Enum.reject(results, &match?({:ok, _, _, _}, &1)) do
      assert {:error, {:act_already_attempted, act_ref, attempt_ref}} = result
      assert act_ref == act.ref
      assert attempt_ref == attempt.ref
    end

    after_race = Sequencer.projection(f.server)
    assert after_race.revision == before.revision + 1
    assert after_race.attempts == %{attempt.ref => attempt}
    assert MapSet.size(after_race.consumed_nonces) == 1
    assert after_race.meters == before.meters
    assert_replay(f, after_race)
  end

  test "fresh nonces minted by admission retries cannot buy a second Attempt", %{fixture: f} do
    assert {:ok, %{act: act, grant: first_grant}} = submit(f, 1)
    before = Sequencer.projection(f.server)

    grants =
      for _ <- 1..8 do
        assert {:ok, %{act: ^act, grant: grant}} = submit(f, 1)
        grant
      end

    assert MapSet.size(MapSet.new([first_grant | grants], & &1.nonce)) == 9
    assert Sequencer.projection(f.server) == before
    assert {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, first_grant)
    consumed = Sequencer.projection(f.server)

    for grant <- grants do
      assert {:error, {:act_already_attempted, act_ref, attempt_ref}} =
               Sequencer.consume_grant(f.server, grant)

      assert act_ref == act.ref
      assert attempt_ref == attempt.ref
      assert Sequencer.projection(f.server) == consumed
    end

    assert {:ok, %{act: ^act, grant: nil}} = submit(f, 1)
    assert Sequencer.projection(f.server) == consumed
    assert_replay(f, consumed)
  end

  test "recomputing a context digest cannot authenticate forged trusted claims", %{fixture: f} do
    before = Sequencer.projection(f.server)

    for {field, value} <- [
          domain_ref: "foreign-domain",
          scope_ref: "foreign-scope",
          authenticated_principal_ref: f.mandate.grantor_ref,
          authentication_ref: "stolen-authentication",
          ingress_ref: "forged-ingress",
          channel_ref: "foreign-channel",
          session_ref: "foreign-session",
          host_generation: 2
        ] do
      assert {:ok, forged} =
               f.context
               |> Map.from_struct()
               |> Map.put(:ref, nil)
               |> Map.put(field, value)
               |> SubmissionContext.new()

      assert forged.ref != f.context.ref

      assert {:error, _reason} =
               Sequencer.submit(f.server, forged, Fixture.candidate(f, 1))

      assert Sequencer.projection(f.server) == before
      assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
      assert snapshot.revision == before.revision
      assert snapshot.head_digest == before.head_digest
    end

    # Positive control: the same Candidate still works with genuine ingress.
    assert {:ok, %{decision: %{outcome: :admitted}}} = submit(f, 1)
  end

  test "a malformed disclosure is rejected before commit without killing the Domain", %{
    fixture: f
  } do
    assert {:ok, label} = Label.new(owner_ref: f.mandate.grantor_ref, value: "private")
    candidate = Fixture.candidate(f, 1)
    before = Sequencer.projection(f.server)

    malformed =
      Map.put(candidate, :disclosure, %{
        destination_refs: candidate.target_refs,
        source_evidence_refs: candidate.evidence_refs,
        labels: [label | :broken]
      })

    assert {:error, _reason} = Sequencer.submit(f.server, f.context, malformed)
    assert Process.alive?(f.server)
    assert Sequencer.projection(f.server) == before
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert snapshot.revision == before.revision
    assert snapshot.head_digest == before.head_digest
    assert {:ok, %{decision: %{outcome: :admitted}}} = submit(f, 1)
    assert_replay(f, Sequencer.projection(f.server))
  end

  test "changing the envelope schema type cannot retain a valid interoperability identity", %{
    fixture: f
  } do
    assert {:ok, envelope} =
             Interop.outbound(f.refs.domain, "destination", Fixture.candidate(f, 1), [f.evidence])

    assert {:ok, contents} = Interop.inbound(envelope, "destination")
    assert contents.ref == envelope["ref"]

    assert {:error, _reason} =
             Interop.inbound(%{envelope | "schema_version" => 1.0}, "destination")
  end

  test "an improper inbound Evidence list returns an error instead of crashing the caller", %{
    fixture: f
  } do
    assert {:ok, envelope} =
             Interop.outbound(f.refs.domain, "destination", Fixture.candidate(f, 1), [f.evidence])

    malformed = %{envelope | "evidence" => [Evidence.canonical(f.evidence) | :broken]}
    assert {:error, _reason} = Interop.inbound(malformed, "destination")
    assert {:ok, _contents} = Interop.inbound(envelope, "destination")
  end

  test "dropping or duplicating an admission event cannot mint unaccounted authority", %{
    fixture: f
  } do
    assert {:ok, prefix} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, %{act: _act}} = submit(f, 1)
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    batch = Enum.drop(snapshot.entries, prefix.revision)
    payloads = Enum.map(batch, & &1.payload)

    assert Enum.map(payloads, & &1["type"]) ==
             ~w(decision_recorded act_committed meter_reserved dispatch_ready)

    for index <- 0..3 do
      dropped = List.delete_at(payloads, index)
      duplicated = List.insert_at(payloads, index, Enum.at(payloads, index))
      assert_semantic_rejection(f, rewrite_tail(prefix, [dropped], hd(batch).recorded_at))
      assert_semantic_rejection(f, rewrite_tail(prefix, [duplicated], hd(batch).recorded_at))
    end

    assert {:ok, ^snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert_replay(f, Sequencer.projection(f.server))
  end

  test "an admission cannot be reordered or split into individually durable fragments", %{
    fixture: f
  } do
    assert {:ok, prefix} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, _} = submit(f, 1)
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    batch = Enum.drop(snapshot.entries, prefix.revision)
    payloads = Enum.map(batch, & &1.payload)

    for permutation <- permutations(payloads), permutation != payloads do
      assert_semantic_rejection(f, rewrite_tail(prefix, [permutation], hd(batch).recorded_at))
    end

    for cut <- 1..3 do
      {left, right} = Enum.split(payloads, cut)
      assert_semantic_rejection(f, rewrite_tail(prefix, [left, right], hd(batch).recorded_at))
    end
  end

  test "one Attempt's receipt cannot settle another Act or recover its allocation", %{fixture: f} do
    assert {:ok, %{act: first, grant: first_grant}} = submit(f, 1)
    assert {:ok, ^first, first_attempt, _} = Sequencer.consume_grant(f.server, first_grant)
    assert {:ok, %{act: second, grant: second_grant}} = submit(f, 2)
    assert {:ok, ^second, second_attempt, _} = Sequencer.consume_grant(f.server, second_grant)
    receipt = Fixture.outcome_evidence(f, first, first_attempt)
    before = Sequencer.projection(f.server)

    assert {:error, {:executor_evidence_binding_mismatch, _}} =
             Sequencer.record_executor_evidence(f.server, second.ref, second_attempt.ref, receipt)

    assert Sequencer.projection(f.server) == before

    assert {:ok, [^receipt]} =
             Sequencer.record_executor_evidence(f.server, first.ref, first_attempt.ref, receipt)

    before = Sequencer.projection(f.server)
    forged = Fixture.outcome(second, second_attempt, receipt)
    assert {:error, _reason} = Sequencer.record_outcome(f.server, forged)
    assert Sequencer.projection(f.server) == before
    assert before.meter_reservations[first.ref] == :reserved
    assert before.meter_reservations[second.ref] == :reserved

    # Authentic observation settles only the causal Act, never both.
    outcome = Fixture.outcome(first, first_attempt, receipt)
    assert {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    after_observation = Sequencer.projection(f.server)
    assert after_observation.meter_reservations[first.ref] == :settled
    assert after_observation.meter_reservations[second.ref] == :reserved
    assert_replay(f, after_observation)
  end

  test "provisional executor Evidence is recordable but cannot declare a definitive success", %{
    fixture: f
  } do
    assert {:ok, %{act: act, grant: grant}} = submit(f, 1)
    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)
    receipt = Fixture.outcome_evidence(f, act, attempt)

    assert {:ok, provisional} =
             receipt
             |> Map.from_struct()
             |> Map.merge(%{
               ref: nil,
               provisional: true,
               valid_until: receipt.observed_at + 60_000
             })
             |> Evidence.new()

    assert {:ok, [^provisional]} =
             Sequencer.record_executor_evidence(f.server, act.ref, attempt.ref, provisional)

    before = Sequencer.projection(f.server)
    outcome = Fixture.outcome(act, attempt, provisional)

    assert {:error, {:outcome_evidence_provisional, _, _}} =
             Sequencer.record_outcome(f.server, outcome)

    assert Sequencer.projection(f.server) == before
    assert before.meter_reservations[act.ref] == :reserved
    assert before.outcomes == %{}
    assert_replay(f, before)
  end

  test "a corrected no-effect claim cannot hide a deficit after the released budget was reused",
       %{
         fixture: f
       } do
    assert {:ok, %{act: act, grant: grant}} = submit(f, 1)
    assert {:ok, ^act, attempt, _} = Sequencer.consume_grant(f.server, grant)

    assert {:ok, no_effect_evidence} =
             f
             |> Fixture.outcome_evidence(act, attempt)
             |> Map.from_struct()
             |> Map.drop([:ref])
             |> Map.put(
               :proposition,
               Outcome.proposition(
                 :definitive_no_effect,
                 act.ref,
                 attempt.ref,
                 act.executor_contract_ref
               )
             )
             |> Evidence.new()

    assert {:ok, [^no_effect_evidence]} =
             Sequencer.record_executor_evidence(
               f.server,
               act.ref,
               attempt.ref,
               no_effect_evidence
             )

    assert {:ok, no_effect} =
             act
             |> Fixture.outcome(attempt, no_effect_evidence)
             |> Map.from_struct()
             |> Map.merge(%{ref: nil, status: :definitive_no_effect})
             |> Outcome.new()

    assert {:ok, ^no_effect} = Sequencer.record_outcome(f.server, no_effect)
    assert Sequencer.projection(f.server).meter_reservations[act.ref] == :released

    admissions =
      for n <- 2..4 do
        assert {:ok, %{decision: %{outcome: :admitted}} = admission} = submit(f, n)
        admission
      end

    before = Sequencer.projection(f.server)
    assert %{available: 0, reserved: 3, spent: 0} = before.meters[f.mandate.ref][f.refs.meter]
    receipt = Fixture.outcome_evidence(f, act, attempt)

    assert {:ok, [^receipt]} =
             Sequencer.record_executor_evidence(f.server, act.ref, attempt.ref, receipt)

    assert {:ok, correction} =
             act
             |> Fixture.outcome(attempt, receipt)
             |> Map.from_struct()
             |> Map.merge(%{ref: nil, contradicts_outcome_ref: no_effect.ref})
             |> Outcome.new()

    assert {:ok, ^correction} = Sequencer.record_outcome(f.server, correction)
    corrected = Sequencer.projection(f.server)
    assert corrected.meters == before.meters
    assert corrected.outcomes[no_effect.ref] == no_effect
    assert corrected.outcomes[correction.ref] == correction
    assert corrected.meter_reservations[act.ref] == :suspended
    assert corrected.meter_recontainments[act.ref].deficits == %{f.refs.meter => 1}
    assert corrected.meter_recontainments[act.ref].recontained == %{}
    assert [duty] = Map.values(corrected.duties)
    assert duty.class == :contradicted_outcome
    assert duty.status == :open
    assert duty.act_ref == act.ref
    assert duty.attempt_ref == attempt.ref

    assert {:error, :mandate_meter_debt} = Sequencer.consume_grant(f.server, grant)

    for admission <- admissions do
      assert {:error, :mandate_meter_debt} =
               Sequencer.consume_grant(f.server, admission.grant)
    end

    assert {:ok, ^correction} = Sequencer.record_outcome(f.server, correction)
    assert Sequencer.projection(f.server) == corrected
    assert_replay(f, corrected)
  end

  # These attacks change semantic history, not hash validity. They do not claim
  # to defend a BEAM node against an operator who already owns its memory/keys.
  defp rewrite_tail(prefix, batches, recorded_at) do
    Enum.with_index(batches)
    |> Enum.reduce(prefix, fn {payloads, index}, snapshot ->
      assert {:ok, entries} =
               Entry.build_batch(
                 snapshot.domain_ref,
                 "adversarial-tail-#{index}",
                 payloads,
                 snapshot.revision,
                 recorded_at,
                 snapshot.head_digest
               )

      %{
        snapshot
        | entries: snapshot.entries ++ entries,
          revision: snapshot.revision + length(entries),
          head_digest: List.last(entries).digest
      }
    end)
  end

  defp assert_semantic_rejection(f, forged) do
    constitution = Keyword.fetch!(f.sequencer_opts, :constitution)
    assert {:ok, exported} = Ledger.export_snapshot(forged)
    assert {:ok, ^forged} = Ledger.verify(exported)
    assert {:error, _reason} = Projection.replay(forged, constitution)

    assert {:error, {:semantic_violation, %{reason: _reason}}} =
             Audit.verify(exported, constitution, List.last(forged.entries).recorded_at)
  end

  defp assert_replay(f, projection) do
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)
    assert {:ok, ^projection} = Projection.replay(snapshot, projection.constitution)

    assert {:ok, _report} =
             Audit.verify(snapshot, projection.constitution, projection.recorded_at)
  end

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for head <- values, tail <- permutations(List.delete(values, head)), do: [head | tail]
  end

  defp submit(f, n), do: Sequencer.submit(f.server, f.context, Fixture.candidate(f, n))
end
