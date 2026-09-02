Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.AuditTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.{Event, Sequencer}
  alias Spectre.Ledger.Entry
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "audits a complete lifecycle and reports the foundation applicable to its Act" do
    fixture = start_domain("complete")
    {act, attempt} = admit_and_attempt(fixture, 500)

    receipt = Fixture.receipt_evidence(fixture, act.ref)
    assert {:ok, ^receipt} = Sequencer.record_evidence(fixture.server, receipt)

    outcome = Fixture.outcome(fixture, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)

    assert {:ok, report} = Spectre.Audit.verify(Fixture.snapshot(fixture))

    assert report.format == "spectre-semantic-audit"

    assert report.counts == %{
             mandates: 1,
             decisions: 1,
             acts: 1,
             attempts: 1,
             outcomes: 1,
             duties: 0
           }

    act_ref = act.ref
    host_profile_ref = fixture.refs.host_profile
    surface_ref = fixture.refs.surface

    assert [context] = report.act_contexts
    assert context.act_ref == act_ref
    assert context.host_profile_ref == host_profile_ref
    assert context.host_profile["ref"] == host_profile_ref
    assert context.surface_ref == surface_ref
    assert context.surface["ref"] == surface_ref
    assert context.surface_revision == fixture.genesis.surface_revision

    account = report.meters[fixture.mandate.ref][fixture.refs.meter]
    assert account["ceiling"] == 10_000
    assert account["available"] == 9_500
    assert account["spent"] == 500
  end

  test "keeps an ambiguous world result visible as suspended quantity and an open Duty" do
    fixture = start_domain("ambiguous")
    {act, attempt} = admit_and_attempt(fixture, 750)

    outcome = Fixture.outcome(fixture, act, attempt, :ambiguous, [])
    assert {:ok, ^outcome} = Sequencer.record_outcome(fixture.server, outcome)

    assert {:ok, report} = Spectre.Audit.verify(Fixture.snapshot(fixture))
    assert report.counts.duties == 1
    assert [%{"status" => :open, "act_ref" => act_ref}] = report.open_duties
    assert act_ref == act.ref

    account = report.meters[fixture.mandate.ref][fixture.refs.meter]
    assert account["reserved"] == 0
    assert account["suspended"] == 750
    assert account["spent"] == 0
  end

  test "rejects structurally valid phase fusion and an unevidenced Meter release" do
    fixture = start_domain("adversarial")
    payment = record_payment(fixture)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, 250, evidence_refs: [payment.ref])
             )

    admission_snapshot = Fixture.snapshot(fixture)
    {:ok, release} = Event.meter(:release, act)
    forged_release = append_batch(admission_snapshot, "forged-release", [release])
    act_ref = act.ref

    assert {:error,
            {:semantic_violation,
             %{
               reason: {:meter_disposition_without_same_batch_evidence, ^act_ref, :release}
             }}} = Spectre.Audit.verify(forged_release)

    assert {:ok, ^act, _attempt} = Sequencer.consume_grant(fixture.server, grant)

    fused =
      fixture
      |> Fixture.snapshot()
      |> fuse_batches("act_committed", "attempt_started")

    assert {:error,
            {:semantic_violation,
             %{reason: {:attempt_without_prior_durable_dispatch, _attempt_ref, ^act_ref}}}} =
             Spectre.Audit.verify(fused)
  end

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: "audit-" <> namespace)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp admit_and_attempt(fixture, amount) do
    payment = record_payment(fixture)

    assert {:ok, %{act: act, grant: grant}} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, amount, evidence_refs: [payment.ref])
             )

    assert {:ok, ^act, attempt} = Sequencer.consume_grant(fixture.server, grant)
    {act, attempt}
  end

  defp record_payment(fixture) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Sequencer.record_evidence(fixture.server, payment)
    payment
  end

  defp append_batch(snapshot, batch_id, payloads) do
    {:ok, entries} =
      Entry.build_batch(
        snapshot.domain_ref,
        batch_id,
        payloads,
        snapshot.revision,
        snapshot.head_digest
      )

    %{
      snapshot
      | entries: snapshot.entries ++ entries,
        revision: snapshot.revision + length(entries),
        head_digest: List.last(entries).digest
    }
  end

  defp fuse_batches(snapshot, left_type, right_type) do
    groups = Enum.chunk_by(snapshot.entries, & &1.batch_id)
    left_index = batch_index(groups, left_type)
    right_index = batch_index(groups, right_type)
    right = Enum.at(groups, right_index)

    groups
    |> Enum.with_index()
    |> Enum.reject(fn {_group, index} -> index == right_index end)
    |> Enum.map(fn {group, index} -> if index == left_index, do: group ++ right, else: group end)
    |> rechain(snapshot.domain_ref)
  end

  defp batch_index(groups, type) do
    Enum.find_index(groups, fn group ->
      Enum.any?(group, &(&1.payload["type"] == type))
    end)
  end

  defp rechain(groups, domain_ref) do
    {entries, revision, head_digest} =
      Enum.reduce(groups, {[], 0, Entry.genesis_digest()}, fn group, {all, revision, head} ->
        payloads = Enum.map(group, & &1.payload)

        {:ok, rebuilt} =
          Entry.build_batch(domain_ref, hd(group).batch_id, payloads, revision, head)

        {all ++ rebuilt, revision + length(rebuilt), List.last(rebuilt).digest}
      end)

    %{
      domain_ref: domain_ref,
      revision: revision,
      head_digest: head_digest,
      entries: entries,
      recovery: nil
    }
  end
end
